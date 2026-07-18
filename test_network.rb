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

puts "NETWORK_CALCULATION_OK #{cases.length} cases"
