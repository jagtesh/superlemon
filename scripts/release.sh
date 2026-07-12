#!/bin/zsh
set -euo pipefail

root=${0:A:h:h}
version=${1:-}

if [[ ! "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
  echo "usage: scripts/release.sh <version>"
  echo "example: scripts/release.sh 0.2.0"
  exit 2
fi

cd "$root"

if [[ $(git branch --show-current) != main ]]; then
  echo "release must be created from main"
  exit 1
fi

if [[ -n $(git status --porcelain) ]]; then
  echo "working tree must be clean"
  exit 1
fi

git fetch origin main --tags

if [[ $(git rev-parse HEAD) != $(git rev-parse origin/main) ]]; then
  echo "local main must exactly match origin/main"
  exit 1
fi

tag="v$version"
if git rev-parse --verify --quiet "refs/tags/$tag" >/dev/null; then
  echo "$tag already exists"
  exit 1
fi

/usr/libexec/PlistBuddy -c \
  "Set :CFBundleShortVersionString $version" packaging/Info.plist
/usr/libexec/PlistBuddy -c \
  "Set :CFBundleVersion $(( $(git rev-list --count HEAD) + 1 ))" packaging/Info.plist

git add packaging/Info.plist
git commit -m "Release $tag"
git tag -a "$tag" -m "Superlemon $version"
git push origin main
git push origin "$tag"

echo "Release build started: https://github.com/jagtesh/superlemon/actions"
echo "After it completes, publish the Homebrew cask with:"
echo "  scripts/publish-homebrew-cask.sh $version"
