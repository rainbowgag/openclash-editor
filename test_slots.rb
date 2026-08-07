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
abort "slot codes were not assigned sequentially" unless slots.map { |slot| slot["code"] } == %w[001 002]
abort "slot code lookup failed" unless slot_by_code!(slots, "1")["id"] == slots.first["id"]
abort "slot IP duplicate" unless slots.map { |slot| slot["ip"] }.uniq.length == 2

legacy_slots = slots.map { |slot| slot.reject { |key, _value| key == "code" } }
File.write(slot_state_path, json_generate({ "slots" => legacy_slots }))
migrated_codes = read_slots.map { |slot| slot["code"] }
abort "legacy slots did not receive stable codes" unless migrated_codes == %w[001 002]
persisted_codes = YAML.safe_load(File.read(slot_state_path), aliases: true).fetch("slots").map { |slot| slot["code"] }
abort "migrated slot codes were not persisted" unless persisted_codes == %w[001 002]
slots = read_slots

config = YAML.load_file(config_path, aliases: true)
slots.each do |slot|
  expected = "SRC-IP-CIDR,#{slot['ip']}/32,test-node"
  abort "slot rule missing: #{expected}" unless Array(config["rules"]).include?(expected)
end

missing_rule_slot = slots.last
missing_rule = "- SRC-IP-CIDR,#{missing_rule_slot['ip']}/32,#{missing_rule_slot['node']}"
File.write(config_path, File.readlines(config_path).reject { |line| line.strip == missing_rule }.join)
broken_slot = slots_response["slots"].find { |slot| slot["id"] == missing_rule_slot["id"] }
abort "missing slot rule was not detected" if broken_slot["rule_ok"]
repaired = slots_repair_response
abort "missing slot rule was not repaired" unless repaired["repaired_count"] == 1
repaired_slot = slots_response["slots"].find { |slot| slot["id"] == missing_rule_slot["id"] }
abort "repaired slot rule still reports a mismatch" unless repaired_slot["rule_ok"]

first = slots.first
old_token = first["token"]
bound_probe = first.merge("mac" => "02:11:22:33:44:55", "rebind_until" => 0)
different_device = slot_rebind_status(bound_probe, "02:aa:bb:cc:dd:ee", 1_000)
abort "bound slot did not lock a different device" unless different_device["locked"] && !different_device["can_bind"]
same_device = slot_rebind_status(bound_probe, "02:11:22:33:44:55", 1_000)
abort "bound slot blocked the same device" unless same_device["same_device"] && same_device["can_bind"]
first["mac"] = "02:11:22:33:44:55"
first["device_name"] = "locked-phone"
write_slots(slots)
allowed = slot_rebind_response(first["id"], "1")
abort "rebind authorization was not opened" unless allowed["rebind_allowed"] && allowed["rebind_remaining"].between?(590, 600)
authorized_slot = read_slots.find { |slot| slot["id"] == first["id"] }
authorized_status = slot_rebind_status(authorized_slot, "02:aa:bb:cc:dd:ee")
abort "authorized replacement device was blocked" unless authorized_status["can_bind"]
cancelled = slot_rebind_response(first["id"], "0")
abort "rebind authorization was not cancelled" if cancelled["rebind_allowed"]
expired_status = slot_rebind_status(bound_probe.merge("rebind_until" => 999), "02:aa:bb:cc:dd:ee", 1_000)
abort "expired rebind authorization remained usable" if expired_status["can_bind"]
slot_rebind_response(first["id"], "1")

updated = slot_update_response(first["id"], "second-node")
abort "slot node update failed" unless updated.dig("slot", "node") == "second-node"
config = YAML.load_file(config_path, aliases: true)
abort "updated slot rule missing" unless Array(config["rules"]).include?("SRC-IP-CIDR,#{first['ip']}/32,second-node")

code_updated = slot_code_update_response(first["id"], "h377")
abort "slot code update failed" unless code_updated.dig("slot", "code") == "H377"
abort "updated slot code was not persisted" unless slot_by_code!(read_slots, "h377")["id"] == first["id"]
begin
  slot_code_update_response(first["id"], "002")
  abort "duplicate slot code was accepted"
rescue StandardError => error
  abort "duplicate slot code returned wrong error" unless error.message.include?("已被其他槽位使用")
