# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.
"""Tests of scripts/make-dmg.sh on a small made-up app, in a folder with a space in its name."""
import hashlib
import json
import os
import plistlib
import re
import shutil
import stat
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent.parent
SCRIPT = ROOT / "scripts" / "make-dmg.sh"
VENV_PYTHON = ROOT / "build" / "dmgbuild" / "bin" / "python"
# What DiskImageCheck.onlyApp of Stelix 1.0.0 accepts at the top of the image, besides the app.
ACCEPTED = {"Stelix.app", "Applications", ".DS_Store", ".VolumeIcon.icns", ".background", ".fseventsd", ".Trashes"}


def make_app(folder: Path) -> Path:
    app = folder / "Stelix.app"
    (app / "Contents" / "MacOS").mkdir(parents=True)
    (app / "Contents" / "Resources").mkdir()
    (app / "Contents" / "Resources" / "note.txt").write_text("resource\n")
    with open(app / "Contents" / "Info.plist", "wb") as f:
        plistlib.dump({"CFBundleIdentifier": "io.example.fake", "CFBundleExecutable": "Stelix",
                       "CFBundleShortVersionString": "9.9.9", "CFBundleVersion": "1",
                       "CFBundlePackageType": "APPL"}, f)
    shutil.copy("/usr/bin/true", app / "Contents" / "MacOS" / "Stelix")
    subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True, capture_output=True)
    return app


def run_script(*args: str, env: dict | None = None) -> subprocess.CompletedProcess:
    return subprocess.run([str(SCRIPT), *args], capture_output=True, text=True,
                          env={**os.environ, **(env or {})})


@pytest.fixture(scope="module")
def mounted(tmp_path_factory):
    folder = tmp_path_factory.mktemp("dmg") / "with space"
    folder.mkdir()
    app = make_app(folder)
    dmg = folder / "Stelix.dmg"
    result = run_script(str(app), "Stelix 9.9.9", str(dmg))
    assert result.returncode == 0, result.stderr
    mount = folder / "mount"
    mount.mkdir()
    subprocess.run(["hdiutil", "attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", str(mount),
                    str(dmg)], check=True, capture_output=True, stdin=subprocess.DEVNULL)
    yield mount
    subprocess.run(["hdiutil", "detach", str(mount)], capture_output=True)


def test_volume_name(mounted):
    info = plistlib.loads(subprocess.run(["diskutil", "info", "-plist", str(mounted)],
                                         capture_output=True, check=True).stdout)
    assert info["VolumeName"] == "Stelix 9.9.9"


