#!/bin/zsh
set -euo pipefail

root=${0:A:h:h}
manifest="$root/packaging/dependencies.json"

manifest_value() {
  /usr/bin/plutil -extract "$1" raw -o - "$manifest"
}

if [[ ! -f "$manifest" ]]; then
  echo "missing dependency manifest: $manifest" >&2
  exit 1
fi

pinned_version=$(manifest_value neovim.version)
version=${SUPERLEMON_NEOVIM_VERSION:-$pinned_version}
version=${version#v}
architecture=${SUPERLEMON_ARCHITECTURE:-$(uname -m)}

case "$architecture" in
  arm64|x86_64) ;;
  *)
    echo "unsupported macOS architecture: $architecture" >&2
    exit 1
    ;;
esac

asset=$(manifest_value "neovim.architectures.$architecture.asset")
url=$(manifest_value "neovim.architectures.$architecture.url")
expected_sha256=$(manifest_value "neovim.architectures.$architecture.sha256")

if [[ "$version" != "$pinned_version" ]]; then
  if [[ -z ${SUPERLEMON_NEOVIM_SHA256:-} ]]; then
    echo "a non-manifest Neovim version requires SUPERLEMON_NEOVIM_SHA256" >&2
    exit 2
  fi
  expected_sha256=$SUPERLEMON_NEOVIM_SHA256
  if [[ -n ${SUPERLEMON_NEOVIM_URL:-} ]]; then
    url=$SUPERLEMON_NEOVIM_URL
  else
    url="https://github.com/neovim/neovim/releases/download/v$version/$asset.tar.gz"
  fi
elif [[ -n ${SUPERLEMON_NEOVIM_SHA256:-} || -n ${SUPERLEMON_NEOVIM_URL:-} ]]; then
  echo "URL/checksum overrides are only accepted with a non-manifest version" >&2
  exit 2
fi

if [[ ! "$expected_sha256" =~ '^[0-9a-f]{64}$' ]]; then
  echo "invalid Neovim SHA-256 for $architecture" >&2
  exit 1
fi

cache="$root/.build/neovim/v$version/$architecture"
distribution="$cache/$asset"
marker="$distribution/.superlemon-source-sha256"

verify_distribution() {
  local candidate=$1
  [[ -x "$candidate/bin/nvim" ]] || return 1
  local reported_version
  reported_version=$("$candidate/bin/nvim" --version | head -n 1)
  [[ "$reported_version" == "NVIM v$version"* ]] || return 1
  /usr/bin/file "$candidate/bin/nvim" | /usr/bin/grep -q "$architecture" || return 1
}

if verify_distribution "$distribution" \
  && [[ -f "$marker" ]] \
  && [[ $(<"$marker") == "$expected_sha256" ]]
then
  echo "$distribution"
  exit 0
fi

for command in curl shasum tar awk python3; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "$command is required" >&2
    exit 1
  fi
done

mkdir -p "$cache"
archive=$(mktemp "$cache/.neovim-download.XXXXXX")
extract_dir=$(mktemp -d "$cache/.neovim-extract.XXXXXX")
cleanup() {
  rm -f "$archive"
  rm -rf "$extract_dir"
}
trap cleanup EXIT INT TERM

curl --fail --location --retry 3 --proto '=https' --tlsv1.2 \
  "$url" --output "$archive"

actual_sha256=$(shasum -a 256 "$archive" | awk '{print $1}')
if [[ "$actual_sha256" != "$expected_sha256" ]]; then
  echo "Neovim checksum mismatch" >&2
  echo "expected: $expected_sha256" >&2
  echo "actual:   $actual_sha256" >&2
  exit 1
fi

# The checksum authenticates the bytes. Before extraction, independently
# constrain every member and symlink/hardlink target to the one expected
# top-level directory; device nodes and other special members are rejected.
python3 "$root/scripts/validate-tar-archive.py" "$archive" "$asset"

tar -xzf "$archive" -C "$extract_dir" --no-same-owner
candidate="$extract_dir/$asset"
if ! verify_distribution "$candidate"; then
  echo "downloaded Neovim distribution is incomplete or has the wrong version/architecture" >&2
  exit 1
fi

print -r -- "$expected_sha256" > "$candidate/.superlemon-source-sha256"
rm -rf "$distribution"
mv "$candidate" "$distribution"

echo "$distribution"