end

regenerated = slot_regenerate_response(first["id"])
new_token = regenerated.dig("slot", "token")
abort "slot token was not regenerated" if new_token == old_token
abort "new slot token is invalid" unless new_token.match?(/\A[0-9a-f]{32}\z/)
abort "QR reset did not close rebind authorization" unless regenerated.dig("slot", "rebind_until").to_i.zero?
info = slot_info_response(new_token)
abort "slot info mismatch" unless info.dig("slot", "name") == first["name"]

listed = slots_response
abort "slot list count mismatch" unless listed["slots"].length == 2

group = slots_create_many_response("test-node,second-node")
abort "group slot create count mismatch" unless group["created_count"] == 2
slots = read_slots
abort "group slot state count mismatch" unless slots.length == 4
abort "group slot naming failed" unless group["created"].map { |slot| slot["name"] }.sort == ["second-node-槽位1", "test-node-槽位1"].sort
abort "group slot codes were not continued" unless group["created"].map { |slot| slot["code"] } == %w[003 004]

import_plan_request = "/tmp/openclash-editor-slot-code-import-unit.json"
File.write(import_plan_request, json_generate({
  "slot_requests" => [
    { "node" => "test-node", "code" => "h60" },
    { "node" => "test-node", "code" => "760" },
    { "node" => "second-node", "code" => "H75" }
  ],
  "available_nodes" => ["test-node", "second-node"],
  "slots" => slots,
  "used_ips" => device_rules(load_config).map { |rule| rule_parts(rule)["ip"] }
}))
import_planned = slots_plan_response(import_plan_request)
abort "custom code import count mismatch" unless import_planned["created_count"] == 3
abort "custom codes changed" unless import_planned["created"].map { |slot| slot["code"] } == %w[H60 760 H75]
abort "repeated node slot naming failed" unless import_planned["created"].map { |slot| slot["name"] } == ["test-node-槽位2", "test-node-槽位3", "second-node-槽位2"]
[["002", "002"], ["h377", "H377"]].each do |raw_code, expected_code|
  File.write(import_plan_request, json_generate({
    "slot_requests" => [{ "node" => "test-node", "code" => raw_code }],
    "available_nodes" => ["test-node", "second-node"],
    "slots" => slots,
    "used_ips" => []
  }))
  begin
    slots_plan_response(import_plan_request)
    abort "existing custom code collision was not rejected"
  rescue StandardError => error
    raise unless error.message.include?("槽位口令已存在：#{expected_code}")
  end
end

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

historical_ip = slot_allocatable_ips(1).first
apply_qr_rule(historical_ip, "second-node")
before_migration = read_slots.length
migrated = slots_response
abort "historical rule slot was not auto-created" unless migrated["auto_created_count"] == 1
abort "historical rule migration count mismatch" unless migrated["slots"].length == before_migration + 1
historical_slot = migrated["slots"].find { |slot| slot["ip"] == historical_ip }
abort "historical rule slot target mismatch" unless historical_slot && historical_slot["node"] == "second-node"

preview_autofill_path = "/tmp/openclash-editor-slot-preview-autofill-unit.json"
formal_config = load_config
File.write(preview_autofill_path, json_generate({
  "nodes" => formal_config["proxies"],
  "anchor_names" => ["test-node"],
  "rules" => device_rules(formal_config),
  "slots" => read_slots.reject { |slot| slot["id"] == historical_slot["id"] },
  "start_ip" => detect_lan["first_host"],
  "network_cidr" => detect_lan["cidr"],
  "manual_network" => false
}))
autofilled_preview = preview_response(preview_autofill_path)
abort "preview did not auto-create missing rule slot" unless autofilled_preview["auto_slot_count"] == 1
abort "preview rule and slot counts diverged" unless autofilled_preview["slot_count"] == autofilled_preview["rule_count"]

unless ENV["KEEP_SLOT_TEST"] == "1"
  Dir.glob("/tmp/.openclash-editor-slot-unit.yaml.qr-backup-*").each { |path| File.delete(path) }
  [config_path, slot_state_path, slot_lock_path, plan_request, preview_request_path, preview_autofill_path, PENDING_SLOTS].each { |path| File.delete(path) if File.exist?(path) }
end
puts "FIXED_SLOT_CORE_OK"