def test_root_holds_only_what_the_update_check_accepts(mounted):
    names = {p.name for p in mounted.iterdir()}
    assert names <= ACCEPTED, names - ACCEPTED
    assert [n for n in names if n.endswith(".app")] == ["Stelix.app"]
    link = mounted / "Applications"
    assert link.is_symlink() and os.readlink(link) == "/Applications"
    background = mounted / ".background"
    assert [p.name for p in background.iterdir()] == ["background.tiff"]
    tiff = background / "background.tiff"
    assert tiff.is_file() and not tiff.is_symlink()
    assert not tiff.stat().st_mode & (stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    # Folders Finder or the system may add: the check accepts them with plain files only.
    for name in (".fseventsd", ".Trashes"):
        for entry in (mounted / name).iterdir() if (mounted / name).is_dir() else []:
            assert entry.is_file() and not entry.is_symlink(), entry
            assert not entry.stat().st_mode & (stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH), entry


def test_volume_icon_is_stelix(mounted):
    assert (mounted / ".VolumeIcon.icns").read_bytes() == (ROOT / "App/Resources/AppIcon.icns").read_bytes()


def test_background_is_the_drawn_one(mounted):
    drawn = (ROOT / "scripts/dmg/background.tiff").read_bytes()
    assert (mounted / ".background/background.tiff").read_bytes() == drawn


def read_ds_store(path: Path) -> dict:
    code = """import json, sys
from ds_store import DSStore
out = {}
with DSStore.open(sys.argv[1], "r") as store:
    for entry in store:
        code = entry.code.decode() if isinstance(entry.code, bytes) else entry.code
        out.setdefault(entry.filename, {})[code] = entry.value
print(json.dumps(out, default=lambda v: v.hex() if isinstance(v, bytes) else repr(v)))
"""
    result = subprocess.run([str(VENV_PYTHON), "-I", "-c", code, str(path)], capture_output=True, text=True,
                            check=True)
    return json.loads(result.stdout)


def test_window_layout(mounted):
    store = read_ds_store(mounted / ".DS_Store")
    view = store["."]["icvp"]
    assert view["backgroundType"] == 2
    assert view["backgroundImageAlias"]
    assert view["iconSize"] == 128
    assert view["textSize"] == 13
    window = store["."]["bwsp"]
    assert window["WindowBounds"] == "{{400, 400}, {660, 440}}"
    for bar in ("ShowToolbar", "ShowSidebar", "ShowStatusBar", "ShowPathbar", "ShowTabView"):
        assert window[bar] is False, bar
    assert store["Stelix.app"]["Iloc"] == [170, 211]
    assert store["Applications"]["Iloc"] == [490, 211]


def test_nothing_scrolls_with_every_finder_bar(mounted):
    """Finder ignores the window's own bar settings and follows the user's: measured on macOS 27 on
    2026-11-27, the title bar takes 32 pt, and the tab bar and path bar another 64 when the user keeps
    them on. The content scrolls once the icons' frames, labels included, reach 124 pt below their
    centers: they must fit in the smaller of the two heights, and the background must cover the larger."""
    store = read_ds_store(mounted / ".DS_Store")
    height = int(store["."]["bwsp"]["WindowBounds"].rsplit(", ", 1)[1].rstrip("}"))
    lowest = max(store[name]["Iloc"][1] for name in ("Stelix.app", "Applications"))
    assert lowest + 124 <= height - 32 - 64
    tiff = subprocess.run(["/usr/bin/tiffutil", "-info", str(mounted / ".background/background.tiff")],
                          capture_output=True, text=True, check=True).stdout
    assert f"Image Length: {height - 32}" in tiff


def test_background_alias_points_into_the_folder(mounted):
    code = """import sys
from ds_store import DSStore
from mac_alias import Alias
with DSStore.open(sys.argv[1], "r") as store:
    alias = Alias.from_bytes(store["."]["icvp"]["backgroundImageAlias"])
print(alias.target.folder_name, alias.target.filename, alias.target.posix_path, sep="\\n")
"""
    result = subprocess.run([str(VENV_PYTHON), "-I", "-c", code, str(mounted / ".DS_Store")],
                            capture_output=True, text=True, check=True)
    folder, filename, posix = result.stdout.splitlines()
    assert (folder, filename) == (".background", "background.tiff")
    assert posix == "/.background/background.tiff"


def test_signature_survives_the_copy(mounted):
    app = mounted / "Stelix.app"
    subprocess.run(["codesign", "--verify", "--strict", "--deep", str(app)], check=True, capture_output=True)
    assert os.access(app / "Contents/MacOS/Stelix", os.X_OK)


def test_venv_rebuilt_when_requirements_change(tmp_path):
    """Builds a venv of its own: needs the network or uv's cache."""
    app = make_app(tmp_path)
    venv = tmp_path / "venv"
    first = tmp_path / "first.txt"
    shutil.copy(ROOT / "scripts/dmg/requirements.txt", first)
    env = {"STELIX_DMG_VENV": str(venv), "STELIX_DMG_REQUIREMENTS": str(first)}
    assert run_script(str(app), "Test", str(tmp_path / "a.dmg"), env=env).returncode == 0
    marker = venv / "marker"
    marker.write_text("")

    second = tmp_path / "second.txt"
    second.write_text(first.read_text() + "# changed\n")
    env["STELIX_DMG_REQUIREMENTS"] = str(second)
    assert run_script(str(app), "Test", str(tmp_path / "b.dmg"), env=env).returncode == 0
    assert not marker.exists()
    stamp = (venv / "requirements.sha256").read_text().strip()
    assert stamp == hashlib.sha256(second.read_bytes()).hexdigest()


def test_venv_rebuilt_when_its_python_is_gone(tmp_path):
    """A matching stamp is not enough: a venv whose interpreter went away is made again.
    Builds a venv of its own: needs the network or uv's cache."""
    app = make_app(tmp_path)
    venv = tmp_path / "venv"
    env = {"STELIX_DMG_VENV": str(venv)}
    assert run_script(str(app), "Test", str(tmp_path / "a.dmg"), env=env).returncode == 0
    (venv / "bin" / "python").unlink()
    result = run_script(str(app), "Test", str(tmp_path / "b.dmg"), env=env)
    assert result.returncode == 0, result.stderr
    assert (tmp_path / "b.dmg").is_file()
    # The venv runs on uv's Python 3.12, as the sidecar does.
    assert re.search(r"^version_info = 3\.12\b", (venv / "pyvenv.cfg").read_text(), re.M)


def test_explains_a_missing_uv(tmp_path):
    app = make_app(tmp_path)
    env = {"STELIX_DMG_VENV": str(tmp_path / "venv"), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"}
    result = run_script(str(app), "Test", str(tmp_path / "a.dmg"), env=env)
    assert result.returncode == 69
    assert "needs uv" in result.stderr


def test_accepts_an_app_path_ending_in_a_slash(tmp_path):
    app = make_app(tmp_path)
    out = tmp_path / "out.dmg"
    result = run_script(str(app) + "/", "Test", str(out))
    assert result.returncode == 0, result.stderr
    assert out.is_file()


def test_refuses_missing_app(tmp_path):
    out = tmp_path / "out.dmg"
    result = run_script(str(tmp_path / "missing.app"), "X", str(out))
    assert result.returncode != 0
    assert result.stderr.strip()
    assert not out.exists()
