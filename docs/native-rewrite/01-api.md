<!-- Generated as the port specification for the native Swift rewrite. -->
# Backend surface — every Bambuddy endpoint, auth, and response shape

## api

The network layer is two React-free client classes plus one shared type module. **All** HTTP traffic in the app goes through them; nothing else calls `fetch`.

| File | Lines | Role |
|---|---|---|
| `archive/mobile/src/api/bambuddyClient.ts` | 556 | `BambuddyClient` — every Bambuddy (FastAPI) endpoint the app uses |
| `archive/mobile/src/api/types.ts` | 485 | Response/request shapes (pure types + one helper fn) |
| `archive/mobile/src/api/texturizeClient.ts` | 136 | `TexturizeClient` — optional `stl-texturize` sidecar |
| `archive/mobile/src/api/__tests__/bambuddyClient.test.ts` | 315 | Behavioural contract — port these assertions verbatim |
| `archive/mobile/src/api/__tests__/texturizeClient.test.ts` | 88 | Sidecar contract |

All Bambuddy paths are prefixed `/api/v1`. Base URL is a self-hosted host, e.g. `https://bambuddy.example.com` (placeholder — the real host is never in code).

---

### 1. Construction, configuration, and the three auth mechanisms

```ts
export interface BambuddyClientConfig {
  baseUrl: string;                             // e.g. https://bambuddy.example.com
  apiKey: string;                              // Bambuddy scoped key, sent as X-API-Key
  extraHeaders?: Record<string, string>;       // e.g. CF-Access-Client-Id/Secret if Cloudflare Access is added
  adminUsername?: string;                      // optional admin login (see §3)
  adminPassword?: string;
}
```

Constructor behaviour (exact):
- `this.baseUrl = cfg.baseUrl.replace(/\/+$/, '')` — **strips ALL trailing slashes**. Test: `'https://x/'` → `'https://x'`.
- `this.extraHeaders = cfg.extraHeaders ?? {}`
- `this.adminUsername = cfg.adminUsername?.trim() || undefined` (trim, and empty-string → undefined)
- `this.adminPassword = cfg.adminPassword || undefined` (**no trim** — passwords may legitimately have leading/trailing spaces)

Computed properties:
- `get hasAdminLogin(): boolean` → `!!(this.adminUsername && this.adminPassword)`. Drives Settings UI and the slice-override path (advanced overrides are only attempted when admin creds exist).
- `get wsBaseUrl(): string` → `this.baseUrl.replace(/^http/, 'ws')`. `https://x` → `wss://x`; `http://x` → `ws://x`. (Regex is anchored `^http`, so it rewrites the scheme only.)

**The three auth mechanisms — this is the single most important thing to get right:**

| Mechanism | How | Used by |
|---|---|---|
| **A. `X-API-Key` header** | `{ 'X-API-Key': apiKey, ...extraHeaders }` on every `req()` | ~all JSON endpoints, SD-card file endpoints, `<Image>` loads of SD-card thumbnails, the texturize sidecar |
| **B. Camera *stream* token in `?token=`** | Minted via `POST /api/v1/printers/camera/stream-token`, TTL **60 min** | MJPEG stream, camera snapshot, **library thumbnails**, **plate thumbnails**, **print-log thumbnails**. Sending `X-API-Key` instead returns **401** |
| **C. Admin JWT `Authorization: Bearer …`** | Minted via `POST /api/v1/auth/login`, TTL 24 h, **no refresh endpoint** | `local-presets` writes, `maintenance/items/{id}/perform` (see §3) |

Plus two one-off tokens: the **WS token** (`POST /api/v1/auth/ws-token`, used as `?token=` on the socket) and the **slicer/download token** (`POST /api/v1/library/files/{id}/slicer-token`, embedded in the download *path*, not a query).

Config is persisted in the iOS Keychain via `expo-secure-store` under key `bambu.config`, with `keychainAccessible: WHEN_UNLOCKED_THIS_DEVICE_ONLY` (`archive/mobile/src/config/secureConfig.ts`). Stored fields: `baseUrl`, `apiKey`, `cameraToken?`, `theme?`, `printerId?`, `printerName?`, `pushUrl?`, `serverPush?`, `texturizeUrl?`, `texturize?`, `adminUsername?`, `adminPassword?`.

---

### 2. The core request primitive

```ts
private headers(): Record<string, string> {
  return { 'X-API-Key': this.apiKey, ...this.extraHeaders };
}

private async req(path: string, init?: RequestInit): Promise<Response> {
  const res = await fetch(this.baseUrl + path, {
    ...init,
    headers: { ...this.headers(), ...(init?.headers ?? {}) },
  });
  if (!res.ok) {
    const body = await res.text().catch(() => '');
    throw new Error(`Bambuddy ${init?.method ?? 'GET'} ${path} -> HTTP ${res.status} ${body}`.trim());
  }
  return res;
}
```

Notes that matter for the port:
- **No timeout by default.** Only `probe()` (8000 ms) and `TexturizeClient.healthy()` (4000 ms) use `AbortController`. Everything else can hang indefinitely — the UI compensates (polling loops, the camera's "no stream URL ever arrived" safety net in `Overlays.tsx:49`).
- **No retry anywhere** except the single admin-JWT 401/403 re-login retry (§3).
- **Error string format is load-bearing**: `Bambuddy {METHOD} {path} -> HTTP {status} {body}`. Both `apiErrorDetail()` and `classifyConnectError()` parse it, and `adminReq` substring-matches `'administrative operations'` in it.
- Caller-supplied headers *override* the auth headers (spread order), which is what lets `adminReq` drop `X-API-Key` entirely.
- `res.text()` failures are swallowed (`.catch(() => '')`) so a body-read error never masks the status.

#### `apiErrorDetail(e: unknown): string`

Surfaces the API's JSON `detail` instead of the raw wrapper string (e.g. a drying 409's `"AMS is busy"`):

```ts
export function apiErrorDetail(e: unknown): string {
  const s = String(e instanceof Error ? e.message : e);
  const m = s.match(/\{"detail"\s*:\s*"([^"]+)"/);
  return m ? m[1] : s;
}
```

It is a **regex over the concatenated error string**, not a JSON parse — deliberately, because the detail is embedded inside the wrapper message. Non-Bambuddy errors pass through unchanged (`new Error('plain failure')` → `'plain failure'`).

#### `classifyConnectError(e): { kind: ConnectErrorKind; message: string }`

`type ConnectErrorKind = 'timeout' | 'auth' | 'notFound' | 'server' | 'network' | 'unknown'`.

Whole point (from the doc comment): *split the two failures that otherwise look identical — server-unreachable vs. key-rejected — so a silent "Connecting" forever becomes an actionable error at the moment of entry.*

Decision order (must be preserved — the HTTP check runs **before** the network check):

1. `err.name === 'AbortError' || /\babort/i.test(msg)` → `timeout`: *"Timed out reaching the server. Check the URL, and that your phone can actually reach that host (same Wi‑Fi / VPN)."*
2. `msg.match(/HTTP (\d{3})/)`:
   - `401 | 403` → `auth`: `` `Server reached, but the API key was rejected (HTTP ${code}). Double-check the key.` ``
   - `404` → `notFound`: *"Reached that host, but it doesn't respond like a Bambuddy server (HTTP 404). Check the URL."*
   - `>= 500` → `server`: `` `The Bambuddy server returned an error (HTTP ${code}). It may be down or restarting.` ``
   - else → `unknown`: `` `Unexpected response from the server (HTTP ${code}).` ``
