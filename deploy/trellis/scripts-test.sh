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
# The venv lives outside the repo and is reused across runs. NOT under $TMPDIR: macOS reaps files
# there that have not been read for a few days, and it takes `pyvenv.cfg` while leaving the
# directories and the symlinks. What is left looks exactly like a venv and is not one — without
# `pyvenv.cfg` the interpreter runs in system mode, so `pip install` goes to the Homebrew Python and
# dies with PEP 668's "externally-managed-environment", days after the last good run.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV="${TRELLIS_VENV:-$HOME/.cache/trellis-test-venv}"

# `pyvenv.cfg`, not `bin/python`: the second answers "is there an interpreter here?" when the
# question is "is this a venv?", and the reaped tree above answers yes to the first and no to the
# second. Rebuilt rather than repaired — a half-eaten venv has no state worth keeping.
if [ ! -f "$VENV/pyvenv.cfg" ]; then
  echo "==> creating venv at $VENV"
  rm -rf "$VENV"
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
