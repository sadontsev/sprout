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


def hms_reason(hms_errors: list[dict] | None) -> str | None:
    """The sentence to put on a banner for the fault that halted this print, or None.

    Bambuddy resolves a description for the 8-char ``print_error`` family only — that table is
    keyed ``MMMM_EEEE``, which is a ``print_error`` full_code split in half, and the 16-char
    ``hms[]`` family matches no key. So most faults still have nothing to say, and this returns
    None rather than inventing something. "Spaghetti defects were detected", "Filament ran out"
    and ~434 others do resolve, and those are the ones worth naming on a lock screen.

    **The LAST resolving entry, not the first.** ``hms_errors`` accumulates across a print: the
    print_error branch appends and only clears on a payload bearing a fresh ``hms`` array or on a
    new print. The first entry is therefore the OLDEST fault the printer has mentioned, which on a
    long print is very unlikely to be the one that just halted it.

    The ``len == 8`` test is not a formatting nicety either — it confines the answer to the branch
    that fires on a halt.
    """
    for err in reversed(hms_errors or []):
        if len(str(err.get("full_code") or "")) != 8:
            continue
        text = (err.get("description") or "").strip()
        if text:
            return text
    return None


def wake_push_due(now: float, due: float | None) -> bool:
    """Whether a card owes a re-render because the app has just been woken to fetch its picture.

    The card is re-rendered when its ContentState changes, and `meaningful_change` decides that by
    comparing NUMBERS. After a wake nothing numeric has changed — a print in its calibration phase
    sits at progress 0, layer 0, with the temperatures settled — so the card kept drawing the brand
    glyph until the 450 s heartbeat came round, minutes after the plate was already on disk. The
    picture appearing is a reason to push that the numeric predicate cannot see; it answers "did the
    readings move", which is the neighbouring question.

    `due` is a timestamp rather than a flag because the app needs a moment to actually fetch the
    thing: measured on a real wake, the cover arrived one second after the push. Pushing in the same
    tick would re-render a card whose file does not exist yet, spend the update, and change nothing.
    """
    return due is not None and now >= due


def may_wake(now: float, last: float | None, min_interval: float) -> bool:
    """Whether a device may be woken by a silent push again yet.

    Apple: "the system may throttle the delivery of background notifications if the total number
    becomes excessive ... don't try to send more than two or three per hour." That ceiling is the
    whole reason this rule exists, and it lives here as a tested function rather than as an inline
    comparison so it can be checked without a printer.

    Being throttled is not an error the service sees — iOS simply stops delivering, and the symptom
    is a card that never gets its picture. So the floor is deliberately far below the ceiling: one
    wake per printer per half hour spends at most two an hour even if every print were half an hour
    long.

    `last` is None when this device has never been woken, and that is a DIFFERENT question from
    "has enough time passed", so it gets its own answer rather than a zero sentinel. A sentinel
    works here only because real timestamps are enormous — `now - 0 >= 1800` is true for every clock
    reading since 1970 — which is a dependency on the units nobody would think to check, and a test
    written with small numbers found it immediately.
    """
    if last is None:
        return True
    return now - last >= min_interval


def aggregate_should_start(identity: str, started_for: str | None, has_rearm: bool) -> bool:
    """Whether to push-to-start the AGGREGATE drying card now.

    A different question from ``should_start``, and that is why it is a different function rather
    than a call into that one. ``should_start`` deliberately refuses to compare identity, because a
    print's identity is unstable early on — Bambuddy assigns the archive id a little after printing
    begins and comparing values started a second card. The aggregate's identity is the SET of
    cycles, which is stable and which genuinely selects the card: a unit joining or leaving the
    batch means the card shows different rows, so it is a different card.

    It used to be written inline as ``should_start(_p2s_tokens, akey)`` — two arguments to a
    four-parameter function, so the first batch of two simultaneous cycles would have raised
    TypeError into the poll loop's catch-all rather than starting a card. Never observed, because it
    needs two units drying at once with no card up yet; a rule with no test and no call of its own
    is how that survived review.

    identity    the set of cycles this card would show
    started_for what we recorded when we last started on this key (None = not this session)
    has_rearm   a device holds a replacement grant, which overrides the arming answer
    """
    return started_for != identity or has_rearm


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
