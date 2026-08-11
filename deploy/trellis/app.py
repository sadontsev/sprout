"""
Trellis — keeps Sprout's iOS Live Activities updating when the app is closed.

The app (foreground) starts one Live Activity per printer and registers each card's APNs push token
with this service. This service polls Bambuddy for each registered printer's status and pushes the
Live-Activity ContentState to Apple (APNs, apns-push-type: liveactivity) so the lock-screen cards keep
tracking even after iOS suspends the app. It ends a card when its print finishes/fails/goes idle.

The ContentState shape MUST match PrintActivityProps in the app
(mobile/src/liveactivity/PrintActivity.tsx); the state/colour mapping mirrors present.ts.

TWO clients register here — that RN app and the native SwiftUI rewrite (native/), which ship as
different TestFlight builds of the SAME bundle id. Their Live-Activity wire shapes are incompatible
and both mismatches fail SILENTLY (APNs 200, nothing applied), so every registration carries a
`client` discriminator and the payload is built to match it. See clients.py.
"""
from __future__ import annotations

import asyncio
import hashlib
import json
import os
import time
from pathlib import Path
from typing import Any

import httpx
import jwt  # PyJWT
from fastapi import Depends, FastAPI, Header, HTTPException
from pydantic import BaseModel

import makerworld as mw
import canopy
import outbox as ob
import registry
from clients import EXPO, NATIVE, client_of, envelope, key_ids, norm_client, start_attributes
from cooldown import COOL_DEFAULT_C, COOL_MAX_C, COOL_MIN_C, READY, clamp_threshold, cool_step
from p2s import dry_identity, next_started_for, print_identity, prune, should_start

# ---- config (env) ----
BAMBUDDY_URL = os.environ.get("BAMBUDDY_URL", "http://localhost:8910").rstrip("/")
BAMBUDDY_API_KEY = os.environ["BAMBUDDY_API_KEY"]

# Push backend. DIRECT signs with this deployment's own APNs key; RELAY forwards to Canopy, which
# holds the key for App Store builds. Exactly one must be configured: both, or neither, is
# ambiguous about who is expected to sign, and a deployment that guesses would fail at the first
# push rather than at startup.
CANOPY_URL = os.environ.get("CANOPY_URL", "").rstrip("/")
APNS_KEY_PATH = os.environ.get("APNS_KEY_PATH", "/keys/apns_key.p8")
# In RELAY mode nothing Apple-specific lives here: no key, no key id, no team id, no topic, no
# host. That is the point — the owner can rotate the signing key without any self-hoster acting.
RELAY_MODE = bool(CANOPY_URL)
if RELAY_MODE and os.environ.get("APNS_KEY_ID"):
    raise SystemExit(
        "Both CANOPY_URL and APNS_KEY_ID are set. Exactly one push backend must be configured: "
        "CANOPY_URL to relay through Canopy, or the APNS_* set to sign locally. Configuring both "
        "leaves it ambiguous which key is expected to sign."
    )
if not RELAY_MODE and not os.environ.get("APNS_KEY_ID"):
    raise SystemExit(
        "No push backend configured. Set CANOPY_URL to relay through Canopy, or the APNS_* set to "
        "sign locally with your own key."
    )

APNS_KEY_ID = os.environ.get("APNS_KEY_ID", "")
APNS_TEAM_ID = os.environ.get("APNS_TEAM_ID", "")
APNS_TOPIC = os.environ.get("APNS_TOPIC", "com.mvks5.bambu.push-type.liveactivity")  # Live Activity topic
# The bundle id is the topic for regular alert notifications (print done / error).
APNS_BUNDLE_ID = os.environ.get("APNS_BUNDLE_ID", APNS_TOPIC.replace(".push-type.liveactivity", ""))
# Dev/Xcode builds use the SANDBOX gateway; TestFlight/App Store use production. Flip via env.
APNS_HOST = os.environ.get("APNS_HOST", "api.sandbox.push.apple.com")
POLL_INTERVAL = float(os.environ.get("POLL_INTERVAL", "5"))
# 30s: Live-Activity pushes draw from a per-device budget (even WITH the frequent-updates plist
# key). Priority-10 every 4s exhausted it within minutes — iOS then silently stops applying updates
# while APNs keeps answering 200 (observed: card froze shortly after each app open). The countdown
# and "ends" clock tick CLIENT-side from etaEpochMs, so a 30s data cadence loses nothing visible.
MIN_UPDATE_S = float(os.environ.get("MIN_UPDATE_S", "30"))
DATA_DIR = Path(os.environ.get("DATA_DIR", "/data"))
REG_FILE = DATA_DIR / "registrations.json"
# Canopy tenant credential. Lives beside the registrations rather than in the environment
# because it is issued at runtime, and is what a rebuild needs to re-adopt its bindings.
TENANT_FILE = DATA_DIR / "tenant.json"

# ---- state → content-state (mirrors present.ts + toContentState) ----
COLORS = {"running": "#30D158", "heating": "#FF9F0A", "paused": "#0A84FF", "error": "#FF453A", "idle": "#8E9398"}
SYMBOLS = {
    "Printing": "printer.fill", "Heating": "thermometer.medium", "Paused": "pause.circle.fill",
    "Complete": "checkmark.circle.fill", "Error": "exclamationmark.triangle.fill",
}


def _rnd(x: Any) -> int:
    try:
        return round(float(x))
    except (TypeError, ValueError):
        return 0


def _heating(explicit: Any, now: float, target: float, gap: float) -> bool:
    """Mirror present.ts heating(): trust the payload's explicit heating flag when present, else
    derive it from the temp gap. Keeps the background push card's Heating/Printing label in sync
    with the foreground app instead of second-guessing it from temperatures alone."""
    if isinstance(explicit, bool):
        return explicit
    return target > 0 and now < target - gap


def classify(status: dict) -> tuple[dict, str]:
    """Return (content-state-fields, kind). kind ∈ live|complete|error|idle|offline."""
    t = status.get("temperatures") or {}
    if not status.get("connected"):
        return ({"name": "", "stateLabel": "Offline", "tint": COLORS["idle"], "progress": 0, "layer": 0,
                 "totalLayers": 0, "etaEpochMs": 0, "finished": False, "symbol": SYMBOLS["Error"],
                 "nozzle": 0, "nozzleTarget": 0, "nozzle2": 0, "nozzle2Target": 0,
                 "hasNozzle2": False, "activeNozzle": 0, "bed": 0, "bedTarget": 0,
                 "modelUri": "", "queueCount": 0, "nextName": ""}, "offline")

    state = (status.get("state") or "").upper()
    progress = _rnd(status.get("progress"))
    layer = int(status.get("layer_num") or 0)
    total = int(status.get("total_layers") or 0)
    remaining = status.get("remaining_time") or 0

    # Nozzles are physical: n1 = left/only head, n2 = right (H2-series). Pick the ACTIVE head exactly as
    # present.ts does: the DRIVEN head (only one has a target; the idle one reads 0), else the hotter one
    # (a just-deactivated head can still be hotter mid tool-change, so a temp compare alone misfires).
    # status.active_extruder is intentionally IGNORED — it reports the wrong index on the live H2C.
    n1, n1t = _rnd(t.get("nozzle")), _rnd(t.get("nozzle_target"))
    has_n2 = t.get("nozzle_2") is not None
    n2, n2t = _rnd(t.get("nozzle_2")), _rnd(t.get("nozzle_2_target"))
    active_idx = 0
    if has_n2:
        if (n1t > 0) != (n2t > 0):
            active_idx = 1 if n2t > 0 else 0
        else:
            active_idx = 1 if n2 > n1 else 0
    anoz, anoz_t = (n2, n2t) if active_idx == 1 else (n1, n1t)  # active head, for the heating heuristic
    bed, bed_t = _rnd(t.get("bed")), _rnd(t.get("bed_target"))

    finished = False
    if status.get("print_error") or state in ("FAILED", "ERROR"):
        label, color, kind = "Error", COLORS["error"], "error"
    elif state in ("PAUSE", "PAUSED"):
        label, color, kind = "Paused", COLORS["paused"], "live"
    elif state in ("FINISH", "FINISHED", "FINISHING"):
        label, color, kind, finished = "Complete", COLORS["running"], "complete", True
    elif state in ("IDLE", "", "UNKNOWN"):
        label, color, kind = "Idle", COLORS["idle"], "idle"
    else:
        stage = (status.get("stg_cur_name") or "").strip()
        in_stage = bool(stage) and stage.lower() != "printing"
        # Mirror present.ts: explicit heating flag (for the ACTIVE head) wins over the temp gap; gate on
        # RAW progress, not the rounded display value — else the pushed card's label can disagree with
        # the in-app dashboard during the early-print heat-soak.
        noz_heat = _heating(t.get("nozzle_2_heating") if active_idx == 1 else t.get("nozzle_heating"), anoz, anoz_t, 3)
        bed_heat = _heating(t.get("bed_heating"), bed, bed_t, 2)
        heating_up = (noz_heat or bed_heat) and (status.get("progress") or 0) < 2
        label = stage if in_stage else ("Heating" if heating_up else "Printing")
        color = COLORS["heating"] if (in_stage or heating_up) else COLORS["running"]
        kind = "live"

    now_ms = int(time.time() * 1000)
    eta = now_ms + int(remaining) * 60000 if (not finished and remaining and remaining > 0) else 0
    return ({
        "name": status.get("subtask_name") or "",
        "stateLabel": label, "tint": color,
        "progress": progress, "layer": layer, "totalLayers": total,
        "etaEpochMs": eta, "finished": finished,
        "symbol": SYMBOLS.get(label, SYMBOLS["Error"] if kind == "error" else "printer.fill"),
        "nozzle": n1, "nozzleTarget": n1t, "nozzle2": n2, "nozzle2Target": n2t,
        "hasNozzle2": has_n2, "activeNozzle": active_idx, "bed": bed, "bedTarget": bed_t,
        "modelUri": "", "queueCount": 0, "nextName": "",
    }, kind)


