# Sprout for Mac — implementation architecture

**Status:** approved 2026-08-15. Companion to the locked UI spec, not a replacement for it.

The UI is already specified. `design_handoff_bambu_mac/README.md` in the Claude Design project
(`fcb20e35-35b7-4c52-84ea-bb84786feacd`) locks the window layout, the six section/inspector
contracts, the Mac-only surfaces, the API swaps, the metrics table, the build order and the
acceptance checks. The prototype `Sprout for Mac.dc.html` (`1a`–`1g`) is the visual reference.

This document covers only what that spec deliberately leaves to the implementer: **how the view
layer forks, and what has to move before it can.** Where the two disagree, the handoff README wins
on anything visible and this document wins on file layout.

## Decisions

| Question | Ship | Not taken |
|---|---|---|
| Scope | All seven steps of §9 | A steps 1–5 first cut |
| View layer | A separate `Views/Mac/` tree, sharing extracted logic | `#if os(macOS)` inside the existing view files; one tree parameterised by metrics |
| Section logic | `@Observable` stores in `Domain/`, driven by both trees | Re-implemented per platform |
| `AppModel` | Hoisted to `SproutApp`, injected via `.environment` | One instance per scene |

### Why not `#if os(macOS)` in place

The spec's §4 layouts are not the iOS layouts resized. Jobs history becomes a `Table`, the camera
tile changes column, Hardware's triage card leaves the content pane entirely, and the whole app
gains a third column. Branching structurally inside `LibraryView.swift` (1,686 lines) and
`AmsView.swift` (1,760) would land both near 2,800 lines carrying two interleaved layouts — and put
every Mac edit inside the file the iOS app ships from.

### Why not one parameterised tree

That works when two layouts are the same shape at two sizes. These are different shapes. Every
section would branch structurally anyway, with an extra layer of indirection in between.

### What this costs, honestly

Two view trees to keep in step for future features. The mitigation is that **layout is the only
thing duplicated** — every fetch, sort, filter and selection rule lives in one place, and that place
is unit-tested. A future feature adds a store method once and a layout twice.

## The load-bearing change: section stores

Each section currently keeps its data loading as `@State` plus a private `load()` driven by `.task`:

| View | Logic trapped in the view |
|---|---|
| `JobsView.swift:102-132` | `loadQueue`, `loadHistory`, `loadSettings`, `refreshAll`, the 5 s/15 s poll cadences |
| `LibraryView.swift:1029-1054` | `load`, `loadPrinter`, `refresh`, folder navigation, source switching |
| `PowerView.swift:45,172` | `refreshNow`, `reload`, the per-plug poller |
| `AmsView.swift:45` | `reload` |
| `DashboardView.swift:87` | maintenance counts |

Writing `Views/Mac/` against these means re-implementing all of it. So each moves to an
`@Observable` store in `Domain/` — `JobsStore`, `LibraryBrowseStore`, `PowerStore`, `HardwareStore`
— and both view trees drive one store.

This is not a new pattern in this codebase. `ExploreModel` is already exactly this shape, owned by
the shell and injected through the environment, and `LibraryView.swift:5-130` is already a block of
pure browse helpers sitting outside the view. The extraction finishes a job that was started.

**It is also the riskiest step, because it edits the shipping iOS views.** It lands first, on its
own, with the 950-test suite green before a single Mac view exists.

## `AppModel` moves to `SproutApp`

`Shell.swift:8` owns `@State private var model = AppModel()`. On macOS four scenes need the *same*
instance — §5.1 requires the menu bar extra to read the existing `PrinterStatusStore` without
opening a second connection, and it must keep working with the main window closed.

`load()` gains a `hasLoaded` guard: once the main window's `.task` stops being the only entry point,
a second call would tear down and rebuild a live session.

On iOS this is behaviour-preserving — one `WindowGroup`, one instance either way.

## Scene graph

