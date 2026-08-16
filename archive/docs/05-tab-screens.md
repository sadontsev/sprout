<!-- Generated as the port specification for the native Swift rewrite. -->
# Library, AMS, Power, Jobs, Queue, History, Maintenance

## tabs

This section documents `mobile/src/components/TabScreens.tsx` (1861 lines) — the Files, Jobs, Hardware and Power tabs — plus every pure module it depends on. Everything below is verified against the source; numbers, strings, colors and endpoint paths are exact.

**Exported entry points** (all mounted from `src/app/index.tsx` `Shell`):

| Export | Tab id | Title | Props |
|---|---|---|---|
| `LibraryView` | `library` | "Files" | `client, texClient, camToken, printerId, plate?, onUpload, onPick, onTexturize?, onView3D?` |
| `JobsView` | `jobs` | "Jobs" | `client, status, printerId, printers, camToken, onBrowse, lanMode` |
| `AmsView` | `ams` | "Hardware" | `client, status, printerId, amsLabel, lanMode` |
| `PowerView` | `power` | "Power" | `client, printerId, status` |
| `MaintenanceSection` | — | (embedded in Hardware) | `client, printerId` |

Internal (not exported): `QueueSection`, `HistorySection`, `DryerCard`, `IdleDryers`, `HistoryRow`, `StatsBanner`, `StatBlock`, `SuccessRing`, `NozzlesSection`, `NozzleCard`, `PlugRow`, `PrinterFileSheet`, `SdVideoPlayer`, `VideoBody`, `Page`, `SectionHead`, `LoadFailed`, `Empty`, `Segmented`, `Stepper`.

---

### 0. Design tokens (`src/theme.ts`)

Two palettes; `c` is a **live-mutated object** — `setTheme()` does `Object.assign(c, themes[name])` and notifies `useSyncExternalStore` subscribers. **Consequence encoded in the file**: `statusMeta()` is a *function* computed per call, not a module-level table, because a module-level table would freeze the dark palette (comment at line 1514).

| token | dark | light |
|---|---|---|
| `bg` | `#0A0B0C` | `#EFF1F3` |
| `s1` | `#131517` | `#FFFFFF` |
| `s2` | `#191C1F` | `#F5F6F8` |
| `s3` | `#23272B` | `#EAECEF` |
| `s4` | `#2D3237` | `#DEE1E5` |
| `line` | `rgba(255,255,255,0.07)` | `rgba(0,0,0,0.08)` |
| `line2` | `rgba(255,255,255,0.12)` | `rgba(0,0,0,0.13)` |
| `t1 / t2 / t3` | `#F3F5F7 / #A4ABB2 / #6B7177` | `#0D1012 / #585E64 / #878D94` |
| `accent` | `#2BD4C0` | `#0EAE9C` |
| `accentInk` | `#04201D` | `#FFFFFF` |
| `accentDim` | `rgba(43,212,192,0.15)` | `rgba(14,174,156,0.14)` |
| `running / runningDim` | `#30D158` / `rgba(48,209,88,0.15)` | `#23B24A` / `rgba(35,178,74,0.14)` |
| `heating / heatingDim` | `#FF9F0A` / `rgba(255,159,10,0.15)` | `#E0860A` / `rgba(224,134,10,0.14)` |
| `paused / pausedDim` | `#0A84FF` / `rgba(10,132,255,0.15)` | `#0A84FF` / `rgba(10,132,255,0.12)` |
| `error / errorDim` | `#FF453A` / `rgba(255,69,58,0.15)` | `#E5392E` / `rgba(229,57,46,0.12)` |
| `idle / idleDim` | `#8E9398` / `rgba(142,147,152,0.14)` | `#9AA0A6` / `rgba(154,160,166,0.14)` |
| `sheet` | `#16181B` | `#FFFFFF` |
| `thumb` | `#0e1113` | `#E4E7EA` |
| `swatchRing` | `#8E9398` | `#6E7378` |

`mono = Platform.select({ ios: 'Menlo', default: 'monospace' })`.
`shadow1 = { shadowColor:'#000', shadowOpacity:0.5, shadowRadius:2, shadowOffset:{width:0,height:1} }`.

**`swatchRing` gotcha (Swatch.tsx):** the ring is chosen for ≥3:1 contrast against the *surfaces* (bg/s1/s2/s3/s4/sheet — min 4.18 dark, 3.65 light), **not** against the fill. A white spool on a white card was a hole in the layout; `line2` at ~1.4:1 did not fix it. `Swatch` has three states: `empty` (transparent + dashed ring), colour-unknown (dashed ring + `help-circle` glyph when `size >= 16`, never black), and known colour (fill + solid ring).

---

### 1. Shared scaffolding

#### `Page({ title, right, refreshControl, children })`
`ScrollView`, `flex:1`, `backgroundColor: c.bg`, `showsVerticalScrollIndicator={false}`,
`contentContainerStyle={{ paddingTop: insets.top + 8, paddingBottom: 120 }}` (safe-area top from `useSafeAreaInsets`).
Header row: `paddingHorizontal: 20`, `space-between`; title `fontWeight:'700', fontSize:30, color:c.t1, letterSpacing:-0.8`; `right` node on the trailing edge.
*Note:* there is a dead `sub?: string` prop in the type that is never rendered.

#### `SectionHead({ label, right, first })`
Row, `paddingHorizontal:20`, `paddingTop: first ? 8 : 26`, `paddingBottom:12`. Label `600/11`, `letterSpacing:1.2`, `c.t3`, mono. Optional right `600/11` mono t3.

#### `LoadFailed({ onRetry })` — **a failed fetch is NOT an empty list**
`marginHorizontal:20, marginTop:20, padding:16, radius:16, bg:c.s1, border 1px c.line`, row `gap:12`.
`Feather wifi-off 18 c.t3` + `Couldn’t reach the server.` (`500/13`, `c.t2`) + Retry pill (`paddingHorizontal:14, paddingVertical:8, radius:10, bg:c.s3`, text `600/13 c.t1`).

#### `Empty({ icon, title, body, cta?, onCta? })`
`marginHorizontal:24, marginTop:48, alignItems:center, gap:15`. Icon well `72×72 radius 22 bg c.s2`, glyph `32 c.t3`. Title `700/20 c.t1 letterSpacing -0.3`. Body `500/13 lineHeight 19 c.t3 center maxWidth 250 marginTop 8`. CTA `height 48, paddingHorizontal 24, radius 14, bg c.accent`, text `600/15 c.accentInk`.

#### `Segmented<T>({ value, options, onChange })`
Container row `gap:4, padding:4, radius:12, bg:c.s2`. Each: `flex:1, height:38, radius:9`, bg `c.s4` when selected else transparent, text `600/13.5` `c.t1`/`c.t2`.

#### `Stepper({ label, value, onMinus, onPlus })`
`flex:1, padding:10, radius:12, bg:c.s2, border 1 c.line`. Label `600/10 letterSpacing 0.6 uppercase c.t3`. Row: minus button `30×30 radius 8 bg c.s3` (`Feather minus 14 c.t1`), value `700/16 mono c.t1`, plus button identical.

#### Formatters
```ts
function fmtBytes(n?: number): string {
  if (!n) return '';                                  // 0 and undefined both render ''
  if (n > 1e6) return `${(n / 1e6).toFixed(1)} MB`;   // decimal MB, not MiB
  if (n > 1e3) return `${(n / 1e3).toFixed(0)} KB`;
  return `${n} B`;
}
function currencySymbol(code?: string): string {
  switch ((code || '').toUpperCase()) {
    case 'GBP': return '£';
    case 'USD': case 'AUD': case 'CAD': case 'NZD': return '$';
    case 'EUR': return '€';
    case 'JPY': case 'CNY': return '¥';
    default: return code ? `${code} ` : '$';           // note trailing space for unknown codes
  }
}
const fmtMoney = (sym: string, n: number) => `${sym}${n.toFixed(2)}`;
```
From `@/dashboard/present`: `fmtDuration(min)` → `'—'` when `!isFinite || <= 0`, else `${h}h ${mm}m` (minutes zero-padded to 2) or `${m}m`.

#### LAN-mode lock (`@/capabilities`)
`LanMode = 'on' | 'off' | 'unknown'` — **tri-state on purpose**; only an explicit `false` from `status.developer_mode` disables anything (absence must not grey the UI on cold start).
Blocked set when mode is `'off'`: `pause, resume, speed, amsLoad, amsUnload, dryStart, dryStop, startPrint, printAgain`. Deliberately **not** blocked: `stop` (emergency control), `light` (system/ledctrl, not verified by firmware), `camera`, `plug`, `plateCleared`, `queueRemove`, `maintenance` (Bambuddy-side bookkeeping).
`useLockedAction(lanMode)` returns `{ blocked(a), style(a), press(a, run) }`. `style` → `{opacity: 0.4}` (`LOCKED_OPACITY`) or `null`. `press` shows `Alert.alert(LAN_BANNER_TITLE, LAN_BLOCKED_HINT)` and swallows the action:
- `LAN_BANNER_TITLE = 'Printer controls are locked'`
- `LAN_BLOCKED_HINT = 'Turn on LAN Developer Mode on the printer (Settings → Network), then re-enter its new access code in this app.'`

---

### 2. `LibraryView` — the **Files** tab

#### 2.1 State
```
source:      'library' | 'printer'                  (Segmented, default 'library')
files:       LibraryFile[] | null                    null = loading
loadFailed:  boolean
refreshing:  boolean                                 pull-to-refresh
filter:      'all' | 'models' | 'sliced'             default 'all'
view:        'grid' | 'list'                         default 'grid'
query:       string                                  search text
selecting:   boolean                                 bulk-select mode
selected:    Set<number>                             library file ids
pList:       PrinterFileList | null                  SD listing, null = never loaded
pPath:       string                                  default '/'
pLoading:    boolean
sheetFile:   PrinterFile | null                      bottom sheet
viewGcode:   PrinterFile | null                      layer viewer modal
playFile:    PrinterFile | null                      video player modal
dlBusy:      boolean                                 shared download spinner
```

#### 2.2 Data loading
```ts
const load = useCallback(() =>
  client.listFiles()
    .then((f) => { setFiles(f); setLoadFailed(false); })
    // A failed fetch is NOT an empty library — show a retry state instead of "No files yet".
    .catch(() => { setFiles((prev) => prev ?? []); setLoadFailed(true); }),
  [client]);
useEffect(() => { void load(); }, [load]);
```
- `GET /api/v1/library/files` → `LibraryFile[]`.
- Printer SD: `loadPrinter(path)` sets `pLoading`, calls `GET /api/v1/printers/{id}/files?path={enc}` → `{path, files}`; sets `pPath = r.path || path`; on failure sets `{path, files: []}` (silent, no retry UI); `finally` clears `pLoading`.
- Lazy: `useEffect(() => { if (source === 'printer' && !pList) loadPrinter('/'); }, [source, pList, loadPrinter])` — the SD list loads only the first time the segment is opened, then persists across segment switches.
- **Pull-to-refresh** (`RefreshControl tintColor={c.t3}`): sets `refreshing`, additionally re-lists the SD folder when the printer segment is showing (it has its own spinner), then `load().finally(() => setRefreshing(false))`.

No pagination anywhere in this view — `listFiles()` returns the whole library, the SD listing returns a whole directory.

#### 2.3 Filtering / search / counts (pure, `src/library/libraryBrowse.ts`)
```ts
export const isSlicedFile = (f) => (f.file_type || '').includes('gcode') || !!f.sliced_for_model;

export function displayName(f) {                    // %20-decoded upload names
  const raw = f.print_name || f.filename || `file-${f.id}`;
  try { return decodeURIComponent(raw); } catch { return raw; }
}
export function safeShareName(name) {               // cache filename safety
  const n = name.replace(/[/\\:]+/g, '-').trim();
  return n || 'file';
}
export function filterFiles(files, filter, query) {
  const q = query.trim().toLowerCase();
  return files.filter((f) => {
    if (filter === 'sliced' && !isSlicedFile(f)) return false;
    if (filter === 'models' && isSlicedFile(f)) return false;
    if (!q) return true;
    // matches BOTH the decoded display name and the raw filename
    return displayName(f).toLowerCase().includes(q) || (f.filename || '').toLowerCase().includes(q);
  });
}
export function toggleSelection(selected, id) {      // immutable Set toggle
  const next = new Set(selected); next.has(id) ? next.delete(id) : next.add(id); return next;
}
```
Counts chip values: `all = files.length`, `models = files.filter(f => !isSlicedFile(f)).length`, `sliced = files.filter(isSlicedFile).length` (computed against the *unfiltered* list, so they never change with the query).

