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

The APP has no CI — its builds are local, through Xcode. **Trellis does**: tagging `trellis-v*`
publishes a multi-arch image (see Releasing Trellis).

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
- The **bundle** is `Sprout Dev.app`, because Spotlight labels an app from `kMDItemFSName` — the
  filename — and ignores `CFBundleDisplayName`. Renaming the display name alone produced a plist
  reading "Sprout Dev" under a Spotlight tile still saying "Sprout"; `mdls` is what settled it.
- The **executable** is still `Sprout`, via a separate `EXECUTABLE_NAME` override. So a Debug probe
  run is `"…/Debug/Sprout Dev.app/Contents/MacOS/Sprout"` — new wrapper, same binary, and the quotes
  matter now that the path has a space.

**`PRODUCT_NAME` drives THREE things, and renaming it broke two of them in turn.** Each failure was
loud, but only because the suite was run; none of them shows up in a plain `build`:

1. the bundle wrapper — the point of the exercise;
2. the **executable**, so `SproutTests`' `TEST_HOST` stopped resolving — *"Could not find test host"*.
   Both that setting and `PRODUCT_NAME` now read one project-level `SPROUT_MAC_APP`, so the two
   cannot drift again;
3. the **Swift module name**, which quietly became `Sprout_Dev` and failed all 1,293 tests on
   `@testable import Sprout`. `PRODUCT_MODULE_NAME` is pinned to `Sprout` for that reason — a module
   is an identifier in source, and must never follow a user-facing name.
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
  "/path/to/Sprout Dev.app/Contents/MacOS/Sprout"   # Debug; Release is still Sprout.app
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

## Releasing Trellis (`deploy/trellis/`)

Trellis is the one component every USER deploys, so it ships as a prebuilt image rather than a
`build: .` that makes every NAS and Pi compile a three-package Python service.

```bash
git tag trellis-v1.2.3 && git push origin trellis-v1.2.3   # that is the whole release
```

`.github/workflows/trellis-release.yml` then runs the suite, builds `linux/amd64` + `linux/arm64`,
publishes to `ghcr.io/sadontsev/sprout/trellis`, and opens a GitHub Release whose notes are the
commits touching `deploy/trellis/` since the previous `trellis-v*` tag.

- **The tag is PREFIXED** because this repo also holds the app and Canopy. A bare `v1.2.3` would not
  say what was released.
- **Five image tags per release**: `1.2.3`, `1.2`, `1`, `latest`, `sha-<short>`. The bare major is
  not decoration — `TRELLIS_TAG=1` is what makes the Watchtower overlay safe, because Watchtower
  re-pulls whatever tag the container was STARTED with and `latest` would deliver a major
  unattended.
- **armv7 is deliberately absent.** `uvicorn[standard]` pulls `uvloop`/`httptools`, which have no
  32-bit wheels, so every release would compile C extensions under QEMU.
- **Compose is three files, overlay-style**, matching what `docker-compose.collections.yml` already
  established: base pulls the image, `docker-compose.build.yml` builds locally, and
  `docker-compose.watchtower.yml` is opt-in *because it needs the Docker socket*, which is root on
  the host. Never present Watchtower as the default path.

### A green run proved nothing, and that is why the guards exist

The first release published **no version tags at all** and still went green.
`docker/metadata-action` was handed the git tag whole; `trellis-v1.0.0` is not semver, so it emitted
a *warning* and then produced nothing — while the release notes it generated advertised `:1.0.0`,
and `TRELLIS_TAG=1` pointed at a tag that had never existed.

Two guards now stand between that and a user:

1. **Before the build** — assert `steps.meta.outputs.tags` actually contains the version, the bare
   major, and `latest`. The failure was in metadata output, so that is where it is checked.
2. **After the push** — fetch each of those manifests from GHCR **anonymously**, the way a user
   without credentials does. A tag that never landed and a package that is private are
   indistinguishable in the run log, and identical from the user's side: `denied`.