def meaningful_change(a: dict | None, b: dict) -> bool:
    """Mirror the app's meaningfulChange — ignore sub-minute ETA drift so we don't push every poll."""
    if a is None:
        return True
    return (
        abs(a["progress"] - b["progress"]) >= 1
        or a["layer"] != b["layer"]
        or a["stateLabel"] != b["stateLabel"]
        or a["name"] != b["name"]
        or abs(a["nozzle"] - b["nozzle"]) >= 3
        # New keys use .get(): a card's lastState persists across deploys, so an old-schema stored
        # state (pre-dual-nozzle) may lack these — treat missing as 0 rather than KeyError-ing the tick.
        or abs(a.get("nozzle2", 0) - b["nozzle2"]) >= 3
        or abs(a["bed"] - b["bed"]) >= 3
        or a["nozzleTarget"] != b["nozzleTarget"]
        or a.get("nozzle2Target", 0) != b["nozzle2Target"]
        or a.get("activeNozzle", 0) != b["activeNozzle"]
        or a["bedTarget"] != b["bedTarget"]
        or abs(a["etaEpochMs"] - b["etaEpochMs"]) >= 120_000
        # Drying cards: temp climb + humidity fall are the whole story (countdown ticks client-side).
        or a.get("dry", False) != b.get("dry", False)
        or abs(a.get("amsTemp", 0) - b.get("amsTemp", 0)) >= 2
        or a.get("amsTarget", 0) != b.get("amsTarget", 0)
        or abs(a.get("humidity", 0) - b.get("humidity", 0)) >= 3
    )


# ---- state ----
# _regs: card key -> LIST of Live-Activity cards, ONE PER DEVICE. Each element is
# {printerId, pushToken, deviceId, printerName, iconUri, client, lastPush, lastState}.
#
# The list is the point: two phones in one household each hold their own card for the same printer.
# `lastPush`, `lastState`, `client` and `iconUri` are PER ELEMENT and must never be hoisted to the
# key — a shared lastPush makes one device's push start another's MIN_UPDATE_S throttle, and a
# shared lastState makes meaningful_change compare against content the other device never received,
# freezing its card while APNs keeps answering 200. `client` may legitimately differ between
# elements (RN on one phone, native on another); absent = EXPO (see clients.py).
#
# An empty list is never stored: `key in _regs` means "a card exists here", and an empty list is
# truthy in that test, which would silently disable push-to-start for that printer forever. All of
# that discipline lives in registry.py, which is pure and tested — this module is not.
_regs: registry.Registry = {}
# _device_tokens: raw APNs device tokens for regular alert notifications (print done / error).
_device_tokens: list[str] = []
# _p2s_tokens: ActivityKit push-to-start tokens (one per device) — start cards with the app closed.
_p2s_tokens: list[str] = []
# _p2s_dry_sent: pid -> True once we remote-started a dry card for the CURRENT cycle (reset when idle).
_p2s_dry_sent: dict[str, bool] = {}
# _p2s_icons: p2s token -> App-Group glyph URI (the app knows the path; we don't).
_p2s_icons: dict[str, str] = {}
# _p2s_clients: p2s token -> EXPO|NATIVE. A start payload's attributes-type is client-specific and a
# wrong one produces NO card (APNs still says 200), so the token has to remember who handed it over.
# Keyed by token, exactly like _p2s_icons — only ONE build can be installed at a time under a shared
# bundle id, but the other build's token lingers here until APNs 400/410s it, and each must be pushed
# in its own shape meanwhile. Absent = EXPO (tokens registered before this field existed).
_p2s_clients: dict[str, str] = {}
# _p2s_devices: p2s token -> device id. A start is per device: a phone with no card must still get
# one even when another phone in the house has one.
_p2s_devices: dict[str, str] = {}
# _p2s_pending: {registry key -> unix ts} for remote starts awaiting their update token.
#
# A remotely-started card is UNREACHABLE until the app hands us its token — we can neither update nor
# end it. Two rules keep that from turning into lock-screen litter:
#   1. At most ONE outstanding start at a time, globally. The app identifies a card only by its push
#      token (expo-widgets exposes nothing else), so if two cards were pending we could not tell which
#      token belonged to which — /adopt would bind them arbitrarily and show a dry card's content on a
#      print card. Serialising starts makes the binding unambiguous by construction.
#   2. Entries expire (P2S_PENDING_TTL). The stale card then has no owner and no pending claim, so the
#      app's reconcile sees an unknown token, /adopt answers known:false, and the app ends it.
# Keyed by (registry key, device) rather than by key alone. The global rule existed because a card
# is identifiable only by its push token, so two simultaneous pending starts could not be told
# apart; scoping by device preserves that — at most one unresolved start PER DEVICE — while letting
# two phones each adopt their own card.
_p2s_pending: dict[str, float] = {}
P2S_PENDING_TTL = 600.0

# How long silence may last before a card is lying. NOT derived from MIN_UPDATE_S: that is a floor
# on how OFTEN we may push, gating a change detector, and a paused print or a drying cycle sitting
# at target produces no meaningful change for a long time while everything is perfectly healthy.
# Deriving one from the other would mark healthy cards stale within a minute.
STALE_AFTER_S = 900.0


def _pending_id(key: str, device: str) -> str:
    return f"{key}|{device}"


# _suspended: push token -> why. Set when Canopy says another tenant holds the token (our authority
# was taken), cleared only by a successful re-registration. Deliberately NOT set on "nobody holds
# it": that is routine after a release or an expiry and means re-claim, and treating it as a
# suspension would suspend every token on this box at once after a Canopy restore.
_suspended: dict[str, str] = {}
# _needs_claim: push tokens Canopy reports unbound. Returned to the owning device so it re-claims.
# A trigger, never a source: the app must intersect this against the tokens it actually holds, or a
# compromised server could name another user's token and have an honest phone sign a claim for it.
_needs_claim: dict[str, str] = {}
# _outbox: alert banners awaiting delivery. Live-Activity updates deliberately have no queue —
# they carry state and the next tick resends it — but a banner carries an EVENT, and the edge that
# produced it fires once. Without this a transient failure lost the notification permanently.
_outbox = ob.Outbox()


def _needs_claim_for(device: str) -> list[str]:
    """Tokens this device should re-claim. Scoped, so one phone is never handed another's."""
    out = []
    for token, owner in _needs_claim.items():
        if owner == device:
            out.append(token)
    return out
