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
PENDING_SLOTS = "/tmp/openclash-editor-preview-slots.json"
STATE = "/etc/openclash/openclash-editor-state.json"
VERSION_FILE = "/usr/share/openclash-editor/VERSION"
QR_TOKEN_DIR = "/tmp/openclash-editor-qr"
QR_TOKEN_TTL = 600
REBIND_WINDOW_SECONDS = 600
SLOT_STATE = ENV["OPENCLASH_EDITOR_SLOT_STATE"].to_s.strip.empty? ? "/etc/openclash/openclash-editor-slots.json" : ENV["OPENCLASH_EDITOR_SLOT_STATE"].to_s
SLOT_LOCK = ENV["OPENCLASH_EDITOR_SLOT_LOCK"].to_s.strip.empty? ? "/tmp/openclash-editor-slots.lock" : ENV["OPENCLASH_EDITOR_SLOT_LOCK"].to_s
SKIP_SLOT_DHCP = ENV["OPENCLASH_EDITOR_SKIP_SLOT_DHCP"] == "1"

def dhcp_lease_file
  override = ENV["OPENCLASH_EDITOR_DHCP_LEASE_FILE"].to_s.strip
  return override unless override.empty?

  configured = `uci -q get dhcp.@dnsmasq[0].leasefile 2>/dev/null`.strip
  configured.empty? ? "/tmp/dhcp.leases" : configured
rescue StandardError
  "/tmp/dhcp.leases"
end

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
    tcp-opts skip-cert-verify ss-opts obfs obfs-password dialer-proxy
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

def read_slots
  data = YAML.safe_load(File.read(SLOT_STATE), aliases: true) || {}
  slots = Array(data["slots"]).select { |slot| slot.is_a?(Hash) }
  write_slots(slots) if normalize_slot_codes!(slots)
  slots
rescue Errno::ENOENT, Psych::SyntaxError
  []
end

def write_slots(slots)
  directory = File.dirname(SLOT_STATE)
  Dir.mkdir(directory, 0o755) unless Dir.exist?(directory)
  staged = "#{SLOT_STATE}.new"
  File.write(staged, json_generate({ "slots" => slots }))
  File.chmod(0o600, staged)
  File.rename(staged, SLOT_STATE)
end

def with_slot_lock
  File.open(SLOT_LOCK, File::RDWR | File::CREAT, 0o600) do |lock|
    lock.flock(File::LOCK_EX)
    yield
  ensure
    lock.flock(File::LOCK_UN) rescue nil
  end
end

def random_hex(bytes)
  File.binread("/dev/urandom", bytes).unpack1("H*")
end

def slot_code!(value)
  raw = value.to_s.strip
  raise "请输入槽位口令" unless raw.match?(/\A\d{1,6}\z/)
  number = raw.to_i
  raise "槽位口令无效" unless number.positive?
  format("%03d", number)
end

def normalize_slot_codes!(slots)
  used = {}
  missing = []
  changed = false
  Array(slots).each_with_index do |slot, index|
    begin
      code = slot_code!(slot["code"])
      raise "duplicate" if used[code]
      changed ||= slot["code"].to_s != code
      slot["code"] = code
      used[code] = true
    rescue StandardError
      missing << [slot, index]
    end
  end

  next_number = 1
  missing.sort_by do |slot, index|
    begin
      [ipv4_to_i(slot["ip"]), index]
    rescue StandardError
      [0xffffffff, index]
    end
  end.each do |slot, _index|
    next_number += 1 while used[format("%03d", next_number)]
    code = format("%03d", next_number)
    slot["code"] = code
    used[code] = true
    changed = true
    next_number += 1
  end
  changed
end

def next_slot_code(slots)
  normalize_slot_codes!(slots)
  highest = Array(slots).map { |slot| slot["code"].to_s.to_i }.max.to_i
  format("%03d", highest + 1)
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
  lease_file = dhcp_lease_file
  if File.file?(lease_file)
    File.foreach(lease_file) do |line|
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

def apply_qr_rule_changes(changes)
  raise "规则变更不能为空" unless changes.is_a?(Hash) && !changes.empty?
  changes.each_key { |address| ipv4_to_i(address) }
  config = load_config
  names = Array(config["proxies"]).filter_map do |node|
    node["name"].to_s if node.is_a?(Hash) && node["name"]
  end
  changes.each_value do |node_name|
    next if node_name.nil?
    raise "目标节点不存在：#{node_name}" unless names.include?(node_name)
  end

  rules = device_rules(config).reject do |rule|
    parts = rule_parts(rule)
    parts && changes.key?(parts["ip"])
  end
  additions = changes.filter_map do |address, node_name|
    "SRC-IP-CIDR,#{address}/32,#{node_name}" unless node_name.nil?
  end
  rules = additions + rules
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

def apply_qr_rule_change(address, node_name = nil)
  apply_qr_rule_changes(address.to_s => node_name)
end

def apply_qr_rule(address, node_name)
  apply_qr_rule_change(address, node_name)
end

def active_dhcp_leases
  leases = []
  lease_file = dhcp_lease_file
  return leases unless File.file?(lease_file)
  File.foreach(lease_file) do |line|
    fields = line.split
    next unless fields.length >= 4
    mac = fields[1].to_s.downcase
    next unless mac.match?(/\A[0-9a-f]{2}(?::[0-9a-f]{2}){5}\z/)
    leases << {
      "expires_at" => fields[0].to_i,
      "mac" => mac,
      "ip" => fields[2].to_s,
      "hostname" => fields[3].to_s,
      "client_id" => fields[4].to_s
    }
  end
  leases
end

def purge_dhcp_lease(mac, address = "")
  normalized_mac = mac.to_s.downcase
  raise "无效的设备 MAC 地址" unless normalized_mac.match?(/\A[0-9a-f]{2}(?::[0-9a-f]{2}){5}\z/)
  address = address.to_s
  ipv4_to_i(address) unless address.empty?

  lease_file = dhcp_lease_file
  return 0 unless File.file?(lease_file)

  original = File.binread(lease_file)
  removed = 0
  retained = original.lines.reject do |line|
    fields = line.split
    matched = fields.length >= 3 &&
      fields[1].to_s.downcase == normalized_mac &&
      (address.empty? || fields[2].to_s == address)
    removed += 1 if matched
    matched
  end
  return 0 if removed.zero?

  temporary = "#{lease_file}.openclash-editor-#{Process.pid}"
  begin
    File.binwrite(temporary, retained.join)
    File.chmod(File.stat(lease_file).mode & 0o777, temporary)
    File.rename(temporary, lease_file)
  ensure
    File.delete(temporary) if File.exist?(temporary)
  end
  removed
