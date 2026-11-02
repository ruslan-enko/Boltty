#!/bin/sh
# Installs Boltty from the latest GitHub release:
#
#   curl -fsSL https://raw.githubusercontent.com/ruslan-enko/Boltty/main/install.sh | sh
#
# Gatekeeper judges only what carries the quarantine mark, and a browser puts
# it on the DMG; curl does not. So a copy installed this way opens without
# System Settings › Privacy & Security › Open Anyway. What keeps it honest is
# done here instead: the DMG must match the release's Boltty.dmg.sha256, and
# the app must be signed by the identity every release is signed with — the
# requirement below, the same one UpdateInstaller holds an update to. Change
# it in the same commit as the signing identity.
#
#   BOLTTY_DMG=<path>          install that DMG (and its .sha256 beside it)
#   BOLTTY_INSTALL_DIR=<dir>   install there and do not open it
#
# Everything is inside main, called on the last line, so a download cut short
# runs nothing.

set -eu

requirement='identifier "com.boltty.app" and certificate root = H"7f48a0cba9e9056cc898f1fb2d5f5eb4938b5904"'
release=https://github.com/ruslan-enko/Boltty/releases/latest/download

say() { printf '%s\n' "$*"; }
die() { printf 'Boltty: %s\n' "$*" >&2; exit 1; }

main() {
  major=$(sw_vers -productVersion | cut -d. -f1)
  [ "$major" -ge 26 ] || die "needs macOS 26 or later (this Mac runs $(sw_vers -productVersion))."

  work=$(mktemp -d "${TMPDIR:-/tmp}/boltty-install.XXXXXX")
  mount="$work/mount"
  trap 'hdiutil detach "$mount" -force >/dev/null 2>&1 || true; rm -rf "$work"' EXIT INT TERM

  if [ -n "${BOLTTY_DMG:-}" ]; then
    dmg=$BOLTTY_DMG
    sums="$BOLTTY_DMG.sha256"
    [ -f "$dmg" ] || die "no DMG at $dmg."
    [ -f "$sums" ] || die "no checksum at $sums."
  else
    dmg="$work/Boltty.dmg"
    sums="$work/Boltty.dmg.sha256"
    say "Downloading Boltty…"
    curl -fsSL "$release/Boltty.dmg.sha256" -o "$sums" || die "could not download the release's checksum."
    curl -fL --progress-bar "$release/Boltty.dmg" -o "$dmg" || die "could not download Boltty.dmg."
  fi

  expected=$(awk 'NR == 1 { print tolower($1) }' "$sums")
  actual=$(shasum -a 256 "$dmg" | awk '{ print $1 }')
  [ -n "$expected" ] && [ "$expected" = "$actual" ] || die "Boltty.dmg does not match its checksum; nothing was installed."

  mkdir "$mount"
  hdiutil attach -nobrowse -noautoopen -readonly -mountpoint "$mount" "$dmg" >/dev/null 2>&1 \
    || die "could not open Boltty.dmg."
  source_app="$mount/Boltty.app"
  [ -d "$source_app" ] || die "Boltty.dmg holds no Boltty.app."
  codesign --verify --deep --strict -R="$requirement" "$source_app" >/dev/null 2>&1 \
    || die "Boltty.app is not signed by Boltty's identity; nothing was installed."

  if [ -n "${BOLTTY_INSTALL_DIR:-}" ]; then
    dir=$BOLTTY_INSTALL_DIR
  elif [ -w /Applications ]; then
    dir=/Applications
  else
    dir="$HOME/Applications"
  fi
  mkdir -p "$dir"
  app="$dir/Boltty.app"

  # An agent may be working inside it; quitting is the person's call.
  if pgrep -f "^$app/Contents/MacOS/Boltty" >/dev/null 2>&1; then
    die "Boltty is running. Choose Quit Boltty in its menu, or use Check for Updates… in it, then run this again."
  fi

  # Braced: in a UTF-8 locale bash 3.2 reads the ellipsis's first byte as
  # part of the name.
  say "Installing into ${dir}…"
  staged="$dir/.Boltty.app.installing"
  rm -rf "$staged"
  ditto "$source_app" "$staged" || die "could not copy Boltty into $dir."
  # curl leaves no quarantine; this is for a DMG that came another way.
  xattr -dr com.apple.quarantine "$staged" 2>/dev/null || true
  if [ -e "$app" ]; then
    rm -rf "$work/old" && mv "$app" "$work/old"
  fi
  mv "$staged" "$app"

  version=$(defaults read "$app/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "")
  say "Boltty $version is in $dir."
  if [ -z "${BOLTTY_INSTALL_DIR:-}" ]; then
    # `open`, not the binary: started from a shell, macOS would ask for
    # permissions on the terminal's behalf.
    open "$app"
    say "Press ⌥Space to start."
  fi
}

main "$@"
