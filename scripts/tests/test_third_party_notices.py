# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.
"""Tests of scripts/third-party-notices.py on small made-up trees."""
import hashlib
import importlib.util
import json
import tarfile
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parent.parent / "third-party-notices.py"
spec = importlib.util.spec_from_file_location("third_party_notices", SCRIPT)
tpn = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tpn)

MIT = "MIT License\n\nCopyright (c) 2026 {who}\n\nPermission is hereby granted, free of charge...\n"
APACHE = "Apache License\nVersion 2.0, January 2004\n" + "terms and conditions\n" * 120


def write(path: Path, text: str = "") -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    return path


def resolved(tmp_path: Path, *identities: str) -> Path:
    pins = [{"identity": i, "location": f"https://example.com/{i}.git",
             "state": {"revision": "abc1234def", "version": "1.2.3"}} for i in identities]
    return write(tmp_path / "Package.resolved", json.dumps({"pins": pins}))


def dist(site: Path, name: str, version: str, license_files: dict, record: list = ()) -> Path:
    info = site / f"{name.replace('-', '_')}-{version}.dist-info"
    write(info / "METADATA", f"Metadata-Version: 2.4\nName: {name}\nVersion: {version}\nLicense: MIT\n"
                             f"Project-URL: Source, https://example.com/{name}\n\nLong description\n")
    for rel, text in license_files.items():
        write(info / "licenses" / rel, text)
    write(info / "RECORD", "".join(f"{r},,\n" for r in record))
    return info


# --- Swift packages ---------------------------------------------------------------------------------

def test_swift_package_missing_from_manifest_is_an_error(tmp_path):
    write(tmp_path / "checkouts/newcomer/LICENSE", MIT.format(who="A"))
    with pytest.raises(tpn.Problem, match="newcomer"):
        tpn.swift_components(resolved(tmp_path, "newcomer"), tmp_path / "checkouts", {"swift": {}})


def test_shipped_swift_package_without_license_file_is_an_error(tmp_path):
    (tmp_path / "checkouts/bare").mkdir(parents=True)
    manifest = {"swift": {"bare": {"license": "MIT", "shipped": True}}}
    with pytest.raises(tpn.Problem, match="bare.*no license file"):
        tpn.swift_components(resolved(tmp_path, "bare"), tmp_path / "checkouts", manifest)


def test_swift_package_carries_license_notice_and_bundled_parts(tmp_path):
    co = tmp_path / "checkouts"
    write(co / "kit/LICENSE.txt", APACHE)
    write(co / "kit/NOTICE.txt", "This product contains bits of Other.")
    write(co / "kit/Vendor/fmt/LICENSE", MIT.format(who="fmt authors"))
    write(co / "tool/LICENSE", MIT.format(who="Tool"))
    manifest = {"swift": {
        "kit": {"license": "Apache-2.0", "shipped": True, "bundled": [
            {"name": "fmt", "license": "MIT", "url": "https://example.com/fmt", "files": ["Vendor/fmt/LICENSE"]}]},
        "tool": {"license": "MIT", "shipped": False, "why": "command-line tools only"}}}
    shipped, build_only = tpn.swift_components(resolved(tmp_path, "kit", "tool"), co, manifest)
    assert [c.name for c in shipped] == ["kit", "fmt"]
    assert shipped[0].version == "1.2.3" and shipped[0].url == "https://example.com/kit"
    assert [label for label, _ in shipped[0].texts] == ["LICENSE.txt", "NOTICE.txt"]
    assert shipped[1].inside == "kit" and "fmt authors" in shipped[1].texts[0][1]
    assert [(c.name, c.note) for c in build_only] == [("tool", "command-line tools only")]


# --- Python packages --------------------------------------------------------------------------------

def test_python_package_without_license_file_is_an_error(tmp_path):
    dist(tmp_path, "nolicense", "0.1", {})
    with pytest.raises(tpn.Problem, match="nolicense.*no license file"):
        tpn.python_components(tmp_path)


