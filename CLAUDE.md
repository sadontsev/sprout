# CLAUDE.md

Guidance for Claude Code (claude.ai/code) working in this repository.

> **Placeholders, not values.** `<YOUR_TEAM_ID>`, `<your-server>`, `<deploy-dir>` and
> `*.example.com` stand in for your own. Nothing identifying is committed: the team id comes from
> `DEVELOPMENT_TEAM` (see `native/.env-local.example`), and secrets live on your server. The author's
> own hosts and paths are in `DEPLOYMENT.local.md`, which is gitignored — as is anything matching
> `*.local.md`. **This repo is public. Keep it that way.**

## What this is

An **iOS and macOS** app to control and monitor a Chinese-market Bambu Lab printer — currently an
**H2C** (dual-nozzle, 9 addressable AMS trays). The official Bambu Handy app can't drive these
units. It is a polished client of a **self-hosted Bambuddy backend** (FastAPI, ~548 endpoints).

**Distribution is TestFlight, to real testers.** This is not a single-user sideload, and the
difference matters: it rules out shortcuts the rest of this repo has deliberately not taken.
`canopy/` exists so **users need no Apple account of their own**; Trellis is "the service each USER
runs next to their own Bambuddy"; and there is a documented case for someone running a build signed
by **another team**, who cannot get push at all and for whom switching it off is correct. Treat
copy, empty states, failure messages and capability gating as things a stranger will read without
being able to ask what they meant.

There is no CI. Builds are local, through Xcode.

Monorepo layout:

- `native/` — **the app.** SwiftUI, iOS + macOS, one target. All new work lands here.
- `deploy/` — docker-compose for the Bambuddy backend + Bambu Studio / OrcaSlicer sidecars.
- `deploy/trellis/` — the push + MakerWorld service each USER runs next to their own Bambuddy.
- `canopy/` — the APNs relay the app AUTHOR hosts (Go). Holds the signing keys so users need no
  Apple account, verifies App Attest, binds each push token to one tenant.
- `docs/native-rewrite/` — reference for things that are **not** the app's own code: the backend's
  API surface, MakerWorld's measured behaviour, the printer's firmware refusals, the camera's frame
  rate, the Mac architecture.
- `docs/phase0-results.md` — validated backend facts (URLs, auth, preset names). No secrets.
- `archive/` — the retired Expo app (`archive/mobile/`) and the port specification
  (`archive/docs/`). **Not maintained.** Read `archive/README.md` before assuming anything there is
  current; several of its decisions are still load-bearing and that file says which.

## The app (`native/`)

```bash
# Every path here is REPO-ROOT relative. The `cd` is subshelled on purpose: unsubshelled it
# leaks into the rest of the block and then `native/Sprout.xcodeproj` resolves to
# native/native/… — which fails with a misleading "does not exist".
(cd native && xcodegen generate)   # project.yml is the source; Sprout.xcodeproj is GITIGNORED

DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer \
  xcodebuild -project native/Sprout.xcodeproj -scheme Sprout \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test          # ~994 tests, seconds

DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer \
  xcodebuild -project native/Sprout.xcodeproj -scheme Sprout \
  -destination 'platform=macOS,name=My Mac' CODE_SIGNING_ALLOWED=NO test  # ~1100 tests

./native/scripts-archive.sh                    # iOS: archive + export an .ipa, and stop
./native/scripts-archive.sh --macos            # …the Mac build instead (exports a .pkg)
./native/scripts-archive.sh --upload           # …then validate + upload to TestFlight
```

- **`Sprout.xcodeproj` is generated and gitignored.** Hand-editing it in Xcode does not survive.
  All project config lives in `native/project.yml`.
- Swift 6 with `SWIFT_STRICT_CONCURRENCY: complete`.
- **iOS runs fewer tests than macOS (994 vs ~1100) and that is correct** — the Live Activity and
  push suites are iOS-only because their subject is. A smaller macOS number is not a regression; a
  smaller *iOS* number is.
- **Bump `CURRENT_PROJECT_VERSION` only** — `MARKETING_VERSION` stays at 1.0.0. A build number,
  once accepted by App Store Connect, is spent forever.

