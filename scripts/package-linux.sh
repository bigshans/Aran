#!/usr/bin/env bash
# Build the Linux deliverables:
#   1. portable tarball  (通用包：解压即用，可加 portable 标记变完全便携)
#   2. Arch package      (aran-bin, 用上面的 tarball 打包)
#
# Usage: scripts/package-linux.sh [--no-arch]
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
VER="$(grep -m1 '^version:' app/pubspec.yaml | awk '{print $2}')"
OUT="$ROOT/dist"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

echo "==> 构建 release（slim：不含内核）"
./scripts/build-app.sh >/dev/null
BUNDLE="$ROOT/app/build/linux/x64/release/bundle"

echo "==> 组装通用包 aran-$VER-linux-x64"
PKG="$STAGE/aran-$VER-linux-x64"
mkdir -p "$PKG"
cp -a "$BUNDLE/." "$PKG/"
install -Dm644 "$ROOT/app/assets/icon.png" "$PKG/share/icons/hicolor/512x512/apps/aran.png"

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

内核：
  本包不含内核。可用以下任一方式：
    * 发行版安装 mihomo（推荐）
    * 应用内 设置 → 内核更新 → 下载
  检查：设置 → 内核二进制 会列出自动发现的候选。

依赖：GTK3（gtk3）、libayatana-appindicator（托盘）
TXT

mkdir -p "$OUT"
TARBALL="$OUT/aran-$VER-linux-x64.tar.gz"
tar -C "$STAGE" -czf "$TARBALL" "aran-$VER-linux-x64"
echo "     $TARBALL  ($(du -h "$TARBALL" | cut -f1))"

if [ "${1:-}" != "--no-arch" ]; then
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
