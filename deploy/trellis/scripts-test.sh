#!/usr/bin/env bash
# Run the whole Trellis suite, including the tests that need the service's own dependencies.
#
# Why this exists: 13 of the 183 tests import fastapi/httpx, and a plain
# `python3 -m unittest discover deploy/trellis` on a Mac without them SKIPS twelve and ERRORS on
# one. That reads as a passing suite to anyone not counting, and the twelve it skips are precisely
# the integration tests over app.py's multi-device registry — the code with no other coverage.
#
# The tests are also NOT in the container image (the Dockerfile copies only the service modules), so
# "run it inside the container" does not reach them either. Between the two, those twelve had never
# executed anywhere until this script.
#
# The venv lives outside the repo and is reused across runs.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV="${TRELLIS_VENV:-${TMPDIR:-/tmp}/trellis-test-venv}"

if [ ! -x "$VENV/bin/python" ]; then
  echo "==> creating venv at $VENV"
  python3 -m venv "$VENV"
fi

echo "==> installing service dependencies"
"$VENV/bin/pip" install -q -r "$HERE/requirements.txt"

echo "==> running the suite"
cd "$HERE"
"$VENV/bin/python" -m unittest discover . "$@"

# A skip here means a dependency did not install, not that a test was inapplicable — the guards in
# test_app_registry.py and test_makerworld.py key on ImportError alone, so a broken app.py fails
# rather than skipping. Surface the count so a silent regression to skipping is visible.
echo "==> if any test above reported 'skipped', the venv is incomplete — investigate, do not ignore"
