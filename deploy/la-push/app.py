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
import json
import os
import time
from pathlib import Path
from typing import Any

import httpx
import jwt  # PyJWT
from fastapi import FastAPI
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
MIN_UPDATE_S = float(os.environ.get("MIN_UPDATE_S", "4"))
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

    # Nozzles are physical: n1 = left/only head, n2 = right (H2-series). Pick the ACTIVE head exactly
    # as present.ts does: trust active_extruder; else the head that's DRIVEN (only one has a target —
    # the idle one reads 0); else the hotter one. A just-deactivated head can still be hotter, so a
    # temperature compare alone picks the wrong nozzle mid tool-change.
    n1, n1t = _rnd(t.get("nozzle")), _rnd(t.get("nozzle_target"))
    has_n2 = t.get("nozzle_2") is not None
    n2, n2t = _rnd(t.get("nozzle_2")), _rnd(t.get("nozzle_2_target"))
    active_idx = 0
    if has_n2:
        ae = status.get("active_extruder")
        if ae == 0 or ae == 1:
            active_idx = ae
        elif (n1t > 0) != (n2t > 0):
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
        or abs(a["nozzle"] - b["nozzle"]) >= 2
        # New keys use .get(): a card's lastState persists across deploys, so an old-schema stored
        # state (pre-dual-nozzle) may lack these — treat missing as 0 rather than KeyError-ing the tick.
        or abs(a.get("nozzle2", 0) - b["nozzle2"]) >= 2
        or abs(a["bed"] - b["bed"]) >= 2
        or a["nozzleTarget"] != b["nozzleTarget"]
        or a.get("nozzle2Target", 0) != b["nozzle2Target"]
        or a.get("activeNozzle", 0) != b["activeNozzle"]
        or a["bedTarget"] != b["bedTarget"]
        or abs(a["etaEpochMs"] - b["etaEpochMs"]) >= 60_000
    )


# ---- state ----
# _regs: str(printerId) -> Live-Activity card {printerId, pushToken, printerName, iconUri, lastPush, lastState}
_regs: dict[str, dict] = {}
# _device_tokens: raw APNs device tokens for regular alert notifications (print done / error).
_device_tokens: list[str] = []
# _last_kind: printerId -> last-seen kind, for edge-triggered notifications (not persisted; rebuilt on boot).
_last_kind: dict[int, str] = {}
# _printers_cache: printerId -> name, refreshed from Bambuddy.
_printers_cache: dict[int, str] = {}


def _load() -> None:
    global _regs, _device_tokens
    try:
        data = json.loads(REG_FILE.read_text())
        _regs = data.get("regs", {})
        _device_tokens = data.get("devices", [])
    except (FileNotFoundError, json.JSONDecodeError):
        _regs, _device_tokens = {}, []


def _save() -> None:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    REG_FILE.write_text(json.dumps({"regs": _regs, "devices": _device_tokens}))


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


async def _apns_send(client: httpx.AsyncClient, push_token: str, aps: dict) -> int:
    r = await client.post(
        f"https://{APNS_HOST}/3/device/{push_token}",
        headers={
            "authorization": f"bearer {_apns_token()}",
            "apns-topic": APNS_TOPIC,
            "apns-push-type": "liveactivity",
            "apns-priority": "10",
        },
        json={"aps": aps},
    )
    return r.status_code


async def _push_update(client: httpx.AsyncClient, reg: dict, cs: dict) -> int:
    return await _apns_send(client, reg["pushToken"], {"timestamp": int(time.time()), "event": "update", "content-state": cs})


async def _push_end(client: httpx.AsyncClient, reg: dict, cs: dict) -> int:
    return await _apns_send(client, reg["pushToken"], {"timestamp": int(time.time()), "event": "end", "content-state": cs, "dismissal-date": int(time.time()) + 1800})


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
    ids: set[int] = {int(k) for k in _regs}
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

        # 1) Live-Activity card: throttled update, or end on a terminal state.
        if reg:
            cs = {"printerName": name, "iconUri": reg.get("iconUri", ""), **fields}
            if kind in ("complete", "error", "idle"):
                code = await _push_end(client, reg, cs)
                print(f"[end] printer {pid} -> {code}", flush=True)
                _regs.pop(str(pid), None)
                _save()
            elif meaningful_change(reg.get("lastState"), cs) and (now - reg.get("lastPush", 0) >= MIN_UPDATE_S):
                code = await _push_update(client, reg, cs)
                if code in (400, 410):
                    print(f"[drop] printer {pid} -> {code}", flush=True)
                    _regs.pop(str(pid), None)
                    _save()
                else:
                    reg["lastState"], reg["lastPush"] = cs, now
                    _save()

        # 2) Alert on a state transition (edge-triggered; the first observation is silent).
        if _device_tokens:
            prev = _last_kind.get(pid)
            if prev is not None and prev != kind:
                model = fields.get("name") or "your print"
                if kind == "complete":
                    await _notify(client, f"✅ {name} — print finished", model)
                elif kind == "error":
                    await _notify(client, f"⚠️ {name} — needs attention", model)
            _last_kind[pid] = kind


# ---- HTTP API ----
app = FastAPI(title="la-push")


class Register(BaseModel):
    printer_id: int  # one card per printer -> registrations are keyed by printer_id
    push_token: str
    printer_name: str = ""
    icon_uri: str = ""


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


@app.post("/register-device")
async def register_device(r: DeviceReg) -> dict:
    if r.device_token not in _device_tokens:
        _device_tokens.append(r.device_token)
        _save()
        print(f"[device] registered {r.device_token[:8]}… ({len(_device_tokens)} total)", flush=True)
    return {"ok": True}


@app.post("/register")
async def register(r: Register) -> dict:
    _regs[str(r.printer_id)] = {
        "printerId": r.printer_id, "pushToken": r.push_token, "printerName": r.printer_name,
        "iconUri": r.icon_uri, "lastPush": 0, "lastState": None,
    }
    _save()
    print(f"[register] printer {r.printer_id} ({r.printer_name}) token {r.push_token[:8]}…", flush=True)
    return {"ok": True}


@app.post("/unregister")
async def unregister(printer_id: int) -> dict:
    _regs.pop(str(printer_id), None)
    _save()
    return {"ok": True}
