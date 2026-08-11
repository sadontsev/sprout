<!-- Generated as the port specification for the native Swift rewrite. -->
# AMS topology, dryer, cooling, power, LAN gating, printer profiles

## domain

Pure, React-free domain logic that the Swift rewrite must reproduce **exactly**. Everything in this section is deterministic (same input → same output) and covered by Jest tests that should be ported 1:1 as XCTest cases. Test files (port these too):
`src/ams/__tests__/units.test.ts`, `src/ams/__tests__/dryer.test.ts`, `src/cooling/__tests__/present.test.ts`, `src/power/__tests__/present.test.ts`, `src/capabilities/__tests__/lanMode.test.ts`, `src/printers/__tests__/profile.test.ts`, plus the fixture `src/cooling/fixtures/realCooldown.ts`.

---

### 0. Shared coercion helpers (from `src/dashboard/present.ts`) — needed by everything below

**Bambuddy's WebSocket serializer emits numbers as STRINGS** (`"30.4"`, `"128"`, `"344"`); REST emits real numbers. Every numeric read in this domain layer goes through `asNum`. A raw `.toFixed()` on a WS value crashes.

```ts
export function asNum(x: unknown): number | null {
  if (x == null || x === '') return null;
  const n = typeof x === 'number' ? x : Number(x);
  return Number.isFinite(n) ? n : null;
}

export function fmtDuration(min: number): string {          // "5h 44m" | "42m" | "—"
  if (!isFinite(min) || min <= 0) return '—';
  const h = Math.floor(min / 60);
  const m = Math.round(min % 60);
  return h > 0 ? `${h}h ${String(m).padStart(2, '0')}m` : `${m}m`;
}

/** Bambu tray colors are RGBA hex ("565656FF"). Returns #RRGGBB uppercase, or null. */
export function normColor(hex?: string | null): string | null {
  if (!hex) return null;
  const h = hex.replace('#', '').trim();
  if (!/^[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$/.test(h)) return null;
  if (h.length === 8 && h.slice(6) === '00') return null;   // alpha EXACTLY "00" = Bambu's "unset" sentinel
  return '#' + h.slice(0, 6).toUpperCase();
}
```

**Gotcha (real bug):** alpha `"00"` is Bambu's *unset* marker, not a colour. `"00000000"` used to render as `#000000`, so a slot whose colour the printer did not know showed as black filament — and in the print wizard that fake black beat the inventory spool's real colour. Any *other* alpha is a genuine colour and keeps its RGB (the AMS reports e.g. `"C9A38180"` → `#C9A381`). Non-hex input returns `null`, never a malformed string (one caller feeds raw MakerWorld values straight into a background colour, where `"#TRANSP"` is invalid).

---

### 1. AMS topology — `src/ams/units.ts`

Governs 1..N AMS units of mixed kinds. **Before this module existed the app read `status.ams[0]` in four places (plus Trellis), so a second unit was invisible.** The owner's live H2C (verified 2026-08-01) reports THREE units: two AMS 2 Pro (ids `0` and `1`, `module_type: "n3f"`, 4 trays each) and an AMS HT (id `128`, `"n3s"`, 1 tray, `is_ams_ht: true`), plus a Filament Track Switch (`fila_switch.installed`). The H2 series drives up to 4 regular units (ids 0–3) plus 8 HT units (128–135); this module assumes nothing about how many of either exist.

#### 1.1 `globalTrayId` — the one piece of id math in the app

```ts
export const globalTrayId = (unitId: number, localId: number): number =>
  (unitId >= 128 ? unitId : unitId * 4 + localId);
```

This is the id space the **printer** speaks: `tray_now`, `ams/load`'s `tray_id`, and `ams_mapping` **values**. Regular units pack 4 trays each (unit 0 → 0..3, unit 1 → 4..7); an AMS HT is a single-spool unit whose **unit id IS its tray id** (128..135). Confirmed against the live inventory endpoint, which keys three trays as `{"0","2","128"}` for (unit 0, tray 0), (unit 0, tray 2) and (HT 128, tray 0).

**THE TRAP this exists to kill:** comparing a *local* tray index against `tray_now` — as `presentDashboard` used to — is right only by coincidence for unit 0, and lights the HT's tray whenever AMS-0 slot 0 prints (both are local id 0). Every "is this tray active / load this tray" question must route through `globalTrayId`.

Test vectors: `globalTrayId(0,0)=0`, `(0,3)=3`, `(1,0)=4`, `(1,3)=7`, `(128,0)=128`, `(129,0)=129`.

Bambuddy decodes the reverse direction as: `gid >= 254` → external spool, `gid >= 128` → HT, else `gid // 4` (unit), `gid % 4` (slot).

#### 1.2 Extruder side convention

```ts
export const extruderSide = (e: number | null | undefined): '' | 'Left' | 'Right' =>
  e === 0 ? 'Right' : e === 1 ? 'Left' : '';
```

**0 = RIGHT/main, 1 = LEFT** on the H2 series — same convention as `active_extruder` and the nozzle rack. Centralised because getting it backwards is easy and silent: **the AMS tab shipped it inverted.** Anything else (null, undefined, 2, -1) returns `''` so callers render nothing rather than guessing.

#### 1.3 Routing state: `fixed` vs `switch`

```ts
export type AmsRouting = 'fixed' | 'switch';

const mapped = status?.ams_extruder_map ?? {};
const everyUnitMapped = raw.every((u) => typeof mapped[String(asNum(u.id) ?? 0)] === 'number');
const routing: AmsRouting =
  status?.fila_switch?.installed === true || !everyUnitMapped ? 'switch' : 'fixed';
const extMap = routing === 'switch' ? {} : mapped;   // stale residue — ignore wholesale
```

Two hard-won facts encoded here:

1. **`ams_extruder_map` is stale residue, not current routing.** Bambuddy builds it from each unit's `info` bits and **skips units reporting `0xE` ("no fixed extruder")** — exactly what an FTS-routed unit reports, permanently. The map is **merge-only and never pruned**, so on the live machine it still reads `{"0":0,"128":1}` from before the switch was fitted, while unit 1 (added after) can never gain an entry. Reading it as current routing shows two units a stale binding and the third nothing at all. Bambuddy's own UI and queue scheduler drop the per-extruder filter whenever the switch is installed; this does the same.
2. **`fila_switch` alone is not a sufficient signal — it is ABSENT from the WebSocket payload** (verified live: REST carries it, the WS feed does not), and the app runs on the WebSocket. Keying solely on it meant the live app fell back to the stale map and painted every unit-0 slot "→ Right". **An INCOMPLETE map is itself the tell**: a map covering some units but not others cannot describe static wiring, whichever transport delivered it. A single unmapped unit is enough to distrust the whole map.

When routing is `'switch'`, **every** `AmsUnitVM.extruder` is `null` (the UI renders "→ auto" instead), and per-slot routing comes from the switch (§1.4). An unmapped unit is `null`, never defaulted to `0` — extruder 0 is a REAL head (the right one), so defaulting would invent a binding.

#### 1.4 `switchExtruderForTray` — live routing through the Filament Track Switch

```ts
export function switchExtruderForTray(status: PrinterStatus | null, globalId: number): number | null {
  const fs = status?.fila_switch;
  if (fs?.installed !== true) return null;
  const track = (fs.in_slots ?? []).indexOf(globalId);
  if (track < 0) return null;
  const out = (fs.out_extruders ?? [])[track];
  return typeof out === 'number' && out !== 0xe ? out : null;   // 0xE (14) = documented "no outlet"
}
```

The FTS has **TWO tracks regardless of how many AMS units are chained in**. `in_slots[track]` is the **global tray id** loaded on that track (`-1` = empty); `out_extruders[track]` is the nozzle that track terminates at. So the answer is a lookup by index. This mirrors Bambuddy's own web UI exactly. With a switch fitted this is the *only honest routing answer*: units no longer belong to a nozzle, but a **loaded tray is on a track, and the track has an outlet**. Only trays currently threaded through the switch have one.

Live owner values: `{ installed: true, in_slots: [-1, 1], out_extruders: [1, 0] }` — track 0 empty → left; track 1 holds global tray 1 → extruder 0 (Right). Must survive malformed/short arrays (`{installed:true}`, `in_slots:[1]` with no `out_extruders`, `out_extruders: []`) by returning `null`.

> Note: `types.ts` documents `in_slots` as "packed `(ams_id << 8) | slot`", but the **implementation and the live data treat it as a plain global tray id** (`indexOf(globalId)` with `in_slots: [-1, 1]` matching global tray 1). Port the implementation, not the comment.

#### 1.5 `presentAms` — the whole algorithm

Returns `{ units: AmsUnitVM[]; slots: AmsSlotVM[]; routing: AmsRouting }`. Empty/absent AMS → `{ units: [], slots: [], routing: 'fixed' }` (never a crash).

```ts
const isHt = (u) => u.is_ams_ht === true || (asNum(u.id) ?? 0) >= 128;
const htTotal = raw.filter(isHt).length;
const trayNow = asNum(status?.tray_now);

function labelFor(unitId, kind, htIndex, htTotal) {
  if (kind === 'ht') return htTotal > 1 ? `AMS HT ${htIndex + 1}` : 'AMS HT';
  return `AMS ${unitId + 1}`;                 // from the STABLE id, not array position
}
```

