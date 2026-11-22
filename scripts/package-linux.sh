#!/usr/bin/env bash
# Build the Linux deliverables:
#   1. portable tarball  (通用包：解压即用，可加 portable 标记变完全便携)
#   2. Arch package      (aran-bin, 用上面的 tarball 打包)
#
# Usage: scripts/package-linux.sh [--slim] [--no-arch]
#   默认内嵌内核（通用包开箱即用）；--slim 打出不含内核的瘦身包。
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
VER="$(grep -m1 '^version:' app/pubspec.yaml | awk '{print $2}')"
OUT="$ROOT/dist"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

MODE="embedded"
ARCH_ON=1
for arg in "$@"; do
  case "$arg" in
    --slim) MODE="slim" ;;
    --no-arch) ARCH_ON=0 ;;
  esac
done

if [ "$MODE" = "embedded" ]; then
  KERNEL="${ARAN_KERNEL:-$(command -v mihomo || true)}"
  if [ -z "${KERNEL:-}" ] || [ ! -x "${KERNEL:-/nonexistent}" ]; then
    echo "找不到 mihomo：设置 ARAN_KERNEL=/path/to/mihomo，或用 --slim 打瘦身包" >&2
    exit 1
  fi
  SMARTDNS="${ARAN_SMARTDNS:-$(command -v smartdns || true)}"
  if [ -n "${SMARTDNS:-}" ] && [ -x "${SMARTDNS:-/nonexistent}" ]; then
    echo "==> 构建 release（内嵌内核: $KERNEL / 内嵌 smartdns: $SMARTDNS）"
    ./scripts/build-app.sh --kernel "$KERNEL" --smartdns "$SMARTDNS" >/dev/null
  else
    echo "==> 构建 release（内嵌内核：$KERNEL，未找到 smartdns）"
    ./scripts/build-app.sh --kernel "$KERNEL" >/dev/null
  fi
else
  echo "==> 构建 release（slim：不含内核）"
  ./scripts/build-app.sh >/dev/null
fi
BUNDLE="$ROOT/app/build/linux/x64/release/bundle"

echo "==> 组装通用包 aran-$VER-linux-x64"
ASSETS="$BUNDLE/data/flutter_assets/assets"
if [ -f "$ASSETS/bin/mihomo" ]; then
  echo "    内嵌内核: $(du -h "$ASSETS/bin/mihomo" | cut -f1)"
else
  echo "    内嵌内核: 无（slim）"
fi
echo "    内嵌 SmartDNS: $(if [ -f "$ASSETS/bin/smartdns" ]; then du -h "$ASSETS/bin/smartdns" | cut -f1; else echo '无'; fi)"
echo "    服务模板: $(ls "$ASSETS/service" 2>/dev/null | tr '\n' ' ')"
PKG="$STAGE/aran-$VER-linux-x64"
mkdir -p "$PKG"
cp -a "$BUNDLE/." "$PKG/"
install -Dm644 "$ROOT/app/assets/icon.png" "$PKG/share/icons/hicolor/512x512/apps/aran.png"

# Upstream licences for the bundled binaries (GPL-3.0 compliance).
LICDIR="$PKG/share/licenses/aran"
install -d "$LICDIR"
install -m644 "$ROOT/LICENSE" "$LICDIR/ARAN-LICENSE"
[ -f "$ROOT/packaging/licenses/mihomo-LICENSE" ] && install -m644 "$ROOT/packaging/licenses/mihomo-LICENSE" "$LICDIR/mihomo-LICENSE"
[ -f "$ROOT/packaging/licenses/smartdns-LICENSE" ] && install -m644 "$ROOT/packaging/licenses/smartdns-LICENSE" "$LICDIR/smartdns-LICENSE"
echo "    许可证: $(ls "$LICDIR" | tr '\n' ' ')"

cat > "$PKG/aran" <<'RUN'
#!/usr/bin/env bash
# Portable launcher: runs from wherever this directory is unpacked.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$here/aran_app" "$@"
RUN
chmod +x "$PKG/aran"

cat > "$PKG/aran.desktop" <<DESK
[Desktop Entry]
Type=Application
Name=Aran
Comment=Proxy scheduler
Exec=aran
Icon=aran
Terminal=false
Categories=Network;
DESK

cat > "$PKG/README.txt" <<'TXT'
Aran — 便携版
=============

用法：
  ./aran                      直接运行（数据在 ~/.local/share/aran）

完全便携（数据/配置/内核都在本目录，不写系统位置、不使用 systemd）：
  touch portable            然后重新启动 ./aran
  数据会落在 ./aran-data/

安装到系统（可选）：
  sudo install -Dm755 aran /usr/local/bin/aran
  sudo install -Dm644 aran.desktop /usr/share/applications/aran.desktop
  sudo install -Dm644 share/icons/hicolor/512x512/apps/aran.png \
      /usr/share/icons/hicolor/512x512/apps/aran.png

内核与服务文件（都在 data/flutter_assets/assets/ 下）：
  bin/mihomo        内嵌内核，首次运行会解压到数据目录（~/.local/share/aran/bin
                    或便携模式的 aran-data/bin），之后由应用管理版本
  service/*.tmpl    内嵌服务文件（systemd / OpenRC / runit 三种模板），
                    「安装服务」时填充 @KERNEL@ / @DATADIR@ 后写入系统

如果想让应用改用系统安装的 mihomo：设置 → 内核二进制 → 选择 /usr/bin/mihomo。

依赖：GTK3（gtk3）、libayatana-appindicator（托盘）
TXT

mkdir -p "$OUT"
TARBALL="$OUT/aran-$VER-linux-x64.tar.gz"
tar -C "$STAGE" -czf "$TARBALL" "aran-$VER-linux-x64"
echo "     $TARBALL  ($(du -h "$TARBALL" | cut -f1))"

if [ "$ARCH_ON" = "1" ]; then
  echo "==> 构建 Arch 包 aran-bin"
  PKGDIR="$ROOT/packaging/arch"
  rm -rf "$PKGDIR/src" "$PKGDIR/pkg" "$PKGDIR"/*.pkg.tar.* 2>/dev/null || true
  cp "$TARBALL" "$PKGDIR/aran-$VER.tar.gz"
  ( cd "$PKGDIR" && PKGEXT='.pkg.tar.zst' makepkg -f --nodeps --noconfirm >/dev/null )
  cp "$PKGDIR"/*.pkg.tar.zst "$OUT"/ 2>/dev/null || true
  rm -rf "$PKGDIR/src" "$PKGDIR/pkg" "$PKGDIR/aran-$VER.tar.gz"
  echo "     $(ls "$OUT"/*.pkg.tar.zst 2>/dev/null | head -1)"
fi

echo "==> 校验和"
( cd "$OUT" && sha256sum ./* > SHA256SUMS && cat SHA256SUMS )
