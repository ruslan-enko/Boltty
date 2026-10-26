#!/usr/bin/env python3
"""Lays out the DMG's window: writes .DS_Store into the mounted disk.

    make-dmg-layout.py /Volumes/Boltty

660 × 400, no toolbar, sidebar or path bar; icons at 128, Boltty at
(170, 190) and the Applications link at (490, 190), over
.background/background.tiff. release.sh runs it on the writable image
before compressing it.

Written down rather than asked of Finder: on macOS 27 Finder took the
window's size from AppleScript (create-dmg's way) and dropped the icon size,
the order and the background. And written on the disk itself, every time:
the background is found through an alias, which names that very volume —
one made on another disk and copied in left the window plain.

It needs ds_store and mac_alias (MIT, the dmgbuild author's); release.sh
installs them, pinned, into apps/macos/.release/dmg-venv.
"""

import os
import sys

from ds_store import DSStore
from mac_alias import Alias

# The background is 660 × 400. WindowBounds is the whole window, title bar
# included (32 pt on macOS 27), so the window is that much taller. Finder may
# still add a status bar from the person's own settings; it covers the
# background's foot, which is why the caption stands 58 pt up.
WINDOW = (660, 400 + 32)
ICONS = {"Boltty.app": (170, 190), "Applications": (490, 190)}

volume = sys.argv[1]
background = os.path.join(volume, ".background", "background.tiff")

with DSStore.open(os.path.join(volume, ".DS_Store"), "w+") as d:
    d["."]["bwsp"] = {
        "ShowStatusBar": False,
        "ShowPathbar": False,
        "ShowToolbar": False,
        "ShowTabView": False,
        "ShowSidebar": False,
        "ContainerShowSidebar": False,
        "WindowBounds": "{{200, 500}, {%d, %d}}" % WINDOW,
    }
    d["."]["icvp"] = {
        "viewOptionsVersion": 1,
        "backgroundType": 2,
        "backgroundImageAlias": Alias.for_file(background).to_bytes(),
        "backgroundColorRed": 1.0,
        "backgroundColorGreen": 1.0,
        "backgroundColorBlue": 1.0,
        "gridOffsetX": 0.0,
        "gridOffsetY": 0.0,
        "gridSpacing": 100.0,
        "arrangeBy": "none",
        "showIconPreview": False,
        "showItemInfo": False,
        "labelOnBottom": True,
        "textSize": 13.0,
        "iconSize": 128.0,
        "scrollPositionX": 0.0,
        "scrollPositionY": 0.0,
    }
    d["."]["vSrn"] = ("long", 1)
    for name, position in ICONS.items():
        d[name]["Iloc"] = position