Per unit (`AmsUnitVM`):

| field | derivation |
|---|---|
| `id` | `asNum(unit.id) ?? 0` — **RAW unit id** (0..3 regular, 128+ HT). Drying/load endpoints expect this, NOT an index. |
| `label` | `labelFor(...)` → `"AMS 1"`, `"AMS 2"`, `"AMS HT"`, `"AMS HT 1"/"AMS HT 2"` |
| `kind` | `'ht'` if `isHt(unit)` else `'ams'` |
| `capacity` | `unit.tray.length` (4 for AMS 2 Pro, 1 for HT) |
| `loaded` | `trays.filter(t => !!t.tray_type).length` |
| `maxDryTemp` | `kind === 'ht' ? 85 : 65` |
| `humidity` | `asNum(unit.humidity)` |
| `tempC` | `asNum(unit.temp)` |
| `extruder` | `typeof extMap[String(id)] === 'number' ? extMap[String(id)] : null` |
| `serialTail` | `serial && serial !== 'N/A' ? serial.slice(-4) : ''` — the only way to tell two identical AMS 2 Pro units apart |
| `dryingMinLeft` | `Math.max(0, Math.round(asNum(unit.dry_time) ?? 0))` |

**Gotcha:** `htTotal` counts with the **same predicate** used to classify (`isHt`). An earlier version counted `is_ams_ht === true` while `kind` also accepted `id >= 128`, so two HTs known only by their id both rendered a bare `"AMS HT"` and were indistinguishable.

Per tray (`AmsSlotVM`) — a **flat list in unit order**, so `DashVM.ams` and the Live Activity consume it unchanged:

| field | derivation |
|---|---|
| `label` | `empty ? 'Empty' : tray.tray_type ?? ''` |
| `color` | `empty ? null : normColor(tray.tray_color)` — **null means unknown**. The old `'#3A3F45'` fallback was a literal dark grey that never adapted to the light theme and claimed a colour we do not know. |
| `pct` | `empty ? '—' : \`${Math.round(asNum(tray.remain) ?? 0)}%\`` |
| `active` | `!empty && trayNow != null && trayNow === globalId` |
| `empty` | `!tray.tray_type` |
| `unitId`, `unitLabel` | from the unit |
| `localId` | `asNum(tray.id) ?? 0` — index INSIDE its unit (what `SlotAssignment` stores) |
| `globalId` | `globalTrayId(id, localId)` |
| `extruder` | `routing === 'switch' ? switchExtruderForTray(status, globalId) : (extMap[String(id)] ?? null)` |

An empty tray is **never active**, even when `tray_now` matches its global id.

#### 1.6 `amsTrayRefs` — flat tray list with raw values

```ts
export interface AmsTrayRef {
  unitId: number; unitLabel: string; localId: number;
  globalId: number;          // tray_now / ams/load tray_id / ams_mapping VALUES
  trayType?: string; trayColor?: string;   // RAW, unformatted
}
export function amsTrayRefs(status: PrinterStatus | null): AmsTrayRef[]
```

Built from `presentAms(status).slots`, re-joining the raw unit by id and the raw tray by `localId`. Keeps **raw** `tray_type`/`tray_color` (not the presented strings) because preset matching and colour fallback need unformatted values. Exists because callers kept reaching for `status.ams[0].tray` — with three units fitted that hides **5 of 9 slots** and makes them unprintable.

#### 1.7 Consumer contracts that depend on this math

- **`ams_mapping`** (print start, `POST /api/v1/queue/`) is Bambu's own field: **indexed by FILAMENT, valued by GLOBAL tray id**. Current code sends `const mapping = [slot]`. The old `Array(4).fill(-1); mapping[slot] = 0` had **index and value swapped**, so it debited the wrong spool and could not address anything past the first unit.
- **`amsLoad`** → `POST /api/v1/printers/{printerId}/ams/load?tray_id={globalId}`. Bambuddy documents tray ids **0–15 only**, so the **Load button stays hidden for HT units** (`kind === 'ht'`) until confirmed on hardware; reads and drying are unaffected.
- **`amsUnload`** → `POST /api/v1/printers/{printerId}/ams/unload`.
- **Inventory slot assignments** are stored per `(ams_id, LOCAL tray_id)`. Matching on `tray_id` alone resolves the HT's spool to AMS-0's (both have tray 0). Resolution order: prefer `tray_uuid` (RFID), then `(ams_id, localId)`.
- Slot naming in the UI: `vm.amsUnits.length > 1 ? \`${unitLabel} · Slot ${localId + 1}\` : \`Slot ${localId + 1}\`` — "Slot 1" is ambiguous across units.

---

### 2. AMS dryer VM — `src/ams/dryer.ts`

Mirrors Bambuddy's semantics for AMS 2 Pro / AMS-HT filament drying.

#### 2.1 Constants (exact)

```ts
export const DRY_BLOCKERS: Record<number, string> = {
  0: 'Printer is busy',
  1: 'Not enough power — too many AMS units drying, or the external PSU is required',
  2: 'AMS is busy',
  3: 'Filament is at the AMS outlet — retract it first',
  4: 'A drying cycle is already starting',
  5: 'Not supported in 2D mode',
  6: 'Already drying',
  7: 'AMS firmware is updating',
  8: 'Plug in the external AMS power adapter to start drying',
};

export const DRY_DEFAULTS: Record<string, { temp: number; hours: number }> = {
  PLA:  { temp: 55, hours: 8 },
  PETG: { temp: 65, hours: 8 },
  TPU:  { temp: 60, hours: 8 },
  ABS:  { temp: 75, hours: 8 },
  ASA:  { temp: 75, hours: 8 },
  PC:   { temp: 80, hours: 10 },
  PA:   { temp: 80, hours: 12 },
  PVA:  { temp: 70, hours: 10 },
  PET:  { temp: 70, hours: 10 },
};
const GENERIC_DRY = { temp: 55, hours: 8 };

export const DRY_MIN_TEMP = 45;
export const DRY_MAX_HOURS = 24;
```

```ts
/** "PETG-CF" -> PETG defaults when there's no exact entry. */
export function dryDefaultFor(type: string) {
  return DRY_DEFAULTS[type] ?? DRY_DEFAULTS[type.split('-')[0]] ?? GENERIC_DRY;
}
const clampTemp  = (t: number, max: number) => Math.min(Math.max(Math.round(t), DRY_MIN_TEMP), max);
const clampHours = (h: number) => Math.min(Math.max(Math.round(h), 1), DRY_MAX_HOURS);
```

Test vectors: `dryDefaultFor('PETG') === DRY_DEFAULTS.PETG`; `'PETG-CF'` → PETG; `'PLA-CF'` → PLA; `'WEIRDIUM'` → `{temp:55,hours:8}`.

#### 2.2 Which units get a dryer card (fail-open, per unit)

```ts
function unitCanDry(u: AmsUnit): boolean {
  return u.is_ams_ht === true || u.module_type === 'n3f'
    || u.dry_time !== undefined || u.dry_target_temp !== undefined || u.dry_filament !== undefined;
}
export function presentDryer(status: PrinterStatus | null): DryerVM[] {
  if (!status?.supports_drying || !status.ams?.length) return [];
  return status.ams.filter(unitCanDry).map(/* … */);
}
```

**Gotcha:** `supports_drying` is **PRINTER-level** — a heaterless first-gen AMS (`module_type: 'f1'`) on the same hub must not get a drying card. Fail-open per unit: real dryers always publish `dry_time` (verified live on the AMS 2 Pro), and `is_ams_ht` / `module_type: "n3f"` identify the drying models explicitly. A `n3f` unit with no `dry_*` fields yet still gets a card (`active: false`, `maxTemp: 65`).

#### 2.3 Per-unit derivation

```ts
const isHt = unit.is_ams_ht === true;                      // NOTE: id>=128 is NOT used here
const maxTemp = isHt ? 85 : 65;
const remainingMin = Math.max(0, Math.round(asNum(unit.dry_time) ?? 0));
const active = remainingMin > 0;
```

**THE REAL-WORLD TRAP:** *"actively drying" is `dry_time > 0` (minutes remaining). `dry_status` is NOT reliable — observed `0` mid-cycle on the live AMS 2 Pro.* Never use `dry_status` as the active flag.

