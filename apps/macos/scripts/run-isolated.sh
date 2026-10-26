#!/bin/zsh
set -euo pipefail

# Runs a built Boltty in full isolation from the user's real state.
#
# Boltty keeps real state in two places, and they need two different mechanisms
# to redirect:
#
#   Application Support/Boltty  (conversations, attachments,  -> follows $HOME
#                                the OpenCode server ledger)
#   com.boltty.app preferences  (settings)                    -> follows the
#                                                                BUNDLE IDENTIFIER
#
# `HOME` alone is not enough. Preferences go through `cfprefsd`, which resolves
# the domain from the bundle id and the *user record* — not from `HOME`, and not
# from `CFFIXED_USER_HOME` for a non-sandboxed app. A test build launched with
# only `HOME` redirected still reads and writes the user's real settings.
#
# So this script does both: a throwaway `HOME`, and a copy of the app bundle
# re-stamped with a unique bundle id so it cannot reach the real domain at all.
#
# Usage:
#   scripts/run-isolated.sh [--keep] [--home DIR] [--app PATH] [-- ARGS...]
#
#   --keep      leave the isolated home, app copy and defaults domain behind
#   --home DIR  where the isolated home lives
#   --app PATH  path to Boltty.app; defaults to the Debug build in .derivedData

repo_root="${0:A:h}/../../.."
app=""
home_dir=""
keep=0
passthrough=()

while (( $# )); do
  case "$1" in
    --keep) keep=1; shift ;;
    --home) home_dir="$2"; shift 2 ;;
    --app) app="$2"; shift 2 ;;
    --) shift; passthrough=("$@"); break ;;
    *) print -u2 "[-] unknown argument: $1"; exit 2 ;;
  esac
done

if [[ -z "$app" ]]; then
  # The one DerivedData (AGENTS.md): Xcode's Cmd-R and every command in
  # README.md land here. This used to default to apps/macos/build, so running
  # the app in isolation launched a *different* bundle from the one just built
  # — and a stale binary looks exactly like a current one.
  app="$repo_root/apps/macos/.derivedData/Build/Products/Debug/Boltty.app"
fi

if [[ ! -x "$app/Contents/MacOS/Boltty" ]]; then
  print -u2 "[-] no executable at $app/Contents/MacOS/Boltty"
  print -u2 "    build first:"
  print -u2 "    xcodebuild -scheme Boltty -configuration Debug -destination 'platform=macOS' -derivedDataPath .derivedData build"
  exit 1
fi

if [[ -z "$home_dir" ]]; then
  home_dir="$(mktemp -d "${TMPDIR:-/tmp}/boltty-isolated.XXXXXX")"
fi
mkdir -p "$home_dir/Library/Preferences" "$home_dir/Library/Application Support"

# One domain per run, so two runs never share settings either.
bundle_id="com.boltty.isolated.$$"
staged_app="$home_dir/Boltty.app"
cp -R "$app" "$staged_app"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_id" \
  "$staged_app/Contents/Info.plist" >/dev/null
# Re-stamping the plist invalidates whatever signature the build had; ad-hoc is
# enough to launch locally and keeps the hardened-runtime checks happy.
codesign --force --sign - "$staged_app" >/dev/null 2>&1 || true

# A Boltty that is killed rather than quit leaves its OpenCode server running,
# and the ledger the next launch would reap it from lives in this home. Deleting
# the home without reading it first orphans the server for good: a
# screenshot loop that killed each launch once left fifteen of them, 1.2 GB. Only a
# pid still running `opencode` is ended, as the app's own reaper does.
reap_servers() {
  local ledger="$home_dir/Library/Application Support/Boltty/opencode-server.pid"
  [[ -f "$ledger" ]] || return 0
  local server owner
  while read -r server owner; do
    [[ "$server" == <-> ]] || continue
    [[ "$(ps -o comm= -p "$server" 2>/dev/null)" == *opencode* ]] || continue
    kill "$server" 2>/dev/null || true
  done < "$ledger"
}

cleanup() {
  if (( keep )); then
    print "[i] kept: home=$home_dir domain=$bundle_id"
  else
    reap_servers
    defaults delete "$bundle_id" >/dev/null 2>&1 || true
    rm -rf "$home_dir"
  fi
}
trap cleanup EXIT

print "[i] isolated home:   $home_dir"
print "[i] isolated domain: $bundle_id"

env HOME="$home_dir" \
    CFFIXED_USER_HOME="$home_dir" \
    "$staged_app/Contents/MacOS/Boltty" "${passthrough[@]}"