| Scene | Prototype | Configuration |
|---|---|---|
| `WindowGroup` → `MacRoot` | `1a` / `1e` | `.defaultSize(1440×900)`, `.windowResizability(.contentMinSize)`, `.windowToolbarStyle(.unified)` |
| `WindowGroup(id:"camera", for: Int.self)` | `1c` | `.defaultSize(920×592)`, aspect locked to the stream |
| `WindowGroup(id:"viewer", for: ViewerRequest.self)` | `1g` | layers and STL as one window with a segment |
| `MenuBarExtra(…).menuBarExtraStyle(.window)` | `1b` | text label, no ring |
| `Settings` | `1d` | `⌘,`, five panes |

`MacRoot` is the config gate: onboarding window when `client == nil`, `MacWindow` otherwise.

## Platform shims

Smaller than the file count suggests. `MJPEGStream` and `MJPEGParser` import UIKit but use **no
UIKit symbol** — they work on `CGImage`, `CMSampleBuffer` and `AVSampleBufferDisplayLayer`, all
cross-platform. The imports are vestigial. §5.2's "reused unchanged" holds.

- `Shared/PlatformImage.swift` — `typealias PlatformImage = NSImage | UIImage`, plus `Image.init`
  and the two data accessors. Consumers: `Api/ThumbCache.swift` (6 uses),
  `Views/Components/SnapshotImage.swift` (3), `LibraryView`'s `PrinterFileImage` (3).
- `StlViewerOverlay.swift:168` `ViewerWebView` — an `NSViewRepresentable` twin for the `WKWebView`
  host.
- `LibShareSheet` (`UIViewControllerRepresentable`) — `ShareLink` on Mac; `NSItemProvider` file
  promises for the drag-out case in §5.3.

`#if os(iOS)`: `Camera/CameraPiP*`, `Realtime/PushRegistrar`, the `SproutWidget` dependency
(`platforms: [iOS]`), `LiveActivityController`'s ActivityKit surface, `tabBarMinimizeBehavior`.

## Traps, all of which stay green

Every one of these compiled, ran, and passed the suite. None was found by reading.

### `platforms:` is not `platformFilter:`

§0 puts `platforms: [iOS]` on the `SproutWidget` dependency. That key does not filter an embed — it
**removes the embed phase entirely, on every platform**, so the iOS app builds, installs and runs
with no `PlugIns/` directory and no Live Activity at all. Measured on both destinations:

| dependency form | iOS appex | macOS build |
|---|---|---|
| `platforms: [iOS]` | **missing** | ok |
| `platformFilter: iOS` | present | ok |
| *(no filter)* | present | **fails** |

It survived one round of "verification" because that check confirmed the appex was absent from the
*macOS* bundle. It was — and from the iOS one too. **Confirming the negative is not confirming the
positive.**

### Inspecting a Mac app's windows from a shell is blind

Both obvious routes need TCC permissions a terminal usually lacks, and neither fails loudly:

- `System Events` window enumeration needs Accessibility. Without it it returns **`0 windows` for
  every app**, including Finder.
- `CGWindowListCopyWindowInfo` needs Screen Recording for names and returns a restricted list that
  omits other apps entirely.

So a perfectly healthy app reports as having no windows. `MacWindowProbe` (DEBUG, `SPROUT_WINDOW_PROBE=1`)
asks the app itself, which needs no permission and cannot lie. Use it before believing a window is
missing.

### An unsatisfied `@Environment` object is a runtime trap

`AmsView` took `HardwareStore` from `@Environment` and nothing injected it. That compiles, and the
whole suite passes, because no test mounts the view — it dies on first render with SwiftUI's "No
Observable object of type … found". Stores are read off `AppModel` as plain properties for exactly
this reason; nothing in this app should reach for a store through the environment.

### Polling belongs to whoever can see the section

`AppModel` has **no `startStores()`**, deliberately. It once did, on both platforms, while the iOS
views also drove their own `.task` polls — so Jobs fetched the queue twice every 5 s with two loads
racing over one failure flag, and an `AppModel`-owned loop has no view to cancel it, so leaving the
tab stopped nothing.

