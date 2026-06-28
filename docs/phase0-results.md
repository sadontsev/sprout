# Phase 0 Results — Backend Bring-up & Validation Spike

**Verified:** 2026-06-28. **Outcome: PASS.** The full architecture is proven end-to-end on the real China-market A1. This document is the source of truth the iOS-app plan (Phase 1+) builds on.

> **Secrets are NOT in this file.** The admin password, app API key, camera token, JWT, and HA token live on `homeserver` under `~/.config/bambu-phase0/` (mode 600) and were shown to the owner once. Reference them by file, never commit their values.

---

## 1. Headline findings

- **Bambuddy works fully on the A1** (monitor + control + camera + server-side slicing), registered as printer **id 1**.
- **Coexistence proven:** Bambuddy and the existing `ha-bambulab` integration run **simultaneously** against the same A1 (firmware `01.08.00.00`) with **no telemetry flap**. **Home Assistant was left untouched** — the planned "disable ha-bambulab + MQTT re-publish" (Task 8) was **dropped**. (The old single-MQTT-client reports were firmware `01.04`; they do not apply here.)
- **Server-side slicing works:** Bambu Studio CLI sliced a test STL → printable `.gcode.3mf` with print-time/filament metadata.
- **HTTPS remote access is live** via the existing cloudflared tunnel, gated by Bambuddy auth.

## 2. Connection facts (for the app)

| | |
|---|---|
| Bambuddy LAN | `http://192.168.1.10:8910` (host-networked on homeserver) |
| Bambuddy remote | **`https://bambuddy.example.com`** (cloudflared tunnel `00000000-0000-0000-0000-000000000000`) |
| Version | Bambuddy `0.2.4.7` — image `docker.io/maziggy/bambuddy:latest` @ `sha256:fd327490566fc7f56d798dc989cf94b6df9da93909e203330a87d48786984331` (GHCR pkg is private; use Docker Hub) |
| App auth | **`X-API-Key`** header (key in `homeserver:~/.config/bambu-phase0/bb_apikey`), scoped: read_status + queue + control + manage_library. Verified: 401 without, 200 with. |
| Admin (web UI only) | user `max`, password in `homeserver:~/.config/bambu-phase0/bb_admin_pw`. JWT login `POST /api/v1/auth/login` (24h, no refresh). Admin-only mutations need JWT; the app's API key covers all operational endpoints. |
| Realtime | WebSocket `wss://bambuddy.example.com/api/v1/ws` — first mint a ws-token via `POST /api/v1/auth/ws-token`, connect with `?token=`. Pushes `printer_status`. REST `GET /api/v1/printers/1/status` is the poll fallback. |
| Printer | A1, id `1`, serial `REDACTEDSERIAL1`, IP `192.168.1.20`, fw `01.08.00.00`, AMS Lite (1 unit, 4 trays). Access code stored **only** in Bambuddy. |

## 3. Verified capabilities + exact endpoints

