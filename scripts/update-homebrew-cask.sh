#!/usr/bin/env bash
# Points the Homebrew cask at the release currently in https://cdn.snapok.app/latest.json:
#
#   ./scripts/update-homebrew-cask.sh            commit and push Casks/snapok.rb to thinkany-ai/homebrew-tap
#   ./scripts/update-homebrew-cask.sh --print    print the cask only
#
# Users install with: brew install --cask thinkany-ai/tap/snapok
#
# Run it after publish-cdn.sh has moved latest.json, so the cask never references a package that isn't uploaded.
# CI pushes with HOMEBREW_TAP_TOKEN (a token with contents:write on the tap); locally it uses your git credentials.
# TAP_DIR=<checkout> writes into an existing checkout instead of cloning.
set -euo pipefail

CDN=https://cdn.snapok.app
TAP_REPO=thinkany-ai/homebrew-tap
MODE="${1:-}"
[[ -z "$MODE" || "$MODE" == --print ]] || { echo "usage: $0 [--print]" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
curl -fsS "$CDN/latest.json?t=$(date +%s)" -o "$WORK/latest.json"
field() { plutil -extract "$1" raw -o - "$WORK/latest.json"; }
VERSION="$(field version)"
SHA256="$(field sha256)"
MIN_OS="$(field minimumSystemVersion)"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Unexpected release version $VERSION" >&2; exit 1; }
[[ "$(field url)" == "$CDN/Snapok-$VERSION.zip" ]] || { echo "Unexpected package URL $(field url)" >&2; exit 1; }

case "${MIN_OS%%.*}" in
  14) MACOS=sonoma ;; 15) MACOS=sequoia ;; 26) MACOS=tahoe ;;
  *) echo "Add a Homebrew name for macOS $MIN_OS" >&2; exit 1 ;;
esac

cask() {
  cat <<RUBY
cask "snapok" do
  version "$VERSION"
  sha256 "$SHA256"

  url "$CDN/Snapok-#{version}.zip"
  name "Snapok"
  desc "Capture, annotate, and frame screenshots"
  homepage "https://snapok.app/"

  livecheck do
    url "$CDN/latest.json"
    strategy :json do |json|
      json["version"]
    end
  end

  auto_updates true
  depends_on macos: :$MACOS

  app "Snapok.app"

  uninstall quit: "ai.thinkany.snapok"

  zap trash: [
    "~/Library/Application Support/Snapok",
    "~/Library/Caches/ai.thinkany.snapok",
    "~/Library/HTTPStorages/ai.thinkany.snapok",
    "~/Library/Logs/Snapok.log",
    "~/Library/Preferences/ai.thinkany.snapok.plist",
  ]
end
RUBY
}

if [[ "$MODE" == --print ]]; then cask; exit 0; fi

if [[ -n "${TAP_DIR:-}" ]]; then
  TAP="$TAP_DIR"
else
  TAP="$WORK/tap"
  if [[ -n "${HOMEBREW_TAP_TOKEN:-}" ]]; then
    git clone --depth 1 "https://x-access-token:$HOMEBREW_TAP_TOKEN@github.com/$TAP_REPO.git" "$TAP"
  else
    git clone --depth 1 "git@github.com:$TAP_REPO.git" "$TAP"
  fi
fi

mkdir -p "$TAP/Casks"
cask > "$TAP/Casks/snapok.rb"
cd "$TAP"
if git diff --quiet -- Casks/snapok.rb && git ls-files --error-unmatch Casks/snapok.rb >/dev/null 2>&1; then
  echo "Casks/snapok.rb already offers Snapok $VERSION."
  exit 0
fi
[[ -n "$(git config user.name || true)" ]] || git config user.name "github-actions[bot]"
[[ -n "$(git config user.email || true)" ]] || git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git add Casks/snapok.rb
git commit -m "snapok $VERSION"
git push origin HEAD
echo "Updated $TAP_REPO: snapok $VERSION"