SD sort (directories first, then case-aware locale name order):
```ts
const pSorted = pList ? [...pList.files].sort((a, b) =>
  a.is_directory === b.is_directory ? a.name.localeCompare(b.name) : a.is_directory ? -1 : 1) : [];
```

#### 2.4 Header + chrome (library segment)
- `Page right`: **only when `source === 'library'`** — `38×38 radius 19 bg c.accentDim`, `Feather plus 22 c.accent` → `onUpload()` (opens the Upload/MakerWorld sheet owned by `Shell`).
- Segmented `[['library','Library'], ['printer','Printer']]`, `paddingHorizontal:20, paddingTop:14`.
- Filter row (`!!files?.length && !selecting`): three chips `paddingHorizontal:13, height:32, radius:10`, bg `c.accentDim` when active else `c.s2`; label `600/12` (`All` / `Models` / `Sliced`) in `c.accent`/`c.t2`; count `600/11` mono `c.accent`/`c.t3`.
  Then a view-mode button `32×32 radius 10 bg c.s2`, icon **`view === 'grid' ? 'list' : 'grid'`** (shows the mode it switches *to*), `hitSlop 6`.
  Then a `check-square` button (same metrics) → `setSelecting(true)`.
- Select bar (`!!files?.length && selecting`): `Done` pill (`paddingHorizontal:14, height:34, radius:10, bg:c.s2`, `600/13 c.t1`) → `exitSelect()` (`selecting=false`, `selected=new Set()`); centre text `600/13 c.t2` = `${selected.size} selected` or `Tap files to select`; `Delete` pill bg `c.errorDim` (text `700/13 c.error`) when non-empty, else `c.s2` + `opacity 0.5` + `c.t3`, `disabled={!selected.size}`.
- Search field (`!!files?.length`, shown in both selecting and normal): `marginHorizontal:20, marginTop:10, paddingHorizontal:12, height:38, radius:12, bg:c.s2, border 1 c.line`; `Feather search 14 c.t3`; `TextInput` placeholder `"Search files"`, `placeholderTextColor c.t3`, `autoCapitalize="none"`, `autoCorrect={false}`, `clearButtonMode="while-editing"`, `fontSize 13.5`, `paddingVertical: 0`.

#### 2.5 Library states
| Condition | Render |
|---|---|
| `loadFailed` | `LoadFailed` banner (retries `load()`), rendered *above* the chrome, and the stale list (or `[]`) stays below |
| `files === null && !loadFailed` | `ActivityIndicator color={c.accent} marginTop:40` |
| `files.length === 0 && !loadFailed` | `Empty` icon `folder`, title **"No files yet"**, body **"Upload an STL, 3MF, or sliced G-code and it'll show up here."**, cta **"Upload a model"** → `onUpload` |
| `files.length > 0 && shown.length === 0` | centred `500/13 c.t3` marginTop 40: `No files match “{query}”.` (the quoted part omitted when the query is blank) |

#### 2.6 Grid cells (`view === 'grid'`)
Container: `row, wrap, paddingHorizontal:20, paddingTop:14, gap:13`. Cell `width:'47%', flexGrow:1`, `opacity: selecting && !selected ? 0.55 : 1`.
Tile: `aspectRatio 4/3, radius 14, overflow hidden, bg c.thumb`, border `selecting && sel ? 2px c.accent : 1px c.line`.

Thumbnail resolution order (**two different auth schemes — this is the classic 401 trap**):
1. `f.thumbnail_path` truthy **and** `texClient` present → `texClient.fileThumbUrl(f.id)` = `{texBase}/file-thumb/{id}` with **`X-API-Key` header**, `width/height 92%`, `contentFit="contain"`. *Comment: Bambuddy's green renders (STL + resliced gcode.3mf) come back neutral-on-transparent from the sidecar; real slicer renders pass through.*
2. else `client.fileThumbUrl(f.id, camToken, f.thumbnail_path)` = `{base}/api/v1/library/files/{id}/thumbnail?token={camToken}` — **camera *stream* token in the query, NOT `X-API-Key`** (returns `''` when `!token || thumbnailPath === null`), `100%`, `contentFit="cover"`.
3. no thumbnail → `Feather` `box` when `file_type` contains `gcode`, else `file`, `26 c.t3`.
All `expo-image` with `transition={120}` (list: 100/150) and `cachePolicy="memory-disk"`.

Overlays:
- Type badge top-left `8/8`, `paddingHorizontal 6, paddingVertical 3, radius 6, bg rgba(0,0,0,0.5)`, text `600/8.5 letterSpacing 0.5 rgba(255,255,255,0.8)` mono, `file_type.toUpperCase()`.
- If `selecting`: circle top-right `7/7`, `22×22 radius 11`, selected → `bg c.accent` + `Feather check 13 c.accentInk`; unselected → `bg rgba(0,0,0,0.5)`, `border 1.5 rgba(255,255,255,0.7)`.
- Else if `isSlicedFile`: small badge `18×18 radius 9 bg c.accent`, `check 11 c.accentInk`.
- Texturize corner button — only `!selecting && onTexturize && file_type.toLowerCase() === 'stl'` (the sidecar takes raw meshes, not sliced gcode): bottom/right `7`, `26×26 radius 13 bg rgba(0,0,0,0.55)`, `Feather droplet 13 #fff`, `hitSlop 6` → `onTexturize(f)`.

Caption: name `600/13 c.t1 numberOfLines 1 marginTop 9`; size `500/11 mono c.t3 marginTop 3` = `fmtBytes(f.file_size)`.

Footer hint (`shown.length > 0`), centred `500/11 c.t3 marginTop 16`:
`selecting ? 'Tap to select · Delete removes all selected' : 'Tap to print · hold for options'`.

Gestures: tap → `selecting ? setSelected(toggleSelection(selected, f.id)) : onPick(f)`; long-press → `!selecting && fileMenu(f)`.

#### 2.7 List rows (`view === 'list'`)
Card `marginHorizontal:20, marginTop:14, radius:16, bg c.s1, border 1 c.line, overflow hidden`. Row: `row, gap 12, paddingHorizontal 12, paddingVertical 10`, bottom hairline `1 c.line` on all but the last, `bg c.accentDim` when selecting+selected. Thumb `44×44 radius 10` (same source logic, fallback glyph `18`). Title `600/14 c.t1` 1 line. Subtitle `500/11 mono c.t3`: `` `${file_type.toUpperCase()}${sliced ? ' · sliced' : ''} · ${fmtBytes(size)}` ``. Trailing: selection circle `22×22` (`bg c.accent` + check, or transparent with `border 1.5 c.line2`) when selecting, else `Feather chevron-right 16 c.t3`. Same footer hint.

#### 2.8 Actions
**Long-press menu** (`fileMenu`) — *comment: "was delete-only — Texturize was undiscoverable as just a corner badge"*. `Alert.alert(displayName(f), undefined, [...])` with buttons in this order:
1. `Print…` → `onPick(f)`
2. `View in 3D` — only if `onView3D && file_type.toLowerCase()==='stl'`
3. `Texturize…` — only if `onTexturize && stl`
4. `Share…` → `shareFile(f)`
5. `Delete` (destructive) → `confirmDelete(f)`
6. `Cancel` (cancel)

**Single delete:** `Alert.alert('Delete file?', '“{displayName}” will be removed from the library. This can’t be undone.', [Cancel, Delete(destructive)])` → `DELETE /api/v1/library/files/{id}` then `load()`; failure → `Alert.alert('Couldn’t delete', String(e))`.

**Bulk delete:**
```ts
const ids = [...selected]; if (!ids.length) return;
Alert.alert(`Delete ${ids.length} ${ids.length === 1 ? 'file' : 'files'}?`,
  'They will be removed from the library. This can’t be undone.', [
  { text: 'Cancel', style: 'cancel' },
  { text: 'Delete', style: 'destructive', onPress: async () => {
      const results = await Promise.allSettled(ids.map((id) => client.deleteFile(id)));
      const failed = results.filter((r) => r.status === 'rejected').length;
      exitSelect(); void load();
      if (failed) Alert.alert('Some deletes failed', `${failed} of ${ids.length} files couldn’t be deleted.`);
  } }]);
```
Partial failure is tolerated and reported — never abort the batch.

**Share a library file** (`shareFile`) — token-in-URL flow, no headers:
```ts
setDlBusy(true);
const url  = await client.mintFileDownloadUrl(f.id, f.filename);  // POST /library/files/{id}/slicer-token
const dest = new File(Paths.cache, safeShareName(displayName(f)));
if (dest.exists) dest.delete();
const file = await File.downloadFileAsync(url, dest);             // NO auth headers — the token IS the auth
await Share.share({ url: file.uri });
```
`mintFileDownloadUrl` accepts `token | slicer_token | download_token | value` from the response and builds
`{base}/api/v1/library/files/{id}/dl/{enc token}/{enc filename||`model-{id}.stl`}` — **single-use, short-lived; mint per share.**

**Share an SD file** (`downloadAndShare`) — the opposite scheme:
```ts
const dest = new File(Paths.cache, pf.name);
if (dest.exists) dest.delete();
const file = await File.downloadFileAsync(
  client.printerFileDownloadUrl(printerId, pf.path), dest, { headers: client.authHeaders() }); // X-API-Key
await Share.share({ url: file.uri });
```
`printerFileDownloadUrl` = `{base}/api/v1/printers/{id}/files/download?path={enc}`. **The URL alone 401s** — SD endpoints are `X-API-Key`-gated, unlike library thumbnails.

**Delete from printer** (`confirmDeletePf`): `Alert.alert('Delete from printer?', '“{name}” will be removed from the printer’s storage. This can’t be undone.', …)` → `DELETE /api/v1/printers/{id}/files?path={enc}`; on success closes both `sheetFile` and `playFile` and re-lists `pPath`; on failure `Alert.alert('Couldn’t delete', apiErrorDetail(e))`.

**Busy pill** — because menu-driven shares have no sheet to host a spinner: `dlBusy && !sheetFile` → absolute `bottom:24, alignSelf:'center', height 42, radius 21, bg c.s1, border 1 c.line, ...shadow1`, spinner + `Preparing to share…` (`600/13 c.t1`).

#### 2.9 Printer (SD-card) segment
Breadcrumb row (`paddingHorizontal:20, paddingTop:14, marginBottom:12`):
- Up button only when `pPath !== '/'`: `32×32 radius 9 bg c.s2`, `arrow-up 16 c.t2`, `hitSlop 8` → `loadPrinter(pPath.replace(/\/[^/]+\/?$/, '') || '/')`.
- Path text `600/12 mono c.t3`, one line: `` `printer:${pPath}` ``.

States: `pLoading` → spinner marginTop 30. `!pLoading && pList && pSorted.length === 0` → `Empty` icon `hard-drive`, **"Empty folder"**, "Nothing here on the printer's onboard storage."

**Media folders** (`isMediaFolder(pPath)`, i.e. `/^\/(timelapse|ipcam)\/?$/i`) render a **newest-first 16:9 thumbnail grid** instead of a list:
```ts
pSorted.filter((pf) => !pf.is_directory && isPlayableVideo(pf.name))   // /\.mp4$/i — .avi is NOT playable
       .sort((a, b) => b.name.localeCompare(a.name))                    // filenames are timestamped
```
Cell `width 47% flexGrow 1`, tile `aspectRatio 16/9 radius 14 bg c.thumb border 1 c.line`; image from `client.printerFileDownloadUrl(printerId, mediaThumbPath(pf.path))` **with `authHeaders()`**; centred play badge `34×34 radius 17 bg rgba(0,0,0,0.45)`, `play 16 #fff marginLeft 2`. Label `mediaLabel(pf.name)` `600/12.5 c.t1 marginTop 8`; size `500/10.5 mono c.t3`. Tap → `setPlayFile`, long-press → `confirmDeletePf`. If every entry is a directory or non-mp4: `No videos here yet.` (`500/12 c.t3`).

