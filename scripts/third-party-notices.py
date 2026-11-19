#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.
"""Writes THIRD_PARTY_NOTICES.md: every third-party component that ships inside the app, with its
version, where it comes from, its license and the full license text.

Where the list comes from:
- Swift packages: Package.resolved, with the license files of build/SourcePackages/checkouts;
- Python packages: sidecar/dist/site-packages/*.dist-info (METADATA and licenses/);
- everything the build tree does not describe on its own (code vendored inside a package, libraries
  compiled into a wheel, the libraries linked into the Python runtime): third-party/manifest.json,
  with the license texts in third-party/licenses/.

It stops with an error, instead of writing an incomplete file, when:
- Package.resolved has a package the manifest does not know;
- a package has no license file;
- the sidecar holds a dynamic library, or a notice file inside a package, that the manifest neither
  lists nor ignores (this is how a library bundled in a wheel gets noticed);
- a component of the manifest was checked against another version of the package that carries it;
- the engine links a package marked as build-only, or does not link one marked as shipped.

Usage, after scripts/build.sh --no-install (it needs the checkouts and sidecar/dist):
  scripts/third-party-notices.py                  write THIRD_PARTY_NOTICES.md
  scripts/third-party-notices.py --check          fail if the committed file is not up to date
  scripts/third-party-notices.py --lgpl-sources release/<name>.tar.gz
                                                  download the source of the LGPL libraries (checked
                                                  by SHA-256) into one archive, to publish next to
                                                  the app

When the Python runtime changes (sidecar/dist/python/BUILD), refresh
third-party/licenses/python-build-standalone/ from python/licenses/ of the matching "full" archive of
python-build-standalone, and compare the list of linked libraries with its python/PYTHON.json.
"""
import argparse
import csv
import fnmatch
import hashlib
import json
import re
import subprocess
import sys
import tarfile
import tempfile
from dataclasses import dataclass, field
from email.parser import HeaderParser
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "THIRD_PARTY_NOTICES.md"
MANIFEST = ROOT / "third-party/manifest.json"
PREAMBLE = ROOT / "third-party/preamble.md"

LICENSE_NAME = re.compile(r"^(LICEN[SC]E|COPYING|UNLICEN[SC]E)", re.I)
NOTICE_NAME = re.compile(r"^NOTICE", re.I)
NOTICE_LIKE = re.compile(r"^(LICEN[SC]E|COPYING|NOTICE|THIRD[_-]?PARTY|AUTHORS|ACKNOWLEDG)", re.I)
BINARY_SUFFIXES = {".dylib", ".so", ".a", ".metallib"}
# A license text this long, used by several components, is printed once at the end.
SHARED_MIN_LINES = 40


class Problem(Exception):
    """Something that would make the notices incomplete or wrong."""


@dataclass
class Component:
    name: str
    version: str
    license: str
    url: str
    texts: list = field(default_factory=list)  # (label, text)
    inside: str = ""
    note: str = ""


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


# --- Swift packages ---------------------------------------------------------------------------------

def swift_components(resolved: Path, checkouts: Path, manifest: dict):
    """The packages of Package.resolved: those linked into the app, each followed by the code it
    vendors, and those that are only resolved at build time."""
    known = manifest.get("swift", {})
    shipped, build_only = [], []
    for pin in sorted(json.loads(read_text(resolved))["pins"], key=lambda p: p["identity"]):
        identity = pin["identity"]
        if identity not in known:
            raise Problem(f"{identity}: in Package.resolved but not in {MANIFEST.name}; add it and say "
                          "whether it is linked into the app")
        entry = known[identity]
        url = re.sub(r"\.git$", "", pin["location"])
        name = url.rstrip("/").rsplit("/", 1)[-1]
        state = pin.get("state", {})
        version = state.get("version") or f"revision {state.get('revision', '')[:7]}"
        if not entry.get("shipped"):
            build_only.append(Component(name, version, entry.get("license", ""), url, note=entry.get("why", "")))
            continue
        folder = checkouts / name
        files = sorted(p for p in folder.glob("*") if p.is_file()) if folder.is_dir() else []
        licenses = [p for p in files if LICENSE_NAME.match(p.name)]
        if not licenses:
            raise Problem(f"{name}: no license file in {folder}")
        notices = [p for p in files if NOTICE_NAME.match(p.name)]
        shipped.append(Component(name, version, entry["license"], url,
                                 [(p.name, read_text(p)) for p in licenses + notices]))
        for part in entry.get("bundled", []):
            texts = []
            for rel in part["files"]:
                path = folder / rel
                if not path.is_file():
                    raise Problem(f"{part['name']} (inside {name}): {path} is missing")
                texts.append((path.name, read_text(path)))
            shipped.append(Component(part["name"], part.get("version", ""), part["license"], part["url"],
                                     texts, inside=name, note=part.get("note", "")))
    return shipped, build_only


