#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.
# Rules of the design and the global constraints, checked with grep on App/.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
FAIL=0
fail() { echo "lint-ui: $1" >&2; FAIL=1; }

FILES=$(find App -name '*.swift')

for pat in 'MenuBarExtra' '\.sheet\(' 'NavigationStack' 'openSettings' 'LinearGradient'; do
  hits=$(grep -nE "$pat" $FILES || true)
  [ -n "$hits" ] && fail "forbidden '$pat':
$hits"
done

# .shadow( with radius > 8 (or without an explicit radius: the default is 10)
hits=$(grep -nE '\.shadow\(' $FILES | awk '{
  if (match($0, /radius: *[0-9.]+/)) { r = substr($0, RSTART, RLENGTH); sub(/radius: */, "", r); if (r+0 > 8) print }
  else print }' || true)
[ -n "$hits" ] && fail "shadow with radius > 8:
$hits"

# Emoji
hits=$(for f in $FILES; do perl -CSD -ne 'print "$ARGV:$.: $_" if /\p{Extended_Pictographic}/' "$f"; done)
[ -n "$hits" ] && fail "emoji:
$hits"

# Visible literal text outside Copy.swift
OTHERS=$(echo "$FILES" | grep -v '/Copy\.swift$')
hits=$(grep -nE 'Text\((verbatim: *)?"[^"]*[A-Za-zÀ-ÿ]' $OTHERS || true)
[ -n "$hits" ] && fail "literal text outside Copy.swift:
$hits"

# TextField without a title: on macOS the title shows as a placeholder in the empty field,
# and every field already has its name written next to it.
hits=$(grep -nE 'TextField\(' $FILES | grep -vE 'TextField\("",' || true)
[ -n "$hits" ] && fail "TextField with a title (it shows as a placeholder):
$hits"

# Localized strings: code and String Catalogs agree
"$ROOT/scripts/check-strings.py" || FAIL=1

[ $FAIL -eq 0 ] && echo "lint-ui: ok"
exit $FAIL
