#!/bin/zsh
set -euo pipefail

root=${0:A:h:h}
configuration=${1:-release}
app="$root/dist/Superlemon.app"
contents="$app/Contents"

cd "$root"
swift build -c "$configuration"
build_dir=$(swift build -c "$configuration" --show-bin-path)

rm -rf "$app"
mkdir -p "$contents/MacOS" "$contents/Resources" "$contents/Helpers"
cp "$root/packaging/Info.plist" "$contents/Info.plist"
cp "$build_dir/superlemon" "$contents/MacOS/superlemon"
cp -R "$root/runtime" "$contents/Resources/runtime"

nvim_distribution=${SUPERLEMON_NVIM_DIST:-$("$root/scripts/fetch-neovim.sh")}
if [[ ! -x "$nvim_distribution/bin/nvim" ]]; then
  echo "invalid Neovim distribution: $nvim_distribution" >&2
  exit 1
fi
cp -R "$nvim_distribution" "$contents/Helpers/nvim"
mv "$contents/Helpers/nvim/share" "$contents/Resources/nvim-share"
ln -s ../../Resources/nvim-share "$contents/Helpers/nvim/share"

resource_bundle=$(find "$build_dir" -maxdepth 1 -name '*SuperlemonApp.bundle' -print -quit)
if [[ -n "$resource_bundle" ]]; then
  cp -R "$resource_bundle" "$contents/Resources/"
fi

xcrun actool "$root/packaging/Assets.xcassets" \
  --compile "$contents/Resources" \
  --platform macosx \
  --minimum-deployment-target 14.0 \
  --app-icon AppIcon \
  --output-partial-info-plist /tmp/superlemon-asset-info.plist

/usr/libexec/PlistBuddy -c \
  "Merge /tmp/superlemon-asset-info.plist" "$contents/Info.plist"

find "$contents/Helpers/nvim" -type f -print0 |
while IFS= read -r -d '' component; do
  if file "$component" | grep -q 'Mach-O'; then
    codesign --force --sign - "$component"
  fi
done
codesign --force --sign - "$contents/MacOS/superlemon"
codesign --force --sign - "$app"
echo "$app"
