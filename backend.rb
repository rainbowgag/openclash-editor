#!/usr/bin/env ruby

require "yaml"

DEFAULT_SOURCE = "/etc/openclash/config/config.yaml"

def configured_source
  override = ENV["OPENCLASH_CONFIG_PATH"].to_s.strip
  return override unless override.empty?

  configured = `uci -q get openclash.config.config_path 2>/dev/null`.strip
  configured.empty? ? DEFAULT_SOURCE : configured
end

SOURCE = configured_source
TEST = "/tmp/openclash-editor-preview.yaml"
PENDING_STATE = "/tmp/openclash-editor-preview-state.json"
STATE = "/etc/openclash/openclash-editor-state.json"
VERSION_FILE = "/usr/share/openclash-editor/VERSION"
QR_TOKEN_DIR = "/tmp/openclash-editor-qr"
QR_TOKEN_TTL = 600

def json_generate(value)
  case value
  when Hash
    "{" + value.map { |key, item| "#{json_generate(key.to_s)}:#{json_generate(item)}" }.join(",") + "}"
  when Array
    "[" + value.map { |item| json_generate(item) }.join(",") + "]"
  when String
    '"' + value.each_codepoint.map do |code|
      case code
      when 0x22 then '\\"'
      when 0x5c then '\\\\'
      when 0x08 then '\\b'
      when 0x0c then '\\f'
      when 0x0a then '\\n'
      when 0x0d then '\\r'
      when 0x09 then '\\t'
      else code < 0x20 ? format('\\u%04x', code) : code.chr(Encoding::UTF_8)
      end
    end.join + '"'
  when Integer, Float then value.to_s
  when true then "true"
  when false then "false"
  when nil then "null"
  else json_generate(value.to_s)
  end
end

def scalar(value)
  case value
  when true then "true"
  when false then "false"
  when Numeric then value.to_s
  when nil then "''"
  else
    string = value.to_s
    return string if string.match?(/\A[A-Za-z0-9_.\/:\-]+\z/) && !string.match?(/\A(?:true|false|null|yes|no|on|off|~|-?\d+(?:\.\d+)?)\z/i)
    "'#{string.gsub("'", "''")}'"
  end
end

def inline_yaml(value)
  case value
  when Hash
    "{" + value.map { |key, item| "#{key}: #{inline_yaml(item)}" }.join(", ") + "}"
  when Array
    "[" + value.map { |item| inline_yaml(item) }.join(", ") + "]"
  else
    scalar(value)
  end
end

def ordered_hash(hash, preferred_keys)
  output = {}
  preferred_keys.each { |key| output[key] = hash[key] if hash.key?(key) }
  hash.each { |key, value| output[key] = value unless output.key?(key) }
  output
end

def ordered_node(node)
  output = ordered_hash(node, %w[
    name type server port username password uuid alterId cipher udp tls network flow
    servername sni client-fingerprint alpn reality-opts ws-opts http-opts grpc-opts
    tcp-opts skip-cert-verify obfs obfs-password dialer-proxy
  ])
  if output["reality-opts"].is_a?(Hash)
    output["reality-opts"] = ordered_hash(output["reality-opts"], %w[public-key short-id spider-x])
  end
  output
end

def load_config(path = SOURCE)
  YAML.load_file(path, aliases: true) || {}
end

def read_state
  YAML.safe_load(File.read(STATE), aliases: true) || {}
rescue Errno::ENOENT, Psych::SyntaxError
  {}
end

def ipv4_to_i(address)
  parts = address.to_s.split(".")
  raise "无效 IPv4 地址：#{address}" unless parts.length == 4 && parts.all? { |part| part.match?(/\A\d{1,3}\z/) && part.to_i.between?(0, 255) }
  parts.reduce(0) { |value, part| (value << 8) | part.to_i }
end

def i_to_ipv4(value)
  [24, 16, 8, 0].map { |shift| (value >> shift) & 255 }.join(".")
end

