#!/usr/bin/env ruby

require "yaml"
ENV["OPENCLASH_EDITOR_SLOT_STATE"] = "/tmp/openclash-editor-reset-slots.json"
ENV["OPENCLASH_EDITOR_SLOT_LOCK"] = "/tmp/openclash-editor-reset-slots.lock"
ENV["OPENCLASH_EDITOR_SKIP_SLOT_DHCP"] = "1"
require_relative "backend"

original = SOURCE
original_contents = File.binread(original)
test_source = "/tmp/openclash-editor-reset-source.yaml"
test_state = "/tmp/openclash-editor-reset-state.yaml"
File.write(test_source, <<~YAML)
  port: 7890
  pr: &pr
    proxies:
      - test-node
  proxies:
    - {name: test-node, type: socks5, server: 203.0.113.10, port: 1080, udp: true}
  rules:
    - SRC-IP-CIDR,192.168.1.2/32,test-node
    - RULE-SET,private_ip,DIRECT,no-resolve
    - MATCH,DIRECT
  proxy-groups:
    - name: select
      type: select
      <<: *pr
YAML
File.write(test_state, "---\nstart_ip: 192.168.1.2\n")
Object.send(:remove_const, :SOURCE)
Object.const_set(:SOURCE, test_source)
Object.send(:remove_const, :STATE)
Object.const_set(:STATE, test_state)

result = reset_response
abort "reset failed" unless result["ok"]
config = YAML.load_file(test_source, aliases: true)
abort "nodes not cleared" unless Array(config["proxies"]).empty?
abort "anchor names not cleared" unless Array(config.dig("pr", "proxies")).empty?
abort "device rules not cleared" if Array(config["rules"]).any? { |rule| rule.to_s.start_with?("SRC-IP-CIDR,") && !rule.to_s.include?(",DIRECT") }
abort "direct rule missing after reset" unless Array(config["rules"]).include?("SRC-IP-CIDR,#{direct_slot_ip},DIRECT")
abort "base rules were removed" unless Array(config["rules"]).any? { |rule| rule.to_s.start_with?("RULE-SET,") }
abort "state not cleared" if File.exist?(test_state)
abort "formal config was modified" unless File.binread(original) == original_contents
reset_slots = YAML.safe_load(File.read(ENV["OPENCLASH_EDITOR_SLOT_STATE"]), aliases: true).fetch("slots")
abort "direct slot missing after reset" unless reset_slots.any? { |slot| slot["id"] == DIRECT_SLOT_ID && slot["code"] == "000" && slot["node"] == "DIRECT" && slot["mac"].to_s.empty? }

File.delete(test_source) if File.exist?(test_source)
File.delete(result["backup"]) if File.exist?(result["backup"])
File.delete(ENV["OPENCLASH_EDITOR_SLOT_STATE"]) if File.exist?(ENV["OPENCLASH_EDITOR_SLOT_STATE"])
File.delete(ENV["OPENCLASH_EDITOR_SLOT_LOCK"]) if File.exist?(ENV["OPENCLASH_EDITOR_SLOT_LOCK"])
puts "RESET_COPY_OK"
