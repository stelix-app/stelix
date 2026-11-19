#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.
# Usage: scripts/snapshot.sh [--lang <code>] [--locale <id>] [--no-models] [--show <what>] <original|live|studio>
# Launches Stelix with DemoEngine and saves the panel to build/snap-<mode>[-<show>][-nomodels][-<code>][-<locale>].png.
# --lang (e.g. en, it, de, it-CH, en-GB) is passed to the app as -AppleLanguages, so the app picks
# its language the way macOS would for that user.
# --locale (e.g. de_DE, it_CH, en_GB) is passed as -AppleLocale: digits follow the region, like
# System Settings, General, Language & Region. Without it the Mac's own region applies.
# --no-models uses an empty models folder (the banner of a level to download).
# --show settings|about|notice opens Settings, About, or the download notice of the mode's level.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
USAGE="usage: scripts/snapshot.sh [--lang <code>] [--locale <id>] [--no-models] [--show <what>] <original|live|studio>"
LANG_CODE=""
LOCALE_ID=""
SHOW=""
NO_MODELS=0
while [ $# -gt 1 ]; do
  case "$1" in
    --lang) LANG_CODE="${2:?$USAGE}"; shift 2 ;;
    --locale) LOCALE_ID="${2:?$USAGE}"; shift 2 ;;
    --show) SHOW="${2:?$USAGE}"; shift 2 ;;
    --no-models) NO_MODELS=1; shift ;;
    *) echo "$USAGE" >&2; exit 2 ;;
  esac
done
MODE="${1:?$USAGE}"
NAME="snap-$MODE"
APP_ARGS=()
if [ -n "$SHOW" ]; then
  NAME="$NAME-$SHOW"
  APP_ARGS+=(--show "$SHOW")
fi
if [ "$NO_MODELS" = 1 ]; then
  NAME="$NAME-nomodels"
  APP_ARGS+=(--no-models)
fi
if [ -n "$LANG_CODE" ]; then
  NAME="$NAME-$LANG_CODE"
  APP_ARGS+=(-AppleLanguages "($LANG_CODE)")
fi
if [ -n "$LOCALE_ID" ]; then
  NAME="$NAME-$LOCALE_ID"
  APP_ARGS+=(-AppleLocale "$LOCALE_ID")
fi
OUT="$ROOT/build/$NAME.png"
rm -f "$OUT"
"$ROOT/build/Build/Products/Release/Stelix.app/Contents/MacOS/Stelix" --snapshot "$OUT" "$MODE" ${APP_ARGS[@]+"${APP_ARGS[@]}"}
[ -f "$OUT" ] || { echo "Error: PNG not created: $OUT" >&2; exit 1; }
echo "$OUT"
