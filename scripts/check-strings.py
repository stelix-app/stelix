#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.
"""Checks that the app's localized strings and the String Catalogs agree.

- Every `String(localized: "<key>", defaultValue: "<text>")` in App/ has its key in
  App/Resources/Localizable.xcstrings, with `en` equal to the default value (interpolations
  become `%@`) and `it` in state `translated`, with the same number of `%@`.
- The catalog has no keys the code doesn't use.
- App/Resources/InfoPlist.xcstrings has `en` (equal to Info.plist) and a translated `it` for
  every key.

Exits with 1 and the list of problems if something doesn't match.
Usage: scripts/check-strings.py [path/to/Localizable.xcstrings]
"""
import json
import plistlib
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "App"
CATALOG = ROOT / "App/Resources/Localizable.xcstrings"
INFO_CATALOG = ROOT / "App/Resources/InfoPlist.xcstrings"
INFO_PLIST = ROOT / "App/Resources/Info.plist"
LANGS = ("en", "it")
MARKER = 'String(localized: "'


def read_literal(src: str, i: int) -> tuple[str, int]:
    """Reads a Swift string literal starting just after its opening quote. Returns the text,
    with each `\\(...)` turned into `%@`, and the index after the closing quote."""
    out = []
    while i < len(src):
        c = src[i]
        if c == '"':
            return "".join(out), i + 1
        if c == "\\":
            nxt = src[i + 1]
            if nxt == "(":
                depth, i = 1, i + 2
                while depth:
                    depth += {"(": 1, ")": -1}.get(src[i], 0)
                    i += 1
                out.append("%@")
                continue
            out.append({"n": "\n", "t": "\t", '"': '"', "\\": "\\"}.get(nxt, nxt))
            i += 2
            continue
        out.append(c)
        i += 1
    raise ValueError("unterminated string literal")


def strings_in_code() -> tuple[dict[str, str], list[str]]:
    found: dict[str, str] = {}
    problems: list[str] = []
    for path in sorted(APP.rglob("*.swift")):
        src = path.read_text()
        start = 0
        while (i := src.find(MARKER, start)) != -1:
            line_start = src.rfind("\n", 0, i) + 1
            if src[line_start:i].lstrip().startswith("//"):
                start = i + len(MARKER)
                continue
            key, j = read_literal(src, i + len(MARKER))
            rest = src[j:].lstrip()
            where = f"{path.relative_to(ROOT)}: {key}"
            if not rest.startswith(","):
                problems.append(f"{where}: no defaultValue")
                start = j
                continue
            rest = rest[1:].lstrip()
            if not rest.startswith('defaultValue: "'):
                problems.append(f"{where}: defaultValue must follow the key")
                start = j
                continue
            k = len(src) - len(rest) + len('defaultValue: "')
            value, start = read_literal(src, k)
            if key in found and found[key] != value:
                problems.append(f"{where}: two different default values")
            found[key] = value
    return found, problems


def unit(entry: dict, lang: str) -> dict | None:
    return entry.get("localizations", {}).get(lang, {}).get("stringUnit")


def check_catalog(catalog_path: Path, code: dict[str, str]) -> list[str]:
    problems = []
    try:
        catalog = json.loads(catalog_path.read_text()).get("strings", {})
    except FileNotFoundError:
        catalog = {}
    for key, value in sorted(code.items()):
        entry = catalog.get(key)
        if entry is None:
            problems.append(f"missing from catalog: {key}")
            continue
        en, it = unit(entry, "en"), unit(entry, "it")
        if en is None or en.get("value") != value:
            problems.append(f"{key}: en is {en and en.get('value')!r}, code says {value!r}")
        if it is None or it.get("state") != "translated" or not it.get("value"):
            problems.append(f"{key}: it not translated")
        elif it["value"].count("%@") != value.count("%@"):
            problems.append(f"{key}: it has a different number of %@")
    for key in sorted(set(catalog) - set(code)):
        problems.append(f"unused key in catalog: {key}")
    return problems


def check_info_plist() -> list[str]:
    problems = []
    info = plistlib.loads(INFO_PLIST.read_bytes())
    if info.get("CFBundleDevelopmentRegion") != "en":
        problems.append("Info.plist: CFBundleDevelopmentRegion is not en")
    try:
        catalog = json.loads(INFO_CATALOG.read_text()).get("strings", {})
    except FileNotFoundError:
        return problems + ["InfoPlist.xcstrings is missing"]
    for key, entry in sorted(catalog.items()):
        en, it = unit(entry, "en"), unit(entry, "it")
        if en is None or en.get("value") != info.get(key):
            problems.append(f"InfoPlist {key}: en differs from Info.plist")
        if it is None or it.get("state") != "translated" or not it.get("value"):
            problems.append(f"InfoPlist {key}: it not translated")
    if "NSAudioCaptureUsageDescription" not in catalog:
        problems.append("InfoPlist: NSAudioCaptureUsageDescription not translated")
    return problems


def main() -> int:
    catalog_path = Path(sys.argv[1]) if len(sys.argv) > 1 else CATALOG
    code, problems = strings_in_code()
    problems += check_catalog(catalog_path, code)
    problems += check_info_plist()
    if problems:
        print(f"check-strings: {len(problems)} problems", file=sys.stderr)
        for p in problems:
            print(f"  {p}", file=sys.stderr)
        return 1
    print(f"check-strings: ok ({len(code)} keys)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