3. `err.name === 'TypeError'` **or** `/network request failed|failed to fetch|econnrefused|enotfound|getaddrinfo|certificate|ssl|tls|handshake/i` → `network`: *"Can't reach that URL. Check the scheme (https), host/port, your network, and that the server's TLS certificate is trusted by the phone."*
4. Fallback → `unknown` with the raw message.

Comment on step 3: *WinterCG / RN network-layer failures: DNS, refused, or an untrusted TLS cert (all surface as a TypeError / "Network request failed" with no HTTP status).*

---

### 3. Admin JWT state machine (`adminReq`) — the trickiest stateful piece

Documented rationale: *Bambuddy **CATEGORICALLY** refuses API keys on "administrative" endpoints (403 `"API keys cannot be used for administrative operations"`) regardless of key permissions — those need a JWT from `POST /auth/login`.*

State: `private jwt: string | null = null; private jwtMintedAt = 0;`
Constant: `private static readonly JWT_MAX_AGE_MS = 23 * 60 * 60 * 1000;` — comment: *JWTs live 24h with no refresh — re-login proactively at 23h so a long-running app doesn't hit mid-action expiry as the norm (the 401-retry below still covers server-side invalidation).*

```ts
private async adminLogin(): Promise<string> {
  const res = await fetch(`${this.baseUrl}/api/v1/auth/login`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', ...this.extraHeaders },   // NOTE: no X-API-Key
    body: JSON.stringify({ username: this.adminUsername, password: this.adminPassword }),
  });
  const body = await res.json().catch(() => ({}) as Record<string, unknown>);
  if (body?.requires_2fa) throw new Error('Admin login failed: this account has 2FA enabled, which the app can’t complete. Use a non-2FA admin account.');
  const token = body?.access_token as string | undefined;
  if (!res.ok || !token) throw new Error(`Admin login failed (HTTP ${res.status}) — check the admin username/password in Settings.`);
  this.jwt = token; this.jwtMintedAt = Date.now();
  return token;
}
```

`requires_2fa` is checked **before** `res.ok` — a 2FA account can answer 200 with `{requires_2fa:true}` and no token.

`adminReq(path, init)` state machine:

```
        ┌── hasAdminLogin == false ──> req(path, init)  [X-API-Key]
        │                                 └─ on error whose message contains 'administrative operations'
        │                                    rethrow: 'This action needs the Bambuddy admin login.
        │                                              Add the admin username + password in Settings → Edit, then retry.'
        │                                 └─ any other error: rethrow untouched
start ──┤
        └── hasAdminLogin == true
              stale = !jwt || (Date.now() - jwtMintedAt) > 23h
              token = stale ? await adminLogin() : jwt
              res = attempt(token)                     // Authorization: Bearer <tok>, extraHeaders, init.headers
              if res.status is 401 or 403:
                  token = await adminLogin()           // ONCE — invalidated server-side (restart, password change)
                  res = attempt(token)
              if !res.ok: throw `Bambuddy {METHOD} {path} -> HTTP {status} {body}`
```

`attempt()` header order: `{ Authorization: 'Bearer '+tok, ...this.extraHeaders, ...(init?.headers ?? {}) }` — **`X-API-Key` is deliberately absent** (test asserts `opts.headers['X-API-Key']` is `undefined`). The JWT is cached across calls: two `performMaintenance` calls with fresh creds produce exactly 3 fetches (1 login + 2 performs).

`verifyAdminLogin(): Promise<void>` → just `await this.adminLogin()`; used as a Settings pre-flight.

**Admin-only calls in this client:** `upsertLocalPreset` (both the PUT and the POST leg), `performMaintenance`. Per the project CLAUDE.md, settings *writes* and smart-plug config writes are also admin-only, but the app never issues them (it only reads `/settings/` and reports plug automations).

---

### 4. Complete endpoint inventory

Auth column: **K** = `X-API-Key`, **T** = camera stream token in `?token=`, **J** = admin JWT via `adminReq`, **P** = path-embedded slicer token, **—** = unauthenticated.

#### Printers, connection, control

| Method | HTTP | Path | Auth | Returns / notes |
|---|---|---|---|---|
| `listPrinters()` | GET | `/api/v1/printers/` | K | `Printer[]` |
| `probe(timeoutMs = 8000)` | GET | `/api/v1/printers/` | K | `Printer[]`; `AbortController` + `setTimeout`, `clearTimeout` in `finally`. Throws on any failure → feed to `classifyConnectError` |
| `getStatus(printerId)` | GET | `/api/v1/printers/{id}/status` | K | `PrinterStatus` |
| `clearHms(printerId)` | POST | `/api/v1/printers/{id}/hms/clear` | K | void. Clears benign mid-print HMS notices (H2C) |
| `clearPlate(printerId)` | POST | `/api/v1/printers/{id}/clear-plate` | K | void |
| `queueResume(printerId)` | POST | `/api/v1/queue/printer/{id}/resume` | K | void |
| `setLight(printerId, on)` | POST | `/api/v1/printers/{id}/chamber-light?on={true\|false}` | K | void |
| `pause(printerId)` | POST | `/api/v1/printers/{id}/print/pause` | K | void |
| `resume(printerId)` | POST | `/api/v1/printers/{id}/print/resume` | K | void |
| `stop(printerId)` | POST | `/api/v1/printers/{id}/print/stop` | K | void |
| `setSpeed(printerId, mode)` | POST | `/api/v1/printers/{id}/print-speed?mode={1..4}` | K | void. `SpeedMode = 1\|2\|3\|4` = silent \| standard \| sport \| ludicrous |
| `getSettings()` | GET | `/api/v1/settings/` | K | `AppSettings`. Read works with the key; **writes are admin-JWT only** (app never writes) |

> **GOTCHA (an entire test block named "the two endpoints that were wrong"):** `clearPlate` ≠ `queueResume`. `clearPlate` acknowledges the plate is clear so the scheduler may dispatch the next job, and **sends no MQTT, so it works without LAN Developer Mode**. `queueResume` clears the previous-**failure** gate and restores skipped items — it never cleared `awaiting_plate_clear`, so the "Plate is clear" button appeared to work and changed nothing.

#### Drying (AMS)

```ts
async dryingStart(printerId, amsId, opts: { temp: number; hours: number; filament?: string; rotate?: boolean }): Promise<void> {
  const q = new URLSearchParams({ ams_id: String(amsId), temp: String(opts.temp), duration: String(opts.hours) });
  if (opts.filament) q.set('filament', opts.filament);
  if (opts.rotate !== undefined) q.set('rotate_tray', String(opts.rotate));
  await this.req(`/api/v1/printers/${printerId}/drying/start?${q}`, { method: 'POST' });
}
```

- `POST /api/v1/printers/{id}/drying/start?ams_id=&temp=&duration=[&filament=][&rotate_tray=]` — **`duration` is HOURS, not minutes** (Bambuddy validates 1–24; minutes would 400).
- Temp is 45–85 °C server-side but **the AMS 2 Pro's hardware max is 65 °C** (85 = AMS-HT only) — clamp via `presentDryer`'s `maxTemp` *before* calling.
- `rotate_tray` spins the spool for even drying. Both optional params are omitted entirely when absent (exact URL asserted in tests).
- A blocked start returns **409 with a human reason** — show via `apiErrorDetail()` (e.g. `"AMS is busy"`).
- `dryingStop(printerId, amsId)` → `POST /api/v1/printers/{id}/drying/stop?ams_id={amsId}`.

#### Reprint (a removed endpoint, re-implemented)

