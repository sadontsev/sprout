<!-- Generated as the port specification for the native Swift rewrite. -->
# The main screen, tab bar, alerts and swatches

## dashboard-ui

Source files (all read in full):
- `/Users/max/ai-projects/bambu-app/mobile/src/components/DashboardView.tsx` (517 lines)
- `/Users/max/ai-projects/bambu-app/mobile/src/components/TabBar.tsx` (55 lines)
- `/Users/max/ai-projects/bambu-app/mobile/src/components/AlertsOverlay.tsx` (93 lines)
- `/Users/max/ai-projects/bambu-app/mobile/src/components/Swatch.tsx` (60 lines)
- `/Users/max/ai-projects/bambu-app/mobile/src/components/NozzleIcon.tsx` (19 lines)

Supporting files read for exact values: `src/theme.ts`, `src/dashboard/present.ts`, `src/alerts/present.ts`, `src/cooling/present.ts`, `src/capabilities/lanMode.ts`, `src/capabilities/useLockedAction.ts`, `src/components/anim/index.tsx`, `src/components/anim/animUtils.ts`, `src/ams/units.ts`, `src/app/index.tsx`, `src/api/bambuddyClient.ts`.

---

### 0. Design tokens (`src/theme.ts`) — the whole palette

Two palettes. **`c` is a single live-mutated object** (`Object.assign(c, themes[name])`) with a `useSyncExternalStore` subscription; components read `c.token` *inline at render*, so nothing may capture a color at module scope. This is why `SPEEDS[].dot` stores a *palette key* (`'paused'`) rather than a value, and why `presentDashboard`'s `base()` is a function rather than a constant.

| token | dark | light | used for |
|---|---|---|---|
| `bg` | `#0A0B0C` | `#EFF1F3` | scroll background, AlertsOverlay backdrop |
| `s1` | `#131517` | `#FFFFFF` | cards, tab bar, popovers, AMS chips |
| `s2` | `#191C1F` | `#F5F6F8` | settings/close pill, cooldown card, offline icon well, Skeleton base |
| `s3` | `#23272B` | `#EAECEF` | secondary buttons, selected rows, progress track, HeatBar track |
| `s4` | `#2D3237` | `#DEE1E5` | speed button while its popover is open |
| `line` | `rgba(255,255,255,0.07)` | `rgba(0,0,0,0.08)` | 1px card hairlines, dividers, tab-bar top border |
| `line2` | `rgba(255,255,255,0.12)` | `rgba(0,0,0,0.13)` | popover / switcher borders, lookup-button border |
| `t1` | `#F3F5F7` | `#0D1012` | primary text |
| `t2` | `#A4ABB2` | `#585E64` | secondary text, settings glyph |
| `t3` | `#6B7177` | `#878D94` | tertiary/mono labels, inactive tab |
| `accent` | `#2BD4C0` | `#0EAE9C` | primary CTA, active tab, checks, "Details" |
| `accentInk` | `#04201D` | `#FFFFFF` | text/glyphs **on** accent fills |
| `accentDim` | `rgba(43,212,192,0.15)` | `rgba(14,174,156,0.14)` | light-ON pill, info alert fill |
| `running` | `#30D158` | `#23B24A` | printing, cooldown-ready, complete |
| `runningDim` | `rgba(48,209,88,0.15)` | `rgba(35,178,74,0.14)` | complete check-circle well |
| `heating` | `#FF9F0A` | `#E0860A` | heating, warnings, LAN banner |
| `heatingDim` | `rgba(255,159,10,0.15)` | `rgba(224,134,10,0.14)` | warning fills, LAN banner fill |
| `paused` | `#0A84FF` | `#0A84FF` | paused state color, Silent speed dot |
| `pausedDim` | `rgba(10,132,255,0.15)` | `rgba(10,132,255,0.12)` | (not used on the dashboard) |
| `error` | `#FF453A` | `#E5392E` | error state, Stop, Ludicrous dot |
| `errorDim` | `rgba(255,69,58,0.15)` | `rgba(229,57,46,0.12)` | Stop button fill, error icon well |
| `idle` | `#8E9398` | `#9AA0A6` | idle/offline/connecting state color |
| `thumb` | `#0e1113` | `#E4E7EA` | camera-tile well behind the image |
| `swatchRing` | `#8E9398` | `#6E7378` | filament swatch ring (see §7) |
| `sheet`, `tabbar`, `idleDim`, `supports` | — | — | **not used by these five files** (`tabbar` in particular is *not* what TabBar paints) |

```ts
export const mono = Platform.select({ ios: 'Menlo', default: 'monospace' });
export const shadow1 = { shadowColor:'#000', shadowOpacity:0.5, shadowRadius:2, shadowOffset:{width:0,height:1} };
```
Everything else is the system font (SF). Weights used: `'500'`, `'600'`, `'700'` only.

---

### 1. `DashboardView` — root container and section order

```
ScrollView
  style:                { flex:1, backgroundColor: c.bg }
  showsVerticalScrollIndicator: false
  contentContainerStyle:{ paddingTop: safeAreaTop + 6, paddingBottom: 120 }
```
`paddingBottom: 120` is the clearance for the floating TabBar. Standard horizontal gutter throughout is **20pt** (`marginHorizontal: 20` / `paddingHorizontal: 20`); the offline block is the sole exception at 24.

**Children, in exact tree order:**

1. Header row (always)
2. Tap-away `Pressable` — only when `switcherOpen`
3. Fleet switcher popover — only when `switcherOpen`
4. Maintenance chip — `!!maintAlert && (maintAlert.due > 0 || maintAlert.warn > 0)`
5. Alert summary chip — `alertSummary(alerts) !== null`
6. Hero (always)
7. Camera tile — `kind ∈ {live, idle, complete, error}`
8. **LIVE** block — `kind === 'live'`
9. **IDLE** block — `kind === 'idle'`
10. **LAN banner** — `lanMode === 'off'`
11. **COMPLETE** block — `kind === 'complete'`
12. **ERROR** block — `kind === 'error'`
13. **OFFLINE** block — `kind === 'offline'`
14. **CONNECTING** block — `kind === 'connecting'`

> **Layout gotcha worth preserving:** the LAN banner sits at position 10 in the tree, i.e. **below** the live/idle content but **above** the complete/error/offline/connecting content. It is not a fixed-position banner and it is not always directly under the hero. Reproduce the ordering literally.

Local state:
```ts
const [camLoaded, setCamLoaded]   = useState(false);
const [speedOpen, setSpeedOpen]   = useState(false);
const [switcherOpen, setSwitcher] = useState(false);
const lock = useLockedAction(lanMode);

useEffect(() => { if (!snapshotUri) setCamLoaded(false); }, [snapshotUri]);   // gotcha A
useEffect(() => { if (lock.blocked('speed')) setSpeedOpen(false); }, [lock]); // gotcha B
```
Derived:
```ts
const showCamera  = vm.kind === 'live' || vm.kind === 'idle' || vm.kind === 'complete' || vm.kind === 'error';
const summary     = alertSummary(alerts);
const printerName = printer?.name ?? 'Printer';
const brand       = printer ? `BAMBU LAB ${printer.model.toUpperCase()}` : 'BAMBU LAB';
const canSwitch   = fleet.length > 1;
```

---

### 2. Header + printer switcher

**Header row** — `{ paddingHorizontal:20, flexDirection:'row', alignItems:'flex-start', justifyContent:'space-between' }`

*Left (the switcher trigger)* — a `Tap`, `disabled={!canSwitch}`, `onPress = () => canSwitch && setSwitcherOpen(o => !o)`:
- Brand line: `weight 600, size 11, color c.t3, letterSpacing 1.4, fontFamily mono` — text = `brand` (e.g. `BAMBU LAB A1`).
- Name row: `{ flexDirection:'row', alignItems:'center', gap:7, marginTop:6 }`
  - `PulseDot color={vm.stateColor} size={8}` (default period 2400ms, glow on)
  - Name: `weight 600, size 17, color c.t1, letterSpacing -0.2`
  - If `canSwitch`: Feather `chevron-up` when open / `chevron-down` when closed, size **15**, color `c.t3`

*Right* — settings `Tap`: `{ width:38, height:38, borderRadius:19, backgroundColor:c.s2, alignItems:'center', justifyContent:'center' }`, Feather **`settings`** size 19, color `c.t2`. → `router.push('/settings')`.

**Tap-away layer** (`switcherOpen` only): a bare `Pressable` with `{ position:'absolute', inset:0 }` that closes the switcher. It is rendered *before* the switcher card so it sits under it and over everything else.

**Fleet switcher popover** (`switcherOpen` only), wrapped in `FadeRise dy={-6} duration={180}` (drops **down** into place because dy is negative):
```
card: { marginHorizontal:20, marginTop:12, borderRadius:16, backgroundColor:c.s1,
        borderWidth:1, borderColor:c.line2, padding:5, ...shadow1 }
```
One row per `FleetEntry`, `key = printer.id`:
```
row Tap: { flexDirection:'row', alignItems:'center', gap:11,
           paddingHorizontal:12, paddingVertical:12, borderRadius:12,
           backgroundColor: isCurrent ? c.s3 : 'transparent' }
  PulseDot color={f.stateColor} size={8}
  column flex:1
    name : weight 600, size 14, color c.t1                      → f.printer.name
    sub  : marginTop 2, weight 500, size 11, color c.t3, mono
  if isCurrent: Feather 'check' size 15 color c.accent
```
Sub-line string, exactly:
```ts
`${f.printer.model}${f.printer.location ? ` · ${f.printer.location}` : ''} · ${
  f.kind === 'live' ? `${f.stateLabel} ${f.progressInt}%` : f.stateLabel}`
```
(`·` = U+00B7 middle dot, space-padded.) Tap behaviour: `setSwitcherOpen(false)`, and `h.onSelectPrinter(f.printer.id)` **only if it is not already the current printer**.

