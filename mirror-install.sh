#!/bin/sh

set -eu

MIRROR_BASE="${OPENCLASH_EDITOR_MIRROR_URL:-https://yy.yaml.uk:9443/openclash-editor/main}"
MIRROR_BASE="${MIRROR_BASE%/}"
TEMPORARY="/tmp/openclash-editor-mirror-install.sh"

cleanup() {
  rm -f "$TEMPORARY"
}
trap cleanup EXIT INT TERM

if command -v uclient-fetch >/dev/null 2>&1; then
  uclient-fetch -q -O "$TEMPORARY" "$MIRROR_BASE/install.sh"
elif command -v wget >/dev/null 2>&1; then
  wget -q -O "$TEMPORARY" "$MIRROR_BASE/install.sh"
elif command -v curl >/dev/null 2>&1; then
  curl -fsSL "$MIRROR_BASE/install.sh" -o "$TEMPORARY"
else
  echo "错误：系统缺少 uclient-fetch、wget 或 curl。" >&2
  exit 1
fi

chmod 700 "$TEMPORARY"
OPENCLASH_EDITOR_BASE_URL="$MIRROR_BASE" sh "$TEMPORARY"