```ts
// printerFiles.ts — poster JPEG lives in a `thumbnail` subfolder with the same basename.
// /timelapse/video_x.mp4        -> /timelapse/thumbnail/video_x.jpg
// /ipcam/ipcam-record.<d>.0.mp4 -> /ipcam/thumbnail/ipcam-record.<d>.0.jpg   (dotted basenames!)
export function mediaThumbPath(videoPath: string): string {
  const m = videoPath.match(/^(.*)\/([^/]+)\.[^./]+$/);
  return m ? `${m[1]}/thumbnail/${m[2]}.jpg` : videoPath;
}
const MONTHS = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
/** "video_2026-07-05_15-16-02.mp4" -> "Jul 5, 15:16" (falls back to the raw name). */
export function mediaLabel(name: string): string {
  const m = name.match(/(\d{4})-(\d{2})-(\d{2})_(\d{2})-(\d{2})/);
  if (!m) return name;
  const month = MONTHS[Number(m[2]) - 1];
  return month ? `${month} ${Number(m[3])}, ${m[4]}:${m[5]}` : name;
}
export const isSliced3mf = (name: string) => /\.3mf$/i.test(name);
export const isPlayableVideo = (name: string) => /\.mp4$/i.test(name);
export const isMediaFolder = (path: string) => /^\/(timelapse|ipcam)\/?$/i.test(path);
```

**Ordinary folders** render stacked rows (`paddingVertical 12, paddingHorizontal 13, radius 13, bg c.s1, border 1 c.line, marginBottom 9`):
- Icon: directory → `isMediaFolder(pf.path) ? 'film' : 'folder'` in **`c.accent`**; file → `isSliced3mf ? 'box' : isPlayableVideo ? 'film' : 'file'` in `c.t3`; size 18.
- Name `600/13.5 c.t1`, 1 line, `flex:1`.
- Trailing: `chevron-right 16 c.t3` for directories, `fmtBytes(pf.size)` `500/11 mono c.t3` for files.
- Tap: directory → `loadPrinter(pf.path)`; file → `setSheetFile(pf)`. Long-press on a file → `confirmDeletePf`.
- Hint when `!isMediaFolder(pPath) && pSorted.some(pf => !pf.is_directory)`: `Tap a file for preview & actions · hold to delete` (`500/11 c.t3 marginTop 8`).

#### 2.10 `PrinterFileSheet`
Presented when `sheetFile != null`. `Modal visible transparent animationType="fade"`; backdrop `rgba(0,0,0,0.55)` with a full-flex `Tap` above the sheet that dismisses. Sheet: `bg c.s1, borderTopLeftRadius/RightRadius 24, padding 20, paddingBottom 36, border 1 c.line`.

- `sliced = isSliced3mf(file.name)`. When sliced, fetch **best-effort** (errors swallowed, alive-guarded):
  `GET /api/v1/printers/{id}/files/plates?path={enc}` → `PrinterFilePlates`; uses `plates.plates[0]` only.
- Preview (sliced only): `210×210 radius 18 bg c.thumb border 1 c.line marginBottom 14`, image `client.printerPlateThumbUrl(printerId, file.path)` = `{base}/api/v1/printers/{id}/files/plate-thumbnail/1?path={enc}` **with `authHeaders()`**, `contentFit="contain"`, `transition 150`.
- Title `plate?.name || file.name`, `700/15.5 c.t1`, centred, up to 2 lines.
- Meta line `500/11.5 mono c.t3 marginTop 6`, joined by two spaces around `·`:
  `fmtBytes(file.size)` + (`plate.print_time_seconds` → `fmtDuration(sec/60)`) + (`plate.filament_used_grams` → `${Math.round(g)}g`).
- Button row `gap 10 marginTop 18`, each `height 46 radius 13`, `opacity 0.5` while `busy`:
  - **Play** (only when `isPlayableVideo(name)`): `bg c.accent`, `play 15` + `Play` `700/14 c.accentInk`. Closes the sheet, opens `SdVideoPlayer`.
  - **Layers** (only when `isSliced3mf(name)`): `bg c.s3`, `layers 15` + `Layers` `700/14 c.t1`. Closes the sheet, opens the shared `GcodeViewerOverlay`.
  - **Download**: `bg` = `onPlay ? c.s3 : c.accent` (so it demotes itself when Play is present); shows `ActivityIndicator` + `Downloading…` while `busy`, else `download 15` + `Download`.
  - **Delete**: fixed `52×46 radius 13 bg c.s3`, `trash-2 16 c.error`.

