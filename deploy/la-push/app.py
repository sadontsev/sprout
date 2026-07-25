"""
la-push — keeps Sprout's iOS Live Activities updating when the app is closed.

The app (foreground) starts one Live Activity per printer and registers each card's APNs push token
with this service. This service polls Bambuddy for each registered printer's status and pushes the
Live-Activity ContentState to Apple (APNs, apns-push-type: liveactivity) so the lock-screen cards keep
tracking even after iOS suspends the app. It ends a card when its print finishes/fails/goes idle.

The ContentState shape MUST match PrintActivityProps in the app
(mobile/src/liveactivity/PrintActivity.tsx); the state/colour mapping mirrors present.ts.
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

# ---- config (env) ----
BAMBUDDY_URL = os.environ.get("BAMBUDDY_URL", "http://localhost:8910").rstrip("/")
BAMBUDDY_API_KEY = os.environ["BAMBUDDY_API_KEY"]
APNS_KEY_PATH = os.environ.get("APNS_KEY_PATH", "/keys/apns_key.p8")
APNS_KEY_ID = os.environ["APNS_KEY_ID"]
APNS_TEAM_ID = os.environ["APNS_TEAM_ID"]
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
# _regs: str(printerId) -> Live-Activity card {printerId, pushToken, printerName, iconUri, lastPush, lastState}
_regs: dict[str, dict] = {}
# _device_tokens: raw APNs device tokens for regular alert notifications (print done / error).
_device_tokens: list[str] = []
# _p2s_tokens: ActivityKit push-to-start tokens (one per device) — start cards with the app closed.
_p2s_tokens: list[str] = []
# _p2s_dry_sent: pid -> True once we remote-started a dry card for the CURRENT cycle (reset when idle).
_p2s_dry_sent: dict[str, bool] = {}
# _p2s_icons: p2s token -> App-Group glyph URI (the app knows the path; we don't).
_p2s_icons: dict[str, str] = {}
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
_p2s_pending: dict[str, float] = {}
P2S_PENDING_TTL = 600.0
# _last_kind: printerId -> last-seen kind, for edge-triggered notifications. Persisted (in REG_FILE) so a
# restart/crash mid-print doesn't lose the live->complete/error edge and silently drop the alert.
_last_kind: dict[int, str] = {}
# _last_paused: printerId -> was it paused last poll. A pause does NOT change `kind` (PAUSE maps to
# "live" so the lock-screen card survives it), so the kind edge can never see it — yet an AI-detection
# halt is the single most important thing to be told about: the printer is stopped mid-print, waiting
# on a human, and false positives are common with print_halt + every detector enabled.
_last_paused: dict[int, bool] = {}
# _last_dry: "printerId:amsId" -> {"t": minutes remaining, "fil": filament} last seen — drives the
# drying-finished banner (dry_time falling to 0). Persisted for the same restart-survival reason.
_last_dry: dict[str, dict] = {}
# _printers_cache: printerId -> name, refreshed from Bambuddy.
_printers_cache: dict[int, str] = {}


def _load() -> None:
    global _regs, _device_tokens, _last_kind, _last_dry, _p2s_tokens, _p2s_dry_sent, _p2s_icons, _p2s_pending, _last_paused
    try:
        data = json.loads(REG_FILE.read_text())
        _regs = data.get("regs", {})
        _device_tokens = data.get("devices", [])
        # JSON object keys are strings; _last_kind is keyed by int printer id, so coerce back.
        _last_kind = {int(k): v for k, v in data.get("last_kind", {}).items()}
        _last_paused = {int(k): bool(v) for k, v in data.get("last_paused", {}).items()}
        _last_dry = data.get("last_dry", {})
        _p2s_tokens = data.get("p2s", [])
        _p2s_dry_sent = data.get("p2s_dry_sent", {})
        _p2s_icons = data.get("p2s_icons", {})
        _p2s_pending = data.get("p2s_pending", {})
    except (FileNotFoundError, json.JSONDecodeError):
        _regs, _device_tokens, _last_kind, _last_dry, _p2s_tokens, _p2s_dry_sent = {}, [], {}, {}, [], {}
        _p2s_icons, _p2s_pending, _last_paused = {}, {}, {}


def _save() -> None:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    REG_FILE.write_text(json.dumps({"regs": _regs, "devices": _device_tokens, "last_kind": _last_kind,
                                    "last_dry": _last_dry, "p2s": _p2s_tokens, "p2s_dry_sent": _p2s_dry_sent,
                                    "p2s_icons": _p2s_icons, "p2s_pending": _p2s_pending,
                                    "last_paused": _last_paused}))


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


async def _apns_send(client: httpx.AsyncClient, push_token: str, aps: dict, priority: str = "10") -> int:
    r = await client.post(
        f"https://{APNS_HOST}/3/device/{push_token}",
        headers={
            "authorization": f"bearer {_apns_token()}",
            "apns-topic": APNS_TOPIC,
            "apns-push-type": "liveactivity",
            # Priority 10 spends the device's Live-Activity budget; 5 is delivered opportunistically
            # and conserves it. Routine drift goes at 5, real state changes at 10.
            "apns-priority": priority,
        },
        json={"aps": aps},
    )
    return r.status_code


def _urgent(last: dict | None, cs: dict) -> bool:
    """Deserves priority 10: first push for a card, a state-label flip (Printing->Paused, Heating->
    Printing, Drying->Done…), or the finished flag. Temp/progress/ETA drift is priority 5."""
    if last is None:
        return True
    return last.get("stateLabel") != cs.get("stateLabel") or bool(last.get("finished")) != bool(cs.get("finished"))


def _envelope(cs: dict) -> dict:
    """The widget's native ContentState is Codable{name: String, props: String} — `props` is the
    JSON-SERIALIZED props string and `name` is the registered component. A flat props dict fails
    decoding ON-DEVICE while APNs still answers 200 — pushed updates silently never applied."""
    return {"name": "PrintActivity", "props": json.dumps(cs, separators=(",", ":"))}


async def _push_update(client: httpx.AsyncClient, reg: dict, cs: dict, priority: str = "5") -> int:
    return await _apns_send(client, reg["pushToken"], {"timestamp": int(time.time()), "event": "update", "content-state": _envelope(cs)}, priority)


async def _push_start(client: httpx.AsyncClient, push_token: str, cs: dict) -> int:
    """ActivityKit push-to-start (iOS 17.2+): starts the Live Activity with the app closed. The
    per-activity UPDATE token reaches us when iOS wakes the app (or on next open via adoption);
    until then the card still shows live countdowns — etaEpochMs timers tick client-side.
    NOTE: the `alert` block is part of Apple's start-payload spec — starts WITHOUT it were observed
    accepted by APNs (200) but silently discarded on-device (no card, no app wake)."""
    title = (cs.get("printerName") or "Printer").strip() or "Printer"
    body = cs.get("name") or cs.get("stateLabel") or "Started"
    return await _apns_send(client, push_token, {
        "timestamp": int(time.time()), "event": "start",
        "attributes-type": "LiveActivityAttributes", "attributes": {},
        "content-state": _envelope(cs),
        "alert": {"title": f"{title} — {cs.get('stateLabel', 'Started')}", "body": body},
    }, "10")


async def _push_end(client: httpx.AsyncClient, reg: dict, cs: dict) -> int:
    return await _apns_send(client, reg["pushToken"], {"timestamp": int(time.time()), "event": "end", "content-state": _envelope(cs), "dismissal-date": int(time.time()) + 1800})


# ---- Bambuddy ----
async def _get_status(client: httpx.AsyncClient, printer_id: int) -> dict | None:
    try:
        r = await client.get(f"{BAMBUDDY_URL}/api/v1/printers/{printer_id}/status", headers={"X-API-Key": BAMBUDDY_API_KEY}, timeout=8)
        return r.json() if r.status_code == 200 else None
    except (httpx.HTTPError, json.JSONDecodeError):
        return None


async def _list_printers(client: httpx.AsyncClient) -> dict[int, str]:
    try:
        r = await client.get(f"{BAMBUDDY_URL}/api/v1/printers/", headers={"X-API-Key": BAMBUDDY_API_KEY}, timeout=8)
        arr = r.json() if r.status_code == 200 else []
        return {p["id"]: (p.get("name") or f"Printer {p['id']}") for p in arr if p.get("is_active", True)}
    except (httpx.HTTPError, json.JSONDecodeError, KeyError, TypeError):
        return {}


# ---- alert notifications (print done / error) ----
async def _notify(client: httpx.AsyncClient, title: str, body: str) -> None:
    for tok in list(_device_tokens):
        try:
            r = await client.post(
                f"https://{APNS_HOST}/3/device/{tok}",
                headers={"authorization": f"bearer {_apns_token()}", "apns-topic": APNS_BUNDLE_ID, "apns-push-type": "alert", "apns-priority": "10"},
                json={"aps": {"alert": {"title": title, "body": body}, "sound": "default"}},
            )
            print(f"[notify] {title!r} -> {r.status_code}", flush=True)
            if r.status_code in (400, 410):
                _device_tokens.remove(tok)
                _save()
        except httpx.HTTPError as e:
            print(f"[notify] error: {e}", flush=True)


def _pending_key() -> str | None:
    """The single outstanding remote start, dropping it if it has aged out."""
    for key, ts in list(_p2s_pending.items()):
        if time.time() - ts > P2S_PENDING_TTL:
            _p2s_pending.pop(key, None)
            print(f"[p2s] pending {key} expired — the app will end that card as an orphan", flush=True)
            _save()
        else:
            return key
    return None


async def _remote_start(client: httpx.AsyncClient, key: str, cs: dict, label: str) -> bool:
    """Push-to-start one card, unless another start is still awaiting adoption. Returns True if sent."""
    if not _p2s_tokens or key in _regs or _pending_key() is not None:
        return False
    for tok in list(_p2s_tokens):
        code = await _push_start(client, tok, {**cs, "iconUri": _p2s_icons.get(tok, cs.get("iconUri", ""))})
        print(f"[p2s] start {label} -> {code}", flush=True)
        if code in (400, 410):
            _p2s_tokens.remove(tok)
            _p2s_icons.pop(tok, None)
    _p2s_pending[key] = time.time()
    _save()
    return True


def dry_state(status: dict) -> dict | None:
    """AMS drying card ContentState, or None when no cycle is active. Mirrors the app's
    toDryContentState: dry_time (minutes remaining) > 0 is THE active signal; the countdown itself
    renders client-side from etaEpochMs, so pushes only carry temp/humidity drift and the end."""
    ams_list = status.get("ams") or []

    def _f(v) -> float:
        try:
            return float(v or 0)
        except (TypeError, ValueError):
            return 0.0

    # Scan EVERY unit, not ams[0] — the H2C pairs an AMS 2 Pro (id 0) with an AMS HT (id 128), and a
    # cycle on the HT produced no card. Mirrors the app's toDryContentState.
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
    # Poll every printer with a Live-Activity card; also the whole fleet when a device token is
    # registered (so print-done/error alerts fire even with no card up).
    ids: set[int] = {int(r["printerId"]) for r in _regs.values()}
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
        reg = _regs.get(str(pid))
        name = (reg or {}).get("printerName") or _printers_cache.get(pid) or f"Printer {pid}"

        # 1b) Drying card: independent lifecycle driven by ams.dry_time.
        dreg = _regs.get(f"dry:{pid}")
        if dreg:
            dname = dreg.get("printerName") or name
            ds = dry_state(status)
            if ds is None:
                end_cs = {**(dreg.get("lastState") or {}), "printerName": dname, "iconUri": dreg.get("iconUri", ""),
                          "dry": True, "stateLabel": "Done", "finished": True, "etaEpochMs": 0}
                code = await _push_end(client, dreg, end_cs)
                print(f"[end] dry printer {pid} -> {code}", flush=True)
                _regs.pop(f"dry:{pid}", None)
                _save()
            else:
                dcs = {"printerName": dname, "iconUri": dreg.get("iconUri", ""), **ds}
                if meaningful_change(dreg.get("lastState"), dcs) and (now - dreg.get("lastPush", 0) >= MIN_UPDATE_S):
                    prio = "10" if _urgent(dreg.get("lastState"), dcs) else "5"
                    code = await _push_update(client, dreg, dcs, prio)
                    print(f"[update] dry printer {pid} prio {prio} -> {code}", flush=True)
                    if code in (400, 410):
                        print(f"[drop] dry printer {pid} -> {code}", flush=True)
                        _regs.pop(f"dry:{pid}", None)
                        _save()
                    else:
                        dreg["lastState"], dreg["lastPush"] = dcs, now
                        _save()

        # 1) Live-Activity card: throttled update, or end on a terminal state.
        if reg:
            cs = {"printerName": name, "iconUri": reg.get("iconUri", ""), **fields}
            if kind in ("complete", "error", "idle"):
                code = await _push_end(client, reg, cs)
                print(f"[end] printer {pid} -> {code}", flush=True)
                _regs.pop(str(pid), None)
                _save()
            elif meaningful_change(reg.get("lastState"), cs) and (now - reg.get("lastPush", 0) >= MIN_UPDATE_S):
                prio = "10" if _urgent(reg.get("lastState"), cs) else "5"
                code = await _push_update(client, reg, cs, prio)
                print(f"[update] printer {pid} prio {prio} -> {code}", flush=True)
                if code in (400, 410):
                    print(f"[drop] printer {pid} -> {code}", flush=True)
                    _regs.pop(str(pid), None)
                    _save()
                else:
                    reg["lastState"], reg["lastPush"] = cs, now
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
            if kind == "live":
                await _remote_start(client, str(pid), {"printerName": name, **fields}, f"print {pid}")
            else:
                _p2s_pending.pop(str(pid), None)  # cycle over; the next print may start a card again

            ds0 = dry_state(status)
            if ds0 is not None:
                await _remote_start(client, f"dry:{pid}", {"printerName": name, **ds0}, f"dry {pid}")
            else:
                _p2s_pending.pop(f"dry:{pid}", None)

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
                    await _notify(client, f"✅ {name} — print finished", model)
                elif kind == "error":
                    await _notify(client, f"⚠️ {name} — needs attention", model)
                elif kind == "idle" and prev == "live":
                    # A live print that goes IDLE ended WITHOUT completing — aborted by the printer,
                    # or cancelled. This was silent: only complete/error notified, so the one case
                    # you most want to hear about while away produced nothing at all.
                    await _notify(client, f"⏹️ {name} — print stopped", f"{model} ended before finishing.")
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
                await _notify(client, f"⏸️ {name} — print paused", f"{model}. {why}")
            _last_paused[pid] = paused_now
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
                    await _notify(client, f"💨 {name} — drying finished", f"{fil} is dry.")
                if prev_dry is None or prev_dry.get("t") != cur:
                    _last_dry[dkey] = {"t": cur, "fil": (unit.get("dry_filament") or (prev_dry or {}).get("fil") or "")}
                    _save()


# ---- HTTP API ----
app = FastAPI(title="la-push")


# Accepted-key cache: sha256(key) -> monotonic expiry. Never stores raw keys. Bounded — a scan of
# garbage keys can't grow it (only keys Bambuddy ACCEPTED are cached).
_key_cache: dict[str, float] = {}
_KEY_CACHE_TTL = 300.0


async def _require_key(x_api_key: str | None = Header(default=None)) -> None:
    """Gate the register endpoints on a VALID Bambuddy API key (the app already sends it as
    X-API-Key). Without this, ANYONE who knows the public la-push URL could POST their token and
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


