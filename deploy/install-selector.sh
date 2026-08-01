#!/bin/sh

set -eu

MIRROR_HOST="yy.yaml.uk"
MIRROR_PORT="9443"
MIRROR_IP="${OPENCLASH_EDITOR_RESOLVE_IP:-103.27.78.68}"
HTTPS_ROOT="https://${MIRROR_HOST}:${MIRROR_PORT}/openclash-editor"
HTTP_ROOT="http://${MIRROR_IP}/openclash-editor"
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
  echo "  1. 扫码绑定版（永久槽位二维码，刷机后重新扫码换绑）"
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
    CHANNEL="scan"
    ;;
  2|manual|ip)
    EDITION="manual"
    LABEL="手动绑定 IP 版"
    CHANNEL="manual-ip"
    ;;
  *)
    echo "错误：请输入 1 或 2。" >&2
    exit 1
    ;;
esac

fetch_candidate() {
  candidate="$1"
  port="$2"
  rm -f "$TEMPORARY"

  case "$DOWNLOADER" in
    curl)
      curl -fL --resolve "${MIRROR_HOST}:${port}:${MIRROR_IP}" \
      --connect-timeout 20 --max-time 120 --retry 2 --show-error --silent \
      "${candidate}/install.sh" -o "$TEMPORARY"
      ;;
    wget)
      wget -T 20 -t 2 -O "$TEMPORARY" "${candidate}/install.sh"
      ;;
    uclient-fetch)
      uclient-fetch -T 20 -O "$TEMPORARY" "${candidate}/install.sh"
      ;;
  esac
}

if command -v curl >/dev/null 2>&1; then
  DOWNLOADER="curl"
elif command -v wget >/dev/null 2>&1; then
  DOWNLOADER="wget"
elif command -v uclient-fetch >/dev/null 2>&1; then
  DOWNLOADER="uclient-fetch"
else
  echo "错误：系统缺少 curl、wget 或 uclient-fetch。" >&2
  exit 1
fi

echo "正在准备安装：${LABEL}"
if fetch_candidate "${HTTPS_ROOT}/${CHANNEL}" "$MIRROR_PORT"; then
  BASE_URL="${HTTPS_ROOT}/${CHANNEL}"
  echo "下载通道：HTTPS"
elif fetch_candidate "${HTTP_ROOT}/${CHANNEL}" "80"; then
  BASE_URL="${HTTP_ROOT}/${CHANNEL}"
  echo "提示：HTTPS 连接失败，已自动使用 HTTP 兼容通道。" >&2
else
  echo "错误：HTTPS 和 HTTP 下载通道均不可用，请检查路由器联网状态。" >&2
  exit 1
fi

chmod 700 "$TEMPORARY"
OPENCLASH_EDITOR_BASE_URL="$BASE_URL" \
OPENCLASH_EDITOR_RESOLVE_IP="$MIRROR_IP" \
sh "$TEMPORARY"

printf '%s\n' "$EDITION" > /usr/share/openclash-editor/EDITION
chmod 644 /usr/share/openclash-editor/EDITION
echo "已安装：${LABEL}"