# _p2s_started: registry key -> the print/cycle identity we last push-to-started a card for.
#
# This is what makes duplication impossible. The TTL above only governs which pending token /sync
# may bind; it must NEVER be what decides whether to start another card. It used to be, and because
# a remotely-started card cannot be adopted while the app is closed, the claim expired every 10
# minutes and a fresh card was started — 199 of them for one print, with three left stacked on the
# lock screen. Now a card is started once per identity, and only a NEW print re-arms it.
_p2s_started: dict[str, str] = {}
# _last_kind: printerId -> last-seen kind, for edge-triggered notifications. Persisted (in REG_FILE) so a
# restart/crash mid-print doesn't lose the live->complete/error edge and silently drop the alert.
_last_kind: dict[int, str] = {}
# _last_paused: printerId -> was it paused last poll. A pause does NOT change `kind` (PAUSE maps to
# "live" so the lock-screen card survives it), so the kind edge can never see it — yet an AI-detection
# halt is the single most important thing to be told about: the printer is stopped mid-print, waiting
# on a human, and false positives are common with print_halt + every detector enabled.
_last_paused: dict[int, bool] = {}
# _paused_at: printerId -> when the pause began, for REMINDERS. One banner is a single point of
# failure — miss it (phone face-down, Focus, glanced past it) and an unattended printer just sits
# there halted. A paused print is re-announced at these offsets, then goes quiet.
_paused_at: dict[int, float] = {}
_paused_reminded: dict[int, int] = {}
PAUSE_REMINDERS_MIN = (10, 30, 60)
# _last_dry: "printerId:amsId" -> {"t": minutes remaining, "fil": filament} last seen — drives the
# drying-finished banner (dry_time falling to 0). Persisted for the same restart-survival reason.
_last_dry: dict[str, dict] = {}
# _printers_cache: printerId -> name, refreshed from Bambuddy.
_printers_cache: dict[int, str] = {}
# _cool: printerId -> plate-cooldown tracker for the "safe to take the print off" banner.
#   {"armed": the bed was hot during a print, so a crossing is meaningful,
#    "fired": already announced for this print,
#    "seen":  [[epoch, bedC], ...] trailing readings, for the plateau detector}
# Like a pause, this is INVISIBLE to the _last_kind edge: the printer sits at FINISH (kind
# "complete") for the whole cooldown, so nothing about `kind` changes when the plate becomes cool.
_cool: dict[int, dict] = {}
_cool_threshold = COOL_DEFAULT_C
_cool_threshold_at = 0.0


def _load() -> None:
    global _regs, _device_tokens, _last_kind, _last_dry, _p2s_tokens, _p2s_dry_sent, _p2s_icons, _p2s_pending, _last_paused, _paused_at, _paused_reminded, _cool, _p2s_started, _p2s_clients, _p2s_devices, _suspended, _needs_claim, _outbox
    try:
        data = json.loads(REG_FILE.read_text())
        # Permanent, not a one-shot migration: rolling back to the previous image
        # rewrites this file in the single-card shape, and a re-upgrade must survive
        # that round trip.
        _regs = registry.coerce(data.get("regs"))
        _device_tokens = data.get("devices", [])
        # JSON object keys are strings; _last_kind is keyed by int printer id, so coerce back.
        _last_kind = {int(k): v for k, v in data.get("last_kind", {}).items()}
        _last_paused = {int(k): bool(v) for k, v in data.get("last_paused", {}).items()}
        _paused_at = {int(k): float(v) for k, v in data.get("paused_at", {}).items()}
        _paused_reminded = {int(k): int(v) for k, v in data.get("paused_reminded", {}).items()}
        _last_dry = data.get("last_dry", {})
        _cool = {int(k): v for k, v in data.get("cool", {}).items()}
        _p2s_tokens = data.get("p2s", [])
        _p2s_dry_sent = data.get("p2s_dry_sent", {})
        _p2s_icons = data.get("p2s_icons", {})
        # Missing on state written before the second client existed -> every stored token is the RN
        # app's, which is what an empty map means anyway (client_of/norm_client default to EXPO).
        _p2s_clients = data.get("p2s_clients", {})
        _p2s_pending = data.get("p2s_pending", {})
        _p2s_started = data.get("p2s_started", {})
        _p2s_devices = data.get("p2s_devices", {})
        _suspended = data.get("suspended", {})
        _needs_claim = data.get("needs_claim", {})
        _outbox = ob.Outbox.from_json(data.get("outbox"))
    except (FileNotFoundError, json.JSONDecodeError):
        # NB: this unpack used to supply three values for five targets, so the very path that exists
        # to survive a missing/corrupt state file raised ValueError instead.
        _regs, _device_tokens, _last_kind, _last_dry, _p2s_tokens, _p2s_dry_sent = {}, [], {}, {}, [], {}
        _p2s_icons, _p2s_pending, _last_paused, _paused_at, _paused_reminded = {}, {}, {}, {}, {}
        _cool, _p2s_started, _p2s_clients = {}, {}, {}
        _p2s_devices, _suspended, _needs_claim = {}, {}, {}
        _outbox = ob.Outbox()


def _save() -> None:
    """Persist state atomically.

    A partial write lands in the JSONDecodeError branch of _load, which resets EVERYTHING —
    registrations, the kind edges the banners depend on, the cooldown trackers. The recovery path
    for a truncated file is total data loss, so writing through a temp file and renaming is a
    correctness matter rather than a nicety, and it matters more now that one key can hold several
    registrations and so is rewritten more often.
    """
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    payload = json.dumps({"regs": _regs, "devices": _device_tokens, "last_kind": _last_kind,
                                    "last_dry": _last_dry, "p2s": _p2s_tokens, "p2s_dry_sent": _p2s_dry_sent,
                                    "p2s_icons": _p2s_icons, "p2s_clients": _p2s_clients,
                                    "p2s_pending": _p2s_pending, "p2s_started": _p2s_started, "p2s_devices": _p2s_devices,
                          "suspended": _suspended, "needs_claim": _needs_claim,
                          "outbox": _outbox.to_json(),
                                    "last_paused": _last_paused,
                                    "paused_at": _paused_at, "paused_reminded": _paused_reminded,
                          "cool": _cool})
    tmp = REG_FILE.with_suffix(".tmp")
    tmp.write_text(payload)
    os.replace(tmp, REG_FILE)


# ---- APNs ----
_apns_jwt: tuple[str, float] | None = None  # (token, issued_at)


def _apns_token() -> str:
    global _apns_jwt
    now = time.time()
    if _apns_jwt and now - _apns_jwt[1] < 2400:  # refresh every ~40 min (APNs caps at 60)
        return _apns_jwt[0]
    key = Path(APNS_KEY_PATH).read_text()
    tok = jwt.encode({"iss": APNS_TEAM_ID, "iat": int(now)}, key, algorithm="ES256", headers={"kid": APNS_KEY_ID})
    _apns_jwt = (tok, now)
    return tok


# ---- the two backends ----
#
# Both return an APNs status code, so every caller's token hygiene (`code in (400, 410)`) keeps
# working unchanged. The relay path is where that needs care: Canopy answers with its OWN HTTP
# status as well as Apple's, and they answer different questions. A Canopy 400 means "I refused
# this request"; an APNs 400 means "this token is dead". Returning the wrong one would delete a
# healthy registration on a malformed body or a dropped connection, so the relay result is
# translated here, once, and never leaks a Canopy status upward.

_canopy: "canopy.CanopyClient | None" = None


async def _relay_send(client: httpx.AsyncClient, push_token: str, aps: dict, priority: str,
                      push_type: str) -> int:
    if _canopy is None:
        return 0  # not enrolled yet; the caller treats 0 as "not delivered, change nothing"
    res = await _canopy.push(push_token, push_type, int(priority), {"aps": aps} if "aps" not in aps else aps)
    if res.token_is_dead:
        return 410
    if res.outcome is canopy.Outcome.DELIVERED:
        return res.apns_status or 0
    if res.outcome is canopy.Outcome.NOT_OWNER:
        # Another tenant holds this token: our authority was taken. Suspend it, and do NOT return
        # a 4xx that the caller would read as a dead token.
        _suspended[push_token] = "not_owner"
        return 0
    if res.outcome is canopy.Outcome.NOT_BOUND:
        # Routine after a release or an expiry. Ask the device to re-claim; changing nothing else.
        _needs_claim[push_token] = _device_for_token(push_token)
        return 0
    return 0  # transport, rate limit, refusal — retry later, touch no registration


def _device_for_token(push_token: str) -> str:
    found = registry.find_by_token(_regs, push_token)
    if found:
        return registry.device_of(found[1])
    return _p2s_devices.get(push_token, registry.LEGACY_DEVICE)


async def _apns_send(client: httpx.AsyncClient, push_token: str, aps: dict, priority: str = "10",
                     push_type: str = "liveactivity") -> int:
    if RELAY_MODE:
        return await _relay_send(client, push_token, aps, priority, push_type)
    r = await client.post(
        f"https://{APNS_HOST}/3/device/{push_token}",
        headers={
            "authorization": f"bearer {_apns_token()}",
            # The topic is derived from the push type, never supplied by a caller: an alert goes
            # to the bundle id and a Live Activity to its sub-topic, and getting it wrong is a
            # silent no-card.
            "apns-topic": APNS_TOPIC if push_type == "liveactivity" else APNS_BUNDLE_ID,
            "apns-push-type": push_type,
            # Priority 10 spends the device's Live-Activity budget; 5 is delivered opportunistically
            # and conserves it. Routine drift goes at 5, real state changes at 10.
            "apns-priority": priority,
        },
        json=aps if "aps" in aps else {"aps": aps},
    )
    return r.status_code


def _needs_heartbeat(reg: dict, now: float) -> bool:
    """Whether this card is close enough to its stale date to need a keep-alive push.

    A card only receives a push when something meaningful changes, so a paused print or a drying
    cycle at target can go quiet for a long time while the pipeline is perfectly healthy. Without a
    heartbeat the stale date would elapse and iOS would dim a card that is telling the truth.
    Priority stays 5 — this is opportunistic by nature and must not spend the device's budget.
    """
    last = reg.get("lastPush", 0)
    if not last:
        return False
    return now - last >= STALE_AFTER_S / 2


