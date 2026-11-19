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
  cat > "$dir/latest.json" <<JSON
{"tag_name": "$NEW", "name": "$NEW", "draft": false, "prerelease": false,
 "html_url": "http://127.0.0.1:$PORT/$name/notes.html",
 "published_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
 "assets": [{"name": "$NAME-$NEW.dmg", "size": $size, "digest": "sha256:$sha",
             "browser_download_url": "http://127.0.0.1:$PORT/$name/$NAME-$NEW.dmg"}]}
JSON
  echo "<h1>$NAME $NEW ($name)</h1><p>Release notes of the local test.</p>" > "$dir/notes.html"
  echo "$name: $NAME $NEW, $size bytes, sha256 $sha"
}

make_variant good "$IDENTITY"
make_variant adhoc "-"
echo "Serve with: python3 -m http.server $PORT --bind 127.0.0.1 --directory $OUT"
