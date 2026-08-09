<!-- Generated as the port specification for the native Swift rewrite. -->
# presentDashboard / DashVM — the single source of print-state truth

## dashboard

Source of truth: `/Users/max/ai-projects/bambu-app/mobile/src/dashboard/present.ts` (519 lines), `/Users/max/ai-projects/bambu-app/mobile/src/alerts/present.ts` (203 lines), `/Users/max/ai-projects/bambu-app/mobile/src/alerts/hmsCatalog.ts` (161 lines). Supporting: `/Users/max/ai-projects/bambu-app/mobile/src/theme.ts`, `/Users/max/ai-projects/bambu-app/mobile/src/ams/units.ts`, `/Users/max/ai-projects/bambu-app/mobile/src/api/types.ts`.

`presentDashboard(status, nowMs) -> DashVM` is **the single source of print-state classification**. Nothing else in the app may re-derive state from `status.state`. It is a **pure function** — no I/O, no React, no clock access (time is injected as `nowMs`). Callers pass `Date.now()`; tests pass `0`. It is the most-tested module in the repo (`src/dashboard/__tests__/present.test.ts`, 495 lines).

---

### 1. `DashVM` — every field

```ts
export type DashKind = 'connecting' | 'offline' | 'idle' | 'live' | 'complete' | 'error';

export interface NozzleVM {
  now: number;        // rounded °C
  target: number;     // rounded °C
  heating: boolean;
  active: boolean;    // the extruder currently doing the work (always true on single-nozzle machines)
}
```

| Field | Type | Meaning / derivation | Default (`base()`) |
|---|---|---|---|
| `kind` | `DashKind` | Print-state classification. See §4. | `'connecting'` |
| `stateLabel` | `string` | Human state text. Exact strings in §4/§5. | `'Connecting'` |
| `stateColor` | `string` | Theme token value (hex/rgba string). §4. | `c.idle` |
| `heroSub` | `string` | `status.subtask_name ?? ''`; overridden to `'No active job'` when idle, `'No response from the printer'` when offline. | `''` |
| `progressInt` | `number` | `round(status.progress)` — integer %, 0 when null/NaN. | `0` |
| `layer` | `string` | `String(status.layer_num ?? 0)` — **a string, not a number**. | `'0'` |
| `totalLayers` | `string` | `String(status.total_layers ?? 0)` — string. | `'0'` |
| `etaText` | `string` | `fmtDuration(status.remaining_time ?? 0)` — e.g. `"1h 12m"`, `"45m"`, `"—"`. | `'—'` |
| `doneText` | `string` | `status.remaining_time ? fmtClock(nowMs + remaining_time*60000) : '—'`. Wall-clock finish time. | `'—'` |
| `nozzleNow` | `number` | ACTIVE nozzle current °C. What compact views + Live Activity read. | `0` |
| `nozzleTarget` | `number` | ACTIVE nozzle target °C. | `0` |
| `nozzleHeating` | `boolean` | ACTIVE nozzle heating flag. | `false` |
| `nozzles` | `NozzleVM[]` | ALL nozzles in **payload order** (idx 0 = `nozzle` = LEFT, idx 1 = `nozzle_2` = RIGHT). Length 1 or 2. | `[]` |
| `bedNow` | `number` | `round(t.bed)` | `0` |
| `bedTarget` | `number` | `round(t.bed_target)` | `0` |
| `bedHeating` | `boolean` | `heating(t.bed_heating, bedNow, bedTarget, 2)` | `false` |
| `hasChamber` | `boolean` | `t.chamber != null` — presence of the KEY, not a nonzero value. | `false` |
| `chamberNow` | `number` | `round(t.chamber)` | `0` |
| `chamberTarget` | `number` | `round(t.chamber_target)` | `0` |
| `chamberHeating` | `boolean` | `hasChamber && heating(t.chamber_heating, now, target, 2)` | `false` |
| `isPaused` | `boolean` | `true` ONLY on the PAUSE branch (which yields `kind: 'live'`). | `false` |
| `lightOn` | `boolean` | `status.chamber_light === true` (strict — `null` ⇒ false). | `false` |
| `speedIdx` | `number` | 1..4 from `status.speed_level`, **clamped to 2 when out of range or missing**. | `2` |
| `speedLabel` | `string` | `SPEED_LABELS[speedIdx]` | `'Standard'` |
| `hmsCount` | `number` | `status.hms_errors?.length ?? 0`. Non-blocking notices — a warning chip, NOT an error screen. | `0` |
| `hmsCode` | `string \| null` | `fmtHmsCode(hms_errors[0].full_code ?? hms_errors[0].code)` — dashed for readability. | `null` |
| `awaitingPlateClear` | `boolean` | `status.awaiting_plate_clear === true`. FINISH + plate not confirmed ⇒ queue blocked. | `false` |
| `ams` | `AmsSlotVM[]` | Flat list of EVERY slot across EVERY unit, in unit order. From `presentAms(status)`. | `[]` |
| `amsUnits` | `AmsUnitVM[]` | The units those slots belong to (grouping, capacity, drying ceiling, fed extruder). | `[]` |
| `amsRouting` | `AmsRouting` | `'fixed'` \| `'switch'` — `'switch'` when a Filament Track Switch routes units dynamically. | `'fixed'` |

**Gotcha — `base()` is a function, not a module constant:**

```ts
// The base VM is built per call — theme tokens (c.*) are live-mutated on theme switch, so
// capturing their values at module scope would freeze the dark palette forever.
function base(): DashVM { ... }
```

`c` is a mutable singleton (`Object.assign(c, themes[name])` in `setTheme`). Any snapshot at module scope pins the dark palette permanently.

---

### 2. Numeric coercion — `round` and `asNum`

```ts
const round = (n: number | undefined | null): number => Math.round(Number(n ?? 0)) || 0;
```
`|| 0` collapses `NaN` and `-0` to `0`. So a garbage temp renders as `0`, never `NaN`.

```ts
/** Coerce a Bambuddy numeric field to a finite number, else null. The WebSocket delivers some
 *  numbers as strings (e.g. AMS `temp` = "30.4") while REST sends real numbers — callers that use
 *  number-only methods (.toFixed) MUST go through this or they crash on the string form. */
export function asNum(x: unknown): number | null {
  if (x == null || x === '') return null;
  const n = typeof x === 'number' ? x : Number(x);
  return Number.isFinite(n) ? n : null;
}
```

**Hard-won:** the WS feed sends AMS `temp` as the string `"30.4"`; a raw `.toFixed()` crashed the AMS tab (2026-07-05). Pinned by test: `asNum('30.4') === 30.4`, `asNum(31.2) === 31.2`, `asNum(0) === 0`, `asNum('0') === 0`, and `null` for `null`/`undefined`/`''`/`'n/a'`/`NaN`. Note `''` is explicitly guarded because `Number('') === 0`.

Which fields arrive as strings over WS but numbers over REST (from `src/api/types.ts`): AMS `humidity`, `temp`, `dry_time`, `dry_target_temp`, tray `drying_temp`/`drying_time`, `nozzle_rack[].wear`/`max_temp`/`nozzle_diameter`. The `temperatures` block also tolerates string values (test: `presentDashboard tolerates string temps in the temperatures block`) because `round()` goes through `Number()`.

---

### 3. Formatters

```ts
export const SPEED_LABELS = ['', 'Silent', 'Standard', 'Sport', 'Ludicrous']; // index 0 unused

export function fmtDuration(min: number): string {
  if (!isFinite(min) || min <= 0) return '—';
  const h = Math.floor(min / 60);
  const m = Math.round(min % 60);
  return h > 0 ? `${h}h ${String(m).padStart(2, '0')}m` : `${m}m`;
}

export function fmtClock(ms: number): string {
  const d = new Date(ms);
  let h = d.getHours();
  const m = d.getMinutes();
  const ap = h >= 12 ? 'PM' : 'AM';
  h = h % 12 || 12;
  return `${h}:${String(m).padStart(2, '0')} ${ap}`;
}

/** "0500050000010007" -> "0500-0500-0001-0007" (the format Bambu's HMS docs use). */
export function fmtHmsCode(fullCode?: string | null): string | null {
  if (!fullCode) return null;
  const s = String(fullCode);
  return s.length === 16 ? s.replace(/(.{4})(?=.)/g, '$1-') : s;
}
```