### Swift and SwiftUI traps that cost real time here

- A property named `body` on a `View` collides with the protocol requirement. Call it `message`.
- Bare-slash regex literals may not begin or end with a space — write `\s`.
- **`PrintActivityAttributes.ContentState` field names are a wire format.** Trellis pushes that JSON
  over APNs, so renaming a property breaks remote Live Activity updates without breaking the build.
- `Text("…")` with a **string literal** is a `LocalizedStringKey`, so SwiftUI parses it as Markdown —
  and Markdown autolinks a bare URL. Use `Text(verbatim:)`. A `String` *variable* picks the
  non-Markdown overload, which is why the Settings fields never hit this.
- `.frame(maxHeight:)` **centres** its child by default. A greedy child (a `ScrollView`) keeps the
  frame at full height while the content shrinks, leaving a bottom sheet floating mid-screen. Pass
  `alignment: .bottom`.
- `.overlay { … }` content is **not** clipped to the base. A `.fill` image is flexible, so a
  `maxWidth/maxHeight` frame does not constrain it and a `clipShape` *inside* the overlay clips
  nothing — put the `clipShape` on the composite.
- The Keychain schema differs from `expo-secure-store`'s, so settings do **not** migrate from the
  archived app. The base URL and API key are re-entered once.

## `native/` is TWO destinations — iOS and macOS, one target

Not Catalyst, not "Designed for iPad". `Api/`, `Domain/`, `Config/`, `Realtime/` and `Theme.swift`
are shared; **only the view layer forks.** iOS views live where they always did, each wrapped in
`#if os(iOS)`; the Mac tree is `Sprout/Views/Mac/`. Density differs through `Metrics` (§8); the
**palette does not change**. Full architecture and the whole trap list:
`docs/native-rewrite/18-mac-port-architecture.md`.

Things here fail **silently** — they compile, run, and pass the suite:

- **`platformFilter: iOS`, never `platforms: [iOS]`, on the widget dependency.** The latter does not
  filter an embed, it deletes the embed phase on *every* platform: the iOS app then ships with no
  `PlugIns/` and no Live Activity. Verify the appex is PRESENT on iOS, not merely absent on macOS.
  Confirming the negative is not confirming the positive.
- **Stores are read off `AppModel`, never `@Environment`.** An unsatisfied `@Environment` object is a
  runtime trap, not a type error, so it survives a green suite until someone opens the screen.
- **Polling is started by whoever can see the section** — `.task` on iOS, `MacSectionContent` on
  macOS. `AppModel` has no `startStores()`, deliberately.
- **A store outliving its session must clear in `attach`.** "A refresh should not blank the list" and
  "this is a different server now" are different questions; conflating them let one library's
  multi-select delete ids reach a different Bambuddy.
- **A detached scene inherits nothing.** `WindowGroup`, `Settings` and `MenuBarExtra` get neither
  the palette nor the appearance from `MacRoot`, and `.environment(\.palette,…)` alone is only half
  of it — it retints what *Sprout* draws and not what **AppKit** draws. A scene missing
  `.preferredColorScheme` keeps the *system* appearance, so a dark-theme Sprout on a light Mac drew
  a white `Toggle` capsule and near-black label text on a near-black card. Found in one window,
  then in three more. Use `macSceneChrome(_:systemScheme:)`, which makes the three inseparable.
- **A window width may never write the stored inspector preference.** It did, twice, by two
  different authors of the same write: an `onChange` transition that saved `false` to `@AppStorage`
  and remembered the old value in `@State` (damage persisted, repair did not), and then SwiftUI's
  own `.inspector` writing `false` back through the binding as it hid itself. Either way one narrow
  window hid the inspector permanently, on every later launch, at every width. Both halves are pure
  rules on `MacInspectorPlacement` now, and tested.

### A macOS Debug build is a DIFFERENT APP from the one on TestFlight

`com.mvks5.bambu.dev`, called **Sprout Dev**, with an amber icon instead of the slate one. macOS
Debug only — iOS keeps the production id so APNs, App Attest and Live Activity testing are
untouched, and Release is unchanged on both platforms.

