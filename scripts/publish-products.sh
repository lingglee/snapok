#!/usr/bin/env bash
# Publishes the「周边」product list to https://cdn.snapok.app/products.json, which the app's settings read.
#
#   ./scripts/publish-products.sh
#
# Edit cdn/products.json, then run this. Icons go to products/<id>.png: those bundled with the app
# (Sources/Snapok/Resources/Products) plus any extra PNGs in cdn/products/ for apps the build doesn't ship.
# Uploads go through the snapok-cdn-upload Worker when CDN_UPLOAD_TOKEN is set, otherwise the local wrangler login.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

CDN=https://cdn.snapok.app
UPLOAD_URL=https://snapok-cdn-upload.me-6e5.workers.dev
BUCKET=snapok
FEED=cdn/products.json

# Every entry needs an id, a name, an http(s) url, and both summaries; icons must exist locally.
python3 - "$FEED" <<'PY'
import json, os, sys
products = json.load(open(sys.argv[1]))["products"]
assert products, "no products"
for p in products:
    for key in ("id", "name", "url"):
        assert p.get(key), f"{p} is missing {key}"
    assert p["url"].startswith(("https://", "http://")), p["url"]
    assert p.get("summary", {}).get("en") and p["summary"].get("zh"), f"{p['id']} needs summary.en and summary.zh"
    icon = p.get("icon")
    if icon:
        name = os.path.basename(icon)
        assert any(os.path.exists(os.path.join(d, name)) for d in ("Sources/Snapok/Resources/Products", "cdn/products")), \
            f"{p['id']}: no local {name} to upload"
print(f"{len(products)} products OK")
PY

if [[ -n "${CDN_UPLOAD_TOKEN:-}" ]]; then
  upload() { # <file> <key> <content-type> <cache-control>
    echo "==> $CDN/$2"
    curl -fsS --retry 5 --retry-all-errors -X PUT -o /dev/null \
      -H "Authorization: Bearer $CDN_UPLOAD_TOKEN" -H "Content-Type: $3" -H "X-Cache-Control: $4" \
      --data-binary "@$1" "$UPLOAD_URL/$2"
  }
else
  upload() {
    echo "==> $CDN/$2"
    npx -y wrangler@latest r2 object put "$BUCKET/$2" --file "$1" --content-type "$3" --cache-control "$4" --remote >/dev/null
  }
fi

shopt -s nullglob
for icon in Sources/Snapok/Resources/Products/*.png cdn/products/*.png; do
  upload "$icon" "products/$(basename "$icon")" image/png "public, max-age=86400"
done
# The list last, so it never names an icon that isn't there yet.
upload "$FEED" products.json "application/json; charset=utf-8" "public, max-age=300"
echo "Published $CDN/products.json"
