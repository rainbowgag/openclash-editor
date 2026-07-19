#!/bin/sh

set -eu

REPO="rainbowgag/openclash-editor"
BRANCH="${OPENCLASH_EDITOR_BRANCH:-main}"
BASE_URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}"

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
    OPENCLASH_EDITOR_BRANCH="$BRANCH" sh "$temporary"
    ;;
  *)
    echo "用法：$0 check|update" >&2
    exit 1
    ;;
esac
