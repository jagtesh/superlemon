#!/bin/zsh
set -euo pipefail

root=${0:A:h:h}
app=${1:-$root/dist/Superlemon.app}
mode=${SUPERLEMON_SIGNING_MODE:-adhoc}
contents="$app/Contents"
main_executable="$contents/MacOS/superlemon"
nvim_executable="$contents/Helpers/nvim/bin/nvim"

if [[ ! -d "$app" || ! -x "$main_executable" || ! -x "$nvim_executable" ]]; then
  echo "incomplete application bundle: $app" >&2
  exit 1
fi

case "$mode" in
  adhoc)
    identity="-"
    signing_arguments=(--force --sign "$identity")
    executable_arguments=(--force --sign "$identity")
    ;;
  developer-id)
    identity=${SUPERLEMON_CODESIGN_IDENTITY:-}
    if [[ -z "$identity" ]]; then
      echo "SUPERLEMON_CODESIGN_IDENTITY is required for developer-id signing" >&2
      exit 2
    fi
    signing_arguments=(--force --timestamp --options runtime --sign "$identity")
    executable_arguments=(--force --timestamp --options runtime --sign "$identity")
    ;;
  *)
    echo "unsupported SUPERLEMON_SIGNING_MODE: $mode" >&2
    exit 2
    ;;
esac

# Remove downloaded-file quarantine/resource-fork metadata before signing.
/usr/bin/xattr -cr "$app"

# Sign every nested Mach-O before the two executables and outer bundle. Neovim
# is handled separately because LuaJIT requires one narrowly-scoped entitlement.
find "$contents" -type f -print0 |
while IFS= read -r -d '' component; do
  if [[ "$component" == "$main_executable" || "$component" == "$nvim_executable" ]]; then
    continue
  fi
  if /usr/bin/file "$component" | /usr/bin/grep -q 'Mach-O'; then
    /usr/bin/codesign "${signing_arguments[@]}" "$component"
  fi
done

if [[ "$mode" == developer-id ]]; then
  /usr/bin/codesign "${executable_arguments[@]}" \
    --entitlements "$root/packaging/entitlements/neovim.plist" \
    "$nvim_executable"
else
  /usr/bin/codesign "${executable_arguments[@]}" "$nvim_executable"
fi

/usr/bin/codesign "${executable_arguments[@]}" "$main_executable"
/usr/bin/codesign "${signing_arguments[@]}" "$app"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app"
