#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.
# A fake GitHub on 127.0.0.1 for testing "Update available" without publishing anything.
# Usage: scripts/update-test-feed.sh <built Stelix.app> <output dir> [new version]
# Makes two releases of <new version> (default: the app's version with one more last component):
#   good/  the app re-signed with the same identity as build.sh: Stelix must accept it;
#   adhoc/ the same app signed ad-hoc: Stelix must refuse it and delete it.
# Each has latest.json (as GitHub's /releases/latest), the DMG and notes.html. Then:
#   python3 -m http.server 8765 --bind 127.0.0.1 --directory <output dir>
#   open <Stelix.app> --args --update-feed http://127.0.0.1:8765/good/latest.json --open-panel original
# The DMG lands in ~/Downloads: don't drag it to Applications, it is a test build.
# STELIX_TEST_NOTES=<file.md> uses that file as the release body instead of the built-in sample.
set -euo pipefail
APP="${1:?built Stelix.app}"
OUT="${2:?output dir}"
IDENTITY="${STELIX_SIGN_IDENTITY:-Stelix Local Signing}"
PORT=8765
CURRENT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
case "$CURRENT" in
  *.*.*) NEW="${3:-${CURRENT%.*}.$((${CURRENT##*.} + 1))}" ;;
  *) NEW="${3:-$CURRENT.1}" ;;
esac
NAME="$(basename "$APP" .app)"
rm -rf "$OUT"
mkdir -p "$OUT"

make_variant() { # dir identity
  local name="$1" identity="$2" dir="$OUT/$1"
  mkdir -p "$dir/staging"
  ditto "$APP" "$dir/staging/$NAME.app"
  local plist="$dir/staging/$NAME.app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NEW" "$plist"
  local build
  build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $((build + 1))" "$plist"
  codesign --force --sign "$identity" --options runtime \
    --preserve-metadata=identifier,entitlements,flags "$dir/staging/$NAME.app"
  ln -s /Applications "$dir/staging/Applications"
  hdiutil create -quiet -volname "$NAME $NEW" -srcfolder "$dir/staging" -format UDZO -ov "$dir/$NAME-$NEW.dmg"
  rm -rf "$dir/staging"
  local size sha
  size="$(stat -f %z "$dir/$NAME-$NEW.dmg")"
  sha="$(shasum -a 256 "$dir/$NAME-$NEW.dmg" | cut -d' ' -f1)"
  # The body as a release written like docs/release-notes-*.md: English up to the first heading,
  # Italian in the collapsed section at the bottom. The link must show as plain text.
  local body
  body="$(cat <<MD
$NAME $NEW is a local test of the update window.

- **Transpose**: move Live and Studio up or down by up to 12 semitones. See [the README](https://example.com).
- **Key**: Live and Studio show the key next to the BPM, and it follows the transpose.
- **Fixes**: the drums stay in time in Studio, and Save keeps the audio as it was.
- **Long line**: this line is long on purpose, to see how the window wraps a sentence that does not fit on one line.

## Requirements

- A Mac with Apple silicon.

<details>
<summary>Italiano</summary>

$NAME $NEW è una prova locale della finestra di aggiornamento.

- **Trasponi**: sposta Live e Studio in su o in giù fino a 12 semitoni. Vedi [il README](https://example.com).
- **Tonalità**: Live e Studio mostrano la tonalità accanto ai BPM, e segue il transpose.
- **Correzioni**: nello Studio la batteria resta a tempo, e il Salva tiene l'audio com'era.
- **Riga lunga**: questa riga è lunga apposta, per vedere come la finestra manda a capo una frase che non sta su una riga.

</details>
MD
)"
  if [ -n "${STELIX_TEST_NOTES:-}" ]; then body="$(cat "$STELIX_TEST_NOTES")"; fi
  python3 -I -c 'import json, sys
tag, port, name, app, size, sha, published, body = sys.argv[1:]
print(json.dumps({
    "tag_name": tag, "name": tag, "draft": False, "prerelease": False,
    "html_url": f"http://127.0.0.1:{port}/{name}/notes.html", "published_at": published, "body": body,
    "assets": [{"name": f"{app}-{tag}.dmg", "size": int(size), "digest": "sha256:" + sha,
                "browser_download_url": f"http://127.0.0.1:{port}/{name}/{app}-{tag}.dmg"}],
}, indent=1))' "$NEW" "$PORT" "$name" "$NAME" "$size" "$sha" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$body" \
    > "$dir/latest.json"
  echo "<h1>$NAME $NEW ($name)</h1><p>Release notes of the local test.</p>" > "$dir/notes.html"
  echo "$name: $NAME $NEW, $size bytes, sha256 $sha"
}

make_variant good "$IDENTITY"
make_variant adhoc "-"
echo "Serve with: python3 -m http.server $PORT --bind 127.0.0.1 --directory $OUT"
