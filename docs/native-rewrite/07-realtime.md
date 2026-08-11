<!-- Generated as the port specification for the native Swift rewrite. -->
# WebSocket, camera stream, Live Activity

## realtime

Files covered (all absolute):
- `/Users/max/ai-projects/bambu-app/mobile/src/realtime/usePrinterStatus.ts`
- `/Users/max/ai-projects/bambu-app/mobile/src/realtime/useCameraStream.ts`
- `/Users/max/ai-projects/bambu-app/mobile/src/liveactivity/useLiveActivity.ts` (note: **not** in `src/realtime/`)
- `/Users/max/ai-projects/bambu-app/mobile/src/liveactivity/PrintActivity.tsx`
- `/Users/max/ai-projects/bambu-app/mobile/src/liveactivity/contentState.ts`
- Supporting: `/Users/max/ai-projects/bambu-app/mobile/src/liveactivity/nozzleIcon.ts`, `modelThumb.ts`, `/Users/max/ai-projects/bambu-app/mobile/src/app/index.tsx` (the only caller), `/Users/max/ai-projects/bambu-app/mobile/src/config/pushConfig.ts`, `/Users/max/ai-projects/bambu-app/mobile/src/notifications/useStatusNotifications.ts`, `/Users/max/ai-projects/bambu-app/deploy/trellis/app.py` (the server side of the same contract)

Hosts below are placeholders: `https://<bambuddy-host>`, `https://<lapush-host>`. No real key/token/host values appear anywhere in this document.

---

### 1. WebSocket status feed — `usePrinterStatus.ts`

#### 1.1 Constants (exact)

| Constant | Value | Meaning |
|---|---|---|
| `POLL_MS` | `3000` | REST fallback poll interval, **only while the socket is down** |
| `RECONNECT_MS` | `12_000` | Fixed reconnect delay. **There is no backoff** — it is a flat 12 s retry, forever |

#### 1.2 Endpoints

- Token mint: `POST {baseUrl}/api/v1/auth/ws-token` with header `X-API-Key: <key>` → JSON `{ token: string }`.
- Socket: `{wsBaseUrl}/api/v1/ws?token=<token>` where `wsBaseUrl` is `baseUrl.replace(/^http/, 'ws')` (so `https://…` → `wss://…`, `http://…` → `ws://…`). The token is placed in the query string **raw, not URL-encoded**.
- REST fallback: `GET {baseUrl}/api/v1/printers/{printerId}/status` with `X-API-Key`.

The socket is **per client (per server), not per printer** — one socket carries frames for the whole fleet.

#### 1.3 Frame format and the two pure parsers

```ts
export function parseWsFrame(raw: string): { printerId: number; status: PrinterStatus } | null {
  try {
    const m = JSON.parse(raw);
    if (m?.type === 'printer_status' && typeof m.printer_id === 'number' && m.data) {
      return { printerId: m.printer_id, status: m.data as PrinterStatus };
    }
    return null;
  } catch { return null; }
}

export function parseWsMessage(raw: string, printerId: number): PrinterStatus | null {
  const f = parseWsFrame(raw);
  return f && f.printerId === printerId ? f.status : null;
}
```

Wire shape: `{"type":"printer_status","printer_id":<int>,"data":{…PrinterStatus…}}`. Any other `type` (e.g. `"pong"`), a non-numeric `printer_id`, a missing `data`, or malformed JSON → `null` and the frame is **silently dropped** (never throws, never disconnects). Tests in `/Users/max/ai-projects/bambu-app/mobile/src/realtime/__tests__/parse.test.ts` pin exactly this.

#### 1.4 State machine

Two cooperating effects. Effect A (socket) has dependency `[client]` — **switching printers must not drop the socket** (explicit comment). Effect B (poll) has dependencies `[client, printerId, connected]`.

```
                    ┌──────────────── connect() ────────────────┐
                    │ mintWsToken() ──throw──► schedule retry ───┤ 12 s
  [mount] ──────────► new WebSocket(wsBase/api/v1/ws?token=…)   │
                    │       │onopen → connected = true          │
                    │       │onmessage → statuses[pid] = data   │
                    │       │onerror → ws.close()  (only action)│
                    │       │onclose → connected = false; ──────┘ 12 s
                    └───────────────────────────────────────────┘

  connected == false ⇒ REST poller ACTIVE: immediate fetch, then every 3000 ms
  connected == true  ⇒ REST poller torn down (effect returns early)
```

- `onerror` does **nothing but `ws.close()`** — all retry logic lives in `onclose`, so there is exactly one retry path.
- Cleanup sets a `cancelled` flag, clears the pending reconnect timer, and calls `wsRef.current?.close()`. Every callback re-checks `cancelled` before touching state.
- A failed token mint is caught and also schedules the same 12 s retry.

#### 1.5 REST fallback details

```ts
useEffect(() => {
  if (connected) return;
  let cancelled = false;
  const poll = async () => {
    try {
      const s = await client.getStatus(printerId);
      if (!cancelled) setStatuses((prev) => ({ ...prev, [printerId]: s }));
    } catch { /* keep polling */ }
  };
  void poll();                       // immediate, so the first paint doesn't wait for a frame
  const id = setInterval(poll, POLL_MS);
  return () => { cancelled = true; clearInterval(id); };
}, [client, printerId, connected]);
```

- Fires **one immediate fetch** before starting the interval — deliberate, so first paint never waits on a socket frame.
- Polls the **selected printer only** (the socket is what gives you the fleet).
- Errors are swallowed; polling continues.

#### 1.6 Return value

```ts
return { status: statuses[printerId] ?? null, statuses, connected };
```

`statuses: Record<number, PrinterStatus>` is a **monotonically accumulating** map — a printer seen once on the socket stays in the map with its last-known status. The fleet switcher and the Live Activity "one card per printer" logic both read it. Entries are never evicted.

#### 1.7 Gotchas that must survive the port

