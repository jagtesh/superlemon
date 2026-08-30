#!/bin/zsh
set -euo pipefail

root=${0:A:h:h}
arg=${1:-}

usage() {
  echo "usage: scripts/release.sh [minor|major|X.Y.Z]"
  echo "with no argument, bumps the patch version automatically"
  echo "examples:"
  echo "  scripts/release.sh          # e.g. 0.1.4 -> 0.1.5"
  echo "  scripts/release.sh minor    # e.g. 0.1.4 -> 0.2.0"
  echo "  scripts/release.sh major    # e.g. 0.1.4 -> 1.0.0"
  echo "  scripts/release.sh 0.2.0    # explicit version"
}

bump=""
explicit_version=""
case "$arg" in
  '') bump="patch" ;;
  minor | major) bump="$arg" ;;
  *)
    if [[ "$arg" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
      explicit_version="$arg"
    else
      usage
      exit 2
    fi
    ;;
esac

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

"$root/scripts/verify-dependencies.sh"

if [[ $(git rev-parse HEAD) != $(git rev-parse origin/main) ]]; then
  echo "local main must exactly match origin/main"
  exit 1
fi

if [[ -n "$explicit_version" ]]; then
  version="$explicit_version"
else
  version=$("$root/scripts/version.sh" next "$bump")
fi

tag="v$version"
if git rev-parse --verify --quiet "refs/tags/$tag" >/dev/null; then
  echo "$tag already exists"
  exit 1
fi

latest_tag=$(git tag --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=-v:refname | head -n 1)
if [[ -n "$latest_tag" ]]; then
  latest=${latest_tag#v}
  requested_parts=(${(s:.:)version})
  latest_parts=(${(s:.:)latest})
  if (( requested_parts[1] < latest_parts[1]
    || (requested_parts[1] == latest_parts[1] && requested_parts[2] < latest_parts[2])
    || (requested_parts[1] == latest_parts[1] && requested_parts[2] == latest_parts[2]
      && requested_parts[3] <= latest_parts[3]) )); then
    echo "$tag must be newer than $latest_tag" >&2
    exit 1
  fi
fi

# packaging/Info.plist deliberately stays at a placeholder version
# (0.0.0 / 0). The real per-build version is stamped into the *built app
# bundle* by scripts/package-app.sh, derived from scripts/version.sh, which
# reads git tags/history — not this checked-in template. Editing the repo
# plist here would just be a version nobody ever ships.
echo "$version" >"$root/VERSION"

git add VERSION
git commit -m "Release $tag"
git tag -a "$tag" -m "Superlemon $version"
git push --atomic origin HEAD:main "refs/tags/$tag"

echo "Released $tag"
echo "Release build started: https://github.com/jagtesh/superlemon/actions"
echo "After it completes, publish the source-build Homebrew formula with:"
echo "  scripts/publish-homebrew-formula.sh $version"