end

def restart_dnsmasq!
  system("/etc/init.d/dnsmasq", "restart") || raise("重启 DHCP 服务失败")
  true
end

def activate_slot_dhcp_reservation(mac, target_ip, replaceable_macs = [], reclaim_target = false)
  normalized_mac = mac.to_s.downcase
  raise "无效的设备 MAC 地址" unless normalized_mac.match?(/\A[0-9a-f]{2}(?::[0-9a-f]{2}){5}\z/)
  allowed_replacements = Array(replaceable_macs).map { |item| item.to_s.downcase }.reject(&:empty?).uniq
  unless allowed_replacements.all? { |item| item.match?(/\A[0-9a-f]{2}(?::[0-9a-f]{2}){5}\z/) }
    raise "无效的原绑定设备 MAC 地址"
  end
  target_ip = lan_ip!(target_ip)
  leases = active_dhcp_leases
  current = leases.find { |lease| lease["mac"] == normalized_mac }
  target_conflicts = leases.select do |lease|
    lease["ip"] == target_ip && lease["mac"] != normalized_mac
  end
  unexpected_conflict = target_conflicts.find do |lease|
    !reclaim_target && !allowed_replacements.include?(lease["mac"])
  end
  if unexpected_conflict
    raise "槽位固定地址 #{target_ip} 当前被设备 #{unexpected_conflict['mac']} 动态占用，请等待该设备释放地址或更换槽位 IP"
  end

  old_ip = current ? current["ip"].to_s : ""
  leases_to_remove = target_conflicts.map { |lease| [lease["mac"], lease["ip"]] }
  leases_to_remove << [normalized_mac, old_ip] if !old_ip.empty? && old_ip != target_ip
  leases_to_remove.uniq!
  removed = 0
  if leases_to_remove.any?
    stopped = false
    begin
      system("/etc/init.d/dnsmasq", "stop") || raise("停止 DHCP 服务以释放旧租约失败")
      stopped = true
      leases_to_remove.each do |lease_mac, lease_ip|
        removed += purge_dhcp_lease(lease_mac, lease_ip)
      end
      system("/etc/init.d/dnsmasq", "start") || raise("启动 DHCP 服务失败")
      stopped = false
    ensure
      system("/etc/init.d/dnsmasq", "start") if stopped
    end
  else
    restart_dnsmasq!
  end

  {
    "old_ip" => old_ip,
    "target_ip" => target_ip,
    "lease_removed" => removed.positive?,
    "removed_count" => removed,
    "replaced_macs" => target_conflicts.map { |lease| lease["mac"] },
    "dnsmasq_restarted" => true,
    "reconnect_required" => old_ip != target_ip
  }
end

def qr_managed_device(mac)
  mac = mac.to_s.downcase
  raise "无效的设备 MAC 地址" unless mac.match?(/\A[0-9a-f]{2}(?::[0-9a-f]{2}){5}\z/)
  found = dhcp_host_sections.find do |section, values|
    section.start_with?("oce_") && !section.start_with?("oce_slot_") && values["mac"].to_s.downcase == mac
  end
  raise "没有找到该扫码设备，可能已经被删除" unless found
  section, values = found
  address = values["ip"].to_s
  ipv4_to_i(address)
  [section, values.merge("mac" => mac, "ip" => address)]
end

def qr_devices_response
  config = load_config
  rules_by_ip = {}
  device_rules(config).each do |rule|
    parts = rule_parts(rule)
    rules_by_ip[parts["ip"]] = parts["name"] if parts
  end
  leases_by_mac = active_dhcp_leases.to_h { |lease| [lease["mac"], lease] }
  devices = dhcp_host_sections.filter_map do |section, values|
    next unless section.start_with?("oce_") && !section.start_with?("oce_slot_")
    mac = values["mac"].to_s.downcase
    address = values["ip"].to_s
    next unless mac.match?(/\A[0-9a-f]{2}(?::[0-9a-f]{2}){5}\z/)
    begin
      ipv4_to_i(address)
    rescue StandardError
      next
    end
    lease = leases_by_mac[mac]
    {
      "section" => section,
      "name" => values["name"].to_s.empty? ? "扫码设备" : values["name"].to_s,
      "mac" => mac,
      "ip" => address,
      "node" => rules_by_ip[address].to_s,
      "online" => !lease.nil?,
      "current_ip" => lease ? lease["ip"] : "",
      "private_mac_likely" => (mac.split(":").first.to_i(16) & 2) != 0
    }
  end
  devices.sort_by! { |device| ipv4_to_i(device["ip"]) }
  { "ok" => true, "devices" => devices }
end

def request_openclash_reload(enabled)
  return false unless enabled
  system("sh", "-c", "(sleep 2; /etc/init.d/openclash restart) >/tmp/openclash-editor-qr-restart.log 2>&1 &")
  true
end

def qr_device_change_response(mac, node_name, reload_openclash)
  _section, device = qr_managed_device(mac)
  lan_ip!(device["ip"])
  backup = apply_qr_rule(device["ip"], node_name.to_s.strip)
  {
    "ok" => true,
    "mac" => device["mac"],
    "ip" => device["ip"],
    "node" => node_name.to_s.strip,
    "backup" => backup,
    "reload_openclash" => request_openclash_reload(reload_openclash)
  }
end

def qr_device_unproxy_response(mac, reload_openclash)
  _section, device = qr_managed_device(mac)
  backup = apply_qr_rule_change(device["ip"])
  {
    "ok" => true,
    "mac" => device["mac"],
    "ip" => device["ip"],
    "backup" => backup,
    "reload_openclash" => request_openclash_reload(reload_openclash)
  }
end

