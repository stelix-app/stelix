# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.
# dmgbuild settings for scripts/make-dmg.sh, which passes the paths in `defines`.
# The icon positions match scripts/make-dmg-background.swift: the app centered at (170, 211) and
# Applications at (490, 211), from the top left of the content. Finder ignores the bar settings below
# when the user keeps a bar on for every window: measured on macOS 27, the title bar takes 32 pt and
# the tab and path bars another 64, so the 440 pt window leaves 408 pt for the content (the height of
# the background) or 344 pt, where the icons and their labels still fit without scrolling.
# The window's origin is its bottom left corner, from the bottom left of the screen.
# dmgbuild runs this file with `defines` already set.
# ruff: noqa: F821
import os.path

app = defines["app"]
name = os.path.basename(app.rstrip("/"))

# The same format as Stelix 1.0.0's image, which its update check accepts.
format = "UDZO"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = defines["icon"]
background = defines["background"]

window_rect = ((400, 400), (660, 440))
default_view = "icon-view"
show_toolbar = False
show_sidebar = False
show_status_bar = False
show_pathbar = False
show_tab_view = False
icon_size = 128
text_size = 13
icon_locations = {name: (170, 211), "Applications": (490, 211)}
