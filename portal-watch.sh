#!/bin/sh

SLOT_STATE="${OPENCLASH_EDITOR_SLOT_STATE:-/etc/openclash/openclash-editor-slots.json}"
NFT_TABLE="${OPENCLASH_EDITOR_PORTAL_NFT_TABLE:-openclash_editor_portal}"
POLL_SECONDS="${OPENCLASH_EDITOR_PORTAL_POLL_SECONDS:-3}"
PROBE_MARKER="OPENCLASH_EDITOR_PORTAL"
BACKUP_DIR="/usr/share/openclash-editor/portal-backups"
NGINX_LOCATIONS="/etc/nginx/conf.d/openclash-editor-portal.locations"
PROBE_PATHS="hotspot-detect.html library/test/success.html generate_204 gen_204 connecttest.txt redirect canonical.html success.txt ncsi.txt"

detect_lan_ip() {
  address="$(uci -q get network.lan.ipaddr 2>/dev/null || true)"
  address="${address%%/*}"
  case "$address" in
    ''|*[!0-9.]*) address="" ;;
  esac
  [ -n "$address" ] || address="$(ip -4 addr show br-lan 2>/dev/null | awk '/inet / { sub(/\/.*/, "", $2); print $2; exit }')"
  printf '%s\n' "$address"
}

backup_probe() {
  path="$1"
  relative="${path#/www/}"
  backup="$BACKUP_DIR/$relative"
  [ ! -f "$path" ] || grep -q "$PROBE_MARKER" "$path" 2>/dev/null || {
    mkdir -p "$(dirname "$backup")"
    [ -e "$backup" ] || cp -p "$path" "$backup"
  }
}

