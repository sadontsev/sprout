import type { PrinterStatus } from '@/api/types';
import { asNum, fmtDuration, normColor } from '@/dashboard/present';

/**
 * Pure view-model for AMS filament drying (AMS 2 Pro / AMS-HT). Mirrors Bambuddy's semantics:
 * - "actively drying" = `dry_time > 0` (minutes remaining). dry_status is NOT reliable — observed
 *   0 mid-cycle on the live AMS 2 Pro.
 * - recommended temp/time come from each tray's RFID/preset (drying_temp/drying_time); trays without
 *   data (0) fall back to a same-type sibling tray, then to DRY_DEFAULTS.
 * - the AMS 2 Pro's heater tops out at 65°C; only the AMS-HT reaches 85°C. Bambuddy validates the
 *   wider 45-85 range for both, so the clamp must happen here.
 */

/** Human messages for the AMS's dry_sf_reason codes (mirrors Bambuddy printers.py). */
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

/** Fallback drying recommendations by filament type, for trays whose RFID/preset carries none.
 *  Starting points only — the UI lets the user adjust; temps are clamped to the unit's hardware max. */
export const DRY_DEFAULTS: Record<string, { temp: number; hours: number }> = {
  PLA: { temp: 55, hours: 8 },
  PETG: { temp: 65, hours: 8 },
  TPU: { temp: 60, hours: 8 },
  ABS: { temp: 75, hours: 8 },
  ASA: { temp: 75, hours: 8 },
  PC: { temp: 80, hours: 10 },
  PA: { temp: 80, hours: 12 },
  PVA: { temp: 70, hours: 10 },
  PET: { temp: 70, hours: 10 },
};
const GENERIC_DRY = { temp: 55, hours: 8 };

export const DRY_MIN_TEMP = 45;
export const DRY_MAX_HOURS = 24;

/** "PETG-CF" -> PETG defaults when there's no exact entry. */
export function dryDefaultFor(type: string): { temp: number; hours: number } {
  return DRY_DEFAULTS[type] ?? DRY_DEFAULTS[type.split('-')[0]] ?? GENERIC_DRY;
}

const clampTemp = (t: number, max: number) => Math.min(Math.max(Math.round(t), DRY_MIN_TEMP), max);
const clampHours = (h: number) => Math.min(Math.max(Math.round(h), 1), DRY_MAX_HOURS);

/** One dryable filament choice, deduped by type across the unit's trays. */
export interface DryOption {
  type: string; // "PETG"
  color: string | null; // #RRGGBB of a tray holding it
  temp: number; // recommended °C, clamped to the unit's max
  hours: number; // recommended duration
  fromPreset: boolean; // true when the tray's own RFID/preset provided the numbers
}

export interface DryerVM {
  amsId: number;
  isHt: boolean;
  /** Hardware ceiling: 65 (AMS 2 Pro) or 85 (AMS-HT). */
  maxTemp: number;
  active: boolean; // dry_time > 0
  remainingMin: number;
  remainingText: string; // "5h 44m"
  humidityPct: number | null;
  tempC: number | null; // current air temp inside the AMS
  /** Target °C — Bambuddy's cache when it started the cycle, else the recommendation for
   *  dry_filament, else null (cycle started from Handy/printer with an unknown target). */
  targetTemp: number | null;
  filament: string; // what the active cycle is drying ('' if unknown)
  /** heating = still climbing to target; holding = at temperature. null when target is unknown. */
  stage: 'heating' | 'holding' | null;
  /** Human reasons the AMS currently refuses to start (code 6 "already drying" is omitted —
   *  the active card already conveys it). */
  blockers: string[];
  options: DryOption[];
}

/** Pure: one DryerVM per AMS unit on a drying-capable machine (empty array otherwise). */
export function presentDryer(status: PrinterStatus | null): DryerVM[] {
  if (!status?.supports_drying || !status.ams?.length) return [];
  return status.ams.map((unit) => {
    const isHt = unit.is_ams_ht === true;
    const maxTemp = isHt ? 85 : 65;
    const remainingMin = Math.max(0, Math.round(asNum(unit.dry_time) ?? 0));
    const active = remainingMin > 0;
    const humidity = asNum(unit.humidity);
    const tempC = asNum(unit.temp);

    // Dryable options: dedupe trays by type; a tray with real preset data beats a 0/0 sibling.
    const byType = new Map<string, DryOption>();
    for (const tray of unit.tray ?? []) {
      const type = tray.tray_type;
      if (!type) continue;
      const presetTemp = asNum(tray.drying_temp) ?? 0;
      const presetHours = asNum(tray.drying_time) ?? 0;
      const fromPreset = presetTemp > 0;
      const fallback = dryDefaultFor(type);
      const opt: DryOption = {
        type,
        color: normColor(tray.tray_color),
        temp: clampTemp(fromPreset ? presetTemp : fallback.temp, maxTemp),
        hours: clampHours(fromPreset && presetHours > 0 ? presetHours : fallback.hours),
        fromPreset,
      };
      const prev = byType.get(type);
      if (!prev || (opt.fromPreset && !prev.fromPreset)) byType.set(type, opt);
    }
    const options = [...byType.values()];

    const filament = unit.dry_filament ?? '';
    let targetTemp = asNum(unit.dry_target_temp);
    if (active && targetTemp == null && filament) {
      // Cycle started outside Bambuddy — best estimate is the recommendation for what it's drying.
      targetTemp = options.find((o) => o.type === filament)?.temp ?? null;
    }
    const stage = active && targetTemp != null && tempC != null ? (tempC < targetTemp - 3 ? 'heating' : 'holding') : null;

    const blockers = (unit.dry_sf_reason ?? [])
      .map((code) => {
        const n = asNum(code);
        return n != null && n !== 6 ? DRY_BLOCKERS[n] : undefined;
      })
      .filter((m): m is string => !!m);

    return {
      amsId: unit.id,
      isHt,
      maxTemp,
      active,
      remainingMin,
      remainingText: fmtDuration(remainingMin),
      humidityPct: humidity != null ? Math.round(humidity) : null,
      tempC,
      targetTemp,
      filament,
      stage,
      blockers,
      options,
    };
  });
}