def netmask_prefix(netmask)
  bits = format("%032b", ipv4_to_i(netmask))
  raise "无效子网掩码：#{netmask}" unless bits.match?(/\A1*0*\z/)
  bits.count("1")
end

def cidr_info(cidr)
  match = cidr.to_s.strip.match(/\A([^\/]+)\/(\d{1,2})\z/)
  raise "无效网段：#{cidr}" unless match
  address = ipv4_to_i(match[1])
  prefix = match[2].to_i
  raise "LAN 网段前缀必须在 /1 至 /30 之间" unless prefix.between?(1, 30)
  mask = (0xffffffff << (32 - prefix)) & 0xffffffff
  network = address & mask
  broadcast = network | (~mask & 0xffffffff)
  {
    "cidr" => "#{i_to_ipv4(network)}/#{prefix}",
    "prefix" => prefix,
    "network_i" => network,
    "broadcast_i" => broadcast,
    "first_i" => network + 1,
    "last_i" => broadcast - 1,
    "first_host" => i_to_ipv4(network + 1),
    "last_host" => i_to_ipv4(broadcast - 1)
  }
end

def detect_lan
  begin
    raw = IO.popen(["ubus", "call", "network.interface.lan", "status"], &:read)
    status = YAML.safe_load(raw, aliases: true) || {}
    address = Array(status["ipv4-address"]).find { |item| item.is_a?(Hash) && item["address"] && item["mask"] }
    if address
      gateway = address["address"].to_s
      info = cidr_info("#{gateway}/#{address['mask']}")
      return info.merge("gateway" => gateway, "detected" => true, "source" => "ubus")
    end
  rescue StandardError
    nil
  end

  ipaddr = `uci -q get network.lan.ipaddr 2>/dev/null`.strip
  raise "无法从 ubus 或 UCI 检测 LAN 地址" if ipaddr.empty?
  if ipaddr.include?("/")
    gateway, prefix = ipaddr.split("/", 2)
  else
    gateway = ipaddr
    netmask = `uci -q get network.lan.netmask 2>/dev/null`.strip
    netmask = "255.255.255.0" if netmask.empty?
    prefix = netmask_prefix(netmask)
  end
  cidr_info("#{gateway}/#{prefix}").merge("gateway" => gateway, "detected" => true, "source" => "uci")
rescue StandardError => error
  cidr_info("192.168.1.0/24").merge(
    "gateway" => "",
    "detected" => false,
    "source" => "fallback",
    "error" => error.message
  )
end

def rule_parts(rule)
  match = rule.to_s.match(/\ASRC-IP-CIDR,(\d{1,3}(?:\.\d{1,3}){3})\/32,([^,\r\n]+)(?:,no-resolve)?\z/)
  return nil unless match
  ipv4_to_i(match[1])
  { "ip" => match[1], "name" => match[2] }
rescue StandardError
  nil
end

def device_rules(config)
  Array(config["rules"]).select { |rule| rule.to_s.start_with?("SRC-IP-CIDR,") }.map(&:to_s)
end

def system_architecture
  architecture = `uname -m 2>/dev/null`.strip
  architecture.empty? ? "unknown" : architecture
end

def qr_token_path(token)
  raise "无效或已过期的二维码" unless token.to_s.match?(/\A[0-9a-f]{32}\z/)
  File.join(QR_TOKEN_DIR, "#{token}.json")
end

def qr_create_response(node_name, reload_openclash)
  node_name = node_name.to_s.strip
  raise "请输入已有节点的准确名称" if node_name.empty?
  config = load_config
  names = Array(config["proxies"]).filter_map do |node|
    node["name"].to_s if node.is_a?(Hash) && node["name"]
  end
  raise "节点不存在：#{node_name}" unless names.include?(node_name)

  Dir.mkdir(QR_TOKEN_DIR, 0o700) unless Dir.exist?(QR_TOKEN_DIR)
  File.chmod(0o700, QR_TOKEN_DIR)
  Dir.glob(File.join(QR_TOKEN_DIR, "*")).each do |old_path|
    File.delete(old_path) if File.file?(old_path) && File.mtime(old_path) < Time.now - QR_TOKEN_TTL
  rescue Errno::ENOENT
    nil
  end
  token = File.binread("/dev/urandom", 16).unpack1("H*")
  expires_at = Time.now.to_i + QR_TOKEN_TTL
  path = qr_token_path(token)
  File.write(path, json_generate({
    "node" => node_name,
    "expires_at" => expires_at,
    "reload_openclash" => reload_openclash == true
  }))
  File.chmod(0o600, path)
  {
    "ok" => true,
    "token" => token,
    "node" => node_name,
    "expires_at" => expires_at,
    "expires_in" => QR_TOKEN_TTL
  }
