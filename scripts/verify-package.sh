#!/bin/zsh
set -euo pipefail

root=${0:A:h:h}
app=${1:-$root/dist/Superlemon.app}
contents="$app/Contents"

required=(
  "$contents/Info.plist"
  "$contents/MacOS/superlemon"
  "$contents/Helpers/nvim/bin/nvim"
  "$contents/Resources/runtime/lua/superlemon/init.lua"
  "$contents/Resources/runtime/config/custom-init.lua"
  "$contents/Resources/runtime/config/user-init.vim"
  "$contents/Resources/Licenses/Superlemon.txt"
  "$contents/Resources/Licenses/Neovim.txt"
  "$contents/Resources/THIRD_PARTY_NOTICES.md"
  "$contents/Resources/dependencies.json"
  "$contents/Resources/runtime/fonts/FiraCodeNerdFontMono-Regular.ttf"
  "$contents/Resources/runtime/fonts/LICENSE-FiraCode-NerdFont.txt"
)
for required_path in "${required[@]}"; do
  if [[ ! -e "$required_path" ]]; then
    echo "package is missing: $required_path" >&2
    exit 1
  fi
done

/usr/bin/plutil -lint "$contents/Info.plist" >/dev/null
/usr/bin/plutil -convert xml1 -o /dev/null "$contents/Resources/dependencies.json"

expected_version=$(/usr/bin/plutil -extract neovim.version raw -o - \
  "$contents/Resources/dependencies.json")
reported_version=$("$contents/Helpers/nvim/bin/nvim" --version | head -n 1)
if [[ "$reported_version" != "NVIM v$expected_version"* ]]; then
  echo "packaged Neovim version mismatch: $reported_version" >&2
  exit 1
fi

expected_license_sha=$(/usr/bin/plutil -extract neovim.licenseSha256 raw -o - \
  "$contents/Resources/dependencies.json")
actual_license_sha=$(/usr/bin/shasum -a 256 \
  "$contents/Resources/Licenses/Neovim.txt" | /usr/bin/awk '{print $1}')
if [[ "$actual_license_sha" != "$expected_license_sha" ]]; then
  echo "packaged Neovim license does not match the dependency manifest" >&2
  exit 1
fi

expected_font_sha=$(/usr/bin/plutil -extract firaCodeNerdFont.fontSha256 raw -o - \
  "$contents/Resources/dependencies.json")
actual_font_sha=$(/usr/bin/shasum -a 256 \
  "$contents/Resources/runtime/fonts/FiraCodeNerdFontMono-Regular.ttf" \
  | /usr/bin/awk '{print $1}')
expected_font_license_sha=$(/usr/bin/plutil \
  -extract firaCodeNerdFont.licenseSha256 raw -o - \
  "$contents/Resources/dependencies.json")
actual_font_license_sha=$(/usr/bin/shasum -a 256 \
  "$contents/Resources/runtime/fonts/LICENSE-FiraCode-NerdFont.txt" \
  | /usr/bin/awk '{print $1}')
if [[ "$actual_font_sha" != "$expected_font_sha" \
  || "$actual_font_license_sha" != "$expected_font_license_sha" ]]
then
  echo "packaged Fira Code Nerd Font assets do not match the dependency manifest" >&2
  exit 1
fi

if /usr/bin/grep -Eq 'vim\.pack|github\.com/kylechui/nvim-surround' \
  "$contents/Resources/runtime/config/init.lua"
then
  echo "managed config still contains a first-run network plugin bootstrap" >&2
  exit 1
fi

/usr/bin/codesign --verify --deep --strict --verbose=2 "$app"
echo "PACKAGE OK: $app (Neovim $expected_version)"
