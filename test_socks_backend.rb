#!/usr/bin/env ruby

require "yaml"

backend = ARGV.fetch(0, "/usr/share/openclash-editor/backend.rb")
source = "/etc/openclash/config/config.yaml"
request_path = "/tmp/openclash-editor-socks-request.yaml"
state_output = IO.popen(["ruby", backend, "state"], &:read)
state = YAML.safe_load(state_output, aliases: true)
abort state.fetch("error", "state failed") unless state["ok"]

socks = {
  "name" => "SOCKS5 203.0.113.10:1080",
  "type" => "socks5",
  "server" => "203.0.113.10",
  "port" => 1080,
  "username" => "tester",
  "password" => "secret",
  "udp" => true
}
request = {
  "nodes" => state.fetch("nodes").map { |node| node.fetch("data") } + [socks],
  "anchor_names" => state.fetch("nodes").select { |node| node["in_pr"] }.map { |node| node.fetch("name") },
  "rules" => state.fetch("rules"),
  "start_ip" => state.fetch("start_ip"),
  "network_cidr" => state.fetch("network_cidr"),
  "manual_network" => state.fetch("manual_network")
}
File.write(request_path, YAML.dump(request))
formal_before = File.binread(source)
preview_output = IO.popen(["ruby", backend, "preview", request_path], &:read)
preview_result = YAML.safe_load(preview_output, aliases: true)
abort preview_result.fetch("error", "preview failed") unless preview_result["ok"]
abort "SOCKS5 missing from change summary" unless preview_result.fetch("diff", "").include?(socks["name"])
abort "formal config changed" unless File.binread(source) == formal_before

generated = YAML.load_file("/tmp/openclash-editor-preview.yaml", aliases: true)
node = Array(generated["proxies"]).find { |item| item["name"] == socks["name"] }
abort "SOCKS5 node missing" unless node
expected = %w[name type server port username password udp]
abort "SOCKS5 field order incorrect: #{node.keys.inspect}" unless node.keys.first(expected.length) == expected
abort "SOCKS5 fields changed" unless expected.all? { |key| node[key] == socks[key] }
puts "SOCKS_BACKEND_OK #{node.inspect}"
