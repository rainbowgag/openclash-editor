#!/usr/bin/env ruby

require "yaml"

backend = ARGV.fetch(0, "/tmp/openclash-editor-backend.rb")
source = ENV.fetch("OPENCLASH_CONFIG_PATH", "/etc/openclash/config/config.yaml")
state_file = "/tmp/openclash-editor-trojan-state.json"
request_file = "/tmp/openclash-editor-trojan-request.yaml"
result_file = "/tmp/openclash-editor-trojan-result.json"
environment = { "OPENCLASH_CONFIG_PATH" => source }

abort "state failed" unless system(environment, "ruby", backend, "state", out: state_file)
state = YAML.safe_load(File.read(state_file), aliases: true)
test_name = "OpenClash Editor Trojan Test"
trojan = {
  "name" => test_name,
  "type" => "trojan",
  "server" => "margaret-rose-kensington.junheff.com",
  "port" => 26_310,
  "password" => "019f31dd-d6c9-7009-b759-96e2f7461bb7",
  "udp" => true,
  "network" => "tcp",
  "sni" => "ShermaneRouter",
  "skip-cert-verify" => true
}
trojan_go_name = "OpenClash Editor Trojan-Go Test"
trojan_go = {
  "name" => trojan_go_name,
  "type" => "trojan",
  "server" => "example.com",
  "port" => 443,
  "password" => "secret@word",
  "udp" => true,
  "network" => "ws",
  "sni" => "edge.example.com",
  "ws-opts" => { "path" => "/trojan-go", "headers" => { "Host" => "cdn.example.com" } },
  "ss-opts" => { "enabled" => true, "method" => "aes-256-gcm", "password" => "extra-secret" }
}
test_names = [test_name, trojan_go_name]
nodes = state.fetch("nodes").map { |node| node.fetch("data") }.reject { |node| test_names.include?(node["name"]) }
nodes.concat([trojan, trojan_go])
request = {
  "nodes" => nodes,
  "anchor_names" => (state.fetch("nodes").select { |node| node["in_pr"] }.map { |node| node.fetch("name") } + test_names).uniq,
  "rules" => state.fetch("rules"),
  "start_ip" => state.fetch("start_ip"),
  "network_cidr" => state.fetch("network_cidr"),
  "manual_network" => state.fetch("manual_network")
}
File.write(request_file, YAML.dump(request))
abort "preview failed" unless system(environment, "ruby", backend, "preview", request_file, out: result_file)
result = YAML.safe_load(File.read(result_file), aliases: true)
abort result.fetch("error", "preview error") unless result["ok"]
generated = YAML.load_file("/tmp/openclash-editor-preview.yaml", aliases: true)
saved = Array(generated["proxies"]).find { |node| node["name"] == test_name }
abort "Trojan node missing from preview" unless saved
abort "Trojan fields changed" unless trojan.all? { |key, value| saved[key] == value }
saved_go = Array(generated["proxies"]).find { |node| node["name"] == trojan_go_name }
abort "Trojan-Go node missing from preview" unless saved_go
abort "Trojan-Go fields changed" unless trojan_go.all? { |key, value| saved_go[key] == value }
puts({ "ok" => true, "preview" => "/tmp/openclash-editor-preview.yaml", "nodes" => [saved, saved_go] }.inspect)