# --- Python packages --------------------------------------------------------------------------------

def _python_url(meta) -> str:
    preferred = ("source", "repository", "code", "source code", "homepage")
    urls = {}
    for value in meta.get_all("Project-URL", []):
        label, _, url = value.partition(",")
        urls[label.strip().lower()] = url.strip()
    for label in preferred:
        if label in urls:
            return urls[label]
    return meta.get("Home-page") or f"https://pypi.org/project/{meta['Name']}/"


def _python_license(meta) -> str:
    declared = meta.get("License-Expression") or (meta.get("License") or "").strip().splitlines()[:1]
    if isinstance(declared, list):
        declared = declared[0] if declared else ""
    if declared and len(declared) <= 80:
        return declared
    for classifier in meta.get_all("Classifier", []):
        if classifier.startswith("License ::"):
            return classifier.rsplit("::", 1)[-1].strip()
    return "see the license text"


def python_components(site_packages: Path) -> list:
    """One component per installed distribution, with every file of its `licenses/` folder."""
    components = []
    for info in sorted(site_packages.glob("*.dist-info")):
        meta = HeaderParser().parsestr(read_text(info / "METADATA"))
        folder = info / "licenses"
        files = sorted(p for p in folder.rglob("*") if p.is_file()) if folder.is_dir() else []
        labels = [p.relative_to(folder).as_posix() for p in files]
        legacy = sorted(p for p in info.glob("*") if p.is_file() and NOTICE_LIKE.match(p.name))
        files, labels = files + legacy, labels + [p.name for p in legacy]
        if not files:
            raise Problem(f"{meta['Name']}: no license file in {info}")
        components.append(Component(meta["Name"], meta["Version"], _python_license(meta), _python_url(meta),
                                    [(label, read_text(p)) for label, p in zip(labels, files)]))
    return components


# --- Safety nets on the sidecar tree ----------------------------------------------------------------

def check_binaries(dist: Path, claims: list) -> None:
    """Every native library in the sidecar belongs to an installed package or is claimed by the
    manifest. A library that a wheel copies next to its module (`.dylibs`) is third-party code with
    its own license: it must always be claimed."""
    site = dist / "site-packages"
    recorded = set()
    for record in site.glob("*.dist-info/RECORD"):
        with record.open(newline="") as handle:
            recorded.update((site / row[0]).resolve() for row in csv.reader(handle) if row)
    orphans = []
    for path in sorted(p for p in dist.rglob("*") if p.is_file() and p.suffix in BINARY_SUFFIXES):
        rel = path.relative_to(dist).as_posix()
        if any(fnmatch.fnmatch(rel, pattern) for pattern in claims):
            continue
        copied_in = any(part == ".dylibs" or part.endswith(".libs") for part in path.parts)
        if path.resolve() in recorded and not copied_in:
            continue
        orphans.append(rel)
    if orphans:
        raise Problem("native libraries in the sidecar that no component claims (add them to "
                      f"{MANIFEST.name}, with their license):\n  " + "\n  ".join(orphans))


def check_notice_files(site_packages: Path, referenced: set, ignored: list) -> None:
    """A package that carries its own notices (a `licenses` folder, a THIRD_PARTY file) bundles
    someone else's code: each of those files is used by the manifest or ignored on purpose."""
    referenced = {p.resolve() for p in referenced}
    loose = []
    for path in sorted(p for p in site_packages.rglob("*") if p.is_file()):
        rel = path.relative_to(site_packages)
        if rel.parts[0].endswith(".dist-info"):
            continue
        if not (NOTICE_LIKE.match(path.name) or "licenses" in rel.parts[:-1]):
            continue
        if path.resolve() in referenced or any(fnmatch.fnmatch(rel.as_posix(), pattern) for pattern in ignored):
            continue
        loose.append(rel.as_posix())
    if loose:
        raise Problem("notice files inside Python packages that the manifest neither uses nor ignores:\n  "
                      + "\n  ".join(loose))


# --- Components the build tree does not describe ----------------------------------------------------

def _check_host(name: str, expected: dict, versions: dict) -> None:
    for host, version in expected.items():
        if versions.get(host) != version:
            raise Problem(f"{name}: was checked against {host} {version}, the build now has "
                          f"{host} {versions.get(host, '(absent)')}; review it in {MANIFEST.name}")