- The em-dash is `—` (U+2014), not a hyphen.
- `fmtDuration` pads minutes to 2 digits only in the `h > 0` form: `72 -> "1h 12m"`, `45 -> "45m"`, `0/null/negative -> "—"`.
- **Latent rounding edge case (preserve or fix deliberately):** `fmtDuration(119.6)` yields `"1h 60m"` because `h` floors and `m` rounds independently. Same for `59.7 -> "60m"`.
- `fmtClock` is hard-coded 12-hour English AM/PM in **device-local time** — it does not respect the locale's 24-hour preference.
- `fmtHmsCode` only dashes 16-char codes; anything else passes through verbatim (so a short `"0x10007"` stays `"0x10007"`).

---

### 4. `kind` classification — the branch order (exhaustive)

Evaluated top to bottom; **first match wins**. Order is load-bearing.

```
presentDashboard(status, nowMs = 0):

 0. status == null
      -> base()                      kind 'connecting'  label 'Connecting'  color c.idle
                                     (every other field at its default — no data at all)

 1. status.connected === false       (note: falsy check `!status.connected`)
      -> { ...base(), kind:'offline', stateLabel:'Offline', stateColor: c.idle,
           heroSub: 'No response from the printer' }
      ** NOTE: spreads base(), NOT common — ALL temps/AMS/progress are DISCARDED and reset to
         defaults. An offline printer shows zeros, never stale values. **

 -- from here: state = (status.state || '').toUpperCase(); `common` is built (see §5) --

 2. !!status.print_error  ||  state === 'FAILED'  ||  state === 'ERROR'
      -> { ...common, kind:'error', stateLabel:'Error', stateColor: c.error }

 3. state === 'PAUSE' || state === 'PAUSED'
      -> { ...common, kind:'live', isPaused:true, stateLabel:'Paused', stateColor: c.paused }
      ** PAUSED IS NOT ITS OWN KIND. It is kind 'live' + isPaused. **

 4. state === 'FINISH' || state === 'FINISHED' || state === 'FINISHING'
      -> { ...common, kind:'complete', stateLabel:'Complete', stateColor: c.running }

 5. state === 'IDLE' || state === '' || state === 'UNKNOWN'
      -> { ...common, kind:'idle', stateLabel:'Idle', stateColor: c.idle,
           heroSub:'No active job' }      // overrides subtask_name

 6. otherwise -> LIVE (see §6 for the label/colour heuristic)
```

**Gotcha, quoted verbatim from the source:**
> A real failure: the backend's `print_error`, or an explicit failed state. An `hms_errors` entry alone is **NOT** an error — the H2C emits benign notices mid-print; they surface via `hmsCount`.

Regression pinned by test (`benign hms while RUNNING stays live`, live payload 2026-07-05): a `RUNNING` status carrying `hms_errors: [{ severity: 5, full_code: '0500050000010007' }]` must yield `kind: 'live'`, `hmsCount: 1`, `hmsCode: '0500-0500-0001-0007'`.

`kind` is consumed downstream for camera visibility: `DashboardView` shows the camera tile when `kind` is one of `live | idle | complete | error` (i.e. not `connecting`/`offline`).

---

### 5. The `common` VM

Built once, then each terminal branch spreads it and overrides `kind`/`stateLabel`/`stateColor` (+ `isPaused`/`heroSub`). `common` itself is **never returned** — every path overrides at least `kind`.

```ts
const common: DashVM = {
  ...base(),
  heroSub: status.subtask_name ?? '',
  progressInt: round(status.progress),
  layer: String(status.layer_num ?? 0),
  totalLayers: String(status.total_layers ?? 0),
  etaText: fmtDuration(status.remaining_time ?? 0),
  doneText: status.remaining_time ? fmtClock(nowMs + status.remaining_time * 60000) : '—',
  nozzleNow: active.now, nozzleTarget: active.target, nozzleHeating: active.heating,
  nozzles,
  bedNow, bedTarget, bedHeating,
  hasChamber, chamberNow, chamberTarget, chamberHeating,
  lightOn: status.chamber_light === true,
  speedIdx, speedLabel: SPEED_LABELS[speedIdx],
  hmsCount, hmsCode,
  awaitingPlateClear: status.awaiting_plate_clear === true,
  ams, amsUnits, amsRouting,
};
```

Speed clamp: `status.speed_level && >= 1 && <= 4 ? status.speed_level : 2`.

---

### 6. The LIVE label/colour heuristic

```ts
// Live. Prefer the printer's own sub-stage name ("Changing filament", "Auto bed leveling"…);
// fall back to the heating heuristic.
const stage = (status.stg_cur_name ?? '').trim();
const inStage = stage.length > 0 && stage.toLowerCase() !== 'printing';
const heatingUp = (active.heating || bedHeating) && (status.progress ?? 0) < 2;
const stateLabel = inStage ? stage : heatingUp ? 'Heating' : 'Printing';
return { ...common, kind: 'live', stateLabel, stateColor: inStage || heatingUp ? c.heating : c.running };
```

- `stg_cur_name === "Printing"` (any case) is explicitly **not** treated as a sub-stage — it falls through to the heuristic.
- `heatingUp` requires progress `< 2` %; past 2 % a heating nozzle no longer relabels the screen.
- Label precedence: sub-stage name > `'Heating'` > `'Printing'`.
- Colour: `c.heating` (amber) if either sub-stage or heating-up; else `c.running` (green).

### The `heating()` helper and its gaps

```ts
/** Heating: trust the payload's explicit flag when present, else derive from the temp gap. */
function heating(explicit: boolean | undefined, now: number, target: number, gap: number): boolean {
  if (typeof explicit === 'boolean') return explicit;
  return target > 0 && now < target - gap;
}
```

Gap constants: **nozzle = 3 °C, bed = 2 °C, chamber = 2 °C.** An explicit `false` from the payload wins over an obviously-heating temperature gap (pinned by test `explicit heating flags from the payload win over the derived heuristic`: nozzle 40/220 with `nozzle_heating: false` ⇒ `nozzleHeating === false`).

---

### 7. Active-nozzle selection — the coordinate-system bug that must not come back

This is the single most bug-prone routine in the file. The comment is reproduced in full because it encodes three separate live captures:

```ts
// Which head is doing the work. TWO different numbering schemes meet here and MUST NOT be compared
// index-to-index (that mismatch caused every past "wrong nozzle" bug):
//  - temperature keys are POSITION-ordered: `nozzle` = LEFT head, `nozzle_2` = RIGHT;
//  - `active_extruder` uses Bambu's extruder ids: 0 = RIGHT, 1 = LEFT.
// Verified live on the H2C (2026-07-18, print running on the right 0.6): active_extruder=0 with
// nozzle_2 driven at 220/220 and nozzle idle at 44 — and re-reading the 2026-07-07 capture
// (active_extruder=1 while `nozzle` was driven at 245/245) it agrees too; the field was never
// unreliable, it was being read in the wrong coordinate system. Order of trust: the DRIVEN head
// (exactly one target set — self-evident), then the mapped active_extruder (breaks the tie when
// both/neither are driven, e.g. mid tool-change), then the hotter head.
let activeIdx = 0;
if (nozzles.length > 1) {
  const driven0 = nozzles[0].target > 0;
  const driven1 = nozzles[1].target > 0;
  const ae = asNum(status.active_extruder);
  if (driven0 !== driven1) activeIdx = driven1 ? 1 : 0;
  else if (ae === 0 || ae === 1) activeIdx = ae === 0 ? 1 : 0; // 0=right -> nozzle_2 (idx 1)
  else activeIdx = nozzles[1].now > nozzles[0].now ? 1 : 0;
}
nozzles.forEach((n, i) => (n.active = i === activeIdx));
const active = nozzles[activeIdx] ?? n1;
```

Nozzle array construction (order matters — index 0 is always `nozzle`/LEFT):

```ts
const n1: NozzleVM = {
  now: round(t.nozzle), target: round(t.nozzle_target),
  heating: heating(t.nozzle_heating, round(t.nozzle), round(t.nozzle_target), 3),
  active: true,
};
const nozzles: NozzleVM[] = [n1];
if (t.nozzle_2 != null) {          // presence of the TEMP KEY, not of a target
  nozzles.push({
    now: round(t.nozzle_2), target: round(t.nozzle_2_target),
    heating: heating(t.nozzle_2_heating, round(t.nozzle_2), round(t.nozzle_2_target), 3),
    active: false,
  });
}
```

Regression tests that pin the three tiers:
1. **Driven wins over hotter** (the real Live-Activity bug, 2026-07-07): left cooling at 150/target 0, right heating 60→220 ⇒ RIGHT (idx 1) active, `nozzleNow: 60`, `nozzleTarget: 220`. "Hotter" would have picked the idle left.
2. **Driven wins over `active_extruder`** (2026-07-07 capture): `active_extruder: 1`, nozzle 245/245, nozzle_2 46/0 ⇒ idx 0 active (they agree, but driven decides).
3. **Hotter is the last resort**: nozzle 250/0, nozzle_2 40/0 ⇒ idx 0 active, `nozzleNow: 250`.
4. **Live H2C payload**: nozzle 41/0, nozzle_2 220/220 ⇒ idx 1 active.