def test_python_package_reads_metadata_and_every_license_file(tmp_path):
    dist(tmp_path, "some-pkg", "2.0", {"LICENSE": MIT.format(who="Some"), "vendor/x/LICENSE.md": "x terms"})
    [c] = tpn.python_components(tmp_path)
    assert (c.name, c.version, c.license, c.url) == ("some-pkg", "2.0", "MIT", "https://example.com/some-pkg")
    assert [label for label, _ in c.texts] == ["LICENSE", "vendor/x/LICENSE.md"]


# --- Safety nets on the sidecar tree ----------------------------------------------------------------

def test_bundled_dynamic_library_nobody_claims_is_an_error(tmp_path):
    site = tmp_path / "site-packages"
    dist(site, "audio", "1.0", {"LICENSE": MIT.format(who="A")},
         record=["audio/_core.so", "audio/.dylibs/libfoo.1.dylib"])
    write(site / "audio/_core.so")
    write(site / "audio/.dylibs/libfoo.1.dylib")
    with pytest.raises(tpn.Problem, match=r"libfoo\.1\.dylib"):
        tpn.check_binaries(tmp_path, [])
    tpn.check_binaries(tmp_path, ["site-packages/audio/.dylibs/libfoo.*.dylib"])


def test_binary_outside_any_package_record_is_an_error(tmp_path):
    write(tmp_path / "python/lib/libextra.dylib")
    with pytest.raises(tpn.Problem, match="libextra.dylib"):
        tpn.check_binaries(tmp_path, [])


def test_notice_file_inside_a_package_that_the_manifest_ignores_is_an_error(tmp_path):
    site = tmp_path / "site-packages"
    write(site / "audio/THIRD_PARTY_NOTICES.md", "bundles libfoo")
    write(site / "audio/licenses/libfoo/COPYING", "LGPL")
    with pytest.raises(tpn.Problem, match="THIRD_PARTY_NOTICES.md"):
        tpn.check_notice_files(site, referenced=set(), ignored=[])
    tpn.check_notice_files(site, referenced={site / "audio/licenses/libfoo/COPYING"},
                           ignored=["audio/THIRD_PARTY_NOTICES.md"])


# --- Components the build tree does not describe ----------------------------------------------------

def test_extra_component_fails_when_its_host_package_changed_version(tmp_path):
    write(tmp_path / "third-party/licenses/lame.txt", "LGPL text")
    extra = [{"name": "LAME", "version": "3.100", "license": "LGPL-2.0-or-later", "url": "https://example.com",
              "inside": "audio", "with": {"audio": "1.0"}, "files": ["third-party/licenses/lame.txt"]}]
    [c] = tpn.extra_components(extra, tmp_path, {"audio": "1.0"})
    assert (c.name, c.inside, c.texts) == ("LAME", "audio", [("lame.txt", "LGPL text")])
    with pytest.raises(tpn.Problem, match="LAME.*audio 1.1"):
        tpn.extra_components(extra, tmp_path, {"audio": "1.1"})


def test_extra_component_with_a_missing_file_is_an_error(tmp_path):
    extra = [{"name": "ghost", "license": "MIT", "url": "u", "inside": "x", "files": ["third-party/licenses/ghost.txt"]}]
    with pytest.raises(tpn.Problem, match="ghost.txt"):
        tpn.extra_components(extra, tmp_path, {})


# --- What is really linked --------------------------------------------------------------------------

def test_probe_catches_a_build_only_package_that_got_linked():
    manifest = {"swift": {"kit": {"shipped": True, "probe": "$s3Kit"},
                          "tool": {"shipped": False, "probe": "$s4Tool"}}}
    tpn.check_probes("0000 T _$s3KitAAVMa\n", manifest)
    with pytest.raises(tpn.Problem, match="tool.*is linked"):
        tpn.check_probes("0000 T _$s3KitAAVMa\n0000 T _$s4ToolAAVMa\n", manifest)
    with pytest.raises(tpn.Problem, match="kit.*not linked"):
        tpn.check_probes("0000 T _main\n", manifest)


# --- Rendering --------------------------------------------------------------------------------------

def test_fence_is_longer_than_any_backtick_run_in_the_text():
    assert tpn.fence("plain") == "```"
    assert tpn.fence("has ``` inside and ````` too") == "``````"


