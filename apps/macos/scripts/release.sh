#!/bin/zsh
set -euo pipefail

#   scripts/release.sh [--arch arm64|universal]
#   scripts/release.sh --local      # this Mac only: the files as they are now

repo="ruslan-enko/boltty"
app_dir="${0:A:h}/.."
cd "$app_dir"

arch=universal
local_build=false
while (( $# )); do
  case "$1" in
    --arch) arch="$2"; shift ;;
    --local) local_build=true ;;
    -h|--help) sed -n '4,40p' "${0:A}"; exit 0 ;;
    *) print -u2 "release: unknown argument $1"; exit 2 ;;
  esac
  shift
done

die() { print -u2 "release: $*"; exit 1 }
step() { print "\n── $*" }

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

version_in() { sed -nE 's/^ *MARKETING_VERSION: "?([^"]+)"?$/\1/p' "$1" }
build_in() { sed -nE 's/^ *CURRENT_PROJECT_VERSION: "?([^"]+)"?$/\1/p' "$1" }

if $local_build; then
  version=$(version_in project.yml)
  build=$(build_in project.yml)
  commit="the working tree"
  uncommitted=0
  out=".release/local"
  arch=$(uname -m)
else
commit=$(git rev-parse --short HEAD)
head_yml=$(mktemp)
git show HEAD:apps/macos/project.yml > "$head_yml"
version=$(version_in "$head_yml")
build=$(build_in "$head_yml")
rm "$head_yml"
[[ -n "$version" && -n "$build" ]] || die "no MARKETING_VERSION / CURRENT_PROJECT_VERSION in the committed project.yml"
tag="v$version"

if [[ "$(version_in project.yml)" != "$version" || "$(build_in project.yml)" != "$build" ]]; then
  die "project.yml says $(version_in project.yml) ($(build_in project.yml)) but the last commit says $version ($build) — commit the version bump first"
fi
uncommitted=$(git status --porcelain | wc -l | tr -d ' ')

published=$(curl -fsSL --max-time 10 -H 'Accept: application/vnd.github+json' \
  "https://api.github.com/repos/$repo/releases/latest" 2>/dev/null \
  | sed -nE 's/.*"tag_name": *"v?([^"]+)".*/\1/p' | head -1 || true)
if [[ -n "$published" ]] && ! is_newer "$version" "$published"; then
  die "$version is not above the published $published — scripts/bump-version.sh"
fi

out=".release/$version"
fi
rm -rf "$out"
mkdir -p "$out"

identity="${BOLTTY_SIGN_IDENTITY:-}"
notary="${BOLTTY_NOTARY_PROFILE:-}"
if [[ -z "$identity" ]]; then
  if security find-identity -v -p codesigning | grep -Fq '"Boltty Development"'; then
    identity="Boltty Development"
  else
    identity="-"
  fi
fi
developer_id=false
[[ "$identity" == "Developer ID Application:"* ]] && developer_id=true
$local_build && developer_id=false   # nothing to notarize: it never leaves this Mac
if $developer_id && [[ -z "$notary" ]]; then
  die "a Developer ID build needs BOLTTY_NOTARY_PROFILE (xcrun notarytool store-credentials)"
fi

if $local_build; then
  project="$app_dir"
else
repo_root=$(git rev-parse --show-toplevel)
src="$(mktemp -d)/boltty"
git -C "$repo_root" worktree add --detach --quiet "$src" HEAD
remove_worktree() { git -C "$repo_root" worktree remove --force "$src" 2>/dev/null || true }
trap remove_worktree EXIT
project="$src/apps/macos"
grep -q "MARKETING_VERSION = $version;" "$project/Boltty.xcodeproj/project.pbxproj" \
  || die "project.yml says $version and the committed pbxproj does not — run xcodegen generate and commit"
grep -q "CURRENT_PROJECT_VERSION = $build;" "$project/Boltty.xcodeproj/project.pbxproj" \
  || die "project.yml says build $build and the committed pbxproj does not — run xcodegen generate and commit"
fi

case "$arch" in
  universal) archs="arm64 x86_64" ;;
  arm64) archs="arm64" ;;
  x86_64) archs="x86_64" ;;
  *) die "--arch is arm64 or universal" ;;
esac
step "Building Boltty $version ($build) from $commit, $archs"
(( uncommitted > 0 )) && print "   $uncommitted uncommitted change(s) in the tree are not part of it"
# A DerivedData of its own: sharing `.derivedData` with ⌘R or another
# session's build locks its build database, and the release fails halfway.
derived="$app_dir/.release/DerivedData"
built="$derived/Build/Products/Release/Boltty.app"
# Only the binary: with the bundle gone an incremental build leaves out default.metallib.
rm -f "$built/Contents/MacOS/Boltty"
if ! xcodebuild -project "$project/Boltty.xcodeproj" -scheme Boltty -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$derived" \
  -clonedSourcePackagesDirPath "$app_dir/.derivedData/SourcePackages" \
  ARCHS="$archs" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  build > "$out/build.log" 2>&1; then
  grep -E 'error:' "$out/build.log" | head -20 >&2
  die "the build failed — $out/build.log"
fi
[[ -x "$built/Contents/MacOS/Boltty" ]] || die "the build produced no $built"
[[ -f "$built/Contents/Resources/default.metallib" ]] \
  || die "the app has no shaders: touch Sources/Boltty/Chat/UI/MascotShaders.metal and run this again"

