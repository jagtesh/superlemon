#!/usr/bin/env bash
# Runs runtime specs under headless nvim.
# Usage:
#   bash runtime/tests/run.sh                    # every spec
#   bash runtime/tests/run.sh minimap_spec.lua   # focused spec(s)
set -u

NVIM="${NVIM:-/opt/homebrew/bin/nvim}"
if ! command -v "$NVIM" >/dev/null 2>&1; then
  NVIM="nvim"
fi

dir="$(cd "$(dirname "$0")" && pwd)"
failed=0
total=0

if [ "$#" -gt 0 ]; then
  specs=()
  for requested in "$@"; do
    case "$requested" in
      /*) candidate="$requested" ;;
      *) candidate="$dir/$requested" ;;
    esac
    if [ ! -f "$candidate" ]; then
      echo "missing runtime spec: $candidate" >&2
      exit 2
    fi
    specs+=("$candidate")
  done
else
  specs=("$dir"/*_spec.lua)
fi

for spec in "${specs[@]}"; do
  total=$((total + 1))
  name="$(basename "$spec")"
  echo "== ${name}"
  if "$NVIM" --headless --clean -u NONE -l "$spec"; then
    echo "== ${name}: PASS"
  else
    echo "== ${name}: FAIL"
    failed=$((failed + 1))
  fi
  echo
done

if [ "$failed" -eq 0 ]; then
  echo "ALL PASS (${total} specs)"
  exit 0
else
  echo "${failed}/${total} specs FAILED"
  exit 1
fi
