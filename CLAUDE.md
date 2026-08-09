# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

> **Note for anyone who isn't the owner:** the device UDID `<YOUR_DEVICE_UDID>` and
> Apple team `<YOUR_TEAM_ID>` are the owner's; `homeserver`/`homeserver.local` and `*.example.com`
> stand in for whatever box/domains run your backend. Substitute your own device/team/hosts;
> the commands and gotchas transfer as-is. Start with [README.md](README.md) for setup.

A **personal iOS app** to control + monitor a Chinese-market **Bambu Lab A1** 3D printer (the official Bambu Handy app can't drive that unit). It's an **Expo SDK 56 / React Native 0.85** app (`mobile/`) that is a polished client of a **self-hosted Bambuddy backend** (FastAPI, ~505 endpoints). Distribution is **local/TestFlight for one user** — there is no CI, and the app is **built locally with Xcode**, not EAS.

Monorepo layout:
- `mobile/` — the Expo app. Has its own `mobile/AGENTS.md`: **read the exact v56 docs at https://docs.expo.dev/versions/v56.0.0/ before writing Expo code** — SDK 56 APIs differ from older muscle memory.
- `native/` — a **native SwiftUI reimplementation** of the same app, built to be compared against the RN one. Same bundle id, so the two ship as different TestFlight builds of one app record. See `docs/native-rewrite/00-overview.md`.
- `deploy/` — docker-compose for the Bambuddy backend + Bambu Studio / OrcaSlicer sidecars (run on the home server `homeserver.local`). See `deploy/README.md`.
- `docs/phase0-results.md` — validated backend facts (URLs, auth, A1 preset names). Secrets are **not** here.
- `docs/native-rewrite/` — the extracted behavioural specification of the RN app, one file per subsystem. It is the source of truth for the port and the reference for anything ambiguous in either app.

## The native app (`native/`)

```bash
cd native && xcodegen generate     # project.yml is the source; Sprout.xcodeproj is GITIGNORED
DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer \
  xcodebuild -project native/Sprout.xcodeproj -scheme Sprout \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
./native/scripts-archive.sh        # archive + export an .ipa for TestFlight
```

- **`Sprout.xcodeproj` is generated and gitignored** — the same discipline `mobile/ios` follows. Hand-editing it in Xcode does not survive. All project config lives in `native/project.yml`.
- Swift 6 with `SWIFT_STRICT_CONCURRENCY: complete`. The camera renderer needed real changes to pass it: its event payload became a typed `Sendable` enum, and the stream-URL provider a concrete error, because `[String: Any]` and `any Error` cannot cross the network→main hop.
- A property named `body` on a `View` collides with the protocol requirement. Two ported screens hit this; call it `message`.
- Bare-slash regex literals may not begin or end with a space — write `\s`.
- **`PrintActivityAttributes.ContentState` field names are a wire format.** la-push pushes that JSON over APNs, so renaming a property breaks remote Live Activity updates without breaking the build.
- The Keychain schema differs from `expo-secure-store`'s, so settings do **not** migrate between the two apps — the base URL and API key are re-entered once.

## Commands (run from `mobile/`)

```bash
npx tsc --noEmit          # type-check — MUST be clean before building
npm test                  # jest (jest-expo preset)
npx jest path/to.test.ts          # one test file
npx jest -t "substring of test name"   # one test by name
```

### Build + run on the physical device (the load-bearing recipe)

There is no `expo run:ios` here — builds go through `xcodebuild` against an Xcode 27 beta toolchain for iOS 27. **Run all of the following with the Bash sandbox disabled** (they touch the network and `~/Library/DerivedData`).

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer   # iOS 27 device support needs the beta
# Prebuild ONLY when app.json / a config plugin / a native dependency changed (regenerates ios/):
LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 CI=1 npx expo prebuild --clean --platform ios
# Build (JS-only changes need just this — the RN bundle phase re-bundles):
LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 xcodebuild \
  -workspace ios/Bambu.xcworkspace -scheme Bambu -configuration Release \
  -destination 'generic/platform=iOS' -allowProvisioningUpdates \
  DEVELOPMENT_TEAM=<YOUR_TEAM_ID> CODE_SIGN_STYLE=Automatic ENABLE_USER_SCRIPT_SANDBOXING=NO build
# Install + launch (DerivedData path: ~/Library/Developer/Xcode/DerivedData/Bambu-*/Build/Products/Release-iphoneos/Bambu.app):
xcrun devicectl device install app --device <YOUR_DEVICE_UDID> "<.../Bambu.app>"
xcrun devicectl device process launch --device <YOUR_DEVICE_UDID> --terminate-existing com.mvks5.bambu
```

Why each non-obvious flag/step matters (forgetting these costs build cycles):
- `-destination 'generic/platform=iOS'`, **never** `id=<UDID>` — with the UDID destination a LOCKED phone fails the build instantly at destination resolution ("needs to be unlocked to enable development services"), and piping to `tail`/`grep` hides it (pipeline exit is 0 while the `.app` stays stale). Verify with `grep "BUILD SUCCEEDED"` on the log, not the exit code.
- `DEVELOPER_DIR=…Xcode-beta…` — stable Xcode can't mount the iOS-27 developer disk image.
- `ENABLE_USER_SCRIPT_SANDBOXING=NO` — Xcode 27's script sandbox otherwise fails the "Bundle React Native code" phase with `EPERM unlink main.jsbundle` on rebuilds.
- `DEVELOPMENT_TEAM=<YOUR_TEAM_ID>` (+ `ios.appleTeamId` in app.json) — `expo prebuild` does not write a team into the project; the app and the Live Activity widget extension both need it for automatic signing.
- Diagnosing a launch crash: pull native crash reports over USB with `idevicecrashreport -e -k /tmp/x`; the crash time is in the **filename** (`Bambu-YYYY-MM-DD-HHMMSS.ips`), not the copy time. `idevicescreenshot` does **not** work on iOS 27.

### Archive + ship to TestFlight (a DIFFERENT toolchain from the device build)

```bash
export DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer   # RELEASE Xcode, NOT the beta
xcodebuild -workspace ios/Bambu.xcworkspace -scheme Bambu -configuration Release \
  -destination 'generic/platform=iOS' -archivePath /tmp/Bambu.xcarchive \
  -allowProvisioningUpdates DEVELOPMENT_TEAM=<YOUR_TEAM_ID> CODE_SIGN_STYLE=Automatic \
  ENABLE_USER_SCRIPT_SANDBOXING=NO archive
xcodebuild -exportArchive -archivePath /tmp/Bambu.xcarchive \
  -exportOptionsPlist ExportOptions.plist -exportPath /tmp/export -allowProvisioningUpdates
xcrun altool --upload-app -f /tmp/export/Bambu.ipa -t ios --apiKey <KEY_ID> --apiIssuer <ISSUER_ID>
```
ExportOptions.plist: `method=app-store-connect`, `teamID=<YOUR_TEAM_ID>`, `signingStyle=automatic`, `destination=export`.

- **Use a RELEASE Xcode to archive — never `Xcode-beta`.** App Store Connect rejects the upload outright: *"Unsupported SDK or Xcode version… you need to use the latest Release Candidates (RC)."* The beta is required ONLY for installing to a device on iOS 27 (developer disk image); it is the wrong toolchain for shipping. The two workflows genuinely need different `DEVELOPER_DIR` values.
- **`/Applications/Xcode.app` (26.6) does not work** — `xcodebuild -showsdks` lists iOS 26.5, but the iOS *platform component* is not installed, so every destination is ineligible (`iOS 26.5 is not installed… download from Xcode > Settings > Components`) and you get `Found no destinations for the scheme`. `Xcode-26.3.0.app` has a working platform. Check with `-showdestinations` before burning a build.
- **`** ARCHIVE FAILED **` can be a FALSE NEGATIVE.** The `expo-modules-jsi` xcframework script phase emits `error: the following command failed with exit code 0 but produced no further output` from its nested `-quiet` xcodebuild. Running that script standalone succeeds and prints the same line, so it is noise — but xcodebuild counts it and fails the action. If it appears, check whether the `.xcarchive` actually exists and contains `Products/Applications/Bambu.app` + `ExpoWidgetsTarget.appex`; if it does, export it. (Same lesson as the device build: trust the artifact, not the exit code.)
- **Upload with `altool` + an App Store Connect API key, not Xcode's account.** `-exportArchive` with `destination=upload` fails `Failed to Use Accounts` / *"Failed to find an account with App Store Connect access for team <YOUR_TEAM_ID>"* — the Apple ID signed into Xcode has Developer-portal access (enough to regenerate profiles) but not ASC. The `.p8` keys live in `~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8`; the issuer UUID is in App Store Connect → Users and Access → Integrations. **Neither is committed** — ask the owner. Validate first with `--validate-app`; it catches the SDK rejection in seconds instead of after a 10-minute upload.
- **Bump `ios.buildNumber` only — leave `version` alone.** `runtimeVersion` is `{"policy": "appVersion"}`, so changing `version` changes the runtime version and **orphans every published OTA update**, which would strand the app on whatever JS shipped in the binary.
- Signing into Xcode (Settings → Accounts) is required for `-allowProvisioningUpdates` to add a NEW capability to the App ID — without an account it fails `No Accounts` and `Provisioning profile … doesn't include the <X> entitlement`.
- `altool` uploads exceed a 10-minute tool timeout; run it in the background and poll the log for `UPLOAD SUCCEEDED`.

## Critical constraint: `ios/` and `android/` are gitignored

`mobile/ios` is **git-ignored and regenerated by `expo prebuild`**. Never hand-edit anything under `ios/` expecting it to last — a clean prebuild wipes it. **All native changes must be durable config:**
- An Expo **config plugin** in `mobile/plugins/` (each is a pure, unit-tested transform + a thin `with*` wrapper), wired in `app.json`:
  - `withIosSceneLifecycle.js` — adds a `SceneDelegate` so the app adopts the iOS 27 UIScene lifecycle (without it the app white-screens then traps on launch).
  - `withIosPodMinDeploymentTarget.js` — force-bumps every Pod target to iOS 16.4 (Xcode 27 rejects pods below 15.0; `expo-build-properties` sets the baseline but doesn't override podspec-pinned lower targets).
- **patch-package** (`patches/`, applied via the `postinstall` script) — e.g. the expo-modules-jsi Swift-6 fix.
- App-level config in `app.json` (e.g. `ios.infoPlist`, the file-association document types, the `expo-widgets` plugin).

When you change a config plugin, verify it end-to-end with `expo prebuild --clean` + a build — not just by reading it.

## Architecture (the big picture)

Data flows **printer → Bambuddy → `BambuddyClient` → `usePrinterStatus` → `presentDashboard` (DashVM) → views/Live Activity**.

- `src/api/bambuddyClient.ts` — a thin, typed, **React-free** wrapper over every Bambuddy endpoint the app uses (status/control, library, slicing, queue, AMS, plug, history, inventory, maintenance, MakerWorld, camera). **All network goes through here.** `src/api/types.ts` holds the response shapes.
- `src/realtime/usePrinterStatus.ts` — live status via a WebSocket (token from `POST /auth/ws-token`) with a REST-poll fallback. `useCameraStream.ts` (MJPEG token lifecycle), `useLiveActivity.ts`.
- `src/dashboard/present.ts` — `presentDashboard(status) → DashVM`, a **pure** view-model that is the single source of print-state classification (`kind: connecting | offline | idle | live | complete | error`, labels, colors, progress). **Reuse `DashVM`; do not re-derive state from `status.state`.** This is the most-tested module.
- `src/app/` — expo-router routes. `index.tsx` is the `Shell`: config gate → constructs `BambuddyClient` → `usePrinterStatus` → renders the active tab + overlays. `settings.tsx` is onboarding (base URL + API key → Keychain).
- `src/components/` — `DashboardView`, `TabBar` (6 tabs), `TabScreens` (Library / Queue / AMS+Maintenance / Power+energy / History), `Overlays` (fullscreen Camera, Upload+MakerWorld sheet, the multi-step Print Wizard), `NozzleIcon` (brand SVG glyph).
- `src/config/secureConfig.ts` — Keychain storage (base URL, API key, camera token) via expo-secure-store.
- `src/liveactivity/` — the iOS Live Activity (lock screen + Dynamic Island) via **`expo-widgets`** (first-party SDK 56). See the gotcha below.

## Gotchas that will waste your time (all hard-won)

**Bambuddy auth quirks** (`bambuddyClient.ts` encodes these):
- Auth is the `X-API-Key` header. Secrets (key, admin password, printer access code) live on `homeserver:~/.config/bambu-phase0/` and are **never** committed.
- **Thumbnails and the camera are gated by a camera *stream* token in `?token=`, NOT `X-API-Key`** (you get 401 otherwise). Mint via `POST /printers/camera/stream-token`; the same token serves the MJPEG stream and all library/print-log thumbnails.
- **Settings writes and library file ops (rename/delete/move) are admin-only** — the scoped API key gets `403`. Reads work with the key. (File ops need Bambuddy ≥ 0.2.4.8.)
- `PrintLogEntry.filament_color`/`filament_type` can be comma-joined multi-material strings; many cost/energy fields are `null` until data accrues.

**File upload**: the global `fetch` is Expo's WinterCG fetch, which **rejects React Native's `{uri,name,type}` FormData part** ("Unsupported FormDataPart implementation"). `uploadFile` therefore uses `expo-file-system`'s native `File.upload`, not `fetch`+`FormData`.

**Live Activity (`src/liveactivity/PrintActivity.tsx`)**: the component function carries a `'widget'` directive — `babel-preset-expo`'s widgets plugin **stringifies only that function's params+body and re-evaluates it in an isolated native runtime** where only `@expo/ui/swift-ui` primitives are injected. So the function **must be fully self-contained** (no module-scope constants/helpers — referencing one renders a blank/black activity). Text styling is via `modifiers={[font(...), foregroundStyle(...)]}` (Text has no `size`/`weight`/`color` props). A `uiImage` only respects `frame` when also marked `resizable()`. The widget runs in a separate process, so images must be written to the **App Group** container (`widgetsDirectory`) and passed as a `file://` URI.

## Testing

`jest-expo`. Tests cover **pure logic** only — `present.ts` view-model, `bambuddyClient` URL/token builders, settings key sanitization, and the config-plugin transforms (`plugins/__tests__/`). Native modules (`expo-widgets`, `@expo/ui`, `react-native-webview`) are not imported by tests. `npx tsc --noEmit` is the main correctness gate before every build.
