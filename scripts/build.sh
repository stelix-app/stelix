#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.
# Generates the project, builds, signs with "Stelix Local Signing" and installs into /Applications.
# Usage: scripts/build.sh [--no-install]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Signing identity: override with STELIX_SIGN_IDENTITY to sign with your own certificate.
IDENTITY="${STELIX_SIGN_IDENTITY:-Stelix Local Signing}"
INSTALL=1
[ "${1:-}" = "--no-install" ] && INSTALL=0

# Every source file says where its license terms are.
"$ROOT/scripts/check-headers.sh"

# project.yml reads the identity from the environment (XcodeGen expands ${STELIX_SIGN_IDENTITY}).
export STELIX_SIGN_IDENTITY="$IDENTITY"
xcodegen generate

# Dependencies pinned by Package.resolved. To update them: delete Package.resolved
# and build again without -onlyUsePackageVersionsFromResolvedFile.
RESOLVED_DIR="$ROOT/Stelix.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
mkdir -p "$RESOLVED_DIR"
cp "$ROOT/Package.resolved" "$RESOLVED_DIR/Package.resolved"

# -ffile-prefix-map: source paths baked into the binaries (C/C++ asserts in MLX) become
# relative, so the build does not carry this machine's folders.
xcodebuild -scheme Stelix -configuration Release -destination 'platform=macOS' \
  -derivedDataPath build -onlyUsePackageVersionsFromResolvedFile \
  OTHER_CFLAGS="\$(inherited) -ffile-prefix-map=$ROOT=." \
  OTHER_SWIFT_FLAGS="\$(inherited) -file-prefix-map $ROOT=." \
  build

PRODUCTS="$ROOT/build/Build/Products/Release"
APP="$PRODUCTS/Stelix.app"
MACOS="$APP/Contents/MacOS"
[ -x "$MACOS/StelixEngine" ] || { echo "Error: $MACOS/StelixEngine is missing" >&2; exit 1; }

# Package resource bundles (MLX: default.metallib), next to StelixEngine.
shopt -s nullglob
for b in "$PRODUCTS"/*.bundle; do
  rm -rf "$MACOS/$(basename "$b")"
  ditto "$b" "$MACOS/$(basename "$b")"
done
shopt -u nullglob

METALLIB="$MACOS/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"
[ -f "$METALLIB" ] || { echo "Error: $METALLIB is missing" >&2; exit 1; }

# Python sidecar (rebuilt only if pyproject.toml changed), copied before the app is signed.
"$ROOT/scripts/build-sidecar.sh"
RES_SIDECAR="$APP/Contents/Resources/sidecar"
rm -rf "$RES_SIDECAR"
mkdir -p "$APP/Contents/Resources"
ditto "$ROOT/sidecar/dist" "$RES_SIDECAR"
rm -f "$RES_SIDECAR/.built"

# The license texts travel with the app, and About opens them: the GPL and the third-party licenses
# ask for a copy with every binary. The list of third-party components must match this build.
# Read-only, so that opening one in an editor cannot change the signed bundle.
"$ROOT/sidecar/dist/python/bin/python3" -I -B "$ROOT/scripts/third-party-notices.py" --check \
  --engine "$MACOS/StelixEngine"
for doc in LICENSE NOTICE THIRD_PARTY_NOTICES.md; do
  dest="$APP/Contents/Resources/${doc%.md}.txt"
  rm -f "$dest"
  cp "$ROOT/$doc" "$dest"
  chmod 444 "$dest"
done

# The shipped executables need no debug map (its stabs hold this machine's build paths).
# The old signature goes first: re-signed in place, its unused bytes (an earlier certificate's
# name, for one) would stay in the space kept for the signature.
codesign --remove-signature "$MACOS/Stelix" "$MACOS/StelixEngine"
strip -S "$MACOS/Stelix" "$MACOS/StelixEngine"

# Signing: first the bundles, then the engine, then the app. No --deep. Engine and app with the
# hardened runtime (the sidecar's interpreter gets it in build-sidecar.sh).
shopt -s nullglob
for b in "$MACOS"/*.bundle; do
  codesign --force --sign "$IDENTITY" "$b"
done
shopt -u nullglob
codesign --force --sign "$IDENTITY" --options runtime --identifier io.github.stelix-app.stelix.engine "$MACOS/StelixEngine"
codesign --force --sign "$IDENTITY" --options runtime "$APP"
codesign --verify --strict --deep "$APP"
# The sidecar, launched the way SidecarJob launches it (-B -I), must not write anything into the signed bundle.
env -i "$RES_SIDECAR/python/bin/python3" -B -I -c '
import runpy, sys, tempfile
module = runpy.run_path(sys.argv[1], run_name="stelix_sidecar")
work = tempfile.mkdtemp()
module["RealSeparator"](work, work, lambda step, total: None)
' "$RES_SIDECAR/stelix_sidecar.py"
codesign --verify --strict --deep "$APP" \
  || { echo "Error: the sidecar wrote into the signed bundle" >&2; exit 1; }
# Hardened runtime on everything that runs. Without it any process can load its own code into the
# app (DYLD_INSERT_LIBRARIES) and record the Mac's audio with the permission given to the app.
for exe in "$MACOS/Stelix" "$MACOS/StelixEngine" "$RES_SIDECAR/python/bin/python3.12"; do
  SIGNATURE="$(codesign -dv "$exe" 2>&1)"
  grep -q 'flags=0x[0-9a-f]*(.*runtime' <<<"$SIGNATURE" \
    || { echo "Error: $exe is not signed with the hardened runtime" >&2; exit 1; }
done
ENGINE_INFO="$(codesign -dv "$MACOS/StelixEngine" 2>&1)"
grep -qx "Identifier=io.github.stelix-app.stelix.engine" <<<"$ENGINE_INFO" \
  || { echo "Error: wrong engine identifier" >&2; exit 1; }
# Nothing in the app may point at the build machine's home folder.
LEAKS="$(grep -rlas -F "$HOME" "$APP" || true)"
[ -z "$LEAKS" ] || { echo "Error: files in the app contain $HOME:" >&2; echo "$LEAKS" | head -20 >&2; exit 1; }
# The designated requirement must pin the certificate (leaf hash): macOS keeps the
# audio permission across updates only if every build is signed with the same certificate.
DR="$(codesign -d -r- "$APP" 2>&1)"
grep -q 'certificate leaf = H"' <<<"$DR" || {
  echo "Error: the designated requirement does not pin the certificate leaf hash:" >&2
  echo "$DR" >&2
  exit 77
}

if [ "$INSTALL" = 1 ]; then
  osascript -e 'if application "Stelix" is running then tell application "Stelix" to quit' >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6; do
    pgrep -x Stelix >/dev/null || break
    sleep 0.5
  done
  pgrep -x Stelix >/dev/null && pkill -x Stelix || true
  rm -rf /Applications/Stelix.app
  ditto "$APP" /Applications/Stelix.app
  codesign -d -r- /Applications/Stelix.app
else
  codesign -d -r- "$APP"
fi
