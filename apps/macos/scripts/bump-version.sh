#!/bin/zsh
set -euo pipefail

# Moves Boltty to a new version, and its build number one up — once per
# version: the same version again changes nothing, a lower one is refused.
#
#   scripts/bump-version.sh 0.2.0
#
# Both only ever grow: an installed Boltty compares its version with the
# latest release's tag, so a version that did not grow is a release nobody is
# told about.
# project.yml is the source; the pbxproj is regenerated from it, and the
# scheme XcodeGen rewrites on the way is put back as it was.

cd "${0:A:h}/.."

version="${1:-}"
[[ "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || {
  print -u2 "usage: scripts/bump-version.sh MAJOR.MINOR.PATCH"
  exit 2
}

# "0.10.0" is newer than "0.9.2": number by number — release.sh and every
# installed copy compare the same way.
is_newer() {
  local -a a b
  a=(${(s:.:)1}); b=(${(s:.:)2})
  local i x y
  for (( i = 1; i <= ${#a} || i <= ${#b}; i++ )); do
    x=${a[i]:-0}; y=${b[i]:-0}
    (( x > y )) && return 0
    (( x < y )) && return 1
  done
  return 1
}

current=$(sed -nE 's/^ *MARKETING_VERSION: "?([^"]+)"?$/\1/p' project.yml)
build=$(sed -nE 's/^ *CURRENT_PROJECT_VERSION: "?([0-9]+)"?$/\1/p' project.yml)
[[ -n "$current" && -n "$build" ]] || { print -u2 "no MARKETING_VERSION / CURRENT_PROJECT_VERSION in project.yml"; exit 1 }

# Run twice for the same version, it does nothing the second time: the build
# number moves once per version, not once per run.
if [[ "$version" == "$current" ]]; then
  print "Boltty is already $current ($build) — nothing to change"
  exit 0
fi
is_newer "$version" "$current" || {
  print -u2 "$version is not above $current — a version only grows"
  exit 1
}
next=$(( build + 1 ))

sed -i '' -E \
  -e "s/^( *MARKETING_VERSION: )\"?[^\"]+\"?$/\1\"$version\"/" \
  -e "s/^( *CURRENT_PROJECT_VERSION: )\"?[0-9]+\"?$/\1\"$next\"/" \
  project.yml

scheme=Boltty.xcodeproj/xcshareddata/xcschemes/Boltty.xcscheme
kept=$(mktemp)
cp "$scheme" "$kept"
xcodegen generate --quiet
cp "$kept" "$scheme"
rm "$kept"

grep -q "MARKETING_VERSION = $version;" Boltty.xcodeproj/project.pbxproj
grep -q "CURRENT_PROJECT_VERSION = $next;" Boltty.xcodeproj/project.pbxproj
print "Boltty $version ($next)"
