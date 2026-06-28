# Phase 0 — Backend Bring-up & Validation Spike — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up the self-hosted backend (Bambuddy + Bambu Studio slicer sidecar) on `homeserver.local` as the sole LAN owner of the Bambu A1, reconcile it with the existing Home Assistant setup, expose it over Tailscale with HTTPS, and prove the full monitor → control → camera → slice → print → push-data path end-to-end **before any iOS app code is written.**

**Architecture:** One `bambuddy` Docker container (host networking) talks MQTT 8883 / FTPS 990 / camera 6000 directly to the A1, and re-publishes telemetry to Home Assistant's Mosquitto so HA keeps its printer entities. A `bambu-studio-api` sidecar provides headless slicing. `tailscale serve` fronts Bambuddy with HTTPS on the tailnet. The existing `ha-bambulab` direct connection is disabled so the A1 has exactly one LAN client.

**Tech Stack:** Docker / Docker Compose, Bambuddy (FastAPI), Bambu Studio CLI sidecar, Home Assistant REST/WebSocket API + Mosquitto MQTT, Tailscale, `curl`/`jq`/`openssl` for verification. All ops run from this laptop over SSH to `max@homeserver.local`.

## Global Constraints

- **Printer:** Bambu Lab A1, IP `192.168.1.20`, serial `REDACTEDSERIAL1`, firmware `01.08.00.00`, AMS Lite (4 trays). Must be in **LAN Mode + Developer Mode** (already effectively on — control + camera work today).
- **Host `homeserver.local`:** Linux **x86_64** (slicer images are linux/amd64-only — confirmed compatible), LAN `192.168.1.10`, Tailscale `100.100.100.100`. Docker present. SSH as `max@homeserver.local`.
- **Home Assistant:** HAOS VM `192.168.1.30:8123` (HA 2026.6.4), Mosquitto add-on `core_mosquitto` running, plug `switch.3d_printer_plug` (+ power sensors), existing integration `greghesp/ha-bambulab` is the current sole MQTT client and MUST be disabled (reversibly).
- **Slicer engine:** **Bambu Studio CLI** (`bambu-studio-api`, host port `3001`, Docker `bambu` profile). Set Bambuddy `preferred_slicer = bambu_studio`, slicer URL `http://localhost:3001`.
- **Transport:** Tailnet-only. Bambuddy + slicer are **NEVER** exposed on the public cloudflared tunnel. HTTPS via `tailscale serve`.
- **Secrets:** the printer **LAN Access Code lives only in Bambuddy**. `JWT_SECRET_KEY` set explicitly. Bambuddy auth **enabled**; a scoped API key is issued for the future app. No secret value is committed to git.
- **Bambuddy is pre-1.0, single-maintainer:** pin a specific released image tag; do not use `:latest` in the committed compose.

