#!/bin/zsh
set -euo pipefail

root=${0:A:h:h}
manifest="$root/packaging/dependencies.json"
license="$root/packaging/licenses/Neovim.txt"
template="$root/packaging/homebrew/superlemon.rb.in"
font="$root/runtime/fonts/FiraCodeNerdFontMono-Regular.ttf"
font_license="$root/runtime/fonts/LICENSE-FiraCode-NerdFont.txt"

/usr/bin/plutil -convert xml1 -o /dev/null "$manifest"
version=$(/usr/bin/plutil -extract neovim.version raw -o - "$manifest")
license_source=$(/usr/bin/plutil -extract neovim.licenseSource raw -o - "$manifest")
license_sha256=$(/usr/bin/plutil -extract neovim.licenseSha256 raw -o - "$manifest")

for architecture in arm64 x86_64; do
  sha=$(/usr/bin/plutil -extract "neovim.architectures.$architecture.sha256" raw -o - "$manifest")
  url=$(/usr/bin/plutil -extract "neovim.architectures.$architecture.url" raw -o - "$manifest")
  [[ "$sha" =~ '^[0-9a-f]{64}$' ]] || {
    echo "invalid $architecture checksum" >&2
    exit 1
  }
  [[ "$url" == https://github.com/neovim/neovim/releases/download/v$version/* ]] || {
    echo "$architecture URL does not match manifest version $version" >&2
    exit 1
  }
done

if [[ $(/usr/bin/shasum -a 256 "$license" | /usr/bin/awk '{print $1}') \
  != "$license_sha256" ]]
then
  echo "checked-in Neovim license differs from the upstream v$version license" >&2
  echo "source: $license_source" >&2
  exit 1
fi

font_sha256=$(/usr/bin/plutil -extract firaCodeNerdFont.fontSha256 raw -o - "$manifest")
font_license_sha256=$(/usr/bin/plutil -extract firaCodeNerdFont.licenseSha256 raw -o - \
  "$manifest")
if [[ $(/usr/bin/shasum -a 256 "$font" | /usr/bin/awk '{print $1}') != "$font_sha256" ]]; then
  echo "bundled Fira Code Nerd Font differs from the dependency manifest" >&2
  exit 1
fi
if [[ $(/usr/bin/shasum -a 256 "$font_license" | /usr/bin/awk '{print $1}') \
  != "$font_license_sha256" ]]
then
  echo "bundled Fira Code Nerd Font license differs from the dependency manifest" >&2
  exit 1
fi

for placeholder in \
  NEOVIM_ARM64_URL NEOVIM_ARM64_SHA256 NEOVIM_X86_64_URL NEOVIM_X86_64_SHA256
do
  /usr/bin/grep -q "@$placeholder@" "$template" || {
    echo "Homebrew template is missing @$placeholder@" >&2
    exit 1
  }
done

echo "DEPENDENCIES OK: Neovim $version"