Same shape as everything else in this file: the exit code answered a nearby question ("did the
step run?") rather than the real one ("can a user pull what the notes promise?").

### GHCR visibility

The package came out publicly pullable on first publish — Actions into a public repo, permissions
inherited. GitHub's docs say packages default to private, so **check rather than assume** in either
direction; the post-push guard is what actually settles it.

## Linting

```bash
./native/scripts-lint.sh                     # what this branch changed
./native/scripts-lint.sh path/to/File.swift  # …or named files
```

There is no SwiftLint and no CI. The script wraps the `swift-format` that ships in the Xcode
toolchain, with `.swift-format` at the repo root set to the house style (4-space indent, 110
columns).

**It reports SEMANTIC rules only, and that filter is deliberate.** swift-format's pretty-printer
re-indents SwiftUI modifier chains to its own model, so an unfiltered run emits **~25 000
`[Indentation]` warnings** against a style this project never adopted — the tool disagreeing with
the codebase, not defects. `Indentation`, `AddLines`, `LineLength`, `Spacing`, `RemoveLine` and
`TrailingWhitespace` are therefore filtered out. Do not "fix" them: accepting them means
reformatting every file in the repo.

What survives the filter is worth reading — `ValidateDocumentationComments` catches a doc comment
whose parameters no longer match the function, which is the kind of rot this codebase's comments
are load-bearing against.

## Apple platform rules: check, never recall

**Do not guess at platform behaviour, and do not answer from memory.** Every layout
bug in the Live Activity was a confident guess: `.fixedSize` where the API has
`DynamicIslandExpandedRegion(_:priority:)`, `lineLimit(1)` believed to cap width
when it caps lines, `.frame(maxWidth:)` believed to stop a squeeze, a 22pt ring
dropped into a 17pt compact slot and clipped against the sensor cutout. Each one
shipped, was seen on a real phone, and cost a build.

Two sources, both local, both authoritative:

| what | where |
|---|---|
| Human Interface Guidelines, 120 pages, plain text | `~/.claude/reference/apple-hig/` |
| This project's distilled Live Activity notes and traps | `~/.claude/reference/live-activity-dynamic-island.md` |

For API facts — signatures, defaults, what a parameter is actually for — read the
SDK, not the web:

```bash
SDK=/Applications/Xcode-26.3.0.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk
find "$SDK/System/Library/Frameworks/WidgetKit.framework" -name "*.swiftinterface"
```

**`developer.apple.com` is JS-rendered and returns an EMPTY SHELL to any fetch.**
A summary of a page fetched that way is invented. If the corpus above is missing a
page, refresh it from the JSON backend that actually serves content:

```bash
curl -sL https://developer.apple.com/tutorials/data/design/human-interface-guidelines/live-activities.json
curl -sL https://developer.apple.com/tutorials/data/documentation/activitykit.json
```

Before changing any platform-surface layout — Live Activity, widget, menu bar,
toolbar, sidebar — read the relevant page first and cite it in the code comment or
the commit. "It looked right in the screenshot" is not verification: **Live
Activities do not start in the iOS Simulator at all**, so island and lock-screen
work can only be confirmed on a device.

### A Live Activity dies at EIGHT HOURS, and its corpse stays on screen

The HIG is explicit — Live Activities "work best for tracking short to medium
duration activities that don't exceed eight hours", and once ended a card
"remains for up to four hours" on the Lock Screen. Both halves matter, and the
second is the one that bites: at eight hours iOS ends the activity and its push
token starts answering APNs **410**, while the card stays visible, frozen at
whatever it last showed. Measured on the live H2C: registered 22:49:15, `410` at
06:49:52 — 8h 00m 37s. A ten-hour print therefore ALWAYS produced two cards.

**A 410 means "this service can no longer drive that card", NOT "the card is
gone".** Trellis re-arms push-to-start and pushes a replacement, which is right —
a long print still needs a live card — but it cannot remove the frozen one,
because the only push that would end it travels through the token that just died.
**The app clears it**, via `LiveActivityController.supersededCardIds`: ending is a
local call and works with a dead token.

The predicate there is **superseded**, not "ended". A card that ends with nothing
to replace it is a finished print, and lingering is the whole point of those four
hours; ending on `.ended` alone snatches every completed print off the Lock
Screen the moment it finishes. A test exists solely to prove that case does not
fire.

Trellis's log for this used to read "its last card is gone". It was not gone, and
that one sentence sent two separate investigations to the wrong place — the same
nearby-question shape as the table below, in a log message rather than a
predicate. **A log line is an assertion; make it one you can defend.**

### RENDER a card layout before shipping it

A Live Activity never starts in the Simulator, so for a long time the only way to
see this card was TestFlight, and every layout defect in it was found by a user.
`SproutTests/LiveActivityRenderTests` renders the views directly instead:

```bash
SHOT=/tmp/la; DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer \
  TEST_RUNNER_SPROUT_SHOT_DIR=$SHOT xcodebuild -project native/Sprout.xcodeproj \
  -scheme Sprout -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:SproutTests/LiveActivityRenderTests test   # then LOOK at $SHOT/*.png
```

`TEST_RUNNER_` is required — plain env vars do not reach the test process.

Two things that each cost an hour, looking exactly like a hung test:

- **`timeout` does not exist on macOS.** A `timeout 240 xcodebuild …` prints
  nothing and exits — it never ran. Bound a run with the Bash tool's own timeout.
- **`name=iPhone 17 Pro` is ambiguous the moment a second one is booted** (Maestro
  boots its own). xcodebuild may pick the busy one and the bundle queues behind
  that runner forever. Use `id=<udid>` from `xcrun simctl list devices booted`.

It measures as well as photographs, and the assertions are the durable half: a
readout that cannot fit its slot fails the suite. **It also reads pixels**, because
a frame can be the right size while the paint is not: `Circle().stroke` centres
the stroke on the path, so a 2pt ring in a 17pt frame paints 19pt and the island
clips the outer point — the sliced compact ring. `pixelsOutsideFrame` renders the
view in its frame with black around it and counts lit pixels in the surround;
`.inset(by:)` half the line width is the fix. **The trap is measuring against
the wrong width.** The first version of these tests compared the temperature row
against the whole lock-screen card and passed while the card rendered
`L…  R 2…  B…  C 3…` — that card is three columns, and the row gets the middle
one. Same shape as the section below: a budget computed from a nearby question.

Two things it still cannot answer, so do not claim them: the slot widths are
measured estimates rather than published values, and nothing here exercises the
larger Dynamic Type sizes.

**A `.frame(width:height:)` is a DEMAND, and the expanded island's regions decide
their own width.** The leading tile asked for a fixed 44pt; where the region
offered less it overflowed and the region clipped it, cutting the model's edges —
and at its extreme showing a sliver of the fallback glyph. Nothing upstream was
at fault, which is what made it hard: the source is square (the printer's cover
is 512x512) and `scaledToFill` into a square frame cannot crop. `scaledToFit`
plus `maxWidth/maxHeight` accepts what it is given instead. Twice this was
"reasoned about" and twice the reasoning was wrong, because the region's width is
Apple's and unpublished. The test that settled it renders a white square with a
RED BORDER into the tile at each plausible offered width and reads the pixels
back: a missing red edge is a crop. **Run the negative control** — the old chain
passes at 44 and loses all four edges at 40, 36 and 30. A crop test that never
saw a crop is proving nothing.

**A `View` interpolated into a `Text` compiles, and renders its own type.** The
drying card shipped a page of `ModifiedContent<ModifiedContent<Text, ScaledFont>,
…>` where the time remaining belonged: `.scaledFont`/`.scaledMono` are
ViewModifiers returning `some View`, and `Text("\(someView)")` is legal —
`LocalizedStringKey` renders it through `String(describing:)`. A green suite says
nothing about it. **Concatenate `Text` with `+`**, which is defined only on
`Text`, so the mistake is a compile error. Where pieces must stay `Text`, sizes
come from `@ScaledMetric`, not the modifiers.

Relatedly, `Text("…\(anInt)")` from a **literal** is a `LocalizedStringKey` and
groups the number ("1,731"); the same interpolation into a `String` parameter does
not. Two call sites that differ only in that had the island and the card
describing one print two ways.

## The recurring bug in this codebase: offering what the backend will refuse

This shape has now appeared many times, in unrelated code, written by different hands:

| Where | The lie | What the user saw |
|---|---|---|
| LAN Developer Mode | Handlers were gated, buttons were not | Controls that looked live and silently did nothing |
| "View layers" | `isSliced` answered "was this prepared by a slicer?" when the question was "does this have toolpaths?" | HTTP 404 on a plain `.3mf` |
| Wizard filament | Identity recomputed from hex instead of read from inventory | A brown spool labelled "Orange" |
| Maintenance | `enabled ?? false` in the list vs `enabled != false` in the triage count | "1 thing needs you" over a pane showing nothing |
| Menu bar panel | `vm.kind == .live` answered "is a print running?", not "will the printer accept a pause?" | Pause/Stop live and silent in LAN mode |
| LA plate preview | `plateIndex` was never passed, so the render endpoint's **default of 1** answered "which plate?" | Plate 1's picture on a card printing plate 3 |
| LA plate file name | `subtask_name` answered "which print?" when it names the **model** | Plate 4's card drew the image plate 1 had written |

The common cause is not carelessness — it is a **predicate that answers a NEARBY question**.
`isSliced` and `hasGcode` sound like synonyms and are not. "The user has permission" and "the printer
will accept it" sound like synonyms and are not.

**`subtask_name` IS THE MODEL'S NAME, NOT THE PRINT'S — and name+plate is still not unique.**
`/api/v1/archives/` settles what is. Read after two builds had each fixed a real fault and stopped
at the first key that looked sufficient:

    204 | 19:30 | plate_4.gcode | PLA profile + Optional PETG Translucen
    203 | 19:27 | plate_4.gcode | PLA profile + Optional PETG Translucen
    202 | 19:20 | plate_2.gcode | PLA profile + Optional PETG Translucen
    197 | 07:21 | plate_3.gcode | Best: 0.2mm layer, 2 walls, 15% infill

Every plate of one model reports the same name; a slicer PRESET name is reported as the print's
name and repeats across unrelated models; and 203/204 are two runs of the SAME plate of the same
model, which no name-and-plate combination can separate. **`current_archive_id` is unique per run**
and was in the status payload the whole time — it is what the App Group plate image is named by,
with name+plate and name alone kept below it, each used only when the stronger one is absent.
`plateURI` never falls back to a weaker key: being handed another run's model is the defect, and a
glyph is honest where a wrong picture is not.

**A key made of a name that repeats is not a key** — and when a payload carries a real id, ask what
in it is actually unique BEFORE picking one. That question, asked once, was worth three builds.

**AND THE PICTURE ITSELF CAN BE WRONG WHEN FETCHED, which no key fixes.** The printer's cover is
its own picture of what it is running, and at job acceptance it can still be the PREVIOUS job's. A
card created during "Auto bed leveling" at layer 0 therefore cached the last print's model, and
`coverAsked` — which exists so a 404 is not retried every four seconds — froze it there. A cover
taken before the first layer is now PROVISIONAL and re-resolved once `layer_num > 0`, exactly once.
Gated on a laid layer rather than a stage name: the stage strings are many and matching them is a
guess about firmware, while a layer is the thing itself. Same symptom as the two above, third
distinct cause; fixing each as though it were THE cause is what made this take four builds.

**READ BAMBUDDY'S HANDLER RATHER THAN PROBING IT.** The library rung was left plate-blind for
several builds because `library/files/{id}/plate-thumbnail/{n}` answered 404 for index 2 on every
sliced file in the live library — which proves nothing, since they are all single-plate. The
handler settles it in three lines: it reads `Metadata/plate_{plate_index}.png` out of the 3MF, so
the index is honoured and the 404s were files genuinely having no second plate. The source is in
the container: `docker exec bambuddy grep -rn "plate_thumbnail" /app/backend/app/api/routes/`.
"Cannot probe it" is not "cannot know it".

**A SQUARE FIXTURE CANNOT TELL `scaledToFit` FROM `scaledToFill`.** The crop test shipped with a
square bordered image, passed, and the lock-screen tile went on cutting the top and bottom off the
brand glyph — which is tall. Test the shape that discriminates. Two insets in that scanner are also
load-bearing, each learnt from a FALSE failure: sample the middle half of each side, because a
rounded tile clips the ends of the extreme row (at 30pt with a 10pt radius, most of it), and sample
two pixels inside the bounding box, because that outermost row is antialiased by the same clip and
is not pure red. Scan the drawn image's own border, never the frame's edge — the frame's edge
answers "does the image reach it", which is a different question and is false by design for a tile
that pads its content.

**`current_archive_id` IS ASSIGNED AFTER THE PRINT STARTS.** Trellis says so above its own wake:
"Bambuddy assigns the archive id a little after printing begins, so the value legitimately changes
mid-print." So it is unique but NOT stable at the moment the picture is fetched — the background
wake wrote `…-p1-…` and the card, created later, asked for `…-a205-…` and got a glyph for the whole
print. A key can be unique and still be the wrong key if it does not exist yet. The lookup walks
archive id, then name+plate, then name, and only ever narrows.

**A DEFAULT ARGUMENT is a predicate too.** The plate case had no predicate at all — just an
omitted parameter whose default silently asserted "plate 1". Nothing was gated wrongly; a question
was never asked, and the API answered the one it was given. The failure looked like success,
because a real render of the wrong plate is indistinguishable from a right one unless you know
what you printed. When a parameter selects WHICH THING, passing nothing is an assertion; make the
unknown case `nil` and handle it, rather than letting a default stand in for knowledge.

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
