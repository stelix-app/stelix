# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.
"""Tests of scripts/check-dmg.sh: the release DMG must pass the update check of Stelix 1.0.0."""
import os
import plistlib
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent.parent
CHECK = ROOT / "scripts" / "check-dmg.sh"
MAKE = ROOT / "scripts" / "make-dmg.sh"
REQUIREMENT = 'identifier "io.example.fake"'


def make_app(folder: Path, version: str = "9.9.9") -> Path:
    app = folder / "Stelix.app"
    (app / "Contents" / "MacOS").mkdir(parents=True)
    with open(app / "Contents" / "Info.plist", "wb") as f:
        plistlib.dump({"CFBundleIdentifier": "io.example.fake", "CFBundleExecutable": "Stelix",
                       "CFBundleShortVersionString": version, "CFBundleVersion": "1",
                       "CFBundlePackageType": "APPL"}, f)
    shutil.copy("/usr/bin/true", app / "Contents" / "MacOS" / "Stelix")
    subprocess.run(["codesign", "--force", "--sign", "-", "--identifier", "io.example.fake", str(app)],
                   check=True, capture_output=True)
    return app


def staged_dmg(folder: Path, extra=None) -> Path:
    """A DMG made by hand from a folder holding the app, the Applications link and `extra(stage)`."""
    stage = folder / "stage"
    stage.mkdir()
    make_app(stage)
    os.symlink("/Applications", stage / "Applications")
    if extra:
        extra(stage)
    dmg = folder / "hand.dmg"
    subprocess.run(["hdiutil", "create", "-quiet", "-volname", "Stelix 9.9.9", "-srcfolder", str(stage),
                    "-format", "UDZO", "-ov", str(dmg)], check=True, capture_output=True)
    return dmg


def check(dmg: Path, version: str = "9.9.9", requirement: str = REQUIREMENT) -> subprocess.CompletedProcess:
    return subprocess.run([str(CHECK), str(dmg), version, requirement], capture_output=True, text=True)


@pytest.fixture(scope="module")
def good_dmg(tmp_path_factory):
    folder = tmp_path_factory.mktemp("good") / "with space"
    folder.mkdir()
    app = make_app(folder)
    dmg = folder / "Stelix.dmg"
    result = subprocess.run([str(MAKE), str(app), "Stelix 9.9.9", str(dmg)], capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    return dmg


def test_accepts_the_dmg_make_dmg_builds(good_dmg):
    result = check(good_dmg)
    assert result.returncode == 0, result.stderr


def test_leaves_nothing_mounted(good_dmg):
    check(good_dmg)
    info = subprocess.run(["hdiutil", "info"], capture_output=True, text=True, check=True).stdout
    assert str(good_dmg) not in info


def test_refuses_another_version(good_dmg):
    result = check(good_dmg, version="9.9.10")
    assert result.returncode != 0
    assert "version" in result.stderr


def test_refuses_another_signer(good_dmg):
    result = check(good_dmg, requirement='identifier "io.example.other"')
    assert result.returncode != 0
    assert "signature" in result.stderr


def test_refuses_an_extra_file_at_the_top(tmp_path):
    dmg = staged_dmg(tmp_path, lambda stage: (stage / ".TemporaryItems").mkdir())
    result = check(dmg)
    assert result.returncode != 0
    assert ".TemporaryItems" in result.stderr


def test_refuses_an_executable_in_an_allowed_folder(tmp_path):
    def extra(stage):
        (stage / ".background").mkdir()
        script = stage / ".background" / "run.sh"
        script.write_text("#!/bin/sh\n")
        script.chmod(0o755)
    result = check(staged_dmg(tmp_path, extra))
    assert result.returncode != 0
    assert ".background" in result.stderr


def test_refuses_a_subfolder_in_an_allowed_folder(tmp_path):
    result = check(staged_dmg(tmp_path, lambda stage: (stage / ".Trashes" / "501").mkdir(parents=True)))
    assert result.returncode != 0
    assert ".Trashes" in result.stderr


def test_refuses_an_applications_link_elsewhere(tmp_path):
    def extra(stage):
        (stage / "Applications").unlink()
        os.symlink("/tmp", stage / "Applications")
    result = check(staged_dmg(tmp_path, extra))
    assert result.returncode != 0
    assert "Applications" in result.stderr