def _urgent(last: dict | None, cs: dict) -> bool:
    """Deserves priority 10: first push for a card, a state-label flip (Printing->Paused, Heating->
    Printing, Drying->Done…), or the finished flag. Temp/progress/ETA drift is priority 5."""
    if last is None:
        return True
    return last.get("stateLabel") != cs.get("stateLabel") or bool(last.get("finished")) != bool(cs.get("finished"))


# The content-state/attributes shapes live in clients.py (`envelope`, `start_attributes`) because
# they are pure and the interesting part is WHICH shape, not the sending — see that module for why
# the RN and native apps cannot share one payload.


async def _push_update(client: httpx.AsyncClient, reg: dict, cs: dict, priority: str = "5") -> int:
    # stale-date makes a card whose feed died go visibly stale instead of lying: without it a
    # Canopy or Bambuddy outage looks exactly like a slow print, with the ETA counting past zero.
    # The heartbeat in _tick renews it while the pipeline is healthy.
    now = int(time.time())
    return await _apns_send(client, reg["pushToken"], {
        "timestamp": now, "event": "update", "stale-date": now + int(STALE_AFTER_S),
        "content-state": envelope(cs, client_of(reg)),
    }, priority)


async def _push_start(client: httpx.AsyncClient, push_token: str, cs: dict, printer_id: int,
                      ams_id: int | None, la_client: str = EXPO) -> int:
    """ActivityKit push-to-start (iOS 17.2+): starts the Live Activity with the app closed. The
    per-activity UPDATE token reaches us when iOS wakes the app (or on next open via adoption);
    until then the card still shows live countdowns — etaEpochMs timers tick client-side.
    NOTE: the `alert` block is part of Apple's start-payload spec — starts WITHOUT it were observed
    accepted by APNs (200) but silently discarded on-device (no card, no app wake).
    `printer_id`/`ams_id` matter only for the native client, whose attributes type carries them (the
    expo client's attributes are empty and both are ignored) — required rather than defaulted anyway,
    because a defaulted 0 would silently start a native card for the wrong printer."""
    title = (cs.get("printerName") or "Printer").strip() or "Printer"
    body = cs.get("name") or cs.get("stateLabel") or "Started"
    attrs_type, attrs = start_attributes(la_client, printer_id, ams_id)
    return await _apns_send(client, push_token, {
        "timestamp": int(time.time()), "event": "start",
        "stale-date": int(time.time()) + int(STALE_AFTER_S),
        "attributes-type": attrs_type, "attributes": attrs,
        "content-state": envelope(cs, la_client),
        "alert": {"title": f"{title} — {cs.get('stateLabel', 'Started')}", "body": body},
    }, "10")


async def _push_end(client: httpx.AsyncClient, reg: dict, cs: dict) -> int:
    code = await _apns_send(client, reg["pushToken"], {
        "timestamp": int(time.time()), "event": "end",
        "content-state": envelope(cs, client_of(reg)),
        "dismissal-date": int(time.time()) + 1800,
    })
    # Tell the relay we are done with this token. Release rather than delete: the binding keeps its
    # anchors, so the token is never reopened to a first-come claim — it simply stops counting
    # against this tenant's cap. Without it, every completed card would linger, because a card that
    # ends is never pushed to again and so never earns the 410 that would free it.
    if RELAY_MODE and _canopy is not None and _canopy.credentials is not None:
        try:
            await _canopy.release(reg["pushToken"])
        except Exception as e:  # noqa: BLE001 — a failed release must not break the end push
            print(f"[canopy] release failed: {e}", flush=True)
    return code


# ---- Bambuddy ----
async def _get_status(client: httpx.AsyncClient, printer_id: int) -> dict | None:
    try:
        r = await client.get(f"{BAMBUDDY_URL}/api/v1/printers/{printer_id}/status", headers={"X-API-Key": BAMBUDDY_API_KEY}, timeout=8)
        return r.json() if r.status_code == 200 else None
    except (httpx.HTTPError, json.JSONDecodeError):
        return None


async def _bed_cooled_threshold(client: httpx.AsyncClient) -> float:
    """The plate-cooled threshold, from Bambuddy's own `bed_cooled_threshold` setting.

    Bambuddy already ships this setting (and a `bed_cooled` event type), so it is the single place a
    user changes the number rather than a second copy living here. Cached for an hour; clamped to
    the defensible band -- below ~30C the threshold collides with room temperature and can never be
    reached, and above ~45C you are inviting someone to grab metal hot enough to burn (EN ISO
    13732-1 puts bare metal at 48C for 10s of contact).
    """
    global _cool_threshold, _cool_threshold_at
    if time.time() - _cool_threshold_at < 3600:
        return _cool_threshold
    try:
        r = await client.get(f"{BAMBUDDY_URL}/api/v1/settings", headers={"X-API-Key": BAMBUDDY_API_KEY}, timeout=8)
        if r.status_code == 200:
            _cool_threshold = clamp_threshold(r.json().get("bed_cooled_threshold"), _cool_threshold)
    except (httpx.HTTPError, json.JSONDecodeError, TypeError, ValueError):
        pass  # keep whatever we had; a settings blip must not change behaviour
    _cool_threshold_at = time.time()
    return _cool_threshold


async def _list_printers(client: httpx.AsyncClient) -> dict[int, str]:
    try:
        r = await client.get(f"{BAMBUDDY_URL}/api/v1/printers/", headers={"X-API-Key": BAMBUDDY_API_KEY}, timeout=8)
        arr = r.json() if r.status_code == 200 else []
        return {p["id"]: (p.get("name") or f"Printer {p['id']}") for p in arr if p.get("is_active", True)}
    except (httpx.HTTPError, json.JSONDecodeError, KeyError, TypeError):
        return {}


# ---- alert notifications (print done / error) ----
def _queue_alert(key: str, title: str, body: str, urgent: bool = True) -> None:
    """Queue a banner for delivery.

    Queued rather than sent inline because the edge that produced it advances regardless: if the
    push failed, `_last_kind` has already moved on and nothing would ever re-fire. The key
    deduplicates, so re-observing the same event while a send is pending cannot deliver twice.
    """
    if _outbox.add(key, title, body, urgent, now=time.time()):
        _save()


async def _drain_outbox(client: httpx.AsyncClient) -> None:
    """Deliver whatever is due, rescheduling what fails."""
    now = time.time()
    dirty = False
    for alert in _outbox.due(now):
        ok = await _notify(client, alert.title, alert.body, alert.urgent)
        if ok:
            _outbox.succeeded(alert.key)
        else:
            _outbox.failed(alert.key, now)
        dirty = True
    if dirty:
        _save()


async def _notify(client: httpx.AsyncClient, title: str, body: str, urgent: bool = True) -> bool:
    """Send an alert banner to every registered device. Returns whether it reached anyone.

    `interruption-level: time-sensitive` asks iOS to break through Focus modes and the Scheduled
    Summary — the difference between "the printer halted 40 minutes ago" and knowing now. It requires
    the com.apple.developer.usernotifications.time-sensitive entitlement (added in app.json, so it
    takes effect at the next NATIVE build); until then iOS simply ignores the field, and APNs still
    returns 200 either way, so a delivered-but-not-shown alert looks identical to a working one from
    here."""
    aps = {"alert": {"title": title, "body": body}, "sound": "default",
           "interruption-level": "time-sensitive" if urgent else "active"}
    if not _device_tokens:
        return True  # nobody to tell; not a failure, and retrying would never help
    delivered = False
    for tok in list(_device_tokens):
        try:
            # Through the same backend as everything else, so the relay's status translation and
            # the local signer stay observably equivalent to the hygiene below.
            code = await _apns_send(client, tok, aps, "10", push_type="alert")
            print(f"[notify] {title!r} -> {code}", flush=True)
            if code in (400, 410):
                _device_tokens.remove(tok)
                _save()
            elif 200 <= code < 300:
                delivered = True
        except httpx.HTTPError as e:
            print(f"[notify] error: {e}", flush=True)
    return delivered


def _pending_key(device: str = "") -> str | None:
    """This device's outstanding remote start, dropping it if it has aged out.

    Still at most ONE unresolved start per device: a card is identifiable only by its push token, so
    two simultaneously-pending starts for one device could not be told apart and adoption would bind
    them arbitrarily. Scoping by device keeps that property while letting two phones each adopt
    their own card.
    """
    want = device or registry.LEGACY_DEVICE
    for pending_id, ts in list(_p2s_pending.items()):
        key, _, owner = pending_id.rpartition("|")
        if not key:  # legacy entry written before ids existed
            key, owner = pending_id, registry.LEGACY_DEVICE
        if time.time() - ts > P2S_PENDING_TTL:
            _p2s_pending.pop(pending_id, None)
            print(f"[p2s] pending {key} expired — the app will end that card as an orphan", flush=True)
            _save()
        elif owner == want:
            return key
    return None