end

def qr_read_token(token)
  path = qr_token_path(token)
  raise "二维码不存在、已经使用或已经过期" unless File.file?(path)
  data = YAML.safe_load(File.read(path), aliases: true) || {}
  if data["expires_at"].to_i < Time.now.to_i
    File.delete(path)
    raise "二维码已经过期，请在管理页面重新生成"
  end
  [path, data]
end

def qr_info_response(token)
  _path, data = qr_read_token(token)
  {
    "ok" => true,
    "node" => data["node"].to_s,
    "expires_at" => data["expires_at"].to_i,
    "reload_openclash" => data["reload_openclash"] == true
  }
end

def lan_ip!(address)
  address = address.to_s.sub(/\A::ffff:/, "")
  value = ipv4_to_i(address)
  lan = detect_lan
  network = cidr_info(lan.fetch("cidr"))
  raise "只能从路由器 LAN 局域网扫码绑定" unless value.between?(network["first_i"], network["last_i"])
  raise "不能绑定路由器自身地址" if address == lan["gateway"]
  address
end

def lookup_lan_device(address)
  if File.file?("/tmp/dhcp.leases")
    File.foreach("/tmp/dhcp.leases") do |line|
      fields = line.split
      next unless fields[2] == address
      mac = fields[1].to_s.downcase
      next unless mac.match?(/\A[0-9a-f]{2}(?::[0-9a-f]{2}){5}\z/)
      return { "mac" => mac, "hostname" => fields[3].to_s }
    end
  end

  neighbor = IO.popen(["ip", "neigh", "show", address], &:read)
  match = neighbor.match(/\blladdr\s+([0-9a-f]{2}(?::[0-9a-f]{2}){5})\b/i)
  raise "没有找到该手机的 DHCP 租约；请让手机保持自动获取 IP，并连接当前路由器 Wi-Fi 后重试" unless match
  { "mac" => match[1].downcase, "hostname" => "" }
end

def dhcp_host_sections
  output = IO.popen(["uci", "-q", "show", "dhcp"], &:read)
  sections = Hash.new { |hash, key| hash[key] = {} }
  output.each_line do |line|
    match = line.match(/\Adhcp\.([^.=]+)\.(mac|ip|name)=['"]?([^'"\r\n]+)['"]?\s*\z/)
    sections[match[1]][match[2]] = match[3] if match
  end
  sections
end

def reserved_ip_for_mac(mac)
  section = dhcp_host_sections.find { |_name, values| values["mac"].to_s.downcase == mac }
  section && section[1]["ip"].to_s.match?(/\A\d{1,3}(?:\.\d{1,3}){3}\z/) ? section[1]["ip"] : nil
end

