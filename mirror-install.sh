#!/bin/sh

set -eu

MIRROR_BASE="${OPENCLASH_EDITOR_MIRROR_URL:-https://yy.yaml.uk:9443/openclash-editor/main}"
MIRROR_BASE="${MIRROR_BASE%/}"
TEMPORARY="/tmp/openclash-editor-mirror-install.sh"

cleanup() {
  rm -f "$TEMPORARY"
}
trap cleanup EXIT INT TERM

if command -v curl >/dev/null 2>&1; then
  curl -fL --connect-timeout 20 --max-time 120 --retry 2 --show-error --silent "$MIRROR_BASE/install.sh" -o "$TEMPORARY"
elif command -v wget >/dev/null 2>&1; then
  wget -T 20 -t 2 -O "$TEMPORARY" "$MIRROR_BASE/install.sh"
elif command -v uclient-fetch >/dev/null 2>&1; then
  uclient-fetch -T 20 -O "$TEMPORARY" "$MIRROR_BASE/install.sh"
else
  echo "错误：系统缺少 uclient-fetch、wget 或 curl。" >&2
  exit 1
fi

chmod 700 "$TEMPORARY"
OPENCLASH_EDITOR_BASE_URL="$MIRROR_BASE" sh "$TEMPORARY"