**Options** (dedupe by filament type across the unit's trays; a tray with real preset data beats a `0/0` sibling):

```ts
const byType = new Map<string, DryOption>();
for (const tray of unit.tray ?? []) {
  const type = tray.tray_type; if (!type) continue;
  const presetTemp  = asNum(tray.drying_temp) ?? 0;
  const presetHours = asNum(tray.drying_time) ?? 0;
  const fromPreset  = presetTemp > 0;
  const fallback = dryDefaultFor(type);
  const opt = {
    type,
    color: normColor(tray.tray_color),
    temp:  clampTemp(fromPreset ? presetTemp : fallback.temp, maxTemp),
    hours: clampHours(fromPreset && presetHours > 0 ? presetHours : fallback.hours),
    fromPreset,
  };
  const prev = byType.get(type);
  if (!prev || (opt.fromPreset && !prev.fromPreset)) byType.set(type, opt);
}
const options = [...byType.values()];   // insertion order preserved
```

`drying_time` from the preset is in **HOURS**. The AMS 2 Pro's heater tops out at **65°C**; only the AMS-HT reaches **85°C**. **Bambuddy validates the wider 45–85 range for both, so the clamp must happen client-side** (a `PLA-S` tray whose preset says 70° must be sent as 65° on an AMS 2 Pro).

**Target temperature and stage:**

```ts
const filament = unit.dry_filament ?? '';
let targetTemp = asNum(unit.dry_target_temp);
if (targetTemp != null && targetTemp <= 0) targetTemp = null;      // <-- critical
if (active && targetTemp == null && filament) {
  targetTemp = options.find((o) => o.type === filament)?.temp ?? null;
}
const stage = active && targetTemp != null && tempC != null
  ? (tempC < targetTemp - 3 ? 'heating' : 'holding')
  : null;
```

**Gotcha (user-reported bug):** "unknown target" arrives as `null` over REST but as **`0` over the WebSocket** (different Bambuddy serializers — verified live). A real drying target is 45–85 °C, so anything `<= 0` is unknown; without the guard the active card rendered **"holding 0°"**. When the cycle was started outside Bambuddy (printer screen / Bambu Handy), the best estimate is the recommendation for `dry_filament`.

Hysteresis is **3 °C**: `heating` below `target − 3`, `holding` at/above it.

**Blockers:**

```ts
const blockers = (unit.dry_sf_reason ?? [])
  .map((code) => { const n = asNum(code); return n != null && n !== 6 ? DRY_BLOCKERS[n] : undefined; })
  .filter((m): m is string => !!m);
```

Code **6 ("Already drying") is deliberately omitted** — the active card already conveys it. Unknown codes are dropped silently. Codes may arrive as strings (`'8'`).

**`amsId` coercion:**

```ts
amsId: asNum(unit.id) ?? 0,
```

**Gotcha:** the WebSocket delivers ids as strings (`'128'`) while REST sends numbers. Leaving it raw made `amsUnits.find(u => u.id === d.amsId)` miss, so the HT's dryer card fell back to a positional label and announced itself as **"AMS 3"**.

Full `DryerVM`: `{ amsId, isHt, maxTemp, active, remainingMin, remainingText: fmtDuration(remainingMin), humidityPct: humidity != null ? Math.round(humidity) : null, tempC, targetTemp, filament, stage, blockers, options }`.

#### 2.4 Dryer UI contract + endpoints (state machine of the card)

- **Endpoints:**
  `POST /api/v1/printers/{printerId}/drying/start?ams_id={amsId}&temp={°C}&duration={HOURS}[&filament={type}][&rotate_tray={bool}]`
  `POST /api/v1/printers/{printerId}/drying/stop?ams_id={amsId}`
  **`duration` is HOURS** — Bambuddy validates 1–24; minutes would 400. A blocked start returns **409** with a human reason.
- **Stepper bounds:** temp ± 5 clamped to `[DRY_MIN_TEMP (45), d.maxTemp]`; duration ± 1 clamped to `[1, DRY_MAX_HOURS (24)]`. Defaults if nothing resolves: 55 °C / 8 h. `rotate` (spool rotation for even heat) defaults **true**.
- **Manual tweaks are KEYED to the filament type they were made for.** The options list is live (WS tray updates): if the selected spool is pulled mid-config, `opt` silently falls back to another filament, and **stale absolute numbers must NOT carry over — a PA temp applied to PLA deforms the spool.** A tweak whose `type` no longer matches the resolved option is ignored. Selecting a filament re-follows its recommendation (clears the tweak).
- Start is disabled when `busy || d.blockers.length > 0 || !d.options.length`.
- **Post-start verification (silent-failure guard):** Bambuddy answers 200 as soon as the MQTT command is *sent*; the printer can still refuse it (observed live: `result:'failed'`, `reason:'mqtt message verify failed'` when LAN Developer Mode is off) and nothing surfaces. After **9000 ms**, re-fetch status and if `Number(unit.dry_time ?? 0) > 0` is false, alert: *"Drying didn't start — The printer rejected the command ("mqtt message verify failed"). Newer Bambu firmware requires LAN Developer Mode for this: on the printer's screen, enable Settings → Network → Developer Mode, then try again."*
- Layout rule: **active cycles get their own card**; idle units collapse behind one disclosure row when there are ≥2 (three units meant three identical "Dry damp spools right in the AMS." cards pushing the actual filament off screen). One idle unit renders directly — wrapping a single card in a disclosure is a wasted tap.
- Active-card copy: `"Drying {filament || 'filament'}"`, `remainingText` + `" left"`, chip `heating to {targetTemp}°` / `holding {targetTemp}°`, humidity chip `{humidityPct}%`. Card tint `c.heatingDim` bg / `c.heating` border. Idle expanded subtitle: `"This AMS dries up to {maxTemp}°C."`; collapsed: `"Dry damp spools right in the AMS."`. Start button label: `"Start drying — {effTemp}° for {effHours}h"`.

---

### 3. Plate cooldown model — `src/cooling/present.ts`

**The single source of truth for "is the plate cool enough yet".** Pure.

#### 3.1 Why the thresholds are what they are

The one number any vendor publishes is Bambu's own, for the Textured PEI plate: *"we always recommend waiting until it reaches 35℃ or lower"*, stated for the **HEATBED** — exactly the sensor read (`PrinterStatus.temperatures.bed`). Everything else in circulation is either a bed *setpoint* (55–80 °C, a different quantity) or an unsourced extrapolation.

Two traps this module exists to avoid:

1. **A threshold at or below room temperature can NEVER be reached** — a passively cooling plate approaches ambient asymptotically and cannot cross it. Picking a "safely cool" 25 °C means the notification silently never fires. The owner's office sits around 28 °C, so even 35 °C is only a few degrees of headroom. Hence the `stalled` phase.
2. **Glass transition is a poor predictor of release** (PLA releases ~25 °C below Tg, PETG can stay welded to smooth PEI 45 °C below it, TPU has no Tg above room temperature at all). **There is no per-material threshold table on purpose. Material only ever changes the WORDING.**

```ts
export const COOLDOWN_DEFAULT_C = 35;   // Bambu's published figure, textured PEI
export const COOLDOWN_MIN_C = 30;       // below this it collides with room temp
export const COOLDOWN_MAX_C = 45;       // burn ceiling; EN ISO 13732-1 ≈ 51°C for 1-min bare-metal contact
export const NOZZLE_CAUTION_C = 50;     // warn only — never blocks "ready"
export const PLATEAU_WINDOW_MIN = 10;
export const PLATEAU_DELTA_C = 1.0;
export const RATE_WINDOW_MIN = 20;      // trailing window for the CURRENT decay rate
export const ETA_MAX_LEAD_C = 10;       // no estimate above threshold + 10
export type CooldownPhase = 'none' | 'cooling' | 'ready' | 'stalled';
```

`ETA_MAX_LEAD_C` rationale (measured against a real 89-minute cooldown): with a known ambient the estimate lands within ~6 minutes of truth from 45 °C down, but runs **27–45 % optimistic while the plate is above 50 °C**. Real plate cooling is not a single exponential — plate, chamber and room have different time constants — so an early extrapolation always runs fast. Show nothing rather than a number wrong by half.

#### 3.2 Input normalisation

```ts
export function clampThreshold(c: unknown): number {
  const n = typeof c === 'string' ? Number(c) : c;
  if (typeof n !== 'number' || !isFinite(n)) return COOLDOWN_DEFAULT_C;
  return Math.min(COOLDOWN_MAX_C, Math.max(COOLDOWN_MIN_C, n));
}

const asC = (v: unknown): number | null => {
  const n = typeof v === 'string' ? Number(v) : v;
  return typeof n === 'number' && isFinite(n) ? n : null;
};

export function normalizeSamples(raw): BedSample[] {     // BedSample = { t: epochMs, c: °C }
  const out: BedSample[] = [];
  for (const s of raw ?? []) {
    const t = asC(s?.t); const c = asC(s?.c);
    if (t != null && c != null) out.push({ t, c });
  }
  out.sort((a, b) => a.t - b.t);
  return out.filter((s, i) => i === 0 || s.t !== out[i - 1].t);   // dedupe by timestamp
}
```

#### 3.3 `parseBedHistory` — the UTC trap

```ts
export function parseBedHistory(h: SensorHistory | null | undefined): BedSample[] {
  const pts = h?.series?.[0]?.data ?? [];
  const out = [];
  for (const p of pts) {
    const raw = p?.recorded_at;
    if (typeof raw !== 'string' || !raw) continue;
    const iso = /([zZ]|[+-]\d\d:?\d\d)$/.test(raw) ? raw : `${raw}Z`;
    out.push({ t: Date.parse(iso), c: p?.value });
  }
  return normalizeSamples(out);
}
```

**Gotcha:** **Bambuddy timestamps are NAIVE and expressed in UTC** (`"2026-08-01T11:57:57"`, no zone marker). JavaScript parses a bare datetime like that as **LOCAL** time, which silently shifts the entire curve by the UTC offset — an hour here — corrupting every rate, ETA and plateau check while looking perfectly plausible. So the zone is appended explicitly unless one is already present. Test: `parseBedHistory(...'2026-08-01T11:57:57'...)[0].t === Date.UTC(2026, 7, 1, 11, 57, 57)`.

Endpoint: `GET /api/v1/printer-sensor-history/{printerId}?hours={h}&kinds={bed|nozzle|nozzle_2|chamber}` (hours capped at 168 server-side; the client swallows errors and returns `null`).

#### 3.4 `estimateAmbient` — room temperature is MEASURED, never fitted

```ts
export function estimateAmbient(temps: Array<number | null | undefined>, pct = 0.05): number | null {
  const s = temps.filter((n): n is number => typeof n === 'number' && isFinite(n) && n > 0)
                 .sort((a, b) => a - b);
  if (s.length < 60) return null;                                  // needs hours of history
  const v = s[Math.min(s.length - 1, Math.floor(s.length * pct))];
  return v >= 0 && v <= 45 ? v : null;                             // no room is 90°C
}
```

Between prints the plate always settles to ambient, so the **low percentile of idle bed readings over a long window IS the room**. Takes the **5th percentile rather than the minimum** so one cold night or one bad reading cannot drag it down.

**This replaces solving for ambient from the cooling curve itself, which sounds elegant and does not work.** Fitted against the real measured cooldown it returned **39.9 °C for a 28.5 °C room while the plate was still at 56 °C** — which declared the plate "as cool as it will get" less than ten minutes after the print ended. The curve does not identify its own asymptote early on; the idle floor does, directly. Ported code must keep this regression test.

#### 3.5 `fitDecayRate` — one free parameter, trailing window only

```ts
export function fitDecayRate(samples: BedSample[], ambientC: number, nowMs: number): number | null {
  const win = samples.filter((s) => nowMs - s.t <= RATE_WINDOW_MIN * 60000);
  if (win.length < 5) return null;
  const spanMin = (win[win.length - 1].t - win[0].t) / 60000;
  if (!(spanMin >= 5)) return null;

  const t0 = win[0].t;
  let sx = 0, sy = 0, sxx = 0, sxy = 0;
  for (const s of win) {
    if (s.c - ambientC <= 0.5) return null;   // at/below ambient: no rate info, breaks the log
    const x = (s.t - t0) / 60000;
    const y = Math.log(s.c - ambientC);
    sx += x; sy += y; sxx += x * x; sxy += x * y;
  }
  const n = win.length;
  const denom = n * sxx - sx * sx;
  if (Math.abs(denom) < 1e-9) return null;
  const slope = (n * sxy - sx * sy) / denom;
  const k = -slope;
  return isFinite(k) && k > 0 ? k : null;
}
```

Given a **known** ambient there is one free parameter instead of two, so ordinary least squares on `ln(T − ambient)` vs minutes is well conditioned even against whole-degree readings (the printer never reports fractions). Deliberately uses **only a trailing 20-minute window** — `k` is not constant across a real cooldown (it fell from **0.038 to 0.021 over 89 measured minutes**), and what matters for a short extrapolation is how fast the plate is losing heat **now**.

Guards: `<5` samples → null; window span `<5` min → null; any sample within 0.5 °C of ambient → null; degenerate denominator → null; non-positive or non-finite `k` → null.

#### 3.6 `etaToThreshold`

```ts
export function etaToThreshold(fit: CoolingFit | null, bedC: number, thresholdC: number): number | null {
  if (bedC <= thresholdC) return 0;
  if (!fit) return null;
  if (fit.ambientC >= thresholdC) return null;                 // asymptote: unreachable, ever
  if (bedC > thresholdC + ETA_MAX_LEAD_C) return null;         // too far out to be honest
  const mins = Math.log((bedC - fit.ambientC) / (thresholdC - fit.ambientC)) / fit.kPerMin;
  if (!isFinite(mins) || mins < 0) return null;
  return Math.min(600, mins);                                  // cap at 10 h
}
```

Accuracy contract proven by the fixture test: over the real curve, **every minute it speaks the absolute error is ≤ 8 minutes**, it is within 25 % whenever ≥15 minutes remain, and it **speaks for more than 30 of the ~72 minutes**. It says **nothing** for the first 25 minutes.

#### 3.7 `hasPlateaued`

```ts
export function hasPlateaued(samples: BedSample[], nowMs: number): boolean {
  const win = samples.filter((s) => nowMs - s.t <= PLATEAU_WINDOW_MIN * 60000);
  if (win.length < 3) return false;
  if ((win[win.length - 1].t - win[0].t) / 60000 < PLATEAU_WINDOW_MIN * 0.8) return false;  // must span ≥8 min
  const temps = win.map((s) => s.c);
  return Math.max(...temps) - Math.min(...temps) < PLATEAU_DELTA_C;   // < 1.0 °C
}
```

The window must actually be spanned — **three samples in ten seconds prove nothing**.

#### 3.8 `materialCaution` — wording only, never the threshold

```ts
export function materialCaution(material: string | null | undefined): string | null {
  const m = (material || '').toUpperCase();
  if (!m) return null;
  if (m.includes('TPU')) return 'TPU never pops off on its own — lift a corner and let isopropyl wick underneath.';
  if (m.includes('ABS') || m.includes('ASA') || m.includes('PC') || m.startsWith('PA') || m.includes('NYLON'))
    return 'Keep the door shut until the chamber cools too, or the part can warp as it contracts.';
  if (m.includes('PETG')) return 'PETG can bond hard to smooth PEI — on a smooth plate, ease it off rather than forcing it.';
  return null;
}
```

Substring matching so `"PLA-CF"`, `"PETG HF"`, `"Bambu ABS"`, `"PA6-CF"`, `"PAHT-CF"` all land correctly. PLA and unknown materials return `null`. **Order matters** (PC/PA before PETG is irrelevant here, but ABS-family precedes PETG).

#### 3.9 `fmtMin` — deliberate imprecision

```ts
const fmtMin = (m: number): string => {
  let r = Math.round(m);
  if (r >= 10) r = Math.round(r / 5) * 5;         // 5-minute steps above 10 min
  if (r <= 1) return 'under a minute';
  if (r < 60) return `about ${r} min`;
  const h = Math.floor(r / 60), rem = r % 60;
  return rem ? `about ${h} h ${rem} min` : `about ${h} h`;
};
```

Measured error is about ±6 min, so *"about 35 min"* is honest where *"34 min"* would be false precision.

#### 3.10 `presentCooldown` — the phase state machine

```ts
export function presentCooldown(input: CooldownInput): CooldownVM
// CooldownInput = { printing, bedC, nozzleC?, thresholdC?, samples?, ambientC?, material?, nowMs? }
```

Evaluation order (short-circuiting):

1. `thresholdC = clampThreshold(input.thresholdC)`; `bedC = asC(input.bedC)`; `nowMs = input.nowMs ?? Date.now()`; `samples = normalizeSamples(input.samples)`; `caution = materialCaution(input.material)`.
2. **`none`** if `input.printing || bedC == null || bedC <= 0`. VM: `{ phase:'none', bedC: bedC ?? 0, thresholdC, etaMin:null, ambientC:null, label:'', detail:'', progress:0, tone:'hot', caution:null }`. *Gotcha:* a bed reading of **0 means "no data" far more often than "the plate is frozen"** — `temperatures` is nullable and missing fields round to 0 upstream.
3. Compute `kPerMin = ambientC != null ? fitDecayRate(samples, ambientC, nowMs) : null`; `fit = (ambientC != null && kPerMin != null) ? {ambientC, kPerMin} : null`; `etaMin = etaToThreshold(fit, bedC, thresholdC)`.
4. `peak = samples.length ? Math.max(bedC, ...samples.map(s => s.c)) : bedC`; `progress = peak > thresholdC ? clamp01((peak - bedC) / (peak - thresholdC)) : 1`.
5. `hotNozzle = nozzleC != null && nozzleC > NOZZLE_CAUTION_C`; `nozzleNote = hotNozzle ? \` The nozzle is still at ${Math.round(nozzleC)}°C.\` : ''`.
6. **`ready`** if `bedC <= thresholdC`:
   `label: 'Plate is cool'`, `etaMin: 0`, `progress: 1`, `tone: 'ready'`,
   `detail: \`Bed at ${Math.round(bedC)}°C — safe to flex the plate and lift the print off.${nozzleNote}\``
   *Deliberately "safe to flex", not "it has popped off"* — plenty of prints stay stuck at room temperature, and over-promising invites someone to force it and tear the PEI coating. The test asserts the detail never matches `/popped|released itself|fell off/i`.
7. **`stalled`** if `hasPlateaued(samples, nowMs) || (ambientC != null && ambientC >= thresholdC)`:
   `label: 'As cool as it will get'`, `etaMin: null`, `tone: 'warm'`, `progress` as computed,
   `detail: \`Bed has settled at ${Math.round(bedC)}°C and is no longer dropping.${room} Go ahead and flex the plate.${nozzleNote}\`` where `room = ambientC != null ? \` The room is around ${Math.round(ambientC)}°C.\` : ''`.
   Both conditions are **observations**, nothing extrapolated.
8. **`cooling`** otherwise:
   `label: 'Plate cooling'`, `tone: bedC > thresholdC + 15 ? 'hot' : 'warm'`,
   `detail: etaMin == null ? \`Bed at ${Math.round(bedC)}°C, heading for ${thresholdC}°C.\` : \`Bed at ${Math.round(bedC)}°C — ${fmtMin(etaMin)} until it is easy to remove.\``.

**A hot nozzle never blocks readiness** — the plate is what you touch, and it cools far slower than the nozzle.

#### 3.11 Rendering contract (`CooldownPanel`, `DashboardView.tsx`)

Rendered only when `phase !== 'none'`. Tint: `tone === 'ready' → c.running` (`#30D158` dark / `#23B24A` light), `'hot' → c.heating` (`#FF9F0A` / `#E0860A`), `'warm' → c.accent` (`#2BD4C0` / `#0EAE9C`). Card bg `c.s2`, border `phase === 'ready' ? c.running : c.line`. Icon `check-circle` when ready else `thermometer`. Progress bar height 5, radius 3, track `c.s3`, fill width `${Math.round(progress*100)}%` in `tint`. Caution row uses `c.heating` with an `alert-triangle`.

#### 3.12 `useCooldown` — the stateful wrapper (`src/cooling/useCooldown.ts`)

```ts
const CURVE_POLL_MS = 60_000;       // refresh the cooling curve while cooling
const CURVE_HOURS = 3;              // covers a whole cooldown plus the print before it
const AMBIENT_HOURS = 24;           // room temp read off the idle floor
const AMBIENT_REFRESH_MS = 30 * 60_000;
const isPrinting = (state?: string) =>
  ['RUNNING','PAUSE','PAUSED','PREPARE','SLICING'].includes((state || '').toUpperCase());
```

Three effects:

1. **Ambient loop** — keyed on `(client, printerId)`, runs immediately then every 30 min: `sensorHistory(printerId, 'bed', 24)` → `parseBedHistory` → `.map(s => s.c)` → `estimateAmbient`. Errors swallowed (keeps last value).
2. **Curve loop** — `active = !printing && typeof bedC === 'number' && bedC > 0`. When inactive, clears the curve and stops polling (no point pulling history for a printer mid-print or cold for hours). When active: load immediately, then every 60 s. **Seeds from the server's stored curve rather than only watching live readings, so opening the app halfway through a cooldown still gets a rate and an ETA instead of starting from nothing.**
3. **Live-sample ref** — appends `{ t: Date.now(), c: bedC }` on every status change, pruning anything older than `CURVE_HOURS`; cleared when inactive. **The stored curve lags by up to a minute, so the live reading is folded in — without this the plateau detector could see a stale flat tail and call a still-falling plate "settled."**

Final: `presentCooldown({ printing, bedC, nozzleC: status?.temperatures?.nozzle ?? null, ambientC, samples: [...curve, ...liveRef.current], material: activeMaterial(status) })`.

```ts
/** Filament in the tray the printer was last using. Wording only. */
function activeMaterial(status: PrinterStatus | null): string | null {
  const now = status?.tray_now;
  if (typeof now !== 'number' || now === 255) return null;     // 255 = none / external spool
  for (const unit of status?.ams ?? [])
    for (const tray of unit.tray ?? [])
      if (globalTrayId(unit.id, tray.id) === now) return tray.tray_type ?? null;
  return null;
}
```

Note: this is absent for an external spool and singular for a multi-material print — which is fine, because it never moves the threshold. **No user-facing setting currently writes `thresholdC`; it always resolves to 35 °C** — but the clamp and the parameter are load-bearing and must be ported.

---

### 4. Smart plug automations — `src/power/present.ts`

Bambuddy runs these rules server-side and switches the plug with nobody watching. **Writes to `/smart-plugs/{id}` are admin-only (a scoped API key gets 403), so the app can only ever REPORT them.** This used to be a toggle wired to nothing but local state.

```ts
export interface PlugAutomation {
  key: 'auto_on' | 'auto_off' | 'after_drying' | 'schedule';
  label: string;
  detail: string;
  cuts: boolean;    // marks the DANGEROUS direction: it can kill power to a running print
}

const hhmm = (t?: string | null): string | null =>
  (/^([01]\d|2[0-3]):[0-5]\d$/.test(t ?? '') ? (t as string) : null);
```

`plugAutomations(plug)` returns armed rules **in this exact order** — `null`/`undefined` plug → `[]`:

| order | condition | label | detail | `cuts` |
|---|---|---|---|---|
| 1 | `plug.auto_on` | `Auto power-on` | `Switches on when a print starts.` | `false` |
| 2 | `plug.auto_off`, mode ≠ temperature | `Auto power-off` | `Switches off ${off_delay_minutes ?? 5} min after a print finishes.` | `true` |
| 2' | `plug.auto_off`, `off_delay_mode === 'temperature'` | `Auto power-off` | `Switches off after a print, once the hotend cools below ${off_temp_threshold ?? 70}°C.` | `true` |
| 3 | `plug.auto_off_after_drying` | `Off after drying` | `Switches off ${off_delay_after_drying_minutes ?? 10} min after AMS drying finishes.` | `true` |
| 4 | `plug.schedule_enabled` **and** at least one valid `HH:MM` | `Schedule` | `Switches ${parts.join(', ')} every day.` where parts are `on at ${on}` / `off at ${off}` | `!!off` |

If `auto_off_persistent` is true, the auto-off detail becomes `` `${detail} Survives a Bambuddy restart.` ``.

**Schedule gotchas:** a schedule counts as armed **only if it has a time to act on** — an enabled schedule with both fields `null` does nothing, and reporting it would be a phantom warning. Times must be **strictly zero-padded 24-hour `HH:MM`**: `"7:00"` is rejected, `"25:00"` and `"soon"` are rejected, `"00:00"` (midnight) is valid. An ON-only schedule cannot cut power (`cuts: false`).

Exact expected strings from the tests: `'Switches on at 07:00, off at 22:30 every day.'`, `'Switches on at 07:00 every day.'`.

```ts
export function otherPlugs(all, printerPlugId): SmartPlug[] {
  return (all ?? [])
    .filter((p) => p && p.id !== printerPlugId && p.enabled !== false)
    .sort((a, b) => a.id - b.id);
}
export function automationSummary(plug): string {
  const list = plugAutomations(plug);
  if (!list.length) return 'Nothing switches this plug automatically.';
  return list.map((a) => a.label).join(' · ');   // "Auto power-on · Auto power-off · Off after drying · Schedule"
}
export const plugLabel = (p) => p?.name?.trim() || (p ? `Plug ${p.id}` : 'Smart plug');
```

**Disabled plugs are dropped** (`enabled === false`) — Bambuddy will not act on them, so a dead row is just noise; a deleted HA entity can never report. **Gotcha (recent fix, commit `4bde037`):** the Power tab calls `otherPlugs(allPlugs, null)` — passing `null` **keeps the printer's own socket in the list**. All three sockets are on one physical strip (a P304M); excluding the printer's socket made it look absent even though it drives the big hero control above. The `printerPlugId` parameter is retained for callers that genuinely want only the peripherals.

#### 4.1 `usePlugState` — optimistic write with a settle window

```ts
export function usePlugState(client, plug, periodMs = 5000): PlugState
// PlugState = { on, reachable, watts, kwh, set(next): Promise<void> }
```

- Poll `GET /api/v1/smart-plugs/{id}/status` immediately then every `periodMs` (printer hero uses the 5000 ms default, peripheral `PlugRow`s use **8000 ms** — background devices, not the thing you're watching).
- Mapping: `on = s.state?.toUpperCase() === 'ON'`; `reachable = !!s.reachable`; `watts = typeof s.energy?.power === 'number' ? s.energy.power : null`; `kwh = typeof s.energy?.today === 'number' ? s.energy.today : null`. A rejected fetch sets `reachable = false` (and leaves the other values).
- **Settle window:** `set(next)` flips `on` immediately, sets `pendingUntil = Date.now() + 8000`, then `POST /api/v1/smart-plugs/{id}/control` with body `{"action": "on"|"off"}`. **While a toggle is settling, poll results are ignored** — Home Assistant takes a few seconds to reflect the new state and the stale poll would visibly bounce the switch back. On failure: `pendingUntil = 0`, revert `on = !next`, rethrow.
- Re-arming: the effect keys on `plug?.id`, so handing it a fresh plug object with the same id does **not** restart the poll; the Power tab's pull-to-refresh re-resolves the plug so a new id fires an immediate poll.

#### 4.2 Confirmation + energy-projection rules (consumer, `TabScreens.tsx`)

- **Switching ON is never confirmed.** Switching OFF always confirms: printer hero → *"Switch off the printer? / This cuts power at the smart plug. If a print is running, it will stop."*; peripheral row → *"Switch off {name}? / This cuts power at the smart plug."* (destructive style).
- Live-print cost projection, only when `state === 'RUNNING'` and `price != null && watts != null && remainMin != null && pct != null && 0 < pct < 100`:
  ```ts
  const elapsedMin = (remainMin * pct) / (100 - pct);   // total = elapsed + remain; pct = elapsed/total
  const kwhPerMin = watts / 1000 / 60;
  soFarCost = elapsedMin * kwhPerMin * price;
  projCost  = (elapsedMin + remainMin) * kwhPerMin * price;
  ```
  `price = settings.energy_cost_per_kwh`, `todayCost = kwh * price`.
- Row status text: `!reachable ? 'Unreachable' : on ? (watts == null ? 'On' : \`On · ${Math.round(watts)} W\`) : 'Off'`. The armed-automation line renders `armed.map(a => a.label).join(' · ')` in `c.heating`. The automation card icon is `clock` (in `c.heating`) when any rule `cuts`, else `shield` (in `c.t3`).
- Empty state fires only when `plug === null && !sockets.length`.

---

### 5. LAN Developer Mode gating — `src/capabilities/lanMode.ts`

#### 5.1 The problem being solved

Bambuddy reaches the printer over **LAN MQTT only**. With LAN Developer Mode off, the firmware rejects every message published to `device/{serial}/request` with **`"mqtt message verify failed"`** — while status reports keep flowing, so the app looks perfectly healthy. **Bambuddy does not check either: it returns success the moment `publish()` returns, so the API answers 200 and the UI renders a successful pause that never happened.** That silent lie is what this module exists to end.

#### 5.2 Tri-state, on purpose

```ts
export type LanMode = 'on' | 'off' | 'unknown';

export function lanModeFrom(status: Pick<PrinterStatus, 'developer_mode'> | null | undefined): LanMode {
  const v = status?.developer_mode;
  if (v === true) return 'on';
  if (v === false) return 'off';
  return 'unknown';
}
```

**`'unknown'` is NOT `'off'`.** The field is absent until the printer has reported, and a gate treating absence as "off" **greys out the whole UI on every cold start**. Only an explicit `false` disables anything. `null`, `undefined`, and a `null` status all map to `'unknown'`.

#### 5.3 The action set

```ts
export type ActionId =
  | 'pause' | 'resume' | 'stop' | 'light' | 'speed'
  | 'amsLoad' | 'amsUnload' | 'dryStart' | 'dryStop'
  | 'startPrint' | 'plateCleared' | 'printAgain'
  | 'plug' | 'camera' | 'maintenance' | 'queueRemove';

const BLOCKED: ReadonlySet<ActionId> = new Set([
  'pause', 'resume', 'speed', 'amsLoad', 'amsUnload', 'dryStart', 'dryStop', 'startPrint', 'printAgain',
]);

export function isBlocked(action: ActionId, mode: LanMode): boolean {
  return mode === 'off' && BLOCKED.has(action);
}
export function blockedActions(mode: LanMode): ActionId[] {
  return mode === 'off' ? [...BLOCKED] : [];
}
```

All nine blocked actions are `print.*` MQTT commands on the one verified topic — the same rejection applies to every one, which is why this is a set and not a per-command investigation.

**Deliberately NOT blocked, each for a specific documented reason:**

| action | why it stays live |
|---|---|
| `stop` | **THE EMERGENCY CONTROL.** A dead grey Stop on a print that is spaghettifying is actively dangerous. A Stop that *might* fail is strictly better than one that cannot be pressed. |
| `light` | the only control here that is not a `print` command — it publishes `system/ledctrl`, which the firmware does not verify the same way. |
| `camera` | RTSPS on its own port; verified streaming with Developer Mode off. |
| `plug` | a different device entirely, and the **real kill switch** when commands are refused. |
| `plateCleared`, `queueRemove`, `maintenance` | Bambuddy-side bookkeeping in its own database; the printer is never asked. |

#### 5.4 Copy (exact strings)

```ts
export const LAN_BANNER_TITLE = 'Printer controls are locked';
export const LAN_BANNER_BODY =
  "This printer won't accept commands until LAN Developer Mode is on. Monitoring, the camera and your library still work.";
export const LAN_BLOCKED_HINT =
  'Turn on LAN Developer Mode on the printer (Settings → Network), then re-enter its new access code in this app.';
export const LAN_HELP_TITLE = 'Turn on LAN Developer Mode';
export const LAN_HELP_BODY = [
  'Your printer reports status, streams the camera and accepts files, but rejects every command this app sends — pause, resume, speed, AMS, drying and starting a print. Its firmware requires signed commands unless Developer Mode is on.',
  '',
  'On the printer:',
  '1. Settings → Network → LAN Only Mode.',
  '2. Turn on Developer Mode and confirm.',
  '3. The printer shows a NEW access code.',
  '',
  'Then update the access code in Bambuddy, and this app will be able to control the printer again.',
].join('\n');
```

#### 5.5 Visual treatment

```ts
export const LOCKED_OPACITY = 0.4;
export const lockedStyle = (locked: boolean): { opacity: number } | null =>
  locked ? { opacity: LOCKED_OPACITY } : null;
```

**Dimming, not hiding**, keeps the UI stable and discoverable: the button stays where it was, and tapping it explains itself. **Gotcha:** it must return `null`, **not `{opacity: 1}`** — the style is spread into callers (`{ opacity: busy ? 0.5 : 1, ...lockedStyle(false) }`), and an `{opacity:1}` would clobber the caller's own opacity (e.g. the dryer buttons' busy state). A locked control additionally renders a `lock` icon.

The `'off'` banner (`c.heatingDim` bg, `c.heating` border, `lock` icon, chevron) is tappable and opens the `LAN_HELP_*` alert.

#### 5.6 `useLockedAction` — one decision applied to both look and tap

```ts
export function useLockedAction(lanMode: LanMode) {
  return useMemo(() => ({
    blocked: (a: ActionId) => isBlocked(a, lanMode),
    style:   (a: ActionId) => lockedStyle(isBlocked(a, lanMode)),
    press:   (a: ActionId, run: () => void) => () => {
      if (isBlocked(a, lanMode)) { Alert.alert(LAN_BANNER_TITLE, LAN_BLOCKED_HINT); return; }
      run();
    },
  }), [lanMode]);
}
```

**Single source of truth so a button can never look enabled while its handler is blocked (or the reverse).** Every gated control pairs `style(a)` with `press(a, run)`.

A **meta-test enforces this**: `lanMode.test.ts` reads every `.tsx` under `src/components` and `src/app` and asserts each `blockedActions('off')` id appears as a quoted literal somewhere. Adding an id to `BLOCKED` without giving it a visual treatment fails the suite rather than shipping a dead-looking button.

#### 5.7 `useLanMode` — fetched OUT-OF-BAND over REST

```ts
const POLL_MS = 5 * 60_000;
```

Deliberately **not** read from `usePrinterStatus`: that feed is WebSocket-primary, and **Bambuddy's WebSocket frame does not carry `developer_mode` at all** (`printer_manager.printer_state_to_dict` omits it). Reading it there would yield `undefined` on the happy path and a real value only while the socket was down — a gate that flickered exactly when the app was healthiest. So: `client.getStatus(printerId)` → `lanModeFrom(s)`, immediately, then every 5 minutes, **plus on every app foreground** (the usual fix is to walk to the printer and change the setting). **A failed fetch leaves the last known value** — a network blip must not grey out the UI. Also: a popover left open when the printer drops out of Developer Mode would strand enabled-looking rows, so `DashboardView` closes the speed popover when `lock.blocked('speed')` becomes true.

---

### 6. Printer profiles — `src/printers/profile.ts`

Model-keyed printer knowledge, so adding a printer is a table entry rather than scattered `'A1'` literals.

```ts
const TEXTURED    = { id: 'Textured PEI Plate',  label: 'Textured PEI' };
const SMOOTH      = { id: 'Smooth PEI Plate',    label: 'Smooth PEI' };
const COOL        = { id: 'Cool Plate',          label: 'Cool Plate' };
const ENGINEERING = { id: 'Engineering Plate',   label: 'Engineering' };
const HIGH_TEMP   = { id: 'High Temp Plate',     label: 'High Temp' };
```

The `id` is the **canonical `bed_type` the slicer expects** — send it verbatim.

| field | A1 | H2C | unknown model fallback |
|---|---|---|---|
| `presetToken` | `@BBL A1` | `@BBL H2C` | `` `@BBL ${model}` `` |
| `printerPresetBase` | `Bambu Lab A1` | `Bambu Lab H2C` | `` `Bambu Lab ${model}` `` |
| `amsLabel` | `AMS Lite` | `AMS 2 Pro` | `AMS` |
| `dualNozzle` | `false` | `true` | `(printer?.nozzle_count ?? 1) > 1` |
| `bedTypes` (first = default) | TEXTURED, SMOOTH, COOL, ENGINEERING | TEXTURED, SMOOTH, **HIGH_TEMP**, ENGINEERING | TEXTURED, SMOOTH, COOL, ENGINEERING |
| `plate` (mm, X width × Y depth) | `{ w: 256, d: 256 }` | `{ w: 350, d: 320 }` | `{ w: 256, d: 256 }` |
| `cameraHint` | `The A1's camera is on-demand and can be slow — give it a moment and tap Retry.` | `If this persists, enable LAN Mode Liveview in the printer's settings screen (Settings → General).` | `Give the camera a moment and tap Retry. Make sure the printer is powered on.` |

(The literal strings use a typographic apostrophe `’` in `A1’s` and `printer’s`.)

```ts
export function printerProfile(printer: Pick<Printer,'model'|'nozzle_count'> | null | undefined): PrinterProfile {
  const model = (printer?.model ?? 'A1').trim();
  const known = PROFILES[model.toUpperCase()];
  if (known) return known;
  return { /* generic, derived from the model string */ };
}
```

**Gotcha:** a null printer (list not loaded yet) falls back to **A1**; an *unknown* model degrades to a **generic** profile derived from the model string, **not** to A1 behaviour. Lookup is case-insensitive on the uppercased model.

#### 6.1 `slicedForMatchesPrinter` — the wrong-machine G-code guard

```ts
export function slicedForMatchesPrinter(embeddedPrinter: string | null | undefined, profile: PrinterProfile): boolean {
  const emb = (embeddedPrinter ?? '').trim().toUpperCase();
  if (!emb) return true;                                     // no data, no block
  const model = profile.printerPresetBase.replace('Bambu Lab ', '').toUpperCase();
  const embModel = emb.replace('BAMBU LAB ', '');
  return embModel === model || embModel.startsWith(`${model} 0.`);
}
```

Exact match, or exact followed by a **nozzle suffix** (`"A1 0.4 NOZZLE"`) — **but never a longer model name**. `"Bambu Lab A1 mini"` must NOT pass for the A1 (different machine). On mismatch the wizard refuses to start: *"Wrong printer — This file was sliced for {slicedFor}. Reslice it for {printer.name} before printing."*

Note the string surgery is done on `printerPresetBase`, so it strips the literal `"Bambu Lab "` prefix on both sides.

#### 6.2 Where the profile fields are consumed

- `presetToken` → filament/quality preset filtering (`@BBL <model>` is the suffix BambuStudio stamps).
- `printerPresetBase` → printer-preset selection with fallback chain: `` `${base} ${nozzle} nozzle` `` → `` `${base} 0.4 nozzle` `` → `base`. **Naming is asymmetric**: 0.4-nozzle presets carry NO nozzle suffix; 0.2/0.6/0.8 variants are suffixed.
- `bedTypes[0].id` is the wizard's initial `bed_type`.
- `plate` drives the G-code layer viewer's plate footprint and the library plate preview.
- `amsLabel` is the Hardware tab's section-right label when there is exactly one unit (multi-unit shows `"{n} units"`).
- `cameraHint` is the camera overlay's failure copy.

---

### Port notes

#### Direct 1:1 translations (pure value types — port as Swift structs/enums in a `BambuDomain` module with no UIKit/SwiftUI import, and port the Jest suites to XCTest verbatim)

| TS | Swift |
|---|---|
| `globalTrayId(unitId, localId)` | `func globalTrayID(unit: Int, local: Int) -> Int` — free function or `static` on `AMSTopology`. Trivial. |
| `extruderSide(e)` | `enum ExtruderSide: String { case right = "Right", left = "Left", none = "" }` with `init(rawExtruder: Int?)`. Prefer an enum over a stringly-typed return, but keep `.none` rendering as an empty string. |
| `AmsKind`, `AmsRouting`, `CooldownPhase`, `LanMode`, `DryerVM.stage` | plain Swift `enum`s (`String`-backed where they cross a boundary). `LanMode` **must stay tri-state** — do not model it as `Bool?` collapsed at the call site. |
| `AmsUnitVM`, `AmsSlotVM`, `AmsTrayRef`, `DryOption`, `DryerVM`, `CooldownVM`, `CoolingFit`, `BedSample`, `PlugAutomation`, `PrinterProfile`, `BedType` | `struct`s, `Equatable` (the "is pure" tests compare whole VMs with `toEqual`). Make them `Sendable`. |
| `presentAms`, `presentDryer`, `presentCooldown`, `plugAutomations`, `otherPlugs`, `automationSummary`, `plugLabel`, `printerProfile`, `slicedForMatchesPrinter`, `lanModeFrom`, `isBlocked`, `blockedActions`, `clampThreshold`, `normalizeSamples`, `parseBedHistory`, `estimateAmbient`, `fitDecayRate`, `etaToThreshold`, `hasPlateaued`, `materialCaution`, `dryDefaultFor` | free `func`s in an enum-namespace (`enum Cooling { static func present(...) }`). All are pure; no actor isolation needed — mark `nonisolated`/`Sendable`. |
| `DRY_BLOCKERS`, `DRY_DEFAULTS`, `PROFILES` | `static let` dictionaries. `DRY_BLOCKERS` keyed `[Int: String]`; `PROFILES` keyed by uppercased model `String`. |
| `LAN_*` copy constants, `COOLDOWN_*`, `DRY_*`, `PLATEAU_*`, `RATE_WINDOW_MIN`, `ETA_MAX_LEAD_C`, `NOZZLE_CAUTION_C`, `LOCKED_OPACITY` | `static let` on a `Constants` enum. Put the LAN copy in a `.strings`/String Catalog only if localisation is planned; otherwise keep them as literals so the tests can assert on them. |
| `useLockedAction` | a small `struct LockedAction { let mode: LanMode; func blocked(_:) -> Bool; func opacity(_:) -> Double }` passed via `@Environment` or as a plain value. **Keep the pairing invariant**: build a single `.lockedButton(_ action:)` `ViewModifier`/`ButtonStyle` that applies both the opacity *and* the intercepting tap, so a view physically cannot dim without gating. |
| `useLanMode`, `usePlugState`, `useCooldown` | `@Observable` (Swift 5.9 Observation) classes or `AsyncStream`-driven actors. See below. |

#### Idioms that need a different approach natively

1. **`asNum` — string/number union coercion.** Swift has no `number | string` type. Model the API DTOs with a `@propertyWrapper` or a custom `Decodable` helper:
   ```swift
   @propertyWrapper struct LenientNumber<T: LosslessStringConvertible & Decodable>: Decodable {
     var wrappedValue: T?
     init(from d: Decoder) throws { /* try T, then String -> T, else nil */ }
   }
   ```
   Apply it to **every** field in `PrinterStatus.ams[]` (`id`, `humidity`, `temp`, `dry_time`, `dry_target_temp`, `tray.id`, `tray.remain`, `tray.drying_temp`, `tray.drying_time`), to `tray_now`, and to the `dry_sf_reason` array elements. Do this once at the decoding boundary and the domain layer sees clean `Int?`/`Double?` — but **keep the round-trip tests** that feed string values, because the coercion is the thing that broke in production.

2. **`Date.parse` vs `ISO8601DateFormatter`.** Swift's `ISO8601DateFormatter` with default options **rejects** a fractionless naive string outright rather than silently interpreting it as local time — a different failure mode from JS, but still a failure. Port `parseBedHistory` as: regex-test for a trailing zone (`/([zZ]|[+-]\d\d:?\d\d)$/`), append `"Z"` if absent, then parse with `ISO8601DateFormatter` configured with `[.withInternetDateTime]` (add `.withFractionalSeconds` as a second attempt). Keep the `Date.UTC(2026,7,1,11,57,57)` assertion as an XCTest with a fixed `TimeZone`. **Set the test process timezone to something non-UTC** (e.g. `TZ=Europe/Berlin`) so a regression actually fails.

3. **Percentile / sort in `estimateAmbient`.** `s[Math.min(s.length - 1, Math.floor(s.length * pct))]` — Swift's integer arithmetic differs from JS float floor only at the edges; use `min(sorted.count - 1, Int(Double(sorted.count) * pct))`. Guard `count >= 60` first so the index is always valid. Filter with `n.isFinite && n > 0` (Swift `Double.isFinite` covers NaN/∞; JS `undefined`/`null` become `nil` in `[Double?]`).

4. **`Math.log`, OLS accumulation.** Direct: `Foundation.log`. Use `Double` throughout — do **not** reach for `Float` or `Measurement<UnitTemperature>` in the fit; the whole-degree-quantization test is sensitive and `Measurement` arithmetic adds noise and ceremony for nothing. Convert to `Measurement` only at the presentation boundary if at all.

5. **`Math.max(...temps)` spread** in `hasPlateaued` and the `peak` computation — Swift `temps.max()!` / `.min()!` after the `count >= 3` guard. In `presentCooldown`, `peak = samples.isEmpty ? bedC : max(bedC, samples.map(\.c).max()!)`.

6. **String formatting.** The `detail`/`label` strings are asserted verbatim by tests. `Math.round` in JS rounds **half away from zero for positives** — Swift's `Int(x.rounded())` uses `.toNearestOrAwayFromZero` by default, which matches. But `String(format: "%.0f")` uses banker's-ish IEEE rounding — **use `Int(x.rounded())` then interpolate**, not `%.0f`. `kwh.toFixed(2)` → `String(format: "%.2f", kwh)` (that one is fine). `fmtDuration`'s `String(m).padStart(2,'0')` → `String(format: "%02d", m)`.

7. **`fmtMin`'s 5-minute rounding** is `Math.round(r / 5) * 5` on an already-rounded integer — in Swift, `Int((Double(r) / 5).rounded()) * 5`. Note JS `Math.round(2.5) === 3` (half-up) whereas `(2.5).rounded()` in Swift is also 3 (`.toNearestOrAwayFromZero`), so this matches; but `Math.round(-2.5) === -2` differs from Swift's `-3` — irrelevant here since minutes are positive, yet worth a comment so nobody "fixes" it.

8. **Dictionary iteration order.** `presentDryer`'s `options` array is built from a JS `Map` and **preserves insertion order** (`[...byType.values()]`), and the test asserts three options in tray order with `PLA` first. Swift `Dictionary` is **unordered** — you must keep an explicit `var order: [String]` alongside a `[String: DryOption]`, or use an ordered-dictionary type. Same for `plugAutomations` (already an array — fine) and `PROFILES` (lookup only — fine).

9. **`Set` iteration order in `blockedActions`.** JS `[...Set]` preserves insertion order; the test sorts before comparing, so a Swift `Set<ActionId>` is fine — but sort in the implementation or the test to keep it deterministic.

10. **The meta-test that greps `.tsx` sources** (`every blocked action is acknowledged by the UI`) has no clean Swift equivalent. Replace it with a **compile-time** guarantee instead, which is strictly better: make `ActionId` a `CaseIterable` enum and require every gated control to be constructed through a `LockedButton(action:)` initializer, then add a test that walks a registry of declared controls. Alternatively keep a source-scanning test as a SwiftPM test that reads `.swift` files — but prefer the type-level fix.

11. **`Alert.alert` inside `useLockedAction.press`.** In SwiftUI, side-effecting alerts from a pure-ish helper is awkward. Model it as: `LockedAction.press` returns an enum (`.run` / `.explain(title:body:)`), and the view binds an `@State var lockedAlert: LockedAlert?` with `.alert(item:)`. Keeps the decision logic testable and out of the view.

12. **Polling loops (`useLanMode`, `usePlugState`, `useCooldown`).** Replace `setInterval` + `alive` flags with structured concurrency:
    - `@Observable final class PlugStore` with a `Task` started in `.task(id: plug?.id)` — SwiftUI's `.task(id:)` gives exactly the "re-arm when the id changes, cancel on disappear" semantics the `useEffect` dependency array provided, and cancellation replaces the `alive` boolean.
    - **The `pendingUntil` settle window (8 s) must survive the port verbatim** — it is not an implementation detail, it is the fix for the visibly bouncing switch caused by HA's lag. Store it as a `Date` and compare in the poll handler, exactly as now.
    - `useLanMode`'s foreground re-check → `.onChange(of: scenePhase)` for `.active`, plus a 5-minute `Task.sleep` loop. Keep "**a failed fetch leaves the last known value**".
    - `useCooldown`'s `liveRef` (a mutable ref deliberately *outside* React state so it doesn't trigger renders) → a plain `var liveSamples: [BedSample]` on the observable store, pruned to `CURVE_HOURS`. **Do not drop it** — it is what keeps the plateau detector from calling a still-falling plate "settled".
    - Note the existing `useCooldown` has a subtle React-ism worth *not* reproducing: `liveRef.current` is mutated in an effect and read in a `useMemo` whose dependency list doesn't include it, so it re-reads only because `status` also changed. In Swift, just recompute the VM whenever either the curve, ambient, or status changes — the model is pure, so recomputation is free and the dependency subtlety disappears.

