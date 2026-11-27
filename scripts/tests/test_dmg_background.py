# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.
"""The background of the disk image window, drawn by scripts/make-dmg-background.swift."""
import re
import struct
import subprocess
from pathlib import Path

BACKGROUND = Path(__file__).resolve().parent.parent / "dmg" / "background.tiff"


def test_background_is_retina_tiff():
    info = subprocess.run(["/usr/bin/tiffutil", "-info", str(BACKGROUND)],
                          capture_output=True, text=True, check=True).stdout
    sizes = re.findall(r"Image Width: (\d+) Image Length: (\d+)", info)
    assert [(int(w), int(h)) for w, h in sizes] == [(660, 408), (1320, 816)]


def test_background_is_light(tmp_path):
    bmp = tmp_path / "background.bmp"
    subprocess.run(["/usr/bin/sips", "-s", "format", "bmp", str(BACKGROUND), "--out", str(bmp)],
                   capture_output=True, check=True)
    data = bmp.read_bytes()
    offset = struct.unpack_from("<I", data, 10)[0]
    width, height = struct.unpack_from("<ii", data, 18)
    bits = struct.unpack_from("<H", data, 28)[0]
    step = bits // 8
    row = (width * step + 3) // 4 * 4
    # Rows go bottom up unless the height is negative: the top left pixel.
    top = offset + (height - 1) * row if height > 0 else offset
    blue, green, red = data[top], data[top + 1], data[top + 2]
    for got, want in zip((red, green, blue), (0xF2, 0xF2, 0xF7)):
        assert abs(got - want) <= 2, (red, green, blue)
