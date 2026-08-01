// Pure AMS topology: 1..N units of mixed kinds -> the view-models every AMS surface consumes.
//
// Before this module the app read `status.ams[0]` in four places (plus la-push), so a second unit was
// invisible. That is not future-proofing: the owner's H2C now reports THREE units — two AMS 2 Pro
// (ids 0 and 1, module_type "n3f", 4 trays each) and an AMS HT (id 128, "n3s", 1 tray, is_ams_ht) —
// verified live on 2026-08-01, together with a Filament Track Switch (`fila_switch.installed`).
//
// The H2 series drives up to 4 regular units (ids 0-3) plus 8 HT units (128-135); this module makes
// no assumption about how many of either are present.
import { normColor, asNum } from '../dashboard/present';
import type { PrinterStatus } from '../api/types';

/** A tray's id in the space the PRINTER speaks: `tray_now`, ams/load's tray_id, ams_mapping values.
 *
 *  Regular AMS units pack 4 trays each (unit 0 -> 0..3, unit 1 -> 4..7); an AMS HT is a single-spool
 *  unit whose id (128..135) IS its tray id. Confirmed against the live inventory endpoint, which keys
 *  the same three trays as {"0","2","128"} for (unit 0, tray 0), (unit 0, tray 2) and (HT 128, tray 0).
 *
 *  This is the one piece of id math in the app; every "is this tray active / load this tray" question
 *  must go through it. Comparing a LOCAL tray index against `tray_now` — as presentDashboard used to —
 *  is right only by coincidence for unit 0, and lights the HT's tray whenever AMS-0 slot 0 prints. */
export const globalTrayId = (unitId: number, localId: number): number => (unitId >= 128 ? unitId : unitId * 4 + localId);

export type AmsKind = 'ams' | 'ht';

export interface AmsUnitVM {
  /** RAW unit id (0..3 regular, 128+ HT) — this is what drying/load endpoints expect, NOT an index. */
  id: number;
  label: string; // "AMS 1" | "AMS 2" | "AMS HT"
  kind: AmsKind;
  capacity: number; // trays this unit reports (4 for an AMS 2 Pro, 1 for an HT)
  loaded: number; // trays with filament
  /** Drying ceiling: the AMS 2 Pro tops out at 65°C, the HT reaches 85°C. */
  maxDryTemp: number;
  humidity: number | null;
  tempC: number | null;
  /** Which extruder this unit feeds: 0 = RIGHT, 1 = LEFT. null when the printer doesn't say — which
   *  includes every unit once a Filament Track Switch is fitted, because routing is then dynamic. */
  extruder: number | null;
  /** Short serial tail — the only way to tell two identical AMS 2 Pro units apart. */
  serialTail: string;
  dryingMinLeft: number; // 0 when idle
}

/** How AMS units are bound to extruders right now.
 *
 *  'switch'  a Filament Track Switch is installed: any unit can feed either nozzle, so no unit HAS a
 *            fixed extruder and any per-unit binding shown to the user would be a lie.
 *  'fixed'   classic wiring — each unit feeds the extruder named in ams_extruder_map.
 *
 *  This distinction is not cosmetic. Bambuddy builds ams_extruder_map from each unit's `info` bits
 *  and skips units reporting 0xE ("no fixed extruder"), which is exactly what an FTS-routed unit
 *  reports — permanently. The map is also merge-only and never pruned, so on this machine it still
 *  reads {"0":0,"128":1} from before the switch was fitted while the unit added afterwards (id 1)
 *  can never gain an entry. Reading it as current routing therefore shows two units a stale binding
 *  and the third nothing at all. Bambuddy's own UI and queue scheduler drop the per-extruder filter
 *  whenever the switch is installed; this does the same. */
export type AmsRouting = 'fixed' | 'switch';

/** 0 = RIGHT/main, 1 = LEFT on the H2 series — the same convention as `active_extruder` and the
 *  nozzle rack (see presentNozzles). Centralised because getting it backwards is easy and silent:
 *  the AMS tab shipped it inverted. */
export const extruderSide = (e: number | null | undefined): '' | 'Left' | 'Right' =>
  e === 0 ? 'Right' : e === 1 ? 'Left' : '';

export interface AmsSlotVM {
  // --- fields below match the legacy AmsTrayVM so existing consumers keep working unchanged ---
  label: string;
  color: string;
  pct: string;
  active: boolean;
  empty: boolean;
  // --- topology ---
  unitId: number;
  unitLabel: string;
  localId: number; // tray index INSIDE its unit (what SlotAssignment stores)
  globalId: number; // what the printer speaks
  /** Which extruder THIS tray is feeding right now (0 = Right, 1 = Left), or null.
   *
   *  With a Filament Track Switch fitted this is the only honest routing answer available: units no
   *  longer belong to a nozzle, but a LOADED tray is on a track, and the track has an outlet. Only
   *  the trays currently threaded through the switch have one. */
  extruder: number | null;
}

/** Which extruder a given global tray id is feeding, via the Filament Track Switch.
 *
 *  `fila_switch.in_slots[track]` is the GLOBAL tray id loaded on that track (-1 = empty) and
 *  `out_extruders[track]` is the nozzle that track terminates at — so the answer is a lookup by
 *  index. This mirrors Bambuddy's own web UI exactly. Returns null with no switch, or for a tray
 *  that is not currently on a track. */
