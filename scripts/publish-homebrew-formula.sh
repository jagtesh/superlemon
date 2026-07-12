#!/bin/zsh
set -euo pipefail

root=${0:A:h:h}
version=${1:-}
tap_repo=${SUPERLEMON_HOMEBREW_TAP:-jagtesh/homebrew-tap}

if [[ ! "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
  echo "usage: scripts/publish-homebrew-formula.sh <version>" >&2
  echo "example: scripts/publish-homebrew-formula.sh 0.2.0" >&2
  exit 2
fi

for command in curl gh git shasum; do
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

source_archive="$workdir/superlemon-$version.tar.gz"
curl --fail --location --retry 3 \
  "https://github.com/jagtesh/superlemon/archive/refs/tags/v$version.tar.gz" \
  --output "$source_archive"
source_sha256=$(shasum -a 256 "$source_archive" | awk '{print $1}')

git clone "git@github.com:${tap_repo}.git" "$workdir/tap"
mkdir -p "$workdir/tap/Formula"

sed \
  -e "s/@VERSION@/$version/g" \
  -e "s/@SOURCE_SHA256@/$source_sha256/g" \
  "$root/packaging/homebrew/superlemon.rb.in" \
  > "$workdir/tap/Formula/superlemon.rb"
rm -f "$workdir/tap/Casks/superlemon.rb"

cd "$workdir/tap"
if [[ -z $(git status --porcelain -- Formula/superlemon.rb Casks/superlemon.rb) ]]; then
  echo "Homebrew formula is already current"
  exit 0
fi

git add -A Formula/superlemon.rb Casks/superlemon.rb
git commit -m "Update Superlemon to $version"
git push origin HEAD

echo "Published $tap_repo/Formula/superlemon.rb"
echo "Install with:"
echo "  brew tap jagtesh/tap"
echo "  brew install superlemon"
