<!-- Generated as the port specification for the native Swift rewrite. -->
# App shell, onboarding, Keychain, theme, native config

## shell

The app shell is `src/app/index.tsx` (route `/`, `expo-router`) plus `src/app/_layout.tsx` (root Stack), `src/app/settings.tsx` (route `/settings`, modal presentation), `src/config/secureConfig.ts` (Keychain), `src/theme.ts` (design tokens), and `app.json` (native config). Absolute paths, all under `/Users/max/ai-projects/bambu-app/mobile/`.

---

### 1. Root layout — `src/app/_layout.tsx`

```tsx
export default function RootLayout() {
  const theme = useTheme(); // re-render on theme switch so the status bar + background follow
  return (<>
    <StatusBar style={theme === 'light' ? 'dark' : 'light'} />
    <Stack screenOptions={{ headerShown: false, contentStyle: { backgroundColor: c.bg } }}>
      <Stack.Screen name="index" />
      <Stack.Screen name="settings" options={{ presentation: 'modal' }} />
    </Stack>
  </>);
}
```

Two routes only. No header anywhere. `/settings` is presented **modally** over `/` (but is also the *destination of a `router.replace`* during onboarding — see below, this dual role matters).

---

### 2. Config gate — `AppScreen` in `src/app/index.tsx`

State: `config: AppConfig | null | undefined` — a deliberate **three-state**:

| value | meaning | render |
|---|---|---|
| `undefined` | not yet read from Keychain | blank `View` filled with `c.bg` (no spinner) |
| `null` | no config stored (or Keychain read threw) | `router.replace('/settings')` in an effect, blank `View` meanwhile |
| `AppConfig` | configured | `<Shell key={reload} config={config} onRetry={…} />` |

```tsx
const [config, setConfig] = useState<AppConfig | null | undefined>(undefined);
const [reload, setReload] = useState(0);
useTheme(); // re-render the whole app when the theme is toggled (Settings)

useFocusEffect(useCallback(() => {
  let active = true;
  // A Keychain read failure must land on the onboarding screen, not an eternal blank gate.
  getConfig().catch(() => null).then((cfg) => {
    if (!active) return;
    if (cfg) setTheme(cfg.theme ?? 'dark');
    setConfig(cfg);
  });
  return () => { active = false; };
}, [reload]));

useEffect(() => { if (config === null) router.replace('/settings'); }, [config]);

if (!config) return <View style={{ flex: 1, backgroundColor: c.bg }} />;
return <Shell key={reload} config={config} onRetry={() => setReload((r) => r + 1)} />;
```

Gotchas encoded here (must survive the port):
- **`useFocusEffect`, not `useEffect`** — the config is re-read every time `/` regains focus, i.e. every time the Settings modal is dismissed. That is the only mechanism by which an edited URL/key propagates into `Shell`.
- **`.catch(() => null)`** — a Keychain failure must resolve to `null` (→ onboarding), never leave `undefined` (→ eternal blank screen).
- **Theme applied before `setConfig`** — `setTheme(cfg.theme ?? 'dark')` runs first so the first painted frame is already in the right palette.
- **`key={reload}`** — `onRetry` bumps `reload`, which both re-reads config *and* forces a full remount of `Shell` (fresh client, fresh sockets, all timers restarted). This is the "Retry" affordance on the offline dashboard.
- `!config` covers both `undefined` and `null`, so the gate never flashes the dashboard.

---

### 3. `Shell` — client construction

```tsx
const client = useMemo(() => new BambuddyClient({
  baseUrl: config.baseUrl, apiKey: config.apiKey,
  adminUsername: config.adminUsername, adminPassword: config.adminPassword,
}), [config]);
```

`BambuddyClient` (`src/api/bambuddyClient.ts`) is React-free:
- `baseUrl` is stripped of trailing slashes in the constructor: `cfg.baseUrl.replace(/\/+$/, '')`.
- `adminUsername` is `.trim() || undefined`; `adminPassword` is `|| undefined`.
- Every normal request sends `{'X-API-Key': apiKey, ...extraHeaders}`.
- `wsBaseUrl` = `baseUrl.replace(/^http/, 'ws')`.
- Non-2xx throws `` `Bambuddy ${method} ${path} -> HTTP ${status} ${body}` `` (trimmed). All shell error alerts stringify that.
- Admin-gated calls use a cached JWT from `POST /api/v1/auth/login` (`{username,password}` JSON → `access_token`), proactively re-minted at **23 h** (`JWT_MAX_AGE_MS = 23*60*60*1000`), with exactly **one** retry on 401/403. `body.requires_2fa` → `"Admin login failed: this account has 2FA enabled…"`. Without admin creds it falls back to the API key and rewrites the server's `"administrative operations"` 403 into *"This action needs the Bambuddy admin login. Add the admin username + password in Settings → Edit, then retry."*

Because `client` is `useMemo([config])` and `config` is a fresh object on every focus-read, **the client is rebuilt on every return from Settings** — which is what restarts the fleet poller, camera minting, etc.

---

### 4. Fleet load + printer selection state machine

```tsx
const [printers, setPrinters] = useState<Printer[] | null>(null);
const [printerId, setPrinterId] = useState<number>(config.printerId ?? 1);
useEffect(() => {
  let alive = true;
  const load = () => client.listPrinters()
    .then((ps) => alive && setPrinters(ps.filter((p) => p.is_active)))
    .catch(() => alive && setPrinters((prev) => prev ?? null)); // keep retrying below
  load();
  // Retry until loaded, then refresh occasionally — a one-shot fetch would hide the fleet
  // switcher forever after a single launch-time failure (and never see newly added printers).
  const id = setInterval(load, 30_000);
  return () => { alive = false; clearInterval(id); };
}, [client]);
```

- `GET /api/v1/printers/` → `Printer[]`, filtered to `is_active === true`.
- Poll every **30 000 ms**, forever. On error the previous list is preserved (`prev ?? null`).
- Default selection is `config.printerId ?? 1` — a *guess* that the reconciler heals.

**Selection reconciler** — `src/printers/selection.ts`, pure, held in a `useRef<SelectionState>`:

```ts
export interface SelectionState { missed: number; everMatched: boolean; }
export const initialSelectionState = { missed: 0, everMatched: false };
export type SelectionAction = { type: 'keep' } | { type: 'select'; id: number; name: string };

export function reconcileSelection(fleet, current, state) {
  if (fleet.length === 0) return { state, action: { type: 'keep' } };
  if (fleet.some((p) => p.id === current))
    return { state: { missed: 0, everMatched: true }, action: { type: 'keep' } };
  const threshold = state.everMatched ? 2 : 1;
  const missed = state.missed + 1;
  if (missed < threshold) return { state: { ...state, missed }, action: { type: 'keep' } };
  const next = fleet[0];
  return { state: { missed: 0, everMatched: state.everMatched },
           action: { type: 'select', id: next.id, name: next.name } };
}
```

State machine, verbatim from the comments:
- Current id **present** → keep, mark `everMatched = true`, reset `missed`.
- Current id **absent, never confirmed** (fresh connect, or guessed id 1 when the real printer is id 2) → adopt `fleet[0]` **immediately** (threshold 1). "No reason to sit on 'Connecting' for a minute while a two-strike heal counts up."
- Current id **absent, previously confirmed** → require a **second consecutive miss** (threshold 2). "A single absence can be a transient list blip (is_active toggled during maintenance, a flaky response); switching on a blip would rewrite a good persisted selection."
- **Empty fleet** → keep; *not* counted as a miss.

On `{type:'select'}` the Shell does `setPrinterId(action.id)` **and** `void patchConfig({ printerId: action.id, printerName: action.name })` (persist). Manual `selectPrinter(id)` does the same, looking the name up from `printers`.

Derived: `printer = printers?.find(p => p.id === printerId) ?? null`, `profile = printerProfile(printer)`.

**`printerProfile`** (`src/printers/profile.ts`) — table keyed by uppercased `model`:

| model | presetToken | printerPresetBase | amsLabel | dualNozzle | plate (mm) | bedTypes |
|---|---|---|---|---|---|---|
| `A1` | `@BBL A1` | `Bambu Lab A1` | `AMS Lite` | false | 256 × 256 | Textured PEI, Smooth PEI, Cool Plate, Engineering |
| `H2C` | `@BBL H2C` | `Bambu Lab H2C` | `AMS 2 Pro` | true | 350 × 320 | Textured PEI, Smooth PEI, High Temp, Engineering |
| unknown | `@BBL {model}` | `Bambu Lab {model}` | `AMS` | `nozzle_count > 1` | 256 × 256 | Textured, Smooth, Cool, Engineering |

Bed-type ids are the exact strings the slicer expects: `'Textured PEI Plate'`, `'Smooth PEI Plate'`, `'Cool Plate'`, `'Engineering Plate'`, `'High Temp Plate'`.
`cameraHint` strings: A1 → *"The A1's camera is on-demand and can be slow — give it a moment and tap Retry."*; H2C → *"If this persists, enable LAN Mode Liveview in the printer's settings screen (Settings → General)."*; generic → *"Give the camera a moment and tap Retry. Make sure the printer is powered on."*
Default model when `printer` is null is `'A1'`.

---

### 5. Status, alerts, HMS catalog