class Register(BaseModel):
    printer_id: int  # one card per printer PER KIND -> keyed printer_id ("print") / "dry:<id>"
    push_token: str
    printer_name: str = ""
    icon_uri: str = ""
    kind: str = "print"  # "print" | "dry" (AMS drying card)


class DeviceReg(BaseModel):
    device_token: str  # raw APNs device token for regular alert notifications


@app.on_event("startup")
async def _startup() -> None:
    _load()
    _apns_token()  # fail fast if the .p8 / key id is wrong
    asyncio.create_task(_poll_loop())
    print(f"la-push up — APNs {APNS_HOST}, LA topic {APNS_TOPIC}, alert topic {APNS_BUNDLE_ID}, "
          f"{len(_regs)} cards, {len(_device_tokens)} device(s)", flush=True)


@app.get("/health")
async def health() -> dict:
    return {"ok": True, "registrations": len(_regs), "devices": len(_device_tokens), "apns_host": APNS_HOST}


class StartReg(BaseModel):
    push_token: str  # ActivityKit push-to-start token (per device, per attributes type)
    icon_uri: str = ""  # App-Group glyph path, so remote starts match app-started cards


@app.post("/register-start")
async def register_start(r: StartReg, _: None = Depends(_require_key)) -> dict:
    if r.push_token:
        if r.push_token not in _p2s_tokens:
            _p2s_tokens.append(r.push_token)
            print(f"[p2s] registered start token {r.push_token[:8]}… ({len(_p2s_tokens)} total)", flush=True)
        if r.icon_uri:
            _p2s_icons[r.push_token] = r.icon_uri
        _save()
    return {"ok": True}