def ensure_dhcp_reservation(mac, address, hostname)
  sections = dhcp_host_sections
  conflict = sections.find do |_name, values|
    values["ip"] == address && !values["mac"].to_s.empty? && values["mac"].downcase != mac
  end
  raise "固定地址 #{address} 已分配给另一台设备，请先处理 DHCP 静态租约冲突" if conflict

  existing = sections.find { |_name, values| values["mac"].to_s.downcase == mac }
  return existing[0] if existing && existing[1]["ip"] == address
  if existing && !existing[0].start_with?("oce_")
    raise "该设备已有手动 DHCP 静态租约 #{existing[1]['ip']}，未自动覆盖用户配置"
  end

  section = "oce_#{mac.delete(':')}"
  safe_name = hostname.to_s.gsub(/[^A-Za-z0-9_-]/, "")[0, 32]
  safe_name = "device-#{mac.delete(':')[-6, 6]}" if safe_name.empty? || safe_name == "*"
  system("uci", "-q", "delete", "dhcp.#{section}")
  commands = [
    ["uci", "set", "dhcp.#{section}=host"],
    ["uci", "set", "dhcp.#{section}.name=#{safe_name}"],
    ["uci", "set", "dhcp.#{section}.mac=#{mac}"],
    ["uci", "set", "dhcp.#{section}.ip=#{address}"],
    ["uci", "commit", "dhcp"]
  ]
  unless commands.all? { |command| system(*command) }
    system("uci", "revert", "dhcp")
    raise "写入 DHCP 静态租约失败"
  end
  system("/etc/init.d/dnsmasq", "reload") || raise("重新载入 DHCP 服务失败")
  section
end

def apply_qr_rule(address, node_name)
  config = load_config
  names = Array(config["proxies"]).filter_map do |node|
    node["name"].to_s if node.is_a?(Hash) && node["name"]
  end
  raise "二维码对应的节点已被删除：#{node_name}" unless names.include?(node_name)

  rules = device_rules(config).reject do |rule|
    parts = rule_parts(rule)
    parts && parts["ip"] == address
  end
  rules.unshift("SRC-IP-CIDR,#{address}/32,#{node_name}")
  lines = File.read(SOURCE).gsub("\r\n", "\n").split("\n", -1)
  replace_device_rules(lines, rules)
  generated = lines.join("\n")
  parsed = YAML.safe_load(generated, aliases: true)
  raise "扫码绑定生成的配置不是有效 YAML" unless parsed.is_a?(Hash)

  stamp = Time.now.strftime("%Y%m%d-%H%M%S")
  backup = File.join(File.dirname(SOURCE), ".#{File.basename(SOURCE)}.qr-backup-#{stamp}")
  File.binwrite(backup, File.binread(SOURCE))
  mode = File.stat(SOURCE).mode & 0o777
  File.chmod(mode, backup)
  staged = "#{SOURCE}.editor-qr"
  File.write(staged, generated)
  File.chmod(mode, staged)
  File.rename(staged, SOURCE)
  backup
end

def qr_bind_response(token, remote_address)
  path, data = qr_read_token(token)
  claimed_path = "#{path}.binding"
  begin
    File.rename(path, claimed_path)
  rescue Errno::ENOENT, Errno::EEXIST
    raise "二维码正在使用或已经使用，请重新生成"
  end

  begin
    source_ip = lan_ip!(remote_address)
    device = lookup_lan_device(source_ip)
    reserved_ip = reserved_ip_for_mac(device["mac"])
    target_ip = reserved_ip ? lan_ip!(reserved_ip) : source_ip
    backup = apply_qr_rule(target_ip, data["node"].to_s)
    begin
      section = ensure_dhcp_reservation(device["mac"], target_ip, device["hostname"])
    rescue StandardError
      File.binwrite(SOURCE, File.binread(backup))
      raise
    end
    File.delete(claimed_path)
    reload_requested = data["reload_openclash"] == true
    if reload_requested
      system("sh", "-c", "(sleep 2; /etc/init.d/openclash restart) >/tmp/openclash-editor-qr-restart.log 2>&1 &")
    end
    {
      "ok" => true,
      "node" => data["node"].to_s,
      "ip" => target_ip,
      "source_ip" => source_ip,
      "mac" => device["mac"],
      "hostname" => device["hostname"],
      "dhcp_section" => section,
      "backup" => backup,
      "reload_openclash" => reload_requested,
      "reconnect_required" => target_ip != source_ip
    }
  rescue StandardError
    File.rename(claimed_path, path) if File.file?(claimed_path) && !File.exist?(path)
    raise
  end
end

