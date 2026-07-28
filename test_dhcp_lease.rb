#!/usr/bin/env ruby

require "yaml"

config_path = "/tmp/openclash-editor-dhcp-lease-unit.yaml"
lease_path = "/tmp/openclash-editor-dhcp-lease-unit.leases"
ENV["OPENCLASH_CONFIG_PATH"] = config_path
ENV["OPENCLASH_EDITOR_DHCP_LEASE_FILE"] = lease_path

File.write(config_path, <<~YAML)
  port: 7890
  proxies: []
  rules:
    - MATCH,DIRECT
YAML

require_relative "backend"

File.write(lease_path, <<~LEASES)
  2000000000 dc:ad:69:bc:b4:81 192.168.100.147 phone 01:dc:ad:69:bc:b4:81
  2000000001 02:11:22:33:44:55 192.168.100.88 laptop *
LEASES

leases = active_dhcp_leases
abort "lease parser did not use configured lease file" unless leases.length == 2
abort "lease parser lost client id" unless leases.first["client_id"] == "01:dc:ad:69:bc:b4:81"

removed = purge_dhcp_lease("DC:AD:69:BC:B4:81", "192.168.100.147")
abort "target lease was not removed" unless removed == 1
remaining = File.read(lease_path)
abort "target MAC remained in lease file" if remaining.downcase.include?("dc:ad:69:bc:b4:81")
abort "unrelated lease was deleted" unless remaining.include?("02:11:22:33:44:55")

unchanged = File.binread(lease_path)
abort "nonmatching lease unexpectedly removed" unless purge_dhcp_lease("02:11:22:33:44:55", "192.168.100.99").zero?
abort "nonmatching purge changed file" unless File.binread(lease_path) == unchanged

def detect_lan
  cidr_info("192.168.100.0/24").merge(
    "gateway" => "192.168.100.1",
    "detected" => true,
    "source" => "unit-test"
  )
end

$dnsmasq_commands = []
def system(*arguments)
  $dnsmasq_commands << arguments
  true
end

File.write(lease_path, <<~LEASES)
  2000000000 dc:ad:69:bc:b4:81 192.168.100.147 phone *
  2000000001 02:11:22:33:44:55 192.168.100.88 laptop *
LEASES
activation = activate_slot_dhcp_reservation("dc:ad:69:bc:b4:81", "192.168.100.2")
abort "old lease release was not reported" unless activation["lease_removed"]
abort "old IP was not reported" unless activation["old_ip"] == "192.168.100.147"
abort "dnsmasq stop/start sequence is incorrect" unless $dnsmasq_commands == [
  ["/etc/init.d/dnsmasq", "stop"],
  ["/etc/init.d/dnsmasq", "start"]
]
remaining = File.read(lease_path)
abort "activation retained the target device old lease" if remaining.downcase.include?("dc:ad:69:bc:b4:81")
abort "activation removed an unrelated lease" unless remaining.include?("02:11:22:33:44:55")

File.delete(config_path) if File.exist?(config_path)
File.delete(lease_path) if File.exist?(lease_path)

puts "DHCP_LEASE_RELEASE_OK"