On macOS the lifetime is owned by `MacSectionContent` and nowhere else, because it is the only thing
in the app that knows which section is on screen. Leaving it to each section produced immediate
drift: Power did it, Files did it, Hardware called `reload` without starting, Jobs did nothing at all
— and since Jobs also backs the Printer section's UP NEXT, the screen a launch lands on sat on
"Loading the queue…" for ever.

### A store that outlives its session must clear on `attach`

The stores are owned by `AppModel` and survive a reconnect; the `@State` they replaced did not.
Three of the four recorded the new client without clearing, so one server's data survived into
another. The worst case was destructive rather than cosmetic: multi-select survived sign-out, so
Delete issued the **previous** library's ids against a different Bambuddy, and library ids are small
integers that collide.

"A refresh should not blank the list" is true, and it is a different question from "this is a
different server now".

### `private` in an iOS-guarded file is invisible, and gets duplicated

`LibraryBrowse` was `private` inside `LibraryView.swift`, which is `#if os(iOS)`. The macOS Files
section could not see it and grew its own copies of `displayName`, `safeShareName`, `filter` and
`sortPrinterFiles`. Not cosmetic: `displayName` feeds `LibraryDownloadName.pathSegment`, which builds
the download URL's last path segment — two copies drifting is a **404 on one platform**.

Anything both trees need lives in `Domain/` and is internal. If a helper is pure, that is already the
argument for moving it.

## Corrections to the handoff spec

Both were found by checking rather than reading, and both fail silently.

**§0's `project.yml` does not work as written.** It nests the macOS-only settings under a `macos:`
key beside `base:`. xcodegen 2.45.4 has no such key for a multiplatform target and **drops the block
without an error** — the generated `pbxproj` contains no `ENABLE_HARDENED_RUNTIME` and no macOS
`CODE_SIGN_ENTITLEMENTS`, so the Mac app would ship unsandboxed and unhardened while the build
stayed green. Use Xcode's own build-setting conditionals instead, which do survive:

```yaml
settings:
  base:
    "CODE_SIGN_ENTITLEMENTS[sdk=macosx*]": Sprout/Resources/Sprout-macOS.entitlements
    "ENABLE_HARDENED_RUNTIME[sdk=macosx*]": YES
    "TARGETED_DEVICE_FAMILY[sdk=iphone*]": "1"
```

`TARGETED_DEVICE_FAMILY` moves under a condition for the same reason: it is currently a
project-wide `"1"`, which is meaningless on macOS and misleading to read.

**§4 Hardware states "`AppModel.hwSegment` still owns the selection".** No such property exists —
`grep` finds `hwSegment` nowhere in the tree, and `AmsView` holds the segment in local `@State`. It
now lives on `HardwareStore.segment` (reached as `model.hardware.segment`), because `⌘R` has to know
which segment to refetch — and because `⌘R` must refetch Filament and Service but **not** Nozzles,
which is live socket state with nothing to refetch.

**`NSPrincipalClass` was absent from the Mac bundle.** Xcode injects it only when it *generates* the
Info.plist; this target names one explicitly, so the key never appeared. Set per-sdk
(`NSApplication` on macOS, `UIApplication` on iOS). No misbehaviour was traced to its absence — it is
set because every Xcode-generated macOS app has it, not because something broke.

**`LSSupportsOpeningDocumentsInPlace` is not among the iOS-only keys macOS ignores.** §0 lists four
that are; this fifth one fails the build outright. Dropped rather than set: absent means what `false`
meant, and Sprout copies imports into its library rather than editing in place.

Every other cross-reference in §4 is verified against the source before it is relied on.

## What macOS deliberately does not have

Beyond §6's list, and each for a reason rather than an omission:

- **The keychain accessibility class.** macOS `SecItem` uses the legacy file-based keychain, which
  does not store `kSecAttrAccessible`. Opting into the data-protection keychain was tried and
  reverted: it needs an entitlement this App ID cannot get without being enabled for macOS on the
  developer portal, and without it *every* keychain call fails `errSecMissingEntitlement` (-34018) —
  the app cannot store credentials at all. The attribute guards a locked-device background wake-up,
  which is an iOS event. Round-trip and migration are still asserted on macOS and pass.
