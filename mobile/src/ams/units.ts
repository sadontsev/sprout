// Pure AMS topology: 1..N units of mixed kinds -> the view-models every AMS surface consumes.
//
// Before this module the app read `status.ams[0]` in four places (plus la-push), so a second unit was
// invisible. That is not future-proofing: the owner's H2C already reports TWO units — an AMS 2 Pro
// (id 0, module_type "n3f", 4 trays) and an AMS HT (id 128, "n3s", 1 tray, is_ams_ht) — verified live
// on 2026-07-19 with ams_extruder_map {"0":0,"128":1}.
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
  /** Which extruder this unit feeds, from ams_extruder_map (null when the printer doesn't say). */
  extruder: number | null;
  /** Short serial tail — the only way to tell two identical AMS 2 Pro units apart. */
  serialTail: string;
  dryingMinLeft: number; // 0 when idle
}

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
export function presentAms(status: PrinterStatus | null): { units: AmsUnitVM[]; slots: AmsSlotVM[] } {
  const raw = status?.ams ?? [];
  if (!raw.length) return { units: [], slots: [] };

  const extMap = (status as { ams_extruder_map?: Record<string, number> } | null)?.ams_extruder_map ?? {};
  const htTotal = raw.filter((u) => u.is_ams_ht === true).length;
  const trayNow = asNum(status?.tray_now);

  let htSeen = 0;
  const units: AmsUnitVM[] = [];
  const slots: AmsSlotVM[] = [];

  for (const unit of raw) {
    const id = asNum(unit.id) ?? 0;
    // is_ams_ht is authoritative; module_type ("n3s") and the 128+ id space corroborate it.
    const kind: AmsKind = unit.is_ams_ht === true || id >= 128 ? 'ht' : 'ams';
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
      });
    }
  }
  return { units, slots };
}