def extra_components(entries: list, root: Path, versions: dict) -> list:
    components = []
    for entry in entries:
        _check_host(entry["name"], entry.get("with", {}), versions)
        texts = []
        for rel in entry["files"]:
            path = root / rel
            if not path.is_file():
                raise Problem(f"{entry['name']}: {path} is missing")
            texts.append((path.name, read_text(path)))
        components.append(Component(entry["name"], entry.get("version", ""), entry["license"], entry["url"],
                                    texts, inside=entry.get("inside", ""), note=entry.get("note", "")))
    return components


# --- What is really linked --------------------------------------------------------------------------

def check_probes(symbols: str, manifest: dict) -> None:
    """`symbols` is the output of `nm` on the engine. A package's probe is a symbol prefix of its."""
    for identity, entry in sorted(manifest.get("swift", {}).items()):
        probe = entry.get("probe")
        if not probe:
            continue
        linked = probe in symbols
        if entry.get("shipped") and not linked:
            raise Problem(f"{identity}: marked as shipped but not linked into the engine")
        if not entry.get("shipped") and linked:
            raise Problem(f"{identity}: marked as build-only but is linked into the engine")


# --- Rendering --------------------------------------------------------------------------------------

def fence(text: str) -> str:
    longest = max((len(run) for run in re.findall(r"`+", text)), default=0)
    return "`" * max(3, longest + 1)


def _normalized(text: str) -> str:
    return " ".join(text.split())


def _title(text: str, label: str) -> str:
    head = _normalized(text[:600]).upper()
    known = [("APACHE LICENSE VERSION 2.0", "Apache License 2.0"),
             ("GNU LESSER GENERAL PUBLIC LICENSE VERSION 2.1", "GNU Lesser General Public License 2.1"),
             ("GNU LIBRARY GENERAL PUBLIC LICENSE VERSION 2", "GNU Library General Public License 2"),
             ("MOZILLA PUBLIC LICENSE VERSION 2.0", "Mozilla Public License 2.0")]
    return next((title for marker, title in known if marker in head), label)


def _block(text: str) -> str:
    marks = fence(text)
    return f"{marks}text\n{text.rstrip()}\n{marks}\n"


def render(sections: list, build_only: list, preamble: str) -> str:
    """`sections` is a list of (title, introduction, components)."""
    uses = {}
    for _, _, components in sections:
        for component in components:
            for label, text in component.texts:
                uses.setdefault(_normalized(text), []).append((component.name, label, text))
    shared = {}
    for key, found in uses.items():
        owner, label, text = found[0]
        if len(found) > 1 and len(text.splitlines()) >= SHARED_MIN_LINES:
            # Several texts can share a title (the Apache License with and without an exception).
            shared[key] = (len(shared) + 1, f"{_title(text, label)}, as distributed with {owner}", text)

    out = ["# Third-Party Notices\n"]
    if preamble.strip():
        out.append(preamble.strip() + "\n")

    out.append("## Summary\n")
    out.append("| Component | Version | License | Part of |\n|---|---|---|---|")
    for title, _, components in sections:
        for c in components:
            out.append(f"| {c.name} | {c.version} | {c.license} | {c.inside or title} |")
    out.append("")

    for title, intro, components in sections:
        out.append(f"## {title}\n")
        if intro:
            out.append(intro.strip() + "\n")
        for c in components:
            out.append(f"### {c.name} {c.version}".rstrip() + "\n")
            lines = [f"- License: {c.license}", f"- Source: <{c.url}>"]
            if c.inside:
                lines.append(f"- Included in: {c.inside}")
            if c.note:
                lines.append(f"- Note: {c.note}")
            out.append("\n".join(lines) + "\n")
            for label, text in c.texts:
                key = _normalized(text)
                if key in shared:
                    number, name, _ = shared[key]
                    out.append(f"`{label}`: see [{name}](#shared-text-{number}) at the end of this file.\n")
                else:
                    out.append(f"`{label}`:\n\n{_block(text)}")

    if build_only:
        out.append("## Resolved at build time, not part of the app\n")
        out.append("The build downloads these packages because other packages declare them, but none of "
                   "their code is linked into the app.\n")
        out.append("| Package | Version | License | Why it is not in the app |\n|---|---|---|---|")
        for c in build_only:
            out.append(f"| [{c.name}]({c.url}) | {c.version} | {c.license} | {c.note} |")
        out.append("")

    if shared:
        out.append("## License texts used by more than one component\n")
        for number, name, text in sorted(shared.values()):
            out.append(f'<a id="shared-text-{number}"></a>\n\n### {name}\n\n{_block(text)}')
    return "\n".join(out).rstrip() + "\n"