def change_summary(config, nodes, rules, anchor_names)
  current_nodes = Array(config["proxies"]).select { |node| node.is_a?(Hash) && node["name"] }
  before_by_name = current_nodes.to_h { |node| [node["name"].to_s, ordered_node(node)] }
  after_by_name = nodes.to_h { |node| [node["name"].to_s, ordered_node(node)] }
  added_nodes = after_by_name.keys - before_by_name.keys
  removed_nodes = before_by_name.keys - after_by_name.keys
  modified_nodes = (before_by_name.keys & after_by_name.keys).select do |name|
    before_by_name[name] != after_by_name[name]
  end

  current_anchors = Array(config.dig("pr", "proxies")).map(&:to_s)
  requested_anchors = anchor_names.map(&:to_s)
  current_rules = device_rules(config)
  requested_rules = rules.map(&:to_s)
  added_rules = requested_rules - current_rules
  removed_rules = current_rules - requested_rules

  lines = ["节点：新增 #{added_nodes.length}，删除 #{removed_nodes.length}，修改 #{modified_nodes.length}"]
  added_nodes.each { |name| lines << "  + #{name}" }
  removed_nodes.each { |name| lines << "  - #{name}" }
  modified_nodes.each { |name| lines << "  ~ #{name}" }
  if current_anchors != requested_anchors
    lines << "路由器代理节点："
    lines << "  - #{current_anchors.empty? ? '（空）' : current_anchors.join('、')}"
    lines << "  + #{requested_anchors.empty? ? '（空）' : requested_anchors.join('、')}"
  end
  lines << "设备规则：新增 #{added_rules.length}，删除 #{removed_rules.length}"
  added_rules.each { |rule| lines << "  + #{rule}" }
  removed_rules.each { |rule| lines << "  - #{rule}" }
  lines.join("\n")
end

def first_available_ip(rules, network, start_ip)
  used = rules.filter_map do |rule|
    parts = rule_parts(rule)
    next unless parts
    value = ipv4_to_i(parts["ip"])
    value if value.between?(network["first_i"], network["last_i"])
  end.to_h { |value| [value, true] }
  gateway_i = ipv4_to_i(network["gateway"]) unless network["gateway"].to_s.empty?
  candidate = ipv4_to_i(start_ip)
  candidate += 1 while candidate <= network["last_i"] && (used[candidate] || gateway_i == candidate)
  candidate <= network["last_i"] ? i_to_ipv4(candidate) : ""
end

def default_start_ip(network)
  candidate = network["first_i"]
  gateway_i = ipv4_to_i(network["gateway"]) unless network["gateway"].to_s.empty?
  candidate += 1 if gateway_i == candidate
  i_to_ipv4(candidate)
end

def state_response
  config = load_config
  saved_state = read_state
  detected_lan = detect_lan
  manual_network = saved_state["manual_network"] == true
  begin
    active_network = manual_network ? cidr_info(saved_state.fetch("network_cidr")) : cidr_info(detected_lan["cidr"])
  rescue StandardError
    manual_network = false
    active_network = cidr_info(detected_lan["cidr"])
  end
  active_network["gateway"] = detected_lan["gateway"] if active_network["cidr"] == detected_lan["cidr"]
  start_ip = default_start_ip(active_network)
  if saved_state["network_cidr"].to_s == active_network["cidr"] && !saved_state["start_ip"].to_s.empty?
    begin
      saved_start_i = ipv4_to_i(saved_state["start_ip"])
      start_ip = i_to_ipv4(saved_start_i) if saved_start_i.between?(active_network["first_i"], active_network["last_i"])
    rescue StandardError
      nil
    end
  end
  anchor_names = Array(config.dig("pr", "proxies")).map(&:to_s)
  nodes = Array(config["proxies"]).filter_map do |node|
    next unless node.is_a?(Hash) && node["name"]
    node = ordered_node(node)
    {
      "name" => node["name"].to_s,
      "type" => node["type"].to_s,
      "server" => node["server"].to_s,
      "port" => node["port"],
      "in_pr" => anchor_names.include?(node["name"].to_s),
      "data" => node,
      "raw" => "- #{inline_yaml(node)}"
    }
  end
  rules = device_rules(config)
  {
    "ok" => true,
    "nodes" => nodes,
    "rules" => rules,
    "start_ip" => start_ip,
    "next_ip" => first_available_ip(rules, active_network, start_ip),
    "network_cidr" => active_network["cidr"],
    "first_host" => active_network["first_host"],
    "last_host" => active_network["last_host"],
    "manual_network" => manual_network,
    "detected_lan_cidr" => detected_lan["cidr"],
    "gateway_ip" => detected_lan["gateway"],
    "detection_source" => detected_lan["source"],
    "detection_error" => detected_lan["error"],
    "architecture" => system_architecture,
    "source_sha256" => `sha256sum #{SOURCE} 2>/dev/null`.split.first.to_s,
    "version" => File.exist?(VERSION_FILE) ? File.read(VERSION_FILE).strip : "dev",
    "source_path" => SOURCE
  }