### Runtime variables (capture during execution; never commit their values)
- `ACCESS_CODE` — A1 LAN Access Code, read from the printer screen: *Settings → (gear) → Network/LAN → LAN Only / Access Code*. (Also recoverable from HA's `ha-bambulab` config entry.)
- `BAMBUDDY_TAG` — a specific Bambuddy release tag (pick the newest stable from https://github.com/maziggy/bambuddy/releases, e.g. `v0.2.4.7`).
- `SIDECAR_TAG` — a specific `bambu-studio-api` release tag (or `latest` pinned by digest).
- `HA_TOKEN` — an HA Long-Lived Access Token (create a fresh one in HA → profile → Long-Lived Access Tokens; used only for Phase-0 verification + plug checks).
- `GEM_TS_HOST` — homeserver's MagicDNS name from `tailscale status --json` (e.g. `homeserver-1.<tailnet>.ts.net`).
- `API_KEY` — the scoped Bambuddy API key minted in Task 7 (store in the laptop Keychain / a password manager; it goes into the app later).

---

## File Structure

Created in **this repo** (infra-as-code; the running copies live on homeserver):

- `deploy/bambuddy/docker-compose.yml` — pinned Bambuddy service (host net, volumes, env).
- `deploy/bambuddy/.env.example` — committed template of env keys (no secrets).
- `deploy/bambuddy/.env` — **gitignored**; real values (`BAMBUDDY_TAG`, `TZ`, `JWT_SECRET_KEY`, `SLICER_API_URL`).
- `deploy/slicer-api/docker-compose.yml` — pinned slicer sidecar (Bambu Studio + Orca).
- `deploy/slicer-api/.env.example` — committed template (`SIDECAR_TAG`, ports).
- `deploy/README.md` — how to deploy/update both stacks on homeserver.
- `docs/phase0-results.md` — the validated facts (endpoints, entity names, engine, API-key location) that feed the iOS-app plan. **This is the deliverable that gates Phase 1.**

`.env` files are already excluded by the repo `.gitignore` (`/.env`, `.env.*` except `.env.example`).

---

## Task 1: Pre-flight — confirm the A1 is reachable from homeserver and in Developer Mode

**Files:** none (verification only).

**Interfaces:**
- Produces: confirmation that MQTT 8883, FTPS 990, and camera 6000 are open on `192.168.1.20` from homeserver, and the working `ACCESS_CODE`.

- [ ] **Step 1: Read the LAN Access Code** from the printer screen (*Settings → Network → LAN Only*). Export it locally for the session:

```bash
read -rsp 'A1 LAN Access Code: ' ACCESS_CODE; echo; export ACCESS_CODE
```

- [ ] **Step 2: Verify the three local ports are open from homeserver**

Run:
```bash
ssh max@homeserver.local 'for p in 8883 990 6000; do nc -z -w3 192.168.1.20 $p && echo "OPEN $p" || echo "CLOSED $p"; done'
```
Expected: `OPEN 8883`, `OPEN 990`, `OPEN 6000`. If any are CLOSED, enable LAN Mode + Developer Mode (incl. "LAN Mode Liveview" for the camera) on the printer and re-run.

- [ ] **Step 3: Verify MQTT TLS + access code auth from homeserver** (read-only status subscribe; uses the access code, disables cert check for the self-signed printer cert):

Run:
```bash
ssh max@homeserver.local "docker run --rm eclipse-mosquitto:2 mosquitto_sub \
  -h 192.168.1.20 -p 8883 --insecure -u bblp -P '$ACCESS_CODE' \
  -t 'device/REDACTEDSERIAL1/report' -W 8 -C 1 2>&1 | head -c 400"
```
Expected: a JSON status payload (contains `\"print\"` or `\"info\"`/`\"nozzle_temper\"`). If it hangs/empties, the access code is wrong or another client is starving MQTT — proceed to Task 5 (disable ha-bambulab) and retry.

- [ ] **Step 4: Record the result** — note in scratch that 8883/990/6000 are open and MQTT auth works. No commit (verification task).

---

## Task 2: Author the slicer sidecar compose in the repo

**Files:**
- Create: `deploy/slicer-api/docker-compose.yml`
- Create: `deploy/slicer-api/.env.example`

**Interfaces:**
- Produces: a pinned slicer stack exposing `bambu-studio-api` on host `:3001` and `orca-slicer-api` on host `:3003`.

- [ ] **Step 1: Write the slicer compose**

`deploy/slicer-api/docker-compose.yml`:
```yaml
# Slicer sidecars for Bambuddy. Bambu Studio CLI is the default engine.
# Start both:  docker compose --profile bambu up -d
# linux/amd64 only (homeserver is x86_64 — OK).
services:
  orca-slicer-api:
    image: ghcr.io/maziggy/orca-slicer-api:${SIDECAR_TAG:-latest}
    container_name: orca-slicer-api
    restart: unless-stopped
    ports:
      - "${ORCA_API_PORT:-3003}:3000"
    volumes:
      - ./data/orca:/app/data
    environment:
      NODE_ENV: production
      PORT: "3000"
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:3000/health"]
      interval: 30s
      timeout: 5s
      start_period: 10s
      retries: 3

  bambu-studio-api:
    image: ghcr.io/maziggy/bambu-studio-api:${SIDECAR_TAG:-latest}
    container_name: bambu-studio-api
    restart: unless-stopped
    ports:
      - "${BAMBU_API_PORT:-3001}:3000"
    volumes:
      - ./data/bambu:/app/data
    environment:
      NODE_ENV: production
      PORT: "3000"
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:3000/health"]
      interval: 30s
      timeout: 5s
      start_period: 10s
      retries: 3
    profiles:
      - bambu
```

- [ ] **Step 2: Write the env template**

`deploy/slicer-api/.env.example`:
```dotenv
# Pin to a specific release; replace `latest` with a tag from
# https://github.com/maziggy/orca-slicer-api/releases
SIDECAR_TAG=latest
BAMBU_API_PORT=3001
ORCA_API_PORT=3003
```

- [ ] **Step 3: Commit**

```bash
cd /Users/max/ai-projects/bambu-app
git add deploy/slicer-api
git commit -m "deploy: add Bambu Studio / Orca slicer sidecar compose"
```

---

## Task 3: Author the Bambuddy compose in the repo

**Files:**
- Create: `deploy/bambuddy/docker-compose.yml`
- Create: `deploy/bambuddy/.env.example`

**Interfaces:**
- Consumes: the slicer at `http://localhost:3001` (Task 2).
- Produces: a pinned Bambuddy service on host `:8000` with a persistent data volume and an explicit JWT secret.

- [ ] **Step 1: Write the Bambuddy compose**

`deploy/bambuddy/docker-compose.yml`:
```yaml
# Bambuddy — sole LAN owner of the A1. Host networking for SSDP + camera.
services:
  bambuddy:
    image: ghcr.io/maziggy/bambuddy:${BAMBUDDY_TAG:?set BAMBUDDY_TAG in .env}
    container_name: bambuddy
    restart: unless-stopped
    network_mode: host
    volumes:
      - bambuddy_data:/app/data
    environment:
      - TZ=${TZ:-Europe/London}
      - PUID=${PUID:-1000}
      - PGID=${PGID:-1000}
      - PORT=${PORT:-8000}
      - JWT_SECRET_KEY=${JWT_SECRET_KEY:?set JWT_SECRET_KEY in .env}
      - SLICER_API_URL=${SLICER_API_URL:-http://localhost:3001}
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8000/health"]
      interval: 30s
      timeout: 5s
      start_period: 20s
      retries: 5

volumes:
  bambuddy_data:
```

- [ ] **Step 2: Write the env template**

`deploy/bambuddy/.env.example`:
```dotenv
# Pin a specific release tag from https://github.com/maziggy/bambuddy/releases
BAMBUDDY_TAG=v0.2.4.7
TZ=Europe/London
PORT=8000
PUID=1000
PGID=1000
# Generate once with: openssl rand -hex 32
JWT_SECRET_KEY=
# Bambu Studio CLI sidecar (Task 2)
SLICER_API_URL=http://localhost:3001
```

- [ ] **Step 3: Write the deploy README**

`deploy/README.md`:
```markdown
# Deploy (homeserver.local)

Both stacks run on homeserver via Docker Compose, copied to `~/docker/bambuddy/`
and `~/docker/slicer-api/`. Tailnet-only; never exposed via cloudflared.

## Slicer
    cd ~/docker/slicer-api && docker compose --profile bambu up -d

## Bambuddy
    cd ~/docker/bambuddy && docker compose up -d

After deploy: set `preferred_slicer = bambu_studio` and slicer URL
`http://localhost:3001` in Bambuddy Settings → Slicer. Front with
`tailscale serve --bg 8000`.

## Update
Bump `BAMBUDDY_TAG` / `SIDECAR_TAG` in `.env`, then `docker compose pull && up -d`.
```

- [ ] **Step 4: Commit**

```bash
cd /Users/max/ai-projects/bambu-app
git add deploy/bambuddy deploy/README.md
git commit -m "deploy: add pinned Bambuddy compose + deploy README"
```

---

## Task 4: Deploy the slicer sidecar on homeserver and verify it slices

**Files:** none in repo (deploys Task 2 files to homeserver).

**Interfaces:**
- Produces: a healthy `bambu-studio-api` on `homeserver:3001` that returns a `.gcode.3mf` for a test STL.

- [ ] **Step 1: Copy the slicer compose to homeserver and start it**

Run:
```bash
ssh max@homeserver.local 'mkdir -p ~/docker/slicer-api'
scp deploy/slicer-api/docker-compose.yml max@homeserver.local:~/docker/slicer-api/
scp deploy/slicer-api/.env.example max@homeserver.local:~/docker/slicer-api/.env
ssh max@homeserver.local 'cd ~/docker/slicer-api && docker compose --profile bambu up -d'
```

- [ ] **Step 2: Verify both sidecars are healthy**

Run:
```bash
ssh max@homeserver.local 'curl -fs http://localhost:3001/health && echo " <- bambu-studio OK"; curl -fs http://localhost:3003/health && echo " <- orca OK"'
```
Expected: a JSON health body from each + the `OK` echoes.

- [ ] **Step 3: Smoke-test a real slice** (download a public benchmark STL on homeserver, slice it via Bambu Studio with bundled A1 profiles):

Run:
```bash
ssh max@homeserver.local 'curl -fsSL -o /tmp/3dbenchy.stl https://raw.githubusercontent.com/CreativeTools/3DBenchy/master/Single_part_DABS/3DBenchy.stl && \
  curl -fs http://localhost:3001/profiles/bundled | jq -r ".[].name" | grep -i "A1" | head'
```
Expected: the STL downloads and the bundled-profile list contains A1 machine/process/filament entries (proves A1 profiles are present in the image).

- [ ] **Step 4: Record** the bundled A1 profile names (machine, a 0.20mm process, a PLA filament) into scratch for Task 9. No commit.

---

## Task 5: Disable the existing ha-bambulab connection (reversible) so the A1 has one LAN client

**Files:** none in repo (HA change on homeserver, reversible).

**Interfaces:**
- Consumes: HA at `192.168.1.30:8123`, `HA_TOKEN`.
- Produces: `ha-bambulab` config entry disabled; the A1 free for Bambuddy to own.

- [ ] **Step 1: Find the ha-bambulab config entry id**

Run:
```bash
export HA=http://192.168.1.30:8123
curl -fs "$HA/api/config/config_entries/entry" -H "Authorization: Bearer $HA_TOKEN" \
 | jq -r '.[] | select(.domain=="bambu_lab") | "\(.entry_id)\t\(.title)\t\(.state)"'
```
Expected: one row with the A1 entry id and `state: loaded`. Save the `entry_id` as `$BL_ENTRY`.

- [ ] **Step 2: Disable the config entry** (reversible — `disabled_by:user`, NOT delete):

Run:
```bash
curl -fs -X POST "$HA/api/config/config_entries/entry/$BL_ENTRY/disable" \
 -H "Authorization: Bearer $HA_TOKEN" -H 'Content-Type: application/json' \
 -d '{"disabled_by":"user"}'
```
Expected: `{"require_restart": ...}`. (To revert later: same endpoint with `{"disabled_by": null}`.)

- [ ] **Step 3: Verify the printer entities went unavailable** (confirms ha-bambulab released its MQTT connection):

Run:
```bash
curl -fs "$HA/api/states/sensor.a1_printer_print_status" -H "Authorization: Bearer $HA_TOKEN" | jq -r '.state'
```
Expected: `unavailable` (entity exists but the integration is no longer connected). HA will re-gain entities via Bambuddy's MQTT publish in Task 8.

---

## Task 6: Deploy Bambuddy on homeserver and register the A1 as its sole client

**Files:** none in repo (deploys Task 3 files to homeserver).

**Interfaces:**
- Consumes: slicer at `:3001` (Task 4); `ACCESS_CODE`; ha-bambulab disabled (Task 5).
- Produces: Bambuddy healthy on `homeserver:8000`, A1 registered, live telemetry flowing.

- [ ] **Step 1: Generate the JWT secret and write homeserver's `.env`**

Run:
```bash
ssh max@homeserver.local 'mkdir -p ~/docker/bambuddy'
scp deploy/bambuddy/docker-compose.yml max@homeserver.local:~/docker/bambuddy/
ssh max@homeserver.local 'cd ~/docker/bambuddy && \
  cp -n /dev/stdin .env <<EOF
BAMBUDDY_TAG=v0.2.4.7
TZ=Europe/London
PORT=8000
SLICER_API_URL=http://localhost:3001
JWT_SECRET_KEY=$(openssl rand -hex 32)
EOF
echo "wrote .env"'
```
(Confirm `BAMBUDDY_TAG` matches a real release; adjust if needed.)

- [ ] **Step 2: Start Bambuddy and verify health + OpenAPI**

Run:
```bash
ssh max@homeserver.local 'cd ~/docker/bambuddy && docker compose up -d && sleep 8 && \
  curl -fs http://localhost:8000/health && echo " <- health OK" && \
  curl -fs http://localhost:8000/openapi.json | jq -r ".info.title, .info.version"'
```
Expected: health OK + the OpenAPI title/version (proves the API + client-codegen source are live).

- [ ] **Step 3: First-run setup (enable auth, create admin)** — do this in the browser over SSH port-forward to keep it private:

Run (opens a local tunnel; then visit http://localhost:18000 and complete Settings → Authentication → enable + create the admin user):
```bash
ssh -N -L 18000:localhost:8000 max@homeserver.local &
echo "Open http://localhost:18000 — enable auth, create admin. Ctrl-C the tunnel when done."
```
Expected: auth enabled; admin login works. (Auth ships OFF by default — this turns it ON.)

- [ ] **Step 4: Register the A1** (over the same tunnel; obtain a JWT, then POST the printer). Replace `ADMIN_USER`/`ADMIN_PASS`:

Run:
```bash
TOK=$(curl -fs -X POST http://localhost:18000/api/v1/auth/login -H 'Content-Type: application/json' \
  -d '{"username":"ADMIN_USER","password":"ADMIN_PASS"}' | jq -r .access_token)
curl -fs -X POST http://localhost:18000/api/v1/printers/ -H "Authorization: Bearer $TOK" \
  -H 'Content-Type: application/json' \
  -d "{\"name\":\"A1\",\"serial_number\":\"REDACTEDSERIAL1\",\"ip_address\":\"192.168.1.20\",\"access_code\":\"$ACCESS_CODE\"}" \
 | jq -r '.id, .name'
```
Expected: a printer `id` (save as `$PID`, typically `1`) and name `A1`.

- [ ] **Step 5: Verify live telemetry**

Run:
```bash
curl -fs "http://localhost:18000/api/v1/printers/$PID/status" -H "Authorization: Bearer $TOK" \
 | jq '{state, progress, temperatures, layer_num, total_layers, ams: (.ams|length)}'
```
Expected: real values (state, temps with nozzle/bed, AMS array length ≥1). **This proves Bambuddy is the working sole MQTT owner.**

---

## Task 7: Mint the scoped API key + camera token for the future app

**Files:** none in repo (records key location into `docs/phase0-results.md` in Task 12; the secret itself is not committed).

**Interfaces:**
- Consumes: admin JWT (`$TOK`), `$PID`.
- Produces: `API_KEY` (scoped: read status + queue + control + manage library; not admin) and a long-lived camera token — both stored securely off-repo.

- [ ] **Step 1: Create the scoped API key**

Run:
```bash
curl -fs -X POST http://localhost:18000/api/v1/auth/api-keys -H "Authorization: Bearer $TOK" \
  -H 'Content-Type: application/json' \
  -d '{"name":"ios-app","can_read_status":true,"can_queue":true,"can_control_printer":true,"can_manage_library":true,"can_access_cloud":false}' \
 | tee /tmp/bb_key.json | jq -r '.key'
```
Expected: a `bb_...` key. **Copy it into the laptop Keychain / password manager now** (it's shown once). Export `API_KEY` for the next step.

> If the exact request body differs from this Bambuddy version's schema, read `GET /openapi.json` for the `/auth/api-keys` request model and adjust field names. Do not guess — use the schema.

- [ ] **Step 2: Verify the API key works for status (header auth, no cookies)**

Run:
```bash
curl -fs "http://localhost:18000/api/v1/printers/$PID/status" -H "X-API-Key: $API_KEY" | jq -r '.state'
```
Expected: the printer state — proves a headless client can drive the API with only the scoped key.

- [ ] **Step 3: Mint a long-lived camera stream token**

Run:
```bash
curl -fs -X POST http://localhost:18000/api/v1/printers/camera/stream-token -H "X-API-Key: $API_KEY" \
 | jq -r '.token' | tee /tmp/bb_cam_token.txt
```
Expected: a token string (save it; the app uses it for `?token=` on the snapshot/stream URLs).

---

## Task 8: Re-publish printer telemetry to Home Assistant via MQTT

**Files:** none in repo (Bambuddy + Mosquitto config on homeserver).

**Interfaces:**
- Consumes: HA Mosquitto on `192.168.1.30:1883`; Bambuddy admin session.
- Produces: HA re-gains printer entities (MQTT discovery) so existing dashboards/automations keep working.

- [ ] **Step 1: Create a Mosquitto login for Bambuddy** (edit the add-on options file on the HASS VM, then restart Mosquitto — pattern per HA infra notes):

Run (over HA SSH on port 22222, or via the VM console):
```bash
# Add a logins entry {username: bambuddy, password: <pw>} to:
#   /mnt/data/supervisor/addons/data/core_mosquitto/options.json
# then: ha addons restart core_mosquitto
```
Expected: Mosquitto restarts; `bambuddy` can authenticate. Record the password for Step 2.

- [ ] **Step 2: Configure Bambuddy's HA MQTT publishing** (Settings → Integrations/Home Assistant → MQTT publish): broker `192.168.1.30`, port `1883`, user `bambuddy`, the password from Step 1, Home Assistant discovery **on**, for printer `$PID`. Save.

- [ ] **Step 3: Verify HA discovered the re-published printer entities**

Run:
```bash
curl -fs "$HA/api/states" -H "Authorization: Bearer $HA_TOKEN" \
 | jq -r '.[].entity_id' | grep -iE 'bambuddy|a1' | head -20
```
Expected: a set of printer entities re-appears (under a `bambuddy`/MQTT-discovery name). Their state should be live (not `unavailable`). The owner's HA dashboards/automations can now be re-pointed to these if needed.

---

## Task 9: Verify control, camera, slice, and print end-to-end

**Files:** none in repo (verification against the live printer).

**Interfaces:**
- Consumes: `API_KEY`, `$PID`, camera token, bundled A1 profile names (Task 4).
- Produces: pass/fail evidence for each capability.

- [ ] **Step 1: Control — toggle the chamber light and confirm in status**

Run:
```bash
curl -fs -X POST "http://localhost:18000/api/v1/printers/$PID/chamber-light?on=true" -H "X-API-Key: $API_KEY"; sleep 2
curl -fs "http://localhost:18000/api/v1/printers/$PID/status" -H "X-API-Key: $API_KEY" | jq -r '.chamber_light'
```
Expected: the command returns success and `chamber_light` reflects `on` (observe the printer LED). Toggle back with `on=false`.

- [ ] **Step 2: Camera — fetch a snapshot JPEG**

Run:
```bash
curl -fs "http://localhost:18000/api/v1/printers/$PID/camera/snapshot?token=$(cat /tmp/bb_cam_token.txt)" -o /tmp/a1_snap.jpg
file /tmp/a1_snap.jpg
```
Expected: `/tmp/a1_snap.jpg: JPEG image data ...`.

- [ ] **Step 3: Slice the test STL via Bambu Studio and confirm preview + metadata**

Run (upload the benchy from Task 4 to the library, slice with the A1 profiles, poll the job):
```bash
# Upload
FID=$(curl -fs -X POST http://localhost:18000/api/v1/library/files -H "X-API-Key: $API_KEY" \
  -F "file=@/tmp/3dbenchy.stl" | jq -r '.id')   # if path differs, check /openapi.json
# Slice (use the A1 machine/process/filament names recorded in Task 4)
JOB=$(curl -fs -X POST "http://localhost:18000/api/v1/library/files/$FID/slice" -H "X-API-Key: $API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"printer_profile":"Bambu Lab A1 0.4 nozzle","process_profile":"0.20mm Standard @BBL A1","filament_profile":"Bambu PLA Basic @BBL A1"}' \
  | jq -r '.job_id')
# Poll
for i in $(seq 1 60); do S=$(curl -fs "http://localhost:18000/api/v1/slice-jobs/$JOB" -H "X-API-Key: $API_KEY"); \
  echo "$S" | jq -r '.status'; echo "$S" | grep -q '"status":"completed"' && break; sleep 5; done
echo "$S" | jq '{status, print_time_seconds, filament_used_g, archive_id}'
```
Expected: `status: completed` with a non-zero `print_time_seconds`, `filament_used_g`, and an `archive_id`. (Exact field/endpoint names: confirm against `/openapi.json` — `library`, `slice-jobs`, and `archives` routers — and adjust profile names to the bundled set from Task 4.)

- [ ] **Step 4: Confirm the slice preview image exists** (the app's review screen depends on this):

Run:
```bash
AID=$(echo "$S" | jq -r '.archive_id')
curl -fs "http://localhost:18000/api/v1/archives/$AID/plate-preview" -H "X-API-Key: $API_KEY" -o /tmp/a1_plate.png; file /tmp/a1_plate.png
```
Expected: `PNG image data` (or fall back to `/archives/$AID/thumbnail`). If neither returns an image headless, note it in `docs/phase0-results.md` — the app uses the model thumbnail or embedded G-code viewer instead.

- [ ] **Step 5: Print a known-good file (optional but recommended)** — enqueue the sliced archive to actually print (use a small calibration object; be physically present). Verify a job appears and starts:

Run:
```bash
curl -fs -X POST http://localhost:18000/api/v1/queue/ -H "X-API-Key: $API_KEY" -H 'Content-Type: application/json' \
  -d "{\"printer_id\":$PID,\"archive_id\":$AID,\"use_ams\":true,\"ams_mapping\":[0]}" | jq '{id,status}'
curl -fs "http://localhost:18000/api/v1/queue/" -H "X-API-Key: $API_KEY" | jq -r '.[0] | "\(.status)\t\(.file_name)"'
```
Expected: a queue item is created and the printer begins the job (confirms FTPS upload + MQTT print-start on fw 01.08.00.00 — clears the old #1520 print-start risk). Cancel afterward if it was only a test.

---

## Task 10: Expose Bambuddy over Tailscale with HTTPS

**Files:** none in repo (tailscale config on homeserver).

**Interfaces:**
- Produces: `https://$GEM_TS_HOST/` serving Bambuddy, reachable from the iPhone over the tailnet (satisfies iOS ATS).

- [ ] **Step 1: Get homeserver's MagicDNS name and enable HTTPS serve**

Run:
```bash
ssh max@homeserver.local 'tailscale status --json | jq -r ".Self.DNSName" && sudo tailscale serve --bg 8000'
```
Expected: the MagicDNS name (e.g. `homeserver-1.<tailnet>.ts.net.`) and serve confirms `https://<name>/ proxied to http://127.0.0.1:8000`. (Requires HTTPS enabled in the tailnet admin → Features → HTTPS Certificates.)

- [ ] **Step 2: Verify HTTPS from a tailnet device**

Run (from this laptop, on the tailnet):
```bash
curl -fs "https://${GEM_TS_HOST%.}/api/v1/printers" -H "X-API-Key: $API_KEY" | jq 'length'
```
Expected: the printer count (≥1) over HTTPS — the exact URL + key the app will use.

- [ ] **Step 3: Confirm it is NOT on the public cloudflared tunnel**

Run:
```bash
ssh max@homeserver.local 'docker inspect cloudflared 2>/dev/null | jq -r ".[0].Config.Env[]" 2>/dev/null | grep -i ingress || echo "checked: no bambuddy ingress"; echo "(verify the CF dashboard has no bambuddy hostname)"'
```
Expected: no Bambuddy hostname in cloudflared ingress. Bambuddy stays tailnet-only.

---

## Task 11: Stability soak — confirm no MQTT/telemetry flap

**Files:** none in repo.

**Interfaces:**
- Produces: evidence the single-owner setup is stable over time.

- [ ] **Step 1: Sample telemetry every 30s for 30 minutes**

Run:
```bash
ssh max@homeserver.local 'for i in $(seq 1 60); do \
  curl -fs http://localhost:8000/api/v1/printers/1/status -H "X-API-Key: '"$API_KEY"'" \
  | jq -r "\"\(now|floor)\t\(.connected)\t\(.state)\t\(.temperatures.nozzle)\""; sleep 30; done' | tee /tmp/soak.tsv
```
Expected: `connected` stays `true` and values update smoothly with no gaps/`null` runs (no flap). Investigate any `connected:false` rows.

- [ ] **Step 2: Confirm Bambuddy container didn't restart**

Run:
```bash
ssh max@homeserver.local 'docker inspect bambuddy --format "{{.RestartCount}} restarts; started {{.State.StartedAt}}"'
```
Expected: `0 restarts` since deploy.

---

## Task 12: Write the Phase-0 results doc (gate to Phase 1)

**Files:**
- Create: `docs/phase0-results.md`

**Interfaces:**
- Produces: the validated facts the iOS-app plan consumes.

- [ ] **Step 1: Write `docs/phase0-results.md`** capturing the verified reality (fill the bracketed values from the runs above):

```markdown
# Phase 0 Results (verified <DATE>)

- Bambuddy base URL (app): `https://<homeserver-magicdns>/` — tailnet only, HTTPS via `tailscale serve`.
- Auth: API key (`X-API-Key`) scoped read/queue/control/manage_library. **Stored in: <keychain/pw-manager item>** (NOT in git).
- Printer id: `<PID>`; serial `REDACTEDSERIAL1`; A1; fw 01.08.00.00.
- WebSocket: `wss://<homeserver-magicdns>/api/v1/ws` (mint ws-token via `/api/v1/auth/ws-token`).
- Camera: `GET /api/v1/printers/<PID>/camera/snapshot?token=<cam-token>` returns JPEG; long-lived cam token stored in <location>.
- Slicer: Bambu Studio CLI (`bambu-studio-api` :3001), `preferred_slicer=bambu_studio`. Verified A1 bundled profiles: machine `<...>`, process `<...>`, filament `<...>`.
- Slice result fields: `print_time_seconds`, `filament_used_g`, `filament_used_mm`, `archive_id`. Plate preview: `GET /api/v1/archives/<id>/plate-preview` → <PNG works | fell back to thumbnail/gcode-viewer>.
- Print start: `POST /api/v1/queue/` with `archive_id`,`use_ams`,`ams_mapping` — verified working on this firmware.
- HA reconciliation: `ha-bambulab` entry `<BL_ENTRY>` disabled (revert: POST .../disable `{"disabled_by":null}`); Bambuddy re-publishes to HA MQTT (entities: `<list>`). Plug `switch.3d_printer_plug` controllable via Bambuddy→HA.
- Stability: 30-min soak, 0 flaps, 0 container restarts.
- Confirmed endpoint/field names that differed from the spec's assumptions: `<list, or "none">`.
```

- [ ] **Step 2: Commit**

```bash
cd /Users/max/ai-projects/bambu-app
git add docs/phase0-results.md
git commit -m "docs: record Phase 0 validated backend facts"
```

---

## Self-Review

- **Spec coverage:** §4.1 Bambuddy deploy → Tasks 3,6; §4.2 slicer (Bambu Studio) → Tasks 2,4,9.3; §4.3 tailscale serve HTTPS → Task 10; §4.4 HA reconciliation (disable ha-bambulab, MQTT re-publish, plug) → Tasks 5,8; §4.1 auth + scoped key + camera token → Tasks 6.3,7; §5.1 Print Wizard data (slice metadata + plate-preview + ams_mapping) → Tasks 9.3–9.5; §6 security (tailnet-only, key off-repo, access code only in Bambuddy) → Tasks 7,10; Phase 0 acceptance criteria (spec §7) → Tasks 9 + 11. All Phase-0 spec items map to a task.
- **Deferred to later plans (correctly out of scope here):** the Expo app (Phases 1–4) and the push relay — each gets its own plan after this one passes.
- **Runtime variables vs. placeholders:** bracketed values (`$PID`, `<homeserver-magicdns>`, profile names) are runtime-discovered with explicit capture commands, not content gaps. Where Bambuddy's exact request schema may vary by version, the plan says to read `/openapi.json` and adjust — not to guess.
- **Consistency:** the slicer URL `http://localhost:3001`, `preferred_slicer=bambu_studio`, printer serial `REDACTEDSERIAL1`, and IP `192.168.1.20` are used identically across all tasks.