- `const { status, statuses } = usePrinterStatus(client, printerId)` — `status` is the selected printer's live `PrinterStatus`; `statuses` is a `Record<printerId, PrinterStatus>` from the shared WebSocket (the socket carries *all* printers, which is what makes the fleet switcher and multi-printer Live Activities cheap).
- HMS catalog: `loadHmsCatalog()` once on mount into `useState<HmsCatalog>(EMPTY_CATALOG)`. `EMPTY_CATALOG = { hms: {}, err: {}, learned: {}, fetchedAt: 0 }`. Comment: *"Bambu's own HMS/print-error text, fetched once and cached on disk. Until it lands, alerts show the code with generic copy — never a spinner, never a blocked render."*
- `alerts = useMemo(() => presentAlerts(status, { connected: status?.connected === true, canControl: true, model: printer?.model }, { hms: c => describeHms(hmsCat, c), printError: e => describePrintError(hmsCat, e) }), [status, hmsCat, printer?.model])`. `canControl` is hardcoded `true` — *"Control endpoints accept the scoped API key; an unreachable printer can't act at all."*
- **Code-learning effect** — for every alert whose `code` is not in the catalog and which has `lookup` URLs, call `learnCodes([{code, urls}])` and swap in the returned catalog. Comment: *"Codes Bambu's feed doesn't carry (every H2-family one) get read off the wiki page ONCE and remembered — that's how `0C00-0100-0002-0017` becomes 'Nozzle camera lens is dirty…'."* Dep array is the hand-rolled `[alerts.map(a => a.code).join(','), hmsCat.fetchedAt]` with an eslint-disable — the identity of `alerts` churns every status frame, so it is keyed on the *code set* instead.
- `describeHms` normalizes: `code.replace(/[-_\s]/g,'').toUpperCase()`, looks in `cat.hms?.[key] ?? cat.learned?.[key] ?? null` — both optional-chained because *"a catalog cached by an earlier build has no `learned` map, and reading it straight would crash the alerts screen on upgrade."*

---

### 6. Dashboard VM, cooldown, LAN mode, guard

```tsx
const vm = useMemo(() => presentDashboard(status, Date.now()), [status]);
const cooldown = useCooldown(client, printerId, status);
const lanMode = useLanMode(client, printerId);       // 'on' | 'off' | 'unknown'

/** Refuse a blocked action loudly instead of firing a command the printer silently discards. */
const guard = (action: ActionId, run: () => void) => () => {
  if (isBlocked(action, lanMode)) { Alert.alert('Printer controls are locked', LAN_BLOCKED_HINT); return; }
  run();
};
```

**`useLanMode`** (`src/capabilities/useLanMode.ts`): polls `GET /api/v1/printers/{id}/status` every **5 min** (`POLL_MS = 5*60_000`), plus a re-check on `AppState → 'active'`. Deliberately **not** read from `usePrinterStatus`: *"that feed is WebSocket-primary, and Bambuddy's WebSocket frame does not carry `developer_mode` at all… a gate that flickered exactly when the app was healthiest."* Failures leave the last value (a network blip must not grey out the UI).

**`lanMode.ts`** — tri-state on purpose; `'unknown'` is not `'off'`; only an explicit `false` disables. Blocked set:
`pause, resume, speed, amsLoad, amsUnload, dryStart, dryStop, startPrint, printAgain`.
**Deliberately NOT blocked**, each for a stated reason: `stop` (emergency control — a dead grey Stop on a spaghettifying print is dangerous), `light` (publishes `system/ledctrl`, not a verified `print` command), `camera` (RTSPS, own port), `plug` (different device; the real kill switch), `plateCleared` / `queueRemove` / `maintenance` (Bambuddy-side bookkeeping only).
Copy constants: `LAN_BANNER_TITLE = 'Printer controls are locked'`; `LAN_BLOCKED_HINT = 'Turn on LAN Developer Mode on the printer (Settings → Network), then re-enter its new access code in this app.'`; `LOCKED_OPACITY = 0.4`.

**Fleet rows** for the switcher:
```tsx
const fleet: FleetEntry[] = useMemo(() => (printers ?? []).map((p) => {
  const pvm = presentDashboard(statuses[p.id] ?? null, Date.now());
  return { printer: p, kind: pvm.kind, stateLabel: pvm.stateLabel, stateColor: pvm.stateColor, progressInt: pvm.progressInt };
}), [printers, statuses]);
```

---

### 7. Camera token lifecycle (shell-level, distinct from the overlay's)

```tsx
const CAM_TOKEN_TTL_MS = 55 * 60 * 1000; // backend camera tokens live 60 min; refresh early
const [camToken, setCamToken] = useState<string | null>(config.cameraToken ?? null);
const camMintedAt = useRef(0);
useEffect(() => {
  let alive = true;
  const mint = () => client.mintCameraToken().then((t) => {
    if (!alive) return; camMintedAt.current = Date.now(); setCamToken(t);
  }).catch(() => {});
  if (!camToken) void mint();
  const id = setInterval(() => {
    if (!camToken || Date.now() - camMintedAt.current > CAM_TOKEN_TTL_MS) void mint();
  }, 60_000);
  return () => { alive = false; clearInterval(id); };
}, [client, camToken]);
```

- Mint: `POST /api/v1/printers/camera/stream-token` → `{ token }`.
- Ticks every **60 s**; re-mints when missing or older than **55 min**.
- This token is the auth for **thumbnails and snapshots too**, not just the stream: `snapshotUrl(printerId, token)` = `` `${baseUrl}/api/v1/printers/${id}/camera/snapshot?token=${encodeURIComponent(token)}` ``; `fileThumbUrl(fileId, token)` = `` `${baseUrl}/api/v1/library/files/${fileId}/thumbnail?token=…` ``. The `X-API-Key` header is **rejected (401)** on those paths.
- The overlay's `useCameraStream(client, printerId, cameraOpen || pipActive, 10)` mints its **own** token with the same 55-min/60-s policy and builds `` `${baseUrl}/api/v1/printers/${id}/camera/stream?token=…&fps=10` `` (MJPEG `multipart/x-mixed-replace`). It exposes `remint` (wired to the overlay's Refresh).

---

### 8. Live Activities + push registration

```tsx
const activityEntries: ActivityEntry[] = useMemo(() => (printers ?? []).map((p) => ({
  printerId: p.id, printerName: p.name, status: statuses[p.id] ?? null,
  vm: p.id === printerId ? vm : presentDashboard(statuses[p.id] ?? null, Date.now()),
})), [printers, statuses, printerId, vm]);

const pushUrl = useMemo(() => resolvePushUrl(config), [config.pushUrl, config.baseUrl, config.serverPush]);
usePrinterActivities(activityEntries, pushUrl, config.apiKey);
useStatusNotifications(pushUrl, config.apiKey);
```

*"Every printer in the fleet gets an entry; the hook starts/updates/ends a card per printer based on its live state, so A1 and H2C show as two separate cards on the lock screen."*

**`resolvePushUrl`** (`src/config/pushConfig.ts`) — pure:
```ts
export function resolvePushUrl(cfg: Pick<AppConfig,'baseUrl'|'pushUrl'|'serverPush'>): string | null {
  if (cfg.serverPush === false) return null;                       // LOCAL mode
  const trim = (s) => s.trim().replace(/\/+$/, '');
  const httpUrl = (s) => (/^https?:\/\/[^\s]+$/i.test(s) ? s : null);
  const explicit = cfg.pushUrl?.trim();
  if (explicit) return httpUrl(trim(explicit));
  const base = cfg.baseUrl ?? '';
  if (base.includes('bambuddy.')) return httpUrl(trim(base.replace('bambuddy.', 'lapush.')));
  return null;
}
```
`null` ⇒ **LOCAL** Live-Activity mode: cards update only while the app runs, no banners, no server. Non-null ⇒ **SERVER** mode: each card's push token is registered with Trellis (gated by `X-API-Key`, *"without it a stranger who knows the URL could register their device and receive this printer's status banners"*). The `httpUrl` regex exists so *"a malformed entry silently disables push rather than POSTing the token somewhere unexpected."*

`useStatusNotifications` requests notification permission, then `Notifications.getDevicePushTokenAsync()` (iOS → `{type:'ios', data:'<hex>'}`) and registers with Trellis. It no-ops unless `Platform.OS === 'ios' && pushUrl && apiKey`.

---

### 9. Texturize sidecar gate (strictly optional feature)

```tsx
const texUrl = useMemo(() => resolveTexturizeUrl(config), [config]);
const [texReady, setTexReady] = useState(false);
useEffect(() => {
  let alive = true;
  setTexReady(false);
  if (!texUrl) return;
  new TexturizeClient({ baseUrl: texUrl, apiKey: config.apiKey }).healthy().then((ok) => alive && setTexReady(ok));
  return () => { alive = false; };
}, [texUrl, config.apiKey]);
const texClient = useMemo(() => (texUrl && texReady ? new TexturizeClient({ baseUrl: texUrl, apiKey: config.apiKey }) : null),
  [texUrl, texReady, config.apiKey]);
```

`resolveTexturizeUrl` mirrors `resolvePushUrl` exactly (`texturize === false` → null; explicit `texturizeUrl` wins; else `bambuddy.` → `texturize.`; same `https?://` validation).

**Gotcha (comment):** *"A bambuddy.\* instance WITHOUT the sidecar must keep a fully working app — no texturize UI, original thumbnails — rather than dead buttons and a library of broken images (every thumbnail routes through the sidecar when it's enabled)."* Hence the URL resolves but the feature stays off until `/health` actually answers; `texClient === null` is threaded through as `onTexturize={texClient ? … : undefined}` so callers hide the affordance.

---