export function switchExtruderForTray(status: PrinterStatus | null, globalId: number): number | null {
  const fs = status?.fila_switch;
  if (fs?.installed !== true) return null;
  const track = (fs.in_slots ?? []).indexOf(globalId);
  if (track < 0) return null;
  const out = (fs.out_extruders ?? [])[track];
  // 0xE (14) is the documented "no outlet" marker.
  return typeof out === 'number' && out !== 0xe ? out : null;
}

/** A tray plus the unit context needed to address it. The raw `tray_type`/`tray_color` are kept
 *  (rather than the presented AmsSlotVM strings) because preset matching and colour fallback need
 *  the unformatted values. */
export interface AmsTrayRef {
  unitId: number;
  unitLabel: string;
  localId: number;
  /** What the printer speaks: tray_now, ams/load's tray_id, and ams_mapping VALUES. */
  globalId: number;
  trayType?: string;
  trayColor?: string;
}

/** Every tray across every unit, flat and in unit order.
 *
 *  Exists because callers kept reaching for `status.ams[0].tray`, which silently hides every unit
 *  after the first — with three units fitted that is 5 of 9 slots. Going through here means a caller
 *  cannot accidentally see only one unit, and gets the global id it needs to address the tray. */
export function amsTrayRefs(status: PrinterStatus | null): AmsTrayRef[] {
  const { slots } = presentAms(status);
  const rawById = new Map<number, PrinterStatus['ams'] extends (infer U)[] | undefined ? U : never>();
  for (const u of status?.ams ?? []) rawById.set(asNum(u.id) ?? 0, u);
  return slots.map((s) => {
    const tray = (rawById.get(s.unitId)?.tray ?? []).find((t) => (asNum(t.id) ?? 0) === s.localId);
    return {
      unitId: s.unitId,
      unitLabel: s.unitLabel,
      localId: s.localId,
      globalId: s.globalId,
      trayType: tray?.tray_type,
      trayColor: tray?.tray_color,
    };
  });
}

const EMPTY_COLOR = 'transparent';

/** Human label. Regular units are numbered from their own stable id (not array position, which the
 *  printer may reorder); HT units are named by kind, numbered only if there are several. */
function labelFor(unitId: number, kind: AmsKind, htIndex: number, htTotal: number): string {
  if (kind === 'ht') return htTotal > 1 ? `AMS HT ${htIndex + 1}` : 'AMS HT';
  return `AMS ${unitId + 1}`;
}

/**
 * Pure: every AMS unit and every slot across all of them.
 *
 * `slots` is a FLAT list in unit order — `DashVM.ams` keeps consuming it with unchanged field names,
 * so the dashboard strip and the Live Activity need no reshaping, while `units` carries the grouping
 * the Hardware tab needs.
 */
export function presentAms(status: PrinterStatus | null): { units: AmsUnitVM[]; slots: AmsSlotVM[]; routing: AmsRouting } {
  const raw = status?.ams ?? [];
  if (!raw.length) return { units: [], slots: [], routing: 'fixed' };

  const routing: AmsRouting = status?.fila_switch?.installed === true ? 'switch' : 'fixed';
  // With a switch fitted the map is stale residue, not current routing — ignore it wholesale rather
  // than showing a binding for the units that happen to still have an entry.
  const extMap = routing === 'switch' ? {} : (status?.ams_extruder_map ?? {});
  // Count HTs with the SAME predicate used to classify them, or a unit that reports the 128+ id
  // without is_ams_ht is labelled 'AMS HT' while htTotal stays 0 — two units, one identical label.
  const isHt = (u: (typeof raw)[number]): boolean => u.is_ams_ht === true || (asNum(u.id) ?? 0) >= 128;
  const htTotal = raw.filter(isHt).length;
  const trayNow = asNum(status?.tray_now);

  let htSeen = 0;
  const units: AmsUnitVM[] = [];
  const slots: AmsSlotVM[] = [];

  for (const unit of raw) {
    const id = asNum(unit.id) ?? 0;
    // is_ams_ht is authoritative; module_type ("n3s") and the 128+ id space corroborate it.
    const kind: AmsKind = isHt(unit) ? 'ht' : 'ams';
    const label = labelFor(id, kind, htSeen, htTotal);
    if (kind === 'ht') htSeen++;
    const trays = unit.tray ?? [];
    const serial = (unit as { serial_number?: string }).serial_number ?? '';

    units.push({
      id,
      label,
      kind,
      capacity: trays.length,
      loaded: trays.filter((t) => !!t.tray_type).length,
      maxDryTemp: kind === 'ht' ? 85 : 65,
      humidity: asNum(unit.humidity),
      tempC: asNum(unit.temp),
      extruder: typeof extMap[String(id)] === 'number' ? extMap[String(id)] : null,
      serialTail: serial && serial !== 'N/A' ? serial.slice(-4) : '',
      dryingMinLeft: Math.max(0, Math.round(asNum(unit.dry_time) ?? 0)),
    });

    for (const tray of trays) {
      const localId = asNum(tray.id) ?? 0;
      const globalId = globalTrayId(id, localId);
      const empty = !tray.tray_type;
      slots.push({
        label: empty ? 'Empty' : tray.tray_type ?? '',
        color: empty ? EMPTY_COLOR : normColor(tray.tray_color) ?? '#3A3F45',
        pct: empty ? '—' : `${Math.round(asNum(tray.remain) ?? 0)}%`,
        active: !empty && trayNow != null && trayNow === globalId,
        empty,
        unitId: id,
        unitLabel: label,
        localId,
        globalId,
        extruder: routing === 'switch' ? switchExtruderForTray(status, globalId) : (extMap[String(id)] ?? null),
      });
    }
  }
  return { units, slots, routing };
}