1. **The socket is keyed on `client`, not `printerId`.** Re-keying it on the selected printer would tear down and re-auth the socket on every printer switch. The comment in the source says this explicitly.
2. **No heartbeat / ping-pong and no `AppState` handling.** The hook never pings, never checks foreground/background. The only `AppState` listener in the app is in `useLanMode.ts`. On iOS the socket dies when the app is suspended; recovery is entirely via `onclose` → 12 s timer, so the first ~12 s after foregrounding can be served by the REST poller.
3. **`connected` reflects the socket only** — it is *not* `status.connected` (which is the printer's own reachability, used by `presentDashboard` to produce `kind: 'offline'`). Two different "connected" notions; don't merge them.
4. **No backoff, deliberately.** A flat 12 s is what shipped; a 401 from a rotated key produces a mint throw → same 12 s loop, with the REST poller carrying the UI in the meantime.
5. The socket token is short-lived server-side, but the hook **re-mints on every reconnect attempt** (mint is inside `connect()`), so token expiry is self-healing.

---

### 2. Camera stream token lifecycle

There are **two independent camera-token holders** in the app. Both mint the same kind of token from the same endpoint; they do not share state. Preserve both roles (they can be unified in the port — see Port notes).

#### 2.1 Endpoint + URL builders (`bambuddyClient.ts`)

```ts
async mintCameraToken(): Promise<string> {
  return (await (await this.req(`/api/v1/printers/camera/stream-token`, { method: 'POST' })).json()).token;
}
snapshotUrl(printerId, token) {
  return `${this.baseUrl}/api/v1/printers/${printerId}/camera/snapshot?token=${encodeURIComponent(token)}`;
}
/** Token MUST be in the query; the X-API-Key header is rejected (401) on stream/snapshot. */
streamUrl(printerId, token, fps = 10) {
  return `${this.baseUrl}/api/v1/printers/${printerId}/camera/stream?token=${encodeURIComponent(token)}&fps=${fps}`;
}
fileThumbUrl(fileId, token, thumbnailPath?) {
  if (!token || thumbnailPath === null) return '';
  return `${this.baseUrl}/api/v1/library/files/${fileId}/thumbnail?token=${encodeURIComponent(token)}`;
}
plateThumbUrl(fileId, plateIndex, token) {
  if (!token) return '';
  return `${this.baseUrl}/api/v1/library/files/${fileId}/plate-thumbnail/${plateIndex}?token=${encodeURIComponent(token)}`;
}
```

The mint itself is `X-API-Key`-authed. **Everything the token gates — MJPEG stream, snapshot, library thumbnails, plate thumbnails, print-log thumbnails — rejects `X-API-Key` with 401 and requires `?token=`.** This is the single most repeated gotcha in the codebase.

`POST /api/v1/printers/camera/stream-token` is **not per-printer** (no printer id in the path); one token serves every printer's camera and every thumbnail.

#### 2.2 Holder A — the stream token (`useCameraStream.ts`), full source semantics

```ts
const TOKEN_TTL_MS = 55 * 60 * 1000; // backend camera token TTL is 60 min; refresh a little early.

export function useCameraStream(client, printerId, enabled, fps = 10) {
  const [token, setToken] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const mintedAt = useRef(0);

  const mint = useCallback(async () => {
    try { const t = await client.mintCameraToken(); mintedAt.current = Date.now(); setToken(t); setError(null); }
    catch (e) { setError(String(e)); }
  }, [client]);

  useEffect(() => {                                    // mint on enable; clear on disable
    if (!enabled) { setToken(null); return; }
    if (!token || Date.now() - mintedAt.current > TOKEN_TTL_MS) void mint();
  }, [enabled, token, mint]);

  useEffect(() => {                                    // periodic refresh while enabled
    if (!enabled) return;
    const id = setInterval(() => { if (Date.now() - mintedAt.current > TOKEN_TTL_MS) void mint(); }, 60_000);
    return () => clearInterval(id);
  }, [enabled, mint]);

  const streamUrl = enabled && token ? client.streamUrl(printerId, token, fps) : null;
  return { token, streamUrl, error, remint: mint };
}
```

- **TTL 55 min against a 60 min server TTL**; the staleness check runs on a **60 000 ms** timer, so worst-case age at refresh is 56 min.
- Token is **session-only, never persisted** (contrast holder B, which seeds from Keychain).
- On disable the token is dropped, so re-opening the camera always mints fresh.
- `error` is set but the CameraOverlay does not read it; the overlay has its own failure detection (§2.5).
- Callsite in `index.tsx`: `useCameraStream(client, printerId, cameraOpen || pipActive, 10)` — **`fps=10`**.

**Enable condition and the PiP latch:** `enabled = (overlay === 'camera') || pipActive`. The token must outlive the overlay because Picture-in-Picture keeps playing after the fullscreen view closes; letting the token lapse would kill the floating window. There is an explicit anti-latch guard, because a stuck `pipActive` keeps the token and the overlay alive forever:

```ts
useEffect(() => {
  if (overlay !== 'camera' && !pipActive) return;
  if (overlay === 'camera') return;
  const t = setTimeout(() => setPipActive(false), 30_000);   // 30 s PiP latch breaker
  return () => clearTimeout(t);
}, [overlay, pipActive]);
```

#### 2.3 Holder B — the dashboard/thumbnail token (`src/app/index.tsx`)

```ts
const CAM_TOKEN_TTL_MS = 55 * 60 * 1000; // backend camera tokens live 60 min; refresh early

const [camToken, setCamToken] = useState<string | null>(config.cameraToken ?? null);
const camMintedAt = useRef(0);
useEffect(() => {
  let alive = true;
  const mint = () => client.mintCameraToken().then((t) => { if (!alive) return; camMintedAt.current = Date.now(); setCamToken(t); }).catch(() => {});
  if (!camToken) void mint();
  const id = setInterval(() => { if (!camToken || Date.now() - camMintedAt.current > CAM_TOKEN_TTL_MS) void mint(); }, 60_000);
  return () => { alive = false; clearInterval(id); };
}, [client, camToken]);
```

- Seeded from Keychain (`config.cameraToken`, via `src/config/secureConfig.ts`). **Note the seeded value has `camMintedAt = 0`**, so the first 60 s tick sees it as stale and re-mints — the persisted token is a first-paint optimisation only.
- Same 55 min / 60 s cadence. Failed mints are swallowed and retried on the next tick.
- This token feeds: the dashboard snapshot tile, `CameraOverlay`'s fast-fail snapshot probe, all library/plate/print-log thumbnails, and `writeModelThumb`.

#### 2.4 Snapshot polling (dashboard tile) — exact rules

```ts
const [tick, setTick] = useState(0);
useEffect(() => {
  if (cameraOpen || tab !== 'printer') return;
  const id = setInterval(() => setTick((t) => t + 1), 2000);   // 1 frame / 2 s
  return () => clearInterval(id);
}, [cameraOpen, tab]);

// Deliberately NOT gated on pipActive. It was, and a pipActive that never cleared froze this tile
// on a cached frame — the URL only changes with `tick`, so pausing the poller pauses the picture.
const snapshotUri = camToken && !cameraOpen ? `${client.snapshotUrl(printerId, camToken)}&_t=${tick}` : null;
```

- **Interval: 2000 ms.** Cache-busting is by appending `&_t=<tick>` (a monotonically increasing integer, not a timestamp) to `snapshotUrl(...)`, which already contains `?token=`.
- Paused when the fullscreen camera is open (`cameraOpen`) — **there is exactly one on-demand camera on the printer** and the two would contend.
- Paused when the dashboard tab is not shown (`tab !== 'printer'`) — the dashboard stays mounted, so without this the timer would poll an invisible tile.
- **Not** paused on `pipActive` — hard-won regression: a `pipActive` that never cleared froze the tile on a cached frame.
- Rendered in `DashboardView.tsx` via `expo-image` `<Image source={{uri}} contentFit="cover" transition={120} onLoad={…}/>`; `camLoaded` resets to false whenever `snapshotUri` goes null.
- Other pollers in the same screen, for completeness: fleet list every **30 000 ms**; maintenance rollup every **60 000 ms**; speed optimistic-override expiry **15 000 ms**.

#### 2.5 Fullscreen camera stream lifecycle (`CameraOverlay` in `src/components/Overlays.tsx`)

The rendering path is the **native** `CameraPiPView` (`/Users/max/ai-projects/bambu-app/mobile/modules/camera-pip/` — already Swift: `MJPEGStream.swift`, `MJPEGParser.swift`, `CameraPiPRenderer.swift`, `CameraPiPView.swift`, `CameraPiPModule.swift`). The older WebView document builder `/Users/max/ai-projects/bambu-app/mobile/src/components/mjpegHtml.ts` is retained and still carries the definitive description of the warm-up problem.

Overlay phase machine: `'connecting' → 'live' | 'failed'`.

- Re-arms to `'connecting'` whenever `streamUrl` changes (token re-mint) or `reloadKey` bumps (manual retry).
- **8000 ms safety net**: if no `streamUrl` ever arrives (mint rejecting/hanging) no native view mounts to report anything, so a timer flips `connecting → failed`.
- **Fast-fail probe**: `fetch(snapshotUrl)`; a clean non-OK HTTP response flips to `failed` immediately. A *network* failure is ignored ("proves nothing about the stream path"). Rationale in the comment: a disabled H2C camera 503s the snapshot in ~60 ms while `/stream` returns HTTP 200 whose only multipart part is a `text/plain` error, so the image never decodes and the overlay would otherwise sit on "waking…" for the full 40 s watchdog.
- `failedView = phase === 'failed' || (!live && vm.kind === 'offline')` — a known-offline printer shows the actionable card immediately.
- `CameraPiPView` is **not keyed on `streamUrl`**: the token refreshes hourly and remounting would destroy the display layer and take an active PiP window down. The native view hot-swaps the connection internally.
- `retry()` = `onRefresh()` (i.e. `remint`) + `reloadKey++`. `reloadKey` is intentionally **not** part of the view key, so a fresh token causes exactly one warm-up, not two.
- Landscape is a **manual 90° rotation of the whole overlay** (`transform: rotate('90deg')`, swapped width/height, offset by `(winW-winH)/2` / `(winH-winW)/2`) because the app is portrait-locked in `app.json` and `expo-screen-orientation` is not installed. It also keeps working when the phone's rotation lock is on.
- Legacy WebView watchdog numbers (still the correct tuning if you re-implement warm-up detection): `stallMs = 9000`, `retryMs = 2000`, `deadlineMs = 40000`, fps sampled by drawing into a 16×16 canvas each rAF and reporting once per 1000 ms.
- The camera is **on-demand**: `/stream` returns headers in ~7 ms but the cold camera takes ~7 s to emit the first JPEG; during that window the socket is healthy so neither `onload` nor `onerror` fires — an error-only retry loop waits forever. `POST /api/v1/printers/{id}/camera/diagnose` exists but is a known false negative on the A1 (reports port 6000 unreachable while snapshot and stream both work).

---

### 3. Live Activity

#### 3.1 ContentState — every field (`contentState.ts`)

```ts
export type PrintActivityProps = {
  printerName: string;   // "A1" | "H2C" — one card per machine
  name: string;          // subtask/file name ('' when unknown)
  stateLabel: string;    // "Printing" | "Heating" | "Paused" | "Complete" | "Error" | a stage name | "Drying" | "Done"
  progress: number;      // 0..100 (integer)
  layer: number;
  totalLayers: number;   // 0 if unknown
  etaEpochMs: number;    // absolute finish time, ms epoch; 0 if unknown
  finished: boolean;
  symbol: string;        // SF Symbol fallback name
  iconUri: string;       // file:// URI of the brand nozzle glyph in the App Group ('' -> use symbol)
  tint: string;          // hex accent
  nozzle: number;        // LEFT/only head, current °C
  nozzleTarget: number;
  nozzle2: number;       // RIGHT head (H2-series only)
  nozzle2Target: number;
  hasNozzle2: boolean;   // dual-nozzle machine -> render both, one marked active
  activeNozzle: number;  // 0 = left/only, 1 = right
  bed: number;
  bedTarget: number;
  modelUri: string;      // file:// URI of the plate thumbnail in the App Group ('' -> nozzle glyph)
  queueCount: number;    // prints waiting (drives the "Up next" banner row)
  nextName: string;      // name of the next queued print ('')
  // ---- AMS drying card (second activity per printer; widget branches on `dry`) ----
  dry?: boolean;
  amsTemp?: number;      // current AMS interior °C
  amsTarget?: number;    // drying target °C (0 when unknown)
  humidity?: number;     // AMS %RH
};

export type LiveActivityExtras = { modelUri?: string | null; queueCount?: number; nextName?: string | null };
```

**All numbers are integers** (`Math.round`). **The state is flat and JSON-serializable** — this is load-bearing, see §3.9.

Current-app note: `index.tsx` builds `ActivityEntry[]` **without** `extras`, so `modelUri`/`queueCount`/`nextName` are always `''`/`0`/`''` today; Trellis also hardcodes them to `''`/`0`/`''`. The widget already renders them (`lead()` and the "Up next" row), so the plumbing is there and unused. `writeModelThumb()` (`modelThumb.ts`) exists to populate `modelUri` and is currently called from nowhere.

#### 3.2 Fixed palette — `LA_COLORS` and `laTint`

```ts
export const LA_COLORS = {
  running: '#30D158',
  heating: '#FF9F0A',
  paused:  '#0A84FF',
  error:   '#FF453A',
  idle:    '#8E9398',
} as const;

export function laTint(vm: DashVM): string {
  if (vm.kind === 'error') return LA_COLORS.error;
  if (vm.isPaused) return LA_COLORS.paused;
  if (vm.kind === 'idle' || vm.kind === 'offline' || vm.kind === 'connecting') return LA_COLORS.idle;
  if (vm.kind === 'complete') return LA_COLORS.running;
  return vm.stateColor === c.heating ? LA_COLORS.heating : LA_COLORS.running;
}
```

**Gotcha (documented at length in the source):** this palette is deliberately **NOT** the app theme's `c.*`. The lock screen has no relationship to the in-app theme, and Trellis (which owns cards in server mode) does not know the phone's theme — it always sends these values. Reading `vm.stateColor` meant a light-mode app produced `#23B24A` while an identical card pushed from the server produced `#30D158`: the same print rendering in two different greens depending on which side made the card. **These five values must equal Trellis's `COLORS` dict exactly** (verified: `app.py:51` is byte-identical).

Note the dark-theme tokens happen to match `LA_COLORS`; the **light** theme tokens (`#23B24A`, `#E0860A`, `#0A84FF`, `#E5392E`, `#9AA0A6`) are what must never leak into a card. The `laTint` heating branch compares against the *themed* token `c.heating` purely as a "is this the heating classification" probe.

Drying tint is a sixth, separate colour: **`#FFB86C`** (also hardcoded identically in Trellis's `dry_state`).

#### 3.3 SF Symbols

```ts
const SYMBOLS: Record<string, string> = {
  Printing: 'printer.fill',
  Heating:  'thermometer.medium',
  Paused:   'pause.circle.fill',
  Complete: 'checkmark.circle.fill',
  Error:    'exclamationmark.triangle.fill',
};
```

Lookup: `SYMBOLS[vm.stateLabel] ?? (vm.kind === 'error' ? SYMBOLS.Error : SYMBOLS.Printing)` — a *stage-name* label (e.g. "Auto bed levelling") falls through to `printer.fill`. Drying overrides to `humidity.fill`.

#### 3.4 `toContentState` — the mapping

```ts
export function toContentState(vm, status, nowMs, iconUri = '', printerName = '', extras = {}): PrintActivityProps {
  const finished = vm.kind === 'complete';
  const remainingMin = status.remaining_time ?? 0;      // MINUTES
  const t = status.temperatures;
  const dual = vm.nozzles.length > 1;
  const activeNozzle = Math.max(0, vm.nozzles.findIndex((n) => n.active));
  return {
    printerName, iconUri,
    modelUri: extras.modelUri ?? '', queueCount: extras.queueCount ?? 0, nextName: extras.nextName ?? '',
    name: status.subtask_name ?? '',
    stateLabel: vm.stateLabel,
    progress: vm.progressInt,
    layer: status.layer_num ?? 0,
    totalLayers: status.total_layers ?? 0,
    etaEpochMs: !finished && remainingMin > 0 ? nowMs + remainingMin * 60000 : 0,
    finished,
    symbol: SYMBOLS[vm.stateLabel] ?? (vm.kind === 'error' ? SYMBOLS.Error : SYMBOLS.Printing),
    tint: laTint(vm),
    nozzle:  Math.round(t?.nozzle ?? 0),          nozzleTarget:  Math.round(t?.nozzle_target ?? 0),
    nozzle2: Math.round(t?.nozzle_2 ?? 0),        nozzle2Target: Math.round(t?.nozzle_2_target ?? 0),
    hasNozzle2: dual, activeNozzle,
    bed: Math.round(t?.bed ?? 0),                 bedTarget: Math.round(t?.bed_target ?? 0),
  };
}
```

Key points:
- `remaining_time` is in **minutes**; ETA is an **absolute epoch-ms instant** computed once per push, so the card counts down client-side between pushes.
- `etaEpochMs = 0` when finished or when remaining ≤ 0 — the widget treats `0` as "no ETA".
- Nozzle mapping is **positional**: `nozzle` = LEFT, `nozzle_2` = RIGHT. `activeNozzle` comes from the view-model, never re-derived here.

**The active-nozzle rule** (in `present.ts`, reproduced here because the card depends on it and it caused every past "wrong nozzle" bug):

```ts
// temperature keys are POSITION-ordered: `nozzle` = LEFT, `nozzle_2` = RIGHT
// `active_extruder` uses Bambu's extruder ids: 0 = RIGHT, 1 = LEFT   ← different coordinate system
let activeIdx = 0;
if (nozzles.length > 1) {
  const driven0 = nozzles[0].target > 0, driven1 = nozzles[1].target > 0;
  const ae = asNum(status.active_extruder);
  if (driven0 !== driven1) activeIdx = driven1 ? 1 : 0;              // 1. the DRIVEN head wins
  else if (ae === 0 || ae === 1) activeIdx = ae === 0 ? 1 : 0;       // 2. mapped active_extruder breaks ties
  else activeIdx = nozzles[1].now > nozzles[0].now ? 1 : 0;          // 3. else the hotter head
}
```

Regression tests that pin this live in `/Users/max/ai-projects/bambu-app/mobile/src/liveactivity/__tests__/contentState.test.ts`: right-active H2C (`nozzle 41/0`, `nozzle_2 220/220` → `activeNozzle === 1`), mid-tool-change (driven-but-cooler head still active), and "contradictory `active_extruder=1` while `nozzle` idx0 is driven at 245/245 → left is active". **Trellis's `classify()` ignores `active_extruder` entirely** (driven, then hotter) — a small, known divergence from the app.

#### 3.5 `meaningfulChange` — the exact push filter

```ts
const PROGRESS_EPS = 1; // push when progress moved >= 1%

export function meaningfulChange(a: PrintActivityProps | null, b: PrintActivityProps): boolean {
  if (!a) return true;
  return (
    Math.abs(a.progress - b.progress) >= PROGRESS_EPS ||
    a.layer !== b.layer || a.stateLabel !== b.stateLabel || a.name !== b.name ||
    a.printerName !== b.printerName || a.modelUri !== b.modelUri ||
    a.queueCount !== b.queueCount || a.nextName !== b.nextName ||
    Math.abs(a.nozzle  - b.nozzle)  >= 2 ||
    Math.abs(a.nozzle2 - b.nozzle2) >= 2 ||
    a.nozzleTarget !== b.nozzleTarget || a.nozzle2Target !== b.nozzle2Target ||
    a.activeNozzle !== b.activeNozzle ||
    Math.abs(a.bed - b.bed) >= 2 || a.bedTarget !== b.bedTarget ||
    Math.abs(a.etaEpochMs - b.etaEpochMs) >= 60_000 ||
    (a.dry ?? false) !== (b.dry ?? false) ||
    Math.abs((a.amsTemp ?? 0) - (b.amsTemp ?? 0)) >= 1 ||
    (a.amsTarget ?? 0) !== (b.amsTarget ?? 0) ||
    Math.abs((a.humidity ?? 0) - (b.humidity ?? 0)) >= 2
  );
}
```

Thresholds, verbatim: progress **≥ 1 %**, either nozzle **≥ 2 °C**, bed **≥ 2 °C**, ETA **≥ 60 000 ms** (ignores sub-minute drift), AMS temp **≥ 1 °C**, humidity **≥ 2 %**; every target, label, name, and `activeNozzle` is an exact-inequality trigger.

**Gotcha (from the comment):** temps and ETA are on the lock screen — *without* the temperature clauses a heat-up that doesn't advance progress or layer never pushes, and the card shows cold temps for minutes. Both nozzles and the active head matter now that dual machines render side by side.

Trellis's `meaningful_change()` mirrors this.

#### 3.6 Drying cards

```ts
const dnum = (v: unknown): number => {            // the WebSocket can deliver these as STRINGS
  const n = typeof v === 'number' ? v : Number(v ?? 0);
  return Number.isFinite(n) ? n : 0;
};

export function dryingUnitIds(status: PrinterStatus | null): number[] {
  return (status?.ams ?? []).filter((u) => dnum(u.dry_time) > 0).map((u) => dnum(u.id));
}
```

- **`dry_time` (minutes remaining) > 0 is THE active signal.** `dry_status` stayed `0` mid-cycle on the live H2C and must not be used.
- Values may arrive as strings → every read goes through `dnum`.
- Three drying-capable units are fitted (2× AMS 2 Pro + AMS HT), so **concurrent cycles are ordinary**; hence one card **per unit**.

```ts
export function toDryContentState(status, nowMs, iconUri = '', printerName = '', amsId?): PrintActivityProps | null {
  const units = status.ams ?? [];
  const ams = amsId != null ? units.find((u) => dnum(u.id) === amsId)
                            : units.find((u) => dnum(u.dry_time) > 0) ?? units[0];
  if (!ams) return null;
  const unitId = dnum(ams.id);
  const isHt = ams.is_ams_ht === true || unitId >= 128;             // HT ids start at 128
  const unitLabel = units.length > 1 ? (isHt ? 'AMS HT' : `AMS ${unitId + 1}`) : '';
  const mins = dnum(ams.dry_time);
  if (mins <= 0) return null;
  const target = Math.round(dnum(ams.dry_target_temp));
  const fil = ams.dry_filament || 'Filament';
  return {
    ...GENERIC_END,
    printerName, iconUri,
    dry: true, stateLabel: 'Drying',
    name: [unitLabel, target > 0 ? `${fil} @ ${target}°` : fil].filter(Boolean).join(' · '),
    tint: '#FFB86C',                    // drying amber — fixed, matches Trellis's dry_state
    symbol: 'humidity.fill',
    finished: false, progress: 0,
    etaEpochMs: nowMs + mins * 60000,
    amsTemp: Math.round(dnum(ams.temp)), amsTarget: target, humidity: Math.round(dnum(ams.humidity)),
  };
}
```

**Gotcha:** scan **every** unit, not `ams[0]` — a cycle on the AMS HT produced no card at all. The card names its unit (`AMS 1` / `AMS 2` / `AMS HT`, one-based for numbered units) so it is unambiguous which one is drying — but only when more than one unit is fitted.

`name` example: `"AMS HT · PA-CF @ 80°"`.

#### 3.7 `GENERIC_END` — the orphan-dismissal content

```ts
export const GENERIC_END: PrintActivityProps = {
  printerName: '', name: '', stateLabel: 'Complete', progress: 100, layer: 0, totalLayers: 0, etaEpochMs: 0,
  finished: true, symbol: 'checkmark.circle.fill', iconUri: '', tint: LA_COLORS.running,
  nozzle: 0, nozzleTarget: 0, nozzle2: 0, nozzle2Target: 0, hasNozzle2: false, activeNozzle: 0,
  bed: 0, bedTarget: 0, modelUri: '', queueCount: 0, nextName: '',
};
```

Used only to dismiss an activity that cannot be mapped back to a printer, and as the spread base for drying states.

#### 3.8 Lifecycle hook — `usePrinterActivities` (`useLiveActivity.ts`)

Signature: `usePrinterActivities(entries: ActivityEntry[], pushUrl?: string | null, apiKey?: string)`, with

```ts
export type ActivityEntry = { printerId: number; printerName: string; vm: DashVM; status: PrinterStatus | null; extras?: LiveActivityExtras };
```

Constants and predicates:

| Name | Value / rule |
|---|---|
| `MIN_UPDATE_MS` | `4000` — never push to ActivityKit more than ~once / 4 s **per card** |
| reconcile interval | `45_000` ms, server mode only |
| `isLive(vm)` | `vm.kind === 'live'` (covers Printing / Heating / Paused / named stages) |
| `isTerminal(vm)` | `vm.kind === 'complete' \|\| 'error' \|\| 'idle'` |
| no-op kinds | `offline` and `connecting` are **deliberately neither** — a WS blip must never kill a card mid-print |
| platform gate | everything returns early unless `Platform.OS === 'ios'` |
| deep link | `printActivity.start(state, 'bambu://')` |

**Ownership modes — the central design (verbatim rationale worth carrying over).** The old design had two independent producers (this hook started cards locally *and* Trellis push-to-started them) with nothing able to reconcile them, because `expo-widgets` exposes no id and no content on an adopted activity — `getInstances()` returns opaque handles. That produced all three reported failures at once: duplicate cards for one print, cards frozen at 0 % that nobody owned, and local-vs-remote cards rendering different colours/icons. Ownership is now decided by **mode**, so a conflict cannot arise.

```
serverMode = !!(pushUrl && apiKey)          // pushUrl from resolvePushUrl(config)

SERVER mode — Trellis owns every card. This hook NEVER calls start().
  jobs: (a) hand over the device push-to-start token, (b) reconcile every 45 s.
  Tradeoff, deliberately taken: a card appears on Trellis's next poll (≤ 5 s) rather than
  instantly, and if Trellis is down there is no card at all. Predictable beats partially-working.

LOCAL mode — this hook owns every card: sweep-on-first-run, start on live, throttled updates,
  end on terminal. No server, no push, no reconciliation.
```

State kept in refs (all survive re-render, none in React state):

```
instances:    Map<number, LiveActivity>        // print card per printerId
lastPush:     Map<number, number>              // epoch ms of last push
lastState:    Map<number, PrintActivityProps>
subs:         Map<string, {remove()}>          // push-token listeners, key '<pid>'
adopted:      boolean                          // first-run sweep / first reconcile latch
dryInstances: Map<string, LiveActivity>        // key '<printerId>:<amsId>'
dryLastPush / dryLastState / drySubs: same keying
```

**Keying gotcha:** drying cards are keyed `"<printerId>:<amsId>"`, not per printer — a per-printer key showed only the first concurrent cycle and the second silently never appeared. `subs`/`drySubs` are keyed by **string** so both shapes share one map type.

**LOCAL-mode main loop (per entry, `now = Date.now()` captured once):**

```ts
if (!e.status) continue;
const next = toContentState(e.vm, e.status, now, nozzleIconUri(), e.printerName, e.extras ?? {});
const inst = instances.current.get(e.printerId);

if (isTerminal(e.vm)) {                      // END
  if (inst) {
    inst.end('default', next, new Date(now)).catch(() => {});
    instances/lastState/lastPush.delete(pid); subs.get(String(pid))?.remove(); subs.delete(String(pid));
  }
  continue;
}
if (isLive(e.vm) && !inst) {                 // START
  try {
    const ni = printActivity.start(next, 'bambu://');
    instances.set(pid, ni); lastState.set(pid, next); lastPush.set(pid, now);
    wirePush(pid, e.printerName, ni);
  } catch { /* disabled by user / not a dev build — app UI still works */ }
  continue;
}
if (inst) {                                  // UPDATE (throttled + filtered)
  const due = now - (lastPush.get(pid) ?? 0) >= MIN_UPDATE_MS;
  if (due && meaningfulChange(lastState.get(pid) ?? null, next)) {
    inst.update(next).catch(() => {});
    lastState.set(pid, next); lastPush.set(pid, now);
  }
}
```

**Drying loop (LOCAL mode), after the print loop:**

```ts
const liveDryKeys = new Set<string>();
for (const e of entries) {
  if (!e.status) continue;
  for (const amsId of dryingUnitIds(e.status)) {
    const key = `${e.printerId}:${amsId}`;
    liveDryKeys.add(key);
    const dcs = toDryContentState(e.status, now, nozzleIconUri(), e.printerName, amsId);
    if (!dcs) continue;
    // start if absent (wirePush(..., 'dry', amsId)), else same 4 s + meaningfulChange throttle
  }
}
// set-difference sweep — driven by keys, not per-entry, so a unit that VANISHES from the payload
// entirely is still cleaned up:
for (const key of [...dryInstances.current.keys()]) {
  if (liveDryKeys.has(key)) continue;
  inst.end('default',
    { ...(dryLastState.get(key) ?? GENERIC_END), dry: true, stateLabel: 'Done', finished: true, etaEpochMs: 0 },
    new Date(now)).catch(() => {});
  // delete from all four maps, remove the push-token sub
}
```

**First-run sweep (LOCAL only):**

```ts
if (!adopted.current) {
  adopted.current = true;
  try { printActivity.getInstances().forEach((inst) => inst.end('immediate', GENERIC_END, new Date()).catch(() => {})); }
  catch { /* Expo Go / no native module */ }
}
```

Anything left over from a previous launch cannot be identified and nothing else will ever end it, so it is killed and the live set rebuilt from state.

**Reconcile (SERVER only)** — full source, because the algorithm is subtle:

```ts
const reconcile = async () => {
  if (!serverMode) return;
  let list: LiveActivity<PrintActivityProps>[] = [];
  try { list = printActivity.getInstances(); } catch { return; }   // Expo Go / no native module
  const byToken = new Map<string, LiveActivity<PrintActivityProps>>();
  for (const inst of list) {
    try { const tok = await inst.getPushToken(); if (tok) byToken.set(tok, inst); }  // no token yet -> next pass
    catch { /* one bad instance must not abort the sweep */ }
  }
  try {
    const res = await fetch(`${pushUrl.replace(/\/+$/, '')}/sync`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'X-API-Key': apiKey },
      body: JSON.stringify({ tokens: [...byToken.keys()], icon_uri: nozzleIconUri() }),
    });
    if (!res.ok) return;                       // Trellis unreachable -> leave every card alone; never destroy on doubt
    const { end = [] } = (await res.json()) as { end?: string[] };
    for (const tok of end) await byToken.get(tok)?.end('immediate', GENERIC_END, new Date()).catch(() => {});
  } catch { /* offline -> try again on the next pass */ }
};
```

**Why the FULL set, not one token at a time:** APNs answers `200` for a card the user has swiped away, so Trellis cannot detect a dismissal on its own — it kept believing it owned a vanished card and refused to start a replacement (an empty lock screen mid-print). The app is the only party that can see the truth, so it reports all of it and the server converges: forget vanished cards, bind an unknown token to a card it just remote-started (this is what un-freezes a card stuck at 0 %), and hand back anything nothing accounts for, which the app ends.

Two absolute rules: an activity with **no token yet** is skipped (picked up next pass), and a **non-OK `/sync`** means *do nothing* — never destroy a card on doubt.

**Push-token wiring:**

```ts
const wirePush = (printerId, printerName, inst, kind: 'print'|'dry' = 'print', amsId?) => {
  const sm = kind === 'dry' ? drySubs : subs;
  const key = kind === 'dry' ? `${printerId}:${amsId}` : String(printerId);
  if (!pushUrl || !apiKey || sm.current.has(key)) return;
  try {
    inst.getPushToken().then((tok) => tok && registerPushToken(pushUrl, apiKey, printerId, printerName, tok, kind, amsId)).catch(() => {});
    const sub = inst.addPushTokenListener((ev) => registerPushToken(pushUrl, apiKey, printerId, printerName, ev.pushToken, kind, amsId));
    sm.current.set(key, sub);
  } catch { /* older expo-widgets / push disabled — foreground updates still work */ }
};
```

**Push-to-start registration** (separate effect, deps `[pushUrl, apiKey]`, iOS + both credentials required):

```ts
sub = addPushToStartTokenListener((ev) => {
  const tok = ev.activityPushToStartToken;
  if (!tok) return;
  fetch(`${pushUrl.replace(/\/+$/, '')}/register-start`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'X-API-Key': apiKey },
    body: JSON.stringify({ push_token: tok, icon_uri: nozzleIconUri() }),
  }).catch(() => {});
});
```

The native module emits the current token as soon as the listener attaches, then again on rotation. **The `icon_uri` is handed over deliberately:** Trellis has no way to know the App-Group glyph path, and without it remotely-started cards render the SF-symbol fallback while app-started ones show the brand nozzle — the visual tell that exposed the whole duplicate-ownership bug.

#### 3.9 Trellis HTTP contract (all `X-API-Key` gated)

| Endpoint | Body | Purpose |
|---|---|---|
| `POST {pushUrl}/register` | `{printer_id, push_token, printer_name, icon_uri, kind: 'print'\|'dry', ams_id?}` | Bind a card's APNs update token. Card key server-side: `"<pid>"` or `"dry:<pid>:<amsId>"` |
| `POST {pushUrl}/register-start` | `{push_token, icon_uri}` | Device push-to-start token (iOS 17.2+) |
| `POST {pushUrl}/sync` | `{tokens: string[], icon_uri}` → `{end: string[], cards: string[]}` | Reconciliation (§3.8) |
| `POST {pushUrl}/register-device` | `{device_token}` | Raw APNs device token for print-done/error **alert** banners (`useStatusNotifications.ts`) |
| `POST {pushUrl}/unregister?printer_id=<id>` | — | Not called by the app |
| `GET {pushUrl}/health` | — | `{ok, registrations, devices, apns_host}` |

`pushUrl` resolution (`src/config/pushConfig.ts`): `serverPush === false` → `null` (forces LOCAL); else an explicit `cfg.pushUrl`; else, if `baseUrl` contains `bambuddy.`, that host with `bambuddy.` → `lapush.`; else `null`. Whatever is chosen is validated against `/^https?:\/\/[^\s]+$/i` — a malformed entry silently disables push rather than POSTing a token somewhere unexpected. Trailing slashes are stripped at every call site with `.replace(/\/+$/, '')`.

Server-side numbers: poll every **5 s** (`POLL_INTERVAL`), minimum push spacing **30 s** (`MIN_UPDATE_S`), APNs priority **10** for the first push / a `stateLabel` flip / a `finished` flip, **5** otherwise, end pushes carry `dismissal-date = now + 1800 s`.

**The single most dangerous serialization gotcha, from `_envelope()`:**

```python
def _envelope(cs: dict) -> dict:
    """The widget's native ContentState is Codable{name: String, props: String} — `props` is the
    JSON-SERIALIZED props string and `name` is the registered component. A flat props dict fails
    decoding ON-DEVICE while APNs still answers 200 — pushed updates silently never applied."""
    return {"name": "PrintActivity", "props": json.dumps(cs, separators=(",", ":"))}
```

i.e. `expo-widgets`' generated `ContentState` is `{ name: String, props: String }` where `props` is a **stringified JSON blob**. Also: a push-to-start payload **without** an `alert` block is accepted by APNs (200) and silently discarded on-device — no card, no app wake. `attributes-type` is `"LiveActivityAttributes"` with `attributes: {}`.

#### 3.10 Widget rendering — `PrintActivity.tsx`

**The `'widget'` directive contract (must be understood before touching this file):** `babel-preset-expo`'s widgets plugin **stringifies only this function's params + body** and re-evaluates it in an isolated native runtime where only the `@expo/ui/swift-ui` primitives are injected. The function must be **fully self-contained** — every constant and helper lives *inside* it; it may reference only its args (`p`, `_env`), `Math`/`Date`, and the injected components/modifiers. Referencing a module-scope constant renders a blank/black activity.

Related `@expo/ui` rules encoded here: `Text` has no `size`/`weight`/`color` props — styling is `modifiers={[font({...}), foregroundStyle(hex)]}`. A `uiImage` only respects `frame` when also marked `resizable()`. `Image systemName` *does* take `color` and `size` props. Text can render a live timer via `date={Date}` + `dateStyle="timer" | "time"`.

Text colours (declared inside the function):

```ts
const T1 = '#F3F5F7';   // primary text
const T2 = '#A4ABB2';   // secondary/dim text
```

Derived values:

```ts
const pct    = `${Math.max(0, Math.min(100, Math.round(p.progress)))}%`;
const layers = p.totalLayers > 0 ? `${p.layer}/${p.totalLayers}` : `${p.layer}`;
const eta    = p.etaEpochMs > 0 && !p.finished;
const endDate = new Date(p.etaEpochMs || Date.now());
const temp = (cur, target) => (target > 0 && target !== cur ? `${cur}/${target}°` : `${cur}°`);
const dim  = (s) => <Text modifiers={[font({ size: 11 }), foregroundStyle(T2)]}>{s}</Text>;
const queueLine = p.queueCount > 0
  ? (p.nextName ? `Up next: ${p.nextName}${p.queueCount > 1 ? `  ·  +${p.queueCount - 1} more` : ''}` : `${p.queueCount} queued`)
  : '';
```

Note the **double-space around the middle dot** in `queueLine` and in the banner subtitle — intentional optical spacing.

Shared sub-views:

```ts
// One nozzle segment: label + temp, bright when driven, dim when idle.
const nozSeg = (label, cur, target, active) => (
  <HStack spacing={3}>
    {dim(label)}
    <Text modifiers={[font(active ? { size: 11, weight: 'semibold' } : { size: 11 }),
                      foregroundStyle(active ? T1 : T2)]}>{temp(cur, target)}</Text>
  </HStack>
);
const nozzleTemps = () => (
  <HStack spacing={8}>
    {p.hasNozzle2 ? nozSeg('L', p.nozzle, p.nozzleTarget, p.activeNozzle === 0) : null}
    {p.hasNozzle2 ? nozSeg('R', p.nozzle2, p.nozzle2Target, p.activeNozzle === 1)
                  : nozSeg('Nozzle', p.nozzle, p.nozzleTarget, true)}
    {dim('·')}
    {dim(`Bed ${temp(p.bed, p.bedTarget)}`)}
  </HStack>
);
// Brand nozzle glyph from the App Group; falls back to the SF symbol if unavailable.
const glyph = (s) => p.iconUri
  ? <Image uiImage={p.iconUri} modifiers={[resizable(), aspectRatio({contentMode:'fit'}), frame({width:s,height:s})]} />
  : <Image systemName={p.symbol} color={p.tint} size={s} />;
// Leading visual: plate thumbnail (rounded) when we have it, else the brand nozzle.
const lead = (s) => p.modelUri
  ? <Image uiImage={p.modelUri} modifiers={[resizable(), aspectRatio({contentMode:'fill'}),
                                            frame({width:s,height:s}), cornerRadius(s * 0.22)]} />
  : glyph(s);
```

Dual-nozzle rationale (comment): H2-series machines show **both** heads — driven one bright, idle one dimmed — so a right-nozzle print never reads as the (idle, cool) left.

**PRINT face — Lock Screen / Notification Center banner**

- Root: `VStack alignment="leading" spacing={9}` + `padding({ all: 14 })`
- Row 1: `HStack spacing={12}`
  - `lead(40)` — thumbnail 40×40, corner radius **8.8** (`40 * 0.22`), `contentMode: 'fill'`; else nozzle glyph 40×40 `fit`; else SF symbol size 40 in `p.tint`
  - `VStack alignment="leading" spacing={2}`
    - `Text` — `p.printerName || 'Printer'` — font **15 semibold**, colour **T1**
    - `Text` — `p.name ? \`${p.name}  ·  L${layers}\` : \`${p.stateLabel}  ·  L${layers}\`` — font **12**, colour **T2**
  - `Spacer`
  - `VStack alignment="trailing" spacing={1}`
    - `Text` — `pct` — font **22 bold, design 'rounded'**, colour **`p.tint`**
    - if `eta`: `HStack spacing={3}` → `Text "ends"` (11, T2) + `Text date={endDate} dateStyle="time"` (11 medium, T1)
    - else: `Text` (11, T2) = `p.finished ? 'Done' : '—'`
- Row 2: `ProgressView value={clamp(p.progress / 100, 0, 1)}` with `tint(p.tint)`
- Row 3: `HStack spacing={8}` → `nozzleTemps()`, `Spacer`, if `eta` → `Text date={endDate} dateStyle="timer"` (11 semibold rounded, **T2**)
- Row 4 (only when `queueLine`): `HStack spacing={6}` → `Image systemName="square.stack.3d.up" color={T2} size={11}` + `Text` (11, T2) = `queueLine`

**PRINT face — Dynamic Island**

| Region | Content |
|---|---|
| `compactLeading` | `glyph(16)` |
| `compactTrailing` | `eta` → `Text date={endDate} dateStyle="time"` (13 semibold rounded, `p.tint`) — **the end clock time, deliberately not the percentage**; else `Text` (13 semibold rounded, `p.tint`) = `p.finished ? 'Done' : pct` |
| `minimal` | `glyph(14)` |
| `expandedLeading` | `VStack leading spacing={1}` + `padding({leading: 6})`: `Text` (13 semibold, T1) = `p.printerName \|\| p.stateLabel`; `Text` (11, T2) = `` `${p.stateLabel} · L${layers}` `` (single spaces here) |
| `expandedTrailing` | `VStack trailing spacing={1}` + `padding({trailing: 6})`: `Text pct` (17 bold rounded, `p.tint`); then `eta` → `Text date dateStyle="timer"` (11, T2), else `Text` (11, T2) = `p.finished ? 'Done' : ''` |
| `expandedBottom` | `VStack spacing={6}` + `padding({horizontal: 6, top: 4})`: `ProgressView` (same clamp + tint); `HStack spacing={8}` → `nozzleTemps()`, `Spacer`, if `eta` → `HStack spacing={3}` of `Text "ends"` (11, T2) + `Text date dateStyle="time"` (11 medium, T1) |

**DRY face** — same activity type, branched at the top of the function on `if (p.dry) { … }`. Countdown renders client-side from `etaEpochMs` (`dateStyle="timer"`), so the card stays live between pushes.

```ts
const dryIcon = (s) => <Image systemName="humidity.fill" color={p.tint} size={s} />;
const dryStats = (
  <HStack spacing={8}>
    {dim('AMS')}
    <Text modifiers={[font({size:11, weight:'semibold'}), foregroundStyle(T1)]}>
      {(p.amsTarget ?? 0) > 0 ? `${p.amsTemp ?? 0}/${p.amsTarget}°` : `${p.amsTemp ?? 0}°`}
    </Text>
    {dim('·')}
    {dim(`Humidity ${p.humidity ?? 0}%`)}
  </HStack>
);
```

| Region | Content |
|---|---|
| `banner` | `VStack leading spacing={9}` + `padding(all:14)`. Row 1 `HStack spacing={12}`: `dryIcon(34)`; `VStack leading spacing={2}` → `Text` (15 semibold, T1) = `` `${p.printerName \|\| 'AMS'} · Drying` ``, `Text` (12, T2) = `p.name`; `Spacer`; `VStack trailing spacing={1}` → `eta` ? `Text date dateStyle="timer"` (**20 bold rounded**, `p.tint`) : `Text "—"` (same font), then if `eta` `HStack spacing={3}` of `"ends"` (11, T2) + `time` (11 medium, T1). Row 2: `dryStats` |
| `compactLeading` | `dryIcon(16)` |
| `compactTrailing` | `eta` ? `Text date dateStyle="timer"` (13 semibold rounded, tint) : `Text "dry"` (same font) |
| `minimal` | `dryIcon(14)` |
| `expandedLeading` | `VStack leading spacing={1}` + `padding(leading:6)`: `Text` (13 semibold, T1) = `` `${p.printerName \|\| 'AMS'} · Drying` ``; `Text` (11, T2) = `p.name` |
| `expandedTrailing` | `VStack trailing spacing={1}` + `padding(trailing:6)`: only when `eta` → `Text date dateStyle="timer"` (17 bold rounded, tint) |
| `expandedBottom` | `VStack spacing={6}` + `padding(horizontal:6, top:4)`: `HStack spacing={8}` → `dryStats`, `Spacer`, if `eta` → `"ends"` (11, T2) + `time` (11 medium, T1) |

Registration: `export const printActivity = createLiveActivity<PrintActivityProps>('PrintActivity', PrintActivity);` — the string `'PrintActivity'` is the name Trellis puts in the push envelope's `name` field. **It must match exactly.**

#### 3.11 Asset pipeline into the App Group

`nozzleIcon.ts` — the widget extension is a **separate process** and `Image uiImage` can only load a local file from the shared App Group container:

```ts
export function nozzleIconUri(): string {
  if (Platform.OS !== 'ios') return '';
  const dir = widgetsDirectory;                 // "file:///.../ExpoWidgets/" — App Group container; '' on the stub
  if (!dir) return '';
  const uri = dir.endsWith('/') ? `${dir}nozzle.png` : `${dir}/nozzle.png`;
  if (!writeStarted) {
    writeStarted = true;
    FileSystem.writeAsStringAsync(uri, NOZZLE_PNG_B64, { encoding: FileSystem.EncodingType.Base64 })
      .catch(() => { writeStarted = false; });  // allow a retry on the next call
  }
  return uri;                                   // returned SYNCHRONOUSLY, before the write completes
}
```

- The PNG is a **96×96 base64 blob embedded in the source**, rendered from `/Users/max/ai-projects/bambu-app/mobile/src/liveactivity/nozzle-glyph.svg`.
- Written **once per process** (module-level `writeStarted` latch, reset on failure so the next call retries).
- The URI is returned synchronously even on the very first call, i.e. the first card may briefly reference a not-yet-written file. Accepted: `uiImage` failing simply shows nothing and the next update fixes it.
- **`uiImage` cannot be re-tinted**, so this is a fixed brand mark (teal bead); print state is conveyed by the label, the %, and the progress colour.

`modelThumb.ts` — same container, for plate thumbnails:

```ts
export async function writeModelThumb(client, fileId, token): Promise<string | null> {
  if (Platform.OS !== 'ios' || !token) return null;
  const dir = widgetsDirectory; if (!dir) return null;
  const url = client.fileThumbUrl(fileId, token);        // authed via ?token= (camera stream token!)
  if (!url) return null;
  const dest = new File(dir.endsWith('/') ? `${dir}model.png` : `${dir}/model.png`);
  try { await File.downloadFileAsync(url, dest, { idempotent: true }); return dest.uri; }
  catch { return null; }
}
```

Fixed filename `model.png` — **one slot for the whole fleet**, which would collide on a multi-printer setup if `extras.modelUri` were ever wired up.

#### 3.12 Companion: status banner notifications (`src/notifications/useStatusNotifications.ts`)

Separate from Live Activities but part of the same push story. Requests notification permission, gets the **raw APNs device token** (`Notifications.getDevicePushTokenAsync()` → `{type:'ios', data:'<hex>'}`), POSTs it to `{pushUrl}/register-device` with `X-API-Key`. iOS-only, no-ops without both `pushUrl` and `apiKey`, all failures swallowed. A `setNotificationHandler` at module scope sets `shouldShowBanner/shouldShowList/shouldPlaySound = true`, `shouldSetBadge = false`, so banners appear even in the foreground. Trellis sends print-done and error banners plus a "💨 <printer> — drying finished" banner (only when `dry_time` fell from a value **≤ 15** min, so a manual stop stays silent).

---

### Port notes

#### WebSocket (`usePrinterStatus`)

| RN piece | Swift equivalent |
|---|---|
| `useState<Record<number, PrinterStatus>>` + `connected` | An `@Observable` (or `ObservableObject`) `PrinterStatusStore` actor-backed class exposing `statuses: [Int: PrinterStatus]`, `connected: Bool`, and a `status(for:)` accessor. Keep the fleet map — the Live Activity logic depends on it. |
| `new WebSocket(url)` + `onopen/onmessage/onclose/onerror` | `URLSessionWebSocketTask`. There is no `onclose`/`onerror` — you get an error from `receive(completionHandler:)` and, separately, `URLSessionWebSocketDelegate.didCloseWith`. **Unify both into one `handleDisconnect()`** so you keep the single-retry-path property the JS gets for free. |
| `ws.onmessage` recursion | `URLSessionWebSocketTask.receive` is one-shot — you must re-arm it after every message. Forgetting this silently stops the feed with the socket still "open". |
| `parseWsFrame` | `Codable` envelope: `struct WSFrame: Decodable { let type: String; let printer_id: Int?; let data: PrinterStatus? }`. Keep it a **pure, unit-tested function** returning `(Int, PrinterStatus)?` — the existing jest cases port 1:1 to XCTest. |
| `setTimeout(connect, 12_000)` | `Task { try await Task.sleep(for: .seconds(12)); await connect() }`, stored so `cancel()` replaces the `cancelled` flag + `clearTimeout`. |
| `setInterval(poll, 3000)` | `Task` loop with `Task.sleep(for: .seconds(3))`, cancelled when `connected` becomes true. Keep the **immediate first fetch**. |
| `client.wsBaseUrl` | `URLComponents` on the base URL, `scheme = scheme == "https" ? "wss" : "ws"`. Do not do the JS `replace(/^http/, 'ws')` string hack. |

Things that need a **different** approach natively:

1. **Backgrounding is now yours to handle.** RN got away with "the socket dies, 12 s later it reconnects". In Swift you should add `scenePhase` / `UIApplication.didBecomeActiveNotification` observation to force an immediate reconnect on foreground instead of waiting up to 12 s. This is a *behaviour improvement*, so make it deliberate.
2. **Token in the query string is not URL-encoded today.** Build the URL with `URLComponents.queryItems` (which percent-encodes) — verify against the server once, since a token containing `+` or `/` would change on the wire.
3. Consider `NWPathMonitor` to collapse the retry delay when connectivity returns — again a deliberate improvement over the flat 12 s.
4. Keep `connected` (socket) and `status.connected` (printer) as **two distinct properties**; naming them the same is how this gets broken.

#### Camera

| RN piece | Swift equivalent |
|---|---|
| `useCameraStream` + the `index.tsx` token effect | **Unify into one `CameraTokenProvider` actor**: `func token() async throws -> String` that mints on first call and re-mints when `Date.now - mintedAt > 55 * 60`. The two independent holders exist only because of hook boundaries; one provider serving stream + snapshot + thumbnails is strictly better and removes the duplicated 60 s timers. |
| 55-min TTL + 60 s staleness timer | Keep the numbers. A timer is no longer needed if you check-on-demand, but keep a background refresh if you want the fullscreen stream URL to be swapped proactively rather than after a 401. |
| `config.cameraToken` seeded from Keychain with `mintedAt = 0` | Persist `mintedAt` alongside the token in the Keychain item so a warm launch does not immediately re-mint. |
| Snapshot tile `&_t=<tick>` cache-buster | `URLCache`-aware: either keep the cache-buster or set `URLRequest.cachePolicy = .reloadIgnoringLocalCacheData`. **AsyncImage caches aggressively** — without one of the two, the tile freezes. Interval **2.0 s**, and preserve both gates (`!cameraOpen`, dashboard tab visible) and the deliberate **non**-gate on PiP. |
| MJPEG stream + PiP | **Reuse `/Users/max/ai-projects/bambu-app/mobile/modules/camera-pip/ios/` verbatim** — `MJPEGParser.swift`, `MJPEGStream.swift`, `CameraPiPRenderer.swift`, `CameraPiPView.swift` are already Swift/AVKit and drop straight into a native app; only `CameraPiPModule.swift` (the Expo bridge) goes away. Wrap `CameraPiPView` in a `UIViewRepresentable`. |
| Overlay phase machine | A small `enum CameraPhase { case connecting, live, failed }` in an `@Observable` view model. Port all three timers: **8 s** no-URL safety net, the snapshot fast-fail probe (only a clean HTTP error demotes; a network error is ignored), and the offline short-circuit. |
| Manual landscape rotation | **Drop the hack.** The RN version rotates the whole overlay 90° because the app is portrait-locked in Info.plist and `expo-screen-orientation` wasn't installed. Natively, use `supportedInterfaceOrientations` / `UIWindowScene.requestGeometryUpdate` for the camera screen — but note the *feature* it bought (works even with the phone's rotation lock ON) and consider keeping the manual toggle as well. |

Gotchas that must be re-encoded in the Swift client:
- `X-API-Key` on `/camera/stream`, `/camera/snapshot`, and every thumbnail endpoint returns **401**. Token goes in `?token=` only. Put this in a doc comment on the URL builders exactly as the TS does.
- One on-demand camera per printer: never run the snapshot poller and the fullscreen stream concurrently.
- `/camera/diagnose` is a known false negative on the A1 — don't gate the UI on it.

#### Live Activity

| RN piece | Swift equivalent |
|---|---|
| `PrintActivityProps` | `struct PrintAttributes: ActivityAttributes { struct ContentState: Codable, Hashable { … } }`. **This is where the port gets much better**: the `expo-widgets` `{name: String, props: String}` double-encoding envelope disappears — but **Trellis must be updated in lockstep** (`_envelope()` in `app.py`), or every pushed update will fail to decode on-device while APNs still answers 200. This is the single highest-risk item in the whole port. |
| `createLiveActivity('PrintActivity', fn)` + the `'widget'` directive | A real Widget Extension target with `ActivityConfiguration(for: PrintAttributes.self)`. **All the self-containment restrictions evaporate** — you can share constants, colours, and helper views with the app via a shared framework/target membership. Delete the "everything must be inline" contortions. |
| `HStack/VStack/Text/Image/Spacer/ProgressView` + modifier arrays | Native SwiftUI 1:1. `font({size:15, weight:'semibold'})` → `.font(.system(size: 15, weight: .semibold))`; `design:'rounded'` → `.system(size:, weight:, design: .rounded)`; `foregroundStyle(hex)` → `.foregroundStyle(Color(hex:))`; `tint(hex)` → `.tint(...)` on `ProgressView(value:)`. |
| `Text date={endDate} dateStyle="timer"` | `Text(endDate, style: .timer)`; `dateStyle="time"` → `Text(endDate, style: .time)`. Same client-side ticking, same reason: the card must stay live between pushes. |
| `Image uiImage={file://…}` from the App Group | `Image(uiImage: UIImage(contentsOfFile:))` reading from `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)`. **Keep the App Group** — the widget is still a separate process. Prefer shipping the nozzle glyph as an **asset in the widget extension's bundle** instead of a base64 PNG written at runtime; that deletes `nozzleIcon.ts` entirely and, with it, the `icon_uri` field on `/register`, `/register-start`, and `/sync` (coordinate with Trellis before removing it). Plate thumbnails still need the App Group, and the fixed `model.png` filename should become `model-<printerId>.png` to fix the latent fleet collision. |
| `printActivity.start(state, 'bambu://')` | `Activity.request(attributes:content:pushType:)`. **Deep link**: Live Activities use `.widgetURL(URL(string: "bambu://"))` on the view rather than a start parameter — set it in the widget body. |
| `inst.update(state)` | `await activity.update(ActivityContent(state:staleDate:))`. Consider setting `staleDate` (RN never did) so a card whose feed dies visibly goes stale instead of lying. |
| `inst.end('default'\|'immediate', state, date)` | `await activity.end(content, dismissalPolicy: .default / .immediate)`. Map: terminal print card → `.default`; orphan sweep and `/sync`-disowned cards → `.immediate`; drying finish → `.default`. |
| `printActivity.getInstances()` | `Activity<PrintAttributes>.activities` — **and this is strictly better than what RN had.** The whole reconcile-by-push-token dance exists because `expo-widgets` exposes no id and no content on an adopted activity. Natively you get `activity.id`, `activity.attributes`, and `activity.content.state`. Consider putting `printerId` (and `amsId`) into **`ActivityAttributes` (static)**, which makes every card self-identifying and lets you replace token-matching with id-matching. That is the single biggest simplification available — but see the warning below. |
| `inst.getPushToken()` / `addPushTokenListener` | `activity.pushToken` (`Data?`) and `for await tok in activity.pushTokenUpdates`. Hex-encode: `tok.map { String(format: "%02x", $0) }.joined()` — Trellis expects the hex string form. |
| `addPushToStartTokenListener` | `for await data in Activity<PrintAttributes>.pushToStartTokenUpdates` (iOS 17.2+). Same hex encoding, same `/register-start` POST. |
| `Platform.OS !== 'ios'` guards | Delete. But keep `ActivityAuthorizationInfo().areActivitiesEnabled` checks — the RN code's bare `try/catch` around `start()` was covering "user disabled Live Activities" and must not become a crash. |
| refs (`instances`, `lastPush`, `lastState`, `subs`, dry variants) | Plain properties on an `@MainActor final class LiveActivityCoordinator`. Keys: `Int` for print cards, a `struct DryKey: Hashable { let printerId: Int; let amsId: Int }` for drying cards (better than the `"pid:amsId"` string). |
| the effect firing on every `entries` change | An `AsyncStream`/Combine subscription on the status store, funnelling into `coordinator.apply(entries:)`. The 4 s throttle and `meaningfulChange` filter stay exactly as-is — do **not** replace them with Combine `throttle`, because the filter is content-aware, not time-only. |

Things that will be **hard** or need a different approach:

1. **Changing the ContentState wire format breaks server push.** `_envelope()` in `/Users/max/ai-projects/bambu-app/deploy/trellis/app.py` stringifies props because of `expo-widgets`. A native `ContentState` wants the fields **flat** under `content-state`. Plan this as a coordinated change (and note the failure mode is *silent*: APNs 200, no visible update). Consider keeping the exact same field names and types so only the envelope changes.
2. **`registerPushToken` is the identity of a card.** If you switch reconciliation to `activity.id`, Trellis's `/sync` contract (`{tokens:[…]} → {end:[…]}`) needs rethinking — but do **not** remove `/sync` naively: the reason it exists is that **APNs answers 200 for a card the user swiped away**, so the server can never detect dismissal on its own. Natively you can detect dismissal properly via `activity.activityStateUpdates` (`.dismissed` / `.ended`) and proactively tell the server — that is the right redesign, and it makes the 45 s polling reconcile unnecessary. Until that lands, port `/sync` as-is.
3. **Keep the two-mode ownership model.** The temptation natively is "the app can now do everything, drop server mode" — but the whole point of Trellis is cards that keep updating and starting **while the app is not running**. Both modes must survive, and the invariant "exactly one owner per card" is what killed the duplicate/zombie/mismatched-colour bugs. In server mode the native app must still never call `Activity.request`, including for drying cards (the RN code returns before the drying block).
4. **`LA_COLORS` must stay a fixed, theme-independent palette** shared verbatim with Trellis. In SwiftUI it is tempting to use `Color.green`/`.orange` or semantic colours — don't. Hardcode `#30D158 / #FF9F0A / #0A84FF / #FF453A / #8E9398` and `#FFB86C`, plus `T1 #F3F5F7` / `T2 #A4ABB2`, in a `LiveActivityPalette` enum that the widget target and the app share, and add a test asserting they equal the server's values.
5. **Every numeric threshold is load-bearing** and should move into a shared `LiveActivityTuning` enum with the comments intact: `minUpdate = 4 s`, `reconcile = 45 s`, `progressEps = 1 %`, `nozzleEps = 2 °C`, `bedEps = 2 °C`, `etaEps = 60 s`, `amsTempEps = 1 °C`, `humidityEps = 2 %`. The temperature clauses in particular were added because a heat-up that doesn't move progress/layer otherwise never pushes.
6. **`offline` and `connecting` must remain no-ops.** A WS blip must never end a card. Only `complete | error | idle` ends one. This is easy to lose when rewriting the branch as a `switch` with a `default:`.
7. **Drying detection**: `dry_time > 0` only — never `dry_status`. Values may arrive as **strings** on the WebSocket, so the Swift `PrinterStatus` decoder needs a lenient number decoder (`@LenientNumber` property wrapper or a custom `init(from:)`) for `dry_time`, `dry_target_temp`, `temp`, `humidity`, and `id`. This is a real risk: a strict `Codable` will throw and silently drop the whole AMS array.
8. **AMS HT identification**: `is_ams_ht == true || id >= 128`. Unit labels are one-based (`AMS 1`, `AMS 2`, `AMS HT`) and only shown when more than one unit is fitted.
9. **`activeNozzle` must come from the shared view-model**, not be re-derived in the widget. Port `present.ts`'s three-tier rule (driven → mapped `active_extruder` where **0 = RIGHT, 1 = LEFT** → hotter) and port its regression tests. Note Trellis deliberately ignores `active_extruder`; decide whether to align the server up or the app down, but document the choice.
10. **Push-to-start payloads need the `alert` block.** Apple's spec requires it and starts without it are accepted (200) then silently discarded. Whoever owns the server side must not "clean that up".
11. Live Activity **budget**: APNs priority 10 spends the device's budget, 5 is opportunistic. The server already splits these (`_urgent()`: first push, `stateLabel` flip, or `finished` flip → 10; drift → 5). If the native app starts pushing more often than the RN one, that budget becomes the limiting factor.
