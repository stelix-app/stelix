#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.
# Builds a release DMG: release/Stelix.dmg (Stelix.app plus an Applications link). The file name has no
# version, so https://github.com/stelix-app/stelix/releases/latest/download/Stelix.dmg always points to the latest.
# Usage: scripts/release.sh <version>    e.g. scripts/release.sh 1.0.0
# Requires: CFBundleShortVersionString == <version> and a clean working tree.
# Next to it, release/Stelix-<version>-lgpl-sources.tar.gz: the source of the LGPL libraries in the app.
# It only builds them locally; uploading both is a manual step.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-}"
[ -n "$VERSION" ] || { echo "Usage: scripts/release.sh <version>" >&2; exit 64; }

PLIST="$ROOT/App/Resources/Info.plist"
PLIST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
[ "$PLIST_VERSION" = "$VERSION" ] || {
  echo "Error: Info.plist says $PLIST_VERSION, not $VERSION" >&2
  exit 1
}
[ -z "$(git status --porcelain)" ] || {
  echo "Error: the working tree is not clean; commit or stash first" >&2
  git status --short >&2
  exit 1
}

"$ROOT/scripts/build.sh" --no-install

APP="$ROOT/build/Build/Products/Release/Stelix.app"
codesign --verify --strict --deep "$APP"

# Model weights never ship with the app.
WEIGHTS="$(find "$APP" \( -name '*.safetensors' -o -name '*.ckpt' -o -name '*.th' \
  -o -name '*.pt' -o -name '*.pth' -o -name '*.onnx' \) -print)"
[ -z "$WEIGHTS" ] || { echo "Error: model weights inside the app:" >&2; echo "$WEIGHTS" >&2; exit 1; }

RELEASE="$ROOT/release"
STAGING="$RELEASE/staging"
DMG="$RELEASE/Stelix.dmg"
rm -rf "$STAGING"
mkdir -p "$STAGING"
ditto "$APP" "$STAGING/Stelix.app"
ln -s /Applications "$STAGING/Applications"

hdiutil create -volname "Stelix $VERSION" -srcfolder "$STAGING" -format UDZO -ov "$DMG"
hdiutil verify "$DMG"
rm -rf "$STAGING"

BYTES="$(stat -f %z "$DMG")"
LIMIT=$((2 * 1024 * 1024 * 1024))
[ "$BYTES" -lt "$LIMIT" ] || { echo "Error: $DMG is $BYTES bytes, over the 2 GB release limit" >&2; exit 1; }

# The LGPL asks for the source of LAME and libsoxr to be offered from the same place as the app:
# this archive is published next to the DMG.
LGPL="$RELEASE/Stelix-$VERSION-lgpl-sources.tar.gz"
"$ROOT/sidecar/dist/python/bin/python3" -I -B "$ROOT/scripts/third-party-notices.py" --lgpl-sources "$LGPL"

LEAF="$(codesign -d -r- "$APP" 2>&1 | grep -o 'certificate leaf = H"[0-9a-f]*"' || true)"
[ -n "$LEAF" ] || { echo "Error: no certificate leaf hash in the designated requirement" >&2; exit 77; }

echo
echo "Stelix $VERSION (build $BUILD_NUMBER)"
echo "DMG:     ${DMG#"$ROOT"/}"
echo "Size:    $BYTES bytes ($(du -h "$DMG" | cut -f1))"
echo "SHA-256: $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
echo "LGPL sources: ${LGPL#"$ROOT"/}"
echo "SHA-256: $(shasum -a 256 "$LGPL" | cut -d' ' -f1)"
echo "Signing: $LEAF"
echo "         (must be the same in every release, or users grant the audio permission again)"
