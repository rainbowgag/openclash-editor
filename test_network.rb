#!/usr/bin/env ruby

require_relative "backend"

cases = {
  "192.168.88.1/24" => ["192.168.88.0/24", "192.168.88.1", "192.168.88.254"],
  "192.168.99.1/24" => ["192.168.99.0/24", "192.168.99.1", "192.168.99.254"],
  "10.0.0.1/24" => ["10.0.0.0/24", "10.0.0.1", "10.0.0.254"],
  "10.0.1.1/23" => ["10.0.0.0/23", "10.0.0.1", "10.0.1.254"]
}

cases.each do |input, expected|
  info = cidr_info(input)
  actual = [info["cidr"], info["first_host"], info["last_host"]]
  abort "#{input}: expected #{expected.inspect}, got #{actual.inspect}" unless actual == expected
end

network = cidr_info("192.168.101.1/24").merge("gateway" => "192.168.101.1")
rules = [
  "SRC-IP-CIDR,192.168.101.2/32,node-1",
  "SRC-IP-CIDR,192.168.101.4/32,node-2"
]
abort "allocation should choose first gap" unless first_available_ip(rules, network, "192.168.101.2") == "192.168.101.3"
rules.delete_at(0)
abort "deleted address should be reused" unless first_available_ip(rules, network, "192.168.101.2") == "192.168.101.2"

puts "NETWORK_CALCULATION_OK #{cases.length} subnets, rule IP recycling OK"
