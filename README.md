# Sprout 🌱

An **iOS and macOS** app for **Bambu Lab 3D printers** that you host yourself. Built because the
official Bambu Handy app can't drive China-market units, and grown into a fuller client than it.

Your printer talks to **your** server. Nothing about your prints, files or camera goes to anyone
else.

```
                      ┌──────── your server ────────┐   ┌── the author's ──┐
printer ──MQTT/FTPS──► Bambuddy ──► Trellis ─────────────► Canopy ──► APNs ──► lock screen
                          │                                  holds the signing keys
                          └──────► Sprout (iOS · macOS)
```

Only one piece is not yours: **Canopy**, which signs the push notifications. It holds Apple's
signing keys so you don't need an Apple developer account, and it never contacts your server —
it can't see your printer, your files or your camera. [Run your own](docs/guides/self-hosting-push.md)
if you'd rather.

## Install

[![Join the TestFlight beta](https://img.shields.io/badge/TestFlight-Join_the_beta-0D96F6?style=for-the-badge&logo=apple&logoColor=white)](https://testflight.apple.com/join/hPeRqT65)

Sprout ships through **TestFlight**. Nothing to buy, and no Apple developer account of your own —
Canopy exists so that push works without one. Open
**[the invite](https://testflight.apple.com/join/hPeRqT65)** on the device you want it on, install
Apple's TestFlight app if you don't already have it, and Sprout appears alongside it.

| | |
|---|---|
| **iPhone / iPad** | iOS 26 or later |
| **Mac** | macOS 26 or later — the same build, a real Mac app, not Catalyst |

**It needs a server before it can show you anything.** Your printer talks to
[Bambuddy](https://github.com/maziggy/bambuddy), which you run yourself on a NAS, a Pi or any spare
box. That is [step 1 below](#getting-started), and it is the longer half of the setup.

Joined to look around first? Open the app and pick **Try demo mode** on the onboarding screen. The
whole app runs against an in-process fake server — a print that advances, a filled library, AMS
trays — and it reaches no network at all. No printer, no server, nothing to configure.

> TestFlight builds expire after 90 days. If Sprout stops opening, the invite link above has the
> current one.

## What you need

**To use the app**, the TestFlight invite above and a printer — that's all. You need no Apple
developer account of your own: Canopy exists so that push works without one.

**To run the backend** (everyone needs this — the app is a client, not a bridge):

| | |
|---|---|
| A Bambu Lab printer | on your LAN |
| A machine that runs Docker | for [Bambuddy](https://github.com/maziggy/bambuddy) — a NAS, a Pi, any spare box |

**To build it yourself**, additionally a Mac with Xcode and a **paid** Apple Developer Program
membership — the Live Activity widget needs App Groups and Push Notifications, which a free
personal team cannot provision.

## Getting started

Three steps, in order. Each links to the detail.

**1. Run the backend** — [`deploy/README.md`](deploy/README.md)

Bambuddy talks to the printer and does the real work. Register your printer, then mint a scoped
API key (`bb_…`) — that key is what the app uses.

**2. Run Trellis, for push** — [`docs/guides/push-notifications.md`](docs/guides/push-notifications.md)

```bash
cp -r deploy/trellis <deploy-dir>/trellis && cd <deploy-dir>/trellis
cp .env.example .env        # BAMBUDDY_API_KEY is the only value you must set
docker compose up -d --build
```

That's the whole configuration. Trellis relays through Canopy by default, so there is no Apple
credential to obtain and no key to install. Without this step the app still works — lock-screen
cards just stop updating once you close it.

**3. Open the app** and enter your backend URL and API key. They are stored in the Keychain,
this-device-only. Or [build it yourself](#building).

## Features

- **Dashboard** — live temperatures (dual-nozzle aware), progress, speed, chamber light, HMS
  notices, and a switcher if you run more than one machine.
- **Live Activities** (iOS) — a lock-screen and Dynamic Island card per printing machine, kept
  current after iOS suspends the app.
- **Notifications** — print finished, print failed, filament drying finished.
- **Files** — your Bambuddy library and the printer's own SD card: plate previews, download,
  delete, and a 3D **layer viewer** you can orbit and scrub. Timelapse and IP-cam recordings play
  inline.
- **MakerWorld** — search and browse without signing in, open **your own collections**, pick a
  profile with its real print time, weight, filaments and licence, and land in the print wizard.
  Your Bambu Cloud login stays on your server; the phone never sees it.
- **Jobs** — queue and history in one timeline, with stats, cost and one-tap reprint.
- **Hardware** — AMS trays with spool inventory, **filament drying** with per-material temperature
  and time, nozzle rack, maintenance reminders.
- **Power** — smart-plug control with live watts and per-print energy cost.
- **Camera** — chamber stream with honest failure states and a real delivered-fps counter.

On the Mac it is a native three-column app — sidebar, content, inspector — with a menu bar extra,
its own camera window, Quick Look, Spotlight indexing and drag-and-drop. Not Catalyst: only the
view layer differs from iOS.

## Repo layout

| path | what |
|---|---|
| `native/` | **the app.** SwiftUI, iOS + macOS, one target. Xcode project generated by xcodegen from `project.yml`. |
| `deploy/bambuddy/` | compose for the Bambuddy backend |
| `deploy/slicer-api/` | Bambu Studio / OrcaSlicer slicing sidecars |
| `deploy/trellis/` | the push + MakerWorld service **you** run next to Bambuddy |
| `canopy/` | the APNs relay the **author** runs. Self-hostable — see the guide. |
| `docs/guides/` | setup, in the order you need it |
| `docs/design/` | how the push architecture works, and why |
| `docs/native-rewrite/` | reference: the backend's API surface, MakerWorld's measured behaviour, the Mac architecture |
| `archive/` | the retired Expo app and the port specification. Not maintained — see [`archive/README.md`](archive/README.md). |
| `CLAUDE.md` | notes for AI-assisted development, and the most complete build reference |

## Building

No Node, no prebuild. The Xcode project is generated from `native/project.yml` and is gitignored,
so hand-edits in Xcode do not survive — all project configuration lives in that file.

```bash
brew install xcodegen
cd native
cp .env-local.example .env-local      # set DEVELOPMENT_TEAM=<your Apple team id>; gitignored
set -a && . ./.env-local && set +a    # xcodegen reads it from the environment
xcodegen generate
```

Then build for whichever platform you want:

```bash
xcodebuild -project native/Sprout.xcodeproj -scheme Sprout \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
xcodebuild -project native/Sprout.xcodeproj -scheme Sprout \
  -destination 'platform=macOS,name=My Mac' CODE_SIGNING_ALLOWED=NO build
```

Tests — around 1100 on macOS and 990 on iOS, and they run in seconds:

```bash
xcodebuild -project native/Sprout.xcodeproj -scheme Sprout \
  -destination 'platform=macOS,name=My Mac' CODE_SIGNING_ALLOWED=NO test
```

The macOS suite is the larger of the two on purpose; the iOS-only difference is the Live Activity
and push suites, whose subject does not exist on the Mac.

To ship, `./native/scripts-archive.sh` archives and exports; add `--macos` for the Mac build and
`--upload` to send it to TestFlight. The bundle id lives in `native/project.yml`; your team id
never does.

Want to try it without a printer? Launch it and pick **Try demo mode** on the onboarding screen —
it runs the whole app against an in-process fake server, including a print that advances.

## Secrets

No credentials live in this repo, and the test suite uses synthetic fixtures only. Your Apple team
id is read from `DEVELOPMENT_TEAM` (`native/.env-local`, gitignored) rather than committed. Real
secrets (API key, printer access code, APNs `.p8`, admin password) belong on your server,
referenced via gitignored `.env` files and mounted paths. `.gitignore` already excludes `.env*`
(except `.env.example`), `*.p8`, `*.key` and `*.local.md`.

## Status & credits

A personal project, built for one household's printers (currently a Bambu Lab H2C) and distributed
through [TestFlight](https://testflight.apple.com/join/hPeRqT65). It is not affiliated with Bambu
Lab. Expect sharp edges outside the tested paths — issues and PRs welcome.

Built on the excellent [Bambuddy](https://github.com/maziggy/bambuddy) (AGPL-3.0) by maziggy —
Sprout is an independent API client and ships none of Bambuddy's code.

**License: [MIT](LICENSE).**
