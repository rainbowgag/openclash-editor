#!/bin/sh

set -eu

REPO="rainbowgag/openclash-editor"
BRANCH="${OPENCLASH_EDITOR_BRANCH:-main}"
BASE_URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}"

if [ "$(id -u)" != "0" ]; then
  echo "错误：请使用 root 用户运行安装命令。" >&2
  exit 1
fi

if [ ! -x /usr/bin/ruby ] || ! ruby -ryaml -e 'exit 0' >/dev/null 2>&1; then
  echo "错误：缺少 Ruby YAML 支持，请先安装 ruby、ruby-yaml 和 ruby-psych。" >&2
  exit 1
fi

if [ ! -f /etc/openclash/config/config.yaml ]; then
  echo "错误：未找到 /etc/openclash/config/config.yaml，请先安装并配置 OpenClash。" >&2
  exit 1
fi

if [ ! -d /usr/lib/lua/luci/controller ] || [ ! -d /usr/lib/lua/luci/view ]; then
  echo "错误：当前系统没有兼容的 LuCI Lua 环境。" >&2
  exit 1
fi

fetch_file() {
  url="$1"
  destination="$2"
  temporary="${destination}.download"
  mkdir -p "$(dirname "$destination")"

  if command -v uclient-fetch >/dev/null 2>&1; then
    uclient-fetch -q -O "$temporary" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$temporary" "$url"
  elif command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$temporary"
  else
    echo "错误：系统缺少 uclient-fetch、wget 或 curl。" >&2
    exit 1
  fi

  mv "$temporary" "$destination"
}

echo "正在安装 OpenClash Visual Editor..."

fetch_file "$BASE_URL/backend.rb" "/usr/share/openclash-editor/backend.rb"
fetch_file "$BASE_URL/luci/controller/openclash_editor.lua" "/usr/lib/lua/luci/controller/openclash_editor.lua"
fetch_file "$BASE_URL/luci/view/openclash_editor/index.htm" "/usr/lib/lua/luci/view/openclash_editor/index.htm"
fetch_file "$BASE_URL/www/converter.js" "/www/luci-static/resources/openclash-editor/converter.js"

chmod 755 /usr/share/openclash-editor/backend.rb
chmod 644 /usr/lib/lua/luci/controller/openclash_editor.lua
chmod 644 /usr/lib/lua/luci/view/openclash_editor/index.htm
chmod 644 /www/luci-static/resources/openclash-editor/converter.js

ruby -c /usr/share/openclash-editor/backend.rb >/dev/null
lua /usr/lib/lua/luci/controller/openclash_editor.lua >/dev/null

rm -f /tmp/luci-indexcache 2>/dev/null || true
rm -f /tmp/luci-modulecache/* 2>/dev/null || true

echo "安装成功！"
echo "请刷新 LuCI，然后进入：服务 -> OpenClash -> Visual Editor"
echo "页面地址：http://路由器IP/cgi-bin/luci/admin/services/openclash/visual-editor"