```ts
async reprint(archiveId: number, printerId: number): Promise<void> {
  await this.enqueue({ printer_id: printerId, archive_id: archiveId, use_ams: true });
}
```

> **GOTCHA:** `POST /archives/{id}/reprint` is **GONE** — Bambuddy answers **410** with *"Direct archive reprint has been removed. Create a print queue item with POST /queue/."* The queue accepts an `archive_id` directly, so no library-file lookup is needed (archives do not expose one anyway).

#### Realtime + camera

| Member | Method/Path | Auth | Notes |
|---|---|---|---|
| `mintWsToken()` | POST `/api/v1/auth/ws-token` | K | Returns `json().token` |
| `mintCameraToken()` | POST `/api/v1/printers/camera/stream-token` | K | Returns `json().token`. TTL **60 min** |
| `snapshotUrl(printerId, token)` | — | T | `` `${base}/api/v1/printers/${id}/camera/snapshot?token=${encodeURIComponent(token)}` `` |
| `streamUrl(printerId, token, fps = 10)` | — | T | `` `${base}/api/v1/printers/${id}/camera/stream?token=${encodeURIComponent(token)}&fps=${fps}` `` |
| `diagnoseCamera(printerId)` | **POST** `/api/v1/printers/{id}/camera/diagnose` | K | Read-only despite POST |

`diagnoseCamera` response type (declared inline, not in `types.ts`):

```ts
{ protocol: string; port: number; overall_status: string; summary_code: string;
  stages: { name: string; status: string; code: string | null }[] }
```

> **GOTCHA:** *MJPEG multipart live stream (`multipart/x-mixed-replace`) — render in a WebView `<img>`. Token MUST be in the query; the `X-API-Key` header is **rejected (401)** on stream/snapshot.*

The WebSocket is **not** in the client (it lives in `src/realtime/usePrinterStatus.ts`) but is part of the same API surface:
`new WebSocket(\`${client.wsBaseUrl}/api/v1/ws?token=${token}\`)` — one socket for the *whole fleet*, per-client not per-printer. Frames: `{ type: 'printer_status', printer_id: number, data: PrinterStatus }`. Reconnect delay `RECONNECT_MS = 12_000`; REST fallback poll `POLL_MS = 3000` while the socket is down.

#### Library

