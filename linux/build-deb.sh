#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${VERSION:-0.1.3}"
ARCH="${ARCH:-$(dpkg --print-architecture)}"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

mkdir -p \
  "$STAGING/DEBIAN" \
  "$STAGING/usr/bin" \
  "$STAGING/usr/lib/snapok" \
  "$STAGING/usr/share/applications" \
  "$STAGING/usr/share/icons/hicolor/256x256/apps"

cp -R "$ROOT_DIR/linux/snapok_linux.py" "$ROOT_DIR/linux/snapok_linux" "$STAGING/usr/lib/snapok/"
cp "$ROOT_DIR/linux/packaging/snapok-system-launcher" "$STAGING/usr/bin/snapok"
cp "$ROOT_DIR/linux/packaging/ai.thinkany.snapok.desktop" "$STAGING/usr/share/applications/"
cp "$ROOT_DIR/Sources/Snapok/Resources/AppIcon.png" \
  "$STAGING/usr/share/icons/hicolor/256x256/apps/ai.thinkany.snapok.png"
find "$STAGING/usr/lib/snapok" -type d -name __pycache__ -prune -exec rm -rf {} +
find "$STAGING" -type d -exec chmod 755 {} +
find "$STAGING" -type f -exec chmod 644 {} +
chmod 755 "$STAGING/usr/bin/snapok" "$STAGING/usr/lib/snapok/snapok_linux.py"

sed \
  -e "s/@VERSION@/$VERSION/g" \
  -e "s/@ARCH@/$ARCH/g" \
  "$ROOT_DIR/linux/packaging/control.in" > "$STAGING/DEBIAN/control"

mkdir -p "$ROOT_DIR/dist"
dpkg-deb --root-owner-group --build "$STAGING" "$ROOT_DIR/dist/snapok_${VERSION}_${ARCH}.deb"
echo "Built $ROOT_DIR/dist/snapok_${VERSION}_${ARCH}.deb"