#### 2.11 Layer viewer + video player modals
- `viewGcode` → `<Modal visible animationType="slide">` hosting `GcodeViewerOverlay key={path}` with
  `src={{ url: client.baseUrl + client.printerGcodePath(printerId, path), headers: client.authHeaders() }}`,
  `title={name}`, `plate={plate}` (the printer profile's build volume `{w,d}`).
  `printerGcodePath` = `/api/v1/printers/{id}/files/gcode?path={enc}`. **The WebView is handed a URL, not a 70 MB string**, so it can parse with JIT and build GPU buffers directly.
- `playFile` → `<SdVideoPlayer key={path} … />`.

#### 2.12 `SdVideoPlayer` (timelapse + ipcam recordings) — hard-won constraints
Header comment, verbatim in intent: *the download endpoint does **not** honour Range requests (verified: 200 + full body), so AVPlayer can't stream off the URL — download-then-play is the only reliable path; a bare `<video src>` also can't send `X-API-Key`. ipcam chunks are ~250 MB (hence the real progress bar); SD videos are immutable, so cached copies are reused as-is.*

```ts
const kind = file.path.toLowerCase().startsWith('/ipcam') ? 'camera recording' : 'timelapse';
useEffect(() => { let alive = true; (async () => {
  const dest = new File(Paths.cache, file.name);
  if (!dest.exists) {
    await File.downloadFileAsync(client.printerFileDownloadUrl(printerId, file.path), dest, {
      headers: client.authHeaders(),
      // totalBytes is -1 when the server omits Content-Length — fall back to the listed size.
      onProgress: ({ bytesWritten, totalBytes }) =>
        alive && setProg({ written: bytesWritten, total: totalBytes > 0 ? totalBytes : file.size }),
    });
  }
  if (alive) setLocalUri(dest.uri);
})().catch(e => alive && setErr(apiErrorDetail(e)));
  return () => { alive = false; };
}, []);   // mounted per-file via key={path} — download exactly once
const pct = prog && prog.total > 0 ? Math.min(100, Math.round((prog.written / prog.total) * 100)) : null;
```
Chrome: `Modal animationType="slide"`, root `flex:1 bg '#0A0B0C'` (**hardcoded, not `c.bg`** — it's a player), `paddingTop insets.top`, trailing `View height={insets.bottom}`.
Header row `paddingHorizontal 16 paddingBottom 10 gap 10`: title `mediaLabel(file.name)` `700/15 #fff`; sub `500/10.5 mono #8E9398` = `` `${fmtBytes(size)} · ${kind}` ``. Three `36×36 radius 18 bg rgba(255,255,255,0.08)` buttons: share (`share 15 #fff`, `opacity 0.4` until `localUri`; shares the **local** cached URI), delete (`trash-2 15 #FF6B6B` → `onDelete`), close (`x 17 #fff`).
Body: once `localUri` → `<VideoBody>`; else centred (`paddingHorizontal 44`) either the error string (`#8E9398 13.5 center lineHeight 19`) or `ActivityIndicator #30D158` plus, when `pct != null`, `` `${pct}% · ${fmtBytes(written)} / ${fmtBytes(total)}` `` (`600/13 #fff` mono) and a bar `height 4 radius 2` track `rgba(255,255,255,0.12)` / fill `#30D158`.
`VideoBody` is a **separate component** so `useVideoPlayer` is only called once a local URI exists (hooks can't be conditional) and the player is created/destroyed with the modal: `useVideoPlayer(uri, p => { p.loop = true; p.play(); })`, `<VideoView player style={{flex:1}} contentFit="contain" nativeControls />`.

---

### 3. `JobsView` — the **Jobs** tab (queue + history merged)

*Comment: one tab that reads top-to-bottom as the printer's job timeline — what's printing NOW, what's UP NEXT (with queue actions), then the HISTORY archive (stats + reprint). Frees a tab slot.*

```tsx
<Page title="Jobs" refreshControl={<RefreshControl refreshing onRefresh={refresh} tintColor={c.t3} />}>
  <QueueSection   key={`q${refreshKey}`} … />
  <HistorySection key={`h${refreshKey}`} … />
</Page>
```
`refresh()` bumps `refreshKey` — **the sections own their data and their own poll intervals, so remounting is how a pull-to-refresh re-fetches both**; `refreshing` is cleared by a `setTimeout(…, 600)`, not by real completion.

#### 3.1 `QueueSection`
- Fetch: `GET /api/v1/queue/` → `QueueItem[]`. **Polls every 5000 ms** (`setInterval`, cleared on unmount). Same `catch` idiom as the library: `setItems(prev => prev ?? [])` + `loadFailed = true`.
- Derivation:
```ts
const vm       = presentDashboard(status, Date.now());
const pending  = (items ?? []).filter(i => i.status === 'pending' || i.status === 'queued');
// The queue is backend-global; this tab shows the selected printer's lane (untargeted jobs included).
const upcoming = pending.filter(i => i.printer_id == null || i.printer_id === printerId);
const elsewhere = pending.length - upcoming.length;
const otherNames = [...new Set(pending.filter(i => !upcoming.includes(i))
  .map(i => i.printer_name || printers.find(p => p.id === i.printer_id)?.name || 'another printer'))];
const printing = vm.kind === 'live';        // NEVER re-derive from status.state
```
- States: `items === null && !loadFailed` → spinner (marginTop 40). `loadFailed` → `LoadFailed`. `items.length === 0 && !printing && !loadFailed` → **compact inline** card (not a full-screen `Empty`, because history renders right below): `marginHorizontal 20 marginTop 16 padding 14 radius 14 bg c.s1 border 1 c.line`, `Feather list 16 c.t3`, text `500/12.5 c.t3` = "Nothing queued. Files you send to print line up here.", and a `Browse` pill (`paddingHorizontal 12 paddingVertical 8 radius 10 bg c.s3`, `600/12 c.accent`) → `onBrowse()` (switches the shell to the library tab).
- **NOW PRINTING** (when `printing`): header `600/11 letterSpacing 1 mono c.t3`, `paddingHorizontal 20 paddingTop 18 paddingBottom 11`. Card `marginHorizontal 20 padding 16 radius 18 bg c.s1 border **1.5** c.running`; title `vm.heroSub || 'Current print'` `600/14 c.t1`; row `PulseDot color=c.running size=6 period=2000` + `` `${vm.progressInt}% · ${vm.etaText} left` `` (`600/11 mono c.running`); `<ExtrudeBar pct={vm.progressInt} color={c.running} height={5} />`.
- **UP NEXT** (when `upcoming.length`): header row `paddingTop 22 paddingBottom 11` — left `UP NEXT`, right `` `${upcoming.length} jobs` `` (both `600/11 mono c.t3`). Rows `paddingHorizontal 20 gap 10`, each `row gap 12 padding 12 radius 15 bg c.s1 border 1 c.line`:
  - Ordinal `i + 1`, `600/13 mono c.t3 width 16 center`.
  - Name `j.library_file_name || j.archive_name || `Job ${j.id}`` `600/13 c.t1` 1 line.
  - Sub `500/11 mono c.t3 marginTop 4`: `j.print_time_seconds ? fmtDuration(sec/60) : j.status`.
  - `x` button `30×30`, `hitSlop 8`, `Feather x 16 c.t3` → `Alert.alert('Remove from queue?', '“{name}” won\'t print.', [{Keep, cancel}, {Remove, destructive}])` → `POST /api/v1/queue/{id}/cancel` then `load()`; failure → `Alert.alert('Couldn’t remove', String(e))`. **Not LAN-gated** (`queueRemove` is Bambuddy bookkeeping).
- Footer when `elsewhere > 0`: `paddingHorizontal 20 paddingTop 18`, `500/12 c.t3`: `` `${elsewhere} more ${elsewhere === 1 ? 'job' : 'jobs'} queued for ${otherNames.join(', ')}.` ``

#### 3.2 `HistorySection`
- Fetches: `GET /api/v1/print-log/?limit=50` → `{items,total}` and `GET /api/v1/archives/stats` → `ArchiveStats`, both in `load()`; `GET /api/v1/settings/` once on mount (for the currency symbol). **Polls `load()` every 15000 ms.** Stats failure sets `stats = null` silently; print-log failure raises `loadFailed`.
- Header `HISTORY` (`600/11 letterSpacing 1 mono c.t3`, `paddingHorizontal 20 paddingTop 24 paddingBottom 2`).
- States: `entries === null && !loadFailed` → spinner; `loadFailed` → `LoadFailed`; `entries.length === 0 && !loadFailed` → `Empty` icon `clock`, **"No prints yet"**, "Once you finish a print it's archived here with its stats, filament, and cost."
- `StatsBanner` renders only when `entries !== null && stats && stats.total_prints > 0`.
- List header: **`RECENT PRINTS · TAP TO REPRINT`** (`600/11 letterSpacing 1 mono c.t3`, `paddingTop 26 paddingBottom 12`), rows `paddingHorizontal 20 gap 10`.
- **Reprint**, LAN-gated via `printAgain`:
```ts
const reprint = (e) => {
  if (e.archive_id == null) return;
  // The row is a list item, not a button — dimming the whole history would read as broken, so this
  // one explains itself on tap instead of going grey.
  lock.press('printAgain', () => Alert.alert('Print again?', `“${e.print_name || `Print ${e.id}`}” goes back into the queue.`, [
    { text: 'Cancel', style: 'cancel' },
    { text: 'Print again', onPress: () => client.reprint(e.archive_id!, printerId)
        .then(() => Alert.alert('Queued', 'The job is back in the queue.'))
        .catch(err => Alert.alert('Couldn’t reprint', String(err))) },
  ]))();
};
```
`client.reprint(archiveId, printerId)` → `POST /api/v1/queue/` with `{ printer_id, archive_id, use_ams: true }`. **`POST /archives/{id}/reprint` is GONE (410).**

#### 3.3 `StatsBanner` / `StatBlock` / `SuccessRing`
```ts
const total   = stats.total_prints || 0;
const success = total > 0 ? Math.round((stats.successful_prints / total) * 100) : 0;
const grams   = stats.total_filament_grams || 0;
const filamentVal  = grams >= 1000 ? (grams / 1000).toFixed(2) : Math.round(grams).toString();
const filamentUnit = grams >= 1000 ? 'kg' : 'g';
const showCost   = stats.total_cost > 0;
const showEnergy = stats.total_energy_kwh > 0;
```
Wrapped in `FadeRise` (opacity 0→1 + translateY 11→0 over 340 ms). Card 1 (`padding 20 radius 22 bg c.s1 border 1 c.line ...shadow1`): `LIFETIME PRINTS` (`600/10 letterSpacing 1.2 mono c.t3`), `RollingNumber total` at `fontSize 46 weight 700 letterSpacing -2`, then `PulseDot c.running 7 @2400` + `${successful_prints} done`, and when `failed_prints > 0` a `7×7 c.error` dot + `${failed_prints} failed` (`500/12 c.t2`). Right: `SuccessRing` = `ProgressRing size 76 stroke 7 progress=success color=c.accent` with `RollingNumber(pct) 20/700` and `SUCCESS` (`600/8 mono c.t3 marginTop -2`) inside.
Card 2 (`marginTop 12 padding 18 radius 22`, wrap, `rowGap 18 columnGap 12`) — `StatBlock`s (`flex:1 minWidth '30%'`, label `600/9.5 letterSpacing 1 mono c.t3`, value `RollingNumber 25/700 letterSpacing -1`, unit `600/12 c.t3`):
`PRINT HOURS` = `total_print_time_hours.toFixed(1)` + `h`; `FILAMENT` = value/unit above; `EST. COST` = `fmtMoney(sym, total_cost)` with `accent` colouring (only when `showCost`); `ENERGY` = `total_energy_kwh.toFixed(2)` + `kWh`, or `'—'` with no unit.
When `stats.energy_data_warming_up`: `marginTop 8 marginLeft 4`, `500/11 c.t3` — "Energy data is warming up — costs appear after the next full job."

#### 3.4 `HistoryRow` + helpers
```ts
function statusMeta(s: string) {                       // recomputed per call — see theme note
  if (s === 'completed') return { label: 'Done',     color: c.running, dim: c.runningDim };
  if (s === 'failed')    return { label: 'Failed',   color: c.error,   dim: c.errorDim };
  if (s === 'cancelled') return { label: 'Canceled', color: c.idle,    dim: c.idleDim };
  return { label: s ? s[0].toUpperCase() + s.slice(1) : 'Unknown', color: c.idle, dim: c.idleDim };
}
/** "2026-06-28T15:07:35.681213" is naive *local* time (no Z); new Date() parses naive as local. */
function relTime(iso: string | null): string {
  if (!iso) return '';
  const ms = Date.now() - new Date(iso).getTime();
  if (!isFinite(ms)) return '';
  const m = Math.floor(ms / 60000);
  if (m < 1) return 'just now';
  if (m < 60) return `${m}m ago`;
  const h = Math.floor(m / 60);
  if (h < 24) return `${h}h ago`;
  const d = Math.floor(h / 24);
  if (d < 7) return `${d}d ago`;
  return new Date(iso).toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
}
/** First swatch from a possibly comma-joined "#565656,#000000". */
function firstColor(s: string | null) { return s ? normColor(s.split(',')[0]?.trim() || undefined) : null; }
```
Row layout: `row gap 13 padding 12 radius 16 bg c.s1 border 1 c.line`. Thumb `58×58 radius 12 border 1 c.line bg c.thumb`; source `client.printLogThumbUrl(entry.id, camToken, entry.thumbnail_path)` = `{base}/api/v1/print-log/{id}/thumbnail?token={camToken}` (**camera stream token again**, `''` when absent) → fallback `Feather box 22 c.t3`.
Line 1: name `entry.print_name || `Print ${entry.id}`` `600/14 c.t1` flex 1 + status chip `paddingHorizontal 8 paddingVertical 3 radius 7 bg meta.dim`, text `700/9.5 letterSpacing 0.4 mono meta.color`, `meta.label.toUpperCase()`.
Line 2 (`marginTop 6, gap 8`): `Swatch value={firstColor(entry.filament_color)} size 11 radius 3` when known; `relTime(entry.started_at)` `500/11 mono c.t3`; then `· ` + facts joined by ` · ` where facts = `[fmtDuration(duration_seconds/60)?, `${Math.round(filament_used_grams)}g`?, `${energy_kwh.toFixed(2)} kWh`?]` (each included only when non-null); then, when `cost = entry.cost ?? entry.energy_cost` is `> 0`, `· ${fmtMoney(sym, cost)}` in `600/11 mono c.accent`.
Line 3: `entry.printer_name` when present, `500/10 mono c.t3 marginTop 4`.
The whole row is a `Tap` that is `disabled` unless `onReprint && entry.archive_id != null` (archive-less rows are inert but visually identical).

---

### 4. `AmsView` — the **Hardware** tab (filament + nozzles + maintenance)

`Page title="Hardware"`. Three `SectionHead`-separated groups: **FILAMENT**, **NOZZLES**, **MAINTENANCE**.

#### 4.1 Data & refresh
```ts
const vm     = presentDashboard(status, Date.now());   // units + slots come from presentAms — NO ams[0] anywhere
const dryers = presentDryer(status);
const [assigns, setAssigns] = useState<SlotAssignment[] | null>(null);
const loadInv = useCallback(() => {
  client.listAssignments(printerId).then(setAssigns).catch(() => setAssigns([]));
}, [client, printerId]);
useEffect(loadInv, [loadInv]);

// Pull-to-refresh re-fetches only the FETCHED data (assignments + maintenance, remounted via key).
// Trays/temps/dryer are live WS state and need no refetch.
const refresh = () => { setRefreshing(true); loadInv(); setMaintKey(k => k + 1); setTimeout(() => setRefreshing(false), 600); };
```
`listAssignments` → `GET /api/v1/inventory/assignments?printer_id={id}`, and it **already swallows its own errors returning `[]`**, so the AMS view degrades to status-only tray data.

#### 4.2 FILAMENT header + unit chips
`SectionHead label="FILAMENT" first right={vm.amsUnits.length > 1 ? `${n} units` : amsLabel}` — `amsLabel` comes from the printer profile (`'AMS Lite'` / `'AMS 2 Pro'` / `'AMS'`).
Under it (`paddingHorizontal 20`, row, wrap, `gap 8`): `${vm.ams.filter(t => !t.empty).length} of ${vm.ams.length || 4} slots loaded` (`500/13 c.t3`), then **one chip per unit** — *comment: an AMS 2 Pro and an AMS HT sit at very different humidity/temp, so a single machine-wide reading (this used to show `ams[0]`'s) was actively misleading.*
Chip: `paddingHorizontal 9 paddingVertical 3 radius 8 bg c.s2 gap 5`; unit label `700/10 mono c.t2`; humidity (only when `!= null && > 0`) `droplet 10 c.t3` + `${Math.round(h)}%`; temp (same guard) `thermometer 10 c.t3` + `${t.toFixed(1)}°`; and when `amsUnits.length > 1`, the routing suffix:
- `vm.amsRouting === 'switch'` → `→ auto`
- else `extruderSide(u.extruder)` → `→ Right` / `→ Left` (omitted when empty)
All `600/10 mono c.t3`.
**Gotcha (documented in-file):** *Extruder 0 is the RIGHT/main head on the H2 series — this chip shipped inverted. With a Filament Track Switch fitted no unit has a fixed extruder at all, so say "auto" rather than showing a stale binding for some units and nothing for the others.*

`extruderSide` (`src/ams/units.ts`): `e === 0 ? 'Right' : e === 1 ? 'Left' : ''`.

#### 4.3 Slot cards
Container `paddingHorizontal 20 paddingTop 18 gap 12`, one card per `vm.ams` slot: `padding 16 radius 18 bg c.s1`, border `t.active ? 1.5 c.accent : 1 c.line`, `...shadow1`.

**Spool resolution — the id-math gotcha:**
```ts
// Prefer tray_uuid (RFID), fall back to (ams_id, tray_id).
// Assignments are stored per (ams_id, LOCAL tray_id) — matching on tray_id alone would resolve the
// HT's spool to AMS-0's, since both units have a tray 0.
const spoolForSlot = (slot: AmsSlotVM): SlotAssignment['spool'] | null => {
  if (!assigns?.length) return null;
  const uuid = (status?.ams ?? []).find(u => (asNum(u.id) ?? 0) === slot.unitId)?.tray?.[slot.localId]?.tray_uuid ?? null;
  const byUuid = uuid ? assigns.find(a => a.spool?.tray_uuid === uuid) : undefined;
  const hit = byUuid ?? assigns.find(a => a.ams_id === slot.unitId && a.tray_id === slot.localId);
  return hit?.spool ?? null;
};
```

**Title / subtitle composition** (every line here encodes a fixed bug):
```ts
const swatch = spool ? (normColor(spool.rgba ?? undefined) ?? t.color) : t.color;
// A swatch cannot say "white" — on a white card it is a hole — and the row otherwise read just "PETG".
// A vendor's own name always wins.
const named  = spool?.color_name ?? colorName(swatch);
const title  = spool
  ? (spool.color_name ? `${spool.color_name} ${spool.material}`
                      : [colorName(swatch), spool.material].filter(Boolean).join(' '))
  : (t.empty ? 'Empty slot' : [named, t.label].filter(Boolean).join(' '));
const grams = spool ? spoolGramsRemaining(spool) : null;   // max(0, label_weight - weight_used)
// The LOCATION always leads: "Slot 1" is ambiguous across units.
const slotName = vm.amsUnits.length > 1 ? `${t.unitLabel} · Slot ${t.localId + 1}` : `Slot ${t.localId + 1}`;
// Drop a brand the preset name already repeats ("Bambu Lab · Bambu PETG Basic").
const brand = spool?.brand ?? '';
const preset = spool?.slicer_filament_name ?? '';
const brandRedundant = !!brand && !!preset && preset.toLowerCase().startsWith(brand.split(' ')[0].toLowerCase());
const spoolLine = [brandRedundant ? '' : brand, preset].filter(Boolean).join(' · ');  // 2 lines max
const isHt = vm.amsUnits.find(u => u.id === t.unitId)?.kind === 'ht';
```
Layout: `Swatch value={swatch} size={46} radius={12} empty={t.empty}` + a flex column:
- Title row `gap 8`: title `700/16 c.t1 flexShrink 1` 1 line; `ACTIVE` chip when `t.active` (`paddingHorizontal 7 paddingVertical 2 radius 6 bg c.accentDim`, `600/8.5 letterSpacing 0.5 mono c.accent`); extruder chip when `!t.empty && extruderSide(t.extruder)` (`bg c.s3`, `600/8.5 mono c.t2`, `→ RIGHT`/`→ LEFT`) — *never on an empty slot: there is no filament in it to feed anything*; with a Filament Track Switch this per-slot answer is the only true one.
- `slotName` `500/11 mono c.t3 marginTop 5`.
- `spoolLine` `500/11 lineHeight 15 c.t3`, up to 2 lines.
Trailing (when `!t.empty`): if `grams != null` → `${Math.round(grams)}g` `700/17 mono c.t1` over `t.pct` `600/10 mono c.t3`; else just `t.pct` `700/17 mono c.t1`. (`t.pct` is `'—'` when empty, else `` `${Math.round(remain)}%` ``.)
Action:
- Loaded slot → right-aligned **Unload** pill (`paddingHorizontal 16 paddingVertical 8 radius 10 bg c.s3`, `600/12 c.t1`), `lock.press('amsUnload', …)` → `POST /api/v1/printers/{id}/ams/unload`; failure `Alert.alert('Unload failed', String(e))`. **Quirk:** the label is written `lock.blocked('amsUnload') ? ' Unload' : 'Unload'` — a leading space with no lock glyph; the lock icon is only rendered on the Load button. Port this as a plain lock affordance.
- Empty slot **and not the HT** → full-width **Load filament** button (`marginTop 14 height 44 radius 12 border 1 c.line2`, `600/13 c.accent`, with `Feather lock 13 c.accent` prefixed when blocked), `lock.press('amsLoad', …)` → `POST /api/v1/printers/{id}/ams/load?tray_id={t.globalId}`; failure `Alert.alert('Load failed', String(e))`.
  *Comment: **global** tray id, not the flat index — index 4 is the HT, whose id is 128. Bambuddy documents `ams/load` for tray ids 0–15 only, so the HT's button stays hidden until it's confirmed on hardware; reads and drying are unaffected.*

The id math lives in one place:
```ts
export const globalTrayId = (unitId: number, localId: number): number =>
  unitId >= 128 ? unitId : unitId * 4 + localId;    // HT units (128..135) ARE their own tray id
```

#### 4.4 Dryers
Rendering order in the page: **active dryer cards first** (one per `d.active`), then `IdleDryers` (the collapsed group), then the slot cards.

```tsx
{dryers.filter(d => d.active).map((d, i) =>
  <DryerCard key={d.amsId} d={d} unitLabel={dryerLabel(vm, d.amsId, i)} … />)}
<IdleDryers dryers={dryers.filter(d => !d.active)} … />
```
```ts
/** Unit name for a dryer card; falls back to a positional label if the unit isn't in the VM. */
function dryerLabel(vm: DashVM, amsId: number, i: number): string | null {
  return vm.amsUnits.length > 1 ? (vm.amsUnits.find(u => u.id === amsId)?.label ?? `AMS ${i + 1}`) : null;
}
```
**`IdleDryers`** — *comment: each idle unit used to render its own collapsed card, all with identical copy, so a three-unit machine spent most of the first screen telling you three times that you can dry filament. One unit still renders directly — wrapping a single card in a disclosure is just a wasted tap.*
- `dryers.length === 0` → `null`; `=== 1` → the bare `DryerCard`; `> 1` → a disclosure card (`marginHorizontal 20 marginTop 14 radius 16 bg c.s1 border 1 c.line`) whose header row (`padding 14 gap 12`) is `Feather wind 17 c.t2` + "Filament drying" (`600/14 c.t1`) + `${dryers.length} units ready · ${names}` (`500/11.5 c.t3`, names joined by ` · `) + `chevron-up/down 18 c.t3`; expanded it renders every `DryerCard` inline.

**`DryerCard`** — *Handy-style drying: pick a loaded filament → its recommended temp/time (from RFID/preset, with per-type fallbacks), adjust, optional spool rotation; live cycle detail + Stop while running.*

State: `open`, `selType: string|null`, `tweak: {type, temp|null, hours|null} | null`, `rotate = true`, `busy`.
```ts
const opt = d.options.find(o => o.type === selType) ?? d.options[0] ?? null;
// Manual ± tweaks are KEYED to the filament type they were made for. The options list is live (WS tray
// updates): if the selected spool is pulled mid-config, `opt` silently falls back to another filament —
// stale absolute numbers must NOT carry over (a PA temp applied to PLA deforms the spool).
const t = tweak && opt && tweak.type === opt.type ? tweak : null;
const effTemp  = t?.temp  ?? opt?.temp  ?? 55;
const effHours = t?.hours ?? opt?.hours ?? 8;
const pick = (type) => { setSelType(type); setTweak(null); };   // re-follow the recommendation
const adjTemp  = (d5) => opt && setTweak({ type: opt.type, temp:  Math.min(Math.max(effTemp + d5, DRY_MIN_TEMP), d.maxTemp), hours: t?.hours ?? null });
const adjHours = (d1) => opt && setTweak({ type: opt.type, hours: Math.min(Math.max(effHours + d1, 1), DRY_MAX_HOURS), temp: t?.temp ?? null });
```
Steps: temperature ±5 °C clamped to `[45, d.maxTemp]`; duration ±1 h clamped to `[1, 24]`. `DRY_MIN_TEMP = 45`, `DRY_MAX_HOURS = 24`, `maxTemp = 85` (AMS-HT) or `65` (AMS 2 Pro).

**Start** — with the silent-failure verification that must survive the port:
```ts
client.dryingStart(printerId, d.amsId, { temp: effTemp, hours: effHours, filament: opt?.type, rotate })
  .then(() => {
    setOpen(false);
    // Bambuddy answers 200 as soon as the MQTT command is SENT — the printer can still refuse it
    // (observed live: result:'failed', reason:'mqtt message verify failed' when LAN Developer Mode is
    // off) and nothing surfaces anywhere. Verify the AMS actually entered drying.
    setTimeout(async () => {
      try {
        const s = await client.getStatus(printerId);
        const unit = (s.ams ?? []).find(a => a.id === d.amsId);
        // dry_time (minutes remaining) > 0 is THE active signal; dry_status is unreliable and WS
        // numbers can arrive as strings.
        if (unit && !(Number(unit.dry_time ?? 0) > 0)) {
          Alert.alert('Drying didn’t start',
            'The printer rejected the command ("mqtt message verify failed"). Newer Bambu firmware requires LAN Developer Mode for this: on the printer’s screen, enable Settings → Network → Developer Mode, then try again.');
        }
      } catch { /* status fetch failed — can't verify; stay quiet */ }
    }, 9000);
  })
  .catch(e => Alert.alert('Couldn’t start drying', apiErrorDetail(e)))
  .finally(() => setBusy(false));
```
Endpoint: `POST /api/v1/printers/{id}/drying/start?ams_id={amsId}&temp={c}&duration={HOURS}&filament={type}&rotate_tray={bool}` — **`duration` is hours (1–24); minutes would 400.** Server validates 45–85 °C for both models, so the 65 °C clamp for the AMS 2 Pro must happen client-side. A blocked start returns **409** with a human `detail` → show via `apiErrorDetail`.
**Stop:** `Alert.alert('Stop drying?', 'Ends the current drying cycle.', [Cancel, Stop(destructive)])` → `POST /api/v1/printers/{id}/drying/stop?ams_id={amsId}`; failure `Alert.alert('Couldn’t stop drying', apiErrorDetail(e))`.

**Active card**: `marginHorizontal 20 marginTop 14 padding 16 radius 16 bg c.heatingDim border 1 c.heating`.
Row: `PulseDot c.heating 9` + `Drying ${d.filament || 'filament'}` (`700/15 c.t1`) with ` · ${unitLabel}` appended as an inline `12/600 c.t3` `Text` when multi-unit; **Stop** pill (`paddingHorizontal 15 paddingVertical 8 radius 11 bg c.s3`, `600/13 c.t1`, `opacity 0.5` while busy) via `lock.press('dryStop', stop)`.
Then `d.remainingText` at `700/26 mono c.t1` with a trailing `  left` (`13/600 c.t3`).
Then chips (`marginTop 10 gap 8 wrap`, each `paddingHorizontal 9 paddingVertical 4 radius 8 bg c.s2`): temperature chip when `stage != null && targetTemp != null` — `thermometer 11 c.heating` + `heating to ${targetTemp}°` or `holding ${targetTemp}°` (`600/11.5 mono c.t2`); humidity chip when `humidityPct != null` — `droplet 11 c.t3` + `${humidityPct}%`.

**Idle card**: same frame but `bg c.s1 border 1 c.line`. Header row (`padding 14 gap 12`) — `wind 17 c.t2`, title `unitLabel ? `Filament drying · ${unitLabel}` : 'Filament drying'` (`600/14 c.t1`), subtitle `open ? `This AMS dries up to ${d.maxTemp}°C.` : 'Dry damp spools right in the AMS.'` (`500/11.5 c.t3`), chevron `16 c.t3`.
Expanded (`paddingHorizontal 14 paddingBottom 14 gap 12`):
1. Filament chips (wrap, `gap 8`): `paddingHorizontal 10 paddingVertical 7 radius 10`, bg `c.accentDim`/`c.s2`, border `1 c.accent`/`1 c.line`; a `10×10 radius 5` colour dot when `o.color != null`; type `600/12` (`c.accent`/`c.t2`); recommendation `500/10.5 mono c.t3` = `${o.temp}° · ${o.hours}h`. When `!d.options.length`: "No filament loaded." (`500/12 c.t3`).
2. Two `Stepper`s side by side: `Temperature` = `${effTemp}°` (±5), `Duration` = `${effHours}h` (±1).
3. Rotate row: "Rotate spool" (`600/13 c.t1`) + "Turns the spool during drying for even heat." (`500/11 c.t3`) + `Toggle` (48×30, knob 24, `translateX 3 → 24`).
4. One line per blocker: `alert-triangle 13 c.heating` + text `500/12 c.heating`.
5. Start button `height 46 radius 12 bg c.accent`, label **`Start drying — ${effTemp}° for ${effHours}h`** (`700/14 c.accentInk`), prefixed with `Feather lock 14 c.accentInk` when LAN-blocked.
   `disabled = busy || d.blockers.length > 0 || !d.options.length`; opacity = `lock.blocked('dryStart') ? 0.4 : (disabled ? 0.45 : 1)`.

**`presentDryer` (pure, `src/ams/dryer.ts`)** — the semantics the UI depends on:
- Returns `[]` unless `status.supports_drying && status.ams?.length`. `supports_drying` is **printer-level**, so per-unit fail-open filtering is applied: `unitCanDry(u) = u.is_ams_ht === true || u.module_type === 'n3f' || u.dry_time !== undefined || u.dry_target_temp !== undefined || u.dry_filament !== undefined` (a heaterless first-gen AMS on the same hub must not get a drying card).
- `active = round(asNum(dry_time)) > 0` — **`dry_status` is NOT reliable (observed 0 mid-cycle on a live AMS 2 Pro)**.
- `maxTemp = is_ams_ht ? 85 : 65`.
- Options: dedupe trays by `tray_type`; `fromPreset = drying_temp > 0`; a preset-backed tray beats a `0/0` sibling; temps clamped to `[45, maxTemp]`, hours to `[1, 24]`; fallbacks `dryDefaultFor(type)` = exact match → prefix before `-` (so `PETG-CF` → PETG) → `{temp:55,hours:8}`.
  `DRY_DEFAULTS`: PLA 55/8, PETG 65/8, TPU 60/8, ABS 75/8, ASA 75/8, PC 80/10, PA 80/12, PVA 70/10, PET 70/10.
- `targetTemp`: "unknown target" arrives as `null` over REST but as **`0` over the WS** (different Bambuddy serializers, verified live) — anything `<= 0` becomes `null`, otherwise the active card renders "holding 0°". When active with an unknown target but a known `dry_filament`, fall back to that type's recommended temp.
- `stage = active && target != null && tempC != null ? (tempC < target - 3 ? 'heating' : 'holding') : null` (3 °C hysteresis).
- `blockers` from `dry_sf_reason[]` mapped through `DRY_BLOCKERS`, **code 6 ("Already drying") omitted** — the active card already conveys it:
  `0 Printer is busy · 1 Not enough power — too many AMS units drying, or the external PSU is required · 2 AMS is busy · 3 Filament is at the AMS outlet — retract it first · 4 A drying cycle is already starting · 5 Not supported in 2D mode · 7 AMS firmware is updating · 8 Plug in the external AMS power adapter to start drying`
- `amsId: asNum(unit.id) ?? 0` — **the WebSocket delivers ids as strings (`'128'`) while REST sends numbers**; leaving it raw made `amsUnits.find(u => u.id === d.amsId)` miss, so the HT's dryer card fell back to a positional label and announced itself as "AMS 3".

#### 4.5 `NozzlesSection` / `NozzleCard`
*Inventory grouped by toolhead. **No temperatures here** (those are on the dashboard, labelled Left/Right) so nothing is shown twice. On the H2C the RIGHT (main, extruder 0) head carries the nozzle changer — one ENGAGED nozzle plus its docked spares — and the LEFT is a fixed chipless nozzle.*
Renders `null` when `presentNozzles(status).toolheads.length === 0`. `SectionHead label="NOZZLES"`.
Per toolhead: sub-header row (`paddingHorizontal 20 paddingBottom 10 gap 8`) with `th.label` (`700/13 c.t1`); when `th.side !== 'single'`, `th.swappable ? `VORTEX · ${th.nozzles.length}` : 'FIXED'` (`600/10 letterSpacing 0.5 mono c.t3`); `ACTIVE` chip (`paddingHorizontal 6 paddingVertical 1.5 radius 5 bg c.accentDim`, `600/8 mono c.accent`) when `th.active`.
When `th.swappable`, an explainer line (`500/11.5 lineHeight 15 c.t3`): "Engaged is in the head now; the rest are docked. Color chips show each nozzle's last filament."
Cards: wrap grid `paddingHorizontal 20 gap 10`, each `width 47% flexGrow 1 padding 13 radius 15 bg c.s1`, border `highlight ? 1.5 c.accent : 1 c.line` where `highlight = showMounted && n.engaged`.
Card content: `Swatch value={n.colorHex} size 30 radius 8 ink={<Feather chevron-down 14 inkOn(n.colorHex)} />`; then a **wrapping** chip row (`flexWrap:'wrap', gap 5, rowGap 4` — *on a half-width card "0.4 mm" + HIGH FLOW + ENGAGED overflowed one line and the last chip was clipped*): diameter `700/14 c.t1` (`n.diameter || 'Nozzle'`); flow chip when `n.flow` — `HIGH FLOW` on `c.heatingDim`/`c.heating` or `STANDARD` on `c.s3`/`c.t3` (`600/7.5 letterSpacing 0.4 mono`); `ENGAGED` chip on `c.accentDim`/`c.accent` when `showMounted && n.engaged`.
Subtitle `500/10.5 mono c.t3`: `[n.type, n.serial && `#${n.serial}`].filter(Boolean).join(' · ')`.
**Semantics:** ENGAGED = physically in the toolhead now (rack `id < 16` — Bambu Studio's own parsing). The colour chip is per-nozzle filament **memory** (last filament run through it), so several docked nozzles legitimately show colours; only one can be ENGAGED. `inkOn(hex)` picks `#0D1012` above luminance 0.179, else `#FFFFFF`.

---

### 5. `PowerView` — the **Power** tab

#### 5.1 Data
```ts
const [plug, setPlug]       = useState<SmartPlug | null | undefined>(undefined);  // undefined = loading, null = none
const [allPlugs, setAllPlugs] = useState<SmartPlug[]>([]);
const [settings, setSettings] = useState<AppSettings | null>(null);
const loadBase = useCallback(() => {
  client.getPlug(printerId).then(p => setPlug(p ?? null)).catch(() => setPlug(null));   // GET /smart-plugs/by-printer/{id}
  client.listPlugs().then(setAllPlugs).catch(() => setAllPlugs([]));                    // GET /smart-plugs/
  client.getSettings().then(setSettings).catch(() => setSettings(null));                // GET /settings/
}, [client, printerId]);
```
Pull-to-refresh calls `loadBase()` and clears `refreshing` after 600 ms. *Comment: a fresh plug object re-arms the status poll (`usePlugState` keys on the id), which fires immediately — live watts/kWh refresh too.*

**`usePlugState(client, plug, periodMs = 5000)`** — shared by the hero control (5 s) and each `PlugRow` (8 s, *"these are background devices, not the thing you're watching"*):
```ts
// While a toggle is settling, ignore poll results — HA takes a few seconds to reflect the new state
// and the stale poll would visibly bounce the switch back.
const pendingUntil = useRef(0);
poll(): client.plugStatus(id)                                  // GET /smart-plugs/{id}/status
  .then(s => { if (!alive || Date.now() < pendingUntil.current) return;
    setOn(s.state?.toUpperCase() === 'ON');
    setReachable(!!s.reachable);
    setWatts(typeof s.energy?.power === 'number' ? s.energy.power : null);
    setKwh(typeof s.energy?.today === 'number' ? s.energy.today : null); })
  .catch(() => alive && setReachable(false));
set(next): setOn(next); pendingUntil.current = Date.now() + 8000;      // optimistic
           try { await client.plugControl(id, next); }                 // POST /smart-plugs/{id}/control {action:'on'|'off'}
           catch (e) { pendingUntil.current = 0; setOn(!next); throw e; }  // revert
```

`sockets = useMemo(() => otherPlugs(allPlugs, null), [allPlugs])` — **passing `null` keeps the printer's own plug in the list.** *Comment: it used to be excluded because it already has the big control above — but that made the printer's own plug look absent from the list of plugs, when in fact all of these are sockets on one strip.* `otherPlugs` drops `enabled === false` plugs (Bambuddy won't act on them, so a dead row is noise) and sorts by `id` ascending.

#### 5.2 States and layout
- **Empty**: only when `plug === null && !sockets.length` → `Page title="Power"` with `Empty` icon `power`, **"No smart plug linked"**, "Link the printer's plug in Bambuddy (Settings → Smart Plugs) to control power here."
- The whole printer block (`plug !== null`, i.e. loading *or* present) renders:
  - Sub-title `plug?.name ?? 'Printer smart plug'` (`500/13 c.t3`, `paddingHorizontal 20 marginTop 7`).
  - Hero card `marginHorizontal 20 marginTop 20 paddingVertical 30 radius 22 bg c.s1 border 1 c.line`, centred. `Breathe active={on && reachable} color={c.accent} grow={0.18} maxOpacity={0.5} style={{borderRadius:65}}` wrapping a `130×130 radius 65` button, bg `on ? c.accent : c.s3`, `Feather power 48` in `c.accentInk`/`c.t2`, `opacity: reachable ? 1 : 0.4`, `disabled={!reachable || plug === undefined}`.
  - `on ? 'Powered on' : 'Powered off'` (`700/19 c.t1 letterSpacing -0.3 marginTop 20`); reachability row (`PulseDot c.running 7 @2000` when reachable else a static `7×7 c.idle` dot) + `Plug reachable` / `Plug unreachable` (`500/12 c.t3`); hint "Tap to toggle the printer's smart plug".
  - **Toggle guard:** switching **off** confirms — `Alert.alert('Switch off the printer?', 'This cuts power at the smart plug. If a print is running, it will stop.', [Cancel, 'Switch off'(destructive)])`; **turning on is immediate (no confirmation)**. Failure → `Alert.alert('Plug command failed', String(e))`.
  - Two stat cards side by side (`marginTop 14 gap 12`, each `flex 1 padding 16 radius 18 bg c.s1 border 1 c.line`):
    - **DRAWING NOW** (`600/10 letterSpacing 1 mono c.t3`) with a `Spark color=c.accent count=6 size=3 spread=14` emitter on a `5×5` dot when `watts != null && watts > 5`; value `RollingNumber(Math.round(watts)) 28/700 letterSpacing -1` or `—`, unit `W` (`600/13 c.t3`).
    - **TODAY**: `RollingNumber(kwh.toFixed(2))` or `—`, unit `kWh`; below, `600/13 c.accent` with `fontVariant:['tabular-nums']`: `todayCost == null ? (price == null ? 'price not set' : '—') : `${fmtMoney(sym, todayCost)} today``.
- **THIS PRINT projection** — only when `running` (`status.state?.toUpperCase() === 'RUNNING'`):
```ts
const price     = settings?.energy_cost_per_kwh ?? null;
const sym       = currencySymbol(settings?.currency);
const todayCost = price != null && kwh != null ? kwh * price : null;
const pct       = typeof status?.progress === 'number' ? status.progress : null;
const remainMin = typeof status?.remaining_time === 'number' ? status.remaining_time : null;
let projCost = null, soFarCost = null;
if (running && price != null && watts != null && remainMin != null && pct != null && pct > 0 && pct < 100) {
  const elapsedMin = (remainMin * pct) / (100 - pct);   // total = elapsed + remain; pct = elapsed/total
  const kwhPerMin  = watts / 1000 / 60;
  soFarCost = elapsedMin * kwhPerMin * price;
  projCost  = (elapsedMin + remainMin) * kwhPerMin * price;
}
```
  Card `marginTop 12 padding 16 radius 18 bg c.s1 border **1.5** c.running`: `PulseDot c.running 7 @2000` + `THIS PRINT` (`600/10 letterSpacing 1 mono c.running`); `status.subtask_name || 'Current print'` (`600/13 c.t1`); two columns `gap 24` — `SO FAR` (`c.t1`) and `PROJECTED` (`c.accent`), values `700/20 letterSpacing -0.5 fontVariant tabular-nums`, `—` when null; footnote `500/11 c.t3`: `price == null ? 'Set an electricity price in Bambuddy to see cost.' : `Estimate from ${watts == null ? '—' : Math.round(watts)} W live draw · ${remainMin ?? '—'} min left``.
- **AUTOMATIC SWITCHING** card — *comment: this used to be a toggle wired to nothing but local state; plug settings are admin-only (a scoped API key gets 403), so the app **reports** them and Bambuddy owns them.*
  Header `Feather` = `automations.some(a => a.cuts) ? 'clock' : 'shield'` in `c.heating`/`c.t3`, label `AUTOMATIC SWITCHING`. Empty → "Nothing switches this plug automatically — power stays as you leave it." Otherwise one row per automation: a `6×6` dot (`a.cuts ? c.heating : c.t3`), `a.label` (`600/13 c.t1`), `a.detail` (`500/12 lineHeight 17 c.t3`). Footer: "Change these in Bambuddy → Settings → Smart Plugs."
  `plugAutomations(plug)` (pure) yields, in order:
  - `auto_on` → **Auto power-on** / "Switches on when a print starts." / `cuts:false`
  - `auto_off` → **Auto power-off** / `off_delay_mode === 'temperature'` ? `Switches off after a print, once the hotend cools below ${off_temp_threshold ?? 70}°C.` : `Switches off ${off_delay_minutes ?? 5} min after a print finishes.`; when `auto_off_persistent`, `" Survives a Bambuddy restart."` is appended; `cuts:true`
  - `auto_off_after_drying` → **Off after drying** / `Switches off ${off_delay_after_drying_minutes ?? 10} min after AMS drying finishes.` / `cuts:true`
  - `schedule_enabled` **and at least one valid `HH:MM`** (`/^([01]\d|2[0-3]):[0-5]\d$/`) → **Schedule** / `Switches on at HH:MM, off at HH:MM every day.` / `cuts: !!off`. *An enabled schedule with both fields null does nothing, and reporting it would be a phantom warning.*
- **ALL SOCKETS** (only when `sockets.length > 1`): header `600/10 letterSpacing 1 mono c.t3 marginTop 22`, then a `PlugRow` per socket with `isPrinter={p.id === plug?.id}`.
- **Tariff footer** (always): `marginTop 14 paddingHorizontal 16 paddingVertical 13 radius 14 bg c.s1 border 1 c.line`, `Feather zap 14 c.t3` + `500/12 lineHeight 17 c.t3`:
  `price == null ? 'Electricity price not set. Add it in Bambuddy → Settings → Energy.' : `Tariff ${fmtMoney(sym, price)}/kWh · set in Bambuddy → Settings → Energy``.

#### 5.3 `PlugRow`
`marginHorizontal 20 marginTop 10 padding 16 radius 18 bg c.s1 border 1 c.line`, row `gap 14`.
Name `plugLabel(plug)` = `p.name?.trim() || `Plug ${p.id}`` (`600/14 c.t1`, 1 line, `flexShrink 1`); `PRINTER` chip (`paddingHorizontal 6 paddingVertical 2 radius 6 bg c.accentDim`, `600/8.5 letterSpacing 0.5 mono c.accent`) when `isPrinter`.
Status row: `PulseDot color={on ? c.running : c.idle} size 6 period 2400` when reachable, else a static `6×6 c.idle` dot; text `500/12 c.t3` = `!reachable ? 'Unreachable' : on ? (watts == null ? 'On' : `On · ${Math.round(watts)} W`) : 'Off'`.
Armed automations, if any: `500/11 c.heating`, `armed.map(a => a.label).join(' · ')`, 1 line.
Trailing `Toggle value={on} onChange={toggle} disabled={!reachable}`. `toggle`: turning on applies immediately; turning off confirms — `Alert.alert(`Switch off ${name}?`, 'This cuts power at the smart plug.', [Cancel, 'Switch off'(destructive)])`. *Comment: cutting power to a peripheral is disruptive too — an AMS mid-print, a running dryer.*

---

### 6. `MaintenanceSection` (rendered inside the Hardware tab, remounted by `maintKey`)

```ts
const [data, setData] = useState<MaintenancePrinter | null | undefined>(undefined); // undefined = loading, null = failed
const [busy, setBusy] = useState<number | null>(null);                              // item id being marked
const load = useCallback(() => client.getMaintenance(printerId).then(setData).catch(() => setData(null)), [client, printerId]);
```
`GET /api/v1/maintenance/printers/{id}` → `{printer_id, printer_name, total_print_hours, maintenance_items[], due_count, warning_count}`. No polling — refresh happens by remount.

**Sort + filter (exact):**
```ts
const items = (data?.maintenance_items ?? []).filter(i => i.enabled);
items.sort((a, b) =>
  Number(b.is_due) - Number(a.is_due) ||
  Number(b.is_warning) - Number(a.is_warning) ||
  a.hours_until_due - b.hours_until_due);         // in-place sort on a fresh array
```
**Helpers:**
```ts
const MAINT_ICON: Record<string, FeatherName> = {   // Lucide name from the API -> closest Feather glyph
  Droplet:'droplet', Sparkles:'star', Flame:'thermometer', Ruler:'sliders',
  Square:'square', Cable:'git-commit', Wrench:'tool', Tool:'tool',
};
const maintIcon = (n) => (n && MAINT_ICON[n]) || 'tool';
function maintStatus(it) {
  if (it.is_due)     return { text: 'Due now', color: c.error,   urgent: true };
  if (it.is_warning) return { text: 'Soon',    color: c.heating, urgent: true };
  const h = it.hours_until_due;
  return { text: h >= 1 ? `in ${Math.round(h)} h` : `in ${Math.max(0, Math.round(h * 60))} min`, color: c.t3, urgent: false };
}
function fmtLastPerformed(iso) {
  if (!iso) return 'Never performed';
  const d = new Date(iso); if (isNaN(d.getTime())) return 'Performed';
  const days = Math.floor((Date.now() - d.getTime()) / 86400000);
  if (days <= 0) return 'Done today';
  if (days === 1) return 'Done yesterday';
  if (days < 30)  return `Done ${days} days ago`;
  return `Done ${d.toLocaleDateString()}`;
}
```
Header row (`paddingHorizontal 20 paddingTop 26 paddingBottom 12`): `MAINTENANCE` (`600/11 letterSpacing 1.2 mono c.t3`) and, when `data`, `${data.total_print_hours.toFixed(1)} h printed` (`600/11 mono c.t3`).
States: `data === undefined` → spinner (`marginTop 16`); `data === null` → card with "Couldn’t load maintenance." (`500/13 c.t3`); `data && items.length === 0` → centred card `padding 18 gap 8` with `Feather tool 22 c.t3`, "No reminders set up" (`600/14 c.t1`), and "Add service intervals in Bambuddy (Settings → Maintenance) and they’ll track here as you print." (`500/12 lineHeight 17 c.t3 center maxWidth 250`).
Item card — an `Animated.View` with **`layout={LinearTransition.springify().damping(18).stiffness(180)}`**: *after "Mark done" the list re-sorts (done items sink below due ones) — the spring makes the card visibly glide to its new slot instead of teleporting. Keys are stable item ids, so reanimated tracks each card across the reorder. One-shot (not a looping animation), so the reanimated-4 unmount race in `index.tsx` doesn't apply.*
Card: `padding 16 radius 18 bg c.s1`, border `st.urgent ? 1.5 st.color : 1 c.line`, `...shadow1`.
- Icon well `42×42 radius 12`, bg `st.urgent ? c.s3 : c.s2`, glyph `20` in `st.color`/`c.t2`.
- Name `700/15 c.t1`; `fmtLastPerformed(it.last_performed_at)` `500/11 mono c.t3`.
- Right column: urgent → chip `paddingHorizontal 9 paddingVertical 4 radius 7` bg `st.color === c.error ? c.errorDim : c.heatingDim`, text `700/10.5 letterSpacing 0.4 mono st.color` uppercased; non-urgent → `600/12 mono c.t2` plain text. Below: `every ${Math.round(it.interval_hours)} h` (`500/10 mono c.t3`).
- Progress bar `marginTop 13 height 4 radius 2 bg c.s3 overflow hidden`, fill width `pct` where
  `pct = Math.max(0, Math.min(100, (it.hours_since_maintenance / it.interval_hours) * 100))`, colour `st.urgent ? st.color : c.accent`.
- **Mark done** button (right-aligned, `paddingHorizontal 15 paddingVertical 9 radius 11`, bg `st.urgent ? c.accent : c.s3`, `opacity 0.5` while busy): spinner or `Feather check 14`, label `600/13`, ink `c.accentInk`/`c.t1`.
  Confirm: `Alert.alert(`Mark "${it.maintenance_type_name}" as done?`, `This resets its counter. Next reminder in ${Math.round(it.interval_hours)} h of printing.`, [Cancel, 'Mark done'])` → `client.performMaintenance(it.id)` then `load()`; failure `Alert.alert('Couldn’t update', String(e))`; `finally setBusy(null)`.
  **`POST /api/v1/maintenance/items/{id}/perform` is ADMIN-gated and needs a non-empty JSON body** — a bodyless POST 422s, and a scoped API key gets 403 regardless of permissions, so the client routes it through `adminReq` (Bearer JWT from `POST /api/v1/auth/login`, cached 23 h, one retry on 401/403). Not LAN-gated (Bambuddy DB only).

---

### 7. Endpoint index for these tabs

| Purpose | Method + path | Auth |
|---|---|---|
| Library list | `GET /api/v1/library/files` | `X-API-Key` |
| Library delete | `DELETE /api/v1/library/files/{id}` | key (needs Manage-Library, Bambuddy ≥ 0.2.4.8) |
| Library thumbnail | `GET /api/v1/library/files/{id}/thumbnail?token={camToken}` | **camera stream token** |
| Library share URL | `POST /api/v1/library/files/{id}/slicer-token` → `GET .../dl/{token}/{name}` | token in path, single-use |
| SD list | `GET /api/v1/printers/{id}/files?path=` | `X-API-Key` |
| SD download | `GET /api/v1/printers/{id}/files/download?path=` | `X-API-Key`, **no Range support** |
| SD plate meta | `GET /api/v1/printers/{id}/files/plates?path=` | `X-API-Key` |
| SD plate thumb | `GET /api/v1/printers/{id}/files/plate-thumbnail/1?path=` | `X-API-Key` |
| SD gcode (viewer) | `GET /api/v1/printers/{id}/files/gcode?path=` | `X-API-Key` |
| SD delete | `DELETE /api/v1/printers/{id}/files?path=` | `X-API-Key` |
| Queue list | `GET /api/v1/queue/` | key |
| Queue cancel | `POST /api/v1/queue/{itemId}/cancel` | key |
| Reprint | `POST /api/v1/queue/` `{printer_id, archive_id, use_ams:true}` | key |
| Print log | `GET /api/v1/print-log/?limit=50` | key |
| Print-log thumb | `GET /api/v1/print-log/{id}/thumbnail?token={camToken}` | **camera stream token** |
| Archive stats | `GET /api/v1/archives/stats` | key |
| Settings (price/currency) | `GET /api/v1/settings/` | key (read); writes admin-only |
| AMS assignments | `GET /api/v1/inventory/assignments?printer_id={id}` | key (client swallows errors → `[]`) |
| AMS load / unload | `POST /api/v1/printers/{id}/ams/load?tray_id={globalId}` / `.../ams/unload` | key; LAN-gated |
| Drying start / stop | `POST /api/v1/printers/{id}/drying/start?ams_id=&temp=&duration=&filament=&rotate_tray=` / `.../drying/stop?ams_id=` | key; LAN-gated; `duration` in **hours** |
| Status (verify drying) | `GET /api/v1/printers/{id}/status` | key |
| Plugs | `GET /api/v1/smart-plugs/by-printer/{id}`, `GET /api/v1/smart-plugs/`, `GET /api/v1/smart-plugs/{id}/status`, `POST /api/v1/smart-plugs/{id}/control` `{action:'on'\|'off'}` | key |
| Maintenance | `GET /api/v1/maintenance/printers/{id}`, `POST /api/v1/maintenance/items/{id}/perform` | read: key; perform: **admin JWT** |

`apiErrorDetail(e)` extracts the API's JSON `detail` from the thrown message (`/\{"detail"\s*:\s*"([^"]+)"/`) so a 409's "AMS is busy" surfaces instead of `Bambuddy POST … -> HTTP 409 {...}`.

---

### Port notes

**Screen scaffolding**
- `Page` → a `ScrollView { … }` with `.refreshable { await reload() }` and a large-ish inline title (`Text(title).font(.system(size: 30, weight: .bold)).kerning(-0.8)`) rather than `.navigationTitle` — the design's header is inside the scroll content with `safeAreaInsets.top + 8` padding and a fixed `120 pt` bottom inset for the floating tab bar. Keep the custom tab bar; do not adopt `TabView` unless you re-do the overlay/tab-bar chrome in `index.tsx`.
- `RefreshControl` → `.refreshable`. **Caveat:** three refresh handlers here (`AmsView`, `PowerView`, `JobsView`) fake completion with `setTimeout(600)` and one (`JobsView`) refreshes by remounting children with a changing `key`. `.refreshable` is `async` and *awaits* — port these as real `await` on the underlying fetches (an observable-object `reload()` per section), which is strictly better and removes the fake delay. `JobsView`'s key-remount becomes `await queueVM.reload(); await historyVM.reload()`.
- `Empty` / `LoadFailed` → small `ViewBuilder` structs; `ContentUnavailableView` is close but doesn't match the 72×72 rounded-square icon well or the accent CTA, so build them by hand.
- `Segmented` → a custom control, **not** `Picker(.segmented)` (the design uses 38 pt tall pills on `c.s2` with an `c.s4` selection and a specific corner radius).

**Theme**
- `c` (mutable global + `useSyncExternalStore`) → an `@Observable final class Theme` (or `Color` extensions driven by `@Environment(\.colorScheme)` if you drop the manual light/dark override). Because RN reads `c.token` inline at render, every colour is late-bound; in SwiftUI, inject the theme through `@Environment` so a theme flip re-renders. Do **not** cache colours in `let` constants at type scope — that's exactly the frozen-palette bug `statusMeta()` was written to avoid.
- `mono` → `.font(.system(size: n, weight: .semibold, design: .monospaced))`. Numeric columns already using `fontVariant: ['tabular-nums']` → `.monospacedDigit()`.

**Networking / auth**
- `BambuddyClient` ports almost 1:1 to an `actor BambuddyClient` with `URLSession`. Keep the three distinct auth schemes explicit, they are the top source of 401s:
  1. `X-API-Key` header (most endpoints + **all SD-card endpoints and their images**),
  2. camera **stream token** in `?token=` (library thumbnails, print-log thumbnails, camera),
  3. single-use slicer token embedded in the download path (library share).
- Images: `AsyncImage` **cannot send headers**. Every headered image here (`texClient.fileThumbUrl`, SD media posters, SD plate thumbnails) needs a custom loader: `URLSession.shared.data(for: request)` + an `NSCache`/disk cache, wrapped in a reusable `RemoteImage(url:headers:)` view. Token-in-URL images can use `AsyncImage`, but you'll want the same cache for `cachePolicy: "memory-disk"` parity.
- `Promise.allSettled` (bulk delete) → `withTaskGroup(of: Bool.self)` counting failures; keep the partial-failure alert.
- `apiErrorDetail` → decode the JSON `{detail: String}` body properly in the error type instead of regexing the message; surface `detail` in the alert.

**Lists**
- Library grid → `LazyVGrid(columns: [.adaptive(minimum: …)] or two flexible columns, spacing: 13)` with `.aspectRatio(4/3, contentMode: .fit)`. List mode → a hand-rolled `VStack` of rows inside a rounded card (SwiftUI `List` will fight the card look).
- Bulk selection → `EditMode` + `Set<Int>` selection is tempting but the design's selection chrome (dimming unselected cells to 0.55, corner check circles, custom Done/Delete bar) is custom; keep an explicit `selecting: Bool` + `selected: Set<Int>` on the view model and drive both grid and list from it.
- Long-press action sheet → `.contextMenu` is the idiomatic port (and gives a preview of the thumbnail for free), but it changes the interaction: the current build uses `Alert.alert(title, undefined, buttons)` as a menu. Either `.contextMenu` on the cell or `.confirmationDialog` triggered by `.onLongPressGesture` — the latter matches today's behaviour exactly. Keep the button order (Print… / View in 3D / Texturize… / Share… / Delete / Cancel) and the destructive roles.
- Destructive confirmations → `.alert` with `.destructive` roles; keep the exact copy (it's been tuned: "This can’t be undone.", "Keep"/"Remove", "Switch off").
- Share sheet → `ShareLink(item: URL)` or `UIActivityViewController`. Both need a **local file URL**, same as today: download to `FileManager.default.temporaryDirectory` (or caches) first. Keep `safeShareName()` — user-derived names can contain `/`.
- `MaintenanceSection`'s `LinearTransition.springify().damping(18).stiffness(180)` → `.animation(.spring(response:…, dampingFraction:…), value: sortedItems.map(\.id))` on the container plus stable `id:` in the `ForEach`; SwiftUI's implicit list reorder animation gives the same "glide, don't teleport" effect.

**Video + WebView**
- `SdVideoPlayer` → `AVPlayer` + `VideoPlayer`. **The download-then-play requirement stands**: the backend returns 200 with the full body and ignores Range, and `AVPlayer` cannot attach `X-API-Key`. Use `URLSession` **download task** with a delegate for real byte progress (`URLSessionDownloadDelegate.didWriteData`), fall back to the listed `size` when `totalBytesExpectedToWrite == NSURLSessionTransferSizeUnknown` (the `-1` case). Cache by filename and reuse — SD videos are immutable. ipcam chunks are ~250 MB, so a determinate progress bar is required, not a spinner.
  - *(Alternative if you want streaming: an `AVAssetResourceLoaderDelegate` can inject headers, but the server's lack of Range support still forces a full fetch — not worth it.)*
- `GcodeViewerOverlay` (WebView) is out of scope here but note `printerGcodePath` returns a **path**, and the viewer fetches it in-page with `authHeaders()` — a `WKWebView` port needs the same (hand it the URL + headers, never a 70 MB string).

**Pure logic — port verbatim, it's already unit-tested**
`libraryBrowse.ts` (`isSlicedFile`, `displayName`, `safeShareName`, `filterFiles`, `toggleSelection`), `printerFiles.ts` (`isSliced3mf`, `isPlayableVideo`, `isMediaFolder`, `mediaThumbPath`, `mediaLabel`), `dryer.ts` (`presentDryer`, `DRY_DEFAULTS`, `DRY_BLOCKERS`, clamps), `units.ts` (`globalTrayId`, `presentAms`, `extruderSide`, `switchExtruderForTray`), `power/present.ts` (`plugAutomations`, `otherPlugs`, `plugLabel`), plus the local helpers `statusMeta`, `relTime`, `firstColor`, `maintStatus`, `fmtLastPerformed`, `maintIcon`, `fmtBytes`, `currencySymbol`. These are `struct`/free-function ports with no framework dependency — write the Swift tests against the same cases.

**Things that will be HARD or need a different approach**
1. **`decodeURIComponent` + `%`-mangled names.** `displayName` relies on JS's lenient `decodeURIComponent` with a `try/catch`. Swift's `removingPercentEncoding` returns `nil` on malformed input — mirror the fallback (`raw` on failure), and note it does **not** throw for the same inputs, so behaviour differs on stray `%`.
2. **`localeCompare` sorting.** SD listing and media grid use `String.localeCompare` (locale-aware, case-insensitive-ish, numeric-unaware). Use `a.compare(b, options: [.caseInsensitive], locale: .current)` — plain `<` on Swift `String` gives different ordering for mixed case.
3. **Naive local timestamps.** `started_at` is `"2026-06-28T15:07:35.681213"` with **no timezone**, and `new Date()` parses it as *local*. `ISO8601DateFormatter` will refuse it (fractional seconds with 6 digits, no offset). Use a `DateFormatter` with `dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"` (plus a no-fraction fallback) and `timeZone = .current`. Getting this wrong shifts every "3h ago" by the UTC offset. Same for `last_performed_at`.
4. **Numbers arriving as strings over the WebSocket.** `asNum()` exists because REST sends numbers and the WS sends some of the same fields as strings (`temp: "30.4"`, `ams.id: "128"`). In Swift, decode these with a lenient `@propertyWrapper` / custom `init(from:)` that accepts both `Double` and `String` — a plain `Codable` model will throw and blank the whole Hardware tab. The HT-label bug (`amsUnits.find(u => u.id === d.amsId)` missing) came from exactly this.
5. **Optimistic plug toggles.** `usePlugState`'s `pendingUntil` (8 s window during which poll results are ignored) must be ported as-is; HA takes seconds to reflect the new state and without it the switch visibly bounces back. In Swift, a `Date` stored on the observable + a check inside the poll closure.
6. **Tri-state optionals as UI states.** Three separate `T | null | undefined` tri-states drive real branches: `files: LibraryFile[]?` (nil = loading), `plug: SmartPlug??` (`undefined` = loading, `null` = none, `.some` = present) and `data: MaintenancePrinter??`. Swift's `T??` is legal but awful to read — define `enum Loadable<T> { case loading, failed, loaded(T) }` (plus `.absent` for the plug) and port each branch explicitly. Note the Power tab's empty state is specifically `plug == null && sockets.isEmpty` — *loading* must not show it.
7. **`LoadFailed` vs empty.** Every list here deliberately distinguishes "fetch failed" from "genuinely empty" and keeps the previously-loaded data visible while showing the retry banner. Don't collapse these into one error state.
8. **The 9-second drying verification.** Port the `Task.sleep(9s)` + `getStatus` + `dry_time > 0` check verbatim. Bambuddy returns 200 the moment MQTT publish returns; the printer can still reject with "mqtt message verify failed" and nothing else would ever surface it. Cancel the task if the view goes away, but do **not** drop the check.
9. **LAN-mode gating.** `useLockedAction` → a small `@Observable LockGate` in the environment exposing `blocked(_:)`, `opacity(for:)` and a `press(_:_:)` wrapper. Keep the tri-state (`unknown` ≠ `off`) and the **unblocked** list (`stop`, `light`, `camera`, `plug`, `plateCleared`, `queueRemove`, `maintenance`) — greying out Stop on a spaghettifying print is the failure mode this design explicitly rejects.
10. **Poll intervals.** Queue 5 s, history 15 s, printer plug 5 s, peripheral plugs 8 s, and a 9 s one-shot after drying start. Port as `Task` loops with `Task.sleep`, cancelled in `.onDisappear` / `task(id:)`. The RN version keeps polling while the tab is backgrounded within the app; in SwiftUI, `.task {}` cancelling on disappear is a behaviour improvement — verify nothing relies on stale data being fresh on return (nothing does; every section re-fetches on appear).
11. **Animation kit.** `Tap` (scale 0.955 / opacity 0.62, 90 ms in / 170 ms out) → a `ButtonStyle`. `PulseDot` → `.opacity` between 1 and 0.22 with `.easeInOut(duration: period/2).repeatForever()`. `RollingNumber` (per-digit odometer) → `.contentTransition(.numericText())` on iOS 17+, which is close enough and far less code. `ProgressRing` → `Circle().trim(from:to:)` with `.animation(.easeInOut(duration: 0.7))`. `ExtrudeBar` (nozzle glyph riding the fill edge, driven by a shared `trackW` from `onLayout` so it animates a **transform**, not a layout prop) → `GeometryReader` + `.offset(x: fraction * width - 12)`. `Spark` particles and `Breathe` halo are straightforward `.scaleEffect`/`.opacity` repeaters. The reanimated-specific `cancelAnimation` on unmount (guarding the reanimated-4 New-Arch teardown crash, swmansion/react-native-reanimated#9402) has **no SwiftUI analogue and can be dropped**.
12. **`Feather` glyph names.** All icon names in this file are Feather, not SF Symbols. You need a mapping table: `wifi-off → wifi.slash`, `folder`, `hard-drive → externaldrive`, `film`, `box → shippingbox`, `file → doc`, `droplet`, `wind`, `thermometer`, `alert-triangle → exclamationmark.triangle`, `tool → wrench.and.screwdriver`, `git-commit → point.topleft.down.curvedto.point.bottomright.up` (or `cable.connector`), `sliders`, `star → sparkles`, `power`, `zap → bolt`, `clock`, `shield`, `list → list.bullet`, `check-square`, `grid`, `check`, `chevron-*`, `arrow-up`, `plus`, `x → xmark`, `search → magnifyingglass`, `share → square.and.arrow.up`, `download → arrow.down.circle`, `layers → square.3.layers.3d`, `play`, `trash-2 → trash`, `minus`, `lock`, `help-circle → questionmark.circle`. Keep the **`MAINT_ICON`** Lucide→glyph table (`Droplet, Sparkles, Flame, Ruler, Square, Cable, Wrench, Tool`) — those strings come from the API.
13. **The `' Unload'` label quirk** (leading space when LAN-blocked, with no lock glyph) is almost certainly a bug — port it as a proper lock affordance matching the Load button (`lock` glyph + dimmed), not as a leading space.
14. **Currency.** `currencySymbol()` is a hand-rolled 6-case switch with a `"${code} "` fallback (note the trailing space). `Decimal` + `.formatted(.currency(code:))` is the idiomatic Swift port and handles every ISO code — but it also localises placement and separators, so the rendered strings will differ from today's `£12.34`. If pixel-identical output matters, port the switch verbatim; otherwise prefer `FormatStyle` and accept the change.
