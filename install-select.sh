#!/bin/sh

set -eu

REPO="rainbowgag/openclash-editor"
TEMP_INSTALLER="/tmp/openclash-editor-edition-install.sh"

cleanup() {
  rm -f "$TEMP_INSTALLER"
}
trap cleanup EXIT INT TERM

echo "========================================"
echo " OpenClash 可视化编辑器安装程序"
echo "========================================"
echo "1. 手动绑定 IP 版"
echo "2. 口令绑定版"
echo
printf "请选择要安装的版本 [1/2]: "
read -r EDITION

case "$EDITION" in
  1)
    BRANCH="codex/manual-ip-version"
    EDITION_NAME="手动绑定 IP 版"
    ;;
  2)
    BRANCH="codex/qr-device-binding-test"
    EDITION_NAME="口令绑定版"
    ;;
  *)
    echo "错误：请输入 1 或 2。" >&2
    exit 1
    ;;
esac

BASE_URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}"
INSTALLER_URL="${BASE_URL}/install.sh"

echo
echo "正在下载：${EDITION_NAME}"

if command -v curl >/dev/null 2>&1; then
  curl -fL --connect-timeout 20 --max-time 120 --retry 2 --show-error \
    -o "$TEMP_INSTALLER" "$INSTALLER_URL"
elif command -v wget >/dev/null 2>&1; then
  wget -T 30 -t 2 -O "$TEMP_INSTALLER" "$INSTALLER_URL"
elif command -v uclient-fetch >/dev/null 2>&1; then
  uclient-fetch -T 30 -O "$TEMP_INSTALLER" "$INSTALLER_URL"
else
  echo "错误：系统中未找到 curl、wget 或 uclient-fetch。" >&2
  exit 1
fi

chmod 700 "$TEMP_INSTALLER"
OPENCLASH_EDITOR_BRANCH="$BRANCH" sh "$TEMP_INSTALLER"

echo
echo "${EDITION_NAME}安装完成。"
