#!/bin/zsh
set -euo pipefail

root=${0:A:h:h}
version=${1:-}
tap_repo=${SUPERLEMON_HOMEBREW_TAP:-jagtesh/homebrew-tap}
asset="Superlemon-${version}-macOS.zip"
release_url="https://github.com/jagtesh/superlemon/releases/download/v${version}/${asset}"

if [[ ! "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
  echo "usage: scripts/publish-homebrew-cask.sh <version>" >&2
  echo "example: scripts/publish-homebrew-cask.sh 0.2.0" >&2
  exit 2
fi

for command in gh git shasum; do
  if ! command -v "$command" >/dev/null; then
    echo "$command is required" >&2
    exit 1
  fi
done

if ! gh release view "v$version" --repo jagtesh/superlemon >/dev/null 2>&1; then
  echo "GitHub Release v$version is not available yet" >&2
  exit 1
fi

workdir=$(mktemp -d "${TMPDIR:-/tmp}/superlemon-homebrew.XXXXXX")
trap 'rm -rf "$workdir"' EXIT

gh release download "v$version" \
  --repo jagtesh/superlemon \
  --pattern "$asset" \
  --dir "$workdir"
sha256=$(shasum -a 256 "$workdir/$asset" | awk '{print $1}')

git clone "git@github.com:${tap_repo}.git" "$workdir/tap"
mkdir -p "$workdir/tap/Casks"

sed \
  -e "s/@VERSION@/$version/g" \
  -e "s/@SHA256@/$sha256/g" \
  "$root/packaging/homebrew/superlemon.rb.in" \
  > "$workdir/tap/Casks/superlemon.rb"

cd "$workdir/tap"
if [[ -z $(git status --porcelain -- Casks/superlemon.rb) ]]; then
  echo "Homebrew cask is already current"
  exit 0
fi

git add Casks/superlemon.rb
git commit -m "Update Superlemon to $version"
git push origin HEAD

echo "Published $tap_repo/Casks/superlemon.rb"
echo "Install with:"
echo "  brew tap jagtesh/tap"
echo "  brew install --cask --no-quarantine superlemon"
