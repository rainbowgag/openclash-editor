#!/bin/sh

set -eu

MIRROR_HOST="yy.yaml.uk"
MIRROR_PORT="9443"
MIRROR_IP="${OPENCLASH_EDITOR_RESOLVE_IP:-103.27.78.68}"
MIRROR_ROOT="https://${MIRROR_HOST}:${MIRROR_PORT}/openclash-editor"
TEMPORARY="/tmp/openclash-editor-selected-install.sh"
EDITION="${OPENCLASH_EDITOR_EDITION:-}"

cleanup() {
  rm -f "$TEMPORARY"
}
trap cleanup EXIT INT TERM

if [ "$(id -u)" != "0" ]; then
  echo "错误：请使用 root 用户运行安装命令。" >&2
  exit 1
fi

if [ -z "$EDITION" ]; then
  echo "请选择要安装的 OpenClash Visual Editor 版本："
  echo "  1. 扫码绑定版（手机扫码绑定代理，带扫码设备管理）"
  echo "  2. 手动绑定 IP 版（保留自动规则和手动 IP 管理）"
  printf "请输入 1 或 2："
  if ! read -r EDITION; then
    echo
    echo "错误：没有读到选择。请先下载脚本再执行，不要使用 curl | sh。" >&2
    exit 1
  fi
fi

case "$EDITION" in
  1|qr|scan)
    EDITION="scan"
    LABEL="扫码绑定版"
    BASE_URL="${MIRROR_ROOT}/qr-device-binding-test"
    ;;
  2|manual|ip)
    EDITION="manual"
    LABEL="手动绑定 IP 版"
    BASE_URL="${MIRROR_ROOT}/manual-ip"
    ;;
  *)
    echo "错误：请输入 1 或 2。" >&2
    exit 1
    ;;
esac

echo "正在准备安装：${LABEL}"
if command -v curl >/dev/null 2>&1; then
  curl -fL --resolve "${MIRROR_HOST}:${MIRROR_PORT}:${MIRROR_IP}" \
    --connect-timeout 20 --max-time 120 --retry 2 --show-error --silent \
    "${BASE_URL}/install.sh" -o "$TEMPORARY"
elif command -v wget >/dev/null 2>&1; then
  wget -T 20 -t 2 -O "$TEMPORARY" "${BASE_URL}/install.sh"
elif command -v uclient-fetch >/dev/null 2>&1; then
  uclient-fetch -T 20 -O "$TEMPORARY" "${BASE_URL}/install.sh"
else
  echo "错误：系统缺少 curl、wget 或 uclient-fetch。" >&2
  exit 1
fi

chmod 700 "$TEMPORARY"
OPENCLASH_EDITOR_BASE_URL="$BASE_URL" \
OPENCLASH_EDITOR_RESOLVE_IP="$MIRROR_IP" \
sh "$TEMPORARY"

printf '%s\n' "$EDITION" > /usr/share/openclash-editor/EDITION
chmod 644 /usr/share/openclash-editor/EDITION
echo "已安装：${LABEL}"