def qr_device_delete_response(mac, reload_openclash)
  section, device = qr_managed_device(mac)
  backup = apply_qr_rule_change(device["ip"])
  begin
    unless system("uci", "-q", "delete", "dhcp.#{section}") && system("uci", "commit", "dhcp")
      system("uci", "revert", "dhcp")
      raise "删除 DHCP 固定租约失败"
    end
    system("/etc/init.d/dnsmasq", "reload") || raise("重新载入 DHCP 服务失败")
  rescue StandardError
    File.binwrite(SOURCE, File.binread(backup))
    raise
  end
  {
    "ok" => true,
    "mac" => device["mac"],
    "ip" => device["ip"],
    "backup" => backup,
    "reload_openclash" => request_openclash_reload(reload_openclash)
  }
end

def qr_devices_delete_response(mac_list, reload_openclash)
  macs = mac_list.to_s.split(",").map { |mac| mac.strip.downcase }.reject(&:empty?).uniq
  raise "请至少选择一台扫码设备" if macs.empty?
  raise "单次最多批量删除 256 台设备" if macs.length > 256

  managed = macs.map do |mac|
    section, device = qr_managed_device(mac)
    [section, device]
  end
  addresses = managed.map { |_section, device| device["ip"] }
  address_set = addresses.to_h { |address| [address, true] }

  config = load_config
  rules = device_rules(config).reject do |rule|
    parts = rule_parts(rule)
    parts && address_set[parts["ip"]]
  end
  lines = File.read(SOURCE).gsub("\r\n", "\n").split("\n", -1)
  replace_device_rules(lines, rules)
  generated = lines.join("\n")
  parsed = YAML.safe_load(generated, aliases: true)
  raise "批量删除生成的配置不是有效 YAML" unless parsed.is_a?(Hash)

  stamp = Time.now.strftime("%Y%m%d-%H%M%S")
  backup = File.join(File.dirname(SOURCE), ".#{File.basename(SOURCE)}.qr-backup-#{stamp}")
  File.binwrite(backup, File.binread(SOURCE))
  mode = File.stat(SOURCE).mode & 0o777
  File.chmod(mode, backup)
  staged = "#{SOURCE}.editor-qr"
  File.write(staged, generated)
  File.chmod(mode, staged)
  File.rename(staged, SOURCE)

  begin
    deleted = managed.all? { |section, _device| system("uci", "-q", "delete", "dhcp.#{section}") }
    unless deleted && system("uci", "commit", "dhcp")
      system("uci", "revert", "dhcp")
      raise "批量删除 DHCP 固定租约失败"
    end
    system("/etc/init.d/dnsmasq", "reload") || raise("重新载入 DHCP 服务失败")
  rescue StandardError
    File.binwrite(SOURCE, File.binread(backup))
    raise
  end

  {
    "ok" => true,
    "deleted_count" => managed.length,
    "deleted_macs" => managed.map { |_section, device| device["mac"] },
    "backup" => backup,
    "reload_openclash" => request_openclash_reload(reload_openclash)
  }
end

def slot_id!(id)
  id = id.to_s.strip
  raise "无效的固定槽位编号" unless id.match?(/\A[0-9a-f]{12}\z/)
  id
end

def slot_token!(token)
  token = token.to_s.strip
  raise "无效的固定槽位二维码" unless token.match?(/\A[0-9a-f]{32}\z/)
  token
end

def slot_by_id!(slots, id)
  id = slot_id!(id)
  slots.find { |slot| slot["id"].to_s == id } || raise("固定槽位不存在或已经删除")
end

def slot_by_token!(slots, token)
  token = slot_token!(token)
  slots.find { |slot| slot["token"].to_s == token } || raise("固定槽位二维码不存在或已经失效")
end

def slot_by_code!(slots, code)
  code = slot_code!(code)
  slots.find { |slot| slot["code"].to_s == code } || raise("没有找到口令 #{code} 对应的槽位")
end

def slot_rebind_status(slot, requester_mac = "", now = Time.now.to_i)
  bound_mac = slot["mac"].to_s.downcase
  requester_mac = requester_mac.to_s.downcase
  rebind_until = slot["rebind_until"].to_i
  bound = !bound_mac.empty?
  same_device = bound && !requester_mac.empty? && requester_mac == bound_mac
  rebind_allowed = bound && rebind_until > now
  {
    "bound" => bound,
    "same_device" => same_device,
    "rebind_allowed" => rebind_allowed,
    "rebind_until" => rebind_allowed ? rebind_until : 0,
    "rebind_remaining" => rebind_allowed ? rebind_until - now : 0,
    "locked" => bound && !rebind_allowed,
    "can_bind" => !bound || same_device || rebind_allowed
  }
end

def config_node_names
  Array(load_config["proxies"]).filter_map do |node|
    node["name"].to_s if node.is_a?(Hash) && !node["name"].to_s.empty?
  end
end

def dhcp_dynamic_range(network)
  raw_start = `uci -q get dhcp.lan.start 2>/dev/null`.strip
  raw_limit = `uci -q get dhcp.lan.limit 2>/dev/null`.strip
  return nil unless raw_limit.match?(/\A\d+\z/) && raw_limit.to_i.positive?
  start_i = if raw_start.include?(".")
              ipv4_to_i(raw_start)
            elsif raw_start.match?(/\A\d+\z/)
              network["network_i"] + raw_start.to_i
            end
  return nil unless start_i && start_i.between?(network["first_i"], network["last_i"])
  [start_i, [start_i + raw_limit.to_i - 1, network["last_i"]].min]
rescue StandardError
  nil
end

def slot_allocatable_ips(count, additional_ips = [])
  lan = detect_lan
  network = cidr_info(lan.fetch("cidr"))
  used = {}
  device_rules(load_config).each do |rule|
    parts = rule_parts(rule)
    used[ipv4_to_i(parts["ip"])] = true if parts
  end
  dhcp_host_sections.each_value do |values|
    begin
      used[ipv4_to_i(values["ip"])] = true unless values["ip"].to_s.empty?
    rescue StandardError
      nil
    end
  end
  active_dhcp_leases.each do |lease|
    begin
      used[ipv4_to_i(lease["ip"])] = true
    rescue StandardError
      nil
    end
  end
  read_slots.each do |slot|
    begin
      used[ipv4_to_i(slot["ip"])] = true
    rescue StandardError
      nil
    end
  end
  Array(additional_ips).each do |address|
    begin
      used[ipv4_to_i(address.to_s.sub(%r{/32\z}, ""))] = true
    rescue StandardError
      nil
    end
  end
  used[ipv4_to_i(lan["gateway"])] = true unless lan["gateway"].to_s.empty?

  saved_start = read_state["start_ip"].to_s
  begin
    start_i = ipv4_to_i(saved_start)
    start_i = network["first_i"] unless start_i.between?(network["first_i"], network["last_i"])
  rescue StandardError
    start_i = ipv4_to_i(default_start_ip(network.merge("gateway" => lan["gateway"])))
  end
  candidates = (start_i..network["last_i"]).to_a + (network["first_i"]...start_i).to_a
  dynamic_range = dhcp_dynamic_range(network)
  if dynamic_range
    outside, inside = candidates.partition { |value| value < dynamic_range[0] || value > dynamic_range[1] }
    candidates = outside + inside
  end
  available = candidates.reject { |value| used[value] }.first(count)
  raise "LAN 网段没有足够的空闲固定 IP，需要 #{count} 个，仅找到 #{available.length} 个" if available.length < count
  available.map { |value| i_to_ipv4(value) }