This is not cosmetic. Every build used to share one bundle id, so they shared one **preferences
domain**: running a local build to take a screenshot read and wrote the same `mac.section` and
inspector state as the installed TestFlight app. A probe run could leave the real app on a different
screen, and did. Spotlight also listed three identical "Sprout" entries with no way to tell them
apart.

- The dev build gets **no push** — APNs topics are bundle ids and Canopy binds `com.mvks5.bambu`.
- It starts with an **empty Keychain**, so the base URL and API key are entered once. That is the
  isolation working.
- `PRODUCT_NAME` is deliberately still `Sprout`, so every script and probe path in this repo —
  `Sprout.app/Contents/MacOS/Sprout` — keeps working.
- The overrides live in `project.yml` under `targets.Sprout.settings.configs.Debug`, as
  `[sdk=macosx*]` conditionals. **Put them under `settings:`, not after `preBuildScripts:`** — an
  unknown key there is dropped WITHOUT AN ERROR, same failure mode as the `macos:` key this file
  already warns about, and the build stays green while nothing changes.

### Seeing the Mac app — the probe, and its three blind spots

**You cannot inspect a Mac app from the shell.** `System Events` needs Accessibility and returns
`0 windows` for every app (including Finder) without it; `CGWindowList` needs Screen Recording. A
healthy app reports as having none.

`MacWindowProbe` (DEBUG only) is the way in, because an app needs no permission to look at itself:

```bash
SPROUT_DEMO=1 SPROUT_SECTION=jobs SPROUT_WINDOW_SIZE=1120x900 \
  SPROUT_SHOT=/tmp/shot SPROUT_SHOT_DELAY=9 \
  /path/to/Sprout.app/Contents/MacOS/Sprout
```

**`SPROUT_DEMO=1` is what makes this useful** — it starts the in-process fake server, so sections
actually render without a Bambuddy. Without it the app sits on onboarding and you photograph
nothing. Other knobs: `SPROUT_WINDOW_PROBE` (report windows), `SPROUT_TREE` (dump the AppKit
hierarchy), `SPROUT_INSPECTOR_LOG` (print `width|preference|visible` on every change).

What the screenshot **cannot** show you, each of which has already caused a wrong diagnosis:

1. **`NSVisualEffectView` does not render.** The sidebar and inspector come back as whatever was in
   the bitmap — a flat white block and leftover wallpaper. It looks exactly like a broken sidebar
   beside an empty inspector. `SPROUT_TREE` is what settles whether those panes are really there.
2. **The toolbar is not in the image at all.** `cacheDisplay` renders the `contentView`; the toolbar
   lives in the window frame above it, so every capture starts below it. Toolbar work needs a real
   screen.
3. **Focus-gated controls photograph as dimmed** unless the app is frontmost — `@FocusedValue` reads
   nil and `controlActiveState` is `.inactive`. The probe now calls `NSApp.activate` before
   measuring, because without it a live navigation link looks exactly like a dead one.

## MakerWorld is a PAGE, not a sheet

`Views/Explore/` — `ExploreView` (NavigationStack root: pinned search + chips + grid),
`ModelDetailView`, `VersionChooserView`, `VersionDetailView`, `VersionGallery`, `ImportReceiptSheet`.
The browse session lives in `Domain/ExploreModel.swift`, owned by `Shell` via the environment, so
leaving Explore and coming back returns to the same results, query and scroll — it was `@State` on a
view a `fullScreenCover` mounted, and died with it every time.

Three rules that keep being re-learnt:

- **Never blank the grid while loading.** `ExploreModel.startFetch` keeps the outgoing hits until
  the replacement lands; an empty scroll reads as slower than the request is.
- **Never drop input.** The old `guard !searching` meant tapping a category during a search did
  nothing at all. Cancel-and-replace, with `activeQuery`/`activeNav` as the write barrier.
- **`VersionGrouping` is where the honesty lives.** A model publishes up to 88 versions and ~58 % of
  them publish no time, weight or material at all. Unlabelled rows keep MakerWorld's order in a
  trailing group under every sort, the count says "7 of 88 match · 51 publish no settings", and a
  version you cannot print is greyed with the remedy rather than hidden. `Universal` is the absence
  of a material constraint, not a material.