The `ae === 0 ? 1 : 0` inversion is the whole fix — do not "simplify" it to `activeIdx = ae`.

---

### 8. Colour helpers

#### `normColor` — the alpha-00 sentinel

```ts
/** Bambu tray colors are RGBA hex like "565656FF". Return #RRGGBB, or null when there is no colour.
 *
 *  Alpha EXACTLY "00" is Bambu's "unset" sentinel, NOT a real colour: "00000000" used to come back
 *  as "#000000", so a slot whose colour the printer does not know rendered as black filament — and
 *  in the print wizard that black even beat the inventory spool's real colour. Any other alpha is a
 *  genuine colour and keeps its RGB (the AMS reports e.g. "C9A38180").
 *
 *  Non-hex input returns null rather than a malformed string: one caller feeds raw MakerWorld values
 *  straight into a React Native backgroundColor, where "#TRANSP" is an invalid colour. */
export function normColor(hex?: string | null): string | null {
  if (!hex) return null;
  const h = hex.replace('#', '').trim();
  if (!/^[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$/.test(h)) return null;
  if (h.length === 8 && h.slice(6) === '00') return null;
  return '#' + h.slice(0, 6).toUpperCase();
}
```

Truth table (pinned by tests):
| Input | Output | Why |
|---|---|---|
| `"00000000"` | `null` | alpha `00` = unset sentinel |
| `"000000FF"` | `"#000000"` | genuinely black |
| `"565656FF"` | `"#565656"` | normal |
| `"C9A38180"` | `"#C9A381"` | partial alpha is still a real colour |
| `"565656"` | `"#565656"` | 6-digit accepted |
| `"#ff8800"` | `"#FF8800"` | `#` stripped, uppercased |
| `"TRANSPARENT"`, `""`, `null` | `null` | rejected, never a malformed string |

Note: `.replace('#','')` strips only the **first** `#`, and `.trim()` runs after the strip.

#### `relLuminance` / `contrastRatio` — WCAG

```ts
const rgb = (hex: string): [number, number, number] => [
  parseInt(hex.slice(1, 3), 16), parseInt(hex.slice(3, 5), 16), parseInt(hex.slice(5, 7), 16),
];

/** WCAG relative luminance of a #RRGGBB colour. */
export function relLuminance(hex: string): number {
  const [r, g, b] = rgb(hex).map((ch) => {
    const v = ch / 255;
    return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4;
  });
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

/** WCAG contrast ratio between two #RRGGBB colours, 1..21. */
export function contrastRatio(a: string, b: string): number {
  const [la, lb] = [relLuminance(a), relLuminance(b)];
  return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05);
}
```

`rgb()` assumes a leading `#` (slices from index 1) — always feed it `normColor` output.

These are not decorative: a test (`swatch ring contrast — the guarantee the fix rests on`) asserts `c.swatchRing` clears **3:1 against every surface a swatch can sit on** (`bg, s1, s2, s3, s4, sheet`) **in both themes** — minimum 4.18:1 in dark (vs `s4`), 3.65:1 in light. It also asserts the ring beats the old `c.line2` hairline (~1.4:1), which is why bordered swatches still vanished.

#### `inkOn` — the tie-point constant

```ts
/** Ink that stays readable ON a given fill. 0.179 is the exact luminance where black and white ink
 *  tie: solve (L+0.05)/0.05 = 1.05/(L+0.05). Replaces a hard-coded '#fff' glyph that vanished on a
 *  white swatch. */
export function inkOn(hex?: string | null): string {
  return hex && relLuminance(hex) > 0.179 ? '#0D1012' : '#FFFFFF';
}
```

Returns literal hex, **not** theme tokens: `#0D1012` (near-black, same value as light-theme `t1`) or `#FFFFFF`. No fill ⇒ `#FFFFFF`.

#### `colorName` — HSL-derived human name

```ts
/** A human name for a filament colour — "White", "Titan grey", "Pale beige".
 *
 *  The point is that a swatch alone cannot say "white": on a white card it is a hole, and a user
 *  reading the row sees only "PETG". Derived from HSL rather than luminance because naming is about
 *  hue and saturation, not perceived brightness. Used only as a FALLBACK — an inventory spool's own
 *  color_name always wins, since a vendor name ("Titan Gray") beats anything computed. */
export function colorName(hex?: string | null): string | null {
  if (!hex || !/^#[0-9A-Fa-f]{6}$/.test(hex)) return null;
  const [r, g, b] = rgb(hex);
  const mx = Math.max(r, g, b);
  const mn = Math.min(r, g, b);
  const chroma = (mx - mn) / 255;
  const L = (mx + mn) / 2 / 255;

  if (chroma < 0.06) {                       // achromatic ladder
    if (L >= 0.97) return 'White';
    if (L >= 0.86) return 'Off-white';
    if (L >= 0.65) return 'Light grey';
    if (L >= 0.42) return 'Grey';
    if (L >= 0.15) return 'Dark grey';
    return 'Black';
  }

  const d = mx - mn;
  let hue: number;
  if (mx === r) hue = 60 * (((g - b) / d) % 6);
  else if (mx === g) hue = 60 * ((b - r) / d + 2);
  else hue = 60 * ((r - g) / d + 4);
  if (hue < 0) hue += 360;

  let base =
    hue < 15 || hue >= 345 ? 'red'
    : hue < 45 ? 'orange'
    : hue < 70 ? 'yellow'
    : hue < 160 ? 'green'
    : hue < 200 ? 'teal'
    : hue < 250 ? 'blue'
    : hue < 290 ? 'purple'
    : 'pink';
  // Warm but washed-out reads as beige/brown, not "pale orange".
  if (hue >= 15 && hue < 55 && chroma < 0.3) base = L >= 0.65 ? 'beige' : 'brown';
  const qual = L >= 0.75 ? 'Pale ' : L <= 0.25 ? 'Dark ' : '';
  const name = qual + base;
  return name.charAt(0).toUpperCase() + name.slice(1);
}
```

Exact thresholds:
- Achromatic gate: `chroma < 0.06`. Grey ladder cut points: `0.97 / 0.86 / 0.65 / 0.42 / 0.15`.
- Hue buckets (degrees): red `[345,360)∪[0,15)`, orange `[15,45)`, yellow `[45,70)`, green `[70,160)`, teal `[160,200)`, blue `[200,250)`, purple `[250,290)`, pink `[290,345)`.
- Warm-washed override: `hue ∈ [15,55) && chroma < 0.3` ⇒ `beige` when `L >= 0.65`, else `brown`. Note this range **straddles** the orange/yellow boundary at 45.
- Qualifier: `L >= 0.75` ⇒ `"Pale "`, `L <= 0.25` ⇒ `"Dark "`, else `""`.
- Capitalisation: **only the first character** — so `"Pale beige"`, `"Dark grey"` (lower-case second word), while the achromatic ladder returns pre-capitalised `"Light grey"`/`"Off-white"`.
- Input must be a strict `#RRGGBB` (6 hex digits with `#`). 8-digit RGBA is **rejected** ⇒ `null` — always pipe through `normColor` first.

Call-site rule (from `TabScreens.tsx:879-881`, `Overlays.tsx:1311`): `spool?.color_name ?? colorName(swatch)` — the vendor's own name always wins.

---

### 9. Nozzle / toolhead decoding

#### The code grammar

```ts
/**
 * H2-series nozzle codes are structured, not opaque: `H` + flow + a two-digit MATERIAL id.
 *
 *   HS00  standard flow, stainless steel      HS01  standard flow, hardened steel
 *   HH01  high flow,     hardened steel       HH05  high flow,     tungsten carbide
 *
 * Decoded from the live H2C rack + owner ground truth (2026-08-01): HS01 and HH01 are both 0.4 mm
 * / 350 °C and differ only in the middle letter, which pins that letter as flow rather than
 * material; HH05 is the owner's tungsten nozzle. Treating the parts separately means a nozzle Bambu
 * ships tomorrow still reports its flow correctly instead of falling back to a raw code.
 */
const NOZZLE_MATERIAL: Record<string, string> = {
  '00': 'Stainless',
  '01': 'Hardened',
  '05': 'Tungsten Carbide',
};
/** Long-form codes some machines (A1) report instead of the H2 short codes. */
const NOZZLE_TYPE_LABEL: Record<string, string> = {
  hardened_steel:    'Hardened',
  stainless_steel:   'Stainless',
  tungsten_carbide:  'Tungsten Carbide',
  hardened_tungsten: 'Hardened Tungsten',
};

const H2_CODE = /^H([SH])(\d{2})$/;   // anchored, exactly 4 chars: H + S|H + 2 digits
```

