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
APNS_TOPIC = os.environ.get("APNS_TOPIC", "com.mvks5.bambu.push-type.liveactivity")
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


def classify(status: dict) -> tuple[dict, str]:
    """Return (content-state-fields, kind). kind ∈ live|complete|error|idle|offline."""
    t = status.get("temperatures") or {}
    if not status.get("connected"):
        return ({"name": "", "stateLabel": "Offline", "tint": COLORS["idle"], "progress": 0, "layer": 0,
                 "totalLayers": 0, "etaEpochMs": 0, "finished": False, "symbol": SYMBOLS["Error"],
                 "nozzle": 0, "nozzleTarget": 0, "bed": 0, "bedTarget": 0,
                 "modelUri": "", "queueCount": 0, "nextName": ""}, "offline")

    state = (status.get("state") or "").upper()
    progress = _rnd(status.get("progress"))
    layer = int(status.get("layer_num") or 0)
    total = int(status.get("total_layers") or 0)
    remaining = status.get("remaining_time") or 0

    noz, noz_t = _rnd(t.get("nozzle")), _rnd(t.get("nozzle_target"))
    if t.get("nozzle_2") is not None:  # dual-nozzle (H2 series) — pick the active/hotter extruder
        ae = status.get("active_extruder")
        n2, n2t = _rnd(t.get("nozzle_2")), _rnd(t.get("nozzle_2_target"))
        if ae == 1 or (ae not in (0, 1) and n2 > noz):
            noz, noz_t = n2, n2t
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
        heating_up = ((noz < noz_t - 3) or (bed < bed_t - 2)) and progress < 2
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
        "nozzle": noz, "nozzleTarget": noz_t, "bed": bed, "bedTarget": bed_t,
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
        or abs(a["bed"] - b["bed"]) >= 2
        or a["nozzleTarget"] != b["nozzleTarget"]
        or a["bedTarget"] != b["bedTarget"]
        or abs(a["etaEpochMs"] - b["etaEpochMs"]) >= 60_000
    )


# ---- registrations (activityId -> {printerId, pushToken, printerName, iconUri, lastPush, lastState}) ----
_regs: dict[str, dict] = {}


def _load() -> None:
    global _regs
    try:
        _regs = json.loads(REG_FILE.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        _regs = {}


def _save() -> None:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    REG_FILE.write_text(json.dumps(_regs))


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
    if not _regs:
        return
    by_printer: dict[int, list[str]] = {}
    for aid, reg in _regs.items():
        by_printer.setdefault(reg["printerId"], []).append(aid)

    for printer_id, aids in by_printer.items():
        status = await _get_status(client, printer_id)
        if status is None:
            continue
        fields, kind = classify(status)
        now = time.time()
        for aid in aids:
            reg = _regs.get(aid)
            if not reg:
                continue
            cs = {"printerName": reg.get("printerName", ""), "iconUri": reg.get("iconUri", ""), **fields}
            if kind in ("complete", "error", "idle"):
                code = await _push_end(client, reg, cs)
                print(f"[end] printer {printer_id} activity {aid[:8]} -> {code}", flush=True)
                _regs.pop(aid, None)
                _save()
            elif meaningful_change(reg.get("lastState"), cs) and (now - reg.get("lastPush", 0) >= MIN_UPDATE_S):
                code = await _push_update(client, reg, cs)
                if code in (400, 410):  # BadDeviceToken / Unregistered — drop it
                    print(f"[drop] activity {aid[:8]} -> {code}", flush=True)
                    _regs.pop(aid, None)
                    _save()
                else:
                    reg["lastState"], reg["lastPush"] = cs, now
                    _save()


# ---- HTTP API ----
app = FastAPI(title="la-push")


class Register(BaseModel):
    printer_id: int  # one card per printer -> registrations are keyed by printer_id
    push_token: str
    printer_name: str = ""
    icon_uri: str = ""


@app.on_event("startup")
async def _startup() -> None:
    _load()
    _apns_token()  # fail fast if the .p8 / key id is wrong
    asyncio.create_task(_poll_loop())
    print(f"la-push up — APNs {APNS_HOST}, topic {APNS_TOPIC}, {len(_regs)} registrations", flush=True)


@app.get("/health")
async def health() -> dict:
    return {"ok": True, "registrations": len(_regs), "apns_host": APNS_HOST}


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