Thumbnails go through `ThumbCache` (actor; NSCache for decoded images, URLCache for bytes,
in-flight coalescing). A bare `AsyncImage` in a grid re-fetches and re-decodes on every scroll back.

### Three network surfaces, deliberately kept apart

| what | who serves it | auth |
|---|---|---|
| resolve + import | Bambuddy (`/api/v1/makerworld/*`) | app's `X-API-Key`; *import* additionally needs the server signed in to Bambu Cloud |
| search + browse | `api.bambulab.com/v1/search-service` — **called straight from the app** | none, anonymous |
| the owner's collections | the owner's own **Trellis** (`/makerworld/collections`) | app's `X-API-Key`; Trellis reads Bambuddy's stored bearer |

**The app must never hold a Bambu Cloud bearer.** A phone is lost far more often than a home server,
and Bambu has been actively hostile to third-party cloud access. If `search-service` ever starts
requiring one, search is **removed**, not worked around.

Hard-won facts, all measured (`docs/native-rewrite/15-makerworld-design.md` has the probes):

- `search-service/search/design` works anonymously; `design-service/design/search` answers
  `200 {"total":0,"hits":null}` from anywhere. They sound like the same endpoint. They are not.
- **A `200` with an empty list from this API can mean "not authenticated".** `favorites/designs/{uid}`
  returns `total: 0` anonymously and `total: 30` with a token, for the same user. Never render "you
  have none" from one of these without checking the endpoint 401s when unauthenticated.
- `resolve` returns two overlapping profile lists. The `/instances` **hits are the row set** (a
  strict superset); `design.instances[]` is a metadata sidecar and the only place
  `prediction`/`weight`/`needAms`/`instanceFilaments` live. `defaultInstanceId` is an **instance id**,
  matching `hits[].id` — not a `profileId`.
- MakerWorld lists profiles it will not release a file for: 5 of 6 undescribed profiles on model
  40146 are refused, **including the one it pre-selects**. The refusal arrives as a **502** wrapping
  the upstream status, and through a tunnelling proxy even its `detail` is stripped — so that copy
  has to stand on its own words.
- An import is **never** sliced: `file_type` `3mf`, `/gcode` → 404 — while `print_time_seconds` *is*
  populated, which makes that field an unsafe proxy for "has toolpaths".
- **No ordering parameter is honoured on search.** `sort`, `order`, `orderby`, `orderBy`, `sortBy`,
  `sortType`, `sortField` and `rank` were each replayed: the returned counts come back unordered for
  every value, and a nonsense value shuffles the list exactly as much as a real one. So the sort
  control reorders **the loaded hits, client-side**, and the UI says so. The server's own order is
  labelled **"MakerWorld's order"**, never "Relevance". `isPrintable` is **absent** from hits and may
  not drive a control.

## `laPushUrl` vs `resolvePushUrl`

Two questions, two functions, and they must not be merged back:

- `resolvePushUrl` — *"should Live Activities be pushed through a server, and where?"* `nil` when the
  user turns push off.
- `laPushUrl` — *"where is Trellis?"* Ignores the toggle.

Trellis serves MakerWorld **collections** as well as push, and collections are plain authenticated
HTTP with no APNs involved. Gating them on the push toggle made switching push off silently remove
the Collections tab — the recurring bug, in a predicate that only *nearly* answered the question.

Not hypothetical: someone running a build signed by **another team** cannot get push at all (APNs
refuses a key that does not own the topic), so turning it off is the correct configuration for them
— and precisely when collections must keep working.

## Printing more than one filament

`ams_mapping` is **indexed by the 3MF's filament slot and valued by global tray id** — index 0
addresses slot 1. `Domain/AmsMapping.swift` owns the array and is the tested boundary; a plate whose
lone filament is slot 3 needs `[-1, -1, tray]`, and `usedSlotCount == 1` is *not* the same question
as "expressible as a one-element array".

