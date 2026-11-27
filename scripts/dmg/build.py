# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.
"""Runs dmgbuild for scripts/make-dmg.sh, then moves the background into a .background folder.

dmgbuild puts the background at the top of the image as `.background.tiff`. Stelix 1.0.0 checks every
update before opening it and refuses an image with any file at the top besides the app, the
Applications link, `.DS_Store` and `.VolumeIcon.icns`: the background must sit in `.background/`.
So once dmgbuild has written `.DS_Store`, while the image is still mounted and writable, the file
moves there and the window's settings get an alias to its new place.

Usage: build.py <settings.py> <app> <background> <volume icon> <volume name> <output dmg>
Runs inside build/dmgbuild, the virtual environment make-dmg.sh sets up.
"""
import os
import sys

from dmgbuild import build_dmg
from ds_store import DSStore
from mac_alias import Alias

FOLDER = ".background"


class Mover:
    def __init__(self, app_name: str):
        self.app_name = app_name
        self.mount_point: str | None = None
        self.moved = False

    def __call__(self, info: dict) -> None:
        kind, operation = info.get("type"), info.get("operation")
        if kind == "error::fatal":
            print(f"Error: {info.get('message')}", file=sys.stderr)
        elif kind == "operation::start" and operation == "file::add":
            path = info["file"]
            if os.path.basename(path) == self.app_name:
                self.mount_point = os.path.dirname(path)
        elif kind == "operation::finished" and operation == "dsstore::create":
            self.move_background()

    def move_background(self) -> None:
        if self.mount_point is None:
            raise RuntimeError("dmgbuild never said where the image is mounted")
        names = [n for n in os.listdir(self.mount_point) if n.startswith(".background.")]
        if len(names) != 1:
            raise RuntimeError(f"expected one background at the top of the image, found {names}")
        folder = os.path.join(self.mount_point, FOLDER)
        os.mkdir(folder)
        target = os.path.join(folder, "background" + os.path.splitext(names[0])[1])
        os.rename(os.path.join(self.mount_point, names[0]), target)
        os.chmod(target, 0o644)
        with DSStore.open(os.path.join(self.mount_point, ".DS_Store"), "r+") as store:
            view = store["."]["icvp"]
            view["backgroundImageAlias"] = Alias.for_file(target).to_bytes()
            store["."]["icvp"] = view
        self.moved = True


def main(argv: list[str]) -> int:
    if len(argv) != 7:
        print(__doc__, file=sys.stderr)
        return 64
    settings, app, background, icon, volume, output = argv[1:]
    mover = Mover(os.path.basename(app.rstrip("/")))
    build_dmg(output, volume, settings_file=settings,
              defines={"app": app, "background": background, "icon": icon}, callback=mover)
    if not mover.moved:
        print("Error: the background was not moved into .background", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
