#!/bin/sh
# Builds Boltty Design and opens it; `-boltty.design.page "Chat list"` opens a page.
set -e
cd "$(dirname "$0")"
command -v xcodegen >/dev/null || { echo "Boltty Design needs XcodeGen: brew install xcodegen" >&2; exit 1; }
xcodegen generate -q
if ! xcodebuild -project BolttyDesign.xcodeproj -scheme BolttyDesign -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath .derivedData -quiet build >.build.log 2>&1
then
  grep -E 'error:' .build.log
  exit 1
fi
open -n ".derivedData/Build/Products/Debug/Boltty Design.app" --args "$@"
