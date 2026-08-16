<!-- Generated as the port specification for the native Swift rewrite. -->
# Gaps, native configuration and third-party dependencies

## gaps-and-native-config

Walked `/Users/max/ai-projects/bambu-app/mobile` in full: `src/` (74 non-test files), `modules/`, `plugins/`, `patches/`, `app.json`, `package.json`, `eas.json`, plus the *generated* `ios/` tree (gitignored, but present locally — it is the ground truth for what prebuild actually emits).

---

## 1. Source files not covered by the eleven documented areas

The eleven areas (api, dashboard, dashboard-ui, anim, tabs, overlays, realtime, domain, library-logic, shell, pip) plausibly cover `src/api/bambuddyClient.ts` + `types.ts`, `src/dashboard/present.ts`, `src/components/{DashboardView,TabBar,TabScreens,Overlays}.tsx`, `src/components/anim/*`, `src/realtime/*`, `src/library/*`, `src/app/index.tsx`, `modules/camera-pip/*`. "domain" is the only elastic label — **everything below is either definitely uncovered or at serious risk of having been swallowed by that one word.** Each is a distinct behavioural contract the Swift app must reproduce.

### Definitely uncovered

| File | What the rewrite must reproduce |
|---|---|
| `/Users/max/ai-projects/bambu-app/mobile/src/theme.ts` | 40 design tokens × 2 palettes (dark/light) from the Claude Design source. The theme is a **mutable module-scope object** `c` plus a `useSyncExternalStore` subscription — components read `c.token` inline at render. Theme is **manual and persisted in Keychain**, *not* system-driven, despite `userInterfaceStyle: "automatic"` in app.json. Also exports `mono` (Menlo on iOS) and `shadow1`. Includes a documented contrast rule: `swatchRing: '#8E9398'` is chosen for ≥3:1 against every *surface*, not against the fill. |
| `/Users/max/ai-projects/bambu-app/mobile/src/config/secureConfig.ts` | The **entire persisted config schema** — one JSON blob under SecureStore key `bambu.config`, accessibility `WHEN_UNLOCKED_THIS_DEVICE_ONLY`. 12 fields: `baseUrl`, `apiKey`, `cameraToken`, `theme`, `printerId`, `printerName`, `pushUrl`, `serverPush`, `texturizeUrl`, `texturize`, `adminUsername`, `adminPassword`. **Migration hazard:** if the Swift app uses a different Keychain account/service, every existing user setting is silently lost on upgrade. |
| `/Users/max/ai-projects/bambu-app/mobile/src/config/sanitize.ts` | Input rules for the connect form: base-URL trim + strip trailing slashes/whitespace; API-key charset is `bb_` + base64url `[A-Za-z0-9_-]{6,}`, with leading/trailing invalid chars stripped (paste artifacts: newline, `%`). Has a documented past bug — sanitizer and validator charsets must stay identical or Connect greys out for keys containing `_`/`-`. |
| `/Users/max/ai-projects/bambu-app/mobile/src/config/pushConfig.ts` | `resolvePushUrl()` — three-way resolution: `serverPush === false` → LOCAL (null); explicit `pushUrl` wins; else derive by swapping the `bambuddy.` subdomain to `lapush.`. Rejects anything not matching `^https?://`. This single function decides **who owns Live Activity cards** (see below). |
| `/Users/max/ai-projects/bambu-app/mobile/src/config/texturizeConfig.ts` | Same shape for the `texturize.` sidecar, plus the Shell health-probes the resolved URL before enabling any texturize UI. |
| `/Users/max/ai-projects/bambu-app/mobile/src/capabilities/lanMode.ts` | **Tri-state** (`on`/`off`/`unknown`) LAN-Developer-Mode gate. `unknown ≠ off` — absence must never grey out the UI. A hard-coded `BLOCKED` set of 9 of 17 `ActionId`s, with an explicit rationale for each *non*-blocked one (`stop` stays live because a dead emergency stop is dangerous; `light` uses `system/ledctrl` not `print.*`; `camera` is a separate port; `plug` is a different device; `plateCleared`/`queueRemove`/`maintenance` are backend bookkeeping). |
| `/Users/max/ai-projects/bambu-app/mobile/src/capabilities/useLanMode.ts` | Deliberately **out-of-band REST poll**, not read from the WebSocket feed (the WS frame omits `developer_mode`). 5-minute interval + re-check on app foreground. Failures keep the last known value. |
| `/Users/max/ai-projects/bambu-app/mobile/src/capabilities/useLockedAction.ts` | Single source of truth pairing a control's *look* (`style(a)`) with its *tap* (`press(a, run)`) so a button can never look enabled while blocked. |
| `/Users/max/ai-projects/bambu-app/mobile/src/alerts/present.ts` | Status → alert list VM, each carrying only actions currently possible. 5 action ids (`resume`/`stop`/`clearHms`/`plateCleared`/`lookup`), `destructive` flag, ordered candidate URL list for HMS lookup with a guaranteed-resolving last entry. |
| `/Users/max/ai-projects/bambu-app/mobile/src/alerts/hmsCatalog.ts` | Fetches Bambu's public code feed (`https://e.bambulab.com/query.php?lang=en`, ~4,900 HMS + ~650 print-error entries), caches ~535 KB to disk with a 14-day TTL, and scrapes `og:title` off wiki pages for codes the feed lacks (`parseWikiTitle`), persisting learned codes. Deliberately not bundled. |
| `/Users/max/ai-projects/bambu-app/mobile/src/ams/units.ts` | **The only tray-id math in the app.** `globalTrayId(unitId, localId) = unitId >= 128 ? unitId : unitId*4 + localId`. Handles N mixed units (up to 4 regular 0–3 + 8 HT 128–135), per-kind dry ceilings (65 °C AMS 2 Pro / 85 °C HT), humidity/temp/extruder/serial-tail disambiguation, Filament Track Switch. Getting this wrong lights the wrong spool. |
| `/Users/max/ai-projects/bambu-app/mobile/src/ams/dryer.ts` | Drying VM: "actively drying" = `dry_time > 0` (`dry_status` is unreliable), 9-entry `DRY_BLOCKERS` reason-code map, 9-entry `DRY_DEFAULTS` temp/hour table with same-type sibling-tray fallback, client-side clamp to the unit's hardware max (backend validates a wider range). |
| `/Users/max/ai-projects/bambu-app/mobile/src/cooling/present.ts` + `useCooldown.ts` + `fixtures/realCooldown.ts` | Bed-cooldown model: 35 °C target (Bambu's own textured-PEI figure), ambient estimation from 24 h of idle-floor history, **`stalled` detection** so a target below room temperature doesn't wait forever, deliberate absence of a per-material threshold table. Polling: 60 s curve refresh, 3 h curve window, 24 h ambient window, 30 min ambient refresh; seeds from server history so mid-cooldown app opens still get an ETA. |
| `/Users/max/ai-projects/bambu-app/mobile/src/power/present.ts` | `plugAutomations()` — enumerates the 4 server-side rules (`auto_on`, `auto_off`, `after_drying`, `schedule`) with a `cuts: boolean` flag marking the ones that can kill power mid-print. Read-only (writes are admin-gated). |
| `/Users/max/ai-projects/bambu-app/mobile/src/power/usePlugState.ts` | Optimistic toggle with a settle window that ignores poll results while a write is in flight (Home Assistant lags a few seconds), 5 s poll, revert on rejection. |
| `/Users/max/ai-projects/bambu-app/mobile/src/printers/profile.ts` | Per-model table: slicer preset token (`@BBL <token>`), printer-preset base name, AMS marketing label, `dualNozzle`, accepted bed types (first = default), physical plate footprint in mm (drives the layer viewer's plate). |
| `/Users/max/ai-projects/bambu-app/mobile/src/printers/selection.ts` | Fleet-selection **state machine**: adopt the first printer immediately when the current id was never confirmed (fresh connect / guessed default), but heal a previously-confirmed-then-vanished id only on the 2nd consecutive miss. Runs against a 30 s fleet refresh. |
| `/Users/max/ai-projects/bambu-app/mobile/src/notifications/useStatusNotifications.ts` | Foreground presentation policy (banner + list + sound, no badge), permission flow, raw APNs **device** token → `POST {pushUrl}/register-device` with `X-API-Key`. Distinct from the per-activity tokens below. |
| `/Users/max/ai-projects/bambu-app/mobile/src/liveactivity/useLiveActivity.ts` (286 lines) | If "domain"/"pip" didn't cover this, it is the single largest uncovered behaviour. **Exactly-one-owner ownership model:** SERVER mode (Trellis URL resolved) → the server starts/updates/ends every card, the app *never* calls `start()` and instead runs a **reconcile protocol** (enumerate live activities, read each one's push token — the only identity an adopted card exposes — report the *full* set so the server can detect user-swiped dismissals, end anything disowned). LOCAL mode → the app owns cards. Plus: 4 s per-printer update throttle, `meaningfulChange` gating, push-token rotation listeners, **one drying card per AMS unit** keyed `"<printerId>:<amsId>"` (a per-printer key silently hid the 2nd concurrent cycle), `offline`/`connecting` are no-ops so a WS blip never kills a card. |
| `/Users/max/ai-projects/bambu-app/mobile/src/liveactivity/contentState.ts` | **This is your `ActivityAttributes.ContentState` schema** — 24 flat fields (`printerName, name, stateLabel, progress, layer, totalLayers, etaEpochMs, finished, symbol, iconUri, tint, nozzle/nozzleTarget/nozzle2/nozzle2Target/hasNozzle2/activeNozzle, bed/bedTarget, modelUri, queueCount, nextName`, + drying variant `dry/amsTemp/amsTarget/humidity`). Plus `LA_COLORS` — **fixed hexes, not theme tokens**, because the server pushing updates cannot know the phone's theme — and an SF-Symbol name map per state label. |
| `/Users/max/ai-projects/bambu-app/mobile/src/liveactivity/nozzleIcon.ts` | A base64 PNG written once into the App Group container; returns a `file://` URI. Exists because the widget is a separate process and `uiImage` can't be re-tinted. |
| `/Users/max/ai-projects/bambu-app/mobile/src/liveactivity/modelThumb.ts` | Downloads the plate thumbnail into the App Group as `model.png`; the URL is **camera-token-gated (`?token=`)**, not `X-API-Key`. |
| `/Users/max/ai-projects/bambu-app/mobile/src/liveactivity/nozzle-glyph.svg` | Source asset for the above. |
| `/Users/max/ai-projects/bambu-app/mobile/src/components/Swatch.tsx` | Three-state filament swatch (colour / no-colour / unknown) with the fixed contrast ring. Documented as a proof, not a sampled result. |
| `/Users/max/ai-projects/bambu-app/mobile/src/components/NozzleIcon.tsx` | Brand tab glyph, `viewBox="48 30 96 142"`, tinted by prop. Same proportions as the Live Activity glyph. |
| `/Users/max/ai-projects/bambu-app/mobile/src/components/AlertsOverlay.tsx` | The alerts UI surface — separate from `Overlays.tsx`, so "overlays" likely missed it. |
| `/Users/max/ai-projects/bambu-app/mobile/src/api/texturizeClient.ts` | A **second, independent backend client** for the stl-texturize sidecar (jobs, textures, preview/commit, mapping modes, amplitude/scale/refine params, its own thumbnail + result URL builders, same `X-API-Key`). If "api" only covered `bambuddyClient`, this is missing entirely. |
| `/Users/max/ai-projects/bambu-app/mobile/src/app/settings.tsx` (339 lines) | If "shell" only covered `index.tsx`: the whole onboarding + settings screen — base URL / API key entry, admin credentials, push and texturize toggles, theme switch, app version from `expo-constants`, and the OTA update id readout. |
| `/Users/max/ai-projects/bambu-app/mobile/src/app/_layout.tsx` | Two-route stack, `headerShown: false`, settings presented as a `modal`, StatusBar style follows theme. |

### At risk — probably filed under "library-logic" but they are *renderers*, not logic

These three are ~700 lines of in-WebView graphics code and are the biggest single native-rewrite decision. Verify they were actually documented:

- `/Users/max/ai-projects/bambu-app/mobile/src/library/stlViewerHtml.ts` — raw WebGL flat-shaded STL viewer, **no CDN imports** (offline WKWebView), orbit/pinch/double-tap, Normals material mode, `MAX_STL_BYTES = 120 MB`, fetches the model itself from a same-origin tokenized URL so no bytes cross the bridge.
- `/Users/max/ai-projects/bambu-app/mobile/src/library/gcodeLayers.ts` — Canvas2D layer viewer, plate footprint from `printerProfile`.
- `/Users/max/ai-projects/bambu-app/mobile/src/library/gcodeParserSource.ts` — the G-code parser kept **as a source string** so one implementation serves both the WebView (JITed JavaScriptCore) and jest. Output is flat `Float32Array` segment buffers (`[x0,y0,x1,y1,…]`) + per-layer Z + separate support arrays. Explicitly moved out of Hermes because parsing a 70 MB file there produced three full copies before a triangle was drawn.
- `/Users/max/ai-projects/bambu-app/mobile/src/components/mjpegHtml.ts` — the **WebView MJPEG fallback** (distinct from the native PiP view): stall watchdog because a warming camera fires neither `onload` nor `onerror` for ~7 s, wall-clock retry budget rather than a retry count, `postMessage` protocol of exactly `connecting | frame | retry | failed | fps:<n>`.
- `/Users/max/ai-projects/bambu-app/mobile/src/components/anim/animUtils.ts` — pure half of the anim kit (digit-roll tokenizer, confetti geometry); "anim" may have covered only `index.tsx`.

### Trivial / no port needed
`src/global.css` + `src/global.d.ts` (web-only font vars), `scripts/reset-project.js` (Expo template scaffolding), `src/__tests__/sanity.test.ts`.

---

## 2. Native capability configured outside JS

### 2a. Config plugins (`/Users/max/ai-projects/bambu-app/mobile/plugins/`)

- **`withIosSceneLifecycle.js` + `iosSceneTransform.js`** — rewrites `AppDelegate.swift` and injects `UIApplicationSceneManifest`. Two things survive into a native rewrite even though the plugin itself dies: (1) the window must be created via `UIWindow(windowScene:)`, never `UIWindow(frame:)`, or safe-area insets and orientation resolve wrong; (2) **once a SceneDelegate exists, iOS routes cold-start URLs through `scene(_:openURLContexts:)` instead of `application(_:open:options:)`** — the plugin forwards `connectionOptions.urlContexts` in `willConnectTo` explicitly. Miss that and "open a .3mf from Files" silently does nothing on a cold launch.
- **`withIosPodMinDeploymentTarget.js` + `podfileMinTarget.js`** — forces every Pod target to iOS 16.4. Dies with CocoaPods; the **16.4 minimum itself must carry over**.

### 2b. patch-package (`/Users/max/ai-projects/bambu-app/mobile/patches/`)

- `expo-modules-jsi+56.0.10.patch` — Swift 6 workaround for a C++ interop initializer. **Delete, do not port.**

### 2c. `app.json` plugin list

`expo-router`, `expo-splash-screen` (background `#208AEF`), `expo-secure-store`, `expo-image`, `withIosSceneLifecycle`, `expo-build-properties` (`ios.deploymentTarget: "16.4"`), `withIosPodMinDeploymentTarget`, **`expo-widgets`** (`bundleIdentifier: com.example.sprout.LiveActivity`, `groupIdentifier: group.com.example.sprout`, `enablePushNotifications: true`, `frequentUpdates: true`), `expo-video`.

### 2d. Entitlements (verified in the generated project)

`/Users/max/ai-projects/bambu-app/mobile/ios/Bambu/Bambu.entitlements`:
```
aps-environment = development            (→ production for TestFlight/App Store)
com.apple.developer.usernotifications.time-sensitive = true
com.apple.security.application-groups = [group.com.example.sprout]
```
`/Users/max/ai-projects/bambu-app/mobile/ios/ExpoWidgetsTarget/ExpoWidgetsTarget.entitlements`:
```
com.apple.security.application-groups = [group.com.example.sprout]
```
All three capabilities (Push Notifications, App Groups, Time Sensitive Notifications) must exist on the App ID **before** signing.

### 2e. Info.plist keys the rewrite must recreate

| Key | Value | Why it matters |
|---|---|---|
| `CFBundleDisplayName` | `Sprout` | **Home-screen name differs from the product name `Bambu`.** Easy to lose. |
| `UIBackgroundModes` | `["audio"]` | Load-bearing for PiP: an *active audio session* — not PiP itself — is what keeps the app out of suspension. Without it the PiP window freezes on its last frame. |
| `NSSupportsLiveActivities` | `true` | ActivityKit |
| `NSSupportsLiveActivitiesFrequentUpdates` | `true` | Higher push-update budget |
| `NSAppTransportSecurity` | `NSAllowsArbitraryLoads: false`, **`NSAllowsLocalNetworking: true`** | Permits plain-HTTP to LAN/`.local` backends while keeping ATS on for the public internet. Dropping this breaks LAN setups. |
| `CFBundleURLTypes` | schemes `bambu` **and** `com.example.sprout` | Two schemes, not one |
| `CFBundleDocumentTypes` | 4 entries | `3MF Model`, `Bambu Sliced 3MF`, `G-code` all `LSHandlerRank: Owner`; `STL Model` (`public.standard-tesselated-geometry-format`) `Alternate` |
| `UTImportedTypeDeclarations` | 3 UTIs | `com.bambulab.3mf` (conforms `public.data`+`public.zip-archive`, ext `3mf`, 2 MIME types); `com.bambulab.gcode-3mf` (conforms to the above, **double extension `gcode.3mf`**); `com.bambulab.gcode` (conforms `public.text`+`public.data`, MIME `text/x.gcode`) |
| `LSSupportsOpeningDocumentsInPlace` | `false` | Files are copied into Inbox; `index.tsx` then re-copies to `Paths.cache` before upload |
| `ITSAppUsesNonExemptEncryption` | `false` | Skips the export-compliance prompt on every upload |
| `NSFaceIDUsageDescription` | template string | Injected by `expo-secure-store`; the app never uses biometrics — **drop it** rather than shipping a bogus purpose string |
| `UISupportedInterfaceOrientations` | Portrait + PortraitUpsideDown, `supportsTablet: false` | |
| `CADisableMinimumFrameDurationOnPhone` | `true` | 120 Hz ProMotion |
| `UIUserInterfaceStyle` | `Automatic` | …but the app's own theme is manual — see `theme.ts` |
| `UIRequiresFullScreen` | `false`, `UIViewControllerBasedStatusBarAppearance: false` | |
| `NSUserActivityTypes` | `$(PRODUCT_BUNDLE_IDENTIFIER).expo.index_route` | expo-router artifact; replace or drop |

**Not present but likely needed:** `NSLocalNetworkUsageDescription` — if the Swift app ever does Bonjour/mDNS discovery of the backend it will need this; the RN app avoided it by requiring a typed URL.

### 2f. App Group container usage

`group.com.example.sprout` is the only channel to the widget process. Three writers: `nozzle.png` (brand glyph), `model.png` (plate thumbnail), and expo-widgets' own bookkeeping. Any image the Live Activity shows must be a `file://` URI inside this container.

### 2g. Widget extension target

`/Users/max/ai-projects/bambu-app/mobile/ios/ExpoWidgetsTarget/`: `NSExtensionPointIdentifier = com.apple.widgetkit-extension`, a `@main WidgetBundle` containing a single `WidgetLiveActivity`, and `CFBundleShortVersionString`/`CFBundleVersion` that **must match the host app** or the archive is rejected.

### 2h. Privacy manifest

`/Users/max/ai-projects/bambu-app/mobile/ios/Bambu/PrivacyInfo.xcprivacy` — `NSPrivacyTracking: false`, empty `NSPrivacyCollectedDataTypes`, and three accessed-API reasons: FileTimestamp `C617.1`, UserDefaults `CA92.1`, SystemBootTime `35F9.1`. Aggregated from pods via `apple.privacyManifestAggregationEnabled`. The Swift app must hand-author its own.

### 2i. OTA update system (native config, `ios/Bambu/Supporting/Expo.plist`)

```
EXUpdatesEnabled = true, EXUpdatesCheckOnLaunch = ALWAYS, EXUpdatesLaunchWaitMs = 0
EXUpdatesRuntimeVersion = 1.0.0
EXUpdatesRequestHeaders = { expo-channel-name: production }
EXUpdatesURL = https://u.expo.dev/<eas-project-id>
```
**There is no native equivalent.** Today every JS-only fix ships without App Store review and applies on the *second* cold launch. The rewrite loses this entirely — call it out as a release-cadence change, not a footnote.

### 2j. Local Expo native module autolinking

`modules/camera-pip/` is picked up by Expo autolinking's default `./modules` scan via `expo-module.config.json`. Its `CameraPiP.podspec` declares the frameworks the Swift code needs: **AVKit, AVFoundation, CoreMedia, CoreVideo, ImageIO**, `static_framework = true`, `DEFINES_MODULE = YES`, `s.platforms = { ios: '16.4' }`. In the rewrite the Swift sources move into the app target and podspec + config JSON are deleted.

### 2k. Build properties

`ios/Podfile.properties.json`: Hermes engine, `RCTNewArchEnabled = true`, `EXPO_USE_PRECOMPILED_MODULES = true`, `ios.deploymentTarget = 16.4`, `expo-image.disable-libdav1d = false` (AVIF support). All disappear except the deployment target.

### 2l. App icon

`/Users/max/ai-projects/bambu-app/mobile/assets/Bambu.icon/` is an **Icon Composer bundle** (Liquid Glass), referenced by `ios.icon`: three layered SVGs (`accent`, `printhead`, `plate`) at scale 1.3, a two-stop `linear-gradient` fill in extended-sRGB, neutral shadow at 0.5 opacity, translucency disabled. Carries over verbatim into an Xcode asset catalog.

---

## 3. Third-party dependencies whose behaviour must be replicated natively

### Actually used

| Package | What it does here | Native equivalent |
|---|---|---|
| `expo-router` (+ `react-native-screens`, `react-native-safe-area-context`, `react-native-gesture-handler`) | 2-route stack: `index` + `settings` as a modal. Typed routes. 6 `useSafeAreaInsets` sites. | `NavigationStack` + `.sheet`; `safeAreaInsets`. gesture-handler/screens are transitive plumbing — nothing to port. |
| `react-native-webview` 13.16.1 | **Three WKWebView surfaces:** MJPEG camera fallback, STL WebGL viewer, G-code layer viewer. Mounted with `source={{ html, baseUrl: <backend origin> }}` so in-page `fetch` is same-origin against tokenized URLs (no CORS, no header plumbing); `originWhitelist={['*']}`, `allowsInlineMediaPlayback`, `postMessage` bridge. | `WKWebView` directly (cheapest — reuse the HTML generators verbatim), or rewrite the viewers in SceneKit/Metal. The MJPEG path is already superseded by the native PiP view. |
| `react-native-reanimated` 4.3.1 + `react-native-worklets` | The whole motion system: digit-roll counters, `FadeRise`, `LinearTransition` list reflow, `SlideInDown`/`FadeIn` sheet entry, confetti. | SwiftUI `withAnimation`, `.contentTransition(.numericText())`, `matchedGeometryEffect`, `.transition`. |
| `react-native-svg` 15.15.4 | `NozzleIcon` + anim-kit shapes. | SwiftUI `Shape`/`Path`, or SVG→PDF template assets. |
| `@expo/vector-icons` (Feather, MaterialIcons) | 7 import sites across every screen. | SF Symbols — **needs an explicit Feather→SF Symbol name mapping table**; the names do not correspond. |
| `expo-image` | Remote thumbnails with **custom headers** (`X-API-Key` for texturize, `?token=` for Bambuddy), `cachePolicy="memory-disk"`, `transition`, `contentFit`. | `URLSession` + `URLCache`/`NSCache` behind a custom `AsyncImage`. Plain SwiftUI `AsyncImage` cannot send headers — this is the trap. |
| `expo-video` | Timelapse playback. Note the comment at `TabScreens.tsx:543`: the download endpoint **does not honor Range requests**, so the file is downloaded fully to disk first, then played from a local URI. | `AVPlayerViewController`; keep the download-first workaround. |
| `expo-file-system` (+ `/legacy`) | `File`/`Paths`, `downloadFileAsync`, cache staging for opened documents, HMS catalog cache, App Group writes, and **`File.upload` for multipart** — used because Expo's WinterCG `fetch` rejects RN's `{uri,name,type}` FormData part. | `FileManager` + `URLSession` upload/download tasks. **The entire upload workaround evaporates** — this is a genuine simplification. |
| `expo-secure-store` | Keychain, `WHEN_UNLOCKED_THIS_DEVICE_ONLY`, one item. | Keychain Services. Preserve the item identity if you want existing installs to keep their config. |
| `expo-notifications` | Foreground presentation policy, permission flow, `getDevicePushTokenAsync` → hex APNs token. | `UNUserNotificationCenter` + `registerForRemoteNotifications()` + `willPresent` delegate. |
| `expo-widgets` + `@expo/ui/swift-ui` | Live Activity — and the source of the worst constraint in the codebase: the `'widget'`-directive function is **stringified and re-evaluated in an isolated native runtime**, so it may reference no module-scope value; `Text` takes no `size`/`weight`/`color` props (modifiers only); `uiImage` honours `frame` only when also `resizable()`. | **ActivityKit + WidgetKit directly.** Every one of those constraints disappears. `contentState.ts` becomes `ActivityAttributes.ContentState`; `Activity.pushToStartToken` and per-activity `pushTokenUpdates` replace the expo-widgets listeners. |
| `expo-linking` | `getInitialURL()` + `url` listener → file-open handling. | Already handled by the SceneDelegate code in the plugin. |
| `expo-document-picker` | `getDocumentAsync({ copyToCacheDirectory: true })`. | `UIDocumentPickerViewController` / `.fileImporter`. |
| `expo-updates` | OTA; `settings.tsx` displays `Updates.updateId`. | None. |
| `expo-constants` | `expoConfig.version` for the settings screen. | `Bundle.main` `CFBundleShortVersionString`. |
| `expo-status-bar` | Style follows theme. | `preferredStatusBarStyle` / `.toolbarColorScheme`. |
| `expo-splash-screen` | Launch storyboard, background `#208AEF`. | Launch screen asset. |

### RN core APIs needing native equivalents (easy to miss in a component-by-component port)

`Alert` — **60 call sites** (→ `UIAlertController`, note the destructive-style confirm on Stop); `Modal` — 7; `RefreshControl` — 6 (→ `.refreshable`); `Share` — 5 (→ `UIActivityViewController`, used for timelapse + downloaded files); `Linking.openURL` — 5 (HMS wiki lookup, with a HEAD-probe loop over candidate URLs before opening); `useWindowDimensions` — 3; `KeyboardAvoidingView` — 3; `AppState` — 2 (→ `scenePhase`).

### Declared in `package.json` but imported **nowhere** in `src/` — do not port

`@tanstack/react-query`, `expo-glass-effect`, `expo-symbols`, `expo-font`, `expo-system-ui`, `expo-device`, `expo-web-browser`, `react-native-web`, `react-dom`.

**`@tanstack/react-query` is the important one:** there is no query cache, no retry policy, no stale-while-revalidate anywhere. All data fetching is hand-rolled hooks with `setInterval` and explicit intervals (fleet 30 s, plug 5 s, LAN mode 5 min, cooldown curve 60 s, ambient 30 min, camera token 55 min). If the docs claim a caching layer, they are describing a dependency that isn't wired up.

---

## 4. Build / signing / distribution the rewrite must reproduce

**Identity (all three must be created/reused together)**
- App bundle id `com.example.sprout`; widget extension `com.example.sprout.LiveActivity`; App Group `group.com.example.sprout`. Development team is `ios.appleTeamId` in `app.json` (the owner's — substitute your own).
- Marketing version `1.0.0`, build `6`. Build number must keep climbing; **host and extension versions must match**.
- Deployment target **16.4** (Live Activities ≥16.1, frequent updates ≥16.2, `AVPictureInPictureController` sample-buffer content source ≥15).

**Two distinct Xcode toolchains — do not merge them**
- Device install on iOS 27 requires the **beta** Xcode (developer disk image); a locked phone plus `-destination 'id=<UDID>'` fails at destination resolution, so always use `-destination 'generic/platform=iOS'`.
- Archiving for TestFlight requires a **release** Xcode — App Store Connect rejects beta-SDK uploads outright. Note also that not every installed release Xcode has the iOS platform component; check `-showdestinations` before burning a build.
- `ENABLE_USER_SCRIPT_SANDBOXING=NO` is needed only because of the RN bundle script phase — **this goes away in a native rewrite**, as does the `** ARCHIVE FAILED **` false negative from the `expo-modules-jsi` script phase. Both current "trust the artifact, not the exit code" rules become unnecessary.
- `-allowProvisioningUpdates` + `CODE_SIGN_STYLE=Automatic`; adding a *new* capability to the App ID requires an Xcode-signed-in Apple ID.

**Export + upload**
- `ExportOptions.plist` (`method=app-store-connect`, `teamID`, `signingStyle=automatic`, `destination=export`) is referenced by the docs but **is not committed anywhere in the repo** — I searched the whole tree. The rewrite must recreate it.
- Upload via `xcrun altool --upload-app` with an **App Store Connect API key** (`.p8` under `~/.appstoreconnect/private_keys/`, plus a key id and issuer UUID — none committed). `-exportArchive destination=upload` fails: the Xcode Apple ID has Developer-portal access but not ASC. Validate with `--validate-app` first (catches SDK rejection in seconds). Uploads exceed 10-minute tool timeouts — run backgrounded and poll for `UPLOAD SUCCEEDED`.
- Crash triage over USB: `idevicecrashreport -e`; the crash time is in the **filename**, not the copy time. `idevicescreenshot` does not work on iOS 27.

**Process**
- **No CI.** Local Xcode builds only. Single-user TestFlight distribution.
- `eas.json` declares `development`/`preview`/`production` build profiles with `appVersionSource: "remote"` and `autoIncrement`, but EAS Build is **not** used — EAS serves only `eas update` (OTA) on channel `production`, runtime `1.0.0`. Both the EAS project id and `u.expo.dev` update URL become dead on rewrite.
- Today `runtimeVersion: {policy: "appVersion"}` means bumping `version` orphans every published OTA. That constraint dies, but plan the cutover: users currently on an OTA build reach the native binary only through TestFlight.
- **`ios/` and `android/` are gitignored and regenerated.** In the rewrite the Xcode project becomes the committed source of truth, and `plugins/`, `patches/`, and the `postinstall: patch-package` hook should be **deleted, not ported**.
- Quality gates today are `npx tsc --noEmit` and `npm test` (jest-expo). There are **~25 test files covering pure logic** that should port to XCTest: `dashboard/present`, `api/bambuddyClient`, `api/texturizeClient`, `config/{sanitize,secureConfig,pushConfig,texturizeConfig}`, `capabilities/lanMode`, `alerts/present`, `ams/{units,dryer}`, `cooling/present` (with a recorded real-cooldown fixture at `src/cooling/fixtures/realCooldown.ts`), `power/present`, `printers/{profile,selection}`, `library/{filamentMatch,gcodeLayers,gcodeParserSource,libraryBrowse,plateReview,presetSelect,printerFiles,sliceOverrides,stlViewerHtml}`, `liveactivity/contentState`, `components/mjpegHtml`, `anim/animUtils`, `realtime/parse`. The two `plugins/__tests__/` suites are the only ones that become obsolete.
