#!/bin/zsh
#
# publish-local.sh — build the current commit and put it in /Applications.
#
set -euo pipefail

root=${0:A:h:h}
dist_dir=${SUPERLEMON_DIST_DIR:-"$root/dist"}
install_dir=${SUPERLEMON_INSTALL_DIR:-/Applications}
built_app="$dist_dir/Superlemon.app"
installed_app="$install_dir/Superlemon.app"
staging_app="$install_dir/Superlemon.app.new"
process_pattern="Superlemon.app/Contents/MacOS/superlemon"

dry_run=0
force=0
open_mode="auto" # auto | open | skip

usage() {
  cat <<'EOF'
usage: scripts/publish-local.sh [--dry-run] [--force] [--open|--no-open] [-h]

Packages the current commit and installs it to /Applications/Superlemon.app
in place, quitting and relaunching a running instance around the swap.

  --dry-run   package and verify only; never touches /Applications or any
              running instance
  --force     kill a running instance that does not quit within 15 s
              (default: abort, so an unsaved-buffers dialog is never bypassed)
  --open      relaunch after installing, even if it wasn't already running
  --no-open   never relaunch, even if it was already running
  -h, --help  this text

Overrides: SUPERLEMON_DIST_DIR (build output), SUPERLEMON_INSTALL_DIR
(install target, default /Applications).
EOF
}

while (($#)); do
  case "$1" in
    --dry-run) dry_run=1 ;;
    --force) force=1 ;;
    --open) open_mode="open" ;;
    --no-open) open_mode="skip" ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

trap 'echo "publish-local.sh failed at line $LINENO" >&2' ERR

is_running() {
  pgrep -f "$process_pattern" >/dev/null 2>&1
}

echo "==> Packaging Superlemon (release)"
"$root/scripts/package-app.sh" release

if [[ ! -d "$built_app" ]]; then
  echo "expected build output at $built_app but it is missing" >&2
  exit 1
fi

if ((dry_run)); then
  echo "==> Dry run: package + verify complete, stopping before install"
  if is_running; then
    echo "==> Dry run: Superlemon is running; a real run would quit it,"
    echo "    replace $installed_app, and relaunch it"
  else
    echo "==> Dry run: Superlemon is not running; a real run would install"
    echo "    to $installed_app without relaunching (unless --open is passed)"
  fi
  exit 0
fi

was_running=0
if is_running; then
  was_running=1
  echo "==> Quitting running Superlemon"
  osascript -e 'tell application "Superlemon" to quit' >/dev/null 2>&1 || true
  attempts=0
  while is_running && ((attempts < 30)); do
    sleep 0.5
    attempts=$((attempts + 1))
  done
  if is_running; then
    if ((force)); then
      echo "==> Superlemon did not quit gracefully; --force given, sending SIGTERM"
      pids=("${(@f)$(pgrep -f "$process_pattern")}")
      ((${#pids[@]})) && kill -TERM "${pids[@]}" 2>/dev/null || true
      sleep 5
      if is_running; then
        echo "==> Still running; sending SIGKILL"
        pids=("${(@f)$(pgrep -f "$process_pattern")}")
        ((${#pids[@]})) && kill -KILL "${pids[@]}" 2>/dev/null || true
      fi
    else
      # A quit that stalls is almost always the unsaved-buffers dialog.
      # Killing here would discard those edits; leave the running app and
      # the freshly built bundle alone.
      echo "Superlemon is still running (probably waiting on an unsaved-buffers dialog)." >&2
      echo "Save or discard, quit it, and rerun — or pass --force to kill it." >&2
      exit 1
    fi
  fi
fi

echo "==> Installing to $installed_app"
rm -rf "$staging_app"
cp -R "$built_app" "$staging_app"
rm -rf "$installed_app"
mv "$staging_app" "$installed_app"

echo "==> Verifying installed bundle"
codesign --verify --deep --strict "$installed_app"
if ! cmp -s "$installed_app/Contents/MacOS/superlemon" "$built_app/Contents/MacOS/superlemon"; then
  echo "installed binary does not match the freshly built binary" >&2
  exit 1
fi

installed_version=$(/usr/libexec/PlistBuddy -c "Print :SuperlemonVersion" \
  "$installed_app/Contents/Info.plist" 2>/dev/null || echo unknown)
installed_build=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" \
  "$installed_app/Contents/Info.plist" 2>/dev/null || echo unknown)
installed_commit=$(/usr/libexec/PlistBuddy -c "Print :SuperlemonCommit" \
  "$installed_app/Contents/Info.plist" 2>/dev/null || echo unknown)
echo "Installed Superlemon $installed_version (build $installed_build, $installed_commit) at $installed_app"

should_open=0
if [[ "$open_mode" == open ]]; then
  should_open=1
elif [[ "$open_mode" == auto && $was_running -eq 1 ]]; then
  should_open=1
fi

if ((should_open)); then
  echo "==> Relaunching Superlemon"
  open -a "$installed_app"
fi
