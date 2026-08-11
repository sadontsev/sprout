"""The Live-Activity card registry: one key, many devices.

`_regs` used to map a card key to a single registration. That was correct while
exactly one phone existed. With two, every read of it answers a question about
"the card" that now has several answers, and the failure modes are all silent:
APNs answers 200 to a push nobody sees, so a starved or frozen card is visually
indistinguishable from a working one.

This module owns the list discipline so it is written once rather than at each
of the ~27 sites that touch the registry, and so it can be tested — `app.py` has
no tests, and its poll loop swallows exceptions, which means a mistake there
shows up as a healthy-looking service that has quietly stopped pushing.

Three invariants, each of which had a specific way of going wrong:

1. **Per-element state stays per element.** `lastPush`, `lastState`, `client`
   and `iconUri` describe one device. Hoisting `lastPush` to the key makes one
   device's push start another's 30-second throttle, halving its update rate or
   starving it entirely. Hoisting `lastState` is worse: `meaningful_change`
   compares against a state the other device never received, so its card freezes
   at old content forever.
2. **An empty list is never stored.** `key in _regs` is used to mean "a card
   exists here", and an empty list is truthy in that test. A stale empty key
   silently disables push-to-start for that printer, on every device, forever.
3. **Drops are per token.** A 400 or 410 is a statement about one device's
   token. Removing the whole key destroys the other devices' live cards — they
   freeze, are never ended, and because the key vanished the next tick starts a
   duplicate on top.
"""

from __future__ import annotations

from typing import Any, Iterable, Optional

# Registrations migrated from the single-card format predate device ids. They
# get this sentinel so device-scoped operations can still reason about them
# instead of treating them as belonging to everyone.
LEGACY_DEVICE = "legacy"

Registry = dict[str, list[dict]]


def coerce(raw: Any) -> Registry:
    """Normalise whatever is on disk into the list form.

    This is deliberately permanent rather than a one-shot migration: rolling
    back to the previous image rewrites the file in the single-card shape, and a
    subsequent re-upgrade has to survive that round trip.
    """
    out: Registry = {}
    if not isinstance(raw, dict):
        return out

    for key, value in raw.items():
        if isinstance(value, dict):
            cards = [value]
        elif isinstance(value, list):
            cards = [c for c in value if isinstance(c, dict)]
        else:
            cards = []

        for card in cards:
            card.setdefault("deviceId", LEGACY_DEVICE)
        if cards:
            out[str(key)] = cards
    return out


def cards(regs: Registry, key: str) -> list[dict]:
    """Every registration under key. Never None, so callers can iterate freely."""
    return regs.get(key) or []


def device_of(reg: dict) -> str:
    return str(reg.get("deviceId") or LEGACY_DEVICE)


def has_card(regs: Registry, key: str, device_id: str) -> bool:
    """Whether *this device* holds a card here.

    The predicate the push-to-start gate needs. Asking "does the key exist"
    instead answers a nearby question: once one phone adopts a card, the other
    never receives a start again, for any print, and nothing logs.
    """
    return any(device_of(reg) == device_id for reg in cards(regs, key))


def upsert(regs: Registry, key: str, reg: dict) -> None:
    """Add or replace one device's registration under key.

    Identity is the device id, falling back to the push token for legacy
    entries, so a device re-registering after a token rotation replaces its own
    row rather than accumulating one per rotation.
    """
    reg.setdefault("deviceId", LEGACY_DEVICE)
    existing = regs.setdefault(key, [])
    device = device_of(reg)
    token = reg.get("pushToken")

    for i, current in enumerate(existing):
        same_device = device != LEGACY_DEVICE and device_of(current) == device
        same_token = token is not None and current.get("pushToken") == token
        if same_device or same_token:
            existing[i] = reg
            return
    existing.append(reg)


def drop_token(regs: Registry, key: str, token: str) -> bool:
    """Remove the registration holding token. Returns whether anything went.

    Per token because that is what APNs told us about. Removing the key would
    take every other device's card with it.
    """
    existing = regs.get(key)
    if not existing:
        return False

    remaining = [reg for reg in existing if reg.get("pushToken") != token]
    if len(remaining) == len(existing):
        return False
    _store(regs, key, remaining)
    return True


def drop_device(regs: Registry, key: str, device_id: str) -> bool:
    """Remove one device's registration under key."""
    existing = regs.get(key)
    if not existing:
        return False

    remaining = [reg for reg in existing if device_of(reg) != device_id]
    if len(remaining) == len(existing):
        return False
    _store(regs, key, remaining)
    return True


def drop_key(regs: Registry, key: str) -> None:
    """Remove every registration under key. For cases that genuinely concern the
    card as a whole, such as a printer being deleted."""
    regs.pop(key, None)


def prune_device(regs: Registry, device_id: str, seen_tokens: Iterable[str]) -> list[str]:
    """Drop this device's registrations whose token it no longer reports.

    The /sync reconcile, scoped. Unscoped it is the most damaging operation in
    the service: opening the app on one phone deregisters every card on every
    other phone, which then freeze — never updated, never ended — while the next
    tick starts duplicates underneath them.
    """
    seen = set(seen_tokens)
    dropped: list[str] = []

    for key in list(regs):
        existing = regs.get(key) or []
        remaining = [
            reg for reg in existing
            if device_of(reg) != device_id or reg.get("pushToken") in seen
        ]
        if len(remaining) != len(existing):
            dropped.append(key)
            _store(regs, key, remaining)
    return dropped


def printer_ids(regs: Registry) -> set[int]:
    """Every printer with at least one live card."""
    out: set[int] = set()
    for existing in regs.values():
        for reg in existing:
            try:
                out.add(int(reg["printerId"]))
            except (KeyError, TypeError, ValueError):
                continue
    return out


def all_tokens(regs: Registry) -> set[str]:
    return {
        reg["pushToken"]
        for existing in regs.values()
        for reg in existing
        if reg.get("pushToken")
    }


def card_count(regs: Registry) -> int:
    """Total registrations, not keys.

    The operator reads this after a deploy to confirm state survived. Counting
    keys would report three when six exist, making a half-failed migration look
    clean.
    """
    return sum(len(existing) for existing in regs.values())


def count_by(regs: Registry, classify) -> dict[str, int]:
    """Tally registrations by some per-element property, such as the client
    discriminator. A mixed fleet is exactly when this matters, so it must not
    assume one value per key."""
    out: dict[str, int] = {}
    for existing in regs.values():
        for reg in existing:
            label = str(classify(reg))
            out[label] = out.get(label, 0) + 1
    return out


def find_by_token(regs: Registry, token: str) -> Optional[tuple[str, dict]]:
    """Locate the registration holding token, with its key."""
    for key, existing in regs.items():
        for reg in existing:
            if reg.get("pushToken") == token:
                return key, reg
    return None


def _store(regs: Registry, key: str, remaining: list[dict]) -> None:
    """Write back, deleting the key when nothing is left.

    Invariant 2 lives here. An empty list left behind keeps `key in regs` true,
    which reads as "a card exists" and silently blocks push-to-start forever.
    """
    if remaining:
        regs[key] = remaining
    else:
        regs.pop(key, None)
