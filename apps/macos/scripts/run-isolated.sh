#!/bin/zsh
set -euo pipefail

# `HOME` alone is not enough: cfprefsd finds preferences by bundle id and user record.
#   scripts/run-isolated.sh [--keep] [--home DIR] [--app PATH] [-- ARGS...]
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

bundle_id="com.boltty.isolated.$$"
staged_app="$home_dir/Boltty.app"
cp -R "$app" "$staged_app"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_id" \
  "$staged_app/Contents/Info.plist" >/dev/null
codesign --force --sign - "$staged_app" >/dev/null 2>&1 || true

# A killed Boltty leaves its OpenCode server, and the ledger to reap it by is in this home.
reap_servers() {
  local ledger="$home_dir/Library/Application Support/Boltty/opencode-server.pid"
  [[ -f "$ledger" ]] || return 0
  local server owner
  while read -r server owner || [[ -n "$server" ]]; do
    [[ "$server" == <-> ]] || continue
    [[ "$(ps -o comm= -p "$server" 2>/dev/null)" == *opencode* ]] || continue
    kill "$server" 2>/dev/null || true
  done < "$ledger"
}

# A Boltty killed outright never runs the trap: its server is left with launchd as
# its parent, in a throwaway home holding a staged copy under a bundle id of its own.
reap_orphans() {
  local server home id
  for server in $(pgrep -x opencode 2>/dev/null); do
    [[ "$(ps -o ppid= -p "$server" 2>/dev/null | tr -d ' ')" == 1 ]] || continue
    home="$(ps eww -o command= -p "$server" 2>/dev/null | tr ' ' '\n' | sed -n 's/^HOME=//p' | head -1)"
    [[ -n "$home" && "$home" != "$HOME" ]] || continue
    id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$home/Boltty.app/Contents/Info.plist" 2>/dev/null || true)"
    [[ "$id" == com.boltty.* && "$id" != com.boltty.app ]] || continue
    print "[i] reaping OpenCode server $server left by a staged copy that was killed"
    kill "$server" 2>/dev/null || true
  done
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
trap 'exit 130' INT TERM HUP
reap_orphans

print "[i] isolated home:   $home_dir"
print "[i] isolated domain: $bundle_id"

env HOME="$home_dir" \
    CFFIXED_USER_HOME="$home_dir" \
    "$staged_app/Contents/MacOS/Boltty" "${passthrough[@]}"
