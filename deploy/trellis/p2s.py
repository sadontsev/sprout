"""When may Trellis remotely start a Live Activity?

THE BUG THIS EXISTS TO KILL. A push-to-started card is unreachable until the app hands us its push
token — we can neither update nor end it. The old rule allowed one outstanding start at a time and
expired that claim after 10 minutes, on the assumption that the app would soon run, adopt the card
or report it as an orphan. When the app stays closed — which is the whole point of push-to-start —
nothing ever adopted anything, the claim expired, the "this printer is live and has no card"
condition became true again, and another card was started. Every ten minutes. The live log showed
199 starts against 225 expiries for a single print, and the lock screen showed three stacked cards
frozen at the moments they happened to be created.

THE RULE. A card is started at most once per PRINT, keyed by the print's identity rather than by a
timeout. Identity changing (a new print) is the only thing that re-arms it. That makes duplication
impossible by construction instead of relying on a cleanup that may never run.

The cost is deliberate and small: if the user swipes a card away mid-print they do not get another
one until the next print. That is strictly better than three, and the app repairs it the moment it
runs — /sync tells us which cards actually exist.
"""
from __future__ import annotations

from typing import Any


def print_identity(status: dict, fields: dict) -> str:
    """A stable id for the CURRENT print.

    Prefers the archive id, which Bambuddy assigns per print job. Falls back to the subtask name so
    a machine that reports no archive still gets one card rather than one every ten minutes. Empty
    string means "nothing identifiable", which callers treat as a single anonymous print.
    """
    aid = status.get("current_archive_id")
    if isinstance(aid, int) and aid > 0:
        return f"a{aid}"
    name = (fields.get("name") or status.get("subtask_name") or "").strip()
    return f"n{name}" if name else "unknown"


def dry_identity(ams_id: int, unit: dict) -> str:
    """A stable id for one unit's CURRENT drying cycle.

    The filament and target are fixed for a cycle, so they identify it without depending on the
    remaining-minutes countdown, which changes every poll.
    """
    fil = (unit.get("dry_filament") or "").strip()
    target = unit.get("dry_target_temp")
    return f"{ams_id}:{fil}:{target}"


def should_start(active: bool, identity: str, started_for: str | None, has_card: bool) -> bool:
    """Whether to push-to-start a card now.

    active      the thing the card is about is happening (printing, or this unit is drying)
    identity    identity of that print/cycle (recorded for diagnosis; see below)
    started_for what we recorded when we last started on this key (None = not this session)
    has_card    a registered card already exists for this key (the app adopted one)

    Arming is per LIVE SESSION, not per identity value. Identity is deliberately NOT compared:
    it is not stable early in a print. Bambuddy assigns the archive id a little after printing
    begins, so the identity legitimately changes from the subtask name to "a125" mid-print — and
    comparing values treated that as a new print and started a SECOND card. Observed live:

        [p2s] start print 2 [nSide changed. Mounting for top left…]
        [p2s] start print 2 [a125]

    Only leaving the live state re-arms a start (see next_started_for), which is exactly once per
    print because every print passes through FINISH before the next one begins.
    """
    if not active or has_card:
        return False
    return started_for is None


def next_started_for(active: bool, identity: str, started_for: str | None) -> str | None:
    """The value to persist after a tick. Clearing on leaving the live state is the ONLY thing that
    re-arms a start. The value itself is just the latest identity, kept for logs — the arming
    decision never compares it (see should_start)."""
    if not active:
        return None
    return identity


def prune(started: dict[str, Any], live_keys: set[str]) -> dict[str, Any]:
    """Drop bookkeeping for keys that are no longer live, so the map cannot grow without bound
    across printers and AMS units."""
    return {k: v for k, v in started.items() if k in live_keys}
