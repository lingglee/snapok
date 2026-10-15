#!/usr/bin/env bash
set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/snapok"
BIN_DIR="$HOME/.local/bin"
DESKTOP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"

mkdir -p "$APP_DIR" "$BIN_DIR" "$DESKTOP_DIR"
# Replace application code as a unit so removed modules do not linger after an
# upgrade. User screenshots live in "$APP_DIR/history" and are left untouched.
rm -rf "$APP_DIR/snapok_linux"
cp -R "$SOURCE_DIR/snapok_linux.py" "$SOURCE_DIR/snapok_linux" "$APP_DIR/"
cp "$SOURCE_DIR/../Sources/Snapok/Resources/AppIcon.png" "$APP_DIR/AppIcon.png"
ln -sfn "$APP_DIR/snapok_linux.py" "$BIN_DIR/snapok"
chmod +x "$APP_DIR/snapok_linux.py" "$BIN_DIR/snapok"

sed \
  -e "s|@EXEC@|$BIN_DIR/snapok|g" \
  -e "s|@ICON@|$APP_DIR/AppIcon.png|g" \
  "$SOURCE_DIR/packaging/snapok.desktop.in" > "$DESKTOP_DIR/ai.thinkany.snapok.desktop"

command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$DESKTOP_DIR" || true
echo "Installed Snapok. Launch it from the application menu or run: $BIN_DIR/snapok"