end

def reset_response
  lines = File.read(SOURCE).gsub("\r\n", "\n").split("\n", -1)
  replace_anchor_names(lines, [])
  replace_nodes(lines, [])
  replace_device_rules(lines, [])
  generated = lines.join("\n")
  parsed = YAML.safe_load(generated, aliases: true)
  raise "恢复后的配置不是 YAML 映射" unless parsed.is_a?(Hash)

  stamp = Time.now.strftime("%Y%m%d-%H%M%S")
  backup = File.join(File.dirname(SOURCE), ".#{File.basename(SOURCE)}.before-reset-#{stamp}")
  File.binwrite(backup, File.binread(SOURCE))
  File.chmod(File.stat(SOURCE).mode & 0o777, backup)
  staged = "#{SOURCE}.editor-reset"
  File.write(staged, generated)
  File.chmod(File.stat(SOURCE).mode & 0o777, staged)
  File.rename(staged, SOURCE)
  File.delete(STATE) if File.exist?(STATE)
  { "ok" => true, "backup" => backup }
end

def replace_anchor_names(lines, names)
  anchor = lines.index { |line| line.match?(/^pr:\s*&pr\s*$/) }
  raise "没有找到 pr: &pr 锚点" unless anchor
  header = (anchor + 1...lines.length).find { |index| lines[index].match?(/^  proxies:\s*/) }
  raise "没有找到 pr 锚点下的 proxies 字段" unless header
  finish = (header + 1...lines.length).find { |index| lines[index].match?(/^[A-Za-z0-9_-]+:\s*/) } || lines.length
  replacement = ["  proxies:  # managed by OpenClash Visual Editor"] + names.map { |name| "    - #{scalar(name)}" } + [""]
  lines[header...finish] = replacement
end

def replace_nodes(lines, nodes)
  header = lines.index { |line| line.match?(/^proxies:\s*/) }
  raise "没有找到顶层 proxies 字段" unless header
  finish = (header + 1...lines.length).find { |index| lines[index].match?(/^rules:\s*/) }
  raise "没有找到顶层 rules 字段" unless finish
  replacement = ["proxies:  # managed by OpenClash Visual Editor"] + nodes.map { |node| "  - #{inline_yaml(ordered_node(node))}" } + [""]
  lines[header...finish] = replacement
end

