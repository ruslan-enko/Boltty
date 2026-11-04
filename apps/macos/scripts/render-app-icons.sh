#!/bin/sh
# Renders the icons Settings can choose (`AppIconChoice`) from their Icon
# Composer files, with Xcode's ictool. Run it after changing an AppIcon*.icon.
set -eu
cd "$(dirname "$0")/.."
ictool="$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool"
out=Resources/AppIcons
mkdir -p "$out"
render() {
  "$ictool" "$1" --export-image --output-file "$out/$2.png" \
    --platform macOS --rendition Default --width 512 --height 512 --scale 1
}
render "AppIcon.icon" default
render "AppIcon C.icon" citrus
render "AppIcon P.icon" pastel
render "AppIcon R.icon" sunset