Ask `filament-requirements` **per plate** (`?plate_id=`) for the exact `(file, plate)` pair that will
be enqueued — unfiltered it reports every slot in the file, and on a Sprout-sliced output the plate
ids other than the one sliced return stale data.

Slicing sends `filament_presets` plural, **compacted** to used slots in ascending order (measured),
falling back to singular `filament_preset` for one so the common path stays byte-identical to what is
proven against the server. Printing maps N slots through `AmsMapping.build`.

What still **cannot** be expressed is which NOZZLE runs which material: `nozzle_mapping` exists on the
queue item's `…Response`/`…Update` but not on `…Create`. Say that, rather than offering a control.

## The push relay (`canopy/`)

```bash
cd canopy && go build ./... && go vet ./... && go test ./...   # ~199 tests, seconds
./canopy/scripts-deploy.sh                                     # backs up, syncs, rebuilds, verifies
```

Go, SQLite, three dependencies **forever** (`modernc.org/sqlite`, `golang.org/x/time/rate`,
`github.com/fxamacker/cbor/v2`) — this process holds the APNs signing keys for every install, so its
supply chain is part of its threat model. `canopy/README.md` is the operator reference;
`docs/design/push-architecture.md` is the design.

**Deploy with the script, never a hand-rolled rsync.** `--delete` into `<deploy-dir>/canopy` will
remove `data/` (the bindings and attest keys) and `.env`, neither of which is in git. rsync anchors a
leading-slash exclude to the TRANSFER ROOT, so it is `/data`, not `/canopy/data` — written the wrong
way once, it deleted the live database, and recovery only worked because the container still held the
deleted inodes open under `/proc/<pid>/fd`.

Invariants that are load-bearing, each learnt expensively:

- **A binding may only carry the push types its kind owns** (`binding.Kind.Permits`). Canopy cannot
  tell a device token from a push-to-start token by value — only the claimant's `binding_kind` says
  which. Start tokens bind with no vouch because they cannot receive one, so without this gate an
  attacker declares a victim's DEVICE token to be a `start` token, binds it unvouched, and pushes an
  `alert` onto the victim's lock screen. Reproduced end to end.
- **Apple signs `SHA-256(nonce)`, not the nonce.** The assertion verifier and its fixture were both
  wrong in the same direction and agreed perfectly; only real hardware found it. Fixtures that share
  code with the parser cannot catch this class of bug.
- **Receipts are BER, not DER.** `encoding/asn1` refuses indefinite lengths, which every real Apple
  receipt uses, and the eContent is a segmented OCTET STRING.
- **A new DeviceCheck key does not work for up to 24 hours.** Until Apple propagates it, tokens
  signed by it are rejected *without being verified*, so a corrupted signature and a valid one fail
  identically. Use `validate_device_token` to tell propagation from misconfiguration.
- **The captured attestation fixture is gitignored.** Apple's leaf certificate carries
  `<TEAMID>.<bundle id>` in plaintext and this repo is public.

## Shipping

`scripts-archive.sh` does both platforms. Six things differ between them and **each fails at a
different stage**, which is why doing it by hand is how a platform ships with an unverified build
number: destination, the SDK the archive is checked against, whether there is a widget profile to
name, the artifact (`.ipa` vs `.pkg`), where the app keeps its `Info.plist` (`Contents/` on macOS),
and `altool -t`.

- **Use a RELEASE Xcode to archive — never a beta.** App Store Connect rejects the upload outright:
  *"Unsupported SDK or Xcode version"*. `Xcode-26.3.0.app` has a working platform;
  `/Applications/Xcode.app` (26.6) lists an iOS SDK whose *platform component* is not installed, so
  every destination is ineligible and you get `Found no destinations for the scheme`.
- **`** ARCHIVE FAILED **` can be a FALSE NEGATIVE**, and so can silence. Trust the artifact, not the
  exit code — the script checks the `.app` exists and reads the version back out of the exported
  `.ipa`/`.pkg` rather than from `project.yml`.
- **The ASC key must NOT be passed to the macOS export.** `-authenticationKey*` does not add an
  authority, it *selects* one: cloud signing then runs as the key, whose role cannot create the
  `Mac App Distribution` and `Mac Installer Distribution` certificates. Four errors, none naming the
  key. iOS keeps it, because that path signs manually and asks Apple for nothing.