---

### 3. Maintenance chip and alert summary chip

Both are the same visual species: a full-width tinted pill with a leading glyph, a flexed label, and a trailing `chevron-right` (size 16, `c.t3`). Both are wrapped in a bare `FadeRise` (defaults: `delay 0, dy 11, duration 340`).

**Maintenance chip** → `h.onTab('ams')`
```
{ marginHorizontal:20, marginTop:14, paddingVertical:12, paddingHorizontal:14,
  borderRadius:14, flexDirection:'row', alignItems:'center', gap:11,
  backgroundColor: due > 0 ? c.errorDim : c.heatingDim,
  borderWidth:1, borderColor: due > 0 ? c.error : c.heating }
```
- Feather **`tool`** size 16, color `due > 0 ? c.error : c.heating`
- Label `flex:1, weight 600, size 13, color c.t1`:
```ts
due > 0
  ? `${due} maintenance ${due === 1 ? 'task is' : 'tasks are'} due`
  : `${warn} maintenance ${warn === 1 ? 'task is' : 'tasks are'} coming up`
```
Data source: `GET /api/v1/maintenance/printers/{printerId}` → `{ due_count, warning_count }`, polled every **60 000 ms**, reset to `{0,0}` on printer change.

**Alert summary chip** → `h.onAlerts()` (opens `AlertsOverlay`)
```
{ marginHorizontal:20, marginTop:14, paddingVertical:13, paddingHorizontal:14,
  borderRadius:14, flexDirection:'row', alignItems:'center', gap:11,
  backgroundColor: level==='error' ? c.errorDim : level==='warning' ? c.heatingDim : c.accentDim,
  borderWidth:1,
  borderColor:     level==='error' ? c.error   : level==='warning' ? c.heating   : c.accent }
```
Note `paddingVertical` is **13** here vs 12 on the maintenance chip — a real 1pt difference, not a typo to normalise.
- Feather `level === 'info' ? 'info' : 'alert-circle'`, size 16, same three-way color.
- Label `flex:1, weight 600, size 13, color c.t1` = `summary.label`.

`alertSummary` (from `src/alerts/present.ts`) — port verbatim:
```ts
export function alertSummary(alerts: AlertVM[]) {
  if (!alerts.length) return null;                       // renders NOTHING when clear — no "all good" row
  const level = alerts.some(a => a.level === 'error')   ? 'error'
              : alerts.some(a => a.level === 'warning') ? 'warning' : 'info';
  const actionable = alerts.filter(a => a.actions.some(x => x.id !== 'lookup')).length;
  const noun = alerts.length === 1 ? 'alert' : 'alerts';
  return { count: alerts.length, level,
           label: actionable > 0 ? `${alerts.length} ${noun} · ${actionable} actionable`
                                 : `${alerts.length} ${noun}` };
}
```
> Design comment kept in the source, and the reason the list is not inline: *"with 3 HMS notices plus a plate prompt, inline cards pushed the actual print state off the screen."* The dashboard shows exactly one row; all detail and every action live in the overlay.

---

### 4. Hero

```
{ paddingHorizontal:20, paddingTop:18, paddingBottom:2 }
  Text  weight 700, size 36, letterSpacing -1, color vm.stateColor   → vm.stateLabel
  if vm.heroSub:
  Text  marginTop 8, weight 500, size 13, lineHeight 17, color c.t2, mono → vm.heroSub
```

`stateLabel` / `stateColor` come from `presentDashboard` and are the **single source of print-state truth** — never re-derive from `status.state`:

| kind | condition (state uppercased) | label | color |
|---|---|---|---|
| `offline` | `!status.connected` | `Offline` | `c.idle` (heroSub `No response from the printer`) |
| `error` | `print_error` truthy \|\| `FAILED` \|\| `ERROR` | `Error` | `c.error` |
| `live` (paused) | `PAUSE` \| `PAUSED` | `Paused` | `c.paused` |
| `complete` | `FINISH` \| `FINISHED` \| `FINISHING` | `Complete` | `c.running` |
| `idle` | `IDLE` \| `''` \| `UNKNOWN` | `Idle` | `c.idle` (heroSub `No active job`) |
| `live` | otherwise | `stg_cur_name` if present and ≠ "printing", else `Heating` if `(nozzleHeating‖bedHeating) && progress < 2`, else `Printing` | `c.heating` when stage/heating, else `c.running` |
| `connecting` | `status === null` | `Connecting` | `c.idle` |

`heroSub` for live/complete is `status.subtask_name ?? ''` (the file name).

---

### 5. Camera tile

Rendered only when `showCamera`. Wrapper `{ paddingHorizontal:20, paddingTop:16 }`, a `Tap` at `width:'100%'` → `h.onCamera()` (opens the fullscreen `CameraOverlay`).

```
tile: { width:'100%', aspectRatio: 16/10, borderRadius:18, overflow:'hidden',
        backgroundColor: c.thumb, borderWidth:1, borderColor: c.line, ...shadow1 }
```
Contents:
- If `snapshotUri`: `expo-image` `<Image>` at 100%×100%, `contentFit="cover"`, `transition={120}` (ms cross-fade), `onLoad={() => setCamLoaded(true)}`.
- Else: centered placeholder `Text` — `weight 500, size 10, letterSpacing 1.6, color c.t3, mono`, literal string **`CHAMBER · SNAPSHOT`**.
- **Live badge** — absolute `top:11, left:11`, `{ flexDirection:'row', alignItems:'center', gap:5, paddingHorizontal:8, paddingVertical:4, borderRadius:8, backgroundColor:'rgba(0,0,0,0.55)' }`
  - dot: `camLoaded ? <PulseDot color={c.running} size={6} period={2000}/> : <View 6×6 borderRadius 3 backgroundColor c.t3/>`
  - text: `weight 600, size 9.5, letterSpacing 0.6, color '#fff'` = `camLoaded ? 'LIVE · 1 fps' : 'WAKING…'` (`…` is U+2026)
- **Expand chip** — absolute `bottom:9, left:11`, `{ width:26, height:26, borderRadius:7, backgroundColor:'rgba(0,0,0,0.5)', center }`, Feather **`maximize-2`** size 13, `#fff`.

**Snapshot state machine** (owned by the Shell, `src/app/index.tsx:271-283`):
```ts
const [tick, setTick] = useState(0);
useEffect(() => {
  if (cameraOpen || tab !== 'printer') return;          // pause while fullscreen, or tab hidden
  const id = setInterval(() => setTick(t => t + 1), 2000);
  return () => clearInterval(id);
}, [cameraOpen, tab]);
const snapshotUri = camToken && !cameraOpen
  ? `${client.snapshotUrl(printerId, camToken)}&_t=${tick}`
  : null;
```
- Endpoint: `GET {baseUrl}/api/v1/printers/{printerId}/camera/snapshot?token={cameraToken}` — the **camera stream token**, minted with `POST /api/v1/auth/…` → actually `POST /api/v1/printers/camera/stream-token`. `X-API-Key` is **rejected (401)** on snapshot/stream.
- Cache-bust is `&_t={tick}`; the picture only changes when the URL changes.
- **Gotcha (documented in-code):** the poller is deliberately *not* gated on `pipActive`. It was, and a `pipActive` that never cleared froze this tile on a cached frame.
- Badge says "1 fps" but the poll is every 2 s — the label is nominal, keep the string.
- **Gotcha A:** `camLoaded` resets to false whenever `snapshotUri` becomes null. A cold camera takes seconds to produce a frame, and the badge must not claim "LIVE" over a blank tile.

---

### 6. Print-state blocks

#### 6a. LIVE (`vm.kind === 'live'`, covers both printing and paused)

**Progress card**
```
{ marginHorizontal:20, marginTop:16, padding:20, borderRadius:22,
  backgroundColor:c.s1, borderWidth:1, borderColor:c.line,
  flexDirection:'row', alignItems:'center', gap:18, ...shadow1 }
```
Left: `ProgressRing progress={vm.progressInt} color={vm.stateColor} glow={!vm.isPaused}` — defaults `size 128`, `stroke 9`, `track c.s3`. Ring geometry: `r = (size - stroke)/2 = 59.5`, `circumference = 2πr`, `strokeDashoffset` animated to `circ * (1 - clamp01(progress/100))` over 700 ms with `bezier(0.4,0,0.2,1)`, `strokeLinecap="round"`, rotated `-90°` about center. Glow = an absolutely-positioned view at `0.7×size`, `borderRadius: size`, `shadowColor: color`, `shadowRadius: 9`, `shadowOpacity` pulsing `0 → 0.6` on a 1200 ms up / 1200 ms down infinite loop.
Ring center content: row `alignItems:'flex-end'` — `RollingNumber value={vm.progressInt} fontSize={32} weight="700" color={c.t1} letterSpacing={-1}` + `Text '%'` at `size 15, weight 700, color c.t3, marginBottom 2`.

