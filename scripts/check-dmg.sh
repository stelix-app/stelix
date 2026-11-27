#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.
# Checks a release DMG with the rules every installed Stelix applies before opening an update
# (DiskImageCheck in StelixCore): one volume; at its top only the app, a link named Applications to
# /Applications, .DS_Store, .VolumeIcon.icns and the .background, .fseventsd and .Trashes folders
# holding plain, non-executable files; one app, signed to satisfy <requirement>, at <version>.
# A published release can't be changed: a DMG that fails here would be refused by every copy of Stelix.
# Usage: scripts/check-dmg.sh <dmg> <version> <requirement>
set -euo pipefail

DMG="${1:-}"
VERSION="${2:-}"
REQUIREMENT="${3:-}"
[ -n "$DMG" ] && [ -n "$VERSION" ] && [ -n "$REQUIREMENT" ] || {
  echo "Usage: scripts/check-dmg.sh <dmg> <version> <requirement>" >&2
  exit 64
}
fail() { echo "Error: $DMG: $*" >&2; exit 1; }

MOUNT="$(mktemp -d "${TMPDIR:-/tmp}/StelixCheckDMG.XXXXXX")"
PLIST="$MOUNT.plist"
cleanup() {
  hdiutil detach -quiet "$MOUNT" 2>/dev/null || hdiutil detach -quiet -force "$MOUNT" 2>/dev/null || true
  rmdir "$MOUNT" 2>/dev/null || true
  rm -f "$PLIST"
}
trap cleanup EXIT

# The same flags as DiskImageCheck; no input, so an image with a license agreement fails.
hdiutil attach -plist -nobrowse -readonly -noautoopen -mountpoint "$MOUNT" "$DMG" \
  < /dev/null > "$PLIST" 2>/dev/null || fail "hdiutil can't attach it"

# One volume, mounted where asked: opening the DMG would mount every volume it holds.
COUNT="$(plutil -extract system-entities raw "$PLIST")"
VOLUMES=0
for ((i = 0; i < COUNT; i++)); do
  if plutil -extract "system-entities.$i.mount-point" raw "$PLIST" > /dev/null 2>&1 ||
     [ "$(plutil -extract "system-entities.$i.potentially-mountable" raw "$PLIST" 2>/dev/null)" = "true" ]; then
    VOLUMES=$((VOLUMES + 1))
  fi
done
[ "$VOLUMES" -eq 1 ] || fail "$VOLUMES volumes, not one"

plain_files_only() { # folder
  local entry
  for entry in "$1"/* "$1"/.[!.]* "$1"/..?*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    [ -f "$entry" ] && [ ! -L "$entry" ] && [ ! -x "$entry" ] || return 1
  done
}

APPS=()
for entry in "$MOUNT"/* "$MOUNT"/.[!.]* "$MOUNT"/..?*; do
  [ -e "$entry" ] || [ -L "$entry" ] || continue
  name="$(basename "$entry")"
  if [ -L "$entry" ]; then
    [ "$name" = "Applications" ] && [ "$(readlink "$entry")" = "/Applications" ] ||
      fail "the link $name must be Applications, pointing to /Applications"
  elif [ -d "$entry" ] && [ "${name%.app}" != "$name" ]; then
    APPS+=("$entry")
  elif [ -f "$entry" ] && { [ "$name" = ".DS_Store" ] || [ "$name" = ".VolumeIcon.icns" ]; }; then
    :
  elif [ -d "$entry" ] && { [ "$name" = ".background" ] || [ "$name" = ".fseventsd" ] || [ "$name" = ".Trashes" ]; }; then
    plain_files_only "$entry" || fail "$name may hold only plain, non-executable files"
  else
    fail "$name is not allowed at the top of the image"
  fi
done
[ "${#APPS[@]}" -eq 1 ] || fail "${#APPS[@]} apps at the top of the image, not one"
APP="${APPS[0]}"

codesign --verify --strict --deep --all-architectures -R="$REQUIREMENT" "$APP" 2>/dev/null ||
  fail "the app's signature doesn't satisfy $REQUIREMENT"

FOUND="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[ "$FOUND" = "$VERSION" ] || fail "the app's version is $FOUND, not $VERSION"

echo "check-dmg: ok ($(basename "$APP") $VERSION)"
