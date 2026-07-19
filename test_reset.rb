#!/usr/bin/env ruby

require "yaml"
require_relative "backend"

original = "/etc/openclash/config/config.yaml"
test_source = "/tmp/openclash-editor-reset-source.yaml"
test_state = "/tmp/openclash-editor-reset-state.yaml"
File.binwrite(test_source, File.binread(original))
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
abort "device rules not cleared" if Array(config["rules"]).any? { |rule| rule.to_s.start_with?("SRC-IP-CIDR,") }
abort "base rules were removed" unless Array(config["rules"]).any? { |rule| rule.to_s.start_with?("RULE-SET,") }
abort "state not cleared" if File.exist?(test_state)
abort "formal config was modified" unless File.binread(original) != File.binread(test_source)

File.delete(test_source) if File.exist?(test_source)
File.delete(result["backup"]) if File.exist?(result["backup"])
puts "RESET_COPY_OK"