Right column `{ flex:1, gap:15 }`:
- `<Label>LAYER</Label>` — the shared `Label` is `weight 600, size 10, color c.t3, letterSpacing 1, mono`.
- Row `{ marginTop:5, flexDirection:'row', alignItems:'flex-end' }`: `RollingNumber value={vm.layer} fontSize={19} weight="600" color={c.t1}` + `Text` `" / " + vm.totalLayers` at `weight 500, size 19, color c.t3, mono` (leading space is inside the string: `` ` / ${vm.totalLayers}` ``).
- Divider `{ height:1, backgroundColor:c.line }`.
- `<Label>TIME LEFT</Label>`, then `RollingNumber value={vm.etaText} fontSize={19} weight="600" color={c.t1} style={{marginTop:5}}`, then `Text` `done ~ ${vm.doneText}` at `marginTop 3, weight 500, size 12, color c.t3`.

Formatters (`src/dashboard/present.ts`):
```ts
export function fmtDuration(min: number): string {          // → vm.etaText
  if (!isFinite(min) || min <= 0) return '—';
  const h = Math.floor(min / 60), m = Math.round(min % 60);
  return h > 0 ? `${h}h ${String(m).padStart(2,'0')}m` : `${m}m`;
}
export function fmtClock(ms: number): string {              // → vm.doneText, 12-hour local
  const d = new Date(ms); let h = d.getHours(); const m = d.getMinutes();
  const ap = h >= 12 ? 'PM' : 'AM'; h = h % 12 || 12;
  return `${h}:${String(m).padStart(2,'0')} ${ap}`;
}
// doneText = status.remaining_time ? fmtClock(nowMs + remaining_time*60000) : '—'
```

**Temperature grid** — `<TempGrid vm={vm} heatingEnabled />`

Card list construction:
```ts
const dual = vm.nozzles.length > 1;
const cards = dual
  ? vm.nozzles.map((n, i) => ({ label: i === 0 ? 'Left nozzle' : 'Right nozzle',
      now: n.now, target: n.target, heating: heatingEnabled && n.heating, active: n.active }))
  : [{ label: 'Nozzle', now: vm.nozzleNow, target: vm.nozzleTarget,
       heating: heatingEnabled && vm.nozzleHeating }];
cards.push({ label: 'Bed', now: vm.bedNow, target: vm.bedTarget, heating: heatingEnabled && vm.bedHeating });
if (vm.hasChamber) cards.push({ label: 'Chamber', now: vm.chamberNow, target: vm.chamberTarget,
                                heating: heatingEnabled && vm.chamberHeating });
// chunk into rows of 2
```
Row: `{ marginHorizontal:20, marginTop: rowIndex === 0 ? 14 : 12, flexDirection:'row', gap:12 }`. A trailing odd card is balanced by an empty `<View style={{flex:1}}/>` so it stays half-width — it does **not** stretch.

`TempCard`:
```
{ flex:1, padding:14, borderRadius:18, backgroundColor:c.s1,
  borderWidth:1, borderColor: active ? c.accent : c.line }
  header row (space-between):
    Text  weight 600, size 12, color c.t2            → label
    heating ? PulseDot(color=barColor, size=7, period=1400)
            : View 7×7 borderRadius 4 backgroundColor barColor opacity 0.9
  row { marginTop:9, alignItems:'baseline', gap:6 }
    row { alignItems:'flex-end' }
      RollingNumber(now, 26, '700', c.t1, letterSpacing -0.5)
      Text '°'  weight 700, size 13, color c.t3
    Text `→ ${target}°`  weight 500, size 12, color c.t3, mono   (arrow is U+2192)
  HeatBar pct, barColor, heating, height 3, style { marginTop:11 }
```
`barColor = heating ? c.heating : c.running`.
Fill percentage — note the **4 % floor**, so a cold/unset card still shows a sliver:
```ts
const pct = target > 0 ? Math.max(4, Math.min(100, (now / target) * 100)) : 4;
```
The static dot's `borderRadius` is **4** for a 7pt box (slightly over-rounded — harmless, but that is what ships). `active: true` (accent border) only ever appears on dual-nozzle machines.

**Controls row 1** — `{ marginHorizontal:20, marginTop:18, flexDirection:'row', gap:12 }`
- Pause/Resume: `flex:2, height:58, borderRadius:17, backgroundColor:c.s3, row, center, gap:9`, plus `...lock.style(vm.isPaused ? 'resume' : 'pause')` (= `{opacity: 0.4}` when locked, else null).
  Icon: `lock.blocked(action) ? 'lock' : vm.isPaused ? 'play' : 'pause'`, size 17, `c.t1`. Label `weight 600, size 16, c.t1` = `'Resume' | 'Pause'`.
  Endpoint: `POST /api/v1/printers/{id}/print/pause` or `/print/resume`.
- Stop: `flex:1, height:58, borderRadius:17, backgroundColor:c.errorDim, row, center, gap:8`. Feather **`square`** size 15 `c.error`; label `weight 600, size 16, c.error` = `Stop`. **Never dimmed, never lock-gated** — see §9. Confirms first: `Alert('Stop print?', "This cancels the current job. It can't be undone.", [Keep printing | Stop(destructive)])`, then `POST /api/v1/printers/{id}/print/stop`.

**Controls row 2** — `{ marginHorizontal:20, marginTop:12, flexDirection:'row', gap:12 }`
- Light: `flex:1, height:54, borderRadius:16, backgroundColor: vm.lightOn ? c.accentDim : c.s3, row, center, gap:9`
  - `<Breathe active={vm.lightOn} color={c.accent} grow={0.8} maxOpacity={0.5}>` wrapping Feather **`sun`** size 17, color `vm.lightOn ? c.accent : c.t1`.
  - `Text 'Light'` — `weight 600, size 14`, same conditional color.
  - `Text` `'ON' | 'OFF'` — `weight 600, size 12`, same color, `opacity 0.7`, `mono`.
  - Endpoint `POST /api/v1/printers/{id}/chamber-light?on={bool}`. **Not lock-gated** (it is `system/ledctrl`, not a `print.*` command).
- Speed container: `{ flex:1, zIndex: speedOpen ? 30 : 0 }` — the zIndex bump is what lets the popover escape above the AMS strip.

**Speed button + popover**
```
button: { width:'100%', height:54, borderRadius:16,
          backgroundColor: speedOpen ? c.s4 : c.s3,
          row, center, gap:9, ...lock.style('speed') }
  Feather  lock.blocked('speed') ? 'lock' : 'zap'   size 17  c.t1
  Text     weight 600, size 14, c.t1  → SPEEDS.find(s => s.i === speedIdx)?.name ?? vm.speedLabel
  Feather  'chevrons-up'  size 13  c.t3
onPress = lock.press('speed', () => setSpeedOpen(o => !o))
```
Popover, `FadeRise dy={6} duration={170}` with `{ position:'absolute', left:-6, right:-6, bottom:62, zIndex:30 }` — it **opens upward**, 6pt wider than the button on each side, 62pt above the container bottom (8pt above a 54pt button).
```
card: { backgroundColor:c.s1, borderWidth:1, borderColor:c.line2, borderRadius:16, padding:5,
        ...shadow1, shadowOpacity:0.55, shadowRadius:24, shadowOffset:{width:0,height:12} }
```
(shadow1 is spread then three of its four fields overridden — the popover has a much heavier drop shadow than any card.)
- Header `Text 'SPEED'`: `paddingHorizontal:10, paddingTop:7, paddingBottom:6, weight 600, size 9, letterSpacing 1, c.t3, mono`.
- Four rows from the module constant:
```ts
const SPEEDS: { i:number; name:string; hint:string; dot: keyof Palette }[] = [
  { i:1, name:'Silent',    hint:'50%',  dot:'paused'  },
  { i:2, name:'Standard',  hint:'100%', dot:'running' },
  { i:3, name:'Sport',     hint:'124%', dot:'heating' },
  { i:4, name:'Ludicrous', hint:'166%', dot:'error'   },
];
```
```
row Tap: { row, alignItems:'center', gap:10, paddingHorizontal:11, paddingVertical:11,
           borderRadius:11, backgroundColor: selected ? c.s3 : 'transparent' }
  View 8×8 borderRadius 4 backgroundColor c[s.dot]
  Text flex:1  weight 600, size 14, c.t1   → s.name
  Text         weight 500, size 11, c.t3, mono → s.hint
  if selected: Feather 'check' size 15 c.accent
onPress: h.onSpeedSet(s.i); setSpeedOpen(false);
```
Endpoint `POST /api/v1/printers/{id}/print-speed?mode={1..4}`.
**Optimistic override state machine** (Shell): tapping sets `speedOverride = i` immediately; `speedIdx = speedOverride ?? vm.speedIdx`; the override clears when `vm.speedIdx === speedOverride` (server caught up), on a **15 000 ms** timeout, or on request failure (rolled back + `Alert('Speed failed', …)`).
**Gotcha B:** if `lanMode` flips to `off` while the popover is open, the effect force-closes it — an open list of enabled-looking rows over a blocked control is the bug that effect exists to prevent.

