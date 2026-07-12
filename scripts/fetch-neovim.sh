#!/bin/zsh
set -euo pipefail

root=${0:A:h:h}
version=${SUPERLEMON_NEOVIM_VERSION:-v0.12.4}
architecture=$(uname -m)

case "$architecture" in
  arm64) asset="nvim-macos-arm64" ;;
  x86_64) asset="nvim-macos-x86_64" ;;
  *)
    echo "unsupported macOS architecture: $architecture" >&2
    exit 1
    ;;
esac

cache="$root/.build/neovim/$version/$architecture"
distribution="$cache/$asset"

if [[ ! -x "$distribution/bin/nvim" ]]; then
  archive="$cache/$asset.tar.gz"
  mkdir -p "$cache"
  curl --fail --location --retry 3 \
    "https://github.com/neovim/neovim/releases/download/$version/$asset.tar.gz" \
    --output "$archive"
  rm -rf "$distribution"
  tar -xzf "$archive" -C "$cache"
  rm -f "$archive"
fi

if [[ ! -x "$distribution/bin/nvim" ]]; then
  echo "downloaded Neovim distribution is incomplete" >&2
  exit 1
fi

echo "$distribution"
