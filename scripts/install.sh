#!/bin/bash
# Installs the latest Snapok from https://cdn.snapok.app, which serves this file as /install.sh:
#
#   curl -fsSL https://cdn.snapok.app/install.sh | bash
#
# Environment:
#   SNAPOK_CHANNEL=dev          install Snapok Dev instead of Snapok
#   SNAPOK_INSTALL_DIR=<dir>    install somewhere other than /Applications (or ~/Applications when that isn't writable)
#   SNAPOK_NO_LAUNCH=1          don't open the app afterwards
#
# The ZIP must match the manifest's SHA-256 and pass Gatekeeper as a notarized Developer ID app,
# the same checks the in-app updater relies on. Everything runs inside main so a truncated download does nothing.
set -euo pipefail

CDN=https://cdn.snapok.app

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }
die() { printf '\033[31mError:\033[0m %s\n' "$*" >&2; exit 1; }

version_at_least() { # <have> <need>, numeric x.y.z
  local IFS=.
  local -a have=($1) need=($2)
  local i
  for i in 0 1 2; do
    (( ${have[i]:-0} > ${need[i]:-0} )) && return 0
    (( ${have[i]:-0} < ${need[i]:-0} )) && return 1
  done
  return 0
}

main() {
  [[ "$(uname -s)" == Darwin ]] || die "Snapok runs on macOS only."

  local channel="${SNAPOK_CHANNEL:-release}" app_name bundle_id prefix
  case "$channel" in
    release) app_name="Snapok"; bundle_id="ai.thinkany.snapok"; prefix="" ;;
    dev) app_name="Snapok Dev"; bundle_id="ai.thinkany.snapok.dev"; prefix="dev/" ;;
    *) die "SNAPOK_CHANNEL must be release or dev." ;;
  esac

  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT

  say "Checking the latest $app_name"
  curl -fsSL --retry 3 "$CDN/${prefix}latest.json?t=$(date +%s)" -o "$tmp/latest.json" \
    || die "Could not download $CDN/${prefix}latest.json"
  field() { plutil -extract "$1" raw -o - "$tmp/latest.json"; }
  local version url sha256 min_os
  version="$(field version)"; url="$(field url)"; sha256="$(field sha256)"; min_os="$(field minimumSystemVersion)"
  [[ "$url" == "$CDN/"* ]] || die "Unexpected download URL in manifest: $url"

  version_at_least "$(sw_vers -productVersion)" "$min_os" \
    || die "$app_name $version requires macOS $min_os or later (this Mac runs $(sw_vers -productVersion))."

  say "Downloading $app_name $version"
  curl -fL --retry 3 --progress-bar "$url" -o "$tmp/$app_name.zip" || die "Download failed: $url"
  [[ "$(shasum -a 256 "$tmp/$app_name.zip" | cut -d' ' -f1)" == "$sha256" ]] \
    || die "Checksum mismatch for $url; nothing was installed."

  ditto -x -k "$tmp/$app_name.zip" "$tmp/unpacked"
  local new_app="$tmp/unpacked/$app_name.app"
  [[ -d "$new_app" ]] || die "The download does not contain $app_name.app."
  [[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$new_app/Contents/Info.plist")" == "$bundle_id" ]] \
    || die "The download has an unexpected bundle identifier."
  codesign --verify --deep --strict "$new_app" 2>/dev/null || die "The app's code signature is invalid."
  spctl --assess --type execute "$new_app" 2>/dev/null || die "Gatekeeper rejected the app; it is not notarized."

  local dir="${SNAPOK_INSTALL_DIR:-}"
  if [[ -z "$dir" ]]; then
    if [[ -w /Applications ]]; then dir=/Applications; else dir="$HOME/Applications"; fi
  fi
  mkdir -p "$dir"
  local target="$dir/$app_name.app"

  if pgrep -f "$target/Contents/MacOS/" >/dev/null 2>&1; then
    say "Quitting the running $app_name"
    osascript -e "tell application id \"$bundle_id\" to quit" >/dev/null 2>&1 || true
    local i
    for i in {1..20}; do pgrep -f "$target/Contents/MacOS/" >/dev/null 2>&1 || break; sleep 0.5; done
  fi

  say "Installing to $target"
  # Move the old copy aside first so a failed copy can be rolled back.
  if [[ -e "$target" ]]; then mv "$target" "$tmp/previous.app"; fi
  if ! ditto "$new_app" "$target"; then
    rm -rf "$target"
    [[ -e "$tmp/previous.app" ]] && mv "$tmp/previous.app" "$target"
    die "Could not copy $app_name.app into $dir."
  fi

  say "$app_name $version is installed."
  [[ -n "${SNAPOK_NO_LAUNCH:-}" ]] || open "$target"
  echo "It updates itself from now on. To uninstall, quit $app_name and move $target to the Trash."
}

main "$@"
