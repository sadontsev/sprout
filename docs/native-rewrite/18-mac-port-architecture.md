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
is added to `AppModel` as §4 assumes, because `⌘R` has to know which segment to refetch.

Every other cross-reference in §4 is verified against the source before it is relied on.

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
