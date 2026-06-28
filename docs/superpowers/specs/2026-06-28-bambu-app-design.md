# Bambu A1 Companion App — Design Spec

**Date:** 2026-06-28
**Status:** Approved design, pre-implementation
**Author:** Max + Claude

---

## 1. Goal

A personal iOS app to monitor and control a **Chinese-market Bambu Lab A1** (the Bambu Handy app is unusable for this unit) and to bring models in, slice simple ones, and send them to print — usable on the home LAN **and** remotely, securely, for a single user, distributed via **TestFlight**.

### Non-goals (v1)
- Public/multi-user distribution. Single user (owner) only.
- Full "browse MakerWorld in-app → one-tap print any model." MakerWorld auto-import is deferred (it requires slicing, is ToS-gray, and is global-cloud-only while this is a China-cloud unit).
- Multicolor/AMS-**painted** automated slicing (multiple filaments baked into one model). v1 slices **simple single-material STL** only — but the on-device **Print Wizard** still lets you select the printer, pick the filament/plastic + quality, review the sliced result, and confirm which AMS slot feeds the print.
- Smooth live video. The A1 camera is a ~1–5 fps JPEG stream; v1 presents it as a refreshing snapshot.
- Live Activities / lock-screen widgets (v2).

---

## 2. Context & confirmed facts

These were verified live against the running system (Home Assistant `ha-manager` dump) and by source/web research; they are the ground truth the design rests on.

