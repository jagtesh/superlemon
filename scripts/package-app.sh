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
mkdir -p "$contents/MacOS" "$contents/Resources"
cp "$root/packaging/Info.plist" "$contents/Info.plist"
cp "$build_dir/superlemon" "$contents/MacOS/superlemon"
cp -R "$root/runtime" "$contents/Resources/runtime"

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

codesign --force --deep --sign - "$app"
echo "$app"