end

def next_slot_name(node_name, slots)
  prefix = "#{node_name}-槽位"
  numbers = Array(slots).filter_map do |slot|
    match = slot["name"].to_s.match(/\A#{Regexp.escape(prefix)}(\d+)\z/)
    match[1].to_i if match
  end
  "#{prefix}#{numbers.empty? ? 1 : numbers.max + 1}"
end

def build_slots_for_nodes(node_names, slots, additional_ips = [], available_names = nil)
  names = Array(node_names).map { |name| name.to_s.strip }
  raise "请至少选择一个节点" if names.empty?
  raise "单次最多为 256 个节点创建槽位" if names.length > 256
  available = available_names || config_node_names
  missing = names.reject { |name| available.include?(name) }
  raise "目标节点不存在：#{missing.join('、')}" unless missing.empty?
  ips = slot_allocatable_ips(names.length, additional_ips)
  now = Time.now.to_i
  working = slots.map(&:dup)
  names.each_with_index.map do |node_name, index|
    slot = {
      "id" => random_hex(6),
      "token" => random_hex(16),
      "code" => next_slot_code(working),
      "name" => next_slot_name(node_name, working),
      "ip" => ips[index],
      "node" => node_name,
      "mac" => "",
      "device_name" => "",
      "created_at" => now,
      "updated_at" => now,
      "last_bound_at" => 0,
      "rebind_until" => 0
    }
    working << slot
    slot
  end
end

def augment_slots_from_rules(slots, rules, node_names)
  working = Array(slots).select { |slot| slot.is_a?(Hash) }.map(&:dup)
  known_nodes = Array(node_names).map(&:to_s)
  by_ip = {}
  working.each do |slot|
    address = slot["ip"].to_s
    by_ip[address] ||= slot unless address.empty?
  end
  now = Time.now.to_i
  created = []
  updated = 0

  Array(rules).each do |rule|
    parts = rule_parts(rule)
    next unless parts && known_nodes.include?(parts["name"])

    slot = by_ip[parts["ip"]]
    if slot
      next if slot["node"].to_s == parts["name"]

      slot["node"] = parts["name"]
      slot["updated_at"] = now
      updated += 1
      next
    end

    slot = {
      "id" => random_hex(6),
      "token" => random_hex(16),
      "code" => next_slot_code(working),
      "name" => next_slot_name(parts["name"], working),
      "ip" => parts["ip"],
      "node" => parts["name"],
      "mac" => "",
      "device_name" => "",
      "created_at" => now,
      "updated_at" => now,
      "last_bound_at" => 0,
      "rebind_until" => 0
    }
    working << slot
    by_ip[parts["ip"]] = slot
    created << slot
  end

  [working, created, updated]
end

def slots_response
  config = load_config
  node_names = Array(config["proxies"]).filter_map do |node|
    node["name"].to_s if node.is_a?(Hash) && !node["name"].to_s.empty?
  end
  auto_created = []
  auto_updated = 0
  current_slots = with_slot_lock do
    existing = read_slots
    codes_changed = normalize_slot_codes!(existing)
    reconciled, created, updated = augment_slots_from_rules(existing, device_rules(config), node_names)
    write_slots(reconciled) if codes_changed || created.any? || updated.positive?
    auto_created = created
    auto_updated = updated
    reconciled
  end
  rules_by_ip = {}
  device_rules(config).each do |rule|
    parts = rule_parts(rule)
    rules_by_ip[parts["ip"]] = parts["name"] if parts
  end
  leases_by_mac = active_dhcp_leases.to_h { |lease| [lease["mac"], lease] }
  slots = current_slots.map do |slot|
    mac = slot["mac"].to_s.downcase
    lease = leases_by_mac[mac]
    rebind = slot_rebind_status(slot)
    slot.merge(
      "online" => !mac.empty? && !lease.nil?,
      "current_ip" => lease ? lease["ip"].to_s : "",
      "rule_node" => rules_by_ip[slot["ip"].to_s].to_s,
      "rule_ok" => rules_by_ip[slot["ip"].to_s].to_s == slot["node"].to_s,
      "locked" => rebind["locked"],
      "rebind_allowed" => rebind["rebind_allowed"],
      "rebind_until" => rebind["rebind_until"],
      "rebind_remaining" => rebind["rebind_remaining"]
    )
  end
  slots.sort_by! do |slot|
    ipv4_to_i(slot["ip"])
  rescue StandardError
    0xffffffff
  end
  {
    "ok" => true,
    "slots" => slots,
    "auto_created_count" => auto_created.length,
    "auto_updated_count" => auto_updated,
    "lan_cidr" => detect_lan["cidr"],
    "version" => File.exist?(VERSION_FILE) ? File.read(VERSION_FILE).strip : "dev"
  }
end

def slots_create_response(node_name, count_value, prefix_value, start_value)
  with_slot_lock do
    node_name = node_name.to_s.strip
    raise "请输入已有节点的准确名称" if node_name.empty?
    raise "目标节点不存在：#{node_name}" unless config_node_names.include?(node_name)
    count = Integer(count_value)
    start_number = Integer(start_value)
    raise "单次创建数量必须在 1 至 256 之间" unless count.between?(1, 256)
    raise "起始编号必须在 0 至 999999 之间" unless start_number.between?(0, 999_999)
    prefix = prefix_value.to_s.strip
    prefix = "手机槽位" if prefix.empty?
    raise "槽位名称前缀不能包含逗号或换行" if prefix.match?(/[,\r\n]/)
    raise "槽位名称前缀过长" if prefix.bytesize > 120

    slots = read_slots
    existing_names = slots.to_h { |slot| [slot["name"].to_s, true] }
    names = count.times.map { |offset| "#{prefix}#{start_number + offset}" }
    duplicate = names.find { |name| existing_names[name] }
    raise "固定槽位名称已经存在：#{duplicate}" if duplicate
    ips = slot_allocatable_ips(count)
    now = Time.now.to_i
    working = slots.map(&:dup)
    created = []
    names.each_with_index do |name, index|
      slot = {
        "id" => random_hex(6),
        "token" => random_hex(16),
        "code" => next_slot_code(working),
        "name" => name,
        "ip" => ips[index],
        "node" => node_name,
        "mac" => "",
        "device_name" => "",
        "created_at" => now,
        "updated_at" => now,
        "last_bound_at" => 0,
        "rebind_until" => 0
      }
      working << slot
      created << slot
    end
    backup = apply_qr_rule_changes(created.to_h { |slot| [slot["ip"], slot["node"]] })
    begin
      write_slots(slots + created)
    rescue StandardError
      File.binwrite(SOURCE, File.binread(backup))
      raise
    end
    {
      "ok" => true,
      "created" => created,
      "created_count" => created.length,
      "backup" => backup,
      "requires_apply" => true
    }
  end
end

def slots_create_many_response(node_list)
  with_slot_lock do
    names = node_list.to_s.split(",").map(&:strip).reject(&:empty?)
    slots = read_slots
    created = build_slots_for_nodes(names, slots)
    backup = apply_qr_rule_changes(created.to_h { |slot| [slot["ip"], slot["node"]] })
    begin
      write_slots(slots + created)
    rescue StandardError
      File.binwrite(SOURCE, File.binread(backup))
      raise
    end
    {
      "ok" => true,
      "created" => created,
      "created_count" => created.length,
      "backup" => backup,
      "requires_apply" => true
    }
  end
end

def slots_plan_response(request_path)
  request = YAML.safe_load(File.read(request_path), aliases: true) || {}
  names = Array(request["nodes"]).map { |name| name.to_s.strip }
  available_names = Array(request["available_nodes"]).map { |name| name.to_s.strip }
  draft_slots = Array(request["slots"]).select { |slot| slot.is_a?(Hash) }
  used_ips = Array(request["used_ips"])
  created = build_slots_for_nodes(names, draft_slots, used_ips, available_names)
  { "ok" => true, "created" => created, "created_count" => created.length }
end

def slot_info_response(token, remote_address = "")
  slot = slot_by_token!(read_slots, token)
  requester = {}
  requester_error = ""
  unless remote_address.to_s.empty?
    begin
      source_ip = lan_ip!(remote_address)
      requester = lookup_lan_device(source_ip)
      requester["ip"] = source_ip
    rescue StandardError => error
      requester_error = error.message
    end
  end
  rebind = slot_rebind_status(slot, requester["mac"])
  {
    "ok" => true,
    "slot" => {
      "name" => slot["name"].to_s,
      "ip" => slot["ip"].to_s,
      "node" => slot["node"].to_s,
      "mac" => slot["mac"].to_s,
      "device_name" => slot["device_name"].to_s
    },
    "requester_mac" => requester["mac"].to_s,
    "requester_name" => requester["hostname"].to_s,
    "requester_error" => requester_error,
    "same_device" => rebind["same_device"],
    "rebind_allowed" => rebind["rebind_allowed"],
    "rebind_remaining" => rebind["rebind_remaining"],
    "locked" => rebind["locked"],
    "can_bind" => rebind["can_bind"],
    "permanent" => true
  }
end

def slot_update_response(id, node_name)
  with_slot_lock do
    slots = read_slots
    slot = slot_by_id!(slots, id)
    node_name = node_name.to_s.strip
    raise "请输入已有节点的准确名称" if node_name.empty?
    raise "目标节点不存在：#{node_name}" unless config_node_names.include?(node_name)
    return { "ok" => true, "slot" => slot, "unchanged" => true, "requires_apply" => false } if slot["node"].to_s == node_name

    backup = apply_qr_rule_change(slot["ip"], node_name)
    old_node = slot["node"]
    slot["node"] = node_name
    slot["updated_at"] = Time.now.to_i
    begin
      write_slots(slots)
    rescue StandardError
      slot["node"] = old_node
      File.binwrite(SOURCE, File.binread(backup))
      raise
    end
    { "ok" => true, "slot" => slot, "backup" => backup, "requires_apply" => true }
  end
end

def slot_regenerate_response(id)
  with_slot_lock do
    slots = read_slots
    slot = slot_by_id!(slots, id)
    slot["token"] = random_hex(16)
    slot["rebind_until"] = 0
    slot["updated_at"] = Time.now.to_i
    write_slots(slots)
    { "ok" => true, "slot" => slot }
  end
end

def slot_rebind_response(id, enabled)
  with_slot_lock do
    slots = read_slots
    slot = slot_by_id!(slots, id)
    allow = enabled.to_s == "1"
    raise "未绑定设备的槽位不需要开启换绑" if allow && slot["mac"].to_s.empty?
    now = Time.now.to_i
    slot["rebind_until"] = allow ? now + REBIND_WINDOW_SECONDS : 0
    slot["updated_at"] = now
    write_slots(slots)
    status = slot_rebind_status(slot, "", now)
    {
      "ok" => true,
      "slot" => slot,
      "rebind_allowed" => status["rebind_allowed"],
      "rebind_until" => status["rebind_until"],
      "rebind_remaining" => status["rebind_remaining"]
    }
  end
end

def slot_refresh_lease_response(id)
  with_slot_lock do
    slots = read_slots
    slot = slot_by_id!(slots, id)
    mac = slot["mac"].to_s.downcase
    raise "该扫码槽位还没有绑定设备" if mac.empty?
    target_ip = lan_ip!(slot["ip"])
    section = "oce_slot_#{slot['id']}"
    values = dhcp_host_sections[section]
    unless values &&
      values["mac"].to_s.downcase == mac &&
      values["ip"].to_s == target_ip
      raise "该槽位的 DHCP 固定租约缺失或不一致，请让原手机重新扫描该槽位二维码"
    end

    lease_result = activate_slot_dhcp_reservation(mac, target_ip)
    {
      "ok" => true,
      "slot" => slot,
      "mac" => mac,
      "ip" => target_ip,
      "old_ip" => lease_result["old_ip"],
      "lease_removed" => lease_result["lease_removed"],
      "dnsmasq_restarted" => lease_result["dnsmasq_restarted"],
      "reconnect_required" => lease_result["reconnect_required"]
    }
  end
end

def slot_delete_response(id)
  with_slot_lock do
    slots = read_slots
    slot = slot_by_id!(slots, id)
    backup = apply_qr_rule_change(slot["ip"])
    section = "oce_slot_#{slot['id']}"
    begin
      if dhcp_host_sections.key?(section)
        unless system("uci", "-q", "delete", "dhcp.#{section}") && system("uci", "commit", "dhcp")
          system("uci", "revert", "dhcp")
          raise "删除槽位的 DHCP 固定租约失败"
        end
        system("/etc/init.d/dnsmasq", "reload") || raise("重新载入 DHCP 服务失败")
      end
      write_slots(slots.reject { |item| item["id"].to_s == slot["id"].to_s })
    rescue StandardError
      File.binwrite(SOURCE, File.binread(backup))
      raise
    end
    { "ok" => true, "slot" => slot, "backup" => backup, "requires_apply" => true }
  end
end

def slots_delete_response(id_list)
  with_slot_lock do
    ids = id_list.to_s.split(",").map(&:strip).reject(&:empty?).uniq
    raise "请至少选择一个扫码槽位" if ids.empty?
    raise "单次最多批量删除 256 个扫码槽位" if ids.length > 256
    ids.each { |id| slot_id!(id) }
    slots = read_slots
    selected = slots.select { |slot| ids.include?(slot["id"].to_s) }
    raise "没有找到选中的扫码槽位" if selected.empty?
    missing = ids - selected.map { |slot| slot["id"].to_s }
    raise "部分扫码槽位已经不存在：#{missing.join('、')}" unless missing.empty?

    changes = selected.to_h { |slot| [slot["ip"], nil] }
    backup = apply_qr_rule_changes(changes)
    begin
      sections = dhcp_host_sections
      removed_sections = selected.map { |slot| "oce_slot_#{slot['id']}" }.select { |section| sections.key?(section) }
      unless removed_sections.empty?
        removed_sections.each { |section| system("uci", "-q", "delete", "dhcp.#{section}") }
        unless system("uci", "commit", "dhcp")
          system("uci", "revert", "dhcp")
          raise "批量删除扫码槽位的 DHCP 固定租约失败"
        end
        system("/etc/init.d/dnsmasq", "reload") || raise("重新载入 DHCP 服务失败")
      end
      write_slots(slots.reject { |slot| ids.include?(slot["id"].to_s) })
    rescue StandardError
      File.binwrite(SOURCE, File.binread(backup))
      raise
    end
    {
      "ok" => true,
      "deleted_count" => selected.length,
      "deleted_ids" => selected.map { |slot| slot["id"] },
      "backup" => backup,
      "requires_apply" => true
    }
  end
end

def slots_apply_pending_response
  raise "没有待应用的扫码槽位数据，请重新生成预览" unless File.file?(PENDING_SLOTS)
  pending = YAML.safe_load(File.read(PENDING_SLOTS), aliases: true) || {}
  desired = Array(pending["slots"]).select { |slot| slot.is_a?(Hash) }
  with_slot_lock do
    current = read_slots
    desired_ids = desired.to_h { |slot| [slot["id"].to_s, true] }
    removed = current.reject { |slot| desired_ids[slot["id"].to_s] }
    sections = dhcp_host_sections
    removed_sections = removed.map { |slot| "oce_slot_#{slot['id']}" }.select { |section| sections.key?(section) }
    unless removed_sections.empty?
      removed_sections.each { |section| system("uci", "-q", "delete", "dhcp.#{section}") }
      unless system("uci", "commit", "dhcp")
        system("uci", "revert", "dhcp")
        raise "应用配置时删除失效槽位的 DHCP 固定租约失败"
      end
      system("/etc/init.d/dnsmasq", "reload") || raise("重新载入 DHCP 服务失败")
    end
    backup = ""
    if File.file?(SLOT_STATE)
      stamp = Time.now.strftime("%Y%m%d-%H%M%S")
      backup = "#{SLOT_STATE}.backup-#{stamp}"
      File.binwrite(backup, File.binread(SLOT_STATE))
      File.chmod(0o600, backup)
    end
    write_slots(desired)
    File.delete(PENDING_SLOTS)
    {
      "ok" => true,
      "slot_count" => desired.length,
      "removed_count" => removed.length,
      "backup" => backup
    }
  end
end

def safe_dhcp_name(hostname, mac)
  name = hostname.to_s.gsub(/[^A-Za-z0-9_-]/, "")[0, 32]
  name = "device-#{mac.delete(':')[-6, 6]}" if name.empty? || name == "*"
  name
end

def schedule_wifi_reconnect(*macs)
  valid = macs.flatten.map { |mac| mac.to_s.downcase }.select do |mac|
    mac.match?(/\A[0-9a-f]{2}(?::[0-9a-f]{2}){5}\z/)
  end.uniq
  return false if valid.empty?

  calls = valid.map do |mac|
    payload = json_generate({ "addr" => mac, "reason" => 5, "deauth" => true, "ban_time" => 0 })
    "for obj in $(ubus list 'hostapd.*' 2>/dev/null); do ubus call \"$obj\" del_client '#{payload}' >/dev/null 2>&1 || true; done"
  end.join("; ")
  system("sh", "-c", "(sleep 2; #{calls}) >/tmp/openclash-editor-portal-reconnect.log 2>&1 &")
end

def slot_bind_response(identifier, remote_address, force_rebind = false)
  with_slot_lock do
    source_ip = lan_ip!(remote_address)
    device = lookup_lan_device(source_ip)
    mac = device["mac"].to_s.downcase
    slots = read_slots
    slot = force_rebind ? slot_by_code!(slots, identifier) : slot_by_token!(slots, identifier)
    target_ip = lan_ip!(slot["ip"])
    raise "槽位引用的节点已经不存在：#{slot['node']}" unless config_node_names.include?(slot["node"].to_s)
    rebind = slot_rebind_status(slot, mac)
    unless force_rebind || rebind["can_bind"]
      raise "该扫码槽位已绑定其他设备并处于锁定状态，请联系管理员在扫码绑定页面点击“允许换绑”"
    end

    sections = dhcp_host_sections
    target_section = "oce_slot_#{slot['id']}"
    existing_for_mac = sections.find { |_section, values| values["mac"].to_s.downcase == mac }
    conflict_for_ip = sections.find do |section, values|
      values["ip"].to_s == target_ip && section != target_section &&
        !values["mac"].to_s.empty? && values["mac"].to_s.downcase != mac
    end
    raise "槽位固定地址 #{target_ip} 被其他 DHCP 配置占用，请先处理冲突" if conflict_for_ip
    if existing_for_mac && !existing_for_mac[0].start_with?("oce_")
      raise "这台设备已有用户手动创建的 DHCP 固定租约，未自动覆盖"
    end

    rules_by_ip = {}
    device_rules(load_config).each do |rule|
      parts = rule_parts(rule)
      rules_by_ip[parts["ip"]] = parts["name"] if parts
    end
    changes = {}
    changes[target_ip] = slot["node"].to_s if rules_by_ip[target_ip].to_s != slot["node"].to_s
    sections_to_delete = []
    if existing_for_mac && existing_for_mac[0] != target_section
      previous_section, previous_values = existing_for_mac
      sections_to_delete << previous_section
      if previous_section.start_with?("oce_slot_")
        previous_slot = slots.find { |item| "oce_slot_#{item['id']}" == previous_section }
        if previous_slot
          previous_slot["mac"] = ""
          previous_slot["device_name"] = ""
          previous_slot["updated_at"] = Time.now.to_i
          previous_slot["last_bound_at"] = 0
          previous_slot["rebind_until"] = 0
        end
      elsif previous_values["ip"].to_s != target_ip
        changes[previous_values["ip"].to_s] = nil
      end
    end
    sections_to_delete << target_section if sections.key?(target_section)
    sections_to_delete.uniq!

    backup = changes.empty? ? nil : apply_qr_rule_changes(changes)
    lease_result = nil
    begin
      sections_to_delete.each { |section| system("uci", "-q", "delete", "dhcp.#{section}") }
      commands = [
        ["uci", "set", "dhcp.#{target_section}=host"],
        ["uci", "set", "dhcp.#{target_section}.name=#{safe_dhcp_name(device['hostname'], mac)}"],
        ["uci", "set", "dhcp.#{target_section}.mac=#{mac}"],
        ["uci", "set", "dhcp.#{target_section}.ip=#{target_ip}"],
        ["uci", "commit", "dhcp"]
      ]
      unless commands.all? { |command| system(*command) }
        system("uci", "revert", "dhcp")
        raise "写入槽位 DHCP 固定租约失败"
      end
      replacing_device = rebind["bound"] && !rebind["same_device"]
      replaceable_macs = replacing_device ? [slot["mac"]] : []
      lease_result = activate_slot_dhcp_reservation(
        mac,
        target_ip,
        replaceable_macs,
        force_rebind || (replacing_device && rebind["rebind_allowed"])
      )

      slots.each do |item|
        next if item["id"].to_s == slot["id"].to_s
        next unless item["mac"].to_s.downcase == mac
        item["mac"] = ""
        item["device_name"] = ""
        item["updated_at"] = Time.now.to_i
        item["last_bound_at"] = 0
        item["rebind_until"] = 0
      end
      slot["mac"] = mac
      slot["device_name"] = device["hostname"].to_s
      slot["updated_at"] = Time.now.to_i
      slot["last_bound_at"] = Time.now.to_i
      slot["rebind_until"] = 0
      write_slots(slots)
      schedule_wifi_reconnect(slot["mac"], replacing_device ? replaceable_macs : [])
    rescue StandardError
      File.binwrite(SOURCE, File.binread(backup)) if backup
      raise
    end

    {
      "ok" => true,
      "slot" => slot,
      "source_ip" => source_ip,
      "ip" => target_ip,
      "mac" => mac,
      "hostname" => device["hostname"].to_s,
      "backup" => backup.to_s,
      "config_changed" => !backup.nil?,
      "same_device" => rebind["same_device"],
      "replaced_device" => rebind["bound"] && !rebind["same_device"],
      "reload_openclash" => request_openclash_reload(!backup.nil?),
      "old_ip" => lease_result ? lease_result["old_ip"] : source_ip,
      "lease_removed" => lease_result ? lease_result["lease_removed"] : false,
      "dnsmasq_restarted" => lease_result ? lease_result["dnsmasq_restarted"] : false,
      "reconnect_required" => source_ip != target_ip
    }
  end
end

def slot_code_bind_response(code, remote_address)
  slot_bind_response(slot_code!(code), remote_address, true)
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
    "slots" => read_slots,
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
  slot_sections = SKIP_SLOT_DHCP ? [] : dhcp_host_sections.keys.select { |section| section.start_with?("oce_slot_") }
  unless slot_sections.empty?
    slot_sections.each { |section| system("uci", "-q", "delete", "dhcp.#{section}") }
    unless system("uci", "commit", "dhcp")
      system("uci", "revert", "dhcp")
      File.binwrite(SOURCE, File.binread(backup))
      raise "恢复初始配置时删除固定槽位 DHCP 租约失败"
    end
    system("/etc/init.d/dnsmasq", "reload")
  end
  File.delete(SLOT_STATE) if File.exist?(SLOT_STATE)
  File.delete(PENDING_SLOTS) if File.exist?(PENDING_SLOTS)
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

def normalize_preview_slots(requested_slots, node_names, rules)
  raise "扫码槽位数据必须是数组" unless requested_slots.is_a?(Array)
  raise "扫码槽位数量超过上限" if requested_slots.length > 4096
  current_by_id = read_slots.to_h { |slot| [slot["id"].to_s, slot] }
  rules_by_ip = {}
  Array(rules).each do |rule|
    parts = rule_parts(rule)
    rules_by_ip[parts["ip"]] = parts["name"] if parts
  end
  lan = detect_lan
  network = cidr_info(lan["cidr"])
  now = Time.now.to_i
  seen_ids = {}
  seen_tokens = {}
  seen_codes = {}
  seen_names = {}
  seen_ips = {}
  requested_slots.map do |raw|
    raise "扫码槽位数据格式错误" unless raw.is_a?(Hash)
    id = slot_id!(raw["id"])
    existing = current_by_id[id]
    token = existing ? existing["token"].to_s : slot_token!(raw["token"])
    code = slot_code!(existing ? existing["code"] : raw["code"])
    name = raw["name"].to_s.strip
    node_name = raw["node"].to_s.strip
    address = existing ? existing["ip"].to_s : raw["ip"].to_s
    value = ipv4_to_i(address)
    raise "扫码槽位名称不能为空" if name.empty?
    raise "扫码槽位名称不能包含逗号或换行：#{name}" if name.match?(/[,\r\n]/)
    raise "扫码槽位名称过长：#{name}" if name.bytesize > 180
    raise "扫码槽位引用了不存在的节点：#{node_name}" unless node_names.include?(node_name)
    raise "扫码槽位 IP 不在当前 LAN 网段：#{address}" unless value.between?(network["first_i"], network["last_i"])
    raise "扫码槽位不能使用路由器自身地址：#{address}" if address == lan["gateway"]
    raise "扫码槽位缺少对应设备规则：#{address}/32 → #{node_name}" unless rules_by_ip[address].to_s == node_name
    raise "扫码槽位编号重复：#{id}" if seen_ids[id]
    raise "扫码槽位二维码重复" if seen_tokens[token]
    raise "槽位口令重复：#{code}" if seen_codes[code]
    raise "扫码槽位名称重复：#{name}" if seen_names[name]
    raise "扫码槽位 IP 重复：#{address}" if seen_ips[address]
    seen_ids[id] = seen_tokens[token] = seen_codes[code] = seen_names[name] = seen_ips[address] = true
    {
      "id" => id,
      "token" => token,
      "code" => code,
      "name" => name,
      "ip" => address,
      "node" => node_name,
      "mac" => existing ? existing["mac"].to_s : "",
      "device_name" => existing ? existing["device_name"].to_s : "",
      "created_at" => existing ? existing["created_at"].to_i : (raw["created_at"].to_i.positive? ? raw["created_at"].to_i : now),
      "updated_at" => now,
      "last_bound_at" => existing ? existing["last_bound_at"].to_i : 0,
      "rebind_until" => existing ? existing["rebind_until"].to_i : raw["rebind_until"].to_i
    }
  end
end

def preview_response(request_path)
  request = YAML.safe_load(File.read(request_path), aliases: true)
  nodes = request.fetch("nodes")
  rules = request.fetch("rules")
  anchor_names = request.fetch("anchor_names")
  network = cidr_info(request.fetch("network_cidr"))
  start_ip = request.fetch("start_ip").to_s
  manual_network = request["manual_network"] == true
  requested_slots = request.key?("slots") ? request["slots"] : read_slots
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
  requested_slots, auto_created_slots, auto_updated_slots =
    augment_slots_from_rules(requested_slots, rules, names)
  slots = normalize_preview_slots(requested_slots, names, rules)

  current_config = load_config
  diff = change_summary(current_config, nodes, rules, anchor_names)
  current_slots = read_slots
  current_by_id = current_slots.to_h { |slot| [slot["id"].to_s, slot] }
  desired_by_id = slots.to_h { |slot| [slot["id"].to_s, slot] }
  added_slots = desired_by_id.keys - current_by_id.keys
  removed_slots = current_by_id.keys - desired_by_id.keys
  modified_slots = (current_by_id.keys & desired_by_id.keys).count do |id|
    %w[name node ip].any? { |key| current_by_id[id][key].to_s != desired_by_id[id][key].to_s }
  end
  diff = "#{diff}\n扫码槽位：新增 #{added_slots.length}，删除 #{removed_slots.length}，修改 #{modified_slots}"
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
  File.write(PENDING_SLOTS, json_generate({ "slots" => slots }))
  File.chmod(0o600, PENDING_SLOTS)
  {
    "ok" => true,
    "node_count" => nodes.length,
    "rule_count" => rules.length,
    "slot_count" => slots.length,
    "auto_slot_count" => auto_created_slots.length,
    "auto_updated_slot_count" => auto_updated_slots,
    "diff" => diff,
    "source_path" => SOURCE
  }
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
             when "qr-devices" then qr_devices_response
             when "qr-device-change" then qr_device_change_response(ARGV.fetch(1), ARGV.fetch(2), ARGV[3] == "1")
             when "qr-device-unproxy" then qr_device_unproxy_response(ARGV.fetch(1), ARGV[2] == "1")
             when "qr-device-delete" then qr_device_delete_response(ARGV.fetch(1), ARGV[2] == "1")
             when "qr-devices-delete" then qr_devices_delete_response(ARGV.fetch(1), ARGV[2] == "1")
             when "slots" then slots_response
             when "slots-create" then slots_create_response(ARGV.fetch(1), ARGV.fetch(2), ARGV.fetch(3), ARGV.fetch(4))
             when "slots-create-many" then slots_create_many_response(ARGV.fetch(1))
             when "slots-plan" then slots_plan_response(ARGV.fetch(1))
             when "slots-apply-pending" then slots_apply_pending_response
             when "slot-info" then slot_info_response(ARGV.fetch(1), ARGV[2].to_s)
             when "slot-bind" then slot_bind_response(ARGV.fetch(1), ARGV.fetch(2))
             when "slot-code-bind" then slot_code_bind_response(ARGV.fetch(1), ARGV.fetch(2))
             when "slot-update" then slot_update_response(ARGV.fetch(1), ARGV.fetch(2))
             when "slot-regenerate" then slot_regenerate_response(ARGV.fetch(1))
             when "slot-rebind" then slot_rebind_response(ARGV.fetch(1), ARGV.fetch(2))
             when "slot-refresh-lease" then slot_refresh_lease_response(ARGV.fetch(1))
             when "slot-delete" then slot_delete_response(ARGV.fetch(1))
             when "slots-delete" then slots_delete_response(ARGV.fetch(1))
             else raise "未知操作"
             end
    puts json_generate(result)
  rescue StandardError => error
    puts json_generate({ "ok" => false, "error" => error.message, "details" => error.backtrace&.first(5)&.join("\n") })
    exit 1
  end
end