### Printer
- **Bambu Lab A1**, firmware **01.08.00.00**, LAN IP **192.168.1.20**, serial **REDACTEDSERIAL1**, with **AMS Lite** (4 trays) + external spool.
- **LAN-only mode**, `local_mqtt: true`, and `hybrid_mqtt_blocks_control = off` → **third-party control works on this unit today** (empirically confirmed: pause/stop/resume + `print_project_file` are live while printing).
- Local protocols: **MQTT 8883** (TLS, self-signed; user `bblp`, password = LAN Access Code), **FTPS 990** (implicit TLS, same creds, for sliced-file upload), **camera on TCP 6000** (proprietary JPEG "ChamberImage", ~1–5 fps, **NOT RTSP**, single concurrent client; go2rtc cannot relay it).
- **Constraint:** the A1 firmware reliably supports **one** local MQTT client and **one** camera consumer. (Refs: ha-bambulab #174, BambuStudio #2404.)
- Durability note: full local control depends on **Developer Mode** remaining enabled; Bambu could narrow it in a future firmware. Acceptable risk; monitor it.

### Home server (`homeserver.local`)
- Linux **x86_64** (good — slicer Docker images are amd64-only), Docker host. LAN **192.168.1.10**, **Tailscale 100.100.100.100** (exit node); the owner's iPhone is already a tailnet peer.
- Runs cloudflared (dashboard-token tunnel) and Tailscale.

### Home Assistant
- HAOS 18.0 / HA **2026.6.4** as a **VirtualBox VM "HASS"** on `homeserver.local`, VM IP **192.168.1.30**. LAN `http://192.168.1.30:8123`; remote `https://hass.example.com` (HA Cloudflared add-on).
- Printer currently integrated via **`greghesp/ha-bambulab` HACS v2.2.22** in LAN mode — this is the current sole MQTT client of the printer and **must yield ownership** (see §4.4).
- **Tapo P110M** plug for the printer: `switch.3d_printer_plug` + power sensors (`sensor.3d_printer_plug_current_consumption` W, `_today_s_consumption` kWh, `_current` A, `_voltage` V).
- iPhone push already works: `notify.mobile_app_iphone_pro_max` (iOS Companion app).

### Build toolchain (this laptop)
- Node 24, EAS CLI, Xcode 26.3, **Apple Development + iPhone Distribution** signing identities → TestFlight-ready. Reference Expo monorepo: `/Users/max/ai-projects/theknowledge`.

---

## 3. Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Backend | **Adopt Bambuddy** (`maziggy/bambuddy`, AGPL, FastAPI+React) self-hosted on homeserver | Already does A1 monitor/control/camera/AMS/slice/upload for the A1; ~90% of the backend for free |
| App stack | **Expo / React Native** | Owner's existing fluency (theknowledge); EAS + TestFlight ready; backend-proxy design needs no on-device MQTT/TLS/camera-protocol work |
| Remote transport | **Tailscale only** | iPhone already a peer; one path home+away; no transport secret in app; printer access code stays server-side |
| v1 model→print | Send pre-sliced `.gcode.3mf` **+ server-side slice of simple single-material STL**, behind an on-device Print Wizard (printer + plastic + AMS-mapping selection, slice review/confirm) | Reliable; matches Bambuddy's bundled A1 profiles; avoids brittle multicolor/MakerWorld paths; review-before-print prevents wasted filament |
| Slicer engine | **Bambu Studio CLI** (`bambu-studio-api`), Orca as alt | Bambu Studio CLI is more stable for Bambu/A1 files than OrcaSlicer's CLI |
| Printer ownership | **Bambuddy is the sole LAN owner; re-publishes printer state to HA via MQTT** | A1 tolerates one MQTT client; re-publishing preserves the owner's HA dashboards/automations/history |
| Plug | Driven **through Home Assistant** (Bambuddy → HA integration) | No native Tapo driver in Bambuddy; HA already owns the P110M; gains auto-off + cooldown + alerts |
| Push (v1) | **Native Expo push** via a small Bambuddy-webhook → Expo-Push relay | Real push into our app with deep-links |

---

## 4. Architecture

```
 iPhone — Expo app  ──HTTPS/WSS over Tailscale──►  Bambuddy  (homeserver :8000, host net, SQLite)
   API key in Keychain                              │   SOLE LAN owner of the A1:
   one path home & away                             │     MQTT 8883 · FTPS 990 · camera 6000
        │  (push)                                    ├──► slicer sidecar (orca-slicer-api, amd64)
        ▼                                            ├──► HA MQTT re-publish  ──► HA printer entities
 Expo Push / APNs  ◄── Push relay ◄── webhook ◄──────┤                            (dashboards/automations)
                       (homeserver)                          └──► Home Assistant API ──► Tapo P110M plug
 (Bambuddy fronted by `tailscale serve` for HTTPS; NEVER on the public cloudflared tunnel)
```

The Expo app talks to **one backend (Bambuddy)** for everything printer-related; Bambuddy reaches *through* to HA for the plug and re-publishes telemetry to HA for the owner's existing dashboards. The push relay is the only other thing the app touches (indirectly).

### 4.1 Bambuddy server (deploy/configure)
- Container `ghcr.io/maziggy/bambuddy:<pinned>`, `network_mode: host`, port `8000`, volume `bambuddy_data` (SQLite). Set `JWT_SECRET_KEY`, `TZ`. **Pin the version**; couple loosely (pre-1.0, single maintainer).
- **Enable auth**; create a **scoped API key** (`can_read_status`, `can_queue`, `can_control_printer`, `can_manage_library`; not admin) for the app. Long-lived **camera token** for the snapshot stream.
- Register the A1 via `POST /api/v1/printers/` with IP/serial/access-code (printer in LAN + Developer Mode). The access code lives **only** here.
- Health: `/health`; client codegen source: `/openapi.json` (publicly reachable on the tailnet).

### 4.2 Slicer sidecar
- **Default engine: Bambu Studio CLI** via the `bambu-studio-api` sidecar (amd64, `bambu_studio_api_url=http://localhost:3001`), selected with Bambuddy's `preferred_slicer = bambu_studio` setting. Bambu Studio's CLI is more reliable than OrcaSlicer's for Bambu/A1 files (Orca's CLI is more segfault-prone). `orca-slicer-api` (`:3003`) stays available as an alternative; the final choice is confirmed in the Phase 0 spike.
- Uses **bundled "standard" A1 machine/process/filament profiles** — no cloud account needed for simple STL.
- **Host:** runs headless in the Linux amd64 container on homeserver (x86_64), which is the plan. homeserver also has a **Windows VM in VirtualBox** available as a fallback slicer host if ever needed, but the Linux container path is cleaner.
- Slicing and printing are **separate steps**, surfaced as an on-device **Print Wizard** with a review/confirm gate (see §5.1): `POST /library/files/{id}/slice` → poll `GET /slice-jobs/{id}` (returns `print_time_seconds`, `filament_used_g`, `filament_used_mm`) → user reviews preview + estimates → enqueue via `POST /queue/` with `ams_mapping` + `use_ams`. Bind the sidecar to loopback/tailnet only (it executes a slicer on uploaded files).