def write_or_check(text: str, path: Path, check: bool) -> int:
    if not check:
        path.write_text(text, encoding="utf-8")
        return 0
    if path.is_file() and path.read_text(encoding="utf-8") == text:
        return 0
    print(f"third-party-notices: {path.name} is not up to date; run scripts/third-party-notices.py",
          file=sys.stderr)
    return 1


# --- Source of the LGPL libraries -------------------------------------------------------------------

def _curl(url: str, dest: Path) -> None:
    subprocess.run(["curl", "--fail", "--silent", "--show-error", "--location", "--proto", "=https",
                    "--output", str(dest), url], check=True)


def lgpl_sources(entries: list, versions: dict, out: Path, readme: str, fetch=_curl) -> None:
    """Downloads each source archive, checks its SHA-256 and packs them with a README. The LGPL asks
    for the source of the libraries to be offered from the same place as the binary."""
    for entry in entries:
        _check_host(entry["name"], entry.get("with", {}), versions)
    with tempfile.TemporaryDirectory() as work:
        folder = Path(work)
        for entry in entries:
            dest = folder / entry["file"]
            fetch(entry["url"], dest)
            digest = hashlib.sha256(dest.read_bytes()).hexdigest()
            if digest != entry["sha256"]:
                raise Problem(f"{entry['file']}: SHA-256 is {digest}, expected {entry['sha256']}")
        (folder / "README.txt").write_text(readme, encoding="utf-8")
        out.parent.mkdir(parents=True, exist_ok=True)
        with tarfile.open(out, "w:gz") as tar:
            for path in sorted(folder.iterdir()):
                tar.add(path, arcname=path.name)


# --- The command ------------------------------------------------------------------------------------

def _versions(dist: Path, python: list) -> dict:
    versions = {c.name: c.version for c in python}
    versions["python-build-standalone"] = read_text(dist / "python/BUILD").strip()
    found = subprocess.run([str(dist / "python/bin/python3"), "-I", "-B", "-c",
                            "import platform; print(platform.python_version())"],
                           capture_output=True, text=True, check=True)
    versions["cpython"] = found.stdout.strip()
    return versions


def _engine(explicit) -> Path | None:
    if explicit:
        return Path(explicit)
    found = sorted((ROOT / "build/Build/Products/Release").glob("*.app/Contents/MacOS/*Engine"))
    return found[0] if found else None


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--check", action="store_true", help="fail if THIRD_PARTY_NOTICES.md is not up to date")
    parser.add_argument("--engine", help="the engine executable to inspect with nm (default: the Release build)")
    parser.add_argument("--lgpl-sources", metavar="ARCHIVE", help="write the source of the LGPL libraries here")
    args = parser.parse_args(argv)

    checkouts = ROOT / "build/SourcePackages/checkouts"
    dist = ROOT / "sidecar/dist"
    site = dist / "site-packages"
    try:
        for needed in (checkouts, site, dist / "python/BUILD"):
            if not needed.exists():
                raise Problem(f"{needed} is missing: run scripts/build.sh --no-install first")
        manifest = json.loads(read_text(MANIFEST))
        python = python_components(site)
        versions = _versions(dist, python)

        if args.lgpl_sources:
            lgpl = manifest["lgpl_sources"]
            lgpl_sources(lgpl["archives"], versions, Path(args.lgpl_sources), "\n".join(lgpl["readme"]) + "\n")
            print(f"third-party-notices: wrote {args.lgpl_sources}")
            return 0

        shipped, build_only = swift_components(ROOT / "Package.resolved", checkouts, manifest)
        extra = manifest["extra"]
        groups = {group: extra_components([e for e in extra if e["group"] == group], ROOT, versions)
                  for group in ("packages", "runtime")}
        check_binaries(dist, manifest["binaries"])
        check_notice_files(site, {ROOT / rel for e in extra for rel in e["files"]}, manifest["ignored_notice_files"])
        engine = _engine(args.engine)
        if engine and engine.is_file():
            symbols = subprocess.run(["nm", str(engine)], capture_output=True, text=True, check=True).stdout
            check_probes(symbols, manifest)
        else:
            print("third-party-notices: no engine build found, linked packages not verified", file=sys.stderr)

        intros = manifest["sections"]
        text = render([("Swift packages", intros["swift"], shipped),
                       ("Python packages", intros["python"], python),
                       ("Code inside the Python packages", intros["packages"], groups["packages"]),
                       ("Python runtime", intros["runtime"], groups["runtime"])],
                      build_only, read_text(PREAMBLE))
        return write_or_check(text, OUTPUT, args.check)
    except Problem as problem:
        print(f"third-party-notices: {problem}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