- **Upload with `altool` + an App Store Connect API key, not Xcode's account.** The `.p8` keys live
  in `~/.appstoreconnect/private_keys/`; neither the key nor the issuer id is committed. Validate
  first — it catches an SDK rejection in seconds instead of after a ten-minute upload.
- Distribution needs the App ID enabled for **macOS** on the developer portal. Unsigned local builds
  are unaffected.

## The recurring bug in this codebase: offering what the backend will refuse

This shape has now appeared many times, in unrelated code, written by different hands:

| Where | The lie | What the user saw |
|---|---|---|
| LAN Developer Mode | Handlers were gated, buttons were not | Controls that looked live and silently did nothing |
| "View layers" | `isSliced` answered "was this prepared by a slicer?" when the question was "does this have toolpaths?" | HTTP 404 on a plain `.3mf` |
| Wizard filament | Identity recomputed from hex instead of read from inventory | A brown spool labelled "Orange" |
| Maintenance | `enabled ?? false` in the list vs `enabled != false` in the triage count | "1 thing needs you" over a pane showing nothing |
| Menu bar panel | `vm.kind == .live` answered "is a print running?", not "will the printer accept a pause?" | Pause/Stop live and silent in LAN mode |

The common cause is not carelessness — it is a **predicate that answers a NEARBY question**.
`isSliced` and `hasGcode` sound like synonyms and are not. "The user has permission" and "the printer
will accept it" sound like synonyms and are not.

**The rule: an affordance must be gated on the exact capability it needs, not on a proxy for it.**
When those are two different questions, write two predicates and name them for the questions they
answer. If you find yourself reusing one because it is "basically the same", that is the bug arriving.

**And when a capability is absent, say so in the UI.** A dimmed control with a padlock that explains
itself on tap beats a live-looking one; "Not in this build" beats a toggle that lies. The user should
never have to discover a limitation by hitting an error.

A sibling shape, found repeatedly during the Mac port: **the surface was built and nothing reaches
it.** A sheet whose `isPresented` is never set true, a predicate with zero call sites, a computed
property nothing reads, a `@FocusedValue` nobody publishes. Grep for the symbol before assuming a
control works.

## Bambuddy auth quirks

- Auth is the `X-API-Key` header. Secrets live on your server and are **never** committed.
- **Thumbnails and the camera are gated by a camera *stream* token in `?token=`, NOT `X-API-Key`**
  (you get 401 otherwise). Mint via `POST /printers/camera/stream-token`; the same token serves the
  MJPEG stream and all library/print-log thumbnails.
- **Settings writes and library file ops (rename/delete/move) are admin-only** — the scoped API key
  gets `403`. Reads work with the key.
- `PrintLogEntry.filament_color`/`filament_type` can be comma-joined multi-material strings; many
  cost/energy fields are `null` until data accrues.

## Testing

`native/` has the suite that matters: ~994 iOS and ~1100 macOS XCTest cases over `Sprout/Domain/`,
the API decoders and the Mac shell's pure rules, run with the `xcodebuild … test` lines above.
`canopy/` is `go test ./...` (~199 cases).

**`deploy/trellis/`** uses stdlib `unittest` (no pytest, deliberately, so it runs inside the
container) — but run it with **`./deploy/trellis/scripts-test.sh`**, not `python3 -m unittest
discover`. 13 of the 183 tests import the service's own `fastapi`/`httpx`, so the bare command SKIPS
twelve and ERRORS on one wherever those are not installed, which reads as a passing suite to anyone
not counting the skips. The twelve it skips are the only coverage `app.py` has. They are also **not
in the container image**, so running inside the container does not reach them either. The script
makes a venv and runs everything.

Both dependency guards key on **`ImportError` alone**, and the `import app` / `import makerworld`
lines sit *outside* the `try`. An earlier `except Exception:` around both turned "app.py is broken"
into twelve silent skips and a green run — a guard answering "did anything go wrong?" when the
question was "are the dependencies installed?". Same shape as the table above; keep them apart.