- **An alerts surface.** `Overlay.alerts` is never presented, so `AlertVM.actions` — including the
  ordered HMS wiki lookups — are unreachable. The Printer inspector shows alert text read-only. A
  Mac alerts sheet is worth building; nothing pretends it exists in the meantime.

## Known, not done

- Distribution needs the App ID enabled for **macOS** on the developer portal. There is no Mac
  provisioning profile for `com.mvks5.bambu`, so signed builds fail; unsigned local builds are fine.
  This blocks the first notarised or TestFlight build, nothing before it.
- Dragging a file **out** of the Files grid (`NSItemProvider` file promises, §5.3) is not wired.
  Dropping in, from the window and from the Dock, is.

## Verified before starting

- macOS 26.2 SDK present under `Xcode-26.3.0.app`; host is macOS 26.5.2, so the app builds *and
  runs* locally.
- `supportedDestinations: [iOS, macOS]` with `platforms: [iOS]` on the widget dependency parses in
  xcodegen 2.45.4, resolves both destinations, builds for `platform=macOS`, and correctly omits the
  extension from the Mac bundle. Proven by a throwaway spike, not assumed.
- Baseline: 950 tests, 0 failures.

## Testing

The suite is the gate at every phase boundary, not at the end.

- `SproutTests` gains the macOS destination, so the domain layer is proven on both platforms.
- Each extracted store gets unit tests covering what the view used to do implicitly: poll cadence,
  source switching, folder navigation, selection reconciliation, failure paths.
- `Metrics` gets a test that both platform branches define every token — a missing one is otherwise
  a silent layout bug on one platform only.
- Mac-only logic that can be tested without a window is tested: the collapse-rule thresholds, the
  camera claim handoff state machine, Spotlight index/de-index bookkeeping, `TabKey` raw-value
  stability (they are persisted, and §2 forbids renumbering).

## Build

```bash
(cd native && xcodegen generate)
DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer \
  xcodebuild -project native/Sprout.xcodeproj -scheme Sprout -destination 'platform=macOS' build
DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer \
  xcodebuild -project native/Sprout.xcodeproj -scheme Sprout -destination 'platform=macOS' test
```

The iOS lines in `CLAUDE.md` are unchanged and must stay green throughout.

## Shipping

**iOS ships today.** `./native/scripts-archive.sh --upload` archives, exports, validates and
uploads. Nothing about the Mac port changed that path — the widget is still embedded (see the
`platformFilter` note above, which is the one thing that nearly broke it silently).

**macOS builds, signs and exports a valid App Store package.** With an Apple ID signed into Xcode,
`-allowProvisioningUpdates` creates the Mac profile itself. Measured on the exported `.pkg`: signed
`Apple Distribution`, hardened runtime, App Sandbox plus network client/server, user-selected and
downloads file access, and the app group. No appex, `NSPrincipalClass = NSApplication`, and all four
document types intact.

**And it uploads.** `com.mvks5.bambu` now carries both `IOS` and `MAC_OS` platforms on one App
Store Connect record, so the two ship as separate TestFlight builds of one app and share its
testers. Adding the platform is a UI-only action — the ASC API exposes neither app creation nor
platform addition — and it was the last blocker.

The failure before it was added is worth keeping, because it names itself badly:

```
ERROR: Cannot determine the Apple ID from Bundle ID 'com.mvks5.bambu' and platform 'MAC_OS'. (12)
```

That is not a credentials problem. The same API key had uploaded an iOS build minutes earlier; the
record simply had no macOS platform to attach the build to. **Always `--validate-app` first** — this
cost a validation call instead of a spent build number.

`scripts-archive.sh --macos` does the Mac half now; it was iOS-only, and the Mac build was archived
by hand off a copy of the iOS command. That is worth not going back to, because the two paths differ
in more places than the destination and **each one fails at a different stage**:

