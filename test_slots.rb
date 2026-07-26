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

group = slots_create_many_response("test-node,second-node")
abort "group slot create count mismatch" unless group["created_count"] == 2
slots = read_slots
abort "group slot state count mismatch" unless slots.length == 4
abort "group slot naming failed" unless group["created"].map { |slot| slot["name"] }.sort == ["second-node-槽位1", "test-node-槽位1"].sort

plan_request = "/tmp/openclash-editor-slot-plan-unit.json"
current_rules = device_rules(load_config)
File.write(plan_request, json_generate({
  "nodes" => ["test-node", "second-node"],
  "available_nodes" => ["test-node", "second-node"],
  "slots" => slots,
  "used_ips" => current_rules.map { |rule| rule_parts(rule)["ip"] }
}))
planned = slots_plan_response(plan_request)
abort "slot plan count mismatch" unless planned["created_count"] == 2
abort "repeated group naming failed" unless planned["created"].map { |slot| slot["name"] }.sort == ["second-node-槽位2", "test-node-槽位2"].sort
planned_rules = current_rules + planned["created"].map { |slot| "SRC-IP-CIDR,#{slot['ip']}/32,#{slot['node']}" }
preview_request_path = "/tmp/openclash-editor-slot-preview-unit.json"
File.write(preview_request_path, json_generate({
  "nodes" => load_config["proxies"],
  "anchor_names" => ["test-node"],
  "rules" => planned_rules,
  "slots" => slots + planned["created"],
  "start_ip" => detect_lan["first_host"],
  "network_cidr" => detect_lan["cidr"],
  "manual_network" => false
}))
preview = preview_response(preview_request_path)
abort "slot preview failed" unless preview["slot_count"] == 6 && preview["diff"].include?("扫码槽位：新增 2")
File.binwrite(config_path, File.binread(TEST))
applied = slots_apply_pending_response
abort "pending slots apply failed" unless applied["slot_count"] == 6 && read_slots.length == 6

bulk_deleted = slots_delete_response(planned["created"].map { |slot| slot["id"] }.join(","))
abort "bulk slot delete failed" unless bulk_deleted["deleted_count"] == 2 && read_slots.length == 4

deleted = slot_delete_response(first["id"])
abort "slot delete failed" unless deleted["ok"] && read_slots.length == 3
config = YAML.load_file(config_path, aliases: true)
abort "deleted slot rule remained" if Array(config["rules"]).any? { |rule| rule.start_with?("SRC-IP-CIDR,#{first['ip']}/32,") }

unless ENV["KEEP_SLOT_TEST"] == "1"
  Dir.glob("/tmp/.openclash-editor-slot-unit.yaml.qr-backup-*").each { |path| File.delete(path) }
  [config_path, slot_state_path, slot_lock_path, plan_request, preview_request_path, PENDING_SLOTS].each { |path| File.delete(path) if File.exist?(path) }
end
puts "FIXED_SLOT_CORE_OK"
