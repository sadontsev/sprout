# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

> **Placeholders, not values.** `<YOUR_TEAM_ID>`, `<YOUR_DEVICE_UDID>`, `<your-server>`/
> `<your-server>` and `*.example.com` stand in for your own. Nothing identifying is committed:
> the team id comes from `DEVELOPMENT_TEAM` (see `native/.env-local.example`), and secrets live on
> your server. Start with [README.md](README.md) for setup.

A **personal iOS app** to control + monitor a Chinese-market Bambu Lab printer — currently an **H2C** (dual-nozzle, 9 addressable AMS trays); the codebase still carries A1-era notes where they were written. The official Bambu Handy app can't drive these units. It is a polished client of a **self-hosted Bambuddy backend** (FastAPI, ~548 endpoints). Distribution is **local/TestFlight for one user** — there is no CI, and both apps are **built locally with Xcode**, not EAS.

**There are two apps, same bundle id, shipped as separate TestFlight builds.** `mobile/` is the Expo SDK 56 / RN 0.85 original; `native/` is the SwiftUI reimplementation and is where new work lands. When a change could go in either, ask which is meant.

Monorepo layout:
- `mobile/` — the Expo app. Has its own `mobile/AGENTS.md`: **read the exact v56 docs at https://docs.expo.dev/versions/v56.0.0/ before writing Expo code** — SDK 56 APIs differ from older muscle memory.
- `native/` — a **native SwiftUI reimplementation** of the same app, built to be compared against the RN one. Same bundle id, so the two ship as different TestFlight builds of one app record. See `docs/native-rewrite/00-overview.md`.
- `deploy/` — docker-compose for the Bambuddy backend + Bambu Studio / OrcaSlicer sidecars (run on the home server `<your-server>`). See `deploy/README.md`.
- `docs/phase0-results.md` — validated backend facts (URLs, auth, A1 preset names). Secrets are **not** here.
- `docs/native-rewrite/` — the extracted behavioural specification of the RN app, one file per subsystem. It is the source of truth for the port and the reference for anything ambiguous in either app.

## The native app (`native/`)

```bash
# Every path here is REPO-ROOT relative. The `cd` is subshelled on purpose: unsubshelled it
# leaks into the rest of the block and then `native/Sprout.xcodeproj` resolves to
# native/native/… — which fails with a misleading "does not exist".
(cd native && xcodegen generate)   # project.yml is the source; Sprout.xcodeproj is GITIGNORED
DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer \
  xcodebuild -project native/Sprout.xcodeproj -scheme Sprout \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer \
  xcodebuild -project native/Sprout.xcodeproj -scheme Sprout \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test     # ~760 tests, seconds
./native/scripts-archive.sh            # archive + export an .ipa, and stop
./native/scripts-archive.sh --upload   # …then validate + upload to TestFlight
```

- **`Sprout.xcodeproj` is generated and gitignored** — the same discipline `mobile/ios` follows. Hand-editing it in Xcode does not survive. All project config lives in `native/project.yml`.
- Swift 6 with `SWIFT_STRICT_CONCURRENCY: complete`. The camera renderer needed real changes to pass it: its event payload became a typed `Sendable` enum, and the stream-URL provider a concrete error, because `[String: Any]` and `any Error` cannot cross the network→main hop.
- A property named `body` on a `View` collides with the protocol requirement. Two ported screens hit this; call it `message`.
- Bare-slash regex literals may not begin or end with a space — write `\s`.
- **`PrintActivityAttributes.ContentState` field names are a wire format.** la-push pushes that JSON over APNs, so renaming a property breaks remote Live Activity updates without breaking the build.
- The Keychain schema differs from `expo-secure-store`'s, so settings do **not** migrate between the two apps — the base URL and API key are re-entered once.
- `Text("…")` with a **string literal** is a `LocalizedStringKey`, so SwiftUI parses it as Markdown — and Markdown autolinks a bare URL. A placeholder containing one rendered as blue tappable link text with `foregroundStyle` ignored. Use `Text(verbatim:)`. A `String` *variable* picks the non-Markdown overload, which is why the Settings fields never hit this.
- `.frame(maxHeight:)` **centres** its child by default. A greedy child (a `ScrollView`) keeps the frame at full height while the content shrinks, leaving a bottom sheet floating mid-screen. Pass `alignment: .bottom`.
- `.overlay { … }` content is **not** clipped to the base. A `.fill` image is flexible, so a `maxWidth/maxHeight` frame does not constrain it and a `clipShape` *inside* the overlay clips nothing — put the `clipShape` on the composite. A fixed `.frame(width:height:)` does constrain, which is why the small thumbnails never showed it.

