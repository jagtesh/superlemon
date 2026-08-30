#!/bin/zsh
#
# version.sh — single source of truth for Superlemon's version.
#
# The VERSION file at the repo root holds the last *released* version and is
# used only as a fallback base when git tags are unavailable (shallow
# clones, source tarballs without tag history, etc). Every per-build version
# is derived here, at build time, from git history — it is never written
# back to VERSION. Only scripts/release.sh writes VERSION, at release time.
#
set -euo pipefail

root=${0:A:h:h}

usage() {
  cat <<'EOF'
usage: scripts/version.sh [FIELD] [BUMP]
       scripts/version.sh --json

Prints a single version field derived from git history. With no arguments,
prints the same value the app displays (the "semver" field).

Fields:
  base                latest released version, e.g. 0.1.4
  count               commits since that release (0 at the tag)
  build               total commit count on HEAD (CFBundleVersion)
  commit              short commit SHA, "-dirty" suffixed if the tree has
                      uncommitted tracked changes
  next [patch|minor|major]
                      base with the given component bumped (default: patch)
  semver              what the app displays: base at a clean tag, else
                      "<next patch>-dev.<count>" (plus ".dirty" if dirty)
  marketing           like semver but numeric dot-separated only, for
                      CFBundleShortVersionString; dev builds use the next
                      patch here so they sort above the last release

  --json              all fields as a JSON object
  -h, --help          this text
EOF
}

cd "$root"

_is_dirty() {
  ! git diff --quiet HEAD 2>/dev/null
}

_base_tag() {
  git describe --tags --match 'v[0-9]*' --abbrev=0 2>/dev/null || true
}

_base_version() {
  local tag file_version
  tag=$(_base_tag)
  if [[ -n "$tag" ]]; then
    echo "${tag#v}"
    return
  fi
  if [[ -f "$root/VERSION" ]]; then
    file_version=$(<"$root/VERSION")
    file_version=${file_version//[[:space:]]/}
    if [[ -n "$file_version" ]]; then
      echo "$file_version"
      return
    fi
  fi
  echo "0.0.0"
}

_count() {
  local tag
  tag=$(_base_tag)
  if [[ -n "$tag" ]]; then
    git rev-list --count "$tag"..HEAD 2>/dev/null || echo 0
  else
    git rev-list --count HEAD 2>/dev/null || echo 0
  fi
}

_build() {
  git rev-list --count HEAD 2>/dev/null || echo 0
}

_commit() {
  local sha
  sha=$(git rev-parse --short=10 HEAD 2>/dev/null || echo unknown)
  if _is_dirty; then
    echo "${sha}-dirty"
  else
    echo "$sha"
  fi
}

_next() {
  local bump=${1:-patch} base major minor patch
  base=$(_base_version)
  IFS='.' read -r major minor patch <<<"$base"
  major=${major:-0}
  minor=${minor:-0}
  patch=${patch:-0}
  case "$bump" in
    patch) patch=$((patch + 1)) ;;
    minor)
      minor=$((minor + 1))
      patch=0
      ;;
    major)
      major=$((major + 1))
      minor=0
      patch=0
      ;;
    *)
      echo "unknown bump: $bump (expected patch, minor, or major)" >&2
      exit 2
      ;;
  esac
  echo "${major}.${minor}.${patch}"
}

_semver() {
  local count dirty=0
  count=$(_count)
  _is_dirty && dirty=1
  if [[ "$count" == 0 && "$dirty" == 0 ]]; then
    _base_version
    return
  fi
  local prerelease="dev.${count}"
  if [[ "$dirty" == 1 ]]; then
    prerelease="${prerelease}.dirty"
  fi
  echo "$(_next patch)-${prerelease}"
}

_marketing() {
  local count dirty=0
  count=$(_count)
  _is_dirty && dirty=1
  if [[ "$count" == 0 && "$dirty" == 0 ]]; then
    _base_version
    return
  fi
  _next patch
}

_json() {
  printf '{\n'
  printf '  "base": "%s",\n' "$(_base_version)"
  printf '  "count": %s,\n' "$(_count)"
  printf '  "build": %s,\n' "$(_build)"
  printf '  "commit": "%s",\n' "$(_commit)"
  printf '  "next": "%s",\n' "$(_next patch)"
  printf '  "semver": "%s",\n' "$(_semver)"
  printf '  "marketing": "%s"\n' "$(_marketing)"
  printf '}\n'
}

field=${1:-semver}
case "$field" in
  -h | --help)
    usage
    exit 0
    ;;
  --json) _json ;;
  base) _base_version ;;
  count) _count ;;
  build) _build ;;
  commit) _commit ;;
  next) _next "${2:-patch}" ;;
  semver) _semver ;;
  marketing) _marketing ;;
  *)
    echo "unknown field: $field" >&2
    usage >&2
    exit 2
    ;;
esac
