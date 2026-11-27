#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.
# Builds the disk image Stelix ships in: the app, a link to /Applications, the background with the
# install instructions (scripts/dmg/background.tiff), the icons where the background expects them and
# Stelix's icon on the volume. Used by release.sh and update-test-feed.sh, so the update check is
# tested on the same kind of image users download.
# Usage: scripts/make-dmg.sh <app> <volume name> <output dmg>
# dmgbuild (MIT) writes the window settings without driving Finder; scripts/dmg/build.py runs it and
# moves the background where Stelix 1.0.0's update check allows it. It runs from its own virtual
# environment, build/dmgbuild, made with uv from scripts/dmg/requirements.txt (pinned by hash) and
# made again when that file changes. It never goes into the app.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

APP="${1:-}"
APP="${APP%/}"
VOLUME="${2:-}"
OUT="${3:-}"
[ -n "$APP" ] && [ -n "$VOLUME" ] && [ -n "$OUT" ] || {
  echo "Usage: scripts/make-dmg.sh <app> <volume name> <output dmg>" >&2
  exit 64
}
[ -d "$APP" ] && [ "${APP%.app}" != "$APP" ] || { echo "Error: $APP is not an app" >&2; exit 66; }

VENV="${STELIX_DMG_VENV:-$ROOT/build/dmgbuild}"
REQUIREMENTS="${STELIX_DMG_REQUIREMENTS:-$ROOT/scripts/dmg/requirements.txt}"
STAMP="$VENV/requirements.sha256"
WANTED="$(shasum -a 256 "$REQUIREMENTS" | cut -d' ' -f1)"
if [ "$(cat "$STAMP" 2>/dev/null || true)" != "$WANTED" ] || ! "$VENV/bin/python" -I -c '' 2>/dev/null; then
  command -v uv > /dev/null || {
    echo "Error: make-dmg.sh needs uv to set up dmgbuild (https://docs.astral.sh/uv/)" >&2
    exit 69
  }
  rm -rf "$VENV"
  # The same Python as the sidecar: uv's own 3.12, whatever else is on the Mac.
  uv venv --quiet --managed-python --python 3.12 "$VENV"
  uv pip install --quiet --python "$VENV/bin/python" --require-hashes --only-binary :all: -r "$REQUIREMENTS"
  echo "$WANTED" > "$STAMP"
fi

rm -f "$OUT"
"$VENV/bin/python" -I "$ROOT/scripts/dmg/build.py" "$ROOT/scripts/dmg/settings.py" "$APP" \
  "$ROOT/scripts/dmg/background.tiff" "$ROOT/App/Resources/AppIcon.icns" "$VOLUME" "$OUT"
