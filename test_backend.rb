#!/usr/bin/env ruby

require "yaml"

backend = ARGV.fetch(0, "/tmp/openclash-editor-backend.rb")
state_file = "/tmp/openclash-editor-test-state.json"
request_file = "/tmp/openclash-editor-test-request.json"
preview_result = "/tmp/openclash-editor-test-preview-result.json"

abort "state failed" unless system("ruby", backend, "state", out: state_file)
state = YAML.safe_load(File.read(state_file), aliases: true)
abort "architecture missing" if state["architecture"].to_s.empty?
configured_source = `uci -q get openclash.config.config_path 2>/dev/null`.strip
abort "configured source path not detected" unless configured_source.empty? || state["source_path"] == configured_source
request = {
  "nodes" => state.fetch("nodes").map { |node| node.fetch("data") },
  "anchor_names" => state.fetch("nodes").select { |node| node["in_pr"] }.map { |node| node.fetch("name") },
  "rules" => state.fetch("rules"),
  "start_ip" => state.fetch("start_ip"),
  "network_cidr" => state.fetch("network_cidr"),
  "manual_network" => state.fetch("manual_network")
}
if ENV["TEST_NETWORK_CIDR"]
  request["network_cidr"] = ENV.fetch("TEST_NETWORK_CIDR")
  request["start_ip"] = ENV.fetch("TEST_START_IP")
  request["manual_network"] = true
end
File.write(request_file, YAML.dump(request))
abort "preview failed" unless system("ruby", backend, "preview", request_file, out: preview_result)
preview = YAML.safe_load(File.read(preview_result), aliases: true)
abort preview.fetch("error", "preview error") unless preview["ok"]
abort "change summary missing" unless preview["diff"].is_a?(String) && preview["diff"].include?("节点：")
abort "preview source path mismatch" unless preview["source_path"] == state["source_path"]
generated = YAML.load_file("/tmp/openclash-editor-preview.yaml", aliases: true)
generated_nodes = Array(generated["proxies"])
generated_anchor_names = Array(generated.dig("pr", "proxies")).map(&:to_s)
expected_anchor_names = request.fetch("anchor_names")
abort "pr names changed" unless generated_anchor_names == expected_anchor_names
if generated_nodes.first
  expected_prefix = %w[name type server port].select { |key| generated_nodes.first.key?(key) }
  abort "node field order incorrect" unless generated_nodes.first.keys.first(expected_prefix.length) == expected_prefix
end
puts({
  "ok" => true,
  "nodes" => state.fetch("nodes").length,
  "rules" => state.fetch("rules").length,
  "next_ip" => state.fetch("next_ip"),
  "start_ip" => state.fetch("start_ip"),
  "network_cidr" => state.fetch("network_cidr"),
  "detected_lan_cidr" => state.fetch("detected_lan_cidr"),
  "architecture" => state.fetch("architecture"),
  "pr_names" => generated_anchor_names.length,
  "first_keys" => generated_nodes.first&.keys&.first(4),
  "preview_bytes" => File.size("/tmp/openclash-editor-preview.yaml")
}.inspect)