### 10. Tab + overlay state

```tsx
const [tab, setTab]                 = useState<TabKey>('printer');   // 'printer'|'library'|'jobs'|'ams'|'power'
const [overlay, setOverlay]         = useState<'camera' | 'upload' | null>(null);
const [wizardFile, setWizardFile]   = useState<LibraryFile | null>(null);
const [libKey, setLibKey]           = useState(0);      // bump = remount LibraryView (force refetch)
const [texturizeFile, setTexturizeFile] = useState<LibraryFile | null>(null);
const [viewStl, setViewStl]         = useState<{ fileId: number; name: string } | null>(null);
const [alertsOpen, setAlertsOpen]   = useState(false);
const [pipActive, setPipActive]     = useState(false);
const [speedOverride, setSpeedOverride] = useState<number | null>(null);
const [tick, setTick]               = useState(0);      // snapshot cache-buster
const [maintAlert, setMaintAlert]   = useState<{ due: number; warn: number }>({ due: 0, warn: 0 });
const openStl = (f: LibraryFile) => setViewStl({ fileId: f.id, name: displayName(f) });
```

`displayName(f)` = `decodeURIComponent(f.print_name || f.filename || `file-${f.id}`)` with a `try/catch` falling back to the raw string.

**Tab bar** (`src/components/TabBar.tsx`) — absolutely positioned, `bottom: 0`, `paddingTop: 9`, `paddingBottom: insets.bottom || 12`, `backgroundColor: c.s1`, `borderTopWidth: 1 / c.line`. Five tabs, each `flex:1`, `gap:4`, `paddingVertical:5`, icon size 21 (Feather) / 22 (custom `NozzleIcon` for `printer`), label `fontSize:10 weight:'600'`, colored `c.accent` when active else `c.t3`, press-scale 0.9:

| key | label | icon |
|---|---|---|
| `printer` | Printer | `NozzleIcon` (brand SVG glyph) |
| `library` | Files | Feather `folder` |
| `jobs` | Jobs | Feather `list` (queue + history merged into one print timeline) |
| `ams` | Hardware | Feather `box` |
| `power` | Power | Feather `power` |

**Speed optimistic override state machine:**
```tsx
useEffect(() => { if (speedOverride != null && vm.speedIdx === speedOverride) setSpeedOverride(null); }, [vm.speedIdx, speedOverride]);
useEffect(() => { if (speedOverride == null) return;
  const t = setTimeout(() => setSpeedOverride(null), 15000); return () => clearTimeout(t); }, [speedOverride]);
const speedIdx = speedOverride ?? vm.speedIdx;
```
Set on tap; cleared when the real `speed_level` catches up, on a **15 s** timeout, or immediately on request failure. Speed modes are `1..4` = Silent / Standard / Sport / Ludicrous (hints `50% / 100% / 124% / 166%`; dot palette keys `paused / running / heating / error`).

**Picture-in-Picture latch guard:**
```tsx
const cameraOpen = overlay === 'camera';
// Never let this latch on: it keeps the camera token alive and the overlay mounted.
useEffect(() => {
  if (overlay !== 'camera' && !pipActive) return;
  if (overlay === 'camera') return;
  const t = setTimeout(() => setPipActive(false), 30_000);
  return () => clearTimeout(t);
}, [overlay, pipActive]);
```
i.e. PiP-without-overlay auto-expires after **30 s**.

**Snapshot tile poller:**
```tsx
useEffect(() => {
  if (cameraOpen || tab !== 'printer') return;
  const id = setInterval(() => setTick((t) => t + 1), 2000);
  return () => clearInterval(id);
}, [cameraOpen, tab]);
// Deliberately NOT gated on pipActive. It was, and a pipActive that never cleared froze this tile
// on a cached frame — the URL only changes with `tick`, so pausing the poller pauses the picture.
const snapshotUri = camToken && !cameraOpen ? `${client.snapshotUrl(printerId, camToken)}&_t=${tick}` : null;
```
1 frame / **2 s**; paused while the fullscreen stream is open (one on-demand camera) and while the dashboard tab is hidden (it stays mounted, so the interval would otherwise poll unseen). The `&_t=${tick}` suffix is the cache-buster — that is the only thing that makes the `<Image>` refetch.

**Maintenance rollup poller** (scoped to the selected printer):
```tsx
useEffect(() => {
  setMaintAlert({ due: 0, warn: 0 });              // reset on printer switch
  const poll = () => client.getMaintenance(printerId)
    .then((m) => setMaintAlert({ due: m.due_count, warn: m.warning_count })).catch(() => {});
  poll();
  const id = setInterval(poll, 60000);
  return () => clearInterval(id);
}, [client, printerId]);
```
`GET /api/v1/maintenance/printers/{printerId}`, every **60 s**.

---

### 11. Inbound file import (share sheet / "Open in")

```tsx
const importingRef = useRef(false);
useEffect(() => {
  let handledInitial = false;
  const handleUrl = async (url: string | null) => {
    if (!url || importingRef.current) return;
    if (!url.startsWith('file://') && !url.startsWith('content://')) return; // ignore our own bambu:// links
    try {
      importingRef.current = true;
      const src = new File(url);
      const name = src.name || `import-${Date.now()}.3mf`;
      const dest = new File(Paths.cache, name);
      if (dest.exists) dest.delete();
      src.copy(dest);
      await client.uploadFile(dest.uri, name);
      setLibKey((k) => k + 1);
      setTab('library');
      Alert.alert('Added to library', name);
    } catch (e) { Alert.alert('Couldn’t import file', String(e)); }
    finally { importingRef.current = false; }
  };
  Linking.getInitialURL().then((url) => { handledInitial = true; void handleUrl(url); });
  const sub = Linking.addEventListener('url', ({ url }) => { if (handledInitial) void handleUrl(url); });
  return () => sub.remove();
}, [client]);
```

Gotchas: *"The SceneDelegate forwards `openURLContexts`, so expo-linking sees it"* — the UIScene config plugin is load-bearing for this feature. The `handledInitial` flag prevents double-handling the cold-launch URL. `importingRef` is a re-entrancy lock. The `file://`/`content://` prefix check exists so the app's own `bambu://` deep links don't get treated as imports.

`uploadFile` is `POST /api/v1/library/files`, multipart field name `file`, mime `application/octet-stream`, headers = `X-API-Key`. It uses **`expo-file-system`'s native `File.upload`, not `fetch`** — *"Expo's WinterCG fetch rejects RN's `{uri,name,type}` FormData parts ('Unsupported FormDataPart implementation')"*.

---

### 12. THE HANDLERS OBJECT (`DashHandlers`) — every one, exhaustively

```ts
export interface DashHandlers {
  onSettings: () => void; onCamera: () => void; onPauseResume: () => void; onStop: () => void;
  onLight: () => void; onSpeedSet: (i: number) => void; onSelectPrinter: (id: number) => void;
  onAlerts: () => void; onPlateCleared: () => void; onPrintAgain: () => void;
  onRetry: () => void; onTab: (tab: string) => void;
}
```

| handler | body | endpoint | guard | failure alert |
|---|---|---|---|---|
| `onSettings` | `router.push('/settings')` | — | — | — |
| `onCamera` | `setOverlay('camera')` | — | — | — |
| `onRetry` | `onRetry` prop → `setReload(r=>r+1)` → full `Shell` remount + config re-read | — | — | — |
| `onTab` | `setTab(t as TabKey)` | — | — | — |
| `onSelectPrinter` | `selectPrinter(id)` → `setPrinterId` + `patchConfig({printerId, printerName})` | — | — | — |
| `onLight` | `client.setLight(printerId, !vm.lightOn)` | `POST /api/v1/printers/{id}/chamber-light?on={bool}` | **none** (not a `print` command) | `Alert('Light failed', String(e))` |
| `onPauseResume` | `guard(vm.isPaused ? 'resume' : 'pause', () => vm.isPaused ? client.resume(id) : client.pause(id))` | `POST …/print/resume` \| `POST …/print/pause` | **guarded** | `Alert('Action failed', String(e))` |
| `onStop` | confirm dialog **first**, then `client.stop(printerId)` | `POST /api/v1/printers/{id}/print/stop` | **deliberately NOT guarded** — *"A dead Stop on a failing print is worse than one that might not land."* | `Alert('Stop failed', String(e))` |
| `onSpeedSet(i)` | inline `isBlocked('speed', lanMode)` check → alert & return; else `setSpeedOverride(mode)`, `client.setSpeed(id, mode as 1\|2\|3\|4)`; on failure `setSpeedOverride(null)` (**roll back the optimistic label**) | `POST /api/v1/printers/{id}/print-speed?mode={1-4}` | **inline guard** (not via `guard()` because it takes an argument) | `Alert('Speed failed', String(e))` |
| `onAlerts` | `setAlertsOpen(true)` | — | — | — |
| `onPlateCleared` | `client.clearPlate(id)` then success alert | `POST /api/v1/printers/{id}/clear-plate` | none (Bambuddy bookkeeping, no MQTT) | `Alert('Couldn’t confirm the plate', apiErrorDetail(e))` |
| `onPrintAgain` | if `status.current_archive_id == null` → `setTab('library')` and return; else confirm, then `client.reprint(archiveId, printerId)` → `setTab('jobs')` | `POST /api/v1/queue/` with `{printer_id, archive_id, use_ams: true}` (via `enqueue`) | none | `Alert('Couldn’t reprint', String(e))` |