def test_text_shared_by_several_components_is_printed_once():
    a = tpn.Component("a", "1", "Apache-2.0", "u", [("LICENSE", APACHE)])
    b = tpn.Component("b", "1", "Apache-2.0", "u", [("LICENSE.txt", APACHE.replace("\n", "\n  "))])
    c = tpn.Component("c", "1", "MIT", "u", [("LICENSE", MIT.format(who="C"))])
    out = tpn.render([("Swift packages", "", [a, b, c])], [], preamble="")
    assert out.count(APACHE) == 1 and "\n  terms and conditions" not in out
    assert out.count("](#shared-text-1)") == 2
    assert "Copyright (c) 2026 C" in out


def test_shared_texts_with_the_same_title_say_which_component_they_come_from():
    other = APACHE + "Runtime Library Exception\n"
    plain = "# Contributors\n" + "someone\n" * 60
    comps = [tpn.Component(n, "1", "Apache-2.0", "u", [("LICENSE", t)])
             for n, t in [("a", APACHE), ("b", APACHE), ("c", other), ("d", other)]]
    comps += [tpn.Component(n, "1", "MIT", "u", [("ACKNOWLEDGMENTS.md", plain)]) for n in ("e", "f")]
    out = tpn.render([("Swift packages", "", comps)], [], preamble="")
    assert "### Apache License 2.0, as distributed with a\n" in out
    assert "### Apache License 2.0, as distributed with c\n" in out
    assert "### ACKNOWLEDGMENTS.md, as distributed with e\n" in out


def test_render_is_stable_and_lists_build_only_packages_without_their_text():
    a = tpn.Component("a", "1", "MIT", "https://example.com/a", [("LICENSE", MIT.format(who="A"))])
    t = tpn.Component("tool", "9", "MIT", "https://example.com/tool", [], note="command-line tools only")
    one = tpn.render([("Swift packages", "", [a])], [t], preamble="Intro.")
    assert one == tpn.render([("Swift packages", "", [a])], [t], preamble="Intro.")
    assert "| a | 1 | MIT |" in one
    assert "command-line tools only" in one and one.endswith("\n")


# --- The command ------------------------------------------------------------------------------------

def test_check_mode_fails_when_the_committed_file_is_stale(tmp_path):
    out = write(tmp_path / "NOTICES.md", "old")
    assert tpn.write_or_check("new\n", out, check=True) == 1
    assert out.read_text() == "old"
    assert tpn.write_or_check("new\n", out, check=False) == 0
    assert tpn.write_or_check("new\n", out, check=True) == 0


# --- Source of the LGPL libraries -------------------------------------------------------------------

def lgpl_manifest(payload: bytes) -> list:
    return [{"name": "libfoo", "file": "libfoo-1.0.tar.gz", "url": "https://example.com/libfoo-1.0.tar.gz",
             "sha256": hashlib.sha256(payload).hexdigest(), "with": {"audio": "1.0"}}]


def test_lgpl_sources_archive_holds_the_verified_downloads_and_a_readme(tmp_path):
    out = tmp_path / "sources.tar.gz"
    tpn.lgpl_sources(lgpl_manifest(b"source"), {"audio": "1.0"}, out, "Read me.",
                     fetch=lambda url, dest: dest.write_bytes(b"source"))
    with tarfile.open(out) as tar:
        assert sorted(tar.getnames()) == ["README.txt", "libfoo-1.0.tar.gz"]
        assert tar.extractfile("libfoo-1.0.tar.gz").read() == b"source"


def test_lgpl_sources_refuses_a_download_with_the_wrong_hash(tmp_path):
    with pytest.raises(tpn.Problem, match="libfoo-1.0.tar.gz.*SHA-256"):
        tpn.lgpl_sources(lgpl_manifest(b"source"), {"audio": "1.0"}, tmp_path / "s.tar.gz", "",
                         fetch=lambda url, dest: dest.write_bytes(b"tampered"))
    assert not (tmp_path / "s.tar.gz").exists()


def test_lgpl_sources_refuses_when_the_host_package_changed_version(tmp_path):
    with pytest.raises(tpn.Problem, match="libfoo.*audio 2.0"):
        tpn.lgpl_sources(lgpl_manifest(b"source"), {"audio": "2.0"}, tmp_path / "s.tar.gz", "",
                         fetch=lambda url, dest: dest.write_bytes(b"source"))
