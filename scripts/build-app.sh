#!/usr/bin/env bash
# Build the desktop app.
#
# --no-tree-shake-icons is NOT optional: with Flutter 3.47 the icon subsetting
# produced a 1.1 KB MaterialIcons font whose glyphs no longer matched the
# codepoints, so every icon rendered as garbage.
#
# Build flavours:
#   slim      (default) — no kernel inside the package; uses a system or
#                         user-downloaded mihomo.
#   embedded            — ships a kernel at assets/bin/mihomo (内嵌内核) so a
#                         machine with no kernel and no network still works.
#                         Pass --kernel <path> or ARAN_KERNEL=/path/to/mihomo.
#   --smartdns <path>   — also embed smartdns at assets/bin/smartdns
#                         (--smartdns-auto picks it up from PATH).
#                         mihomo and smartdns are both GPL-3.0: distributing them
#                         makes the whole package GPL-3.0 as well.
set -euo pipefail
cd "$(dirname "$0")/../app"

KERNEL_SRC="${ARAN_KERNEL:-$(command -v mihomo || true)}"
SMARTDNS_SRC="${ARAN_SMARTDNS:-$(command -v smartdns || true)}"
EMBED=0
EMBED_SMARTDNS=0
while [ $# -gt 0 ]; do
  case "$1" in
    --kernel) KERNEL_SRC="$2"; EMBED=1; shift 2 ;;
    --embedded) EMBED=1; shift ;;
    --smartdns) SMARTDNS_SRC="$2"; EMBED_SMARTDNS=1; shift 2 ;;
    --smartdns-auto) EMBED_SMARTDNS=1; shift ;;
    *) break ;;
  esac
done

if [ "$EMBED" = "1" ]; then
  if [ -z "${KERNEL_SRC:-}" ] || [ ! -x "$KERNEL_SRC" ]; then
    echo "需要内核：--kernel <path> 或设置 ARAN_KERNEL" >&2
    exit 1
  fi
  mkdir -p assets/bin
  cp "$KERNEL_SRC" assets/bin/mihomo
  chmod +x assets/bin/mihomo
  echo "内嵌内核: $KERNEL_SRC → assets/bin/mihomo ($(du -h assets/bin/mihomo | cut -f1))"
else
  rm -f assets/bin/mihomo
  echo "slim 构建：包内不含内核"
fi

if [ "$EMBED_SMARTDNS" = "1" ]; then
  if [ -z "${SMARTDNS_SRC:-}" ] || [ ! -x "${SMARTDNS_SRC:-/nonexistent}" ]; then
    echo "找不到 smartdns：--smartdns <path> 或设置 ARAN_SMARTDNS；跳过" >&2
  else
    mkdir -p assets/bin
    cp "$SMARTDNS_SRC" assets/bin/smartdns
    chmod +x assets/bin/smartdns
    echo "内嵌 SmartDNS: $SMARTDNS_SRC → assets/bin/smartdns ($(du -h assets/bin/smartdns | cut -f1))"
  fi
else
  rm -f assets/bin/smartdns
fi

flutter build linux --release --no-tree-shake-icons "$@"