class Sync(BaseModel):
    tokens: list[str] = []  # EVERY live activity the app can currently see
    icon_uri: str = ""


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

    # 1. Forget cards that no longer exist.
    for key, reg in list(_regs.items()):
        if reg.get("pushToken") and reg["pushToken"] not in seen:
            _regs.pop(key, None)
            print(f"[sync] card {key} is gone from the device — dropped, free to restart", flush=True)

    # 2. Claim / disown the tokens we were handed.
    known = {reg.get("pushToken") for reg in _regs.values()}
    orphans: list[str] = []
    for tok in seen:
        if tok in known:
            continue
        key = _pending_key()
        if key is None:
            orphans.append(tok)
            continue
        pid = int(key.split(":")[1]) if key.startswith("dry:") else int(key)
        _regs[key] = {
            "printerId": pid, "pushToken": tok,
            "printerName": _printers_cache.get(pid) or f"Printer {pid}",
            "iconUri": r.icon_uri, "kind": "dry" if key.startswith("dry:") else "print",
            "lastPush": 0, "lastState": None,
        }
        _p2s_pending.pop(key, None)
        known.add(tok)
        print(f"[sync] bound {key} -> token {tok[:8]}… (card is now updatable)", flush=True)

    _save()
    return {"end": orphans, "cards": list(_regs.keys())}


@app.post("/register-device")
async def register_device(r: DeviceReg, _: None = Depends(_require_key)) -> dict:
    if r.device_token not in _device_tokens:
        _device_tokens.append(r.device_token)
        _save()
        print(f"[device] registered {r.device_token[:8]}… ({len(_device_tokens)} total)", flush=True)
    return {"ok": True}


@app.post("/register")
async def register(r: Register, _: None = Depends(_require_key)) -> dict:
    key = str(r.printer_id) if r.kind != "dry" else f"dry:{r.printer_id}"
    _regs[key] = {
        "printerId": r.printer_id, "pushToken": r.push_token, "printerName": r.printer_name,
        "iconUri": r.icon_uri, "kind": r.kind, "lastPush": 0, "lastState": None,
    }
    if r.kind != "dry":
        _p2s_pending.pop(str(r.printer_id), None)  # reachable again — future starts are allowed
    _save()
    print(f"[register] {r.kind} printer {r.printer_id} ({r.printer_name}) token {r.push_token[:8]}…", flush=True)
    return {"ok": True}


@app.post("/unregister")
async def unregister(printer_id: int, _: None = Depends(_require_key)) -> dict:
    _regs.pop(str(printer_id), None)
    _save()
    return {"ok": True}
