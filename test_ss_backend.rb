require "json"
require "open3"
require "tmpdir"
require "yaml"

Dir.mktmpdir("openclash-editor-ss") do |dir|
  config = File.join(dir, "config.yaml")
  request = File.join(dir, "request.yaml")
  state = File.join(dir, "state.json")
  test_output = File.join(dir, "preview.yaml")
  node = {
    "name" => "美国8.6",
    "type" => "ss",
    "server" => "gd.mitwo.top",
    "port" => 19_322,
    "cipher" => "aes-256-gcm",
    "password" => "1919",
    "udp" => true
  }
  File.write(config, <<~YAML)
    pr: &pr
      proxies: []
    proxies: []
    rules:
      - MATCH,DIRECT
  YAML
  File.write(request, {
    "nodes" => [node],
    "rules" => [],
    "anchor_names" => [],
    "network_cidr" => "192.168.100.0/24",
    "start_ip" => "192.168.100.2",
    "manual_network" => false,
    "slots" => []
  }.to_yaml)

  env = {
    "OPENCLASH_EDITOR_SOURCE" => config,
    "OPENCLASH_EDITOR_STATE" => state,
    "OPENCLASH_EDITOR_TEST" => test_output,
    "OPENCLASH_EDITOR_PENDING_STATE" => File.join(dir, "pending-state.json"),
    "OPENCLASH_EDITOR_PENDING_SLOTS" => File.join(dir, "pending-slots.json"),
    "OPENCLASH_EDITOR_SLOT_STATE" => File.join(dir, "slots.json")
  }
  stdout, stderr, status = Open3.capture3(env, "ruby", "backend.rb", "preview", request)
  abort stderr unless status.success?
  result = JSON.parse(stdout)
  abort result.inspect unless result["ok"]

  saved = YAML.safe_load(File.read(test_output), aliases: true).fetch("proxies").first
  expected_keys = %w[name type server port password cipher udp]
  abort "SS field order incorrect: #{saved.keys.inspect}" unless saved.keys.first(expected_keys.length) == expected_keys
  abort "SS fields changed" unless node.all? { |key, value| saved[key] == value }
  puts JSON.generate(saved)
end