| Member | Method/Path | Auth | Returns |
|---|---|---|---|
| `listFiles()` | GET `/api/v1/library/files` | K | `LibraryFile[]` |
| `uploadFile(uri, name, onProgress?)` | POST `/api/v1/library/files` | K | `{ id: number }` — see §5 |
| `getFileDetail(fileId)` | GET `/api/v1/library/files/{id}` | K | `LibraryFile` **with `metadata`** (not present on the list) |
| `getPlates(fileId)` | GET `/api/v1/library/files/{id}/plates` | K | `PlatesResponse` |
| `getGcode(fileId)` | GET `/api/v1/library/files/{id}/gcode` | K | `string` (raw text, can be ~70 MB) |
| `gcodePath(fileId)` | — (path only) | K via `authHeaders()` | `/api/v1/library/files/{id}/gcode` |
| `deleteFile(fileId)` | DELETE `/api/v1/library/files/{id}` | K | void. Needs the Manage-Library scope (**Bambuddy ≥ 0.2.4.8**, issue #1832) |
| `mintFileDownloadUrl(fileId, filename?)` | POST `/api/v1/library/files/{id}/slicer-token` then build URL | P | see below |
| `fileThumbUrl(fileId, token, thumbnailPath?)` | — | T | see below |
| `plateThumbUrl(fileId, plateIndex, token)` | — | T | `` `${base}/api/v1/library/files/${id}/plate-thumbnail/${plateIndex}?token=…` ``, **1-based** index; `''` when no token |

```ts
/** Tokenized library-file download URL (the slicer-token path — token IS the auth, so the URL
 *  works from a WebView fetch with no headers). Single-use, short-lived; mint per view. */
async mintFileDownloadUrl(fileId: number, filename?: string): Promise<string> {
  const data = await (await this.req(`/api/v1/library/files/${fileId}/slicer-token`, { method: 'POST' })).json();
  const token = data.token ?? data.slicer_token ?? data.download_token ?? data.value;   // 4 accepted field names
  if (!token) throw new Error('slicer-token response had no recognizable token field');
  return `${this.baseUrl}/api/v1/library/files/${fileId}/dl/${encodeURIComponent(token)}/${encodeURIComponent(filename || `model-${fileId}.stl`)}`;
}
```

Fallback filename is `model-{fileId}.stl`. Both the token and filename are `encodeURIComponent`-escaped into the **path**.

```ts
/** Library thumbnails are gated by a camera *stream* token (?token=), NOT X-API-Key. */
fileThumbUrl(fileId: number, token: string | null, thumbnailPath?: string | null): string {
  if (!token || thumbnailPath === null) return '';
  return `${this.baseUrl}/api/v1/library/files/${fileId}/thumbnail?token=${encodeURIComponent(token)}`;
}
```

The `thumbnailPath === null` check is a **strict null check**, not falsy: `undefined` (field absent, e.g. list rows) still produces a URL; explicit `null` (server says "no thumbnail") returns `''` so no request is made.

#### Printer onboard storage (SD card) — `X-API-Key`, *not* the camera token

| Member | Method/Path | Notes |
|---|---|---|
| `listPrinterFiles(printerId, path = '/')` | GET `/api/v1/printers/{id}/files?path=…` | `PrinterFileList`. Uses `encodeURIComponent(path)` (**not** `URLSearchParams`) |
| `printerFileDownloadUrl(printerId, path)` | — | `` `${base}/api/v1/printers/${id}/files/download?${new URLSearchParams({path})}` `` — pair with `authHeaders()` (401 otherwise) |
| `printerPlateThumbUrl(printerId, path, plateIndex = 1)` | — | `/api/v1/printers/{id}/files/plate-thumbnail/{plateIndex}?path=…` |
| `getPrinterFilePlates(printerId, path)` | GET `/api/v1/printers/{id}/files/plates?path=…` | `PrinterFilePlates` |
| `deletePrinterFile(printerId, path)` | DELETE `/api/v1/printers/{id}/files?path=…` | Irreversible |
| `getPrinterFileGcode(printerId, path)` | GET `/api/v1/printers/{id}/files/gcode?path=…` | raw text |
| `printerGcodePath(printerId, path)` | — (path only) | `/api/v1/printers/{id}/files/gcode?path=…` for the WebView layer viewer |
| `authHeaders()` | — | `= this.headers()`, i.e. `{ 'X-API-Key', ...extraHeaders }` |

> **GOTCHA — two different query encoders on purpose.** `listPrinterFiles` uses `encodeURIComponent`; every other SD-card method uses `new URLSearchParams({ path })`, which is **`application/x-www-form-urlencoded`**: spaces become `+`, and a literal `%20` inside a filename becomes `%2520`. Tests pin both:
> - `/Bambu_Cube_XYZ.gcode.3mf` → `path=%2FBambu_Cube_XYZ.gcode.3mf`
> - `/Print%20plate Donor.gcode.3mf` → `path=%2FPrint%2520plate+Donor.gcode.3mf`
>
> Comment: *Spaces → `+`/`%20`; a literal "%20" in the NAME must round-trip as `%2520`, not collapse to a space.* Both forms genuinely exist on the real SD card. A native port that uses percent-encoding uniformly **will break** the space case unless the server accepts both — treat `+`-for-space as the verified-working form.

> **GOTCHA:** *These SD-card endpoints use `X-API-Key` (verified live), **NOT** the camera `?token=` that gates library thumbnails.* `authHeaders()` exists because `expo-image`'s `source.headers` and `File.downloadFileAsync` take a header map — endpoints fetched outside `req()`.

#### Slicing

| Member | Method/Path | Auth | Returns |
|---|---|---|---|
| `getPresets()` | GET `/api/v1/slicer/presets` | K | `any` (untyped) |
| `listLocalPresets()` | GET `/api/v1/local-presets/` | K | `{ process?: {id,name}[]; filament?: {id,name}[]; printer?: {id,name}[] }` |
| `upsertLocalPreset(name, presetType, setting)` | PUT/POST `/api/v1/local-presets/[{id}]` | **J** | `number` (row id) |
| `slice(fileId, body)` | POST `/api/v1/library/files/{id}/slice` | K | `{ job_id: number }` |
| `getSliceJob(jobId)` | GET `/api/v1/slice-jobs/{jobId}` | K | `any` |

```ts
/** Upsert the app's reusable override preset (ADMIN-gated — preset writes 403 on scoped keys).
 *  `setting` is a delta JSON with `inherits` (see library/sliceOverrides.ts); Bambuddy resolves the
 *  base at slice time. One row per (name), updated in place so rows don't accumulate per slice. */
async upsertLocalPreset(name, presetType: 'process' | 'filament', setting: Record<string, unknown>): Promise<number> {
  const existing = ((await this.listLocalPresets())[presetType] ?? []).find((p) => p.name === name);
  if (existing) {
    await this.adminReq(`/api/v1/local-presets/${existing.id}`, {
      method: 'PUT', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ setting }),                       // PUT body: { setting } only
    });
    return existing.id;
  }
  const created = await (await this.adminReq('/api/v1/local-presets/', {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ name, preset_type: presetType, setting }),   // POST body: name + preset_type + setting
  })).json();
  if (created?.id == null) throw new Error('local-preset create returned no id');
  return created.id;
}
```

Note the **read leg uses the API key** (`listLocalPresets` via `req`) while only the **writes** go through `adminReq`.

Actual `slice()` body the Print Wizard sends (`archive/mobile/src/components/Overlays.tsx:1027`):

```ts
const { job_id } = await client.slice(file.id, {
  printer_preset: presets?.printer,      // preset ref object from /slicer/presets
  process_preset: processRef,            // preset ref, OR { source: 'local', id: String(localPresetId) }
  filament_preset: filamentRef,          // same
  plate: selectedPlate,                  // 1-based plate index
  bed_type: bedType,
  export_3mf: true,
});
```

Slice-job polling loop (also in `Overlays.tsx`): up to **90 iterations at 1500 ms** (≈2¼ min) then `throw new Error('Slice timed out')`. Terminal states read from `j.status`: `'completed'` → `j.result` (a `SliceResult`); `'failed'` or `'error'` → `throw new Error(j.error || 'Slice failed')`. Progress is faked: `setSlicePct(p => Math.min(95, p + 6))` per poll, starting at 5, 100 on success.

#### Queue

| Member | Method/Path | Body |
|---|---|---|
| `listQueue()` | GET `/api/v1/queue/` | — → `QueueItem[]` |
| `enqueue(body)` | POST `/api/v1/queue/` | arbitrary JSON → `any` |
| `queueAction(itemId, action)` | POST `/api/v1/queue/{itemId}/{action}` | `action: 'start' \| 'stop' \| 'cancel'` |

Real enqueue body from the wizard (`Overlays.tsx:1076`):

```ts
await client.enqueue({
  printer_id: printerId,
  library_file_id: result?.library_file_id ?? file.id,
  use_ams: true,
  ams_mapping: [slot],     // ← see gotcha
  plate_id: selectedPlate,
});
```

> **GOTCHA (real shipped bug):** *`ams_mapping` is Bambu's own print-command field: **indexed by FILAMENT, valued by GLOBAL tray id*** (Bambuddy decodes it with `gid>=254 → external`, `>=128 → HT`, else `gid//4`, `gid%4`). The old `Array(4).fill(-1); mapping[slot] = 0` had **index and value swapped**, so it debited the wrong spool and could not address anything past the first AMS unit at all.

#### AMS

- `amsLoad(printerId, trayId)` → `POST /api/v1/printers/{id}/ams/load?tray_id={trayId}`
- `amsUnload(printerId)` → `POST /api/v1/printers/{id}/ams/unload`

#### Inventory

- `listSpools()` → `GET /api/v1/inventory/spools` → `Spool[]`
- `listAssignments(printerId?)` → `GET /api/v1/inventory/assignments[?printer_id={id}]` → `SlotAssignment[]`, **`try/catch` → `[]`**: *Returns `[]` on failure so the AMS view falls back to status-only tray data.*

#### Print history

- `getPrintLog(limit = 50)` → `GET /api/v1/print-log/?limit={limit}` → `PrintLogPage`
- `getArchiveStats()` → `GET /api/v1/archives/stats` → `ArchiveStats`
- `printLogThumbUrl(entryId, token, thumbnailPath?)` → `` `${base}/api/v1/print-log/${entryId}/thumbnail?token=…` `` — **camera stream token**, identical null-guard logic to `fileThumbUrl`

#### Sensor history

```ts
async sensorHistory(printerId, kind: 'bed'|'nozzle'|'nozzle_2'|'chamber', hours: number): Promise<SensorHistory | null> {
  try { return await (await this.req(`/api/v1/printer-sensor-history/${printerId}?hours=${hours}&kinds=${kind}`)).json(); }
  catch { return null; }
}
```

`hours` is **capped at 168 server-side**. Query param is `kinds` (plural) even though one kind is sent. Swallows errors → `null`. Used for the plate-cooldown curve and reading room temperature off the idle floor (`src/cooling/useCooldown.ts`).

#### Smart plugs

| Member | Method/Path | Failure behaviour |
|---|---|---|
| `getPlug(printerId)` | GET `/api/v1/smart-plugs/by-printer/{id}` | `try/catch` → **`null`** (404 = no plug bound) |
| `listPlugs()` | GET `/api/v1/smart-plugs/` | `try/catch` → **`[]`**; unwraps `Array.isArray(r) ? r : (r?.items ?? [])` |
| `plugStatus(plugId)` | GET `/api/v1/smart-plugs/{id}/status` | throws |
| `plugControl(plugId, on)` | POST `/api/v1/smart-plugs/{id}/control` body `{ action: on ? 'on' : 'off' }` | throws |

> **GOTCHA:** *by-printer returns a **SINGLE** plug, so only one plug may be bound to a printer — bind anything else (AMS, peripherals) to no printer and reach it via `listPlugs`.* This is why the recent commit `4bde037 fix(power): list every socket, including the printer's own` exists.
> Plug **automation fields are read-only to the app**: *writes to `/smart-plugs/{id}` are admin-only and 403 with a scoped API key* — the app can only ever REPORT them.

#### Maintenance

- `getMaintenance(printerId)` → `GET /api/v1/maintenance/printers/{id}` → `MaintenancePrinter`
- `getMaintenanceSummary()` → `GET /api/v1/maintenance/summary` → `MaintenanceSummary`
- `performMaintenance(itemId, notes?)` → **`adminReq`** `POST /api/v1/maintenance/items/{itemId}/perform`, body `JSON.stringify(notes ? { notes } : {})`, `Content-Type: application/json`

> **GOTCHA:** *Body is **REQUIRED** (a bodyless POST **422**s).* Hence the `{}` fallback. And: *ADMIN-gated: Bambuddy refuses API keys here regardless of permissions (verified live: key → 403, JWT → past auth).*

#### MakerWorld import

| Member | Method/Path | Auth | Notes |
|---|---|---|---|
| `makerWorldStatus()` | GET `/api/v1/makerworld/status` | K | `MakerWorldStatus`; `can_download` gates import |
| `resolveMakerWorld(url)` | POST `/api/v1/makerworld/resolve` body `{ url }` | K | `MakerWorldResolved`. No cloud token needed. Throws on **400** (not a MW url) / **404** (model not found) |
| `importMakerWorld(body)` | POST `/api/v1/makerworld/import` | K | MUTATING — downloads the 3MF into the library. Requires `status.can_download === true` |
| `makerworldThumbUrl(cdnUrl)` | — | **—** | `` `${base}/api/v1/makerworld/thumbnail?url=${encodeURIComponent(cdnUrl)}` ``; returns `''` for null/undefined. *Unauthenticated by design — URL is sufficient* |

---

### 5. Upload — the single most portable-hostile piece

```ts
/**
 * Upload a local file (RN `file://` URI) to the library via expo-file-system's native multipart
 * upload — NOT global fetch. Expo's WinterCG fetch rejects RN's {uri,name,type} FormData parts
 * ("Unsupported FormDataPart implementation"); the native File.upload reads the URI natively.
 * Backend field name is `file`; response is { id, ... }.
 */
async uploadFile(uri: string, name: string, onProgress?: (fraction: number) => void): Promise<{ id: number }> {
  const res = await new File(uri).upload(this.baseUrl + '/api/v1/library/files', {
    httpMethod: 'POST',
    uploadType: UploadType.MULTIPART,
    fieldName: 'file',
    mimeType: 'application/octet-stream',
    headers: this.headers(),
    onProgress: onProgress ? ({ bytesSent, totalBytes }) => onProgress(totalBytes > 0 ? bytesSent / totalBytes : 0) : undefined,
  });
  if (res.status < 200 || res.status >= 300) {
    throw new Error(`Bambuddy POST /api/v1/library/files -> HTTP ${res.status} ${res.body}`.trim());
  }
  return JSON.parse(res.body) as { id: number };
}
```

Exact contract to preserve: **`multipart/form-data`**, single part named **`file`**, content type **`application/octet-stream`**, `X-API-Key` (+ extraHeaders) headers, progress as `bytesSent / totalBytes` guarded against a zero `totalBytes`, success = **any 2xx** (not just 200), error string in the same `Bambuddy POST … -> HTTP …` shape. The `name` parameter is accepted but **not passed to `File.upload`** — the filename comes from the URI.

---

### 6. `types.ts` — response shapes with the field-level gotchas

`Printer`: `id, name, model ("A1" | "H2C" | …), nozzle_count (2 on H2-series dual-extruder), location?, is_active, serial_number?, ip_address?`

`HmsError`: `code?, attr?, module?, severity?, full_code?` (e.g. `"0500050000010007"`), `actions?: unknown[]`. > *Present even mid-print for benign notices — presence alone does NOT mean the print failed.*

`PrinterStatus` — the big one. Required: `connected: boolean`, `state: string` (`RUNNING | PAUSE | IDLE | FINISH | FAILED | …`), `progress: number | null` (%), `remaining_time: number | null` (**minutes**), `layer_num`, `total_layers`, `subtask_name`, `chamber_light` (all nullable). Then:

- `temperatures` (nullable object): `nozzle?, nozzle_target?, nozzle_heating?`, `nozzle_2?, nozzle_2_target?, nozzle_2_heating?` (second extruder, H2-series), `bed?, bed_target?, bed_heating?`, `chamber?, chamber_target?, chamber_heating?` (enclosed machines only).
- `ams?: Array<{ id, humidity?, temp?, is_ams_ht?, module_type?, dry_time?, dry_status?, dry_sub_status?, dry_target_temp?, dry_filament?, dry_sf_reason?, tray: Array<{ id, tray_type?, tray_color?, remain?, tray_uuid?, drying_temp?, drying_time? }> }>`

> **GOTCHA (crashes):** *the WebSocket delivers these as **STRINGS** (`"30.4"`); REST sends real numbers. Read via `asNum()` (`src/dashboard/present.ts`) before any number method — a raw `.toFixed()` crashes.* Applies to `humidity`, `temp`, `dry_time`, `dry_target_temp`, `drying_temp`, `drying_time`, and the whole `nozzle_rack`.
>
> **GOTCHA (state detection):** *`dry_time` — Minutes **REMAINING** in the drying cycle. `> 0` is **THE** "actively drying" signal — verified live: `dry_status` stayed 0 mid-cycle, so it must NOT be used as the active flag.* `dry_status`/`dry_sub_status` are informational only.
>
> `dry_target_temp` is *cached by Bambuddy only for cycles it started itself; null when the cycle was started elsewhere (printer screen / Bambu Handy)*. `is_ams_ht` → dries to 85 °C; the AMS 2 Pro tops out at 65 °C. `dry_sf_reason` holds refuse-codes **0–8**, decoded via `DRY_BLOCKERS` in `src/ams/dryer.ts`. Tray `drying_temp`/`drying_time` come from RFID/preset; **0 = no data**.

- `tray_now?: number` — active tray index across the AMS (Bambu `tray_now`; **255 = none/external**). > *on H2-series firmware this can degenerate to a **LOCAL** slot (0-3), which is ambiguous once more than one 4-slot unit is fitted — see `amsRouting()` before treating it as a global id.*
- `ams_extruder_map?: Record<string, number>` — > *Bambuddy derives this from each unit's `info` bits and **SKIPS** units reporting `0xE` ("no fixed extruder"). It is **merge-only and never pruned**, so entries can be stale residue. Do NOT trust it when `fila_switch.installed`.*
- `fila_switch?: { installed?, in_slots?: number[], out_extruders?: number[], stat?, info? }` — Filament Track Switch. > *`in_slots` is per inlet, **packed `(ams_id << 8) | slot`**, `-1` when empty. `out_extruders` is the extruder each outlet feeds (`0xE` = none).*
- `ams_exists?`, `ams_filament_backup?`, `hms_errors?: HmsError[]`, `print_error?: number`
- `speed_level?: number` — *1 Silent | 2 Standard | 3 Sport | 4 Ludicrous* — the printer's **real** speed mode
- `stg_cur_name?: string | null` — sub-stage, e.g. `"Changing filament"`, `"Auto bed leveling"`
- `awaiting_plate_clear?: boolean` — *True after FINISH until the user confirms the plate is clear (gates the queue)*
- `door_open?: boolean`
- `developer_mode?: boolean | null` — **LAN Developer Mode.** > *`false` = the firmware **REJECTS every command** Bambuddy sends (status still flows, so nothing looks wrong). **Absent on the WebSocket feed** — fetch via REST, and treat `undefined` as "not yet known", **never** as off.* See `src/capabilities/lanMode.ts`.
- `wifi_signal?: number` (dBm), `active_extruder?`, `supports_drying?`, `supports_drying_while_printing?`, `supports_chamber_heater?`
- `current_archive_id?: number | null` — reprint target
- `nozzles?: Array<{ nozzle_type?, nozzle_diameter? }>` — index 0 = nozzle/left, 1 = nozzle_2/right
- `nozzle_rack?: Array<{ id, nozzle_type? ("HS01"|"HS00"|…), nozzle_diameter?, wear?, max_temp?, serial_number?, filament_color?, filament_id?, filament_type? }>` — H2-series swappable-nozzle store. > *Empty slots carry serial `"N/A"` / `max_temp` 0. Numeric fields may arrive as strings over the WS.*

`LibraryFile`: `id, filename, file_type ('stl'|'3mf'|'gcode.3mf'), file_size?, thumbnail_path?, sliced_for_model?, print_time_seconds?, filament_used_grams?, print_name?, metadata?: FileMetadata | null` (*Present on GET `/library/files/{id}` (detail), not on the list*).

`FileMetadata`: `total_layers?, layer_height?, nozzle_diameter?, nozzle_temperature?, bed_type?, sliced_for_model?, filament_type?, filament_color?, filament_used_mm?, filament_used_g?, print_time_seconds?, filament_slots?: Array<{slot_id, used_g?, type?, color?}>`, plus an open index signature `[k: string]: unknown`.

`PrinterFile`: `name, is_directory, size, path, mtime?`; `PrinterFileList`: `{ path, files }`.

`PlateFilament`: `slot_id, type? ("PLA"|"PETG-CF"|…), color? ("#RRGGBB"), used_grams?, used_meters?`.
`PlateInfo`: `index` (**1-based**), `name?, objects?: string[], object_count?, has_thumbnail?, thumbnail_url?, print_time_seconds?, filament_used_grams?, filaments?: PlateFilament[]`.
`PlatesResponse`: `{ file_id, filename, plates, is_multi_plate, embedded_printer?, embedded_process? }`.
`PrinterFilePlates`: `{ printer_id, path, filename, plates }`.

`QueueItem`: `id, status ('pending'|'printing'|'completed'|'failed'|…), position?, printer_id?, printer_name?, library_file_name?, archive_name?, library_file_thumbnail?, archive_thumbnail?, print_time_seconds?`.

`SensorPoint`: `{ recorded_at?, value?, target? }` — > *`recorded_at` is **NAIVE and in UTC***. `SensorSeries`: `{ sensor_kind?, data?, min_value?, max_value?, avg_value? }`. `SensorHistory`: `{ printer_id?, series? }`.

`SmartPlug`: `id, name?, printer_id?, plug_type? ("homeassistant"|"mqtt"|"rest"|…), enabled?, last_state? ("ON"|"OFF")`, plus server-side automation fields (report-only): `auto_on?, auto_off?, auto_off_persistent?, off_delay_mode? ("time"|"temperature"), off_delay_minutes?, off_temp_threshold?, auto_off_after_drying?, off_delay_after_drying_minutes?, schedule_enabled?, schedule_on_time? ("HH:MM"), schedule_off_time?`.
`PlugEnergy`: `power?` (live watts), `voltage?, current?, today?` (kWh), `yesterday?, total?`. `PlugStatus`: `{ state? ("ON"|"OFF"), reachable?, device_name?, energy?: PlugEnergy | null, [k: string]: unknown }`.

`MaintenanceItem`: `id, printer_id, maintenance_type_name, maintenance_type_icon: string | null` (**a Lucide icon name**, e.g. `"Droplet"`, `"Flame"`), `enabled, interval_hours, interval_type?, current_hours?, hours_since_maintenance, hours_until_due` (**negative when overdue**), `days_until_due?, is_due, is_warning, last_performed_at: string | null`.
`MaintenancePrinter`: `{ printer_id, printer_name, printer_model?, total_print_hours, maintenance_items, due_count, warning_count }`.
`MaintenanceSummary`: `{ total_due, total_warning, printers_with_issues: Array<{printer_id, printer_name, due_count?, warning_count?}> }`.

`Spool`: `id, material ("PETG-CF"|"Support for PLA"|"PLA"), subtype?, color_name ("Titan Gray"|"Clear"), rgba: string | null` — > **`"565656FF"` — 8-digit hex, ALPHA LAST, no leading `#`** — `brand ("Bambu Lab"), label_weight` (grams on label), `weight_used` (grams consumed), `slicer_filament` (preset code, e.g. `"GFG50"`), `slicer_filament_name` (e.g. `"Bambu PETG-CF"`), `tray_uuid` (RFID UUID; **null for unrecognized spools**), `cost_per_kg, nozzle_temp_min?, nozzle_temp_max?, storage_location?, last_used?`.

```ts
/** Grams of filament remaining on a spool (never negative). */
export function spoolGramsRemaining(s: Spool): number {
  return Math.max(0, (s.label_weight ?? 0) - (s.weight_used ?? 0));
}
```

`SlotAssignment`: `id, spool_id, printer_id, printer_name, ams_id` (→ `status.ams[k].id`), `tray_id` (→ `status.ams[k].tray[i].id`), `fingerprint_color?, fingerprint_type?, configured?, pending_config?, ams_label?, spool: Spool` (full embedded spool).

`AppSettings`: `energy_cost_per_kwh: number` (e.g. `0.24`), `currency: string` (ISO, `"GBP"|"USD"|"EUR"`), `energy_tracking_mode?, default_filament_cost?`, `[k: string]: unknown`.

`PrintLogEntry`: `id, archive_id: number | null, print_name, printer_name, printer_id, status ('completed'|'failed'|'cancelled'|string), started_at` (> *naive local ISO, e.g. `"2026-06-28T15:07:35.681213"`* — **no timezone suffix**), `completed_at: string | null, duration_seconds, filament_type` (> *may be comma-joined: `"PETG-CF, PLA"`*), `filament_color` (> *may be comma-joined: `"#565656,#000000"`*), `filament_used_grams, cost, energy_kwh, energy_cost, failure_reason, thumbnail_path, created_at?`. All the numeric ones are nullable — *many cost/energy fields are `null` until data accrues*.
`PrintLogPage`: `{ items: PrintLogEntry[]; total: number }`.

`ArchiveStats`: `total_prints, successful_prints, failed_prints, cancelled_prints, total_print_time_hours, total_filament_grams, total_cost, prints_by_filament_type: Record<string, number>, prints_by_printer: Record<string, number>, total_energy_kwh, total_energy_cost, energy_data_warming_up: boolean`.

MakerWorld: `MakerWorldStatus { has_cloud_token, can_download }`. `MWFilament { type?, color?, usedG?: string | null }` (**`usedG` is a STRING**). `MWInstance { id, profileId?, title?, cover?, needAms?, prediction?` (seconds, best-effort) `, weight?` (grams, best-effort) `, instanceFilaments?, extention?: { modelInfo?: { plates?: Array<{prediction?, weight?, filaments?}> } } }` — note the upstream misspelling **`extention`** (sic), which must be preserved. `MWDesign { id, title?, coverUrl?, summary?, downloadCount?, likeCount?, tags?, designCreator?: {name?, handle?, avatar?} }`. `MakerWorldResolved { model_id, profile_id?, design, instances, already_imported_library_ids? }`. `MakerWorldImportRequest { model_id, profile_id?, instance_id?, folder_id? }` — comment: *`id` → `instance_id`, `profileId` → `profile_id` on import*. `MakerWorldImportResponse { library_file_id, filename, was_existing }`.

`PresetRef { id: string; name: string; source?: string }` (note `id` is a **string** here — hence `String(id)` when referencing a local preset). `SliceResult { status, print_time_seconds?, filament_used_g?, filament_used_mm?, library_file_id? }`.

---

### 7. `TexturizeClient` — the optional sidecar

Separate host (`texturize.*`), **same `X-API-Key`** (the sidecar checks it against its own `BAMBUDDY_API_KEY`). Same trailing-slash strip. Its `req()` is identical to Bambuddy's except the error prefix is `texturize` instead of `Bambuddy` and it sends **only** `X-API-Key` (no `extraHeaders` support).

URL resolution (`archive/mobile/src/config/texturizeConfig.ts`): `texturize === false` forces OFF → `null`; an explicit `texturizeUrl` wins (trimmed, trailing slashes stripped, must match `/^https?:\/\/[^\s]+$/i`); else derive by string-replacing `bambuddy.` → `texturize.` in `baseUrl`; else `null`.

| Member | Method/Path | Auth | Notes |
|---|---|---|---|
| `healthy(timeoutMs = 4000)` | GET `/health` | **none** | Never throws — `catch → false`. **Gates the entire feature** |
| `listTextures()` | GET `/textures` | K | `TexturizeTexture[] = { id, name, file }[]` |
| `textureThumbUrl(id)` | — | K via `authHeaders()` | `` `${base}/textures/${encodeURIComponent(id)}/thumb` `` |
| `fileThumbUrl(fileId)` | — | K via `authHeaders()` | `` `${base}/file-thumb/${fileId}` `` — *Neutral (restyled) STL thumbnail — Bambuddy's green-on-dark, recolored server-side* |
| `authHeaders()` | — | — | `{ 'X-API-Key': apiKey }` (no extraHeaders) |
| `start(req)` | POST `/texturize` JSON | K | `{ job_id: string }` |
| `getJob(jobId)` | GET `/texturize-jobs/{id}` | K | `TexturizeJob` |
| `resultPath(jobId)` | — (path only) | K | `/texturize-jobs/{id}/result.stl` |
| `commit(jobId)` | POST `/texturize-jobs/{id}/commit` | K | `{ file_id: number }` |
| `discard(jobId)` | DELETE `/texturize-jobs/{id}` | K | *Fire-and-forget safe — previews also expire server-side* |

Job ids are `encodeURIComponent`-escaped in every path.

```ts
export type TexturizeJobStatus = 'queued' | 'running' | 'done' | 'error';
export interface TexturizeJob {
  status: TexturizeJobStatus; stage: string; progress: number;  // 0..1
  preview?: boolean;          // present when the job ran with commit:false
  result_file_id?: number; out_triangles?: number; warnings?: string[]; error?: string;
}
export type TexturizeMappingMode = 'triplanar' | 'cubic' | 'cylindrical' | 'spherical' | 'planar_xy' | 'planar_xz' | 'planar_yz';
export interface TexturizeRequest {
  file_id: number;
  texture: { builtin: string } | { image_b64: string };   // discriminated union
  amplitude?: number;      // displacement depth in mm; server clamps 0–5, default 0.5
  scale_u?: number; scale_v?: number;  // tiling; server default 0.5, scale_v follows unless lock_scale=false
  lock_scale?: boolean;
  mapping_mode?: TexturizeMappingMode;
  protect_bed?: boolean;   // keep the bed-contact face flat; server default true
  refine_length?: number;  // detail in mm — smaller = finer = QUADRATICALLY more server time/RAM; server floors at 0.15
  commit?: boolean;        // false ⇒ PREVIEW (held server-side); omitted/true ⇒ straight to library
}
```

**Preview state machine:** `start({commit:false})` → poll `getJob` until `status==='done'` → the STL is at `resultPath(jobId)` (fetched with `authHeaders()` from a page whose origin is the sidecar base) → user picks **Use it** → `commit(jobId)` → `{file_id}` enters the library; or **Adjust/Cancel** → `discard(jobId)`. An expired preview surfaces **HTTP 410** on commit so the sheet can explain it (test-pinned). Job start can reject with **413** (`{"error":"too many triangles"}`).

> **GOTCHA:** *`healthy()` gates the **WHOLE** feature (texturize UI + thumbnail routing): instances without the sidecar keep a fully working app instead of dead buttons and broken thumbnails.* `/health` is unauthenticated by design.

---

### 8. Token lifecycles (state machines outside the client, but part of the API contract)

**Camera stream token** — two independent owners, both with the same rule:
- `src/app/index.tsx` (`CAM_TOKEN_TTL_MS = 55 * 60 * 1000`) holds a fleet-wide token for *thumbnails*: mint if absent, then a `setInterval` every **60 000 ms** re-mints when `Date.now() - mintedAt > 55 min`; mint failures are swallowed (`.catch(() => {})`) and retried by the next tick. Seeded from `config.cameraToken`.
- `src/realtime/useCameraStream.ts` (`TOKEN_TTL_MS = 55 * 60 * 1000`) holds one for the *live stream*, only while `enabled`; disabling sets `token = null`. Same 60 s interval. Exposes `remint`.
- Backend TTL is **60 min**; both refresh at 55 to stay ahead. Tokens are minted per session, not persisted.

**Admin JWT** — 24 h server TTL, re-minted at 23 h, plus one 401/403 retry (§3).

**Slicer/download token** — *single-use, short-lived; mint per view.* Never cached.

**WS token** — minted per socket connect; a reconnect mints a fresh one.

---

### Port notes

**Overall shape.** Both clients map cleanly onto a single Swift `actor` (or `final class` + `URLSession`) each. The whole layer is React-free already — this is the easiest part of the app to port, and the `__tests__` files are a ready-made XCTest suite.

| RN / TS | Swift / SwiftUI equivalent | Notes |
|---|---|---|
| `class BambuddyClient` | `actor BambuddyClient` | `actor` gives free serialization of the `jwt`/`jwtMintedAt` mutable state that TS got for free from the single-threaded runtime. |
| `fetch(url, {headers, method, body})` | `URLSession.shared.data(for: URLRequest)` | Set `X-API-Key` via `request.setValue(_:forHTTPHeaderField:)`. |
| `req()` throw string | `enum BambuddyError: Error { case http(method: String, path: String, status: Int, body: String) }` | **Do not** port the string-formatting/parsing pattern. Give the error typed `status` + `body` fields and make `apiErrorDetail` / `classifyConnectError` switch on them. |
| `apiErrorDetail(e)` | `func detail(_ e: Error) -> String` decoding `{"detail": …}` from `BambuddyError.body` with `JSONDecoder` | With a typed error you can decode properly instead of regexing. Keep the fallback-to-raw-message behaviour. |
| `classifyConnectError(e)` | `enum ConnectErrorKind` + a `classify(_ error: Error) -> (ConnectErrorKind, String)` | Map `URLError.timedOut`/`.cancelled` → `.timeout`; `.cannotFindHost`, `.cannotConnectToHost`, `.notConnectedToInternet`, `.secureConnectionFailed`, `.serverCertificateUntrusted`, `-999` → `.network`; `BambuddyError.http` status → auth/notFound/server. **Keep the exact user-facing strings** — they are tuned. |
| `probe(8000)` | `URLRequest.timeoutInterval = 8` (or `Task` + `withTimeout`) | Simpler than `AbortController`. |
| `AbortController` in `healthy(4000)` | `request.timeoutInterval = 4`, `try? await …`, return `false` on any throw | |
| `URLSearchParams` | **`URLComponents` is NOT equivalent** | See below — this is the #1 porting trap. |
| `expo-file-system` `File.upload` | `URLSession.uploadTask(with:fromFile:)` + hand-built multipart body, or `URLSession` background upload | See below. |
| `WebSocket` in `usePrinterStatus` | `URLSessionWebSocketTask` | Needs an explicit `receive()` re-arm loop (Swift's API is one-shot per call, unlike JS's `onmessage`). Add `sendPing` keep-alive; RN's WS had none. |
| MJPEG `<img>` in a WebView | A native `URLSession` multipart-stream parser feeding a `UIImageView`/`Image` | **Already done natively in this repo** — see commits `8f08616` / `d0f454a`: *"URLSession de-multiplexes multipart itself"*. Reuse that work; do not re-introduce a WebView. |
| `expo-secure-store` | Keychain via `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` | Matches `WHEN_UNLOCKED_THIS_DEVICE_ONLY` exactly. |
| `expo-image` `source.headers` | `URLSession` fetch → `UIImage`, or Nuke/Kingfisher with a custom request modifier | SwiftUI's `AsyncImage` **cannot send headers** — this breaks every SD-card thumbnail and every texturize thumbnail. You need a custom async image loader from day one. |
| Untyped `getPresets(): any`, `getSliceJob(): any` | Must be given real `Codable` types | These are the only two holes in the type coverage; decode-and-inspect the live responses when porting. |

**Things that will be genuinely hard or need a different approach:**

1. **`URLSearchParams` ≠ percent-encoding.** `new URLSearchParams({path})` is form-urlencoded: space → `+`, `%` → `%25`. `URLComponents.queryItems` percent-encodes space → `%20` and (worse) leaves `%` alone by default, producing a *different* string. The tests pin `path=%2FPrint%2520plate+Donor.gcode.3mf`. Port this as an explicit helper:
   ```swift
   func formURLEncode(_ s: String) -> String {
       var allowed = CharacterSet.alphanumerics
       allowed.insert(charactersIn: "*-._")
       var out = s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
       out = out.replacingOccurrences(of: "%20", with: "+")   // form-encoding: space -> '+'
       return out
   }
   ```
   and verify against a real SD-card filename containing both a space and a literal `%20`. Note `listPrinterFiles` uses plain `encodeURIComponent` — keep the asymmetry unless you verify the server accepts either.

2. **Upload.** There is no `File.upload` equivalent; build the multipart body yourself and use `uploadTask(with:fromFile:)` so a 500 MB 3MF is streamed from disk rather than held in memory (the RN version streams natively — do not regress to `Data(contentsOf:)`). Boundary + part must be exactly: field name `file`, `Content-Type: application/octet-stream`, filename from the file URL. Progress comes from `URLSessionTaskDelegate.urlSession(_:task:didSendBodyData:totalBytesSent:totalBytesExpectedToSend:)` — divide guarded against zero, same as the TS. **Accept any 2xx**, not just 200. This is a good candidate for a *background* `URLSession` so a big upload survives backgrounding — a genuine improvement over the RN version.

3. **JWT actor state.** The `stale → login → attempt → 401/403 → login once → retry` machine must not stampede: if three admin calls fire concurrently with a stale token, TS's single thread interleaved them harmlessly but each would still log in. In Swift, cache the *login `Task`* (`private var loginTask: Task<String, Error>?`) so concurrent callers await one login. Also honour the "retry exactly once" rule — an unbounded retry loop against a permanently-rejecting server is a login-flood.

4. **`X-API-Key` must be absent on admin requests.** The test asserts it. If you build a shared `URLRequest` factory that always injects the key, admin calls will regress silently (the server may accept the JWT anyway, or may not). Make the two request builders separate types.

5. **String-vs-number union fields.** `humidity`, `temp`, `dry_time`, `dry_target_temp`, `drying_temp`, `drying_time`, and all of `nozzle_rack`'s numerics arrive as **strings over WS and numbers over REST**. Swift's `Codable` will hard-fail the whole payload on a type mismatch — one bad field loses the entire status frame. Write a `LenientDouble` / `@propertyWrapper` that tries `Double`, then `String` → `Double`, then `nil`. Apply it everywhere the TS type says `number | string`. This is the single highest-risk decoding issue in the port.

6. **`thumbnailPath === null` vs `undefined`.** Swift's `String?` collapses both to `nil`. To preserve "explicit null means *don't request*, absent means *maybe*", decode with a double-optional (`String??` via `decodeIfPresent`) or a small `enum Tri { case absent, null, value(String) }`. Getting this wrong means either dead thumbnail requests or missing thumbnails.

7. **Camera/thumbnail token is a `?token=` query, never a header.** Two independent 55-minute refreshers exist (fleet thumbnails + live stream). In Swift, consolidate into one `actor CameraTokenStore` with `func token() async throws -> String` that re-mints past 55 min — cleaner than the two `setInterval`s, and it removes the risk of two components racing to mint.

8. **Naive datetimes.** `PrintLogEntry.started_at` (`"2026-06-28T15:07:35.681213"`) has **no timezone** and is *local*, while `SensorPoint.recorded_at` is naive **UTC**. `ISO8601DateFormatter` rejects fractional-second-without-zone by default. Use a `DateFormatter` with `yyyy-MM-dd'T'HH:mm:ss.SSSSSS` and set `timeZone` explicitly per field — **different time zones for the two fields**. Getting this wrong silently shifts the cooldown curve and the history timestamps.

9. **`rgba` is `"565656FF"` — 8 hex digits, alpha last, no `#`.** SwiftUI `Color(hex:)` helpers almost universally assume `#RRGGBB` or ARGB. Write the parser explicitly and unit-test it against `"565656FF"` and the `#RRGGBB` form used by `PlateFilament.color`.

10. **Failure-swallowing methods are load-bearing, not sloppiness.** `listAssignments → []`, `listPlugs → []`, `getPlug → nil`, `sensorHistory → nil`, `healthy → false`. Each one lets a screen degrade instead of erroring. In Swift these become non-throwing `async` functions returning empty/optional. Do **not** "improve" them into `throws`.

11. **`listPlugs` polymorphic body.** The server returns either a bare array or `{items:[…]}`. Decode with `try? [SmartPlug].self` then fall back to a `{items:}` wrapper, then `[]`. A strict `Codable` port will break on whichever shape the live server isn't returning today.

12. **`extention` (sic) in `MWInstance`.** Preserve the misspelling in the `CodingKeys`, or MakerWorld plate predictions silently vanish.

13. **`ams_mapping` semantics.** Ported code must keep the *filament-index → global-tray-id* orientation (`[slot]`), with Bambuddy's decode rule `gid>=254 → external`, `gid>=128 → HT`, else `(gid/4, gid%4)`. This was a shipped bug once; a Swift `[Int]` gives no protection. Consider a `struct AMSMapping` with a documented initializer so the orientation cannot be mixed up again.

14. **Slice-job and texturize-job polling** are ad-hoc `for` loops in React effects today. In Swift, model each as an `AsyncStream<Progress>` on the client so the view just consumes it — keep the exact limits (**90 polls × 1500 ms** for slicing; the fake `min(95, p+6)` progress ramp exists because the server reports no percentage).

15. **G-code text can be ~70 MB.** `getGcode` returns a `String` today only for the non-WebView path; the viewer is handed a *URL + headers* precisely so the WebView can stream and JIT-parse it. A native SceneKit/Metal layer viewer should likewise stream `printerGcodePath`/`gcodePath` with `URLSession.bytes(for:)` and parse incrementally — never `String(contentsOf:)`.

16. **No global timeout today.** Adding a sane `URLRequest.timeoutInterval` (say 30 s, 8 s for `probe`, 4 s for `healthy`) is a net win in the port, but keep long/unbounded timeouts for `getGcode`, `uploadFile`, and the MJPEG stream or they will abort mid-transfer.