async def _remote_start(client: httpx.AsyncClient, key: str, cs: dict, label: str) -> bool:
    """Push-to-start one card, unless another start is still awaiting adoption. Returns True if sent."""
    # NOTE: deliberately does NOT gate on _pending_key(). That claim expires, and using an expiring
    # claim as the "may I start?" test is exactly what produced hundreds of duplicate cards. The
    # caller decides via should_start(); this only refuses when there is nothing to push to, or the
    # card already exists.
    if not _p2s_tokens:
        return False
    # The registry key is the ONLY place the printer/AMS ids survive to here, and the native client's
    # attributes need both — a start without them creates no card.
    pid, ams = key_ids(key)
    sent = False
    for tok in list(_p2s_tokens):
        device = _p2s_devices.get(tok) or registry.LEGACY_DEVICE
        # Per device, not per key. Asking whether ANY card exists is a nearby question: once one
        # phone adopts a card, the other would never receive a start again, for any print.
        if registry.has_card(_regs, key, device):
            continue
        if _pending_key(device) == key:
            continue  # this device already has an unresolved start for this card
        tok_client = norm_client(_p2s_clients.get(tok))
        code = await _push_start(client, tok, {**cs, "iconUri": _p2s_icons.get(tok, cs.get("iconUri", ""))},
                                 printer_id=pid, ams_id=ams, la_client=tok_client)
        print(f"[p2s] start {label} ({tok_client}) -> {code}", flush=True)
        if code in (400, 410):
            _p2s_tokens.remove(tok)
            _p2s_icons.pop(tok, None)
            _p2s_clients.pop(tok, None)
            _p2s_devices.pop(tok, None)
            continue
        _p2s_pending[_pending_id(key, device)] = time.time()
        sent = True
    if sent:
        _save()
    return sent


def _f(v) -> float:
    try:
        return float(v or 0)
    except (TypeError, ValueError):
        return 0.0


def drying_unit_ids(status: dict) -> list[int]:
    """Ids of the units with an ACTIVE drying cycle. Mirrors the app's dryingUnitIds.

    Three drying-capable units are now fitted (two AMS 2 Pro + an AMS HT), so concurrent cycles are
    ordinary rather than theoretical — hence one card PER UNIT rather than per printer."""
    return [int(_f(u.get("id"))) for u in (status.get("ams") or []) if _f(u.get("dry_time")) > 0]


def dry_state(status: dict, ams_id: int | None = None) -> dict | None:
    """One unit's drying card ContentState, or None when that unit is idle. Mirrors the app's
    toDryContentState: dry_time (minutes remaining) > 0 is THE active signal; the countdown itself
    renders client-side from etaEpochMs, so pushes only carry temp/humidity drift and the end.

    `ams_id` selects the unit; omitted, it falls back to the first unit drying."""
    ams_list = status.get("ams") or []

    # Scan EVERY unit, not ams[0] — the H2C pairs two AMS 2 Pro with an AMS HT, and a cycle on the HT
    # produced no card. Mirrors the app's toDryContentState.
    if ams_id is not None:
        ams = next((u for u in ams_list if int(_f(u.get("id"))) == ams_id), None)
        if ams is None or _f(ams.get("dry_time")) <= 0:
            return None
    else:
        ams = next((u for u in ams_list if _f(u.get("dry_time")) > 0), None)
    if not ams:
        return None
    unit_id = int(_f(ams.get("id")))
    is_ht = ams.get("is_ams_ht") is True or unit_id >= 128
    unit_label = ("AMS HT" if is_ht else f"AMS {unit_id + 1}") if len(ams_list) > 1 else ""
    mins = _f(ams.get("dry_time"))
    target = int(_f(ams.get("dry_target_temp")))
    fil = ams.get("dry_filament") or "Filament"
    now_ms = int(time.time() * 1000)
    return {
        "dry": True, "stateLabel": "Drying",
        "name": " · ".join(x for x in (unit_label, f"{fil} @ {target}°" if target > 0 else fil) if x),
        "tint": "#FFB86C", "symbol": "humidity.fill",
        "progress": 0, "layer": 0, "totalLayers": 0,
        "etaEpochMs": now_ms + int(mins * 60000), "finished": False,
        "amsTemp": int(_f(ams.get("temp"))), "amsTarget": target, "humidity": int(_f(ams.get("humidity"))),
        "nozzle": 0, "nozzleTarget": 0, "nozzle2": 0, "nozzle2Target": 0,
        "hasNozzle2": False, "activeNozzle": 0, "bed": 0, "bedTarget": 0,
        "modelUri": "", "queueCount": 0, "nextName": "",
    }


# ---- poll loop ----
async def _poll_loop() -> None:
    async with httpx.AsyncClient(http2=True, timeout=15) as client:
        while True:
            try:
                await _tick(client)
            except Exception as e:  # never let the loop die
                print(f"[poll] error: {e}", flush=True)
            await asyncio.sleep(POLL_INTERVAL)