### 4.3 Transport / HTTPS
- `tailscale serve` (or Caddy) fronts Bambuddy → `https://bambuddy.<tailnet>.ts.net`, satisfying iOS App Transport Security without an exception. App reaches it over the tailnet; identical path at home and away. The slicer sidecar and Bambuddy are **never** exposed via the public cloudflared tunnel.

### 4.4 Home Assistant reconciliation (the one intrusive change)
- **Disable `ha-bambulab`'s direct printer connection** so Bambuddy is the sole MQTT/camera client (avoids the one-client flap).
- Turn on **Bambuddy's MQTT publishing → HA Mosquitto** so HA re-gains printer entities (via MQTT discovery) for the owner's existing dashboards/automations/history.
- Re-point the existing HMS-error actionable-push automation, if kept, to the re-published entities (or migrate it to the new app's push — see §4.6).
- Plug: Bambuddy controls `switch.3d_printer_plug` through HA; configure auto-off after print + temperature/timer cooldown + power alerts in Bambuddy.

### 4.5 Expo app (build)
- **Stack:** Expo (managed) + EAS Build + TestFlight (internal); TypeScript; React Query for REST; a typed client generated from Bambuddy `/openapi.json`; a WebSocket client (`/api/v1/ws`, query-param ws-token) for live telemetry with REST `/status` polling fallback; `expo-secure-store` (Keychain, `WhenUnlockedThisDeviceOnly`) for the API key; Tailscale handled at OS level (no in-app SDK).
- **Camera:** snapshot-poll `/printers/{id}/camera/snapshot` with a long-lived camera token at 1–5 fps (matches the A1's cap). MJPEG `/camera/stream` via a native view is a later enhancement.
- **Navigation/screens:** see §5.
- **Known API gaps to design around:** no fan-speed endpoint, no raw-gcode passthrough, 24 h JWT with no refresh (use the API key for the app to avoid frequent re-login; admin mutations would need JWT).

### 4.6 Push relay (build, small)
- A tiny service on homeserver (FastAPI or Node, ~loopback/tailnet): stores the app's Expo push token (registered via an authenticated endpoint), receives **Bambuddy webhooks** on print-complete/failed/HMS events, and calls the **Expo Push API** → APNs, with a payload that deep-links to the relevant app screen.
- v1 events: print complete, print failed/stopped, HMS error (with severity).

---

## 5. App screens (v1)

| Screen | Contents | Primary Bambuddy endpoints |
|---|---|---|
| **Dashboard** | State badge; nozzle/bed temp + target; progress ring; layer x/y; ETA; camera snapshot; quick controls (pause/resume/stop, chamber light, print speed) | `GET /printers/{id}/status`, WS `/ws`; `POST .../print/{pause,resume,stop}`, `.../chamber-light`, `.../print-speed` |
| **Camera** | Full-screen refreshing snapshot; manual refresh | `GET /printers/{id}/camera/snapshot` (+token) |
| **Library** | Browse/upload `.stl`/`.3mf`/`.gcode.3mf` files + folders; launch the Print Wizard | `GET/POST /library/files`, `GET /library/folders` |
| **Print Wizard** (§5.1) | Pick **printer** → pick **filament/plastic + quality** → **slice** → **review on-device** (plate preview + est. time + filament used) → confirm **AMS plastic mapping** → print | `POST /library/files/{id}/slice`, `GET /slice-jobs/{id}`, `GET /archives/{id}/plate-preview`·`/thumbnail`·`/gcode`, `POST /queue/` (`ams_mapping`, `use_ams`) |
| **Queue** | Current + queued jobs; start/stop/cancel/reorder | `GET /queue/`, `POST /queue/{item}/{start,stop,cancel}`, `POST /queue/reorder` |
| **AMS** | 4 trays (type/color/remaining/active); load/unload | status `ams[]`; `POST .../ams/{load,unload}`, `.../slots/.../configure` |
| **Power** | Plug on/off; live watts; today's kWh; auto-off settings | Bambuddy smart-plug routes (HA-backed) |
| **Settings** | Bambuddy URL + API key; push prefs; onboarding/printer | `GET /auth/status`, `/auth/me` |

### 5.1 Print Wizard (slice → review → confirm → print)

The wizard is the core of the "bring a model in and print it" flow. Steps:

1. **Source** — a file from the Library (uploaded `.stl`/`.3mf`, or an already-sliced `.gcode.3mf`).
2. **Printer** — confirm/select the target printer (one A1 today; multi-printer ready).
3. **Filament / plastic + quality** — choose the filament profile (PLA / PETG / etc., from bundled A1 profiles) and a process/quality preset (e.g. 0.20 mm standard). v1 = a single filament.
4. **Slice** — `POST /library/files/{id}/slice` with the chosen profiles; poll `GET /slice-jobs/{id}`. (Skipped if the source is already a `.gcode.3mf`.)
5. **Review on iPhone** — show the **plate preview image** (`GET /archives/{id}/plate-preview`; fallback `/thumbnail`), **estimated print time** (`print_time_seconds`) and **filament used** (`filament_used_g` / `_mm`). Optionally embed Bambuddy's 3D G-code viewer (`/archives/{id}/gcode`) in a WebView for a richer preview. User can **confirm** or go back and re-slice with different settings.
6. **AMS plastic mapping** — show the model's required filament(s) alongside the current AMS trays (type/color/remaining from live status); let the user **confirm or adjust** which physical tray feeds the print (or external spool). The scheduler can auto-suggest a mapping; the user confirms it.
7. **Print** — enqueue via `POST /queue/` with `ams_mapping` + `use_ams`; the job appears on the Queue + Dashboard.

This gives the explicit **review-and-confirm gate** before any filament is spent, and makes printer + plastic + AMS-mapping selection an intentional step rather than a guess.

UI design will be produced via **Claude Design / the frontend-design skill** during the build: distinctive, glanceable, dark-mode-first.

---

## 6. Security & threat model

- **Trust boundary** = home LAN + tailnet. The phone is semi-trusted (could be lost/stolen).
- The app holds only a **revocable, scoped Bambuddy API key** in the iOS **Keychain** (`WhenUnlockedThisDeviceOnly`, biometric-gated). The **printer Access Code never leaves Bambuddy**; the phone never opens TLS to the self-signed printer.
- All access is over **Tailscale** (device identity, WireGuard). Bambuddy + slicer are **never** exposed on the public cloudflared tunnel. HTTPS via `tailscale serve` for ATS.
- Bambuddy auth is **enabled** (it ships off-by-default); a compromised key can be revoked and re-issued.

---

## 7. Build phases & acceptance criteria

### Phase 0 — Validation spike (GATE before app code)
Stand up Bambuddy + slicer on homeserver; add the A1. **Pass criteria:**
- Live telemetry (temps/progress/AMS) over WS; a control action (chamber light toggle) succeeds and reflects in status.
- Camera snapshot returns a valid JPEG.
- A known-good `.gcode.3mf` uploads via Bambuddy (FTPS) and **prints**.
- A simple test STL **slices** via the sidecar to a valid `.gcode.3mf`.
- Bambuddy **re-publishes** printer state to HA (entities appear); plug toggles via HA through Bambuddy.
- `ha-bambulab` direct connection disabled with **no telemetry flap** over a 30-min observation.
- Confirm fw `01.08.00.00` does not hit the old print-start bug (#1520).

### Phase 1 — App skeleton + Dashboard
- Expo app builds via EAS and installs through **TestFlight** on the owner's iPhone.
- Connects to Bambuddy over Tailscale (HTTPS), authenticates with the Keychain-stored API key.
- Dashboard shows **live** telemetry (WS) + camera snapshot; read-only.

### Phase 2 — Control + Power
- Pause/resume/stop, chamber light, print speed, AMS load/unload all work and reflect in status.
- Power screen toggles the plug and shows live watts + today's kWh.

### Phase 3 — Library + Print Wizard + queue
- Upload a file and run the **Print Wizard**: choose printer + filament/plastic + quality, slice a simple single-material STL, **review the sliced result on the iPhone** (plate preview + estimated print time + filament used), confirm the **AMS plastic mapping**, then print.
- An already-sliced `.gcode.3mf` skips slicing but still shows the review + mapping-confirm step before printing.
- Manage the queue (start/stop/cancel/reorder).

### Phase 4 — Native push + polish
- Push relay delivers print-complete/failed/HMS to the app (deep-linked).
- UI polished via Claude Design; error/edge cases handled (offline, sensor-unavailable, FTPS upload retry, slice failure).

### Deferred (v2)
MakerWorld import (China cookie path), multicolor/AMS slicing, true MJPEG live video, Live Activities/widgets, actionable push buttons.

---

## 8. Risks & mitigations

| Risk | Mitigation |
|---|---|
| A1 one-MQTT-client flap | Bambuddy is **sole** owner; `ha-bambulab` direct link disabled; verified in Phase 0 |
| Bambuddy pre-1.0, single maintainer | Pin version; couple loosely; keep the option to drop to a thin custom backend (bambulabs_api MIT) if it stalls |
| Slicer brittleness on complex models | v1 scoped to **simple single-material STL**; bundled A1 profiles; validate output (`Metadata/plate_1.gcode`, printer_model == A1) |
| Developer Mode could be narrowed by firmware | Monitor; control is empirically working on fw 01.08.00.00 today |
| FTPS upload to A1 flaky (large files) | Handle upload progress + retries/timeouts (A1 weak WiFi: raise FTP timeout) |
| Slicer = code-exec on uploads | Tailnet/loopback only; never public; Bambuddy auth on |
| China-account MakerWorld | Deferred; when added, manual cookie-token paste (Region=China) |

---

## 9. Open questions (to resolve during Phase 0 / build)
- Exact Bambuddy MQTT-republish entity set vs. the owner's current HA automations — confirm the existing HMS-resume automation can be re-pointed.
- Whether to keep any HA printer push, or move all printer push to the new app's relay.
- Reorder vs. simple list for the queue UI (decide with Claude Design).
- Slice-preview fidelity on iPhone: plate-preview image (cheap, confirmed via `/archives/{id}/plate-preview`) vs. embedding Bambuddy's 3D G-code viewer in a WebView (richer, heavier) — decide during the build.
- Confirm the headless Bambu Studio CLI reliably emits a plate-preview image for the A1 (thumbnails can be GUI-generated) — verify in Phase 0; fall back to the model thumbnail if absent.

---

## 10. Key references
- A1 LAN protocol: `Doridian/OpenBambuAPI` (mqtt.md, video.md, ftp.md).
- Backend: `maziggy/bambuddy` (FastAPI, slicer-api), `bambutools/bambulabs_api` (MIT fallback), `greghesp/ha-bambulab`.
- One-MQTT-client limit: ha-bambulab #174, BambuStudio #2404.
- Bambu Authorization Control System (2025): Bambu Lab blog; SimplyPrint LAN/Developer-mode note.
- Transport: Tailscale iOS VPN-on-demand; Cloudflare Access (secondary, unused for the app path).