13. **Timer cadences.** `CURVE_POLL_MS` 60 s, `AMBIENT_REFRESH_MS` 30 min, `POLL_MS` 5 min, plug poll 5 s / 8 s. iOS suspends timers in the background — use `.task` lifecycles plus a scene-phase refresh rather than assuming the loops keep running, and be aware the ambient 24-hour history fetch is cheap enough to just redo on foreground.

14. **`Alert`/confirmation semantics.** The **switch-off confirmations and the destructive styling are safety behaviour, not decoration** — port them as `.confirmationDialog` with a `.destructive` role button. Switching **on** must remain unconfirmed.

15. **Theme colours.** The tone→colour mapping (`ready → running`, `hot → heating`, `warm → accent`) should become a computed property on the Swift `CooldownVM` returning a semantic token, with the palette in an `Assets.xcassets` colour set carrying both appearances: `running` `#30D158`/`#23B24A`, `heating` `#FF9F0A`/`#E0860A`, `accent` `#2BD4C0`/`#0EAE9C`, `error` `#FF453A`/`#E5392E`, `paused` `#0A84FF`/`#0A84FF`, `idle` `#8E9398`/`#9AA0A6`, surfaces `s1 #131517`/`#FFFFFF`, `s2 #191C1F`/`#F5F6F8`, `s3 #23272B`/`#EAECEF`, `s4 #2D3237`/`#DEE1E5`, `bg #0A0B0C`/`#EFF1F3`, text `t1 #F3F5F7`/`#0D1012`, `t2 #A4ABB2`/`#585E64`, `t3 #6B7177`/`#878D94`, `accentInk #04201D`/`#FFFFFF`, `swatchRing #8E9398`/`#6E7378`. The `*Dim` variants are the base colour at 0.15 alpha (dark) / 0.12–0.14 (light) — use `.opacity()` rather than duplicating assets. The current RN implementation mutates a global `c` object and notifies subscribers; **in SwiftUI just use asset catalogue colours with light/dark variants and delete the whole mechanism.**

