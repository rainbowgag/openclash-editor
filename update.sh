#!/bin/sh

set -eu

REPO="rainbowgag/openclash-editor"
BRANCH="${OPENCLASH_EDITOR_BRANCH:-main}"
DEFAULT_BASE_URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}"
SOURCE_URL_FILE="/usr/share/openclash-editor/SOURCE_URL"
if [ -n "${OPENCLASH_EDITOR_BASE_URL:-}" ]; then
  BASE_URL="$OPENCLASH_EDITOR_BASE_URL"
elif [ -s "$SOURCE_URL_FILE" ]; then
  BASE_URL="$(sed -n '1p' "$SOURCE_URL_FILE")"
else
  BASE_URL="$DEFAULT_BASE_URL"
fi
BASE_URL="${BASE_URL%/}"

fetch_stdout() {
  if command -v uclient-fetch >/dev/null 2>&1; then
    uclient-fetch -q -O - "$1"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- "$1"
  elif command -v curl >/dev/null 2>&1; then
    curl -fsSL "$1"
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
    OPENCLASH_EDITOR_BRANCH="$BRANCH" OPENCLASH_EDITOR_BASE_URL="$BASE_URL" sh "$temporary"
    ;;
  *)
    echo "用法：$0 check|update" >&2
    exit 1
    ;;
esac
