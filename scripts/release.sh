#!/bin/sh
# OpenClash Visual Editor — 检查与发布脚本
#
# 用法（任意目录执行，自动定位到仓库根）：
#   sh scripts/release.sh check                # 语法检查 + 前端单测
#   sh scripts/release.sh pack [输出目录]       # 打包发布 tar.gz（默认 ./dist）
#   sh scripts/release.sh all  [输出目录]       # check + pack
#
# 环境变量：
#   CHANNEL=test|scan|manual-ip   发布通道，默认 test（决定文件名中的通道段）
#   RELEASE_VERSION=<版本号>      覆盖 VERSION 文件（一般不使用）

set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"

VERSION="$(sed -n '1p' VERSION | tr -d '\r\n[:space:]')"
[ -n "${RELEASE_VERSION:-}" ] && VERSION="$RELEASE_VERSION"
CHANNEL="${CHANNEL:-test}"

# 发布文件清单（与 deploy_stage/<version> 的发布集一致；测试/开发文件不随包发布）
RELEASE_FILES="
backend.rb
install.sh
mirror-install.sh
uninstall.sh
update.sh
portal-watch.sh
openclash-editor-portal.init
openclash-editor-portal.hotplug
VERSION
README.md
LICENSE
luci
www
"

do_check() {
  echo "== check: openclash-editor $VERSION =="
  failed=0

  if command -v ruby >/dev/null 2>&1; then
    if ruby -c backend.rb >/dev/null 2>&1; then
      echo "  backend.rb          OK (ruby -c)"
    else
      echo "  backend.rb          FAIL (ruby -c)"
      failed=1
    fi
  else
    echo "  backend.rb          跳过（未安装 ruby）"
  fi

  if command -v node >/dev/null 2>&1; then
    for file in www/*.js; do
      if node --check "$file" >/dev/null 2>&1; then
        echo "  $file    OK (node --check)"
      else
        echo "  $file    FAIL (node --check)"
        failed=1
      fi
    done
    if node test_converter.js >/dev/null 2>&1; then
      echo "  test_converter.js    OK (前端转换器单测)"
    else
      echo "  test_converter.js    FAIL (前端转换器单测)"
      failed=1
    fi
  else
    echo "  www/*.js / 单测      跳过（未安装 node）"
  fi

  if command -v luac >/dev/null 2>&1; then
    if luac -p luci/controller/openclash_editor.lua >/dev/null 2>&1; then
      echo "  控制器 Lua           OK (luac -p)"
    else
      echo "  控制器 Lua           FAIL (luac -p)"
      failed=1
    fi
  else
    echo "  控制器 Lua           跳过（未安装 luac）"
  fi

  if [ "$failed" -ne 0 ]; then
    echo "== check 失败 ==" >&2
    exit 1
  fi
  echo "== check 通过 =="
}

do_pack() {
  dest="${1:-dist}"
  mkdir -p "$dest"

  number=1
  while [ -e "$dest/openclash-editor-$VERSION-$CHANNEL.$number.tar.gz" ]; do
    number=$((number + 1))
  done
  out="$dest/openclash-editor-$VERSION-$CHANNEL.$number.tar.gz"

  stage="$(mktemp -d)"
  trap 'rm -rf "$stage"' EXIT INT TERM
  for entry in $RELEASE_FILES; do
    if [ -e "$entry" ]; then
      cp -R "$entry" "$stage/"
    else
      echo "缺少发布文件：$entry" >&2
      exit 1
    fi
  done
  tar --force-local -C "$stage" -czf "$out" .
  rm -rf "$stage"
  trap - EXIT INT TERM
  echo "已打包：$out"
}

case "${1:-}" in
  check) do_check ;;
  pack) do_pack "${2:-dist}" ;;
  all) do_check; do_pack "${2:-dist}" ;;
  *)
    echo "用法：sh scripts/release.sh check|pack|all [输出目录]" >&2
    exit 1
    ;;
esac