### MakerWorld — search, browse and collections are native-only; resolve + import exist in both apps

Three network surfaces, deliberately kept apart so one breaking cannot break the others:

| what | who serves it | auth |
|---|---|---|
| resolve + import | Bambuddy (`/api/v1/makerworld/*`) | app's `X-API-Key`; the *import* additionally needs the server signed in to Bambu Cloud |
| search + browse | `api.bambulab.com/v1/search-service` — **called straight from the app** (`MakerWorldSearchClient`) | none, anonymous |
| the owner's collections | the owner's own **la-push** (`/makerworld/collections`) | app's `X-API-Key`; la-push reads Bambuddy's stored Bambu Cloud bearer |

**The app must never hold a Bambu Cloud bearer.** A phone is lost far more often than a home server, and Bambu has been actively hostile to third-party cloud access. If `search-service` ever starts requiring one, search is **removed**, not worked around.

Hard-won facts, all measured (`docs/native-rewrite/15-makerworld-design.md` has the probes):

- `search-service/search/design` works anonymously; `design-service/design/search` answers `200 {"total":0,"hits":null}` from anywhere. They sound like the same endpoint. They are not.
- **A `200` with an empty list from this API can mean "not authenticated".** `favorites/designs/{uid}` returns `total: 0` anonymously and `total: 30` with a token, for the same user. Never render "you have none" from one of these without checking the endpoint 401s when unauthenticated.
- `resolve` returns two overlapping profile lists. The `/instances` **hits are the row set** (a strict superset); `design.instances[]` is a metadata sidecar and the only place `prediction`/`weight`/`needAms`/`instanceFilaments` live. `defaultInstanceId` is an **instance id**, matching `hits[].id` — not a `profileId`.
- MakerWorld lists profiles it will not release a file for: 5 of 6 undescribed profiles on model 40146 are refused, **including the one it pre-selects**. The refusal arrives as a **502** wrapping the upstream status, and through a tunnelling proxy even its `detail` is stripped — so that copy has to stand on its own words.
- An import is **never** sliced: `file_type` `3mf`, `/gcode` → 404, sliced for someone else's machine — while `print_time_seconds` *is* populated, which makes that field an unsafe proxy for "has toolpaths".
- **No ordering parameter is honoured on search.** `sort`, `order`, `orderby`, `orderBy`, `sortBy`, `sortType`, `sortField` and `rank` were each replayed against `search-service/search/design`: the returned `downloadCount`/`likeCount` sequences come back unordered for every value, and a nonsense value shuffles the list exactly as much as a real one (that shuffle is the endpoint's own instability — identical calls seconds apart differ). The route that DOES sort is the website's Next.js data endpoint, which is behind a Cloudflare challenge and needs a browser's `cf_clearance`. So the sort chips reorder **the loaded hits, client-side**, and the UI says so whenever more pages exist. `isPrintable` is **absent** from hits and may not drive a control at all.

### `laPushUrl` vs `resolvePushUrl`

Two questions, two functions, and they must not be merged back:

- `resolvePushUrl` — *"should Live Activities be pushed through a server, and where?"* `nil` when the
  user turns push off.
- `laPushUrl` — *"where is la-push?"* Ignores the toggle.

la-push serves MakerWorld **collections** as well as push, and collections are plain authenticated
HTTP with no APNs involved. Gating them on the push toggle made switching push off silently remove
the Collections tab — the recurring bug, in a predicate that only *nearly* answered the question.

This is not hypothetical: someone running a TestFlight build signed by **another team** cannot get
push at all (APNs refuses a key that does not own the topic), so turning it off is the correct
configuration for them — and precisely when collections must keep working.

### Printing more than one filament

`ams_mapping` is **indexed by the 3MF's filament slot and valued by global tray id** — index 0 addresses slot 1. `Domain/AmsMapping.swift` owns the array and is the tested boundary; a plate whose lone filament is slot 3 needs `[-1, -1, tray]`, and `usedSlotCount == 1` is *not* the same question as "expressible as a one-element array".

Ask `filament-requirements` **per plate** (`?plate_id=`) for the exact `(file, plate)` pair that will be enqueued — unfiltered it reports every slot in the file, and on a Sprout-sliced output the plate ids other than the one sliced return stale data. Slicing N filaments works today (`filament_presets` plural, **compacted** to used slots in ascending order — measured); the wizard's UI is still single-filament and refuses multi-material with a stated reason.

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
- `DEVELOPMENT_TEAM` (+ `ios.appleTeamId` in app.json) — `expo prebuild` does not write a team into the project; the app and the Live Activity widget extension both need it for automatic signing.
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
`native/ExportOptions.template.plist` is rendered to a temp file by `scripts-archive.sh` with your `DEVELOPMENT_TEAM` — xcodebuild does not expand variables inside an export plist, so it cannot be committed with the id in it. `method=app-store-connect`, `signingStyle=automatic`, `destination=export`.

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

## The recurring bug in this codebase: offering what the backend will refuse

This shape has now appeared four times, in unrelated code, written by different hands:

| Where | The lie | What the user saw |
|---|---|---|
| LAN Developer Mode | Handlers were gated, buttons were not | Controls that looked live and silently did nothing |
| Model texturizer | A settings toggle for a feature the native build lacks | A switch that changed nothing |
| "View layers" | `isSliced` answered "was this prepared by a slicer?" when the question was "does this have toolpaths?" | HTTP 404 on a plain `.3mf` |
| Wizard filament | Identity recomputed from hex instead of read from inventory | A brown spool labelled "Orange", green in Review |

The common cause is not carelessness — it is a **predicate that answers a NEARBY question**. `isSliced`
and `hasGcode` sound like synonyms and are not. "The user has permission" and "the printer will
accept it" sound like synonyms and are not. A vendor's colour name and a computed one sound like
synonyms and are not.

**The rule: an affordance must be gated on the exact capability it needs, not on a proxy for it.**
When those are two different questions, write two predicates and name them for the questions they
answer. If you find yourself reusing one because it is "basically the same", that is the bug
arriving.

**And when a capability is absent, say so in the UI.** A dimmed control with a padlock that explains
itself on tap beats a live-looking one; "Not in this build" beats a toggle that lies. The user should
never have to discover a limitation by hitting an error.

## Gotchas that will waste your time (all hard-won)

**Bambuddy auth quirks** (`bambuddyClient.ts` encodes these):
- Auth is the `X-API-Key` header. Secrets (key, admin password, printer access code) live on `<your-server>:<secrets-dir>/` and are **never** committed.
- **Thumbnails and the camera are gated by a camera *stream* token in `?token=`, NOT `X-API-Key`** (you get 401 otherwise). Mint via `POST /printers/camera/stream-token`; the same token serves the MJPEG stream and all library/print-log thumbnails.
- **Settings writes and library file ops (rename/delete/move) are admin-only** — the scoped API key gets `403`. Reads work with the key. (File ops need Bambuddy ≥ 0.2.4.8.)
- `PrintLogEntry.filament_color`/`filament_type` can be comma-joined multi-material strings; many cost/energy fields are `null` until data accrues.

**File upload**: the global `fetch` is Expo's WinterCG fetch, which **rejects React Native's `{uri,name,type}` FormData part** ("Unsupported FormDataPart implementation"). `uploadFile` therefore uses `expo-file-system`'s native `File.upload`, not `fetch`+`FormData`.

**Live Activity (`src/liveactivity/PrintActivity.tsx`)**: the component function carries a `'widget'` directive — `babel-preset-expo`'s widgets plugin **stringifies only that function's params+body and re-evaluates it in an isolated native runtime** where only `@expo/ui/swift-ui` primitives are injected. So the function **must be fully self-contained** (no module-scope constants/helpers — referencing one renders a blank/black activity). Text styling is via `modifiers={[font(...), foregroundStyle(...)]}` (Text has no `size`/`weight`/`color` props). A `uiImage` only respects `frame` when also marked `resizable()`. The widget runs in a separate process, so images must be written to the **App Group** container (`widgetsDirectory`) and passed as a `file://` URI.

## Testing

**`native/`** has its own suite — ~760 XCTest cases over `Sprout/Domain/` and the API decoders, run
with the `xcodebuild … test` line in the native section above. **`deploy/la-push/`** uses stdlib
`unittest` (no pytest, deliberately, so it runs inside the container): `python3 -m unittest discover
deploy/la-push`.

Everything below is about **`mobile/`**. `jest-expo`. Tests cover **pure logic** only — `present.ts` view-model, `bambuddyClient` URL/token builders, settings key sanitization, and the config-plugin transforms (`plugins/__tests__/`). Native modules (`expo-widgets`, `@expo/ui`, `react-native-webview`) are not imported by tests. `npx tsc --noEmit` is the main correctness gate before every build.