app="$out/Boltty.app"
ditto "$built" "$app"

step "Signing with ${identity/#-/ad hoc}"
sign_flags=(--force --sign "$identity")
if $developer_id; then
  sign_flags+=(--options runtime --timestamp)
fi
for nested in "$app"/Contents/Frameworks/*(N); do
  codesign "${sign_flags[@]}" "$nested"
done
codesign "${sign_flags[@]}" --entitlements "$project/Boltty.entitlements" "$app"
codesign --verify --deep --strict "$app"

if $local_build; then
  installed=/Applications/Boltty.app
  if pgrep -xq Boltty; then
    step "Quitting the running Boltty"
    osascript -e 'tell application id "com.boltty.app" to quit' >/dev/null 2>&1 || true
    for _ in {1..30}; do pgrep -xq Boltty || break; sleep 0.5; done
    pgrep -xq Boltty && die "Boltty did not quit — quit it from the tray and run this again"
  fi
  step "Installing into Applications"
  rm -rf /Applications/Boltty.app
  ditto "$app" "$installed"
  open "$installed"
  print "  Boltty $version ($build) is in Applications and running."
  exit 0
fi

if $developer_id; then
  step "Notarizing the app"
  ditto -c -k --keepParent "$app" "$out/notarize.zip"
  xcrun notarytool submit "$out/notarize.zip" --keychain-profile "$notary" --wait
  rm "$out/notarize.zip"
  xcrun stapler staple "$app"
fi

step "Making the DMG"
dmg="$out/Boltty.dmg"
rm -f "$dmg"
staging="$out/dmg"
rw="$out/Boltty-rw.dmg"
rm -rf "$staging" "$rw"
mkdir -p "$staging/.background"
ditto "$app" "$staging/Boltty.app"
ln -s /Applications "$staging/Applications"
tiffutil -cathidpicheck Resources/DMG/background.png Resources/DMG/background@2x.png \
  -out "$staging/.background/background.tiff" >/dev/null 2>&1
cp "$app/Contents/Resources/AppIcon.icns" "$staging/.VolumeIcon.icns"

venv=.release/dmg-venv
if [[ ! -x $venv/bin/python ]]; then
  python3 -m venv $venv
  $venv/bin/pip install --quiet --disable-pip-version-check ds_store==1.3.1 mac_alias==2.2.2
fi

# `diskutil image` does not take a file system for a folder image yet.
quiet() { "$@" 2> >(grep -v "is deprecated" >&2) }
quiet hdiutil create -srcfolder "$staging" -volname "Boltty" -fs HFS+ -format UDRW -ov "$rw" >/dev/null
mount_dir=$(mktemp -d)
quiet hdiutil attach -nobrowse -noautoopen -mountpoint "$mount_dir" "$rw" >/dev/null
$venv/bin/python -I scripts/make-dmg-layout.py "$mount_dir"
# The volume icon only. Hiding the app's extension writes Finder info onto the
# signed bundle, and `codesign --strict` (Gatekeeper too) then calls it damaged.
SetFile -a C "$mount_dir"
quiet hdiutil detach "$mount_dir" >/dev/null
quiet hdiutil convert "$rw" -format UDZO -imagekey zlib-level=9 -o "$dmg" >/dev/null
quiet hdiutil attach -nobrowse -noautoopen -readonly -mountpoint "$mount_dir" "$dmg" >/dev/null
codesign --verify --deep --strict "$mount_dir/Boltty.app" \
  || { quiet hdiutil detach "$mount_dir" >/dev/null; echo "The app in the DMG fails codesign --verify." >&2; exit 1; }
quiet hdiutil detach "$mount_dir" >/dev/null
rm -rf "$staging" "$rw"
rmdir "$mount_dir" 2>/dev/null || true
if [[ "$identity" != "-" ]]; then
  dmg_flags=(--force --sign "$identity")
  $developer_id && dmg_flags+=(--timestamp)
  codesign "${dmg_flags[@]}" "$dmg"
fi
if $developer_id; then
  step "Notarizing the DMG"
  xcrun notarytool submit "$dmg" --keychain-profile "$notary" --wait
  xcrun stapler staple "$dmg"
  spctl --assess --type open --context context:primary-signature -v "$dmg"
fi

sha=$(shasum -a 256 "$dmg" | awk '{print $1}')
print "$sha  Boltty.dmg" > "$out/Boltty.dmg.sha256"

step "Checking install.sh takes it"
trial=$(mktemp -d)
BOLTTY_DMG="$dmg" BOLTTY_INSTALL_DIR="$trial" sh "$app_dir/../../install.sh" >/dev/null \
  || { rm -rf "$trial"; die "install.sh refuses this DMG: is its requirement still the signing identity's?" }
rm -rf "$trial"

step "Done: $out"
print "  Boltty.dmg      $(du -h "$dmg" | awk '{print $1}'), sha256 $sha"
if ! $developer_id; then
  print "\n  Not notarized: the first open needs System Settings › Privacy & Security › Open Anyway."
fi
print "\nTo publish (nothing above has left this Mac):"
print "  git tag $tag $commit && git push origin main $tag"
print "  gh release create $tag $out/Boltty.dmg $out/Boltty.dmg.sha256 --repo $repo --title \"Boltty $version\" --generate-notes"
