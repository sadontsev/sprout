"""Which iOS app a Live-Activity registration came from, and the wire shape that app needs.

TWO APPS, ONE BUNDLE ID. `com.mvks5.bambu` ships as two different TestFlight builds — the React
Native app (`mobile/`, Live Activities via expo-widgets) and the native SwiftUI rewrite (`native/`) —
and the owner switches between them to compare. They disagree about the JSON a Live-Activity push
must carry, in two places, and BOTH failures are silent: APNs answers 200 and the update simply never
lands on the card, exactly like a wrong-gateway token.

  * CONTENT STATE. expo-widgets' native ContentState is `Codable{name: String, props: String}`, so
    the real fields travel inside `props` as a JSON *string*. The native app's
    `PrintActivityAttributes.ContentState` is FLAT (see native/Shared/PrintActivityAttributes.swift),
    so the very wrapper the RN app requires is what fails to decode there.
  * PUSH-TO-START ATTRIBUTES. A start payload names the attributes TYPE it is creating. expo-widgets
    registers `LiveActivityAttributes` and stores nothing in it; the native app registers
    `PrintActivityAttributes(printerId:amsId:)` and gets no card at all without the right type name
    and the ids inside it.

Nothing in a push tells the two apart, so each registration and each push-to-start token records
which app made it and these builders follow that. `EXPO` is the default EVERYWHERE: the RN build is
already installed and can only be changed by an OTA, so an absent discriminator — in a request body
or in a registrations.json written before this existed — has to keep meaning "expo".

Dependency-free (stdlib only) like p2s.py and cooldown.py, so its tests run anywhere the service
does, including inside the container.
"""
from __future__ import annotations

import json
from typing import Any

EXPO = "expo"
NATIVE = "native"

# Every NON-OPTIONAL field of the native ContentState, with the value Swift declares as its default.
#
# Swift's synthesized `Decodable` does NOT fall back to a property's default when a key is missing —
# it throws — and one missing key discards the WHOLE push while APNs still answers 200. That is not
# theoretical here: the end payloads are built by merging over a card's stored `lastState`, which is
# None for a card that ended before it was ever updated, so an end could arrive with six keys and be
# dropped, leaving the card on the lock screen forever. Padding costs a few bytes and removes the
# failure mode. Optional fields (dry/amsTemp/amsTarget/humidity) are deliberately absent — Swift
# decodes those with decodeIfPresent, and a print card must not claim to be a drying card.
NATIVE_BASE: dict[str, Any] = {
    "printerName": "", "name": "", "stateLabel": "", "progress": 0, "layer": 0, "totalLayers": 0,
    "etaEpochMs": 0, "finished": False, "symbol": "printer.fill", "iconUri": "",
    # = COLORS["running"] in app.py, = LAColors.running in Swift. Only ever used to pad a sparse
    # payload; every real content state carries its own tint.
    "tint": "#30D158",
    "nozzle": 0, "nozzleTarget": 0, "nozzle2": 0, "nozzle2Target": 0, "hasNozzle2": False,
    "activeNozzle": 0, "bed": 0, "bedTarget": 0, "modelUri": "", "queueCount": 0, "nextName": "",
}


def norm_client(value: Any) -> str:
    """Normalise a client discriminator, defaulting anything unrecognised to EXPO.

    Deliberately lenient rather than a 422: a typo'd or future value must degrade to the behaviour
    the installed RN app already depends on, not reject the registration outright — a refused
    registration is a card frozen at the content it was created with, and the app has no way to tell
    that apart from Trellis being down.
    """
    return NATIVE if isinstance(value, str) and value.strip().lower() == NATIVE else EXPO


def client_of(reg: dict | None) -> str:
    """The client a stored registration belongs to. Registrations written before this field existed
    have no key, and those are all RN cards — hence EXPO, not an error."""
    return norm_client((reg or {}).get("client"))


def envelope(cs: dict, client: str) -> dict:
    """The APNs `content-state` for this client's ContentState type (see the module docstring)."""
    if norm_client(client) == NATIVE:
        return {**NATIVE_BASE, **cs}
    return {"name": "PrintActivity", "props": json.dumps(cs, separators=(",", ":"))}


def start_attributes(client: str, printer_id: int, ams_id: int | None) -> tuple[str, dict]:
    """`(attributes-type, attributes)` for a push-to-start payload.

    The native app identifies a card by its ATTRIBUTES — `printerId` alone is not enough, because a
    print and up to three drying cycles run concurrently on one machine — so a start that omits them
    produces a card the app cannot match to anything it renders. `amsId` is omitted rather than sent
    as null for a print card: it is `Int?` in Swift and a drying card is identified BY carrying it.
    """
    if norm_client(client) != NATIVE:
        # expo-widgets' generic attributes type, which stores nothing. Unchanged from before there
        # was a second client, and the installed RN build still expects exactly this.
        return "LiveActivityAttributes", {}
    attrs: dict[str, Any] = {"printerId": int(printer_id)}
    if ams_id is not None:
        attrs["amsId"] = int(ams_id)
    return "PrintActivityAttributes", attrs


def key_ids(key: str) -> tuple[int, int | None]:
    """`(printerId, amsId)` for a registry key: `"<pid>"`, or `"dry:<pid>:<amsId>"` for a drying card
    (`"dry:<pid>"` is the legacy per-printer form, which has no unit id)."""
    if not key.startswith("dry:"):
        return int(key), None
    parts = key.split(":")
    ams = int(parts[2]) if len(parts) > 2 and parts[2].lstrip("-").isdigit() else None
    return int(parts[1]), ams