**AMS strip** — `{ marginHorizontal:20, marginTop:20, marginBottom:8 }`
- Header row (space-between, `marginBottom:11`): `Text 'AMS'` — `weight 600, size 11, letterSpacing 1.2, c.t3, mono`; and a `Tap` → `h.onTab('ams')` `{ row, alignItems:'center', gap:3 }` with `Text 'Details'` (`weight 600, size 13, c.accent`) + Feather `chevron-right` 13 `c.accent`.
- Horizontal `ScrollView`, `showsHorizontalScrollIndicator={false}`, **`scrollEnabled={vm.ams.length > 4}`**, `contentContainerStyle={{ flexDirection:'row', gap:10, flexGrow:1 }}`.
- Chip, `key={`${t.unitId}:${t.localId}`}`:
```
{ flex:      vm.ams.length > 4 ? undefined : 1,
  minWidth:  vm.ams.length > 4 ? 74 : undefined,
  paddingVertical:11, paddingHorizontal:8, borderRadius:15,
  backgroundColor:c.s1, alignItems:'center', gap:8,
  borderWidth: t.active ? 1.5 : 1,
  borderColor: t.active ? c.accent : c.line }
  <Swatch value={t.color} size={32} radius={9} empty={t.empty} />
  Text numberOfLines={1}  weight 600, size 9.5, c.t2   → t.label
  Text  weight 600, size 11, c.t1, mono, fontVariant ['tabular-nums'] → t.pct
  t.active ? <PulseDot color={c.accent} size={5} period={2000}/>
           : <View 5×5 borderRadius 3 backgroundColor c.accent opacity 0 />
```
> **Two documented gotchas here.** (1) The `≤4 ⇒ flex:1 / >4 ⇒ minWidth:74 + scroll` split exists because a fixed flex row sized for 4 collapses to slivers at 5 slots (AMS 2 Pro + HT) and is unreadable at 9. (2) The `opacity: 0` dot is a **layout spacer**, not dead code — without it inactive chips are 5pt+gap shorter than active ones.

Slot data (`presentAms`, `src/ams/units.ts`): `label = tray_type` or `'Empty'`; `color = empty ? null : normColor(tray_color)`; `pct = empty ? '—' : `${Math.round(remain)}%``; `active = !empty && tray_now === globalId` (global id, **not** the local index).

#### 6b. IDLE (`vm.kind === 'idle'`)
`FadeRise` →
```
{ marginHorizontal:20, marginTop:18, padding:22, borderRadius:22,
  backgroundColor:c.s1, borderWidth:1, borderColor:c.line, alignItems:'center', ...shadow1 }
  Text weight 600, size 14, lineHeight 20, c.t2, textAlign:'center', maxWidth 250
       → "No active job. The bed is clear and filament is loaded."
  Tap  { marginTop:16, width:'100%', height:52, borderRadius:15,
         backgroundColor:c.accent, row, center, gap:8 }  → h.onTab('library')
    Feather 'plus' size 18 c.accentInk
    Text 'New print'  weight 600, size 16, c.accentInk
```
Then `<TempGrid vm={vm} heatingEnabled={false} />` — heating is forced off so an idle machine never shimmers.

#### 6c. LAN banner (`lanMode === 'off'`)
```
Tap { marginHorizontal:20, marginTop:14, padding:15, borderRadius:16,
      backgroundColor:c.heatingDim, borderWidth:1, borderColor:c.heating,
      row, alignItems:'center', gap:12 }
  Feather 'lock' size 16 c.heating
  column flex:1
    Text weight 700, size 14, c.t1                                   → LAN_BANNER_TITLE
    Text marginTop 3, weight 500, size 11.5, lineHeight 16, c.t3     → LAN_BANNER_BODY
  Feather 'chevron-right' size 18 c.t3
onPress → Alert.alert(LAN_HELP_TITLE, LAN_HELP_BODY)
```
Exact strings (`src/capabilities/lanMode.ts`):
```ts
LAN_BANNER_TITLE = 'Printer controls are locked';
LAN_BANNER_BODY  = "This printer won't accept commands until LAN Developer Mode is on. "
                 + "Monitoring, the camera and your library still work.";
LAN_HELP_TITLE   = 'Turn on LAN Developer Mode';
LAN_HELP_BODY    = [
 'Your printer reports status, streams the camera and accepts files, but rejects every command this app sends — pause, resume, speed, AMS, drying and starting a print. Its firmware requires signed commands unless Developer Mode is on.',
 '', 'On the printer:',
 '1. Settings → Network → LAN Only Mode.',
 '2. Turn on Developer Mode and confirm.',
 '3. The printer shows a NEW access code.',
 '',
 'Then update the access code in Bambuddy, and this app will be able to control the printer again.',
].join('\n');
LAN_BLOCKED_HINT = 'Turn on LAN Developer Mode on the printer (Settings → Network), then re-enter its new access code in this app.';
```

#### 6d. COMPLETE (`vm.kind === 'complete'`)
Outer `{ marginHorizontal:20, marginTop:18 }`, containing `<Confetti count={22}/>` (absolute-filling, `pointerEvents:'none'`, `overflow:'hidden'` — it is clipped to this container) and then a `FadeRise` card:
```
{ padding:22, borderRadius:22, backgroundColor:c.s1, borderWidth:1, borderColor:c.line, ...shadow1 }
  row { alignItems:'center', gap:13 }
    <Pop>  48×48, borderRadius 24, backgroundColor c.runningDim, centered
             Feather 'check' size 24 c.running
    column
      Text 'Fresh off the bed'  weight 700, size 20, c.t1, letterSpacing -0.3
      Text marginTop 5, weight 500, size 12, c.t3, mono  → vm.heroSub || 'finished'
  if cooldown.phase !== 'none': <CooldownPanel vm={cooldown}/>
  if vm.awaitingPlateClear:
    Tap { marginTop:18, height:52, borderRadius:15, backgroundColor:c.accent, row, center, gap:8 }
      Feather 'check-square' size 16 c.accentInk
      Text 'Plate cleared — continue queue'  weight 600, size 16, c.accentInk
  Tap "Print again"
    { marginTop: vm.awaitingPlateClear ? 10 : 18, height:52, borderRadius:15,
      backgroundColor: vm.awaitingPlateClear ? c.s3 : c.accent, row, center, gap:8,
      ...lock.style('printAgain') }
    if lock.blocked('printAgain'): Feather 'lock' size 15, color awaitingPlateClear ? c.t1 : c.accentInk
    Text 'Print again'  weight 600, size 16, color awaitingPlateClear ? c.t1 : c.accentInk
```
The two buttons **swap primacy**: when a plate clear is pending, "Plate cleared" is the accent CTA and "Print again" demotes to `c.s3`.
- Plate clear → `POST /api/v1/printers/{id}/clear-plate` (**not** `queueResume`; sends no MQTT, so it works with Developer Mode off). Success → `Alert('Plate confirmed clear', 'The next queued job can start.')`.
- Print again → if `status.current_archive_id == null`, just `setTab('library')`; otherwise confirm `Alert('Print this again?', 'The finished job goes back into the queue.')` then `POST /api/v1/queue/` with `{ printer_id, archive_id, use_ams: true }` and `setTab('jobs')`. (`POST /archives/{id}/reprint` is **gone** — Bambuddy answers 410.)

**`Confetti`** — 22 pieces, each generated once at mount by `confettiPieces(count, Math.random, [c.accent, c.running, c.heating, c.paused, c.t1])`:
```ts
{ left: rand()*100,            // % across parent
  size: 6 + rand()*5,          // width; height = size*0.62; borderRadius 2
  color: palette[floor(rand()*palette.length)],
  dx: (rand()-0.5)*130,        // px horizontal drift
  rotate: (rand()-0.5)*560,    // total degrees
  delay: rand()*180,           // ms
  fall: 240 + rand()*130 }     // px
```
Per piece, one-shot over `1100 + fall` ms with `bezier(0.2,0.6,0.4,1)` after `delay`; `t: 0→1` drives
`translateX = dx*t`, `translateY = -14 + (fall+14)*t`, `rotate = rotate*t deg`,
`opacity = t < 0.12 ? t/0.12 : 1 - (t-0.12)/0.88`.

**`CooldownPanel`** (fed by `presentCooldown`, `src/cooling/present.ts`):
```ts
const tint = vm.tone === 'ready' ? c.running : vm.tone === 'hot' ? c.heating : c.accent; // 'warm' → accent
```
```
{ marginTop:16, padding:15, borderRadius:16, backgroundColor:c.s2,
  borderWidth:1, borderColor: vm.phase === 'ready' ? c.running : c.line }
  row { alignItems:'center', gap:8 }
    Feather  vm.phase === 'ready' ? 'check-circle' : 'thermometer'  size 13  color tint
    Text flex:1  weight 700, size 14, c.t1                → vm.label
    Text  weight 700, size 15, color tint, fontVariant ['tabular-nums'] → `${Math.round(vm.bedC)}°C`
  track { marginTop:11, height:5, borderRadius:3, backgroundColor:c.s3, overflow:'hidden' }
    fill  { width: `${Math.round(vm.progress*100)}%`, height:5, borderRadius:3, backgroundColor: tint }
  Text marginTop 10, weight 500, size 12, lineHeight 17, c.t3   → vm.detail
  if vm.caution:
    row { marginTop:9, gap:7 }
      Feather 'alert-triangle' size 12 c.heating, style {marginTop:2}
      Text flex:1  weight 500, size 11, lineHeight 16, c.heating → vm.caution
```
Phase → label/tone/detail (all copy verbatim from `presentCooldown`; threshold default **35 °C**, clamped to 30–45):