def replace_device_rules(lines, rules)
  header = lines.index { |line| line.match?(/^rules:\s*/) }
  raise "没有找到顶层 rules 字段" unless header
  finish = (header + 1...lines.length).find { |index| lines[index].match?(/^[A-Za-z0-9_-]+:\s*/) } || lines.length
  kept = lines[(header + 1)...finish].reject do |line|
    stripped = line.strip
    stripped.start_with?("- SRC-IP-CIDR,") || stripped.match?(/^# OPENCLASH-EDITOR:RULES:(?:BEGIN|END)$/)
  end
  replacement = [
    "rules:",
    "  # OPENCLASH-EDITOR:RULES:BEGIN",
    *rules.map { |rule| "  - #{rule}" },
    "  # OPENCLASH-EDITOR:RULES:END",
    *kept
  ]
  lines[header...finish] = replacement
end

def preview_response(request_path)
  request = YAML.safe_load(File.read(request_path), aliases: true)
  nodes = request.fetch("nodes")
  rules = request.fetch("rules")
  anchor_names = request.fetch("anchor_names")
  network = cidr_info(request.fetch("network_cidr"))
  start_ip = request.fetch("start_ip").to_s
  manual_network = request["manual_network"] == true
  start_ip_i = ipv4_to_i(start_ip)
  raise "自动分配起始 IP 不在规则网段内：#{start_ip}" unless start_ip_i.between?(network["first_i"], network["last_i"])
  raise "节点数据必须是数组" unless nodes.is_a?(Array)
  raise "规则数据必须是数组" unless rules.is_a?(Array)
  raise "pr 节点名称必须是数组" unless anchor_names.is_a?(Array)
  raise "节点数量超过上限" if nodes.length > 512
  raise "规则数量超过上限" if rules.length > 4096

  names = nodes.map do |node|
    raise "节点数据格式错误" unless node.is_a?(Hash)
    name = node["name"].to_s.strip
    raise "节点名称不能为空" if name.empty?
    raise "节点名称不能包含逗号或换行：#{name.inspect}" if name.match?(/[,\r\n]/)
    name
  end
  duplicates = names.group_by(&:itself).select { |_name, list| list.length > 1 }.keys
  raise "节点名称重复：#{duplicates.join(', ')}" unless duplicates.empty?
  anchor_names = anchor_names.map(&:to_s)
  missing_anchor_names = anchor_names.reject { |name| names.include?(name) }
  raise "pr 引用了不存在的节点：#{missing_anchor_names.join(', ')}" unless missing_anchor_names.empty?
  raise "pr 节点名称重复" unless anchor_names.uniq.length == anchor_names.length

  seen_rule_ips = {}
  rules.each do |rule|
    parts = rule_parts(rule)
    raise "设备规则格式错误：#{rule}" unless parts
    full_ip = parts["ip"]
    full_ip_i = ipv4_to_i(full_ip)
    raise "内网 IP 重复：#{i_to_ipv4(full_ip_i)}" if seen_rule_ips[full_ip_i]
    seen_rule_ips[full_ip_i] = true
    raise "规则引用了不存在的节点：#{parts['name']}" unless names.include?(parts["name"])
  end

  current_config = load_config
  diff = change_summary(current_config, nodes, rules, anchor_names)
  lines = File.read(SOURCE).gsub("\r\n", "\n").split("\n", -1)
  replace_anchor_names(lines, anchor_names)
  replace_nodes(lines, nodes)
  replace_device_rules(lines, rules.map(&:to_s))
  generated = lines.join("\n")
  parsed = YAML.safe_load(generated, aliases: true)
  raise "生成后的配置不是 YAML 映射" unless parsed.is_a?(Hash)
  File.write(TEST, generated)
  File.write(PENDING_STATE, json_generate({
    "start_ip" => i_to_ipv4(start_ip_i),
    "network_cidr" => network["cidr"],
    "manual_network" => manual_network
  }))
  { "ok" => true, "node_count" => nodes.length, "rule_count" => rules.length, "diff" => diff, "source_path" => SOURCE }
end

if __FILE__ == $PROGRAM_NAME
  begin
    result = case ARGV[0]
             when "state" then state_response
             when "preview" then preview_response(ARGV.fetch(1))
             when "reset" then reset_response
             when "qr-create" then qr_create_response(ARGV.fetch(1), ARGV[2] == "1")
             when "qr-info" then qr_info_response(ARGV.fetch(1))
             when "qr-bind" then qr_bind_response(ARGV.fetch(1), ARGV.fetch(2))
             else raise "未知操作"
             end
    puts json_generate(result)
  rescue StandardError => error
    puts json_generate({ "ok" => false, "error" => error.message, "details" => error.backtrace&.first(5)&.join("\n") })
    exit 1
  end
end