| | iOS | macOS |
|---|---|---|
| destination | `generic/platform=iOS` | `generic/platform=macOS` |
| SDK checked against | `iphoneos*` | `macosx*` |
| app's own plist | `Sprout.app/Info.plist` | `Sprout.app/Contents/Info.plist` |
| artifact | `.ipa` (a zip) | `.pkg` (needs `pkgutil --expand-full`) |
| widget profile | named | none — no appex is embedded |
| `altool -t` | `ios` | `macos` |
| signing | manual, against `DIST_*` | automatic, cloud-signed |

Three of those were found by RUNNING it, not reading it, and two failed in ways that pointed
somewhere else:

- The SDK guard read the iOS plist path. PlistBuddy failed, and under `set -e` a failing command
  substitution kills the script with no message — so the run ended at exit 1 with `** ARCHIVE
  SUCCEEDED **` as its last line, which reads as the archive having failed when the archive was
  perfect and the *checker* was broken.
- **The ASC key must not be passed to the macOS export.** `-authenticationKey*` does not add an
  authority, it selects one: cloud signing then runs as the key rather than as the Apple ID signed
  into Xcode. The key's role cannot create distribution certificates, and macOS needs two that are
  not in the keychain — `Mac App Distribution` and `Mac Installer Distribution` (the artifact is a
  signed installer, so there is an identity iOS never asks for). It fails as `Cloud signing
  permission error` plus `No signing certificate … found`, twice over, none of which names the key.
  Dropping it exports the same archive first time. iOS keeps it, because that path signs manually
  and asks Apple for nothing.

### The macOS push entitlement is spelled differently, and the wrong one vanishes

`aps-environment` is the **iOS** key. macOS grants `com.apple.developer.aps-environment`, and the
two are not interchangeable — an entitlement the profile does not contain is not refused, it is
**silently filtered out of the `.xcent`**. Three Mac builds shipped without push while the source
file plainly declared it, the archive succeeded and the signature was valid.

It cost two wrong diagnoses before the right one. The App ID was blamed — it has
`PUSH_NOTIFICATIONS` enabled and always did, confirmed through the ASC API. The provisioning profile
was blamed — it grants the capability and always did. What settled it was decoding the profile and
reading the key NAMES:

```
$ security cms -D -i "Mac Team Store Provisioning Profile: com.mvks5.bambu.provisionprofile"
com.apple.developer.aps-environment      <- what macOS grants
```

Check the spelling against the profile before concluding anything about an account. This is
`isSliced` vs `hasGcode` in a plist.

### App Attest is genuinely absent on macOS

The Mac profile grants no App Attest entitlement under any spelling, so it stays out of
`Sprout-macOS.entitlements`. Nothing on macOS needs it: App Attest exists to vouch push tokens to
Canopy from `LiveActivityController`, and that whole file is `#if os(iOS)`.

**Push itself now ships.** The entitlement is correct, `MacAppDelegate` registers, and the exported
package carries `com.apple.developer.aps-environment = production`. What is still missing is a
CONSUMER: nothing on macOS assigns `onDeviceToken`, so a token arrives and is dropped. The Mac's
consumer is the Notifications pane (1d), which turns a push into a `UNUserNotification`. Until that
exists, Mac testers get no remote alerts while iOS testers do — a real gap now that TestFlight goes
to real testers rather than one person.

## Order

Follows §9, with the extraction inserted as its own step because it is the one that can break the
shipping app.

1. Target destinations, entitlements, delegate split, `#if os(iOS)` guards, platform shims.
2. **`AppModel` hoist and store extraction.** iOS suite green before anything Mac-shaped exists.
3. `NavigationSplitView` shell: sidebar, `TabKey.explore`, `⌘1`–`⌘6`, scene storage, toolbar.
4. `Settings` scene and the onboarding window.
5. Inspector column and the six inspector contracts; `Metrics`.
6. Section reflows.
7. Camera window and the claim handoff, then the menu bar extra.
8. Drag-and-drop, Dock open, Quick Look, Spotlight, print sheet, viewer window.
9. Every acceptance check in §10, on a running app.