| phase | label | tone | detail |
|---|---|---|---|
| `ready` (`bedC ≤ threshold`) | `Plate is cool` | `ready` | `Bed at {N}°C — safe to flex the plate and lift the print off.` + optional ` The nozzle is still at {M}°C.` when nozzle > 50 |
| `stalled` (plateaued, or measured ambient ≥ threshold) | `As cool as it will get` | `warm` | `Bed has settled at {N}°C and is no longer dropping.` + optional ` The room is around {A}°C.` + ` Go ahead and flex the plate.` + nozzle note |
| `cooling` | `Plate cooling` | `hot` if `bedC > threshold+15` else `warm` | with ETA: `Bed at {N}°C — {fmtMin} until it is easy to remove.`; without: `Bed at {N}°C, heading for {threshold}°C.` |
| `none` | — | — | panel not rendered |

`progress = peak > threshold ? clamp01((peak - bedC)/(peak - threshold)) : 1`, where `peak = max(bedC, ...samples)`.
`fmtMin`: round to nearest minute; if ≥10, snap to the nearest 5; `≤1 → 'under a minute'`; `<60 → 'about {r} min'`; else `'about {h} h {rem} min'` / `'about {h} h'`.
> Deliberate: never claims the print has released, only "safe to flex" — over-promising invites forcing it and tearing the PEI coating.

#### 6e. ERROR (`vm.kind === 'error'`)
```
FadeRise →
{ marginHorizontal:20, marginTop:18, padding:20, borderRadius:22,
  backgroundColor:c.s1, borderWidth:1, borderColor:c.line, ...shadow1 }
  row { alignItems:'center', gap:12 }
    View 42×42, borderRadius 12, backgroundColor c.errorDim, centered
      Feather 'alert-triangle' size 22 c.error
    column flex:1
      Text 'Printer reported an error'  weight 700, size 17, lineHeight 20, c.t1
      Text marginTop 4, weight 500, size 11, c.t3, mono
           → vm.hmsCode ? `HMS ${vm.hmsCode}` : (vm.heroSub || 'Print error')
buttons row { marginHorizontal:20, marginTop:14, gap:12 }
  Resume: flex 2, height 54, borderRadius 16, backgroundColor c.accent, row, center, gap 8,
          ...lock.style('resume');  if blocked: Feather 'lock' 15 c.accentInk
          Text 'Resume print'  weight 600, size 16, c.accentInk
  Stop:   flex 1, height 54, borderRadius 16, backgroundColor c.errorDim, centered (NO icon)
          Text 'Stop'  weight 600, size 16, c.error
```
HMS code formatting: `"0500050000010007" → "0500-0500-0001-0007"` —
```ts
export function fmtHmsCode(full?: string | null) {
  if (!full) return null;
  const s = String(full);
  return s.length === 16 ? s.replace(/(.{4})(?=.)/g, '$1-') : s;
}
```
> The error *screen* is only entered on `print_error` or an explicit `FAILED`/`ERROR` state. An `hms_errors` entry alone is **not** an error (the H2C emits benign notices mid-print) — those surface only through the alert chip.

#### 6f. OFFLINE (`vm.kind === 'offline'`)
```
FadeRise →
{ marginHorizontal:24, marginTop:48, alignItems:'center', gap:16 }     // 24, not 20
  View 72×72, borderRadius 22, backgroundColor c.s2, centered
    Feather 'wifi-off' size 32 c.t3
  column { alignItems:'center' }
    Text `Can't reach ${printerName}`  weight 700, size 20, c.t1, letterSpacing -0.3
    Text marginTop 8, weight 500, size 13, lineHeight 19, c.t3, textAlign 'center', maxWidth 260
         → "No response right now. Make sure it's powered on and on your network."
  Tap { marginTop:4, paddingHorizontal:26, height:48, borderRadius:14,
        backgroundColor:c.accent, centered }  → h.onRetry()
    Text 'Retry connection'  weight 600, size 15, c.accentInk
```

#### 6g. CONNECTING (`vm.kind === 'connecting'`)
```
{ paddingHorizontal:20, paddingTop:16 }
  Skeleton { width:'100%', aspectRatio: 16/10, borderRadius:18 }            // camera placeholder
  card { marginTop:16, padding:20, borderRadius:22, backgroundColor:c.s1,
         borderWidth:1, borderColor:c.line, row, alignItems:'center', gap:18 }   // NO shadow1 here
    Skeleton { width:110, height:110, borderRadius:55 }
    column { flex:1, gap:12 }
      Skeleton { height:13, width:'55%', borderRadius:5 }
      Skeleton { height:22, width:'85%', borderRadius:6 }
      Skeleton { height:13, width:'42%', borderRadius:5 }
  Text marginTop 20, textAlign 'center', weight 500, size 12, c.t3 → `Reaching ${printerName}…`
```
`Skeleton` = base `backgroundColor: c.s2`, `overflow:'hidden'`, with a 150pt-wide bar of `rgba(255,255,255,0.06)` translating from `-160` to the measured width over 1400 ms, `Easing.inOut(Easing.ease)`, infinite. (The highlight is the same rgba in both themes — in light mode it is nearly invisible, which is the current behaviour.)

---

### 7. `Swatch` — the filament colour chip

```
{ width: size, height: size, borderRadius: radius,
  backgroundColor: known ? value : 'transparent',
  borderWidth: 1, borderColor: c.swatchRing,
  borderStyle: known ? 'solid' : 'dashed',
  alignItems:'center', justifyContent:'center', ...style }
child = known ? ink
      : (!empty && size >= 16) ? <Feather name="help-circle" size={Math.round(size*0.5)} color={c.t3}/>
      : null
