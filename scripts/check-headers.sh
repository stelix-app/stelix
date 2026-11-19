#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.
# Every source file carries the license header: the GPL asks each file to say where its terms are.
# Usage: scripts/check-headers.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
FAIL=0
while IFS= read -r f; do
  head -4 "$f" | grep -q 'SPDX-License-Identifier: GPL-3.0-only' \
    && head -4 "$f" | grep -q 'See the NOTICE file for the additional terms' \
    || { echo "check-headers: no license header in $f" >&2; FAIL=1; }
done < <(git ls-files --cached --others --exclude-standard -- \
  'App/*.swift' 'Engine/*.swift' 'Packages/*.swift' 'scripts/*.swift' \
  'scripts/*.sh' 'scripts/*.py' 'sidecar/*.py' 'project.yml' 'sidecar/pyproject.toml')
[ $FAIL -eq 0 ] && echo "check-headers: ok"
exit $FAIL
