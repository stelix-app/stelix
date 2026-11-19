#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.
# Packages the Python sidecar into sidecar/dist: standalone interpreter, site-packages, stelix_sidecar.py.
# Dependencies come from sidecar/uv.lock (the same versions as the tests), never resolved again.
# Rebuilds only if pyproject.toml, uv.lock, stelix_sidecar.py, python.entitlements or this script are newer than dist/,
# or if the signing identity changed.
# Usage: scripts/build-sidecar.sh [--force]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIDECAR="$ROOT/sidecar"
DIST="$SIDECAR/dist"
IDENTITY="${STELIX_SIGN_IDENTITY:-Stelix Local Signing}"
# The app's minimum macOS, from project.yml: every Mach-O of the sidecar must load there.
MIN_MACOS="$(awk '/MACOSX_DEPLOYMENT_TARGET:/ { gsub(/"/, "", $2); print $2; exit }' "$ROOT/project.yml")"
[ -n "$MIN_MACOS" ] || { echo "Error: MACOSX_DEPLOYMENT_TARGET not found in project.yml" >&2; exit 1; }

# .built holds the signing identity: a new certificate rebuilds and re-signs everything.
if [ "${1:-}" != "--force" ] && [ -f "$DIST/.built" ] \
   && [ "$(cat "$DIST/.built")" = "$IDENTITY" ] \
   && [ ! "$SIDECAR/pyproject.toml" -nt "$DIST/.built" ] \
   && [ ! "$SIDECAR/uv.lock" -nt "$DIST/.built" ] \
   && [ ! "$SIDECAR/stelix_sidecar.py" -nt "$DIST/.built" ] \
   && [ ! "$SIDECAR/python.entitlements" -nt "$DIST/.built" ] \
   && [ ! "$0" -nt "$DIST/.built" ] \
   && [ ! "$ROOT/project.yml" -nt "$DIST/.built" ]; then
  echo "Sidecar already up to date: $DIST"
  exit 0
fi

rm -rf "$DIST"
mkdir -p "$DIST"

# 1. uv's standalone interpreter (not python.org's one in /Library/Frameworks, which cannot be moved).
uv python install 3.12
PYBIN="$(uv python find --managed-python 3.12)"
PYHOME="$(cd "$(dirname "$(realpath "$PYBIN")")/.." && pwd)"
ditto "$PYHOME" "$DIST/python"
[ -x "$DIST/python/bin/python3" ] || { echo "Error: python/bin/python3 is missing" >&2; exit 1; }

# 1b. No traces of the build machine: uv rewrites the interpreter's prefix to its own install
#     path (under $HOME). Text files get python-build-standalone's neutral /install prefix back,
#     libpython gets an @rpath install name (python3 is statically linked and does not load it).
#     pip and ensurepip are dropped: the sidecar never installs anything.
rm -rf "$DIST/python/lib/python3.12/site-packages/pip" "$DIST/python/lib/python3.12/site-packages"/pip-*.dist-info \
  "$DIST/python/lib/python3.12/ensurepip" "$DIST/python/bin"/pip*
grep -rlI --null -F "$PYHOME" "$DIST/python" | xargs -0 sed -i '' "s#$PYHOME#/install#g"
install_name_tool -id @rpath/libpython3.12.dylib "$DIST/python/lib/libpython3.12.dylib"

# 2. Dependencies from the lock, with hashes, without the dev group and without the project (the script goes in step 3).
#    The wheels are the ones for the app's minimum macOS, not for the build machine's: MLX publishes one per
#    macOS version, and the one for macOS 26 does not load on 15.
REQS="$(mktemp -t stelix-sidecar-reqs)"
trap 'rm -f "$REQS"' EXIT
(cd "$SIDECAR" && uv export --frozen --no-dev --no-emit-project --format requirements-txt -o "$REQS" >/dev/null)
MACOSX_DEPLOYMENT_TARGET="$MIN_MACOS" uv pip install --python "$DIST/python/bin/python3" \
  --python-platform aarch64-apple-darwin --target "$DIST/site-packages" --no-cache-dir --no-deps -r "$REQS"

# 3. The script.
cp "$SIDECAR/stelix_sidecar.py" "$DIST/stelix_sidecar.py"

# 4. Cleanup: caches, tests, stubs, headers. .metallib, .json and .yaml remain.
find "$DIST" -type d -name __pycache__ -prune -exec rm -rf {} +
find "$DIST/site-packages" -type d \( -name tests -o -name test -o -name include \) -prune -exec rm -rf {} +
find "$DIST/python" -type d \( -name test -o -name tests -o -name idlelib -o -name include \) -prune -exec rm -rf {} +
find "$DIST" -type f \( -name '*.pyi' -o -name '*.h' -o -name '*.hpp' \) -delete

