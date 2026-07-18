#!/usr/bin/env ruby

require "yaml"

SOURCE = "/etc/openclash/config/config.yaml"
TEST = "/tmp/openclash-editor-preview.yaml"
PENDING_STATE = "/tmp/openclash-editor-preview-state.json"
STATE = "/etc/openclash/openclash-editor-state.json"

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
    name type server port uuid password alterId cipher udp network flow tls
    servername sni client-fingerprint alpn reality-opts ws-opts grpc-opts
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

def next_ip_for(rules, network, saved_state)
  used = rules.filter_map do |rule|
    parts = rule_parts(rule)
    next unless parts
    value = ipv4_to_i(parts["ip"])
    value if value.between?(network["first_i"], network["last_i"])
  end
  start = network["first_i"]
  gateway_i = ipv4_to_i(network["gateway"]) unless network["gateway"].to_s.empty?
  start += 1 if gateway_i == start
  candidates = [start, (used.max || start - 1) + 1]
  if saved_state["network_cidr"].to_s == network["cidr"] && !saved_state["next_ip"].to_s.empty?
    begin
      saved_ip = ipv4_to_i(saved_state["next_ip"])
      candidates << saved_ip if saved_ip.between?(network["first_i"], network["last_i"] + 1)
    rescue StandardError
      nil
    end
  end
  candidate = candidates.max
  candidate += 1 if gateway_i == candidate
  candidate <= network["last_i"] ? i_to_ipv4(candidate) : ""
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
    "next_ip" => next_ip_for(rules, active_network, saved_state),
    "network_cidr" => active_network["cidr"],
    "first_host" => active_network["first_host"],
    "last_host" => active_network["last_host"],
    "manual_network" => manual_network,
    "detected_lan_cidr" => detected_lan["cidr"],
    "gateway_ip" => detected_lan["gateway"],
    "detection_source" => detected_lan["source"],
    "detection_error" => detected_lan["error"],
    "source_path" => SOURCE
  }
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
  next_ip = request.fetch("next_ip").to_s
  manual_network = request["manual_network"] == true
  unless next_ip.empty?
    next_ip_i = ipv4_to_i(next_ip)
    raise "下一地址不在规则网段内：#{next_ip}" unless next_ip_i.between?(network["first_i"], network["last_i"])
  end
  raise "节点数据必须是数组" unless nodes.is_a?(Array)
  raise "规则数据必须是数组" unless rules.is_a?(Array)
  raise "pr 节点名称必须是数组" unless anchor_names.is_a?(Array)
  raise "节点数量超过上限" if nodes.length > 512
  raise "规则数量超过上限" if rules.length > 4096

  names = nodes.map do |node|
    raise "节点数据格式错误" unless node.is_a?(Hash)
    name = node["name"].to_s.strip
    raise "节点名称不能为空" if name.empty?
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

  lines = File.read(SOURCE).gsub("\r\n", "\n").split("\n", -1)
  replace_anchor_names(lines, anchor_names)
  replace_nodes(lines, nodes)
  replace_device_rules(lines, rules.map(&:to_s))
  generated = lines.join("\n")
  parsed = YAML.safe_load(generated, aliases: true)
  raise "生成后的配置不是 YAML 映射" unless parsed.is_a?(Hash)
  File.write(TEST, generated)
  File.write(PENDING_STATE, json_generate({
    "next_ip" => next_ip,
    "network_cidr" => network["cidr"],
    "manual_network" => manual_network
  }))
  { "ok" => true, "node_count" => nodes.length, "rule_count" => rules.length }
end

if __FILE__ == $PROGRAM_NAME
  begin
    result = case ARGV[0]
             when "state" then state_response
             when "preview" then preview_response(ARGV.fetch(1))
             else raise "未知操作"
             end
    puts json_generate(result)
  rescue StandardError => error
    puts json_generate({ "ok" => false, "error" => error.message, "details" => error.backtrace&.first(5)&.join("\n") })
    exit 1
  end
end