write_probe_files() {
  lan_ip="$(detect_lan_ip)"
  [ -n "$lan_ip" ] || return 1
  mkdir -p "$BACKUP_DIR"
  for relative in $PROBE_PATHS; do
    path="/www/$relative"
    backup_probe "$path"
    mkdir -p "$(dirname "$path")"
    cat > "$path" <<EOF
<!doctype html><!-- $PROBE_MARKER --><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="refresh" content="0;url=http://$lan_ip/cgi-bin/luci/oec"><title>设备绑定</title></head><body><p>正在打开设备绑定页面……</p><p><a href="http://$lan_ip/cgi-bin/luci/oec">如果没有自动跳转，请点这里</a></p><script>location.replace('http://$lan_ip/cgi-bin/luci/oec');</script></body></html>
EOF
    chmod 644 "$path"
  done

  if [ -d /etc/nginx/conf.d ] && [ -x /etc/init.d/nginx ]; then
    cat > "$NGINX_LOCATIONS" <<EOF
# $PROBE_MARKER
location = /hotspot-detect.html { return 302 http://$lan_ip/cgi-bin/luci/oec; }
location = /library/test/success.html { return 302 http://$lan_ip/cgi-bin/luci/oec; }
location = /generate_204 { return 302 http://$lan_ip/cgi-bin/luci/oec; }
location = /gen_204 { return 302 http://$lan_ip/cgi-bin/luci/oec; }
location = /connecttest.txt { return 302 http://$lan_ip/cgi-bin/luci/oec; }
location = /redirect { return 302 http://$lan_ip/cgi-bin/luci/oec; }
location = /canonical.html { return 302 http://$lan_ip/cgi-bin/luci/oec; }
location = /success.txt { return 302 http://$lan_ip/cgi-bin/luci/oec; }
location = /ncsi.txt { return 302 http://$lan_ip/cgi-bin/luci/oec; }
EOF
    if nginx -t -c /etc/nginx/uci.conf >/dev/null 2>&1; then
      /etc/init.d/nginx reload >/dev/null 2>&1 || true
    else
      rm -f "$NGINX_LOCATIONS"
    fi
  fi
}

restore_probe_files() {
  rm -f "$NGINX_LOCATIONS"
  for relative in $PROBE_PATHS; do
    path="/www/$relative"
    backup="$BACKUP_DIR/$relative"
    if [ -f "$backup" ]; then
      mkdir -p "$(dirname "$path")"
      mv "$backup" "$path"
    elif [ -f "$path" ] && grep -q "$PROBE_MARKER" "$path" 2>/dev/null; then
      rm -f "$path"
    fi
  done
  rm -rf "$BACKUP_DIR"
  [ ! -x /etc/init.d/nginx ] || /etc/init.d/nginx reload >/dev/null 2>&1 || true
}

ensure_nft_table() {
  nft list table inet "$NFT_TABLE" >/dev/null 2>&1 && return 0
  nft -f - >/dev/null 2>&1 <<EOF
table inet $NFT_TABLE {
  set pending_macs { type ether_addr; }
  chain redirect_http {
    type nat hook prerouting priority dstnat - 1; policy accept;
    ether saddr @pending_macs tcp dport 80 redirect to :80
  }
}
EOF
}

refresh_nft_set() {
  ensure_nft_table || return 1
  temporary="/tmp/openclash-editor-portal-nft.$$"
  printf 'flush set inet %s pending_macs\n' "$NFT_TABLE" > "$temporary"
  for mac in $1; do
    printf 'add element inet %s pending_macs { %s }\n' "$NFT_TABLE" "$mac" >> "$temporary"
  done
  nft -f "$temporary" >/dev/null 2>&1
  status=$?
  rm -f "$temporary"
  return $status
}

refresh_iptables_chain() {
  command -v iptables >/dev/null 2>&1 || return 1
  iptables -t nat -N OCE_PORTAL >/dev/null 2>&1 || true
  iptables -t nat -C PREROUTING -j OCE_PORTAL >/dev/null 2>&1 || iptables -t nat -I PREROUTING 1 -j OCE_PORTAL
  iptables -t nat -F OCE_PORTAL
  for mac in $1; do
    iptables -t nat -A OCE_PORTAL -m mac --mac-source "$mac" -p tcp --dport 80 -j REDIRECT --to-ports 80
  done
  if command -v ip6tables >/dev/null 2>&1; then
    ip6tables -t nat -N OCE_PORTAL >/dev/null 2>&1 || true
    ip6tables -t nat -C PREROUTING -j OCE_PORTAL >/dev/null 2>&1 || ip6tables -t nat -I PREROUTING 1 -j OCE_PORTAL
    ip6tables -t nat -F OCE_PORTAL
    for mac in $1; do
      ip6tables -t nat -A OCE_PORTAL -m mac --mac-source "$mac" -p tcp --dport 80 -j REDIRECT --to-ports 80
    done
  fi
}

collect_pending_macs() {
  bound=" "
  if [ -s "$SLOT_STATE" ] && command -v jsonfilter >/dev/null 2>&1; then
    for mac in $(jsonfilter -s "$(cat "$SLOT_STATE")" -e '@.slots[*].mac' 2>/dev/null | tr 'A-F' 'a-f'); do
      case "$mac" in
        [0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]) bound="$bound$mac " ;;
      esac
    done
  fi

  candidates=""
  lease_file="${OPENCLASH_EDITOR_DHCP_LEASE_FILE:-}"
  [ -n "$lease_file" ] || lease_file="$(uci -q get dhcp.@dnsmasq[0].leasefile 2>/dev/null || true)"
  [ -n "$lease_file" ] || lease_file="/tmp/dhcp.leases"
  [ ! -f "$lease_file" ] || candidates="$candidates $(awk '{print tolower($2)}' "$lease_file")"
  if command -v iw >/dev/null 2>&1; then
    for interface in $(iw dev 2>/dev/null | awk '$1 == "Interface" {print $2}'); do
      candidates="$candidates $(iw dev "$interface" station dump 2>/dev/null | awk '$1 == "Station" {print tolower($2)}')"
    done
  fi

  pending=""
  seen=" "
  for mac in $candidates; do
    case "$mac" in
      [0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]) ;;
      *) continue ;;
    esac
    case "$bound" in *" $mac "*) continue ;; esac
    case "$seen" in *" $mac "*) continue ;; esac
    pending="$pending $mac"
    seen="$seen$mac "
  done
  printf '%s\n' "$pending"
}

cleanup_firewall() {
  command -v nft >/dev/null 2>&1 && nft delete table inet "$NFT_TABLE" >/dev/null 2>&1 || true
  if command -v iptables >/dev/null 2>&1; then
    while iptables -t nat -C PREROUTING -j OCE_PORTAL >/dev/null 2>&1; do iptables -t nat -D PREROUTING -j OCE_PORTAL; done
    iptables -t nat -F OCE_PORTAL >/dev/null 2>&1 || true
    iptables -t nat -X OCE_PORTAL >/dev/null 2>&1 || true
  fi
  if command -v ip6tables >/dev/null 2>&1; then
    while ip6tables -t nat -C PREROUTING -j OCE_PORTAL >/dev/null 2>&1; do ip6tables -t nat -D PREROUTING -j OCE_PORTAL; done
    ip6tables -t nat -F OCE_PORTAL >/dev/null 2>&1 || true
    ip6tables -t nat -X OCE_PORTAL >/dev/null 2>&1 || true
  fi
}

run_loop() {
  write_probe_files || true
  trap 'cleanup_firewall; exit 0' INT TERM EXIT
  while true; do
    pending="$(collect_pending_macs)"
    if command -v nft >/dev/null 2>&1; then
      refresh_nft_set "$pending" || true
    else
      refresh_iptables_chain "$pending" || true
    fi
    sleep "$POLL_SECONDS"
  done
}

case "${1:-run}" in
  setup) write_probe_files ;;
  cleanup) cleanup_firewall; restore_probe_files ;;
  run) run_loop ;;
  *) echo "usage: $0 setup|run|cleanup" >&2; exit 1 ;;
esac
