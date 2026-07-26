#!/bin/sh

set -eu

REPO="rainbowgag/openclash-editor"
BRANCH="${OPENCLASH_EDITOR_BRANCH:-main}"
DEFAULT_BASE_URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}"
BASE_URL="${OPENCLASH_EDITOR_BASE_URL:-$DEFAULT_BASE_URL}"
BASE_URL="${BASE_URL%/}"
RESOLVE_IP_FILE="/usr/share/openclash-editor/RESOLVE_IP"
RESOLVE_IP="${OPENCLASH_EDITOR_RESOLVE_IP:-}"
[ -n "$RESOLVE_IP" ] || [ ! -s "$RESOLVE_IP_FILE" ] || RESOLVE_IP="$(sed -n '1p' "$RESOLVE_IP_FILE")"
ARCHITECTURE="$(uname -m 2>/dev/null || echo unknown)"
CONFIG_PATH="$(uci -q get openclash.config.config_path 2>/dev/null || true)"
[ -n "$CONFIG_PATH" ] || CONFIG_PATH="/etc/openclash/config/config.yaml"

if [ "$(id -u)" != "0" ]; then
  echo "错误：请使用 root 用户运行安装命令。" >&2
  exit 1
fi

if [ ! -x /usr/bin/ruby ] || ! ruby -ryaml -e 'exit 0' >/dev/null 2>&1; then
  echo "错误：缺少 Ruby YAML 支持，请先安装 ruby、ruby-yaml 和 ruby-psych。" >&2
  exit 1
fi

if [ ! -f "$CONFIG_PATH" ]; then
  echo "错误：未找到 OpenClash 当前配置：$CONFIG_PATH，请先安装并配置 OpenClash。" >&2
  exit 1
fi

if [ ! -d /usr/lib/lua/luci/controller ] || [ ! -d /usr/lib/lua/luci/view ]; then
  echo "错误：当前系统没有兼容的 LuCI Lua 环境。" >&2
  exit 1
fi

if [ ! -f /www/luci-static/resources/uqr.js ]; then
  echo "错误：当前 LuCI 缺少本地二维码组件，请先执行：opkg update && opkg install libluci-uqr" >&2
  exit 1
fi

fetch_file() {
  url="$1"
  destination="$2"
  temporary="${destination}.download"
  mkdir -p "$(dirname "$destination")"

  if command -v curl >/dev/null 2>&1; then
    if [ -n "$RESOLVE_IP" ]; then
      curl -fL --connect-timeout 20 --max-time 120 --retry 2 --show-error --silent \
        --resolve "yy.yaml.uk:9443:${RESOLVE_IP}" "$url" -o "$temporary"
    else
      curl -fL --connect-timeout 20 --max-time 120 --retry 2 --show-error --silent "$url" -o "$temporary"
    fi
  elif command -v wget >/dev/null 2>&1; then
    wget -T 20 -t 2 -O "$temporary" "$url"
  elif command -v uclient-fetch >/dev/null 2>&1; then
    uclient-fetch -T 20 -O "$temporary" "$url"
  else
    echo "错误：系统缺少 uclient-fetch、wget 或 curl。" >&2
    exit 1
  fi

  mv "$temporary" "$destination"
}

echo "正在安装 OpenClash Visual Editor（系统架构：${ARCHITECTURE}）..."
echo "OpenClash 当前配置：${CONFIG_PATH}"

fetch_file "$BASE_URL/backend.rb" "/usr/share/openclash-editor/backend.rb"
fetch_file "$BASE_URL/VERSION" "/usr/share/openclash-editor/VERSION"
fetch_file "$BASE_URL/update.sh" "/usr/share/openclash-editor/update.sh"
fetch_file "$BASE_URL/luci/controller/openclash_editor.lua" "/usr/lib/lua/luci/controller/openclash_editor.lua"
fetch_file "$BASE_URL/luci/view/openclash_editor/nodes.htm" "/usr/lib/lua/luci/view/openclash_editor/nodes.htm"
fetch_file "$BASE_URL/luci/view/openclash_editor/rules.htm" "/usr/lib/lua/luci/view/openclash_editor/rules.htm"
fetch_file "$BASE_URL/luci/view/openclash_editor/qr.htm" "/usr/lib/lua/luci/view/openclash_editor/qr.htm"
fetch_file "$BASE_URL/luci/view/openclash_editor/slots.htm" "/usr/lib/lua/luci/view/openclash_editor/slots.htm"
fetch_file "$BASE_URL/www/converter.js" "/www/luci-static/resources/openclash-editor/converter.js"
fetch_file "$BASE_URL/www/editor-common.js" "/www/luci-static/resources/openclash-editor/editor-common.js"
fetch_file "$BASE_URL/www/editor.css" "/www/luci-static/resources/openclash-editor/editor.css"
printf '%s\n' "$BASE_URL" > /usr/share/openclash-editor/SOURCE_URL
printf '%s\n' "scan" > /usr/share/openclash-editor/EDITION
if [ -n "$RESOLVE_IP" ]; then
  printf '%s\n' "$RESOLVE_IP" > "$RESOLVE_IP_FILE"
else
  rm -f "$RESOLVE_IP_FILE"
fi

chmod 755 /usr/share/openclash-editor/backend.rb
chmod 755 /usr/share/openclash-editor/update.sh
chmod 644 /usr/share/openclash-editor/VERSION
chmod 644 /usr/share/openclash-editor/SOURCE_URL
chmod 644 /usr/share/openclash-editor/EDITION
[ ! -f "$RESOLVE_IP_FILE" ] || chmod 600 "$RESOLVE_IP_FILE"
chmod 644 /usr/lib/lua/luci/controller/openclash_editor.lua
chmod 644 /usr/lib/lua/luci/view/openclash_editor/nodes.htm
chmod 644 /usr/lib/lua/luci/view/openclash_editor/rules.htm
chmod 644 /usr/lib/lua/luci/view/openclash_editor/qr.htm
chmod 644 /usr/lib/lua/luci/view/openclash_editor/slots.htm
chmod 644 /www/luci-static/resources/openclash-editor/converter.js
chmod 644 /www/luci-static/resources/openclash-editor/editor-common.js
chmod 644 /www/luci-static/resources/openclash-editor/editor.css

rm -f /usr/lib/lua/luci/view/openclash_editor/index.htm

ruby -c /usr/share/openclash-editor/backend.rb >/dev/null
lua /usr/lib/lua/luci/controller/openclash_editor.lua >/dev/null

rm -f /tmp/luci-indexcache 2>/dev/null || true
rm -f /tmp/luci-modulecache/* 2>/dev/null || true

echo "安装成功！"
echo "请刷新 LuCI，然后进入：服务 -> OpenClash -> Visual Editor"
echo "页面地址：http://路由器IP/cgi-bin/luci/admin/services/openclash/visual-editor"
