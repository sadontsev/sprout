# Sprout 🌱

A self-hosted iOS companion app for **Bambu Lab 3D printers** — born because the official
Bambu Handy app can't drive China-market units, and grown into a full-featured client that
outdoes it in a few places.

The app is a polished **Expo / React Native** client for a
[**Bambuddy**](https://github.com/maziggy/bambuddy) backend you run on your own server.
The printer never talks to a phone directly — everything flows through your box:

```
printer (MQTT/FTPS/RTSP)  ──►  Bambuddy (Docker, your server)  ──►  Sprout (iOS)
                                     │
                                     └──►  la-push (Docker)  ──►  APNs  ──►  lock screen
```

## Features

- **Dashboard** — live temps (dual-nozzle aware), progress, speed control, light, HMS
  notices, multi-printer fleet switcher; pure view-model (`present.ts`) drives everything.
- **Live Activities** — one lock-screen / Dynamic Island card *per printing machine*, kept
  updating after iOS suspends the app via APNs pushes from the bundled `la-push` service.
- **Push banners** — print finished, print failed, filament-drying finished.
- **Files** — Bambuddy library (upload, MakerWorld import, delete) *and* the printer's SD
  card: plate previews, download/share, delete, a 3D **layer viewer** (build plate, orbit,
  layer scrub), plus thumbnail grids with native playback for **timelapse** and **ipcam**
  recordings.
- **Jobs** — queue + print history with stats, cost, and reprint, in one timeline.
- **Hardware** — AMS trays with spool inventory, **filament drying** (recommended temp/time
  per filament, spool rotation, live cycle status), nozzle rack, maintenance reminders.
- **Power** — smart-plug control with live watts and per-print energy cost.
- **Camera** — MJPEG chamber stream with warm-up handling, honest failure states, and a
  live delivered-fps counter.
- **Print wizard** — pick file → filament/quality (with a working supports toggle) →
  server-side slicing → plate preview → AMS mapping → print.

## Repo layout

| path | what |
|---|---|
| `mobile/` | the Expo app (SDK 56 / RN 0.85). Built locally with Xcode — no EAS. |
| `deploy/bambuddy/` | docker-compose for Bambuddy + helper scripts (support-profile provisioning) |
| `deploy/slicer-api/` | Bambu Studio / OrcaSlicer slicing sidecars |
| `deploy/la-push/` | the Live-Activity / notification push service (FastAPI → APNs) |
| `docs/` | validated backend facts and design notes |
| `CLAUDE.md` | working notes for AI-assisted development — also the most complete build reference |

## Getting started

### 1. Backend (any Docker host on your LAN)

1. Deploy Bambuddy + the slicer sidecar: see [`deploy/README.md`](deploy/README.md).
2. Register your printer in Bambuddy's web UI (LAN IP + access code).
3. Enable auth and mint a **scoped API key** (`bb_…`) — this is what the app uses.
4. Reachability: LAN works as-is; for remote use put Bambuddy behind Tailscale or an
   HTTPS tunnel (iOS ATS requires HTTPS for non-LAN hosts).

### 2. Push service (optional — Live Activities + banners when the app is closed)

Full walkthrough: [**docs/guides/push-notifications.md**](docs/guides/push-notifications.md)
(APNs key, `la-push` deploy, sandbox-vs-production, token flow, troubleshooting).
The short version: create an APNs auth key, deploy `deploy/la-push/` with it, expose it at
a `lapush.` hostname next to your Bambuddy one.

Android status (spoiler: not yet): [docs/guides/android.md](docs/guides/android.md).

### 3. iOS app

Requirements: macOS with Xcode (the repo currently targets an iOS 27 device via the Xcode
beta — see `CLAUDE.md` for the exact recipe and its hard-won gotchas), an Apple Developer
team (free tier works for personal installs), Node 20+.

```bash
cd mobile
npm install
# regenerate the native project (only needed after native/config changes):
LANG=en_US.UTF-8 CI=1 npx expo prebuild --clean --platform ios
# build — substitute YOUR team id (and see CLAUDE.md for why these flags matter):
xcodebuild -workspace ios/Bambu.xcworkspace -scheme Bambu -configuration Release \
  -destination 'generic/platform=iOS' -allowProvisioningUpdates \
  DEVELOPMENT_TEAM=<YOUR_TEAM_ID> CODE_SIGN_STYLE=Automatic \
  ENABLE_USER_SCRIPT_SANDBOXING=NO build
```

Also set `ios.appleTeamId` in `mobile/app.json` (the Live Activity widget extension needs
it for automatic signing), and change the bundle identifier to one on your team.

Install on a device with `xcrun devicectl device install app …`, then onboard in-app:
**backend URL + API key** (stored in the iOS Keychain, this-device-only).

Checks before building: `npx tsc --noEmit` and `npm test` must be clean.

## Secrets

No credentials live in this repo — and the test suite uses synthetic fixtures only.
Real secrets (API key, printer access code, APNs `.p8`, admin password) belong on your
server, referenced via gitignored `.env` files and mounted paths. `.gitignore` already
excludes `.env*` (except `.env.example`), `*.p8`, and `*.key`.

## Status & credits

A personal project, built for one household's printers (currently a Bambu Lab H2C) and
distributed via local installs/TestFlight. It is not affiliated with Bambu Lab. Expect
sharp edges outside the tested paths — issues and PRs welcome if this becomes public.

Built on the excellent [Bambuddy](https://github.com/maziggy/bambuddy) (AGPL-3.0) by
maziggy — Sprout is an independent API client and ships none of Bambuddy's code.

**License: [MIT](LICENSE).**
