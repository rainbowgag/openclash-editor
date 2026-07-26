#!/usr/bin/env ruby

require "yaml"

config_path = "/tmp/openclash-editor-slot-unit.yaml"
slot_state_path = "/tmp/openclash-editor-slot-unit.json"
slot_lock_path = "/tmp/openclash-editor-slot-unit.lock"
ENV["OPENCLASH_CONFIG_PATH"] = config_path
ENV["OPENCLASH_EDITOR_SLOT_STATE"] = slot_state_path
ENV["OPENCLASH_EDITOR_SLOT_LOCK"] = slot_lock_path

File.write(config_path, <<~YAML)
  port: 7890
  pr: &pr
    proxies:
      - test-node
  proxies:
    - {name: test-node, type: socks5, server: 203.0.113.10, port: 1080, udp: true}
    - {name: second-node, type: socks5, server: 203.0.113.11, port: 1080, udp: true}
  rules:
    - MATCH,DIRECT
  proxy-groups:
    - name: select
      type: select
      <<: *pr
YAML
File.delete(slot_state_path) if File.exist?(slot_state_path)
File.delete(slot_lock_path) if File.exist?(slot_lock_path)

require_relative "backend"

created = slots_create_response("test-node", "2", "测试槽位", "1")
abort "slot create count mismatch" unless created["created_count"] == 2
slots = read_slots
abort "slot state count mismatch" unless slots.length == 2
abort "slot token invalid" unless slots.all? { |slot| slot["token"].match?(/\A[0-9a-f]{32}\z/) }
abort "slot IP duplicate" unless slots.map { |slot| slot["ip"] }.uniq.length == 2

config = YAML.load_file(config_path, aliases: true)
slots.each do |slot|
  expected = "SRC-IP-CIDR,#{slot['ip']}/32,test-node"
  abort "slot rule missing: #{expected}" unless Array(config["rules"]).include?(expected)
end

first = slots.first
old_token = first["token"]
updated = slot_update_response(first["id"], "second-node")
abort "slot node update failed" unless updated.dig("slot", "node") == "second-node"
config = YAML.load_file(config_path, aliases: true)
abort "updated slot rule missing" unless Array(config["rules"]).include?("SRC-IP-CIDR,#{first['ip']}/32,second-node")

regenerated = slot_regenerate_response(first["id"])
new_token = regenerated.dig("slot", "token")
abort "slot token was not regenerated" if new_token == old_token
abort "new slot token is invalid" unless new_token.match?(/\A[0-9a-f]{32}\z/)
info = slot_info_response(new_token)
abort "slot info mismatch" unless info.dig("slot", "name") == first["name"]

listed = slots_response
abort "slot list count mismatch" unless listed["slots"].length == 2
deleted = slot_delete_response(first["id"])
abort "slot delete failed" unless deleted["ok"] && read_slots.length == 1
config = YAML.load_file(config_path, aliases: true)
abort "deleted slot rule remained" if Array(config["rules"]).any? { |rule| rule.start_with?("SRC-IP-CIDR,#{first['ip']}/32,") }

unless ENV["KEEP_SLOT_TEST"] == "1"
  Dir.glob("/tmp/.openclash-editor-slot-unit.yaml.qr-backup-*").each { |path| File.delete(path) }
  [config_path, slot_state_path, slot_lock_path].each { |path| File.delete(path) if File.exist?(path) }
end
puts "FIXED_SLOT_CORE_OK"
