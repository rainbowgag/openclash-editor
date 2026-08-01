#!/bin/sh

set -eu

if [ "$(id -u)" != "0" ]; then
  echo "错误：请使用 root 用户运行卸载命令。" >&2
  exit 1
fi

if [ -x /etc/init.d/openclash-editor-portal ]; then
  /etc/init.d/openclash-editor-portal disable >/dev/null 2>&1 || true
  /etc/init.d/openclash-editor-portal stop >/dev/null 2>&1 || true
fi

rm -f /usr/share/openclash-editor/backend.rb
rm -f /usr/share/openclash-editor/VERSION
rm -f /usr/share/openclash-editor/SOURCE_URL
rm -f /usr/share/openclash-editor/EDITION
rm -f /usr/share/openclash-editor/RESOLVE_IP
rm -f /usr/share/openclash-editor/update.sh
rm -f /usr/share/openclash-editor/portal-watch.sh
rm -f /etc/init.d/openclash-editor-portal
rm -f /etc/hotplug.d/iface/99-openclash-editor-portal
rm -f /usr/lib/lua/luci/controller/openclash_editor.lua
rm -f /usr/lib/lua/luci/view/openclash_editor/index.htm
rm -f /usr/lib/lua/luci/view/openclash_editor/nodes.htm
rm -f /usr/lib/lua/luci/view/openclash_editor/rules.htm
rm -f /usr/lib/lua/luci/view/openclash_editor/slots.htm
rm -f /www/luci-static/resources/openclash-editor/converter.js
rm -f /www/luci-static/resources/openclash-editor/editor-common.js
rm -f /www/luci-static/resources/openclash-editor/editor.css
rm -f /tmp/luci-indexcache 2>/dev/null || true
rm -f /tmp/luci-modulecache/* 2>/dev/null || true

echo "OpenClash Visual Editor 已卸载。"
echo "配置文件、编辑器状态和自动备份均已保留。"
