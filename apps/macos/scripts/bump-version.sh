#!/bin/zsh
set -euo pipefail

#   scripts/bump-version.sh 0.2.0

cd "${0:A:h}/.."

version="${1:-}"
[[ "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || {
  print -u2 "usage: scripts/bump-version.sh MAJOR.MINOR.PATCH"
  exit 2
}

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
