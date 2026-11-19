#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.
# Launches StelixEngine from the terminal and forwards commands to it, one line per command. The engine's events
# (stdout) and logs (stderr) come out here. Terminal gets the capture permission.
#
# Usage: scripts/engine-repl.sh [path to StelixEngine]
#
# Shortcuts (everything else passes through as is, so JSON can be written by hand):
#   live [base|intermediate|pro]   startLive with all stems on (default intermediate)
#   level <level>                  setLiveLevel
#   mix <stem...>                  setMix: only the listed stems on (vocals drums bass other)
#   mix none | mix all             all off | all on
#   tel on|off                     setTelemetry
#   rec | recstop                  startRecording | stopRecording
#   sep <file> [base]              separateFile (the path may contain spaces; level at the end)
#   play | pause | seek <seconds>  Studio player
#   cancel                         cancelJob
#   (after rec or sep, mix uses the 6 Studio stems: vocals piano guitar bass drums other)
#   stop                           stopLive
#   quit                           shutdown, then exits
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENGINE="${1:-$ROOT/build/Build/Products/Release/Stelix.app/Contents/MacOS/StelixEngine}"
[ -x "$ENGINE" ] || { echo "$ENGINE is missing: run scripts/build.sh --no-install first" >&2; exit 1; }

STEMS=(vocals drums bass other)
STUDIO_STEMS=(vocals piano guitar bass drums other)

mix_json() {   # the arguments are the stems turned on
  local out="" stem on
  for stem in "${STEMS[@]}"; do
    on=false
    for s in "$@"; do [ "$s" = "$stem" ] && on=true; done
    out+="${out:+,}\"$stem\":{\"enabled\":$on,\"volume\":1}"
  done
  printf '{"controls":{%s}}' "$out"
}

translate() {
  local line words
  echo "engine-repl: $ENGINE (pid in the engine log). Type 'live' to start, 'quit' to exit." >&2
  while IFS= read -r -e -p "> " line; do
    read -r -a words <<<"$line" || true
    [ ${#words[@]} -eq 0 ] && continue
    case "${words[0]}" in
      live)  printf '{"startLive":{"level":"%s","mix":%s}}\n' "${words[1]:-intermediate}" "$(mix_json "${STEMS[@]}")" ;;
      level) printf '{"setLiveLevel":{"_0":"%s"}}\n' "${words[1]:-intermediate}" ;;
      mix)
        case "${words[1]:-all}" in
          all)  printf '{"setMix":{"_0":%s}}\n' "$(mix_json "${STEMS[@]}")" ;;
          none) printf '{"setMix":{"_0":%s}}\n' "$(mix_json)" ;;
          *)    printf '{"setMix":{"_0":%s}}\n' "$(mix_json "${words[@]:1}")" ;;
        esac ;;
      rec)   STEMS=("${STUDIO_STEMS[@]}"); echo '{"startRecording":{}}' ;;
      recstop) echo '{"stopRecording":{}}' ;;
      sep)
        STEMS=("${STUDIO_STEMS[@]}")
        local path="${line#sep }" level=base
        case "${words[${#words[@]}-1]}" in base|intermediate|pro) level="${words[${#words[@]}-1]}"; path="${path% *}" ;; esac
        python3 -c 'import json,sys; print(json.dumps({"separateFile": {"path": sys.argv[1], "level": sys.argv[2]}}))' "$path" "$level" ;;
      play)  echo '{"player":{"_0":{"play":{}}}}' ;;
      pause) echo '{"player":{"_0":{"pause":{}}}}' ;;
      seek)  printf '{"player":{"_0":{"seek":{"seconds":%s}}}}\n' "${words[1]:-0}" ;;
      cancel) echo '{"cancelJob":{}}' ;;
      tel)   [ "${words[1]:-on}" = "off" ] && echo '{"setTelemetry":{"_0":false}}' || echo '{"setTelemetry":{"_0":true}}' ;;
      stop)  echo '{"stopLive":{}}' ;;
      quit)  echo '{"shutdown":{}}'; break ;;
      *)     printf '%s\n' "$line" ;;
    esac
  done
}

# The engine's temporary folder is the one of the Stelix app: on macOS 27 FileManager.temporaryDirectory
# ignores TMPDIR, and an engine that exits empties the Studio's folder. With Stelix open it would delete
# the recording and the unsaved stems of the app, so the REPL refuses (STELIX_REPL_FORCE=1 to go ahead).
if pgrep -x Stelix >/dev/null && [ "${STELIX_REPL_FORCE:-0}" != 1 ]; then
  echo "Stelix is open: quit it first. An engine from here shares its temporary folder and empties it on exit." >&2
  echo "STELIX_REPL_FORCE=1 $0 to go ahead anyway." >&2
  exit 1
fi
# TMPDIR does not move the engine's folders (Stelix-Studio, Stelix-sidecar-*), both made from Swift; it stays for
# anything a Python library might write with tempfile.
REPL_TMP="$(mktemp -d "${TMPDIR:-/tmp}/stelix-repl.XXXXXX")"
trap 'rm -rf "$REPL_TMP"' EXIT
translate | TMPDIR="$REPL_TMP/" "$ENGINE"
