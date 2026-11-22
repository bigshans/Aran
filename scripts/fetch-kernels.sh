#!/usr/bin/env bash
# Download the kernels Aran can ship with the app into assets/bin/.
#
# Bundling matters: mihomo and smartdns are not installed on most machines, and
# a 3-year-old distro package is worse than no package at all. The binaries are
# copied into the Flutter asset bundle at build time and extracted to
# ~/.local/share/aran/bin on first run.
#
# Licences: mihomo is GPL-3.0, smartdns is GPL-3.0. Shipping them means the
# distributed app is GPL-3.0 as well.
set -euo pipefail

cd "$(dirname "$0")/.."
DEST="app/assets/bin"
mkdir -p "$DEST"

arch="$(uname -m)"
case "$arch" in
  x86_64)  MIHOMO_ARCH=amd64 ;;
  aarch64) MIHOMO_ARCH=arm64 ;;
  *) echo "不支持的架构: $arch" >&2; exit 1 ;;
esac

echo "==> 拉取最新 mihomo (${MIHOMO_ARCH})"
api="https://api.github.com/repos/MetaCubeX/mihomo/releases/latest"
tag="$(curl -fsSL "$api" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])')"
asset="$(curl -fsSL "$api" | python3 -c "
import json,sys
arch='${MIHOMO_ARCH}'
for a in json.load(sys.stdin)['assets']:
    n=a['name']
    if n.startswith('mihomo-linux-'+arch) and n.endswith('.gz') and 'compatible' not in n and 'go1' not in n:
        print(a['browser_download_url']); break
")"
echo "    $tag"
curl -fsSL "$asset" | gunzip -c > "$DEST/mihomo"
chmod +x "$DEST/mihomo"
"$DEST/mihomo" -v | head -1

echo "==> SmartDNS（可选）"
if command -v pacman >/dev/null && pacman -Qi smartdns >/dev/null 2>&1; then
  cp "$(command -v smartdns)" "$DEST/smartdns"
  chmod +x "$DEST/smartdns"
  echo "    从系统包复制: $("$DEST/smartdns" -v | head -1)"
else
  echo "    跳过：未安装 smartdns（安装后可重跑本脚本，或从上游下载）"
fi

echo
echo "完成。文件："
ls -lh "$DEST"
echo
echo "提醒：内置内核会随 app 一起分发，构建产物因此变大（mihomo 约 15-30MB）。"