async def _tick(client: httpx.AsyncClient) -> None:
    # Deliver queued banners first: an event that failed last tick is older than
    # anything this one will produce.
    await _drain_outbox(client)

    # Poll every printer with a Live-Activity card; also the whole fleet when a device token is
    # registered (so print-done/error alerts fire even with no card up).
    ids: set[int] = registry.printer_ids(_regs)
    if _device_tokens:
        names = await _list_printers(client)
        if names:
            _printers_cache.update(names)
        ids |= set(_printers_cache)
    if not ids:
        return

    now = time.time()
    for pid in ids:
        status = await _get_status(client, pid)
        if status is None:
            continue
        fields, kind = classify(status)
        print_cards = registry.cards(_regs, str(pid))
        name = (print_cards[0].get("printerName") if print_cards else None) or _printers_cache.get(pid) or f"Printer {pid}"

        # 1b) Drying cards: one per UNIT, each with its own lifecycle driven by that unit's
        # dry_time. Keyed "dry:<pid>:<amsId>" — a per-printer key could only ever track one cycle,
        # so a second unit's card was never updated and its completion never pushed.
        for dkey in [k for k in list(_regs) if k.startswith(f"dry:{pid}:") or k == f"dry:{pid}"]:
            # Snapshot: the loop body drops registrations, and mutating while iterating raises
            # inside the poll loop, which swallows it — drying cards would just stop updating.
            dregs = list(registry.cards(_regs, dkey))
            if not dregs:
                continue
            dname = dregs[0].get("printerName") or name
            # Legacy per-printer registrations (no ams id) keep working: fall back to "any unit".
            parts = dkey.split(":")
            d_ams = int(parts[2]) if len(parts) > 2 and parts[2].lstrip("-").isdigit() else None
            ds = dry_state(status, d_ams)
            dirty = False
            for dreg in dregs:
                # Every payload is built per element: the end state merges over THIS device's
                # lastState and carries ITS icon path (an App-Group path only that device knows),
                # and envelope() picks the shape from ITS client discriminator. A wrong shape is
                # accepted by APNs with a 200 and silently discarded.
                if ds is None:
                    end_cs = {**(dreg.get("lastState") or {}), "printerName": dname,
                              "iconUri": dreg.get("iconUri", ""), "dry": True,
                              "stateLabel": "Done", "finished": True, "etaEpochMs": 0}
                    code = await _push_end(client, dreg, end_cs)
                    print(f"[end] {dkey} -> {code}", flush=True)
                    registry.drop_token(_regs, dkey, dreg.get("pushToken"))
                    dirty = True
                    continue

                dcs = {"printerName": dname, "iconUri": dreg.get("iconUri", ""), **ds}
                if (meaningful_change(dreg.get("lastState"), dcs) or _needs_heartbeat(dreg, now)) \
                        and (now - dreg.get("lastPush", 0) >= MIN_UPDATE_S):
                    prio = "10" if _urgent(dreg.get("lastState"), dcs) else "5"
                    code = await _push_update(client, dreg, dcs, prio)
                    print(f"[update] {dkey} prio {prio} -> {code}", flush=True)
                    if code in (400, 410):
                        # Per token: this device's card is gone, the others are still live.
                        print(f"[drop] {dkey} -> {code}", flush=True)
                        registry.drop_token(_regs, dkey, dreg.get("pushToken"))
                    else:
                        dreg["lastState"], dreg["lastPush"] = dcs, now
                    dirty = True
            if dirty:
                _save()

        # 1) Live-Activity card: throttled update, or end on a terminal state. One card per
        # device, each with its own throttle and its own last-seen state.
        dirty = False
        for creg in list(print_cards):
            cs = {"printerName": name, "iconUri": creg.get("iconUri", ""), **fields}
            if kind in ("complete", "error", "idle"):
                code = await _push_end(client, creg, cs)
                print(f"[end] printer {pid} -> {code}", flush=True)
                registry.drop_token(_regs, str(pid), creg.get("pushToken"))
                dirty = True
            elif (meaningful_change(creg.get("lastState"), cs) or _needs_heartbeat(creg, now)) \
                    and (now - creg.get("lastPush", 0) >= MIN_UPDATE_S):
                prio = "10" if _urgent(creg.get("lastState"), cs) else "5"
                code = await _push_update(client, creg, cs, prio)
                print(f"[update] printer {pid} prio {prio} -> {code}", flush=True)
                if code in (400, 410):
                    print(f"[drop] printer {pid} -> {code}", flush=True)
                    registry.drop_token(_regs, str(pid), creg.get("pushToken"))
                else:
                    creg["lastState"], creg["lastPush"] = cs, now
                dirty = True
        if dirty:
            _save()

        # 1c) Push-to-start: a print/dry began while NO card is registered (app closed) -> start the
        # Live Activity remotely. Edge-triggered exactly like the banners so it fires once per event.
        if _p2s_tokens:
            prev_kind = _last_kind.get(pid)
            # STATE-based, not edge-based: "this printer is live and has no card" is the condition,
            # so a print that was ALREADY running when the service (or the card) went away still gets
            # one. Edge-triggering meant a mid-print restart, or a card the user swiped away, could
            # never be recovered — you had to wait for the next print. _remote_start still enforces
            # "no existing card for this key" and the single-outstanding rule.
            # ONE card per print, keyed by the print's identity — not one per expiring claim.
            key = str(pid)
            ident = print_identity(status, fields)
            # NB `key in _regs` answers "does ANYONE have a card", which is a nearby question and
            # not this one. _remote_start now decides per device, so a phone that has no card still
            # gets a start even when another phone in the house does.
            if should_start(kind == "live", ident, _p2s_started.get(key), False):
                await _remote_start(client, key, {"printerName": name, **fields}, f"print {pid} [{ident}]")
            nxt = next_started_for(kind == "live", ident, _p2s_started.get(key))
            if nxt != _p2s_started.get(key):
                if nxt is None:
                    _p2s_started.pop(key, None)
                    _p2s_pending.pop(key, None)  # print over; the next one may start a card again
                else:
                    _p2s_started[key] = nxt
                _save()

            # Push-to-start one card per DRYING UNIT, so a second concurrent cycle also gets a card
            # when the app is closed.
            drying = drying_unit_ids(status)
            units = {int(_f(u.get("id"))): u for u in (status.get("ams") or [])}
            live_dry_keys = set()
            for a_id in drying:
                ds0 = dry_state(status, a_id)
                if ds0 is None:
                    continue
                dkey = f"dry:{pid}:{a_id}"
                live_dry_keys.add(dkey)
                dident = dry_identity(a_id, units.get(a_id) or {})
                # Per device, decided inside _remote_start — see the print gate above.
                if should_start(True, dident, _p2s_started.get(dkey), False):
                    await _remote_start(client, dkey, {"printerName": name, **ds0}, f"dry {pid}:{a_id}")
                _p2s_started[dkey] = dident
            # Forget cycles that ended, so the NEXT cycle on that unit starts a card again.
            for k in [k for k in list(_p2s_started) if k.startswith(f"dry:{pid}:")]:
                if k not in live_dry_keys:
                    _p2s_started.pop(k, None)
                    _p2s_pending.pop(k, None)
            _save()

        # 2) Alert on a state transition (edge-triggered; the first observation is silent). _last_kind is
        # persisted, so a restart/crash mid-print still fires the finish/error edge on the next poll.
        prev = _last_kind.get(pid)
        if prev != kind:
            # Log EVERY transition. Nothing did before, which is why "why wasn't I notified?" could
            # only be answered by inference — the service silently saw, or didn't see, the edge.
            print(f"[state] printer {pid}: {prev} -> {kind}", flush=True)
        if _device_tokens:
            if prev is not None and prev != kind:
                model = fields.get("name") or "your print"
                if kind == "complete":
                    _queue_alert(f"{pid}:complete", f"✅ {name} — print finished", model)
                elif kind == "error":
                    _queue_alert(f"{pid}:error", f"⚠️ {name} — needs attention", model)
                elif kind == "idle" and prev == "live":
                    # A live print that goes IDLE ended WITHOUT completing — aborted by the printer,
                    # or cancelled. This was silent: only complete/error notified, so the one case
                    # you most want to hear about while away produced nothing at all.
                    _queue_alert(f"{pid}:stopped", f"⏹️ {name} — print stopped", f"{model} ended before finishing.")
        # PAUSE is not a `kind` change (see _last_paused), so it needs its own edge. This is the
        # alert that matters most: an AI-detection halt (spaghetti/pile-up/first-layer) stops the
        # print and waits for a human — and those fire false positives.
        paused_now = (status.get("state") or "").upper() in ("PAUSE", "PAUSED")
        was_paused = _last_paused.get(pid)
        if was_paused != paused_now:
            print(f"[state] printer {pid}: paused={paused_now}", flush=True)
            if _device_tokens and was_paused is not None and paused_now:
                model = fields.get("name") or "your print"
                err = status.get("print_error")
                why = "The printer halted it — resume or stop it in the app."
                if err:
                    why = f"Halted with error {err} — open the app to resume or stop."
                _queue_alert(f"{pid}:paused", f"⏸️ {name} — print paused", f"{model}. {why}")
            _last_paused[pid] = paused_now
            if paused_now:
                _paused_at[pid] = time.time()
                _paused_reminded[pid] = 0
            else:
                _paused_at.pop(pid, None)
                _paused_reminded.pop(pid, None)
            _save()
        elif paused_now and _device_tokens and pid in _paused_at:
            # Still paused: re-announce at 10/30/60 minutes so a single missed banner doesn't leave a
            # halted printer sitting unattended, then stop rather than nag forever.
            mins = (time.time() - _paused_at[pid]) / 60.0
            sent = _paused_reminded.get(pid, 0)
            if sent < len(PAUSE_REMINDERS_MIN) and mins >= PAUSE_REMINDERS_MIN[sent]:
                model = fields.get("name") or "your print"
                _queue_alert(f"{pid}:paused:{int(mins)}", f"⏸️ {name} — still paused ({int(mins)} min)", f"{model} is waiting on you.")
                _paused_reminded[pid] = sent + 1
                _save()

        # 2b) Plate cooled down enough to take the print off.
        #
        # Edge-triggered with an ARM step, so an already-cold idle printer never fires: the bed must
        # have been hot DURING a print first. Fires once per print, then re-arms on the next one.
        #
        # The threshold alone is not enough. A plate approaches room temperature asymptotically and
        # cannot cross it, so on a warm day a 35C target may never arrive and the user would simply
        # never be told. The plateau branch covers that: once the bed stops falling, that IS as cool
        # as it gets, and we say so in those words rather than claiming the plate hit the target.
        if _device_tokens:
            threshold = await _bed_cooled_threshold(client)
            bed_now = float(fields.get("bed") or 0)
            action, _cool[pid] = cool_step(kind == "live", bed_now, threshold, _cool.get(pid), now)
            if action:
                model = fields.get("name") or "your print"
                # Deliberately "safe to flex", never "your print has released" — plenty of prints
                # stay stuck at room temperature, and promising a pop invites someone to force it
                # and tear the PEI coating off the steel.
                if action == READY:
                    _queue_alert(f"{pid}:cool", f"🧊 {name} — plate is cool",
                         f"Bed at {int(bed_now)}°C. Safe to flex the plate and lift {model} off.")
                else:
                    _queue_alert(f"{pid}:cool", f"🧊 {name} — plate has stopped cooling",
                         f"Settled at {int(bed_now)}°C, as cool as it will get today. Go ahead and flex the plate.")
                print(f"[cool] printer {pid}: {action} at {int(bed_now)}C (threshold {threshold:g})", flush=True)
            _save()

        if prev != kind:
            _last_kind[pid] = kind
            _save()

        # 3) AMS drying finished (edge-triggered per unit): dry_time (minutes remaining) falling to 0
        # from a SMALL value is a natural run-out -> banner. Falling from a big value is a manual
        # stop — the user did that themselves, stay silent. First observation is silent; filament is
        # captured while the cycle runs (the unit may clear dry_filament once it ends). Persisted.
        if _device_tokens:
            for unit in status.get("ams") or []:
                dkey = f"{pid}:{unit.get('id', 0)}"
                cur = _rnd(unit.get("dry_time"))
                prev_dry = _last_dry.get(dkey)
                if prev_dry is not None and prev_dry.get("t", 0) > 0 and cur <= 0 and prev_dry.get("t", 0) <= 15:
                    fil = prev_dry.get("fil") or "Filament"
                    _queue_alert(f"{pid}:dry:{key}", f"💨 {name} — drying finished", f"{fil} is dry.")
                if prev_dry is None or prev_dry.get("t") != cur:
                    _last_dry[dkey] = {"t": cur, "fil": (unit.get("dry_filament") or (prev_dry or {}).get("fil") or "")}
                    _save()


