#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.
# StelixCore tests with xcodebuild, then the pytest of the sidecar and of the scripts.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

cd "$ROOT/Packages/StelixCore"
xcodebuild test -scheme StelixCore -destination 'platform=macOS'

if [ -d "$ROOT/sidecar/tests" ]; then
  cd "$ROOT/sidecar"
  uv run --frozen pytest -q
  # The scripts' own tests, with the same environment.
  uv run --frozen pytest -q "$ROOT/scripts/tests"
fi