```
`known = !empty && !!value`. Three deliberate states, **not** two:
- **empty** — no spool: transparent fill, dashed ring, no glyph.
- **unknown** — spool present, colour unknown (`value == null`): dashed ring **+ `help-circle` glyph at half size**, never black. Glyph suppressed below 16pt.
- **colour** — the fill, solid ring, optional `ink` overlay child.

> **The hard-won bug this encodes:** every call site used to paint the raw hex into `backgroundColor` and drop the border when a colour was present, so a white spool on a white card was a hole in the layout, and a black spool on a dark card was the same bug in the other theme. `c.line2` is only ~1.4:1 against its own surface, so even sites that kept a hairline still disappeared. `swatchRing` is a **fixed per-theme colour chosen for ≥3:1 contrast against every surface** (`bg/s1/s2/s3/s4/sheet`; worst case 4.18:1 dark, 3.65:1 light) — it is *not* computed from the fill, so the guarantee holds for colours nobody has tested. Do not "improve" this into a computed contrast colour.

Colour normalisation upstream (`normColor`, `src/dashboard/present.ts`) — Bambu sends RGBA hex like `"565656FF"`:
```ts
export function normColor(hex?: string | null): string | null {
  if (!hex) return null;
  const h = hex.replace('#','').trim();
  if (!/^[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$/.test(h)) return null;
  if (h.length === 8 && h.slice(6) === '00') return null;   // alpha exactly "00" is Bambu's UNSET sentinel
  return '#' + h.slice(0,6).toUpperCase();
}
```
Alpha `"00"` is a sentinel, not a colour — `"00000000"` used to render as black filament. Any other alpha (e.g. `"C9A38180"`) is a real colour and keeps its RGB. Non-hex returns `null` rather than a malformed string.

Companion helper for glyphs drawn on a swatch:
```ts
export function inkOn(hex?: string | null): string {
  return hex && relLuminance(hex) > 0.179 ? '#0D1012' : '#FFFFFF';
}
```
`0.179` is the exact luminance where black and white ink tie: solve `(L+0.05)/0.05 = 1.05/(L+0.05)`.

---

### 8. `TabBar`

**Five tabs, not six.** The root `CLAUDE.md` still says "TabBar (6 tabs)" — that is stale; queue and history were merged into a single `jobs` timeline (see the inline comment on the `jobs` entry). The live definition:

```ts
export type TabKey = 'printer' | 'library' | 'jobs' | 'ams' | 'power';
const TABS: [TabKey, string, keyof typeof Feather.glyphMap][] = [
  ['printer', 'Printer',  'cpu'],     // rendered with NozzleIcon instead — 'cpu' is never drawn
  ['library', 'Files',    'folder'],
  ['jobs',    'Jobs',     'list'],    // queue + history merged into one print timeline
  ['ams',     'Hardware', 'box'],
  ['power',   'Power',    'power'],
];
```
Container:
```
{ position:'absolute', left:0, right:0, bottom:0,
  paddingTop:9, paddingBottom: safeAreaBottom || 12,
  backgroundColor: c.s1,          // opaque s1 — NOT the translucent c.tabbar token
  borderTopWidth:1, borderTopColor:c.line,
  flexDirection:'row' }
```
Each item is a `Tap` with `scale={0.9}` (a deeper press-squash than the 0.955 default):
```
{ flex:1, alignItems:'center', gap:4, paddingVertical:5, paddingHorizontal:2 }
  key === 'printer' ? <NozzleIcon color={on ? c.accent : c.t3} size={22}/>
                    : <Feather name={icon} size={21} color={on ? c.accent : c.t3}/>
  Text numberOfLines={1}  weight 600, size 10, color: on ? c.accent : c.t3
```
Note the icon-size asymmetry: the nozzle glyph is **22**, the Feather icons are **21**. No badges, no indicator pill, no blur.

---

### 9. `useLockedAction` / LAN gating — the state machine

```ts
export type LanMode = 'on' | 'off' | 'unknown';
export function lanModeFrom(status) {
  const v = status?.developer_mode;
  if (v === true)  return 'on';
  if (v === false) return 'off';
  return 'unknown';                 // TRI-STATE ON PURPOSE
}
```
> **`'unknown'` is not `'off'`.** The field is absent until the printer has reported, and a gate that treats absence as "off" greys out the whole UI on every cold start. Only an explicit `false` disables anything.

Blocked set (all `print.*` MQTT commands on the one verified topic):
```ts
const BLOCKED = new Set<ActionId>(['pause','resume','speed','amsLoad','amsUnload',
                                   'dryStart','dryStop','startPrint','printAgain']);
export const isBlocked = (a, mode) => mode === 'off' && BLOCKED.has(a);
export const LOCKED_OPACITY = 0.4;
export const lockedStyle = (locked) => locked ? { opacity: LOCKED_OPACITY } : null;
```
**Deliberately NOT blocked**, each for a stated reason: `stop` (the emergency control — a dead grey Stop on a print that is spaghettifying is actively dangerous; a Stop that *might* fail beats one that cannot be pressed), `light` (publishes `system/ledctrl`, which the firmware doesn't verify the same way), `camera` (RTSPS on its own port, verified with Dev Mode off), `plug` (a different device, and the real kill switch), `plateCleared`/`queueRemove`/`maintenance` (Bambuddy-side bookkeeping; the printer is never asked).

The hook pairs look and behaviour so a button can never look enabled while its handler is blocked:
```ts
{ blocked: a => isBlocked(a, lanMode),
  style:   a => lockedStyle(isBlocked(a, lanMode)),
  press:   (a, run) => () => {
    if (isBlocked(a, lanMode)) { Alert.alert(LAN_BANNER_TITLE, LAN_BLOCKED_HINT); return; }
    run();
  } }
```
Locked treatment = **dim to 0.4 + swap the leading glyph to Feather `lock`**, never hide. Tapping a locked control explains itself in an alert.

> **Why this exists:** Bambuddy reaches the printer over LAN MQTT only. With Developer Mode off the firmware rejects every message with "mqtt message verify failed" *while status reports keep flowing*, and Bambuddy returns success the moment `publish()` returns — so the API answers 200 and the UI renders a pause that never happened. Reproduce this gate or the native app will lie the same way.

---

### 10. `AlertsOverlay`

Full-screen opaque sheet, **not** a modal card:
```
{ position:'absolute', inset:0, backgroundColor: c.bg, zIndex: 86 }
```
(zIndex ladder in the Shell: camera overlay 70, alerts 86.)

Header — `{ paddingTop: safeAreaTop + 12, paddingHorizontal:20, paddingBottom:12, row, alignItems:'center', gap:12 }`
- `Text 'Attention'` — `flex:1, weight 700, size 26, c.t1, letterSpacing -0.6`
- Close `Tap` — `hitSlop 12`, `{ width:38, height:38, borderRadius:19, backgroundColor:c.s2, centered }`, Feather **`x`** size 20 `c.t2`

Body `ScrollView`, `showsVerticalScrollIndicator={false}`, `contentContainerStyle={{ paddingHorizontal:20, paddingBottom: safeAreaBottom + 28, gap:12 }}`.

Empty state (`alerts.length === 0`): `{ alignItems:'center', paddingTop:60, gap:12 }`, Feather `check-circle` size **34** `c.running`, `Text 'Nothing needs attention'` `weight 600, size 15, c.t2`.

Tone helpers:
```ts
toneOf = l => l === 'error' ? c.error    : l === 'warning' ? c.heating    : c.accent;
dimOf  = l => l === 'error' ? c.errorDim : l === 'warning' ? c.heatingDim : c.accentDim;
```
Card (each wrapped in `FadeRise key={a.id}`):
```
{ padding:16, borderRadius:18, backgroundColor: dimOf(level),
  borderWidth:1, borderColor: tone, ...shadow1 }
  row { alignItems:'flex-start', gap:12 }
    Feather  level === 'info' ? 'info' : 'alert-circle'   size 18  color tone
    column flex:1
      Text weight 700, size 15, c.t1                                  → a.title
      Text marginTop 4, weight 500, size 12.5, c.t2, lineHeight 18    → a.detail
      if a.code: Text marginTop 6, weight 600, size 11, c.t3, mono    → `HMS ${a.code}`
  if a.actions.length:
    row { flexDirection:'row', flexWrap:'wrap', gap:8, marginTop:14 }
      button { paddingHorizontal:15, height:40, borderRadius:12, centered,
               backgroundColor: act.destructive ? c.s3 : act.id === 'lookup' ? c.s2 : tone,
               borderWidth:  act.id === 'lookup' ? 1 : 0,
               borderColor:  c.line2 }
        Text weight 700, size 13,
             color: act.destructive ? c.error : act.id === 'lookup' ? c.t1 : c.accentInk
```
Note the button styling precedence: `destructive` is tested **first**, then `lookup`, then default (filled with the card's tone). A default-filled action on a warning card is amber-filled with `accentInk` text (`#04201D` in dark) — that is intentional, not a bug.

**Alert generation** (`presentAlerts`) — guiding rule: *never offer an action the printer/permissions can't currently take.* `canAct = caps.connected && caps.canControl`; when false, every alert renders with an **empty action row**. Order:
1. `print-error` (level `error`, title `Print error`) — when `print_error` or state `FAILED`/`ERROR`. Actions when `canAct`: `Resume`, `Stop print` (destructive).
2. `paused` (level `warning`, `Print paused`, detail `Resume once the problem is fixed, or stop the job entirely.`) — actions `Resume print`, `Stop print` (destructive).
3. `plate` (level `info`, `Waiting for the plate`, detail `The finished print has to come off the bed before the next job can start.`) — action `Plate is clear`.
4. One row per `hms_errors[i]`, id `hms-{dashedCode}`. Severity ladder `1 Fatal→error, 2 Serious→error, 3 Common→warning, 4 Info→info`; anything outside → title `Printer notice`, level `warning`. Actions: `What is this?` (`lookup`, always when a code exists) and — **only on `i === 0`** — `Dismiss` or `Dismiss all (N)`.

Action → endpoint (Shell `runAlertAction`): `resume` → `POST /printers/{id}/print/resume`; `stop` → `/print/stop`; `clearHms` → `/printers/{id}/hms/clear`; `plateCleared` → `/printers/{id}/clear-plate`. Destructive actions confirm first with `Alert(`${act.label}?`, `${a.title} — this can't be undone.`)`.

**`lookup` is a probe loop, not a single link** — the Bambu wiki path is per model *family* and each family has its own code namespace (verified: `0C00_0100_0002_0017` is 200 under `/h2/` and 404 under `/x1/`; `0300_0D00_0001_0003` is the exact reverse), and the path uses **underscores**, not the dashes the code is displayed with:
```ts
const FAMILIES = ['h2','x1','p1','a1'];
wikiFamily(model): 'H2*'→h2, 'X1*'→x1, 'P1*'→p1, 'A1*'→a1, else 'x1'
urls = [...ordered.map(f => `https://wiki.bambulab.com/en/${f}/troubleshooting/hmscode/${code_with_underscores}`),
        'https://wiki.bambulab.com/en/hms/error-code'];   // last entry always resolves
// open(): HEAD each candidate except the last; first r.ok wins; any throw breaks out to the index.
```
Without the probe a tap landed on a 404 — the reported "fatal is not found" bug.

---

### 11. `NozzleIcon`

A monochrome SVG of the app-icon mark, tinted by a single `color` prop. Same proportions as the Live Activity glyph (`src/liveactivity/nozzle-glyph.svg`).
```jsx
<Svg width={size} height={size} viewBox="48 30 96 142" fill="none">
  <Rect    x="60" y="36"  width="72" height="50" rx="12"  fill={color}/>
  <Rect    x="60" y="80"  width="72" height="9"  rx="4.5" fill={color}/>
  <Polygon points="74,92 118,92 106,128 96,150 86,128"    fill={color}/>
  <Circle  cx="96" cy="120" r="11"                        fill={color}/>
  <Rect    x="58" y="150" width="76" height="15" rx="7.5" fill={color}/>