# 4b. Bytecode already compiled, with unchecked hash: at runtime the sidecar runs with -B and writes
#     nothing into the signed bundle (a new .pyc would break its seal), and it still starts fast.
#     -s/-p: paths in the bytecode are relative to the bundle, not to this machine.
env -i "$DIST/python/bin/python3" -B -I -m compileall -f -q -j 0 --invalidation-mode unchecked-hash \
  -s "$DIST" -p sidecar "$DIST/python/lib" "$DIST/site-packages" >/dev/null
# The RECORD files stay: mlx_audio_io compares the hash of its native module with the RECORD and without it
# refuses to load it. They are rewritten after signing (step 6).
rm -rf "$DIST/site-packages/bin"

# 5. Sign every Mach-O. The interpreter gets the hardened runtime, like the app and the engine, so
#    that it ignores DYLD_INSERT_LIBRARIES; python.entitlements says why it needs one exception.
while IFS= read -r -d '' f; do
  kind="$(file -b "$f")"
  if grep -q 'Mach-O.*executable' <<<"$kind"; then
    codesign --force --sign "$IDENTITY" --options runtime --entitlements "$SIDECAR/python.entitlements" "$f"
  elif grep -q 'Mach-O' <<<"$kind"; then
    codesign --force --sign "$IDENTITY" "$f"
  fi
done < <(find "$DIST" -type f \( -perm +111 -o -name '*.so' -o -name '*.dylib' \) -print0)

# 6. RECORD files consistent again: signing changes the bytes of the Mach-O files, and the cleanup removed some files.
env -i "$DIST/python/bin/python3" -B -I - "$DIST/site-packages" <<'PY'
import base64, csv, hashlib, os, sys
site = sys.argv[1]
for name in os.listdir(site):
    record = os.path.join(site, name, "RECORD")
    if not (name.endswith(".dist-info") and os.path.isfile(record)):
        continue
    with open(record, newline="") as handle:
        rows = list(csv.reader(handle))
    kept = []
    for row in rows:
        path = os.path.normpath(os.path.join(site, row[0])) if row and row[0] else None
        if path and os.path.abspath(path) == os.path.abspath(record):
            kept.append([row[0], "", ""])
            continue
        if not path or not os.path.isfile(path):
            continue  # removed by the cleanup (caches, tests, headers) or outside site-packages
        with open(path, "rb") as handle:
            data = handle.read()
        digest = base64.urlsafe_b64encode(hashlib.sha256(data).digest()).rstrip(b"=").decode()
        kept.append([row[0], f"sha256={digest}", str(len(data))])
    with open(record, "w", newline="") as handle:
        csv.writer(handle, lineterminator="\n").writerows(kept)
PY

# 7. Check: the native module of mlx_audio_io loads (hash and signature verified) and writes a WAV.
env -i "$DIST/python/bin/python3" -B -I - "$DIST/site-packages" <<'PY'
import os, sys, tempfile
sys.path.insert(0, sys.argv[1])
import mlx_audio_io as mac
import numpy as np
mac.load_native_module()
path = os.path.join(tempfile.mkdtemp(), "check.wav")
mac.save(path, np.zeros((441, 2), dtype=np.float32), 44100, layout="channels_last", encoding="float32")
data, rate = mac.load(path)
assert rate == 44100 and data.shape[0] == 441, (rate, data.shape)
import mlx_audio_separator  # noqa: F401
print("Sidecar ok: native mlx_audio_io and mlx_audio_separator loaded")
PY

# 7b. Every Mach-O loads on the minimum macOS.
TOO_NEW=""
while IFS= read -r -d '' f; do
  m="$(vtool -show-build "$f" 2>/dev/null | awk '/minos/{print $2; exit}' || true)"
  [ -z "$m" ] && continue
  [ "$(printf '%s\n%s\n' "$m" "$MIN_MACOS" | sort -V | tail -1)" = "$MIN_MACOS" ] || TOO_NEW+="$m $f"$'\n'
done < <(find "$DIST" -type f \( -perm +111 -o -name '*.so' -o -name '*.dylib' \) -print0)
[ -z "$TOO_NEW" ] || { echo "Error: Mach-O files that need a macOS newer than $MIN_MACOS:" >&2; echo "$TOO_NEW" >&2; exit 1; }

# 8. Nothing may point at the build machine's home folder.
LEAKS="$(grep -rlas -F "$HOME" "$DIST" || true)"
[ -z "$LEAKS" ] || { echo "Error: files in $DIST contain $HOME:" >&2; echo "$LEAKS" | head -20 >&2; exit 1; }

printf '%s\n' "$IDENTITY" > "$DIST/.built"
du -sh "$DIST"