```ts
export function nozzleTypeLabel(t?: string | null): string {
  if (!t) return '';
  const m = H2_CODE.exec(t);
  if (m) {
    const material = NOZZLE_MATERIAL[m[2]];
    if (material) return material;
    return `Type ${t}`; // known shape, unknown material — don't invent one
  }
  const known = NOZZLE_TYPE_LABEL[t];
  if (known) return known;
  if (t.includes('_')) return t.split('_').map((w) => (w ? w[0].toUpperCase() + w.slice(1).toLowerCase() : w)).join(' ');
  return `Type ${t}`;
}

export function nozzleFlowLabel(t?: string | null): string {
  const m = t ? H2_CODE.exec(t) : null;
  if (!m) return '';
  return m[1] === 'H' ? 'High flow' : 'Standard flow';
}
```

**Gotcha (documented in the source):**
> The map can't be exhaustive — Bambu adds codes with new hardware — and a bare `?? code` fallback printed a raw `HS02` next to cards reading "Hardened", which reads like a material name. So: structured code → material; snake_case → Title Case; anything else → `"Type <code>"`, which at least reads as a machine code. **Never returns a bare unknown token.**

The two halves decode **independently** — pinned by test `still reports FLOW for a material it has never seen`: `HH07` ⇒ type `"Type HH07"`, flow `"High flow"`. `nozzleFlowLabel` returns `''` (not a placeholder) when the code carries no flow info (A1's long-form names), so callers simply omit the chip.

Helper: `nozzleDia(d)` = `asNum(d) != null ? \`${n} mm\` : ''` — e.g. `"0.4 mm"`. No fixed decimal formatting; `0.4` renders as `"0.4"`, `1` as `"1"`.

#### `presentNozzles(status) -> { toolheads: ToolheadVM[]; hasVortex: boolean }`

```ts
export interface RackNozzleVM {
  key: string;         // String(rack id) for rack machines, `m${i}` for spec-only
  diameter: string;    // "0.4 mm"
  type: string;        // "Hardened" | "Stainless" | "Tungsten Carbide" — MATERIAL only
  flow: string;        // "High flow" | "Standard flow" | ''
  colorHex: string | null; // per-nozzle filament MEMORY (last filament run through it)
  serial: string;      // LAST 4 chars of the RFID serial; '' for chipless (sn "N/A")
  mounted: boolean;    // has filament memory — a docked vortex nozzle keeps its color chip
  engaged: boolean;    // physically in the toolhead right now (rack id < 16)
}
export interface ToolheadVM {
  side: 'left' | 'right' | 'single';
  label: string;       // "Left" | "Right" | "Nozzle"
  active: boolean;     // the currently-selected extruder
  swappable: boolean;  // has a vortex (more than one nozzle to choose from)
  nozzles: RackNozzleVM[];
}
```

The rack semantics, quoted in full (this comment IS the spec — it follows Bambu Studio's own `DevNozzleSystemParser::ParseV2_0`):

> - rack `id` < 16 ⇒ the nozzle **CURRENTLY INSTALLED** on extruder `id` (**0 = RIGHT/main, 1 = LEFT**);
> - rack `id` >= 16 ⇒ a nozzle **DOCKED** in the changer ("vortex"), slot = id − 16. The changer belongs to the MAIN (right, ext 0) extruder — Studio attaches rack nozzles only there.
> - An engaged nozzle's home dock simply **DISAPPEARS** from the list (its dock is empty); the raw `src_id`/`tar_id`/`exist` fields that would name the dock are dropped by Bambuddy.
> - `filament_color` is per-nozzle filament **MEMORY** (last filament run through it) — several docked nozzles legitimately carry one. `stat` is health bits, `wear` is opaque; **neither marks engagement**. Chipless nozzles report serial `"N/A"` (and `max_temp` 0) but are **REAL** — the H2C's left fixed 0.4 is exactly that, so `"N/A"` must not be filtered as an empty slot.

**Path A — rack present (`status.nozzle_rack.length > 0`):**

```ts
const mounted  = !!(r.filament_color && r.filament_color !== '00000000');
const chipless = !r.serial_number || r.serial_number === 'N/A';
// colorHex = mounted ? normColor(r.filament_color) : null
// serial   = chipless ? '' : r.serial_number.slice(-4)

const installed = rack.filter((r) => r.id < 16);                        // on-extruder: id IS the extruder id
const docked    = rack.filter((r) => r.id >= 16).map((r) => toNozzle(r, false));
const exts = [...new Set(installed.map((r) => r.id))].sort((a, b) => b - a); // DESC => left (1) first
const dual = exts.length > 1;
// per ext:
//   nozzles   = ext === 0 ? [...engagedNozzles, ...docked] : engagedNozzles
//   side      = dual ? (ext === 0 ? 'right' : 'left') : 'single'
//   label     = dual ? (ext === 0 ? 'Right' : 'Left')  : 'Nozzle'
//   active    = asNum(status.active_extruder) === ext
//   swappable = ext === 0 && docked.length > 0
// hasVortex = toolheads.some(t => t.swappable)
```

Display order is **LEFT first** (descending extruder id) even though ext 0 is RIGHT/main.

**Path B — no rack (A1 etc.), the cross-map:**

```ts
// No rack (A1 etc.): one non-swappable toolhead per mounted nozzle, spec from status.nozzles.
// vm.nozzles is TEMPERATURE-ordered (idx 0 = `nozzle` = LEFT); the `nozzles` spec array is
// EXTRUDER-ordered (idx 0 = extruder 0 = RIGHT) — cross-map on duals or diameters swap sides.
const vm = presentDashboard(status);        // <-- re-entrant call into presentDashboard
const info = status.nozzles ?? [];
const dual = vm.nozzles.length > 1;
const spec = dual ? info[1 - i] : info[i];  // THE CROSS-MAP
//   side  = dual ? (i === 0 ? 'left'  : 'right') : 'single'
//   label = dual ? (i === 0 ? 'Left'  : 'Right') : 'Nozzle'
//   active = n.active            // from the temperature-derived active nozzle
//   nozzles = (diameter || type) ? [{ key: `m${i}`, ..., colorHex: null, serial: '',
//                                     mounted: n.active, engaged: n.active }] : []
// then .filter(t => t.nozzles.length > 0)
```

Note the **side labels are inverted between the two paths** for index 0 — rack path index 0 is `ext 0` = RIGHT; no-rack path index 0 is the `nozzle` temp key = LEFT. Both are correct in their own coordinate system; that is the entire point of the `1 - i` cross-map.

`presentNozzles(null)` ⇒ `{ toolheads: [], hasVortex: false }`.

---

### 10. AMS integration (`src/ams/units.ts`, consumed by `DashVM.ams` / `.amsUnits` / `.amsRouting`)

`presentDashboard` delegates entirely:

```ts
// ALL units, not just ams[0] — the H2C already runs an AMS 2 Pro (id 0) alongside an AMS HT
// (id 128). presentAms also owns the tray-id math: `active` compares tray_now to the GLOBAL id,
// where this used to compare it to a local index (right only by luck for unit 0).
const { units: amsUnits, slots: ams, routing: amsRouting } = presentAms(status);
```

Key facts the dashboard depends on:
- **Global tray id math** (the one piece of id math in the app): `globalTrayId = (unitId, localId) => unitId >= 128 ? unitId : unitId * 4 + localId`. Regular units pack 4 trays each (unit 0 → 0..3, unit 1 → 4..7); an AMS HT's own id (128..135) **IS** its tray id.
- `AmsSlotVM.active` = `!empty && tray_now != null && tray_now === globalId`. Comparing against a **local** index lights the HT's tray whenever AMS-0 slot 0 prints.
- `AmsSlotVM`: `label` (`tray_type` or `'Empty'`), `color` (`normColor(tray_color)`, **null when unknown** — the old `'#3A3F45'` fallback claimed a colour we don't have and never adapted to light theme), `pct` (`` `${Math.round(asNum(remain) ?? 0)}%` `` or `'—'`), `empty`, `unitId`, `unitLabel`, `localId`, `globalId`, `extruder`.
- `AmsUnitVM`: `id` (RAW, what drying/load endpoints expect), `label` (`"AMS 1"`, `"AMS 2"`, `"AMS HT"`/`"AMS HT n"`), `kind` (`'ams'|'ht'`), `capacity`, `loaded`, `maxDryTemp` (**65 for AMS 2 Pro, 85 for HT**), `humidity`, `tempC`, `extruder`, `serialTail` (last 4, `''` for `"N/A"`), `dryingMinLeft`.
- **Routing gotcha:** `routing = fila_switch.installed === true || !everyUnitMapped ? 'switch' : 'fixed'`. `fila_switch` is **absent from the WebSocket payload** (REST carries it, WS does not) and the app runs on the WebSocket — so an *incomplete* `ams_extruder_map` is the real tell: Bambuddy omits any unit whose info nibble reads `0xE` ("no fixed extruder"). Keying solely on `fila_switch` made the live app fall back to a stale map and paint every unit-0 slot "→ Right".
- Extruder convention is the **same everywhere**: `0 = RIGHT/main, 1 = LEFT` (`extruderSide`). The AMS tab shipped it inverted once.

---

### 11. Alerts — `presentAlerts(status, caps, describe) -> AlertVM[]`

The module's governing rule, quoted:
> The guiding rule (the owner's): **never offer an action the printer/permissions can't currently take.** A "Resume" button on a printer that isn't paused, or on one that's offline, is worse than no button — it teaches you not to trust the screen. So every action is gated on observed state, and anything we can't verify is simply not offered.

```ts
export type AlertLevel = 'error' | 'warning' | 'info';
export type AlertActionId = 'resume' | 'stop' | 'clearHms' | 'plateCleared' | 'lookup';

export interface AlertActionVM {
  id: AlertActionId;
  label: string;
  destructive?: boolean;   // irreversible or job-ending — the UI confirms these first
  urls?: string[];         // 'lookup' only: ordered candidates, LAST always resolves
}
export interface AlertVM {
  id: string;              // stable across polls so the list doesn't churn while a print runs
  level: AlertLevel;
  title: string;
  detail: string;
  code?: string;           // formatted HMS code, when this alert came from one
  actions: AlertActionVM[];
}
export interface AlertCaps { connected: boolean; canControl: boolean; model?: string | null; }
export interface AlertDescribe {
  hms?: (code: string) => string | null;
  printError?: (err: number | string) => string | null;   // describe is INJECTED so presentAlerts stays pure
}
```

`const canAct = caps.connected && caps.canControl;` — when false, **every** action array is `[]` except `lookup` (which is a pure link and always offered when a code exists).

#### Emission order (fixed; the list is built top-down)

| # | Condition | `id` | `level` | `title` | `detail` | actions (when `canAct`) |
|---|---|---|---|---|---|---|
| 1 | `status.print_error \|\| state==='FAILED' \|\| state==='ERROR'` | `'print-error'` | `error` | `Print error` | `describe.printError?.(print_error)` ?? (`print_error` ? `` `The printer reported error ${print_error}. Check the machine before continuing.` `` : `The printer stopped with an error. Check the machine before continuing.`) | `Resume` (id `resume`), `Stop print` (id `stop`, **destructive**) |
| 2 | `state==='PAUSE' \|\| state==='PAUSED'` | `'paused'` | `warning` | `Print paused` | `Resume once the problem is fixed, or stop the job entirely.` | `Resume print`, `Stop print` (**destructive**) |
| 3 | `status.awaiting_plate_clear === true` | `'plate'` | `info` | `Waiting for the plate` | `The finished print has to come off the bed before the next job can start.` | `Plate is clear` (id `plateCleared`) |
| 4 | per `hms_errors[i]` | `` `hms-${dashed ?? i}` `` | from severity, else `warning` | `` `${sev.label} notice` `` else `Printer notice` | see below | `What is this?` (id `lookup`, always when a code exists) + `Dismiss` / `` `Dismiss all (${n})` `` (id `clearHms`, **only on `i === 0`**) |

Note the phrasing difference: alert 1 offers `"Resume"`, alert 2 offers `"Resume print"` — both id `resume`. Both offer `"Stop print"`.

#### HMS severity ladder

```ts
/** Bambu's documented severity ladder. Anything outside it stays a neutral "Notice" rather than
 *  guessing a level we can't justify — some firmwares report values outside 1-4. */
const SEVERITY: Record<number, { level: AlertLevel; label: string }> = {
  1: { level: 'error',   label: 'Fatal'   },
  2: { level: 'error',   label: 'Serious' },
  3: { level: 'warning', label: 'Common'  },
  4: { level: 'info',    label: 'Info'    },
};
const sev = SEVERITY[num(h.severity) ?? -1];   // -1 sentinel => undefined => neutral
```

Titles: `"Fatal notice"`, `"Serious notice"`, `"Common notice"`, `"Info notice"`, or `"Printer notice"` for anything unmapped (the live H2C sends `severity: 5`). Unmapped severity ⇒ `level: 'warning'`.

HMS detail cascade:
```ts
detail:
  (dashed ? describe.hms?.(dashed) : null) ??
  (!dashed
    ? 'The printer raised a health notice with no code attached.'
    : sev?.level === 'error'
      ? 'The printer flagged a serious condition. Check the machine — look up the code for what it means.'
      : 'A health notice. The printer keeps going unless it also paused.'),
```
Pinned by tests: a routine notice **never claims the print failed**; a FATAL notice **never reassures** that the printer keeps going.

#### Wiki URL construction — the per-family namespace

```ts
// Bambu's wiki has a page per HMS code, but the path is PER MODEL FAMILY and each family has its own
// code namespace — verified live: 0C00_0100_0002_0017 is 200 under /h2/ and 404 under /x1/, while
// 0300_0D00_0001_0003 is the exact reverse. The path also uses UNDERSCORES, not the dashes the code is
// displayed with (the dashed form 404s everywhere; case is tolerated).
const FAMILIES = ['h2', 'x1', 'p1', 'a1'] as const;

export function wikiFamily(model?: string | null): string {
  const m = (model ?? '').trim().toUpperCase();
  if (m.startsWith('H2')) return 'h2';
  if (m.startsWith('X1')) return 'x1';
  if (m.startsWith('P1')) return 'p1';
  if (m.startsWith('A1')) return 'a1';
  return 'x1'; // the largest/legacy set is the least-bad guess for an unknown machine
}

export const HMS_INDEX_URL = 'https://wiki.bambulab.com/en/hms/error-code';

function hmsUrls(dashed: string, model?: string | null): string[] {
  const code = dashed.replace(/-/g, '_');
  const first = wikiFamily(model);
  const ordered = [first, ...FAMILIES.filter((f) => f !== first)];
  return [...ordered.map((f) => `https://wiki.bambulab.com/en/${f}/troubleshooting/hmscode/${code}`), HMS_INDEX_URL];
}
```

So for an H2C and code `0500-0500-0001-0007` the array is exactly 5 entries:
```
https://wiki.bambulab.com/en/h2/troubleshooting/hmscode/0500_0500_0001_0007
https://wiki.bambulab.com/en/x1/troubleshooting/hmscode/0500_0500_0001_0007
https://wiki.bambulab.com/en/p1/troubleshooting/hmscode/0500_0500_0001_0007
https://wiki.bambulab.com/en/a1/troubleshooting/hmscode/0500_0500_0001_0007
https://wiki.bambulab.com/en/hms/error-code
```
**The code is displayed dashed but linked with underscores** — the dashed form 404s everywhere.

#### `alertSummary` — the one dashboard row

```ts
/** One-line rollup for the dashboard: how many, and how bad the worst one is. `null` = all clear,
 *  so the dashboard renders nothing at all rather than a reassuring-but-noisy "no alerts" row. */
export function alertSummary(alerts: AlertVM[]): { count: number; level: AlertLevel; label: string } | null {
  if (!alerts.length) return null;
  const level: AlertLevel = alerts.some((a) => a.level === 'error') ? 'error'
    : alerts.some((a) => a.level === 'warning') ? 'warning' : 'info';
  const actionable = alerts.filter((a) => a.actions.some((x) => x.id !== 'lookup')).length;
  const noun = alerts.length === 1 ? 'alert' : 'alerts';
  return {
    count: alerts.length,
    level,
    label: actionable > 0 ? `${alerts.length} ${noun} · ${actionable} actionable` : `${alerts.length} ${noun}`,
  };
}
```
Separator is `·` (U+00B7) with spaces. `lookup`-only rows do **not** count as actionable. Example labels: `"1 alert"`, `"3 alerts · 2 actionable"`.

#### Level → colour mapping (both `DashboardView` and `AlertsOverlay`)

| level | tone (border/icon/text) | dim (background) |
|---|---|---|
| `error` | `c.error` | `c.errorDim` |
| `warning` | `c.heating` | `c.heatingDim` |
| `info` | `c.accent` | `c.accentDim` |

Icon: `info` for level `info`, `alert-circle` otherwise. Action-button styling: destructive ⇒ background `c.s3`, text `c.error`; `lookup` ⇒ background `c.s2`, 1 px `c.line2` border, text `c.t1`; everything else ⇒ background `tone`, text `c.accentInk`.

#### Action → endpoint mapping (from `src/app/index.tsx:379-413`, `bambuddyClient.ts`)

| action id | endpoint |
|---|---|
| `resume` | `POST /api/v1/printers/{id}/print/resume` |
| `stop` | `POST /api/v1/printers/{id}/print/stop` |
| `clearHms` | `POST /api/v1/printers/{id}/hms/clear` |
| `plateCleared` | `POST /api/v1/printers/{id}/clear-plate` — **NOT** `queueResume`; that clears the previous-failure gate and leaves `awaiting_plate_clear` set. Sends no MQTT, so it works without LAN Developer Mode. |
| `lookup` | HEAD-probe each candidate except the last; open the first `ok`; on any throw **break** and open the index. |

Destructive confirm: `Alert.alert(\`${act.label}?\`, \`${a.title} — this can't be undone.\`, [Cancel(cancel), act.label(destructive)])`.

`lookup` probe loop (the fix for "the reported *fatal is not found*"):
```ts
const candidates = act.urls!;
for (const url of candidates.slice(0, -1)) {
  try { const r = await fetch(url, { method: 'HEAD' }); if (r.ok) return void Linking.openURL(url).catch(() => {}); }
  catch { break; /* offline/blocked — stop probing and use the index */ }
}
await Linking.openURL(candidates[candidates.length - 1]).catch(() => {});
```

---

### 12. HMS catalog (`hmsCatalog.ts`) — fetch, cache, learn

Why it exists, quoted:
> Bambuddy does **NOT** carry this text (its `HMSErrorResponse` is just code/attr/module/severity/actions), and the wiki has no page for every code — the H2C's `0C00-0100-0002-0017` 404s. But Bambu publishes the same table their own software uses: **~4,900 HMS entries + ~650 print-error entries**, keyed by the exact codes the printer reports. Fetched once and cached, that turns "HMS 0501-0400-0003-0002" into "Threaded rods need lubrication now."
>
> It is fetched rather than bundled: the parsed map is **~535 KB**, which would bloat every OTA for text that changes independently of the app.

Constants:
```ts
const FEED_URL   = 'https://e.bambulab.com/query.php?lang=en';
const CACHE_FILE = 'hms-catalog.json';                    // in Paths.cache
const MAX_AGE_MS = 14 * 24 * 60 * 60 * 1000;              // 14 days
```

Shape:
```ts
export interface HmsCatalog {
  hms: Record<string, string>;      // 16-hex full_code (UPPERCASE) -> description
  err: Record<string, string>;      // decimal print_error (as string) -> description
  learned: Record<string, string>;  // wiki-scraped descriptions for codes the feed lacks
  fetchedAt: number;
}
export const EMPTY_CATALOG: HmsCatalog = { hms: {}, err: {}, learned: {}, fetchedAt: 0 };
```

Feed parsing (tolerant of missing sections and odd casing — a malformed feed yields empty maps rather than throwing):
```ts
export function parseHmsFeed(raw: unknown): Omit<HmsCatalog, 'fetchedAt' | 'learned'> {
  const data = (raw as { data?: Record<string, { en?: { ecode?: unknown; intro?: unknown }[] }> })?.data ?? {};
  const take = (section?, upper = false): Record<string, string> => {
    const out: Record<string, string> = {};
    for (const e of section?.en ?? []) {
      const code = String(e?.ecode ?? '').trim();
      const intro = String(e?.intro ?? '').trim();
      if (code && intro) out[upper ? code.toUpperCase() : code] = intro;
    }
    return out;
  };
  return { hms: take(data.device_hms, true), err: take(data.device_error) };
}
```
Sections: `data.device_hms` (keys **uppercased**) and `data.device_error` (keys left as-is). Each is `{ en: [{ ecode, intro }] }`.

Lookups (pure):
```ts
export function describeHms(cat: HmsCatalog, code: string | null | undefined): string | null {
  if (!code) return null;
  const key = code.replace(/[-_\s]/g, '').toUpperCase();   // accepts dashed display form OR raw hex
  // Optional-chain both: a catalog cached by an earlier build has no `learned` map, and reading it
  // straight would crash the alerts screen on upgrade.
  return cat.hms?.[key] ?? cat.learned?.[key] ?? null;
}

export function describePrintError(cat: HmsCatalog, err: number | string | null | undefined): string | null {
  if (err == null || err === '') return null;
  return cat.err?.[String(err)] ?? null;
}
```
**Gotcha:** the `?.` on `cat.hms`/`cat.learned` is a real upgrade-path fix — a disk cache written by an older build has no `learned` key, and a bare index crashed the alerts screen. Pinned by test `a catalog cached by an OLDER build (no 'learned' map) does not crash`.

Wiki title scraping (pure):
```ts
/** Pure: pull the description out of a Bambu wiki HMS page.
 *  The page's og:title is `HMS_0C00-0100-0002-0017: Nozzle camera lens is dirty, …` — the code's own
 *  prefix is stripped so the caller gets just the sentence. */
export function parseWikiTitle(html: string): string | null {
  const m =
    /<meta[^>]+property=["']og:title["'][^>]+content=["']([^"']+)["']/i.exec(html) ??
    /<title>([^<]+)<\/title>/i.exec(html);
  if (!m) return null;
  const text = m[1].replace(/\s*\|\s*Bambu Lab Wiki\s*$/i, '').trim();
  const body = /^HMS_[0-9A-F_-]+:\s*(.+)$/i.exec(text);
  const out = (body ? body[1] : text).trim();
  return out.length > 3 ? out : null;
}
```
`og:title` first, `<title>` fallback, strip the `" | Bambu Lab Wiki"` suffix, strip the `HMS_<code>: ` prefix, reject results of length ≤ 3.

#### Loader state machine — `loadHmsCatalog()`

Module-level state: `let memo: HmsCatalog | null = null; let inflight: Promise<HmsCatalog> | null = null;`

```
loadHmsCatalog()
 ├─ memo fresh (Date.now() - memo.fetchedAt < 14d)?  -> Promise.resolve(memo)      [sync hit]
 ├─ inflight != null?                                -> inflight                   [dedupe]
 └─ start inflight:
      1. DISK: File(Paths.cache, 'hms-catalog.json')
           if exists -> JSON.parse(textSync())
             if disk.hms && fresh -> memo = { ...disk, learned: disk.learned ?? {} }; RETURN
           any throw -> swallowed ("corrupt cache — refetch")
      2. NETWORK: fetch(FEED_URL); !res.ok -> throw
           cat = { ...parseHmsFeed(json), learned: memo?.learned ?? {}, fetchedAt: Date.now() }
           memo = cat
           best-effort persist: if (cache.exists) cache.delete(); cache.write(JSON.stringify(cat))
           RETURN cat
      3. ANY FAILURE -> return memo ?? EMPTY_CATALOG   ("offline: codes still render, just without prose")
      finally: inflight = null
```
Contract, quoted: *"Memory → disk → network. **Never throws and never blocks a render**: callers get `EMPTY_CATALOG` until it resolves, and the UI simply shows the code without prose in the meantime."*

The persist is `delete()`-then-`write()`, not an overwrite.

#### `learnCodes(codes)` — one request per code, ever

```
learnCodes([{ code, urls }])
  cat = await loadHmsCatalog()
  for each { code, urls }:
      key = code.replace(/[-_\s]/g,'').toUpperCase()
      if cat.hms[key] || cat.learned[key] -> skip (already known)
      for url of urls:
          if url.includes('/hms/error-code') -> continue   // the index describes nothing specific
          fetch(url); if !ok -> continue
          desc = parseWikiTitle(text)
          if desc -> cat.learned = { ...cat.learned, [key]: desc }; changed = true; BREAK
          catch -> BREAK   // offline — try again next launch (moves to the NEXT code)
  if changed: memo = { ...cat }; delete+write the cache (best effort)
  return memo ?? cat
```

Why it exists, quoted:
> Every H2-family code is missing from the public feed, including the one that turned out to say *"Nozzle camera lens is dirty…"* — precisely the message worth surfacing. Candidate URLs come from the alert itself (model family first), and the first page that yields a title wins.

#### Wiring in `src/app/index.tsx`

```ts
// caps
{ connected: status?.connected === true, canControl: true, model: printer?.model }
// describe
{ hms: (code) => describeHms(hmsCat, code), printError: (e) => describePrintError(hmsCat, e) }
```
Two effects: one loads the catalog on mount (`loadHmsCatalog().then(setHmsCat)`); one collects alerts whose `code` has no description yet, takes the `urls` off their `lookup` action, and calls `learnCodes(...)`, keyed on `alerts.map(a => a.code).join(',')` + `hmsCat.fetchedAt`. Both guard with an `alive` flag against setState-after-unmount.

---

### 13. Theme tokens referenced by the dashboard/alerts

`c` is a live-mutated singleton (`Object.assign(c, themes[name])` + `useSyncExternalStore` subscribers). Full values:

| token | dark | light |
|---|---|---|
| `bg` | `#0A0B0C` | `#EFF1F3` |
| `s1` | `#131517` | `#FFFFFF` |
| `s2` | `#191C1F` | `#F5F6F8` |
| `s3` | `#23272B` | `#EAECEF` |
| `s4` | `#2D3237` | `#DEE1E5` |
| `line` | `rgba(255,255,255,0.07)` | `rgba(0,0,0,0.08)` |
| `line2` | `rgba(255,255,255,0.12)` | `rgba(0,0,0,0.13)` |
| `t1` | `#F3F5F7` | `#0D1012` |
| `t2` | `#A4ABB2` | `#585E64` |
| `t3` | `#6B7177` | `#878D94` |
| `accent` | `#2BD4C0` | `#0EAE9C` |
| `accentInk` | `#04201D` | `#FFFFFF` |
| `accentDim` | `rgba(43,212,192,0.15)` | `rgba(14,174,156,0.14)` |
| **`running`** | `#30D158` | `#23B24A` |
| `runningDim` | `rgba(48,209,88,0.15)` | `rgba(35,178,74,0.14)` |
| **`heating`** | `#FF9F0A` | `#E0860A` |
| `heatingDim` | `rgba(255,159,10,0.15)` | `rgba(224,134,10,0.14)` |
| **`paused`** | `#0A84FF` | `#0A84FF` |
| `pausedDim` | `rgba(10,132,255,0.15)` | `rgba(10,132,255,0.12)` |
| **`error`** | `#FF453A` | `#E5392E` |
| `errorDim` | `rgba(255,69,58,0.15)` | `rgba(229,57,46,0.12)` |
| **`idle`** | `#8E9398` | `#9AA0A6` |
| `idleDim` | `rgba(142,147,152,0.14)` | `rgba(154,160,166,0.14)` |
| `sheet` | `#16181B` | `#FFFFFF` |
| `tabbar` | `rgba(13,14,16,0.72)` | `rgba(244,246,248,0.8)` |
| `thumb` | `#0e1113` | `#E4E7EA` |
| `supports` | `#E8A23D` | `#C77E14` |
| `swatchRing` | `#8E9398` | `#6E7378` |

`swatchRing` carries a contract, quoted:
> Ring drawn around every filament colour swatch. Its job is to separate the swatch from the **CARD** it sits on, so it is chosen for contrast against the **SURFACES**, not against the fill — a white spool on a white card was invisible. ≥ 3:1 vs `bg/s1/s2/s3/s4/sheet` (min 4.18 vs `s4` here). `c.line2` is only ~1.4:1, which is why swatches that already had a hairline still disappeared.

`stateColor` only ever takes: `c.idle` (connecting, offline, idle), `c.error` (error), `c.paused` (paused), `c.running` (complete, printing), `c.heating` (sub-stage / heating-up).

---

### 14. Complete inventory of user-visible strings

**State labels:** `Connecting`, `Offline`, `Idle`, `Complete`, `Error`, `Paused`, `Heating`, `Printing`, plus any verbatim `stg_cur_name` (e.g. `Changing filament`, `Auto bed leveling`).
**Hero subtitles:** `` (empty / subtask name), `No response from the printer`, `No active job`.
**Speed labels:** `Silent`, `Standard`, `Sport`, `Ludicrous`.
**Placeholder:** `—` (U+2014) for `etaText`, `doneText`, empty AMS `pct`.
**Duration:** `{h}h {mm}m` / `{m}m`. **Clock:** `{h}:{mm} AM|PM`.
**Colour names:** `White`, `Off-white`, `Light grey`, `Grey`, `Dark grey`, `Black`, and `[Pale |Dark ]{red|orange|yellow|green|teal|blue|purple|pink|beige|brown}` (first letter capitalised only).
**Nozzle materials:** `Stainless`, `Hardened`, `Tungsten Carbide`, `Hardened Tungsten`, `Type <code>`. **Flow:** `High flow`, `Standard flow`, `` (empty). **Diameter:** `{n} mm`.
**Toolhead labels:** `Left`, `Right`, `Nozzle`.
**AMS labels:** `AMS {n}`, `AMS HT`, `AMS HT {n}`, `Empty`, `{n}%`.
**Alert titles:** `Print error`, `Print paused`, `Waiting for the plate`, `Fatal notice`, `Serious notice`, `Common notice`, `Info notice`, `Printer notice`.
**Alert details:** the six exact sentences in §11.
**Alert actions:** `Resume`, `Resume print`, `Stop print`, `Plate is clear`, `Dismiss`, `Dismiss all ({n})`, `What is this?`.
**Alert summary:** `{n} alert|alerts`, `{n} alerts · {k} actionable`.
**Overlay chrome:** `Attention`, `Nothing needs attention`, `HMS {dashed-code}`.
**Dialogs:** `{label}?` / `{title} — this can't be undone.` (Cancel / {label}); `Couldn't resume`, `Couldn't stop`, `Couldn't clear`, `Couldn't confirm the plate`; `Plate confirmed clear` / `The next queued job can start.` (Note: curly apostrophe `'` U+2019.)

---

### Port notes

**Overall shape.** `presentDashboard`, `presentAlerts`, `presentAms`, `presentNozzles`, `alertSummary`, and every helper in §2–§9 are **pure functions of plain data**. Port them as free functions or `static` methods in a `DashboardPresenter` enum/namespace in a framework-free Swift module (no SwiftUI import), and port the existing Jest tests to XCTest **first** — they are the specification, and several encode live-payload regressions that are otherwise impossible to rediscover.

| RN piece | Swift/SwiftUI equivalent | Notes |
|---|---|---|
| `DashVM`, `NozzleVM`, `AmsSlotVM`, `AmsUnitVM`, `ToolheadVM`, `RackNozzleVM`, `AlertVM`, `AlertActionVM` | `struct`s conforming to `Equatable` (and `Sendable`) | Make them `Equatable` so SwiftUI diffing is cheap; `DashVM` is rebuilt on every status frame. |
| `DashKind`, `AlertLevel`, `AlertActionId`, `AmsRouting`, `AmsKind` | `enum: String` | `DashKind` becomes a real sum type — consider hoisting `isPaused` into `case live(paused: Bool)`, but see the warning below. |
| `stateColor: string` (a token *value*) | **`Color` computed from a `StateTone` enum, not a stored hex** | Do **not** store a resolved colour in the VM. The RN code has to rebuild `base()` per call precisely because `c` is live-mutated; in Swift the correct fix is to store a semantic token (`enum StateTone { case idle, running, heating, paused, error }`) and resolve it in the view via an `Environment`-injected palette or an Asset Catalog colour set. This also gets automatic light/dark for free and removes the whole `base()`-must-be-a-function gotcha. |
| `layer`/`totalLayers` as `String` | Keep as `String` **or** change to `Int` — but change both call sites together | They are strings only because the RN views interpolate them directly. `Int` is cleaner in Swift; just don't half-migrate. |
| `round(n)` | `Int(Double(x ?? 0).rounded())` with a NaN guard | Swift traps on `Int(Double.nan)` — **this is a crash, not a `0`**. Write `let d = Double(x ?? 0); return d.isFinite ? Int(d.rounded()) : 0`. The JS `\|\| 0` silently absorbed NaN; Swift will not. |
| `asNum(unknown)` | `func asNum(_ x: JSONValue?) -> Double?` | Model the WS/REST string-or-number duality explicitly. Best approach: a `@propertyWrapper` or a custom `Decodable` init that accepts `.string` and `.number` for the affected fields (`temperatures.*`, AMS `humidity`/`temp`/`dry_time`, `nozzle_rack.*`). Doing it at the `Codable` boundary is strictly better than JS's defensive `asNum` at every use site — but the boundary must be **complete**, or a raw `Double` decode throws where JS merely produced `null`. |
| `fmtDuration` | Hand-roll it — **do not** use `DateComponentsFormatter` | The exact output (`"1h 12m"`, `"45m"`, `"—"`, zero-padded minutes only in the hours form) will not match any formatter preset, and `DateComponentsFormatter` is locale-dependent. Port the arithmetic literally, and decide explicitly whether to keep the `"1h 60m"` edge case (JS floors hours, rounds minutes). Fixing it: round total minutes first, then divmod. |
| `fmtClock` | Hand-roll or a pinned `DateFormatter` | JS hard-codes 12-hour `AM/PM` in device-local time. `DateFormatter` with `.short` time style would silently become 24-hour for many locales — a behaviour change. Use `Calendar.current.dateComponents([.hour,.minute], from:)` and format manually to preserve behaviour, or make the switch to locale-aware deliberately. |
| `fmtHmsCode` | `String` chunking | `stride(from:to:by: 4)` over the characters, joined by `-`, only when `count == 16`. |
| `normColor` | `func normColor(_ hex: String?) -> String?` returning `#RRGGBB` | Keep returning a **String**, not a `Color`, so `colorName`/`inkOn`/`relLuminance` keep working on it and so `nil` stays representable. Add a separate `Color(hex:)` at the view boundary. The alpha-`"00"` sentinel check is the one line that must survive verbatim. |
| `relLuminance` / `contrastRatio` | Direct arithmetic port | `**2.4` → `pow(v, 2.4)`. Keep the `0.03928` and `12.92` constants exactly. **Do not** reach for `UIColor`'s components — the sRGB→linear transfer function is the whole point, and a `Color`/`UIColor` round-trip can introduce colour-space conversion. Operate on the raw hex bytes. |
| `inkOn` | Same, returning `Color(hex:)` or the literal strings | Threshold `0.179` is derived, not tuned — keep the comment explaining the solve. |
| `colorName` | Direct port | Straightforward; all-integer/Double arithmetic. Watch the capitalisation rule: **only the first character** is uppercased, so `"Pale beige"` — Swift's `.capitalized` would produce `"Pale Beige"` and break the tests. Use `prefix(1).uppercased() + dropFirst()`. |
| `NOZZLE_MATERIAL` / `NOZZLE_TYPE_LABEL` | `let` dictionaries `[String: String]` | Keep them as data, not enums — the whole design point is that unknown codes degrade gracefully to `"Type <code>"`. |
| `H2_CODE = /^H([SH])(\d{2})$/` | Swift Regex literal or manual parse | Prefer the manual parse — it is 4 characters: `count == 4 && first == "H" && (s[1] == "S" \|\| s[1] == "H") && s.suffix(2).allSatisfy(\.isNumber)`. Avoids `NSRegularExpression` overhead in a function called per rack entry per frame. If you use `Regex`, note it needs iOS 16+ (the project targets 16.4+, so it is available). |
| `presentAms` / `globalTrayId` | Direct port | `globalTrayId` is a one-liner and is the single piece of tray-id math — make it the only way to compute a global id, e.g. by making `AmsSlotVM.globalId` the only public accessor and keeping the math `private`. |
| `presentNozzles` calling `presentDashboard` re-entrantly | **Refactor** | The no-rack path calls `presentDashboard(status)` just to get the temperature-ordered `nozzles` array and its `active` flags. In Swift, extract that block into `func activeNozzles(_ t: Temperatures, activeExtruder: Int?) -> [NozzleVM]` and have both `presentDashboard` and `presentNozzles` call it. This removes a hidden O(everything) recomputation (it re-runs `presentAms` too) that the RN code pays on every `presentNozzles` call. |
| `presentAlerts` + `AlertDescribe` (injected closures) | A `protocol AlertDescribing` or a `struct` of closures | Keep the injection — it is what makes `presentAlerts` pure and testable. A protocol with a test double is the idiomatic Swift form. |
| `hmsUrls` / `wikiFamily` | Direct port; return `[URL]` | Build with `URL(string:)` and force-validate in a test rather than trusting interpolation. |
| `alertSummary` returning `null` | `-> AlertSummary?` | Natural fit; `if let summary = ...` in the view. |
| `AlertsOverlay` / `DashboardView` | SwiftUI `View`s driven by the VM | Level→tone/dim mapping becomes a `switch` on the `AlertLevel` enum returning `(Color, Color)`. |
| `Alert.alert(...)` destructive confirm | `.confirmationDialog` / `.alert` with `role: .destructive` | The `destructive` flag on `AlertActionVM` maps 1:1 to `ButtonRole.destructive` — keep the flag in the VM rather than re-deriving it in the view. |
| `Linking.openURL` | `openURL` `@Environment` action | — |

**Things that will be genuinely HARD or need a different approach:**

1. **The `hmsCatalog` module-level `memo`/`inflight` singleton is not `Sendable`.** Under Swift 6 strict concurrency, a mutable module-global cache with request coalescing must become an `actor`:
   ```swift
   actor HmsCatalogStore {
       private var memo: HmsCatalog?
       private var inflight: Task<HmsCatalog, Never>?
       func load() async -> HmsCatalog { /* memo-fresh → inflight → disk → network → EMPTY */ }
   }
   ```
   The `inflight` dedupe becomes a stored `Task` — cleaner than the JS promise, but note the JS clears `inflight` in a `finally`, so a *failed* fetch is retried on the next call rather than cached; replicate that (`defer { inflight = nil }` inside the task body).

2. **`textSync()` / `cache.write()` are synchronous disk I/O on the JS thread.** In Swift, do the read/write inside the actor with `Data(contentsOf:)` / `write(to:options:.atomic)`. Use `.atomic` and drop the JS `delete()`-then-`write()` dance entirely — that pattern exists only because `expo-file-system`'s `File.write` did not overwrite reliably.

3. **The `learned` backward-compat optional-chain (`cat.hms?.[key]`) has no Swift analogue** — a `Codable` struct with a non-optional `learned: [String: String]` will **throw on decode** of an old cache, which is worse than the JS crash it was fixing. Give `learned` a default: `@DecodableDefault` or a custom `init(from:)` using `decodeIfPresent(...) ?? [:]`. Same for `hms`/`err`. Add a schema-version field while you are at it and drop unknown versions.

4. **`parseWikiTitle` scrapes HTML with regexes.** Port the regexes as-is (`NSRegularExpression` or `Regex`) rather than reaching for an HTML parser — the JS behaviour, including the `og:title`-then-`<title>` fallback and the `length > 3` reject, is what the tests pin. Note the pattern uses `[^"']+` for the content attribute, so a title containing a quote truncates; preserve that or fix it deliberately.

5. **The wiki `lookup` HEAD-probe loop performs up to 4 network requests inside a tap handler.** In Swift this belongs in an `async` function with a short `URLRequest.timeoutInterval` (JS has none — a hung host stalls the tap indefinitely). Also replicate the `catch → break` semantics precisely: a *network error* aborts the whole probe and jumps to the index, while a *non-2xx* merely tries the next family.

6. **Theme as a live-mutated global (`c`).** Do not port this. It is a React-specific hack (`useSyncExternalStore` + inline `c.token` reads to avoid a context refactor) and it is the sole reason `base()` must be a function. In SwiftUI, an `@Environment` palette or Asset Catalog colour sets give the same result with none of the staleness hazard — and it removes an entire class of "frozen dark palette" bugs.

7. **The dual-nozzle coordinate-system inversion (`ae === 0 ? 1 : 0`) is the highest-risk line in the port.** It reads wrong. Encode the two schemes as distinct types so the compiler enforces the conversion:
   ```swift
   enum ExtruderID: Int { case right = 0, left = 1 }        // Bambu's ids
   enum NozzleSlot: Int { case left = 0, right = 1 }        // temperature-key position
   extension ExtruderID { var slot: NozzleSlot { self == .right ? .right : .left } }
   ```
   With those types, `activeIdx = ae.slot` is self-evidently correct and an index-to-index comparison stops compiling. Same treatment for the `presentNozzles` rack path (`id < 16` is an `ExtruderID`) and for `extruderSide`. This one refactor retires four documented regressions.

8. **`kind: 'live'` + `isPaused: true` is a deliberate encoding, not an oversight.** Every consumer that asks "is a job on the machine right now" checks `kind === 'live'` and would break if paused became its own case. If you promote it to `case live(paused: Bool)`, audit every `kind` comparison — notably `DashboardView`'s camera gate (`live | idle | complete | error`) and the Live Activity's start/update/end decision in `usePrinterActivities`.

9. **The `offline` branch spreads `base()`, not `common` — deliberately.** It discards all temps, AMS state and progress so a disconnected printer never shows stale numbers. A Swift port that "helpfully" keeps the last-known values changes behaviour; if you want last-known-good display, add it as an explicit, separately-labelled feature.

10. **`presentDashboard` is called 3–4× per render in `index.tsx`** (current printer, every fleet row, every Live Activity entry). In Swift, cache by `PrinterStatus` identity or make the VM a `@Published` property recomputed once per status frame in an `@Observable` store — do not call it from `body`.