Exact dialog copy:
- **Stop**: title `'Stop print?'`, body `'This cancels the current job. It can’t be undone.'`, buttons `[{'Keep printing', cancel}, {'Stop', destructive}]`.
- **Print again**: title `'Print this again?'`, body `'The finished job goes back into the queue.'`, buttons `[{'Cancel', cancel}, {'Print again'}]`.
- **Plate cleared success**: title `'Plate confirmed clear'`, body `'The next queued job can start.'`.
- **Blocked action**: title `'Printer controls are locked'`, body = `LAN_BLOCKED_HINT`.

Note the endpoint gotcha in `reprint`: *"POST /archives/{id}/reprint is GONE — Bambuddy answers 410 with 'Direct archive reprint has been removed. Create a print queue item with POST /queue/.'"*
And in `clearPlate`: *"This is NOT queueResume — that clears the previous-FAILURE gate and restores skipped items… Sends no MQTT, so it works without LAN Developer Mode."*

`apiErrorDetail(e)` extracts the API's JSON `detail`: `String(e).match(/\{"detail"\s*:\s*"([^"]+)"/)?.[1] ?? String(e)`.

---

### 13. `runAlertAction(a: AlertVM, act: AlertActionVM)`

```tsx
const run = () => {
  if (act.id === 'resume')       return client.resume(printerId).catch(e => Alert.alert('Couldn’t resume', apiErrorDetail(e)));
  if (act.id === 'stop')         return client.stop(printerId).catch(e => Alert.alert('Couldn’t stop', apiErrorDetail(e)));
  if (act.id === 'clearHms')     return client.clearHms(printerId).catch(e => Alert.alert('Couldn’t clear', apiErrorDetail(e)));
  if (act.id === 'plateCleared') return client.clearPlate(printerId)
      .then(() => Alert.alert('Plate confirmed clear', 'The next queued job can start.'))
      .catch(e => Alert.alert('Couldn’t confirm the plate', apiErrorDetail(e)));
  if (act.id === 'lookup' && act.urls?.length) {
    // The wiki is per model FAMILY and each family has its own code namespace, so the right page
    // can't be known from the code alone. Walk the candidates (this machine's family first) and
    // open the first that actually resolves; the last entry is the searchable index, which always
    // does. Without this a tap landed on a 404 — the reported "fatal is not found".
    const open = async () => {
      const candidates = act.urls!;
      for (const url of candidates.slice(0, -1)) {
        try { const r = await fetch(url, { method: 'HEAD' }); if (r.ok) return void Linking.openURL(url).catch(() => {}); }
        catch { /* offline/blocked — stop probing and use the index */ break; }
      }
      await Linking.openURL(candidates[candidates.length - 1]).catch(() => {});
    };
    return void open();
  }
  return undefined;
};
if (!act.destructive) return void run();
Alert.alert(`${act.label}?`, `${a.title} — this can’t be undone.`, [
  { text: 'Cancel', style: 'cancel' },
  { text: act.label, style: 'destructive', onPress: () => void run() },
]);
```

`clearHms` = `POST /api/v1/printers/{id}/hms/clear`. The **HEAD-probe walk** is a hard-won fix and must be ported exactly: candidate URLs are ordered most-likely-first, the last is always the searchable index, and a network error aborts probing (does not skip to the next candidate).

---

### 14. Render tree + mount-vs-hide gotchas

```tsx
<View style={{ flex: 1, backgroundColor: c.bg }}>
  {/* The live dashboard is a dense tree of looping reanimated animations. Unmounting it
      mid-flight on a tab switch hits a reanimated-4 New-Arch teardown race (upstream #9402 /
      #9293: crash or whole-app freeze), so it stays mounted and is HIDDEN instead. */}
  <View style={{ flex: 1, display: tab === 'printer' ? 'flex' : 'none' }}>
    <DashboardView vm alerts snapshotUri h={handlers} maintAlert speedIdx printer fleet cooldown lanMode />
  </View>
  {tab !== 'printer' && (
    <FadeRise key={tab} dy={8} duration={300} style={{ flex: 1 }}>
      {tab === 'library' && <LibraryView key={libKey} client texClient camToken printerId plate={profile.plate}
        onUpload={() => setOverlay('upload')} onPick={setWizardFile}
        onTexturize={texClient ? setTexturizeFile : undefined} onView3D={openStl} />}
      {tab === 'jobs'   && <JobsView client status printerId printers={printers ?? []} camToken
        onBrowse={() => setTab('library')} lanMode />}
      {tab === 'ams'    && <AmsView client status printerId amsLabel={profile.amsLabel} lanMode />}
      {tab === 'power'  && <PowerView client printerId status />}
    </FadeRise>
  )}

  <TabBar active={tab} onTab={setTab} />

  {/* Stays MOUNTED while Picture-in-Picture is up, merely hidden: unmounting it would tear down
      the AVSampleBufferDisplayLayer and take the floating window with it. */}
  {(overlay === 'camera' || pipActive) && (
    <View style={{ position:'absolute', inset:0, zIndex:70, display: overlay === 'camera' ? 'flex' : 'none' }}
          pointerEvents={overlay === 'camera' ? 'auto' : 'none'}>
      <CameraOverlay streamUrl snapshotUrl={camToken ? client.snapshotUrl(printerId, camToken) : null}
        status cameraHint={profile.cameraHint} onClose={() => setOverlay(null)}
        onRefresh={remint} onPipChange={setPipActive} />
    </View>
  )}
  {overlay === 'upload'      && <UploadSheet client onClose={() => setOverlay(null)} onUploaded={() => setLibKey(k => k + 1)} />}
  {texturizeFile && texClient && <TexturizeSheet texClient file onClose={() => setTexturizeFile(null)} onDone={() => setLibKey(k => k + 1)} />}
  {alertsOpen && <AlertsOverlay alerts onAction={runAlertAction} onClose={() => setAlertsOpen(false)} />}
  {viewStl && <StlViewerOverlay client fileId name onClose={() => setViewStl(null)} />}
  {wizardFile && <WizardOverlay lanMode client file={wizardFile} camToken status printerId printer
    onClose={() => setWizardFile(null)}
    onStarted={() => { setWizardFile(null); setTab('printer'); }}
    onTexturize={texClient ? (f) => { setWizardFile(null); setTexturizeFile(f); } : undefined}
    onView3D={openStl} />}
</View>
```

Overlay z-order (later in tree = on top): camera (explicit `zIndex: 70`) → upload sheet → texturize sheet → alerts → **STL viewer** → wizard. *"Fullscreen interactive STL viewer (renders ABOVE the texturize sheet so 'View in 3D' from the done state returns to the sheet on close, keeping the tweak → re-run loop intact)."*

Tab transition: `FadeRise key={tab} dy={8} duration={300}` — opacity 0→1 and `translateY (1-t)*8`, easing `cubic-bezier(0.22, 1, 0.36, 1)`. The `key={tab}` restarts it on every tab change. The printer tab has **no** entrance animation (it never unmounts).

---

### 15. Onboarding / Settings — `src/app/settings.tsx`

Constant: `const DEFAULT_URL = 'https://bambuddy.example.com';` (also the URL field placeholder).

**Screen state:** `baseUrl` (init `DEFAULT_URL`), `apiKey` (`''`), `hasConfig`, `editing`, `saving`, `printerName`, `pushUrl`, `serverPush` (default `true`), `texturizeUrl`, `texturize` (default `true`), `adminUser`, `adminPw`, `error`.

**Mount effect:** `getConfig()` → if a config exists, hydrate all fields and `setHasConfig(true)`; else `setEditing(true)` (*"first run — go straight to the form"*).

So the screen has two modes: **form** (`editing === true`) and **read-only summary** (`editing === false`, only reachable when `hasConfig`).

**Validation** — `src/config/sanitize.ts`, kept import-free so it stays jest-testable:
```ts
export function sanitizeBaseUrl(raw) { return raw.trim().replace(/\s+/g, '').replace(/\/+$/, ''); }
export function sanitizeApiKey(raw)  { return raw.trim().replace(/^[^A-Za-z0-9_-]+/, '').replace(/[^A-Za-z0-9_-]+$/, ''); }
const KEY_RE = /^bb_[A-Za-z0-9_-]{6,}$/;
export function isValidApiKey(raw)   { return KEY_RE.test(sanitizeApiKey(raw)); }
```
`const canSave = sanitizeBaseUrl(baseUrl).length > 0 && isValidApiKey(apiKey);`