</Svg>
```
Default `size = 24`; TabBar passes 22. The viewBox is **not** square (96×142) and `width === height` — the glyph is therefore rendered with a non-uniform aspect fit by react-native-svg's default `preserveAspectRatio="xMidYMid meet"`, i.e. letterboxed to fit the 22×22 box. A related but distinct 4-shape variant (with `viewBox="48 30 96 128"`, `cy=117`, hard-coded `#C2C7CC`/`#878D94` greys) rides the leading edge of `ExtrudeBar` in the anim kit — do not confuse the two.

---

### 12. Animation kit reference (`src/components/anim/index.tsx`)

Easing curves:
```ts
const SPRING    = Easing.bezier(0.34, 1.56, 0.64, 1);  // the design's signature overshoot
const ROLL_EASE = Easing.bezier(0.3,  1.1,  0.5,  1);
const RISE_EASE = Easing.bezier(0.22, 1,    0.36, 1);
```

| component | behaviour |
|---|---|
| `Tap` | press-in: scale→`scale` (default 0.955) + opacity→`dim` (0.62) over 90 ms `Easing.out(quad)`; press-out: back over 170 ms with SPRING. TabBar overrides `scale={0.9}`. |
| `RollingNumber` | `splitDigits(value)` → only `0-9` become rolling columns; every other char is static text. Column height `h = round(fontSize * 1.08)`, clipped, containing a stacked 0–9 strip translated to `-d*h` over **600 ms** `ROLL_EASE`. All digit text uses `fontVariant:['tabular-nums'], textAlign:'center'`. |
| `PulseDot` | opacity `1 → 0.22 → 1`, each leg `period/2`, `Easing.inOut(quad)`, infinite. `glow` (default on) adds `shadowColor: color, shadowOpacity 0.85, shadowRadius: size*0.7, offset 0`. |
| `ProgressRing` | see §6a. |
| `HeatBar` | width→`clamp01(pct/100)` over 600 ms `Easing.out(quad)`; while `heating`, fill opacity loops `1→0.5→1` at 700 ms per leg; on stop, returns to 1 over 250 ms. Track `c.s3`, both track and fill `borderRadius: height/2`. |
| `Skeleton` | see §6g. |
| `Confetti` | see §6d. |
| `FadeRise` | opacity `0→1` + `translateY (1-t)*dy` over `duration` after `delay`, `RISE_EASE`. Defaults `dy 11, duration 340`. |
| `Pop` | opacity 0→1 over 200 ms `out(quad)`; scale `0.4 → 1.12` (320 ms `out(cubic)`) `→ 1` (220 ms SPRING). |
| `Breathe` | a **sibling halo view** (`position:absolute`, fills parent, `borderRadius:999`, `backgroundColor: color`) animating `opacity 0→maxOpacity` and `scale 1→1+grow` on 1200 ms legs. **Gotcha:** this was originally an iOS shadow on a transparent wrapper, which doesn't render — it was invisible. Keep it as a real view. |

**Every animated component calls `cancelAnimation(sv)` in its cleanup.** The comment on `Tap` says why: flushing updates for a view being torn down is the reanimated-4 New-Arch crash/freeze race (`swmansion/react-native-reanimated#9402`). The same bug is why the Shell keeps `DashboardView` **mounted and `display:'none'`** on tab switch instead of unmounting it, and why the camera overlay stays mounted during PiP.

---

### 13. Endpoints touched from this screen

| action | request |
|---|---|
| status (live) | WebSocket, token from `POST /api/v1/auth/ws-token`; REST fallback `GET /api/v1/printers/{id}/status` |
| camera token | `POST /api/v1/printers/camera/stream-token` → `{ token }` |
| snapshot tile | `GET /api/v1/printers/{id}/camera/snapshot?token={camToken}&_t={tick}` |
| fullscreen stream | `GET /api/v1/printers/{id}/camera/stream?token={camToken}&fps=10` (MJPEG multipart) |
| pause / resume / stop | `POST /api/v1/printers/{id}/print/{pause\|resume\|stop}` |
| speed | `POST /api/v1/printers/{id}/print-speed?mode={1..4}` |
| chamber light | `POST /api/v1/printers/{id}/chamber-light?on={true\|false}` |
| clear HMS | `POST /api/v1/printers/{id}/hms/clear` |
| plate cleared | `POST /api/v1/printers/{id}/clear-plate` |
| print again | `POST /api/v1/queue/` `{ printer_id, archive_id, use_ams:true }` |
| maintenance chip | `GET /api/v1/maintenance/printers/{id}` (60 s poll) |

Auth is the `X-API-Key` header **except** snapshot/stream/thumbnails, which take the camera token in `?token=` and reject the header with 401. Base URL and key live in the Keychain; substitute placeholders for the real host.

---

### Port notes

**Straightforward mappings**

| RN piece | SwiftUI equivalent |
|---|---|
| `ScrollView` + `contentContainerStyle` | `ScrollView { VStack(alignment: .leading, spacing: 0) { … } }` with explicit `.padding(.top, safeTop + 6)` / `.padding(.bottom, 120)`. RN's default `alignItems: 'stretch'` means every child is full-width — SwiftUI defaults to intrinsic width, so add `.frame(maxWidth: .infinity)` on cards or they will shrink-wrap. |
| flex row + `gap` | `HStack(spacing: g)` |
| `flex: 2` / `flex: 1` siblings | `.frame(maxWidth: .infinity)` on both plus `.layoutPriority`, or a `GeometryReader`; cleanest is a custom `HStack` where the 2:1 pair uses `.frame(maxWidth: .infinity)` with the wide one wrapped so widths land 2:1 — or just compute from container width. |
| `borderWidth:1, borderColor` | `.overlay(RoundedRectangle(cornerRadius: r, style: .continuous).strokeBorder(color, lineWidth: 1))` — use `strokeBorder` (inset), not `stroke`, to match RN's inside-border model. |
| `borderRadius` | `.clipShape(RoundedRectangle(cornerRadius: r, style: .continuous))`. RN corners are circular arcs, iOS `.continuous` is a squircle; `.continuous` reads closer to the design intent at these radii (14–22). |
| `shadow1` | `.shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 1)`. The speed popover's override is `radius: 24, y: 12, opacity: 0.55`. Note RN `shadowRadius` ≈ SwiftUI `radius` here (both are blur radius on iOS). |
| `fontWeight '500'/'600'/'700'` | `.medium` / `.semibold` / `.bold` |
| sizes like `9.5`, `11.5`, `12.5` | `.font(.system(size: 9.5, weight: .semibold))` — SwiftUI accepts fractional sizes; keep them. |
| `fontFamily: mono` (Menlo) | `.font(.custom("Menlo", size: n))`, or better `.font(.system(size: n, weight: w, design: .monospaced))`. Menlo is wider than SF Mono — if you switch to `.monospaced`, re-check the letterSpaced label rows (`AMS`, `SPEED`, `CHAMBER · SNAPSHOT`) for width. |
| `letterSpacing: n` | `.tracking(n)` |
| `fontVariant: ['tabular-nums']` | `.monospacedDigit()` |
| `lineHeight: n` | `.lineSpacing(n - fontSize)` approximately — SwiftUI has no direct line-height; for the 4 places it matters (idle copy 14/20, offline copy 13/19, alert detail 12.5/18, cooldown detail 12/17) use `.lineSpacing` deltas of 6, 6, 5.5, 5. |
| `numberOfLines={1}` | `.lineLimit(1)` |
| `maxWidth: 250 / 260` | `.frame(maxWidth: 250)` + `.multilineTextAlignment(.center)` |
| Feather icons | **No SF Symbol is a drop-in.** See "hard" below. |
| `expo-image` with `transition={120}` | `AsyncImage` won't cache-bust cleanly; use a small `URLSession` fetcher into an `@Observable` holder + `.animation(.easeInOut(duration: 0.12), value: image)`. |
| `Alert.alert(title, body)` | `.alert(title, isPresented:) { } message: { Text(body) }` |
| `useSafeAreaInsets()` | `GeometryReader { $0.safeAreaInsets }` or `@Environment(\.safeAreaInsets)` via a custom key; the TabBar and AlertsOverlay both need the raw inset values, not automatic insetting. |

**Component-by-component**

