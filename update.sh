#!/bin/sh

set -eu

REPO="rainbowgag/openclash-editor"
BRANCH="${OPENCLASH_EDITOR_BRANCH:-main}"
DEFAULT_BASE_URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}"
SOURCE_URL_FILE="/usr/share/openclash-editor/SOURCE_URL"
RESOLVE_IP_FILE="/usr/share/openclash-editor/RESOLVE_IP"
RESOLVE_IP="${OPENCLASH_EDITOR_RESOLVE_IP:-}"
[ -n "$RESOLVE_IP" ] || [ ! -s "$RESOLVE_IP_FILE" ] || RESOLVE_IP="$(sed -n '1p' "$RESOLVE_IP_FILE")"
if [ -n "${OPENCLASH_EDITOR_BASE_URL:-}" ]; then
  BASE_URL="$OPENCLASH_EDITOR_BASE_URL"
elif [ -s "$SOURCE_URL_FILE" ]; then
  BASE_URL="$(sed -n '1p' "$SOURCE_URL_FILE")"
else
  BASE_URL="$DEFAULT_BASE_URL"
fi
BASE_URL="${BASE_URL%/}"

fetch_stdout() {
  if command -v curl >/dev/null 2>&1; then
    if [ -n "$RESOLVE_IP" ]; then
      curl -fL --connect-timeout 20 --max-time 120 --retry 2 --show-error --silent \
        --resolve "yy.yaml.uk:9443:${RESOLVE_IP}" "$1"
    else
      curl -fL --connect-timeout 20 --max-time 120 --retry 2 --show-error --silent "$1"
    fi
  elif command -v wget >/dev/null 2>&1; then
    wget -T 20 -t 2 -O - "$1"
  elif command -v uclient-fetch >/dev/null 2>&1; then
    uclient-fetch -T 20 -O - "$1"
  else
    echo "缺少下载工具" >&2
    exit 1
  fi
}

case "${1:-check}" in
  check)
    fetch_stdout "$BASE_URL/VERSION" | tr -d '\r\n '
    ;;
  update)
    temporary="/tmp/openclash-editor-install.sh"
    fetch_stdout "$BASE_URL/install.sh" > "$temporary"
    chmod 700 "$temporary"
    OPENCLASH_EDITOR_BRANCH="$BRANCH" OPENCLASH_EDITOR_BASE_URL="$BASE_URL" \
      OPENCLASH_EDITOR_RESOLVE_IP="$RESOLVE_IP" sh "$temporary"
    ;;
  *)
    echo "用法：$0 check|update" >&2
    exit 1
    ;;
esac