**Gotcha (comment):** API keys are `bb_` + base64url. Pasting often appends a stray trailing char — whitespace, newline, or `%` (zsh's no-newline EOL marker / URL-encode artifact). Only *leading and trailing* non-key chars are stripped; interior characters are never touched. **The sanitizer charset MUST match `KEY_RE`** — *"an earlier mismatch — sanitize kept `_` but the validator only accepted `[A-Za-z0-9]` — left Connect greyed out for any key containing `_`/`-`, despite the field being filled."*

**Save flow (`save`)** — the pre-flight is the point:
```tsx
setError(null); setSaving(true);
const url = sanitizeBaseUrl(baseUrl); const key = sanitizeApiKey(apiKey);
const aUser = adminUser.trim(); const aPw = adminPw;
try {
  // Pre-flight: actually reach the server with the entered URL+key before persisting, so a wrong
  // host or a rejected key surfaces here instead of as a silent, eternal "Connecting" dashboard.
  const probeClient = new BambuddyClient({ baseUrl: url, apiKey: key, adminUsername: aUser || undefined, adminPassword: aPw || undefined });
  const fleet = await probeClient.probe();                       // GET /api/v1/printers/, 8s AbortController
  // Same pre-flight for the optional admin login — a typo'd password should fail HERE, not later
  // on the first "mark done".
  if (aUser && aPw) await probeClient.verifyAdminLogin();        // POST /api/v1/auth/login
  const cur = await getConfig();
  // Auto-select a real printer from the fleet (keep the current one if it still exists) … Spread
  // `cur` so editing the connection doesn't wipe the camera token.
  const keepId = cur?.printerId != null && fleet.some(p => p.id === cur.printerId) ? cur.printerId : fleet[0]?.id;
  const keepName = fleet.find(p => p.id === keepId)?.name ?? cur?.printerName;
  await setConfig({ ...cur, baseUrl: url, apiKey: key,
    pushUrl: pushUrl.trim() || undefined, serverPush,
    texturizeUrl: texturizeUrl.trim() || undefined, texturize,
    adminUsername: aUser || undefined, adminPassword: aPw || undefined,
    theme: cur?.theme ?? theme, printerId: keepId ?? cur?.printerId, printerName: keepName });
  setSaving(false);
  if (hasConfig) setEditing(false); else router.replace('/');
} catch (e) {
  setSaving(false);
  // Admin-login failures carry their own actionable message — classifyConnectError would misread
  // their HTTP 401 as "API key rejected".
  const msg = e instanceof Error && e.message.startsWith('Admin login failed') ? e.message : classifyConnectError(e).message;
  setError(msg);
}
```

`probe(timeoutMs = 8000)` wraps `GET /api/v1/printers/` in an `AbortController` + `setTimeout`, *"so a wrong/dead host fails fast instead of hanging the Connect button."*

**`classifyConnectError`** — the exact user-facing strings (the whole point is separating server-unreachable from key-rejected):

| condition | kind | message |
|---|---|---|
| `err.name === 'AbortError'` or `/\babort/i` | `timeout` | "Timed out reaching the server. Check the URL, and that your phone can actually reach that host (same Wi‑Fi / VPN)." |
| `HTTP 401` / `403` | `auth` | "Server reached, but the API key was rejected (HTTP {code}). Double-check the key." |
| `HTTP 404` | `notFound` | "Reached that host, but it doesn't respond like a Bambuddy server (HTTP 404). Check the URL." |
| `HTTP >= 500` | `server` | "The Bambuddy server returned an error (HTTP {code}). It may be down or restarting." |
| other HTTP | `unknown` | "Unexpected response from the server (HTTP {code})." |
| `TypeError` or `/network request failed\|failed to fetch\|econnrefused\|enotfound\|getaddrinfo\|certificate\|ssl\|tls\|handshake/i` | `network` | "Can't reach that URL. Check the scheme (https), host/port, your network, and that the server's TLS certificate is trusted by the phone." |
| else | `unknown` | raw message |

Note the timeout message contains a **non-breaking hyphen** in "Wi‑Fi" (U+2011).

**Form fields, in order:**

1. *(first run only)* intro copy: "Point the app at your Bambuddy server and paste the app API key. Both are stored only in this device's Keychain." (`c.t2`, 14px, lineHeight 20, marginBottom 20)
2. **`BAMBUDDY URL`** label → `TextInput` `autoCapitalize="none" autoCorrect={false} keyboardType="url"`, placeholder = `DEFAULT_URL`.
3. **`API KEY`** label → `TextInput` `autoCapitalize="none" autoCorrect={false} spellCheck={false} autoComplete="off" textContentType="none"`, placeholder `bb_…`. **CRITICAL comment:** *"Plain (NON-secure) field on purpose. `secureTextEntry` made iOS treat this as a password/OTP field and hijack it with AutoFill: pasted text didn't fire `onChangeText` (Connect stayed grey) and delete wiped the whole value as one autofilled chunk. `textContentType="none"` + `autoComplete="off"` + no `secureTextEntry` disables all of that so paste/edit behave normally. The key is visible while typing (you're pasting your own key on your own device); it's stored in the Keychain."*
4. **Background push** row (title 14/600 `c.t1`; subtitle 11.5/500 `c.t3` lineHeight 16) + `Toggle`. Subtitle when on: *"Lock-screen Live Activities keep updating after the app closes, plus print-done / error alerts. Needs a Trellis server."* When off: *"Live Activities update only while the app is open — no lock-screen alerts, no server needed."*
5. *(if `serverPush`)* **`PUSH SERVER (Trellis)`** field, placeholder = `resolvePushUrl({ baseUrl: sanitizeBaseUrl(baseUrl) }) ?? 'https://lapush.your-host…'` (i.e. the live-derived URL as the placeholder). Helper: *"Your own Trellis URL. Leave blank to derive it from the Bambuddy host (bambuddy.→lapush.); set it if Trellis runs elsewhere."*
6. **Model texturizer** row + `Toggle`. On: *"Bake surface patterns onto STLs and restyle library previews. Needs the stl-texturize sidecar."* Off: *"Off — no texturize actions; library previews come straight from Bambuddy."*
7. *(if `texturize`)* **`TEXTURIZE SERVER`** field, placeholder = `resolveTexturizeUrl({ baseUrl: sanitizeBaseUrl(baseUrl) }) ?? 'https://texturize.your-host…'`. Helper: *"…(bambuddy.→texturize.); the app checks its health before enabling."*
8. **`ADMIN LOGIN (OPTIONAL)`** label + explanation: *"Unlocks admin actions like marking maintenance done — Bambuddy doesn't allow API keys for those. Stored only in the Keychain."* Two fields: `admin username`, `admin password` (`marginTop: 10`). **Both are plain fields** — same AutoFill-avoidance flags (`autoComplete="off" textContentType="none"`, no `secureTextEntry`), so the admin password is visible while typing.
9. **Error box** (if `error`): `marginTop:20 padding:13 borderRadius:12 bg:c.s2 borderWidth:1 borderColor:c.error`, text `c.error` 13/500 lineHeight 18.
10. **Buttons row** (`gap:12 marginTop:24`): `Cancel` (only when `hasConfig`; `paddingHorizontal:22 height:54 radius:16 bg:c.s3`) and the primary — `flex:1 height:54 radius:16`, background `canSave ? c.accent : c.s3`, text `canSave ? c.accentInk : c.t3`, 16/700, label = `saving ? 'Connecting…' : hasConfig ? 'Save' : 'Connect'`, `disabled={!canSave || saving}`.

**Shared field style:**
```ts
{ backgroundColor: c.s2, borderWidth: 1, borderColor: c.line, borderRadius: 12,
  paddingHorizontal: 14, paddingVertical: 13, color: c.t1, fontSize: 14, fontFamily: mono }
```
Section labels: 11px / weight 600 / `c.t3` / `letterSpacing: 1` / `fontFamily: mono` / marginBottom 9 (18 top when following a field).

**Read-only summary mode:**
- Header: title `hasConfig ? 'Settings' : 'Connect'`, 30px/700, `letterSpacing: -0.8`; close button (38×38 circle, `c.s2`, Feather `x` 20px `c.t2`, `hitSlop 12`) → `router.back()`.
- `Section` component: title label + card (`borderRadius:16 bg:c.s1 border 1 c.line overflow:hidden`), `marginTop: 24`.
- `Row` component: `flexDirection:row justify:space-between gap:12 px:16 py:14`, `borderBottomWidth: last ? 0 : 1` `c.line`; label 13/500 `c.t2 flexShrink:0`; value 13/600 mono, color `valueColor ?? c.t1`, `numberOfLines={1}`.
- **CONNECTION** section: status dot row (8×8 circle `c.running` with `shadowColor: c.running, shadowOpacity: 0.8, shadowRadius: 6`), label `Configured`, plus an `Edit` affordance (Feather `edit-2` 13px + text, `c.accent`) → `setEditing(true)`. Then rows:
  - `Server` → `hostOf(baseUrl)` where `hostOf(url) = url.replace(/^https?:\/\//,'').replace(/\/.*$/,'')`
  - `API key` → `maskKey(apiKey)`: `''` → `'—'`; `length > 9` → `` `${key.slice(0,5)}••••${key.slice(-4)}` ``; else the raw key.
  - `Admin login` → `adminUser && adminPw ? adminUser : 'Off'`
  - `Live Activities` → `pushLabel` = `!serverPush ? 'Local only' : effPush ? \`Server · ${hostOf(effPush)}\` : 'Server (set a URL)'`
  - `Texturizer` (last) → `texLabel` = `!texturize ? 'Off' : effTex ? hostOf(effTex) : 'Off (no URL)'`
- **APPEARANCE**: a 2-segment control, container `flexDirection:row gap:4 padding:4 borderRadius:13 bg:c.s2`; each segment `flex:1 height:40 borderRadius:10`, background `on ? c.s4 : 'transparent'`, text 14/600 `on ? c.t1 : c.t2`. Labels `Dark` / `Light`. Tap → `pickTheme(name)` = `setTheme(name); void patchConfig({ theme: name })` — **applies instantly and persists**, no save needed.
- **ABOUT**:
  - `App version` → `Constants.expoConfig?.version ?? '1.0.0'`
  - `Update` → `Updates.updateId ? Updates.updateId.slice(0, 8) : 'embedded'`. Comment: *"Which JS bundle is actually running: the OTA update id (short), or the build's embedded bundle. This is the ground truth for 'did the OTA land?' confusion."*
  - `Printer` (last) → `printerName ?? '—'`
- **Sign out** button: `marginTop:24 height:50 radius:14 borderWidth:1 borderColor:c.line2`, text `c.error` 15/600, label `Sign out · clear key` → `await clearConfig(); router.replace('/settings');`

**Screen chrome:** `SafeAreaView(flex:1, bg c.bg)` → `KeyboardAvoidingView(behavior: iOS 'padding')` → `ScrollView(contentContainerStyle:{padding:24, paddingBottom:48}, keyboardShouldPersistTaps:'handled', showsVerticalScrollIndicator:false)`.

---

### 16. Keychain — `src/config/secureConfig.ts`

**One Keychain item holds the entire config as JSON.**

```ts
const KEY = 'bambu.config';
const OPTS: SecureStore.SecureStoreOptions = {
  keychainAccessible: SecureStore.WHEN_UNLOCKED_THIS_DEVICE_ONLY,
};
```

- `getConfig()` → `SecureStore.getItemAsync('bambu.config', OPTS)`; `null` if absent; `JSON.parse` inside `try/catch` returning `null` on corrupt JSON.
- `setConfig(c)` → `setItemAsync('bambu.config', JSON.stringify(c), OPTS)`.
- `patchConfig(partial)` → read-modify-write; **no-op if nothing is stored yet** (`if (!cur) return;`).
- `clearConfig()` → `deleteItemAsync('bambu.config', OPTS)`.

`AppConfig` fields (all optional except the first two):

| field | type | notes |
|---|---|---|
| `baseUrl` | `string` | e.g. `https://bambuddy.example.com` |
| `apiKey` | `string` | scoped `bb_…` key, sent as `X-API-Key` |
| `cameraToken` | `string?` | long-lived camera stream token, minted lazily. Read at Shell init; **never written back** by the Shell (the mint effect only sets React state) — persistence happens only if some other path writes it. Seeded from here on cold start so the first snapshot can render before the mint round-trips. |
| `theme` | `'dark'\|'light'?` | defaults to `dark` |
| `printerId` | `number?` | last-selected printer, restored on launch |
| `printerName` | `string?` | for the Settings "Printer" row |
| `pushUrl` | `string?` | blank ⇒ derived `bambuddy.` → `lapush.` |
| `serverPush` | `boolean?` | `true`/`undefined` ⇒ SERVER mode; `false` ⇒ LOCAL only |
| `texturizeUrl` | `string?` | blank ⇒ derived `bambuddy.` → `texturize.` |
| `texturize` | `boolean?` | `true`/`undefined` ⇒ enabled (then health-probed) |
| `adminUsername` | `string?` | optional Bambuddy admin login |
| `adminPassword` | `string?` | stored in plaintext inside the Keychain blob |

Secrets stored: API key, admin password, camera token. **Accessibility class `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`** — no iCloud Keychain sync, no backup restore to another device.

---

### 17. THE COMPLETE THEME — `src/theme.ts`

Source of truth: `docs/design/Bambu.dc.html` (Claude Design). `type Palette = typeof dark` — light **must** have every key.

| token | dark | light | purpose |
|---|---|---|---|
| `bg` | `#0A0B0C` | `#EFF1F3` | app background |
| `s1` | `#131517` | `#FFFFFF` | surface 1 (cards, tab bar fill) |
| `s2` | `#191C1F` | `#F5F6F8` | surface 2 (fields, chips) |
| `s3` | `#23272B` | `#EAECEF` | surface 3 (secondary buttons, toggle-off) |
| `s4` | `#2D3237` | `#DEE1E5` | surface 4 (selected segment) |
| `line` | `rgba(255,255,255,0.07)` | `rgba(0,0,0,0.08)` | hairline |
| `line2` | `rgba(255,255,255,0.12)` | `rgba(0,0,0,0.13)` | stronger hairline |
| `t1` | `#F3F5F7` | `#0D1012` | primary text |
| `t2` | `#A4ABB2` | `#585E64` | secondary text |
| `t3` | `#6B7177` | `#878D94` | tertiary text / placeholders / inactive icons |
| `accent` | `#2BD4C0` | `#0EAE9C` | brand teal |
| `accentInk` | `#04201D` | `#FFFFFF` | text **on** accent |
| `accentDim` | `rgba(43,212,192,0.15)` | `rgba(14,174,156,0.14)` | accent wash |
| `running` | `#30D158` | `#23B24A` | printing / OK |
| `runningDim` | `rgba(48,209,88,0.15)` | `rgba(35,178,74,0.14)` | |
| `heating` | `#FF9F0A` | `#E0860A` | heating / warning |
| `heatingDim` | `rgba(255,159,10,0.15)` | `rgba(224,134,10,0.14)` | |
| `paused` | `#0A84FF` | `#0A84FF` | paused (identical in both) |
| `pausedDim` | `rgba(10,132,255,0.15)` | `rgba(10,132,255,0.12)` | |
| `error` | `#FF453A` | `#E5392E` | error / destructive |
| `errorDim` | `rgba(255,69,58,0.15)` | `rgba(229,57,46,0.12)` | |
| `idle` | `#8E9398` | `#9AA0A6` | idle / offline |
| `idleDim` | `rgba(142,147,152,0.14)` | `rgba(154,160,166,0.14)` | |
| `sheet` | `#16181B` | `#FFFFFF` | bottom-sheet background |
| `tabbar` | `rgba(13,14,16,0.72)` | `rgba(244,246,248,0.8)` | translucent tab-bar (note: `TabBar.tsx` currently uses `c.s1`, not this token) |
| `thumb` | `#0e1113` | `#E4E7EA` | neutral well behind thumbnails / camera tiles |
| `supports` | `#E8A23D` | `#C77E14` | supports accent (matches the layer-view support color) |
| `swatchRing` | `#8E9398` | `#6E7378` | ring around filament colour swatches |

**`swatchRing` gotcha (verbatim):** *"Ring drawn around every filament colour swatch. Its job is to separate the swatch from the CARD it sits on, so it is chosen for contrast against the SURFACES, not against the fill — a white spool on a white card was invisible. >= 3:1 vs bg/s1/s2/s3/s4/sheet (min 4.18 vs s4 here). `c.line2` is only ~1.4:1, which is why swatches that already had a hairline still disappeared."* Light-theme minimum is 3.65:1 (vs s4).

**The live-token mechanism** (this is the whole theming architecture):
```ts
export const c: Palette = { ...dark };
let _name: ThemeName = 'dark';
const listeners = new Set<() => void>();
export function setTheme(name: ThemeName): void {
  _name = name;
  Object.assign(c, themes[name]);   // MUTATE in place — every captured reference sees the new value
  listeners.forEach((l) => l());
}
export function getThemeName(): ThemeName { return _name; }
export function useTheme(): ThemeName { return useSyncExternalStore(subscribe, getThemeName, getThemeName); }
```
*"Components read `c.<token>` INLINE at render, so reassigning its properties and notifying subscribers re-themes the whole tree without a context or per-component refactor. Call `useTheme()` at the app root(s) so they re-render when `setTheme()` fires."* Consequence: **any code that captures a color value into a module constant goes stale on theme switch** — `DashboardView`'s `SPEEDS` table stores palette *keys* (`dot: keyof Palette`) resolved at render for exactly this reason.

**Fonts:**
```ts
export const mono = Platform.select({ ios: 'Menlo', default: 'monospace' });
```
Everything else uses the system font at explicit numeric weights (`'500' | '600' | '700'`). `mono` is used for: section labels, all `Row` values, and all `TextInput` field text.

**Shadow:**
```ts
export const shadow1 = { shadowColor: '#000', shadowOpacity: 0.5, shadowRadius: 2, shadowOffset: { width: 0, height: 1 } } as const;
```
One inline shadow exists outside this: the Settings "Configured" status dot (`shadowColor: c.running, shadowOpacity: 0.8, shadowRadius: 6`).

**Motion constants** (`src/components/anim/index.tsx`), needed for parity:
- `SPRING = Easing.bezier(0.34, 1.56, 0.64, 1)` — the design's signature springy ease (overshoots).
- `ROLL_EASE = Easing.bezier(0.3, 1.1, 0.5, 1)` (digit roll), `RISE_EASE = Easing.bezier(0.22, 1, 0.36, 1)` (entrances).
- `Tap`: press-in scale → `0.955`, opacity → `0.62`, in `90 ms` `Easing.out(Easing.quad)`; release back over `170 ms` `SPRING`. **`useEffect(() => () => cancelAnimation(p), [p])`** — *"Cancel a mid-press animation on unmount — flushing updates for a view being torn down is the reanimated-4 New-Arch crash/freeze race (swmansion/react-native-reanimated#9402)."*
- `Toggle`: 48×30 track, radius 15; knob 24×24 radius 12 `#fff`, `translateX = 3 + p*21`; `240 ms` `SPRING`; track color interpolated `c.s3` → `c.accent`; disabled opacity `0.4`.
- `FadeRise`: defaults `dy: 11, duration: 340`; the Shell overrides to `dy: 8, duration: 300`.

---

### 18. `app.json` — native configuration

```
expo.name              "Bambu"
expo.slug              "bambu"
expo.version           "1.0.0"        ← DO NOT BUMP (runtimeVersion policy = appVersion; orphans OTA updates)
expo.orientation       "portrait"
expo.scheme            "bambu"
expo.userInterfaceStyle "automatic"
expo.icon              "./assets/icon-bambu.png"
```

**iOS:**
| key | value |
|---|---|
| `ios.bundleIdentifier` | `com.example.sprout` |
| `ios.appleTeamId` | `<TEAM_ID>` (required — `expo prebuild` does not write a team; the app *and* the widget extension both need it for automatic signing) |
| `ios.buildNumber` | `"6"` (bump this only) |
| `ios.icon` | `./assets/Bambu.icon` (Icon Composer `.icon` bundle — Liquid Glass) |
| `ios.supportsTablet` | `false` |
| `ios.runtimeVersion` | `{ "policy": "appVersion" }` |

**`ios.entitlements`** (declared): `com.apple.developer.usernotifications.time-sensitive: true`.
**Generated `Bambu.entitlements` (full, incl. plugin-added):**
```xml
aps-environment = development
com.apple.developer.usernotifications.time-sensitive = true
com.apple.security.application-groups = [ group.com.example.sprout ]
```

**`ios.infoPlist` (declared):**
- `ITSAppUsesNonExemptEncryption: false`
- `LSSupportsOpeningDocumentsInPlace: false` — imports are **copies**, never in-place edits.
- `CFBundleDisplayName: "Sprout"` — **the home-screen name is "Sprout", not "Bambu"**.
- `UIBackgroundModes: ["audio"]` — *the only background mode*; it exists to keep the **MJPEG camera / PiP** alive in the background, not for audio playback.
- `CFBundleDocumentTypes` (4): `3MF Model` (Owner, `com.bambulab.3mf`), `Bambu Sliced 3MF` (Owner, `com.bambulab.gcode-3mf`), `G-code` (Owner, `com.bambulab.gcode`), `STL Model` (**Alternate**, `public.standard-tesselated-geometry-format`).
- `UTImportedTypeDeclarations` (3):
  - `com.bambulab.3mf` — conforms to `public.data`, `public.zip-archive`; ext `3mf`; mime `model/3mf`, `application/vnd.ms-package.3dmanufacturing-3dmodel+xml`
  - `com.bambulab.gcode-3mf` — conforms to `com.bambulab.3mf`; ext `gcode.3mf`
  - `com.bambulab.gcode` — conforms to `public.text`, `public.data`; ext `gcode`; mime `text/x.gcode`

**Additional keys in the *generated* `ios/Bambu/Info.plist`** (from Expo + plugins — needed for a faithful native rebuild):
```
NSSupportsLiveActivities            = true
NSSupportsLiveActivitiesFrequentUpdates = true
ExpoWidgets_EnablePushNotifications = true
ExpoWidgetsAppGroupIdentifier       = group.com.example.sprout
NSAppTransportSecurity              = { NSAllowsArbitraryLoads: false, NSAllowsLocalNetworking: true }
NSFaceIDUsageDescription            = "Allow $(PRODUCT_NAME) to access your Face ID biometric data."   (expo-secure-store boilerplate; unused)
CFBundleURLTypes                    = [{ CFBundleURLSchemes: ["bambu", "com.example.sprout"] }]
UISupportedInterfaceOrientations    = [Portrait, PortraitUpsideDown]
UIRequiresFullScreen                = false
UIUserInterfaceStyle                = Automatic
UIViewControllerBasedStatusBarAppearance = false
CADisableMinimumFrameDurationOnPhone = true    (allows ProMotion 120 Hz)
RCTNewArchEnabled                   = true
UIApplicationSceneManifest          = { UIApplicationSupportsMultipleScenes: false,
                                        UISceneConfigurations: { UIWindowSceneSessionRoleApplication:
                                          [{ UISceneConfigurationName: "Default Configuration",
                                             UISceneDelegateClassName: "$(PRODUCT_MODULE_NAME).SceneDelegate" }] } }
```
**There are NO camera / photo-library / microphone / location usage descriptions** — the app never touches device hardware. The "camera" is entirely a remote MJPEG stream.

**Plugins** (order matters):
`expo-router`, `["expo-splash-screen", { backgroundColor: "#208AEF", android: {...} }]`, `expo-secure-store`, `expo-image`, `./plugins/withIosSceneLifecycle`, `["expo-build-properties", { ios: { deploymentTarget: "16.4" } }]`, `./plugins/withIosPodMinDeploymentTarget`, `["expo-widgets", { bundleIdentifier: "com.example.sprout.LiveActivity", groupIdentifier: "group.com.example.sprout", enablePushNotifications: true, frequentUpdates: true, widgets: [] }]`, `expo-video`.

**Updates:** channel `production`, `updates.url = https://u.expo.dev/<EAS_PROJECT_ID>`, `runtimeVersion.policy = "appVersion"`.
**Experiments:** `typedRoutes: true`, `reactCompiler: false`.

**Deployment target: iOS 16.4** (`expo-build-properties` + the `withIosPodMinDeploymentTarget` plugin that force-bumps every Pod target, because `expo-build-properties` doesn't override podspec-pinned lower targets and Xcode 27 rejects pods below 15.0).

**`withIosSceneLifecycle` gotcha:** iOS 27 hard-enforces the UIScene lifecycle. The SDK 56 template `AppDelegate.swift` creates the window inside `didFinishLaunchingWithOptions`, which iOS 27 terminates on launch with `EXC_BREAKPOINT` in `_UIApplicationEvaluateRuntimeIssueForNoSceneLifecycleAdoption` (white screen, then crash). The plugin rewrites `AppDelegate.swift` to vend a `UISceneConfiguration` and adds a `SceneDelegate` that owns the window and starts React Native into it, plus writes `UIApplicationSceneManifest`. The transform is pure + unit-tested and **throws loudly** if the template shape changes. **This SceneDelegate is also what forwards `openURLContexts`** — the inbound-file import in §11 depends on it.

---

### Port notes

**Config gate → SwiftUI**
- `AppScreen`'s tri-state maps to an `enum ConfigState { case loading, none, loaded(AppConfig) }` in an `@Observable` `AppModel`, switched on in the root `View`. Keep the *blank `Color(bg)` on `.loading`* — no `ProgressView`, the read is sub-frame fast and a spinner flashes.
- `useFocusEffect` re-read has no direct analogue. Since Settings becomes a `.sheet`, use its `onDismiss:` closure to re-read the Keychain — that is the same trigger, more explicit. Do **not** use `.onAppear` on the root; SwiftUI fires it at different times than expo-router's focus.
- `key={reload}` full-remount → give the shell view an `.id(reloadToken)` (a `UUID`), or better, make `onRetry` an explicit `model.reconnect()` that tears down and rebuilds the client + tasks. The `.id()` trick works but is opaque; explicit teardown is the more Swift-idiomatic port and the CLAUDE.md preference is "explicit over clever".

**Client construction**
- `BambuddyClient` ports almost 1:1 to a Swift `actor BambuddyClient` with `URLSession`. Make the JWT cache `actor`-isolated (it is currently a mutable field guarded only by JS's single thread — Swift concurrency will surface the race). Keep the 23 h proactive re-login and the exactly-one 401/403 retry.
- The `Bambuddy {METHOD} {path} -> HTTP {code} {body}` error string is *parsed* by `apiErrorDetail` and `classifyConnectError`. **Do not port the string-matching** — define `enum BambuddyError { case http(status: Int, detail: String?, path: String), network(URLError), timeout }` and rewrite both classifiers to switch on the enum. Keep the exact user-facing message strings from §15's table verbatim.

**Timers/pollers → structured concurrency**
Each `setInterval` becomes a `Task` in `.task {}` (auto-cancelled on disappear) with `while !Task.isCancelled { try await Task.sleep(...) ; … }`:
| poller | interval | Swift home |
|---|---|---|
| fleet `listPrinters` | 30 s | `.task(id: clientID)` |
| camera token refresh check | 60 s tick / 55 min TTL | same |
| maintenance rollup | 60 s | `.task(id: printerID)` |
| LAN-mode `getStatus` | 5 min + foreground | `.task` + `ScenePhase` observer |
| snapshot tile | 2 s | `.task(id: tab)` — must **not** be gated on PiP (see §10 gotcha) |
Use a monotonic clock (`ContinuousClock` / `DispatchTime`) for the TTL comparisons rather than `Date()`; the JS code uses wall-clock and would mis-fire across a clock change.

**Selection reconciler** — port `reconcileSelection` verbatim as a `struct` + pure `func`; it is already pure and unit-tested-shaped. Keep the 1-vs-2 threshold asymmetry.

**Theme** — this is the piece that needs the *most different* approach. The RN design mutates a shared `c` object in place; that has no safe Swift equivalent. Port to:
```swift
struct Palette { let bg, s1, s2, s3, s4, line, line2, t1, t2, t3,
                     accent, accentInk, accentDim, running, runningDim,
                     heating, heatingDim, paused, pausedDim, error, errorDim,
                     idle, idleDim, sheet, tabbar, thumb, supports, swatchRing: Color }
```
with `static let dark` / `static let light`, injected via `@Environment(\.palette)` (a custom `EnvironmentKey`) so every view re-renders on change. Two traps: (a) `rgba(255,255,255,0.07)` etc. must become `Color.white.opacity(0.07)`, **not** a pre-blended solid, or layered hairlines shift; (b) the "captured color goes stale" bug disappears entirely under `@Environment`, so the `dot: keyof Palette` indirection in `SPEEDS` can be simplified to a plain `Color` — that indirection is a workaround, not a requirement.
- The app has an **explicit** theme picker persisted in the Keychain and `userInterfaceStyle: "automatic"` in `app.json`. Port as `.preferredColorScheme(themeName == .dark ? .dark : .light)` on the root, and keep it a stored preference — **do not** silently switch to following the system, that is a feature regression.
- `mono` → `Font.system(.body, design: .monospaced)` is *not* Menlo. If exact glyph parity matters, use `Font.custom("Menlo", size:)`; otherwise `.monospaced` is the better native choice — decide once, it is visible on every settings row and section label.
- Numeric RN weights map: `'500'` → `.medium`, `'600'` → `.semibold`, `'700'` → `.bold`.
- `letterSpacing: 1` → `.tracking(1)`; `letterSpacing: -0.8` → `.tracking(-0.8)`.
- `shadow1` → `.shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 1)`. Caution: RN's `shadowRadius` is a *blur radius in points* matching CALayer; SwiftUI's `radius` is roughly `blur/2` for the same visual weight — expect to retune.

**Keychain** — replace `expo-secure-store` with a direct `SecItemAdd/CopyMatching` wrapper: `kSecClass: kSecClassGenericPassword`, `kSecAttrService: "bambu.config"` (or account — pick one and keep it stable), `kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, value = `JSONEncoder().encode(AppConfig)`. **Migration:** expo-secure-store stores under its own service/account naming, so a native rebuild installed over the RN build will *not* find the existing item unless you replicate its key layout — decide explicitly whether to migrate or force one re-onboarding. Keep `AppConfig` `Codable` with all-optional fields and a decode failure → `nil` (matching the JSON-parse `catch`).

**Tab + overlay state** — `TabKey` → `enum Tab: Hashable`. `overlay: 'camera'|'upload'|null` and the several nullable file states are best unified into `enum Overlay: Identifiable { case camera, upload, texturize(LibraryFile), wizard(LibraryFile), stl(id: Int, name: String), alerts }` driven by `.fullScreenCover(item:)` / `.sheet(item:)` — **except** that the current design needs *two overlays simultaneously* (STL viewer over the texturize sheet). SwiftUI cannot stack `.sheet` on `.sheet` cleanly; use a `ZStack` with explicit z-ordered layers, which is what the RN code already does.

**The mount-vs-hide gotchas do NOT port — and that is a trap.**
- The dashboard-stays-mounted hack exists solely for a `react-native-reanimated` v4 New-Arch teardown race (#9402/#9293). SwiftUI has no such bug. **Use a normal `TabView`.** But note the *side effect* the hack created and the code compensates for: the dashboard's timers kept running while hidden, which is why the snapshot poller is gated on `tab !== 'printer'`. With a real `TabView`, `.task` cancellation handles this for free — drop the gate.
- The camera-overlay-stays-mounted-during-PiP constraint **does** port, and gets *harder*: AVKit PiP in SwiftUI still requires the `AVPlayerLayer`/`AVSampleBufferDisplayLayer` to outlive the presenting view. Own the player in the model (not the `View`), so SwiftUI view identity churn cannot tear it down. The 30 s `pipActive` anti-latch timeout is a defensive hack around not knowing when PiP really stopped — natively you get `AVPictureInPictureControllerDelegate.pictureInPictureControllerDidStopPictureInPicture`, so **replace the timeout with the real callback** rather than porting it. (Keep a longer safety timeout if paranoid.)
- Related hard-won native fact already in the repo history: *"PiP crashed because AVKit ran off the main thread"* — all AVKit PiP calls must be `@MainActor`.

**MJPEG camera — the single hardest port.** The RN app renders `multipart/x-mixed-replace` in a WebView `<img>`. There is no native SwiftUI equivalent. You need a `URLSessionDataDelegate` that parses the multipart boundary stream into JPEG frames and pushes them into a `CIImage`/`CGImage` (or `AVSampleBufferDisplayLayer` for PiP). Repo history warns: **"URLSession de-multiplexes multipart itself"** — do not hand-roll boundary parsing before checking what `URLSession` already delivers per-part. Budget real time here.

**Camera/thumbnail auth** — remember the token goes in `?token=` and the `X-API-Key` header is *rejected* on stream/snapshot/thumbnail. `AsyncImage` sends no headers, which is fine here — but it also caches aggressively; the `&_t={tick}` cache-buster must be preserved (or use a `URLRequest` with `.reloadIgnoringLocalCacheData`).

**Alerts/dialogs** — RN `Alert.alert(title, body, buttons)` → `.alert(title, isPresented:) { Button(role: .destructive) }` or `.confirmationDialog`. Because SwiftUI alerts are declarative, the imperative `guard(action, run)` closure pattern needs restructuring: model it as `@State var pendingConfirmation: PendingAction?` and a single `.alert(item:)`. Keep every string verbatim (including the typographic apostrophes `’` in "It can't be undone." and "Couldn't confirm the plate" — they are U+2019, not `'`).

**Inbound file import** — `Linking.getInitialURL` + `addEventListener('url')` → `.onOpenURL { url in }` plus scene-connection options for cold launch. The `file://`/`content://` filter becomes `url.isFileURL` (and there is no `content://` on iOS — drop it). **You must call `url.startAccessingSecurityScopedResource()`** before copying: expo-file-system does this internally, and omitting it is the #1 cause of a silently-empty import natively. Keep the copy-to-cache-then-upload flow and the `importingRef` re-entrancy lock (→ an `actor` or a `@MainActor var isImporting`).

**Upload** — the `File.upload` workaround exists purely because Expo's WinterCG fetch rejects RN FormData parts. Natively, `URLSession.upload(for:fromFile:)` with a hand-built multipart body (field name `file`, mime `application/octet-stream`) is straightforward. **This entire gotcha disappears.** Keep the progress callback (`URLSessionTaskDelegate.didSendBodyData`).

**Settings form**
- The `secureTextEntry` AutoFill disaster **does port** — iOS `SecureField` and `.textContentType(.password)` trigger the same Strong-Password / AutoFill hijack. Use plain `TextField` with `.textContentType(nil)`, `.autocorrectionDisabled()`, `.textInputAutocapitalization(.never)` for the API key and both admin fields. Do **not** "improve" this to `SecureField`.
- `keyboardType="url"` → `.keyboardType(.URL)`. `keyboardShouldPersistTaps="handled"` → `.scrollDismissesKeyboard(.interactively)`.
- `KeyboardAvoidingView` is unnecessary — SwiftUI `Form`/`ScrollView` handles it.
- The live-derived placeholders (`resolvePushUrl({baseUrl: sanitizeBaseUrl(baseUrl)})`) recompute on every keystroke of the URL field; that is a nice touch worth preserving — it is cheap and pure.
- `Constants.expoConfig?.version` → `Bundle.main.infoDictionary?["CFBundleShortVersionString"]`. **`Updates.updateId` has no equivalent** — the OTA row becomes meaningless in a native app. Replace it with `CFBundleVersion` (build number) or drop the row; do not leave a stub reading `'embedded'`.

**app.json → Xcode project.** All of §18 becomes a checked-in `Info.plist` + `.entitlements` — and the entire "`ios/` is gitignored, use config plugins" constraint **vanishes**, which is the single biggest simplification of the port. Specifically retire: `withIosSceneLifecycle` (a native app adopts UIScene by default), `withIosPodMinDeploymentTarget` (no Pods), and the `patch-package` expo-modules-jsi fix. Carry over verbatim: bundle id `com.example.sprout`, display name **`Sprout`**, app group `group.com.example.sprout`, `UIBackgroundModes: [audio]` (still required to keep the MJPEG stream alive backgrounded — it is not decorative), the time-sensitive notifications entitlement, `NSSupportsLiveActivities` + `…FrequentUpdates`, `NSAllowsLocalNetworking: true` with `NSAllowsArbitraryLoads: false`, all 4 `CFBundleDocumentTypes` + 3 `UTImportedTypeDeclarations`, `LSSupportsOpeningDocumentsInPlace: false`, both URL schemes, portrait-only, and `CADisableMinimumFrameDurationOnPhone: true` (needed for 120 Hz). Drop `NSFaceIDUsageDescription` (expo-secure-store boilerplate, unused). Add `NSAppTransportSecurity` exceptions only if the backend uses a self-signed cert — note `classifyConnectError` explicitly mentions untrusted TLS as a failure mode, so this is a live scenario.

**Live Activities** — the widget currently suffers a severe constraint that **disappears**: the `'widget'`-directive function must be fully self-contained (no module-scope references) because babel stringifies it into an isolated runtime. Natively this is just a normal `ActivityKit` `Widget` in an extension target with full access to a shared framework. Keep the app-group image-passing (`file://` into `widgetsDirectory`) — that part is a genuine cross-process constraint, not a workaround. Keep one activity **per printer** (`ActivityAttributes` keyed by printer id), which is already the design.

**Push / Trellis** — `resolvePushUrl`/`resolveTexturizeUrl` port verbatim as pure functions (great unit-test targets, matching the repo's testing convention). Keep the `https?://` validation before ever POSTing a push token, and keep `X-API-Key` on Trellis registration.

**Things that will be genuinely hard, ranked:** (1) MJPEG stream decode + PiP; (2) the WebSocket status feed with REST fallback and the multi-printer `statuses` map (not covered here — `src/realtime/usePrinterStatus.ts`); (3) the STL/3MF viewer overlay (currently WebView-based); (4) Keychain migration from expo-secure-store's key layout; (5) resisting the urge to "clean up" the AutoFill-avoidance, the un-guarded Stop, and the non-PiP-gated snapshot poller — all three are scar tissue from real bugs.
