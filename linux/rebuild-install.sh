#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(sed -n 's/^__version__ = "\([^"]*\)"/\1/p' "$ROOT_DIR/linux/snapok_linux/__init__.py")"
ARCH="$(dpkg --print-architecture)"
PACKAGE_PATH="$ROOT_DIR/dist/snapok_${VERSION}_${ARCH}.deb"
SYSTEM_PROCESS_PATTERN='^python3 /usr/lib/snapok/snapok_linux\.py($| )'

if [[ -z "$VERSION" ]]; then
  echo "Could not read the Snapok version." >&2
  exit 1
fi
if ! command -v pkexec >/dev/null 2>&1; then
  echo "pkexec is required to replace the Debian package." >&2
  exit 1
fi

echo "==> 1/7 Running tests"
make -C "$ROOT_DIR" linux-test

echo "==> 2/7 Building Snapok $VERSION for $ARCH"
make -C "$ROOT_DIR" linux-package
if [[ ! -f "$PACKAGE_PATH" ]]; then
  echo "Expected package was not created: $PACKAGE_PATH" >&2
  exit 1
fi

echo "==> 3/7 Removing the per-user application (history and settings are preserved)"
"$ROOT_DIR/linux/uninstall-user.sh"

echo "==> 4/7 Stopping any system-package process"
system_pids="$(pgrep -f "$SYSTEM_PROCESS_PATTERN" 2>/dev/null || true)"
if [[ -n "$system_pids" ]]; then
  kill $system_pids
  for _attempt in {1..20}; do
    pgrep -f "$SYSTEM_PROCESS_PATTERN" >/dev/null 2>&1 || break
    sleep 0.1
  done
fi

echo "==> 5/7 Purging the old Debian package when present"
echo "==> 6/7 Installing $PACKAGE_PATH"
pkexec "$ROOT_DIR/linux/replace-package-root.sh" "$PACKAGE_PATH"

echo "==> 7/7 Starting the system package"
setsid -f /usr/bin/snapok
for _attempt in {1..30}; do
  if pgrep -f "$SYSTEM_PROCESS_PATTERN" >/dev/null 2>&1; then
    echo "Snapok $VERSION is running from /usr/lib/snapok."
    echo "Screenshots: ${XDG_DATA_HOME:-$HOME/.local/share}/snapok/history"
    exit 0
  fi
  sleep 0.1
done

echo "Snapok was installed but did not remain running." >&2
echo "Try launching it manually with: /usr/bin/snapok" >&2
exit 1