- **`Swatch`** → a `SwatchView(value: Color?, size: CGFloat, radius: CGFloat, empty: Bool, ink: AnyView?)`. Dashed ring: `.strokeBorder(Theme.swatchRing, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))`. RN's default dash pattern is platform-defined (roughly 3-on/3-off at width 1) — pick `[3,3]` and eyeball against a screenshot. Keep the tri-state logic and the `size >= 16` glyph gate exactly.
- **`NozzleIcon`** → a `Shape`-based view or an SF-Symbol-free `Path` set. Easiest faithful port: keep it as SVG-derived `Path`s in a `Canvas`/`ZStack` scaled by `viewBox` → `size`, or ship it as an SVG-derived `Image` asset with `.renderingMode(.template).foregroundStyle(color)`. The template-image route is the least code and matches the "tints with `color`" contract. Preserve the non-square 96×142 viewBox letterboxing so it keeps the same optical weight next to the 21pt Feather glyphs.
- **`TabBar`** → **do not use `TabView`.** It is an absolutely-positioned overlay above a single scroll view, with an opaque `c.s1` fill and a 1px top hairline, and the dashboard must stay alive behind it. Build it as an `HStack` in a `.safeAreaInset(edge: .bottom)` or a `ZStack` overlay, driving a `@State var tab: TabKey`. Native `TabView` would give you material blur and its own safe-area handling, both of which are wrong here.
- **`RollingNumber`** → SwiftUI's `.contentTransition(.numericText())` on a `Text` gets ~90 % of the effect for free with `withAnimation(.easeOut(duration: 0.6))`. That is the right call for the temp/layer/progress readouts. Only build a manual clipped digit-strip if the odd-shaped values (`etaText` = `"2h 05m"`, which contains letters and spaces) look wrong — `.numericText()` handles mixed strings less predictably than `splitDigits` does. Recommend: `.numericText()` for pure integers (progress, temps, layer), a hand-rolled column stack for `etaText`.
- **`ProgressRing`** → `Circle().trim(from: 0, to: progress/100).stroke(color, style: StrokeStyle(lineWidth: 9, lineCap: .round)).rotationEffect(.degrees(-90))`, animated with `.animation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.7), value: progress)`. The glow is a blurred `Circle` sibling at `0.7 × size` with pulsing opacity, **not** `.shadow` — same reason as `Breathe`.
- **`PulseDot` / `HeatBar` shimmer / `Breathe`** → `.opacity(x).animation(.easeInOut(duration: p/2).repeatForever(autoreverses: true), value: flag)`. Note RN uses `repeat(sequence(up, down), -1, false)` — autoreverse **false** with an explicit down-leg, which is equivalent to `autoreverses: true` at these easings. Fine to use `autoreverses: true`.
- **`Confetti`** → `TimelineView(.animation)` + `Canvas`, or 22 `Rectangle`s with per-piece `@State`. Generate the piece array **once** (`@State private let pieces = confettiPieces(22, …)`) — the RN version memoizes on mount for exactly this reason.
- **`Skeleton`** → a `LinearGradient` mask sweeping via `.offset(x:)` inside `.clipped()`, or `.redacted(reason: .placeholder)` + `.shimmering()`. Note the RN highlight is a flat `rgba(255,255,255,0.06)` bar, not a gradient — a gradient will look *better* but different.
- **`FadeRise`** → `.transition(.opacity.combined(with: .offset(y: 11)))` with `.animation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.34))`, or `.onAppear` driving an `@State` progress. `FadeRise` fires on **mount**, so tie it to `.transition` on conditionally-rendered subtrees.
- **`Tap`** → a `ButtonStyle`:
  ```swift
  struct TapStyle: ButtonStyle {
    var scale: CGFloat = 0.955, dim: CGFloat = 0.62
    func makeBody(configuration: Configuration) -> some View {
      configuration.label
        .scaleEffect(configuration.isPressed ? scale : 1)
        .opacity(configuration.isPressed ? dim : 1)
        .animation(configuration.isPressed
                   ? .easeOut(duration: 0.09)
                   : .timingCurve(0.34, 1.56, 0.64, 1, duration: 0.17),
                   value: configuration.isPressed)
    }
  }
  ```
  Apply `TapStyle(scale: 0.9)` in the TabBar.
- **`AlertsOverlay`** → a full-screen `ZStack` layer with an explicit `zIndex(86)`, **not** `.sheet` — it has no grabber, no card inset, no scrim; it is an opaque `c.bg` screen with its own close button. `.fullScreenCover` is closer but adds a system push transition the current UI doesn't have.
- **View models** — `presentDashboard`, `presentAlerts`, `presentCooldown`, `alertSummary`, `presentAms`, `normColor`, `fmtDuration`, `fmtClock`, `fmtHmsCode`, `inkOn`, `colorName` are all pure functions over decoded JSON. Port them to plain Swift structs/functions **first** and unit-test them against the existing Jest cases — they are the most-tested modules in the app and carry the most hard-won correctness (the nozzle coordinate-system fix, the `"00"` alpha sentinel, the naive-UTC timestamp fix, the global-vs-local tray id).

**Things that will be HARD or need a different approach**

1. **Feather icon glyphs.** Sixteen distinct names are used across these files: `settings`, `chevron-up`, `chevron-down`, `check`, `tool`, `chevron-right`, `info`, `alert-circle`, `maximize-2`, `square`, `play`, `pause`, `lock`, `sun`, `zap`, `chevrons-up`, `plus`, `check-square`, `alert-triangle`, `wifi-off`, `thermometer`, `x`, `check-circle`, `help-circle`, `folder`, `list`, `box`, `power`, `cpu`. SF Symbols differ in stroke weight, optical size, and bounding box — a naive substitution changes the whole feel. Two options: (a) ship the Feather SVGs as an asset catalog of template images (exact fidelity, ~29 assets, ignores Dynamic Type); (b) map to SF Symbols and re-tune every size (`chevrons-up` → `chevron.up.chevron.up` doesn't exist; use `chevron.up.2`; `maximize-2` → `arrow.up.left.and.arrow.down.right`; `zap` → `bolt.fill`; `tool` → `wrench.and.screwdriver`; `square` → `stop.fill` reads better than `square`). Recommend (a) for the dashboard chrome and (b) for the TabBar, where SF Symbols' optical alignment is worth more.
2. **The live-mutating `c` palette.** There is no SwiftUI analogue and you don't want one. Replace with a `Theme` struct in `@Environment`, or — simplest — asset-catalog `Color`s with light/dark variants and let the system drive it. But note: the app has an **explicit** theme toggle (`setTheme`), not just `colorScheme` following. Use `.environment(\.colorScheme, chosen)` at the root plus asset-catalog colors, and every `c.token` becomes `Color("token")`. The one place this bites: `SPEEDS[].dot` stores a palette *key* precisely because values went stale — in Swift, storing `Color("paused")` is already lazy, so the workaround disappears.
3. **The `zIndex: speedOpen ? 30 : 0` escape hatch for the speed popover.** RN lets an absolutely-positioned child overflow its parent and paint above later siblings. SwiftUI clips less aggressively but z-ordering inside a `ScrollView`'s `VStack` is by declaration order, and `.zIndex` only reorders within one container. The popover renders `bottom: 62, left: -6, right: -6` relative to its flex cell and must paint over the AMS strip below it. Cleanest native approach: hoist it out of the scroll content into a root `ZStack` overlay anchored with `.anchorPreference`/`GeometryReader` on the speed button, or use `.popover`/a custom overlay presented from the root. Do **not** try to reproduce it as a sibling inside the `VStack`.
4. **The AMS strip's `flex:1` ⇄ `minWidth:74 + scroll` switch.** SwiftUI has no `flexGrow` on `ScrollView` content. Port as: if `slots.count <= 4`, an `HStack(spacing: 10)` of `.frame(maxWidth: .infinity)` chips (no scroll); else a `ScrollView(.horizontal)` with `.frame(minWidth: 74)` chips. Two code paths, matching the RN behaviour exactly. Do not unify them — the comment documents that 5 slots collapse to slivers and 9 are unreadable.
5. **`aspectRatio: 16/10` inside a padded scroll view.** `.aspectRatio(16.0/10.0, contentMode: .fit)` on a `.frame(maxWidth: .infinity)` container works, but combined with `.clipShape` and an absolutely-positioned badge overlay, get the order right: frame → background → overlay(badges) → clipShape → overlay(border).
6. **The snapshot cache-bust.** `URLSession`'s default cache will happily serve a stale image even with a changing query string in some proxy configurations; and iOS will re-decode a full JPEG every 2 s. Use a `URLRequest` with `.reloadIgnoringLocalCacheData` and decode off the main actor. Also preserve the exact pause conditions: **pause when the fullscreen camera is open or the tab is not `printer`; do NOT pause on PiP** (that's the documented frozen-tile bug).
7. **`display: 'none'` for the hidden dashboard.** The reason (reanimated teardown race) does not exist in SwiftUI, so you can genuinely swap views — but you then lose the "camera tile keeps its last frame across tab switches" behaviour, and the snapshot poller's `tab !== 'printer'` gate becomes the only thing keeping it quiet. Keep the poller gate; drop the keep-mounted hack.
8. **`inset: 0` positioning.** RN's `inset` shorthand → SwiftUI `.frame(maxWidth: .infinity, maxHeight: .infinity)` inside a `ZStack` with `.ignoresSafeArea()`. The AlertsOverlay in particular ignores safe area for its background but adds `safeAreaTop + 12` to its header padding — reproduce both halves.
9. **Locked-control styling.** `lock.style(action)` returns `{opacity: 0.4}` or `nil` and is spread into the *container* style, dimming the whole button including its text. In SwiftUI apply `.opacity(locked ? 0.4 : 1)` to the button label, and keep the button **enabled** (not `.disabled`) so the tap still fires the explanatory alert — `.disabled(true)` would swallow the tap and lose the explanation, which is the entire point of the design.
10. **Copy with typographic characters.** The strings contain `·` (U+00B7), `→` (U+2192), `—` (U+2014), `…` (U+2026), `°`. Move them into a `Localizable.strings`/`String` catalog verbatim; do not let a linter normalise them to ASCII.

**Stale doc to fix while porting:** the root `CLAUDE.md` describes `TabBar (6 tabs)` and `TabScreens (Library / Queue / AMS+Maintenance / Power+energy / History)`. The shipping code has **5** tabs — Printer / Files / Jobs / Hardware / Power — with queue and history merged into `jobs`.
