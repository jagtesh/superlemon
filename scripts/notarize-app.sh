#!/bin/zsh
set -euo pipefail

root=${0:A:h:h}
app=${1:-$root/dist/Superlemon.app}
archive=${2:-$root/dist/Superlemon-macOS-arm64.zip}
api_key=${APPLE_NOTARY_KEY_PATH:-}
key_id=${APPLE_NOTARY_KEY_ID:-}
issuer_id=${APPLE_NOTARY_ISSUER_ID:-}

if [[ -z "$api_key" || -z "$key_id" || -z "$issuer_id" ]]; then
  echo "APPLE_NOTARY_KEY_PATH, APPLE_NOTARY_KEY_ID, and APPLE_NOTARY_ISSUER_ID are required" >&2
  exit 2
fi
if [[ ! -d "$app" ]]; then
  echo "application bundle not found: $app" >&2
  exit 1
fi

submission=$(mktemp "${TMPDIR:-/tmp}/superlemon-notary.XXXXXX.zip")
trap 'rm -f "$submission"' EXIT INT TERM
notarization_log="$archive.notarization.json"

/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$submission"
xcrun notarytool submit "$submission" \
  --key "$api_key" --key-id "$key_id" --issuer "$issuer_id" \
  --wait --output-format json | /usr/bin/tee "$notarization_log"
xcrun stapler staple "$app"
xcrun stapler validate "$app"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app"
/usr/sbin/spctl --assess --type execute --verbose=2 "$app"

rm -f "$archive"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"
/usr/bin/shasum -a 256 "$archive" > "$archive.sha256"
echo "$archive"
