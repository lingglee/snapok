#!/bin/sh
set -eu

if [ "$(id -u)" -ne 0 ]; then
  echo "This helper must run through pkexec." >&2
  exit 1
fi
if [ "$#" -ne 1 ] || [ ! -f "$1" ]; then
  echo "Usage: replace-package-root.sh /absolute/path/to/snapok_VERSION_ARCH.deb" >&2
  exit 1
fi

package_path="$1"
package_name="$(dpkg-deb -f "$package_path" Package 2>/dev/null || true)"
if [ "$package_name" != "snapok" ]; then
  echo "Refusing to install a package not named snapok: $package_path" >&2
  exit 1
fi

installed_status="$(dpkg-query -W -f='${db:Status-Status}' snapok 2>/dev/null || true)"
if [ "$installed_status" = "installed" ]; then
  apt-get purge -y snapok
else
  echo "No installed Debian snapok package to purge; continuing with installation."
fi
apt-get install -y "$package_path"