# ---- HTTP API ----
app = FastAPI(title="Trellis")


# Accepted-key cache: sha256(key) -> monotonic expiry. Never stores raw keys. Bounded — a scan of
# garbage keys can't grow it (only keys Bambuddy ACCEPTED are cached).
_key_cache: dict[str, float] = {}
_KEY_CACHE_TTL = 300.0


async def _require_key(x_api_key: str | None = Header(default=None)) -> None:
    """Gate the register endpoints on a VALID Bambuddy API key (the app already sends it as
    X-API-Key). Without this, ANYONE who knows the public Trellis URL could POST their token and
    receive the owner's print notifications (name, progress, finish/error) — an info leak.

    Validation is delegated to Bambuddy: equality with the configured admin key is a fast path, and
    any other presented key is accepted iff Bambuddy answers 200 to a read with it. The app may hold
    a SCOPED key that differs from the admin key on disk — a plain equality check 401'd those and
    silently broke Live-Activity push registration."""
    if not x_api_key:
        raise HTTPException(status_code=401, detail="unauthorized")
    if x_api_key == BAMBUDDY_API_KEY:
        return
    h = hashlib.sha256(x_api_key.encode()).hexdigest()
    if _key_cache.get(h, 0.0) > time.monotonic():
        return
    try:
        async with httpx.AsyncClient() as client:
            r = await client.get(f"{BAMBUDDY_URL}/api/v1/printers/", headers={"X-API-Key": x_api_key}, timeout=8)
        if r.status_code == 200:
            _key_cache[h] = time.monotonic() + _KEY_CACHE_TTL
            return
    except Exception:
        pass  # Bambuddy unreachable -> fall through to 401 (fail closed)
    raise HTTPException(status_code=401, detail="unauthorized")


async def _forward_claim(claim: dict | None, push_token: str, device: str) -> None:
    """Relay a device's Canopy claim, if there is one.

    The body is passed through verbatim: every field is inside the device's signed client data, so
    altering one would only invalidate the signature — which is exactly the property that stops a
    compromised companion binding somebody else's token.

    A transport failure raises 502 rather than answering the phone with success. If we said 200 on
    a claim we never delivered, the app would mark the registration accepted and stop retrying, and
    the card would sit unclaimed for the whole print with every component reporting success.
    """
    if not RELAY_MODE or not claim:
        return
    if _canopy is None or _canopy.credentials is None:
        raise HTTPException(status_code=503, detail="not enrolled with the push relay yet")

    res = await _canopy.claim(claim)
    if res.ok:
        _needs_claim.pop(push_token, None)
        _suspended.pop(push_token, None)
        return
    if not res.definitive:
        raise HTTPException(status_code=502, detail="could not reach the push relay; retry")
    raise HTTPException(status_code=403, detail=res.reason or "claim refused")


class Register(BaseModel):
    # Card keys: "<printerId>" for the print card, "dry:<printerId>:<amsId>" for a drying card —
    # one per DRYING UNIT, since several units can dry at once.
    printer_id: int
    push_token: str
    printer_name: str = ""
    icon_uri: str = ""
    kind: str = "print"  # "print" | "dry" (AMS drying card)
    ams_id: int | None = None  # required in practice for kind="dry"; absent = legacy client
    # Which app registered this card — "expo" (mobile/, expo-widgets) | "native" (native/, SwiftUI).
    # Defaults to "expo" because the RN build is already installed and does not send the field; it
    # can only be changed by an OTA, so an absent value MUST keep meaning what it meant before.
    client: str = EXPO
    # Which phone. Minted by the app, not here, so it exists before any registration of any kind and
    # survives whatever the Keychain survives. Absent = a legacy single-device client.
    device_id: str = ""
    # The device's Canopy claim, forwarded verbatim. Absent in DIRECT mode and from the legacy
    # client, which is why relay mode rejects a registration that omits it rather than binding
    # something unverified.
    claim: dict | None = None


class DeviceReg(BaseModel):
    device_token: str  # raw APNs device token for regular alert notifications
    device_id: str = ""  # which phone — see Register.device_id
    claim: dict | None = None  # see Register.claim


_canopy_http: httpx.AsyncClient | None = None


async def _canopy_transport(method: str, path: str, body: dict | None, bearer: str | None):
    """httpx behind the Canopy client's injected transport.

    One client for the process, not one per call: a fresh AsyncClient means a fresh TLS handshake
    for every push, and this path runs on every meaningful change of every card. Keeping it open
    also lets HTTP/2 multiplex, which is what makes several cards updating in one tick cheap.
    """
    global _canopy_http
    if _canopy_http is None:
        _canopy_http = httpx.AsyncClient(timeout=10, http2=True)
    headers = {"Authorization": f"Bearer {bearer}"} if bearer else {}
    r = await _canopy_http.request(method, f"{CANOPY_URL}{path}", json=body, headers=headers)
    try:
        return r.status_code, r.json()
    except (json.JSONDecodeError, ValueError):
        return r.status_code, None


