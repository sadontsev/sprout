"""When to tell the user the plate is cool enough to take the print off.

Pure and dependency-free so it can be unit-tested without FastAPI/httpx/APNs — app.py owns the
polling and the push, this owns the decision. That split matters here: a notification that never
fires looks exactly like a printer that never finished, and the same class of bug already bit this
service once (a PAUSE maps to kind "live", so a kind-edge-triggered alert could never see it).

Two rules, and the second is not optional:

1. THRESHOLD. Bambu publishes exactly one number, for the Textured PEI plate: "we always recommend
   waiting until it reaches 35℃ or lower", stated for the heatbed. That is the sensor we read.

2. PLATEAU. A plate approaches room temperature asymptotically and can never cross it. With a 35°C
   target in a room that sits near 28°C — and warmer in summer — the threshold may simply never
   arrive, and a threshold-only rule would leave the user with no notification at all and nothing to
   diagnose. So once the bed stops falling, that IS as cool as it will get, and we say so.

Both are gated behind an ARM step: the bed must have been hot during an actual print before a
crossing means anything, or an already-cold idle printer would announce itself forever.
"""
from __future__ import annotations

from typing import Any

# Bambu's published figure for the textured PEI plate.
COOL_DEFAULT_C = 35.0
# Below ~30°C the threshold collides with room temperature and may never be reached. Above ~45°C we
# would be inviting someone to grab metal hot enough to burn: EN ISO 13732-1 puts the 10-minute
# contact threshold for bare metal at 48°C, and flexing a plate is a firm multi-second grip.
COOL_MIN_C = 30.0
COOL_MAX_C = 45.0
# "Stopped cooling" = less than this much movement across this window.
PLATEAU_WINDOW_S = 15 * 60
PLATEAU_DELTA_C = 1.0
# Sanity floor: a 0 reading means "no data", not "frozen plate".
MIN_VALID_BED_C = 1.0

READY = "ready"
STALLED = "stalled"


def clamp_threshold(v: Any, default: float = COOL_DEFAULT_C) -> float:
    """Keep a configured threshold inside the defensible band."""
    try:
        f = float(v)
    except (TypeError, ValueError):
        return default
    if f != f or f in (float("inf"), float("-inf")):  # NaN / inf
        return default
    return min(COOL_MAX_C, max(COOL_MIN_C, f))


def new_state() -> dict:
    """Fresh per-printer tracker."""
    return {"armed": False, "fired": False, "seen": []}


def cool_step(printing: bool, bed_now: float, threshold: float, state: dict | None, now: float) -> tuple[str | None, dict]:
    """Advance the cooldown tracker one poll.

    Returns (action, next_state) where action is READY, STALLED or None. The caller sends the push;
    this function decides. Never mutates the state it is given.
    """
    s = dict(state or new_state())
    s.setdefault("armed", False)
    s.setdefault("fired", False)
    s.setdefault("seen", [])

    if printing:
        # Arm only once the bed is genuinely hot, so a cold-bed print (or a printer idling warm)
        # cannot set up a spurious announcement. Clear history: the previous cooldown is irrelevant.
        return None, {"armed": bool(s["armed"] or bed_now > threshold), "fired": False, "seen": []}

    try:
        bed = float(bed_now)
    except (TypeError, ValueError):
        return None, s
    if not s["armed"] or s["fired"] or not bed >= MIN_VALID_BED_C:
        return None, s

    seen = [p for p in s["seen"] if now - p[0] <= PLATEAU_WINDOW_S]
    seen.append([now, bed])
    s["seen"] = seen

    if bed <= threshold:
        return READY, {"armed": False, "fired": True, "seen": []}

    # Needs the window actually spanned — three readings seconds apart prove nothing.
    if len(seen) >= 3 and (seen[-1][0] - seen[0][0]) >= PLATEAU_WINDOW_S * 0.8:
        temps = [p[1] for p in seen]
        if max(temps) - min(temps) < PLATEAU_DELTA_C:
            return STALLED, {"armed": False, "fired": True, "seen": []}

    return None, s
