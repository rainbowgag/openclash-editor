#!/bin/sh

set -eu

if [ "$(id -u)" != "0" ]; then
  echo "错误：请使用 root 用户运行卸载命令。" >&2
  exit 1
fi

rm -f /usr/share/openclash-editor/backend.rb
rm -f /usr/lib/lua/luci/controller/openclash_editor.lua
rm -f /usr/lib/lua/luci/view/openclash_editor/index.htm
rm -f /www/luci-static/resources/openclash-editor/converter.js
rm -f /tmp/luci-indexcache 2>/dev/null || true
rm -f /tmp/luci-modulecache/* 2>/dev/null || true

echo "OpenClash Visual Editor 已卸载。"
echo "配置文件、编辑器状态和自动备份均已保留。"
