#!/bin/zsh
set -euo pipefail

root=${0:A:h:h}
configuration=${1:-release}
dist_dir=${SUPERLEMON_DIST_DIR:-"$root/dist"}
app="$dist_dir/Superlemon.app"
contents="$app/Contents"
manifest="$root/packaging/dependencies.json"

asset_info=$(mktemp "${TMPDIR:-/tmp}/superlemon-assets.XXXXXX.plist")
trap 'rm -f "$asset_info"' EXIT INT TERM

cd "$root"
swift_arguments=(-c "$configuration")
if [[ ${SUPERLEMON_SWIFTPM_DISABLE_SANDBOX:-0} == 1 ]]; then
  # Homebrew already provides the build sandbox; SwiftPM cannot nest its own
  # sandbox-exec process inside it.
  swift_arguments+=(--disable-sandbox)
fi
swift build "${swift_arguments[@]}"
build_dir=$(swift build "${swift_arguments[@]}" --show-bin-path)

rm -rf "$app"
mkdir -p "$contents/MacOS" "$contents/Resources/Licenses" "$contents/Helpers"
cp "$root/packaging/Info.plist" "$contents/Info.plist"
cp "$build_dir/superlemon" "$contents/MacOS/superlemon"
cp -R "$root/runtime" "$contents/Resources/runtime"
cp "$root/LICENSE" "$contents/Resources/Licenses/Superlemon.txt"
cp "$root/packaging/licenses/Neovim.txt" "$contents/Resources/Licenses/Neovim.txt"
cp "$root/packaging/THIRD_PARTY_NOTICES.md" "$contents/Resources/THIRD_PARTY_NOTICES.md"
cp "$manifest" "$contents/Resources/dependencies.json"

nvim_distribution=${SUPERLEMON_NVIM_DIST:-$("$root/scripts/fetch-neovim.sh")}
if [[ ! -x "$nvim_distribution/bin/nvim" ]]; then
  echo "invalid Neovim distribution: $nvim_distribution" >&2
  exit 1
fi
expected_nvim_version=$(/usr/bin/plutil -extract neovim.version raw -o - "$manifest")
reported_nvim_version=$("$nvim_distribution/bin/nvim" --version | head -n 1)
if [[ "$reported_nvim_version" != "NVIM v$expected_nvim_version"* ]]; then
  echo "Neovim version mismatch: expected $expected_nvim_version, got $reported_nvim_version" >&2
  exit 1
fi

cp -R "$nvim_distribution" "$contents/Helpers/nvim"
# Cache metadata authenticates the source before packaging; the bundled
# dependency manifest carries the same digest without confusing code-signing's
# nested-code discovery.
rm -f "$contents/Helpers/nvim/.superlemon-source-sha256"
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
  --output-partial-info-plist "$asset_info"

/usr/libexec/PlistBuddy -c "Merge $asset_info" "$contents/Info.plist"

# Stamp the *bundle's* Info.plist with the real version, derived from git.
# packaging/Info.plist itself stays at a placeholder — see scripts/release.sh.
marketing_version=$("$root/scripts/version.sh" marketing)
build_number=$("$root/scripts/version.sh" build)
semver=$("$root/scripts/version.sh" semver)
commit=$("$root/scripts/version.sh" commit)

plist_set_or_add() {
  local key=$1 type=$2 value=$3
  if /usr/libexec/PlistBuddy -c "Print :$key" "$contents/Info.plist" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c "Set :$key $value" "$contents/Info.plist"
  else
    /usr/libexec/PlistBuddy -c "Add :$key $type $value" "$contents/Info.plist"
  fi
}
plist_set_or_add CFBundleShortVersionString string "$marketing_version"
plist_set_or_add CFBundleVersion string "$build_number"
plist_set_or_add SuperlemonVersion string "$semver"
plist_set_or_add SuperlemonCommit string "$commit"

"$root/scripts/sign-app.sh" "$app"
"$root/scripts/verify-package.sh" "$app"
echo "Superlemon $semver (build $build_number, $commit)"
echo "$app"