async def _ensure_enrolled() -> None:
    """Enrol with Canopy, re-adopting our previous identity if we have a recovery code.

    Failure is deliberately NOT fatal: the service still serves collections, still answers the
    phone, and retries. A relay that cannot be reached at boot must not take the whole companion
    down with it.
    """
    global _canopy
    if not RELAY_MODE:
        return
    _canopy = canopy.CanopyClient(_canopy_transport)

    stored = {}
    try:
        stored = json.loads(TENANT_FILE.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        pass

    if stored.get("tenant_id") and stored.get("tenant_secret"):
        _canopy.credentials = canopy.Credentials(
            stored["tenant_id"], stored["tenant_secret"], stored.get("recovery_code", ""))
        return

    try:
        creds = await _canopy.enroll(recovery_code=stored.get("recovery_code", ""))
    except Exception as e:  # noqa: BLE001
        print(f"[canopy] enrolment failed ({e}); push is off until it succeeds", flush=True)
        _canopy.credentials = None
        return

    DATA_DIR.mkdir(parents=True, exist_ok=True)
    TENANT_FILE.write_text(json.dumps({
        "tenant_id": creds.tenant_id, "tenant_secret": creds.tenant_secret,
        "recovery_code": creds.recovery_code,
    }))
    # Printed once, and only here. The recovery code confers tenant identity, so it must not be
    # served from an endpoint gated by a key whose scope we do not control — save it somewhere that
    # outlives this data volume, or a full rebuild cannot re-adopt these bindings.
    print(f"[canopy] enrolled as {creds.tenant_id}", flush=True)
    print(f"[canopy] RECOVERY CODE (save this — shown once): {creds.recovery_code}", flush=True)


@app.on_event("startup")
async def _startup() -> None:
    _load()
    if RELAY_MODE:
        await _ensure_enrolled()
    else:
        _apns_token()  # fail fast if the .p8 / key id is wrong
    asyncio.create_task(_poll_loop())
    backend = f"relay {CANOPY_URL}" if RELAY_MODE else f"APNs {APNS_HOST}"
    print(f"trellis up — {backend}, "
          f"{registry.card_count(_regs)} cards, {len(_device_tokens)} device(s)", flush=True)


@app.get("/health")
async def health() -> dict:
    return {
        "ok": True, "registrations": registry.card_count(_regs), "devices": len(_device_tokens), "apns_host": APNS_HOST,
        # Per-client counts: a native build whose registration silently landed as "expo" — the exact
        # failure the discriminator exists to prevent, and one that looks like a healthy 200 from
        # every other angle — is visible here without touching the phone.
        "cards_by_client": registry.count_by(_regs, client_of),
        "push_suspended": [{"token": t[:8], "reason": why} for t, why in _suspended.items()],
        "start_tokens_by_client": {c: sum(1 for t in _p2s_tokens if norm_client(_p2s_clients.get(t)) == c) for c in (EXPO, NATIVE)},
    }


class StartReg(BaseModel):
    push_token: str  # ActivityKit push-to-start token (per device, per attributes type)
    icon_uri: str = ""  # App-Group glyph path, so remote starts match app-started cards
    client: str = EXPO  # "expo" | "native" — see Register.client
    device_id: str = ""  # which phone — see Register.device_id
    claim: dict | None = None  # see Register.claim


@app.post("/register-start")
async def register_start(r: StartReg, _: None = Depends(_require_key)) -> dict:
    await _forward_claim(r.claim, r.push_token, r.device_id or registry.LEGACY_DEVICE)
    if r.push_token:
        if r.push_token not in _p2s_tokens:
            _p2s_tokens.append(r.push_token)
            print(f"[p2s] registered start token {r.push_token[:8]}… ({len(_p2s_tokens)} total)", flush=True)
        if r.icon_uri:
            _p2s_icons[r.push_token] = r.icon_uri
        # Always (re)written, never gated on a truthy value: the same device reinstalled with the
        # OTHER build can re-present a token we already hold, and a stale client here means a start
        # payload of the wrong shape — accepted by APNs, no card on the phone.
        _p2s_clients[r.push_token] = norm_client(r.client)
        if r.device_id:
            _p2s_devices[r.push_token] = r.device_id
        _save()
    return {"ok": True}


class Sync(BaseModel):
    tokens: list[str] = []  # EVERY live activity the app can currently see
    icon_uri: str = ""
    # Which device is reporting. Without it two phones share one Bambuddy API key and are
    # indistinguishable, so one phone's reconcile deregisters the other's cards — they then freeze,
    # never updated and never ended, while the next tick starts duplicates underneath.
    device_id: str = ""


@app.post("/sync")
async def sync(r: Sync, _: None = Depends(_require_key)) -> dict:
    """Reconcile our registry against what actually exists on the device.

    APNs answering 200 does NOT mean a card exists — a user who swipes a card away leaves us pushing
    into the void while our registry still claims we own it, and since we refuse to start a card for a
    key we already hold, no replacement is ever created. That deadlock is exactly how the lock screen
    ended up empty mid-print. The app is the only party that can observe the truth, so it sends the
    FULL set of tokens it can see and we converge on it:
      * a registration whose token is absent -> that card is gone; drop it so a fresh one can start;
      * an unknown token that matches our outstanding remote start -> bind it (this is what makes a
        remotely-started card updatable, instead of frozen at 0%);
      * an unknown token with nothing to claim it -> we return it for the app to end.
    """
    seen = {t for t in r.tokens if t}
    device = r.device_id or registry.LEGACY_DEVICE

    # 1. Forget THIS DEVICE's cards that no longer exist. Scoping is essential: a report from one
    # phone says nothing about what another phone can see.
    for key in registry.prune_device(_regs, device, seen):
        print(f"[sync] card {key} is gone from {device} — dropped, free to restart", flush=True)

    # 2. Claim / disown the tokens we were handed.
    known = registry.all_tokens(_regs)
    orphans: list[str] = []
    for tok in seen:
        if tok in known:
            continue
        key = _pending_key(device)
        if key is None:
            orphans.append(tok)
            continue
        pid = int(key.split(":")[1]) if key.startswith("dry:") else int(key)
        registry.upsert(_regs, key, {
            "printerId": pid, "pushToken": tok, "deviceId": device,
            "printerName": _printers_cache.get(pid) or f"Printer {pid}",
            "iconUri": r.icon_uri, "kind": "dry" if key.startswith("dry:") else "print",
            # /sync is the RN app's reconcile path and ONLY the RN app's — the native app hands a
            # remotely-started card over through /register (with client:"native") when its push-token
            # stream fires, and never posts here. Stated rather than left to default so a native app
            # that grows a /sync call is an obvious edit rather than a silent expo-shaped push.
            "client": EXPO,
            "lastPush": 0, "lastState": None,
        })
        _p2s_pending.pop(_pending_id(key, device), None)
        known.add(tok)
        print(f"[sync] bound {key} -> token {tok[:8]}… (card is now updatable)", flush=True)

    _save()
    return {"end": orphans, "cards": list(_regs.keys()), "needs_claim": _needs_claim_for(device)}


@app.post("/register-device")
async def register_device(r: DeviceReg, _: None = Depends(_require_key)) -> dict:
    await _forward_claim(r.claim, r.device_token, r.device_id or registry.LEGACY_DEVICE)
    if r.device_token not in _device_tokens:
        _device_tokens.append(r.device_token)
        _save()
        print(f"[device] registered {r.device_token[:8]}… ({len(_device_tokens)} total)", flush=True)
    return {"ok": True}


@app.post("/register")
async def register(r: Register, _: None = Depends(_require_key)) -> dict:
    key = str(r.printer_id) if r.kind != "dry" else (
        f"dry:{r.printer_id}:{r.ams_id}" if r.ams_id is not None else f"dry:{r.printer_id}"
    )
    device = r.device_id or registry.LEGACY_DEVICE
    await _forward_claim(r.claim, r.push_token, device)
    # upsert, not assign: another phone may already hold a card under this key, and clobbering it
    # freezes that phone's card for the rest of the print.
    registry.upsert(_regs, key, {
        "printerId": r.printer_id, "pushToken": r.push_token, "deviceId": device,
        "printerName": r.printer_name,
        "iconUri": r.icon_uri, "kind": r.kind, "client": norm_client(r.client),
        "lastPush": 0, "lastState": None,
    })
    _suspended.pop(r.push_token, None)  # a fresh registration clears any push suspension
    _needs_claim.pop(r.push_token, None)
    if r.kind != "dry":
        _p2s_pending.pop(_pending_id(str(r.printer_id), device), None)  # reachable again
    _save()
    print(f"[register] {r.kind} printer {r.printer_id} ({r.printer_name}) [{norm_client(r.client)}] "
          f"token {r.push_token[:8]}…", flush=True)
    return {"ok": True}


@app.post("/unregister")
async def unregister(printer_id: int, push_token: str = "", device_id: str = "",
                     _: None = Depends(_require_key)) -> dict:
    """Drop one card.

    Token-scoped, because "this card is gone" is a statement about one device. Dropping the whole
    key would take every other phone's live card with it — they would freeze, never be ended, and
    the next tick would start duplicates underneath. The unqualified form is kept only for the
    legacy single-device client.
    """
    key = str(printer_id)
    if push_token:
        registry.drop_token(_regs, key, push_token)
    elif device_id:
        registry.drop_device(_regs, key, device_id)
    else:
        registry.drop_key(_regs, key)
    _save()
    return {"ok": True}


# MARK: - MakerWorld collections
#
# The only part of this service that is not about push. It is here because it needs the Bambu Cloud
# bearer, that bearer must not reach the phone, and this is the one machine that already has it and
# that the app already trusts. See makerworld.py for why the token stays put.
#
# Both endpoints are gated on the same Bambuddy API key as everything else, so nobody who merely
# knows the public URL can read the owner's collections.


@app.get("/makerworld/collections")
async def makerworld_collections(_: None = Depends(_require_key)) -> dict:
    try:
        return {"collections": await mw.list_collections()}
    except mw.CollectionsUnavailable as e:
        # The reason is the payload. "Couldn't load collections" would send the owner looking at the
        # wrong machine — the fix is usually a Bambu Cloud sign-in on Bambuddy, not anything here.
        raise HTTPException(status_code=e.status, detail=e.message) from e


@app.get("/makerworld/collections/{collection_id}/designs")
async def makerworld_collection_designs(
    collection_id: int, offset: int = 0, limit: int = 20, _: None = Depends(_require_key)
) -> dict:
    try:
        return await mw.collection_designs(collection_id, offset=offset, limit=min(max(limit, 1), 50))
    except mw.CollectionsUnavailable as e:
        raise HTTPException(status_code=e.status, detail=e.message) from e


@app.get("/makerworld/designs/{design_id}/collections")
async def makerworld_design_collections(design_id: int, _: None = Depends(_require_key)) -> dict:
    """Which collections contain this design — what the app needs to draw the checkmarks."""
    try:
        return {"collections": await mw.design_collection_ids(design_id)}
    except mw.CollectionsUnavailable as e:
        raise HTTPException(status_code=e.status, detail=e.message) from e


# PUT/DELETE rather than one endpoint with a flag: adding and removing are different intentions, and
# the upstream call they share replaces the design's WHOLE membership, so which one was meant must
# never be inferred from a payload.


@app.put("/makerworld/collections/{collection_id}/designs/{design_id}")
async def makerworld_add_to_collection(
    collection_id: int, design_id: int, _: None = Depends(_require_key)
) -> dict:
    try:
        return await mw.set_design_collections(design_id, collection_id, add=True)
    except mw.CollectionsUnavailable as e:
        raise HTTPException(status_code=e.status, detail=e.message) from e


@app.delete("/makerworld/collections/{collection_id}/designs/{design_id}")
async def makerworld_remove_from_collection(
    collection_id: int, design_id: int, _: None = Depends(_require_key)
) -> dict:
    try:
        return await mw.set_design_collections(design_id, collection_id, add=False)
    except mw.CollectionsUnavailable as e:
        raise HTTPException(status_code=e.status, detail=e.message) from e
