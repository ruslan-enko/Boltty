#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

derived=.derivedData
xcodebuild -project Boltty.xcodeproj -scheme Boltty -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath "$derived" build -quiet

objects="$derived/Build/Intermediates.noindex/Boltty.build/Debug/Boltty.build/Objects-normal"
arch=$(ls "$objects" | head -n 1)
set --
for file in "$objects/$arch"/*.stringsdata; do
  set -- "$@" --stringsdata "$file"
done
[ $# -gt 0 ] || { echo "no .stringsdata in $objects/$arch" >&2; exit 1; }

xcrun xcstringstool sync Resources/Localizable.xcstrings "$@"
echo "Synced $(xcrun xcstringstool print Resources/Localizable.xcstrings | grep -c . || true) lines of keys."
