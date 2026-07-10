#!/usr/bin/env bash
# Runs every *_spec.lua in this directory under headless nvim.
# Usage: bash runtime/tests/run.sh   (exits 0 iff all specs pass)
set -u

NVIM="${NVIM:-/opt/homebrew/bin/nvim}"
if ! command -v "$NVIM" >/dev/null 2>&1; then
  NVIM="nvim"
fi

dir="$(cd "$(dirname "$0")" && pwd)"
failed=0
total=0

for spec in "$dir"/*_spec.lua; do
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
