#!/usr/bin/env bash
set -euo pipefail

APP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/snapok"
BIN_PATH="$HOME/.local/bin/snapok"
DESKTOP_PATH="${XDG_DATA_HOME:-$HOME/.local/share}/applications/ai.thinkany.snapok.desktop"

# Stop only the per-user Snapok launch paths. Anchoring the full command line
# avoids matching this script, terminals, or unrelated Python applications.
for pattern in \
  "^python3 $BIN_PATH( |$)" \
  "^python3 $APP_DIR/snapok_linux.py( |$)"; do
  pids="$(pgrep -u "$(id -u)" -f "$pattern" 2>/dev/null || true)"
  [[ -z "$pids" ]] || kill $pids 2>/dev/null || true
done

rm -f "$BIN_PATH" "$DESKTOP_PATH" "$APP_DIR/snapok_linux.py" "$APP_DIR/AppIcon.png"
rm -rf "$APP_DIR/snapok_linux"
command -v update-desktop-database >/dev/null 2>&1 \
  && update-desktop-database "$(dirname "$DESKTOP_PATH")" \
  || true

echo "Removed the per-user Snapok application."
echo "Preserved screenshots: $APP_DIR/history"
echo "Preserved settings: ${XDG_CONFIG_HOME:-$HOME/.config}/snapok"