- **Status:** `GET /api/v1/printers/1/status` → `connected`, `state`, `progress`, `layer_num`/`total_layers`, `temperatures.{nozzle,nozzle_target,bed,bed_target}`, `ams[]`, `chamber_light`, etc.
- **Control (verified):** `POST /api/v1/printers/1/chamber-light?on=true|false` (✅ toggled live); `POST /api/v1/printers/1/print/{pause,resume,stop}`; `POST /api/v1/printers/1/print-speed`; `POST /api/v1/printers/1/ams/{load,unload}`; `POST /api/v1/printers/1/home-axes`. **No** fan-speed or raw-gcode endpoint exists.
- **Camera:** `GET /api/v1/printers/1/camera/snapshot?token=<cam-token>` → JPEG **1536×1080** (✅). MJPEG stream at `/camera/stream`. Long-lived camera token in `homeserver:~/.config/bambu-phase0/` (mint via `POST /api/v1/printers/camera/stream-token`). A1 has no plate PNG from headless slice.
- **Slicing (verified):**
  1. Upload: `POST /api/v1/library/files` (multipart, field `file`) → returns file `id`.
  2. Presets: `GET /api/v1/slicer/presets` → `standard.{printer,process,filament}` lists of objects `{id,name,source,...}`.
  3. Slice: `POST /api/v1/library/files/{id}/slice` with JSON `{ "printer_preset": <printer obj>, "process_preset": <process obj>, "filament_preset": <filament obj>, "plate": 1, "export_3mf": true }`. **Pass the full preset OBJECT** in `*_preset` (the `*_preset_id` fields are integer DB ids for user presets, not names).
  4. Poll: `GET /api/v1/slice-jobs/{job_id}` → `result.{library_file_id, print_time_seconds, filament_used_g, filament_used_mm}`.
  - Verified A1 0.4-nozzle preset names: machine **`Bambu Lab A1 0.4 nozzle`**, process **`0.20mm Standard @BBL A1`**, filament **`Bambu PLA Basic @BBL A1`**. Test cube → `cube20.gcode.3mf`, **738 s / 3.75 g**, contains `Metadata/plate_1.gcode` (printable).
  - **Print-Wizard preview:** rich metadata via `GET /api/v1/library/files/{id}/plates` (time, filament, color, embedded printer). **Headless slice has NO plate thumbnail** (`has_thumbnail:false`) → use `POST /api/v1/library/generate-stl-thumbnails` or the embedded G-code viewer (`/library/files/{id}/gcode`).
- **Print start:** `POST /api/v1/queue/` with the sliced file + `use_ams` + `ams_mapping`. **Physical print DEFERRED** — printer auto-powered-off after its job; run the real print test when present + powered on.
- **Plug:** `switch.3d_printer_plug` lives in HA; Bambuddy has an HA smart-plug integration to drive it (not yet configured — Phase 2). Printer power auto-cut after print (plug → off, 0 W).

## 4. Slicer sidecars (on homeserver)

- `bambu-studio-api` → `localhost:3001` (Bambuddy `SLICER_API_URL`), `orca-slicer-api` → `localhost:3003`. Images `docker.io/maziggy/{bambu-studio-api,orca-slicer-api}:latest` (amd64; GHCR private). Bundled **A1 profiles present** (328 BBL profiles incl. A1 machine/process/filament). Compose committed at `deploy/slicer-api/`.

## 5. Stability

- Coexistence soak: while the printer was powered on (print + idle), Bambuddy `connected:true` and HA both live every 30 s, **0 Bambuddy restarts**. Soak ended when the plug auto-powered-off after the print (both clients dropped together = printer offline, **not** a flap).

## 6. Outstanding / follow-ups

- **Cloudflare Access (recommended hardening, owner action):** the tunnel currently relies on Bambuddy's own auth (401 without key). For defense-in-depth, in the **Zero Trust dashboard** (account `88925d559b52ae4efe8f91861067c806`): Access → Applications → Add self-hosted `bambuddy.example.com`; Access → Service Auth → create a service token "Bambuddy iOS App"; policy action **Service Auth** for that token (+ an Allow for `owner@example.com` for browser). The app then sends `CF-Access-Client-Id`/`CF-Access-Client-Secret` headers in addition to `X-API-Key`. (No on-box Zero Trust API token exists, so this is manual.)
- **DNS negative cache:** `bambuddy.example.com` CNAME was created after some resolvers had cached NXDOMAIN (SOA min TTL 1800 s) → up to 30 min for 8.8.8.8 / pihole to resolve. `@1.1.1.1` resolves immediately. Self-heals; no action.
- **Physical print test:** deferred to printer-on + owner present.
- **Bambuddy auth quirk:** password policy requires upper + special char (min length). Tokens are 24h with no refresh → the app uses the long-lived API key, not JWT.

## 7. Repo deploy artifacts

`deploy/bambuddy/` (Bambuddy compose + env example), `deploy/slicer-api/` (slicer sidecars), `deploy/README.md`. Running copies on homeserver: `~/docker/bambuddy/`, `~/docker/slicer-api/`. Cloudflared rule added to `/home/max/docker/cloudflared/config.yml` (backup `config.yml.bak.20260628-135453`).
