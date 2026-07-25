#!/usr/bin/env ruby

require "yaml"

config_path = "/tmp/openclash-editor-qr-unit.yaml"
ENV["OPENCLASH_CONFIG_PATH"] = config_path
File.write(config_path, <<~YAML)
  port: 7890
  pr: &pr
    proxies:
      - test-node
  proxies:
    - {name: test-node, type: socks5, server: 203.0.113.10, port: 1080, udp: true}
  rules:
    - RULE-SET,private_ip,DIRECT,no-resolve
    - MATCH,DIRECT
  proxy-groups:
    - name: select
      type: select
      <<: *pr
YAML

require_relative "backend"

created = qr_create_response("test-node", false)
abort "token not created" unless created["ok"] && created["token"].match?(/\A[0-9a-f]{48}\z/)
info = qr_info_response(created["token"])
abort "token node mismatch" unless info["node"] == "test-node"

backup = apply_qr_rule("192.168.100.88", "test-node")
generated = YAML.load_file(config_path, aliases: true)
expected = "SRC-IP-CIDR,192.168.100.88/32,test-node"
abort "QR rule missing" unless Array(generated["rules"]).include?(expected)
abort "base rule was lost" unless Array(generated["rules"]).include?("MATCH,DIRECT")
abort "QR backup missing" unless File.file?(backup)

File.delete(qr_token_path(created["token"])) if File.file?(qr_token_path(created["token"]))
File.delete(backup) if File.file?(backup)
File.delete(config_path) if File.file?(config_path)
puts "QR_BINDING_CORE_OK"