16. **`normColor` returning `nil` is load-bearing.** Swift: `func normColor(_ hex: String?) -> Color?` — but keep a `String?` (`#RRGGBB`) intermediate in the domain layer so it stays testable without importing SwiftUI, and convert at the view boundary. `nil` must render as "unknown" (an empty/outlined swatch), **never** as black or a hardcoded grey.

#### Things that will be genuinely hard or need care

- **The cooldown accuracy test is the crown jewel and must be ported.** `REAL_COOLDOWN_C` (90 whole-degree readings, 69 °C → 33 °C, crossing 35 °C at minute **72**, room **28.5 °C**) plus `REAL_READY_MIN = 72` and `REAL_AMBIENT_C = 28.5` go in as a Swift fixture array. The test asserts: absolute error ≤ 8 min every minute it speaks; < 25 % relative error whenever ≥ 15 min remain; **spoke on > 30 minutes**; silent for the first 25. Floating-point differences between JS and Swift `log`/`Double` are negligible at these tolerances, but if a bound is borderline, **fix the port, do not loosen the bound** — the bounds encode measured reality.
- **The `presentAms` routing heuristic is the subtlest logic in the app** and depends on two transport-specific facts (WS drops `fila_switch`; WS drops `developer_mode`). If the Swift rewrite changes the transport mix — e.g. goes REST-only, or adds a merged REST+WS status model — **re-derive whether `everyUnitMapped` is still the right tell** rather than porting blindly. Document the decision. If the native client merges REST and WS status into one model, `fila_switch` may now always be present, in which case the incomplete-map heuristic becomes belt-and-braces rather than the primary signal — keep both.
- **`supports_drying` is printer-level and `unitCanDry` is fail-open.** Resist the urge to "tighten" this into an allow-list of module types; the fail-open branches exist because a freshly-connected `n3f` unit publishes no `dry_*` fields yet.
- **`SmartPlug` writes are 403 for the scoped API key.** Do not build editable automation UI in the Swift app; it will fail at runtime. The domain layer is read-only reporting by design.
- **Live Activity / widget sharing.** If `DashVM.ams` (built from `presentAms().slots`) continues to feed a Live Activity, the domain module must be in a framework target linked by **both** the app and the widget extension, and the VM types must be `Codable` + `Sendable` for the `ActivityAttributes.ContentState`. Keep `AmsSlotVM`'s field names stable — the existing note that "`DashVM.ams` keeps consuming it with unchanged field names" exists precisely so the Live Activity needed no reshaping.
- **Endpoint inventory this section depends on** (all authenticated with the `X-API-Key` header; substitute `https://<your-bambuddy-host>` for the base URL):
  `POST /api/v1/printers/{id}/ams/load?tray_id={globalId}` ·
  `POST /api/v1/printers/{id}/ams/unload` ·
  `POST /api/v1/printers/{id}/drying/start?ams_id=&temp=&duration=[&filament=][&rotate_tray=]` ·
  `POST /api/v1/printers/{id}/drying/stop?ams_id=` ·
  `GET  /api/v1/printer-sensor-history/{id}?hours=&kinds=bed` ·
  `GET  /api/v1/smart-plugs/` · `GET /api/v1/smart-plugs/by-printer/{id}` · `GET /api/v1/smart-plugs/{id}/status` · `POST /api/v1/smart-plugs/{id}/control` body `{"action":"on"|"off"}` ·
  `POST /api/v1/queue/` with `{printer_id, library_file_id, use_ams, ams_mapping: [globalTrayId], plate_id}`.
  A blocked drying start returns **409** with a human-readable detail — surface it. `by-printer` returns a **single** plug, so only one plug may be bound to a printer; bind peripherals to no printer and reach them via the list endpoint.
