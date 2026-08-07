#!/bin/sh

set -eu

ROOT="${TMPDIR:-/tmp}/openclash-editor-shortcut-test.$$"
WEB_ROOT="$ROOT/www"
HOSTS_FILE="$ROOT/etc/hosts"
BACKUP_DIR="$ROOT/backups"
NGINX_DIR="$ROOT/nginx"

cleanup() {
  rm -rf "$ROOT"
}
trap cleanup EXIT INT TERM

mkdir -p "$WEB_ROOT" "$(dirname "$HOSTS_FILE")" "$NGINX_DIR"
printf '127.0.0.1 localhost\n' > "$HOSTS_FILE"
printf '<!doctype html><title>Original router page</title>\n' > "$WEB_ROOT/index.html"
cp "$WEB_ROOT/index.html" "$ROOT/index.expected"
cp "$HOSTS_FILE" "$ROOT/hosts.expected"

run_portal() {
  OPENCLASH_EDITOR_LAN_IP="$1" \
  OPENCLASH_EDITOR_WEB_ROOT="$WEB_ROOT" \
  OPENCLASH_EDITOR_HOSTS_FILE="$HOSTS_FILE" \
  OPENCLASH_EDITOR_PORTAL_BACKUP_DIR="$BACKUP_DIR" \
  OPENCLASH_EDITOR_NGINX_CONF_DIR="$NGINX_DIR" \
  OPENCLASH_EDITOR_SKIP_DNS_RELOAD=1 \
  OPENCLASH_EDITOR_SKIP_FIREWALL_CLEANUP=1 \
  sh portal-watch.sh "$2"
}

run_portal 192.168.88.1 setup
grep -q '^192\.168\.88\.1 bind\.lan # OPENCLASH_EDITOR_BIND_LAN$' "$HOSTS_FILE"
grep -q 'OPENCLASH_EDITOR_BIND_LAN' "$WEB_ROOT/index.html"
grep -q 'location.replace("/cgi-bin/luci/oec")' "$WEB_ROOT/index.html"
grep -q 'http://192\.168\.88\.1/cgi-bin/luci/oec' "$WEB_ROOT/oec"

run_portal 192.168.88.1 setup
[ "$(grep -c 'OPENCLASH_EDITOR_BIND_LAN' "$HOSTS_FILE")" -eq 1 ]
[ "$(grep -c 'OPENCLASH_EDITOR_BIND_LAN' "$WEB_ROOT/index.html")" -eq 1 ]

run_portal 10.0.0.1 setup
grep -q '^10\.0\.0\.1 bind\.lan # OPENCLASH_EDITOR_BIND_LAN$' "$HOSTS_FILE"
! grep -q '192\.168\.88\.1 bind\.lan' "$HOSTS_FILE"
grep -q 'http://10\.0\.0\.1/cgi-bin/luci/oec' "$WEB_ROOT/oec"

run_portal 10.0.0.1 cleanup
cmp -s "$ROOT/index.expected" "$WEB_ROOT/index.html"
cmp -s "$ROOT/hosts.expected" "$HOSTS_FILE"
[ ! -e "$WEB_ROOT/oec" ]

echo "portal shortcut tests passed"
