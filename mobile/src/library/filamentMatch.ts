import { normColor } from '@/dashboard/present';
import type { Preset } from '@/library/presetSelect';

export type FilamentPreset = Preset;

export interface AmsTray {
  id: number;
  tray_type?: string;
  tray_color?: string;
  remain?: number;
}

export interface AssignmentLike {
  tray_id: number;
  ams_id?: number;
  spool?: { material?: string | null; color_name?: string | null; rgba?: string | null; slicer_filament_name?: string | null } | null;
}

/** A filament actually loaded in an AMS tray, mapped to a slicer preset + its real color. */
export interface LoadedFilament {
  slot: number; // AMS tray id (0-based)
  material: string; // tray_type, e.g. "PETG-CF"
  colorHex: string | null;
  colorName: string | null;
  preset: FilamentPreset | null;
  isSupport: boolean;
}

// material type -> canonical base preset name (used when a tray has no inventory spool).
const MATERIAL_BASE: Record<string, string> = {
  PLA: 'Bambu PLA Basic',
  'PLA-S': 'Bambu Support For PLA',
  PETG: 'Bambu PETG HF',
  'PETG-CF': 'Bambu PETG-CF',
  ABS: 'Bambu ABS',
  'ABS-GF': 'Bambu ABS-GF',
  ASA: 'Bambu ASA',
  TPU: 'Bambu TPU 95A HF',
  PC: 'Bambu PC',
  'PA-CF': 'Bambu PA-CF',
  PVA: 'Bambu Support For PLA',
};

/** This printer's default-nozzle filament presets only (drops other models + other nozzle sizes).
 *  `token` is the "@BBL <model>" suffix, e.g. "@BBL A1" / "@BBL H2C". */
function modelFilaments(presets: FilamentPreset[], token: string): FilamentPreset[] {
  return presets.filter((p) => {
    const n = p.name || '';
    const at = n.indexOf(token);
    if (at < 0) return false;
    const after = n.slice(at + token.length);
    // "" (exact) or " 0.4 nozzle" pass; "M"/" mini"/other-model suffixes fail.
    if (after !== '' && !/^ 0\.4 nozzle$/.test(after)) return false;
    return true;
  });
}

/** Best filament preset for a slicer name (preferred) or a raw material type. */
export function matchFilamentPreset(
  presets: FilamentPreset[],
  slicerName: string | null | undefined,
  material: string | null | undefined,
  token = '@BBL A1',
): FilamentPreset | null {
  const pool = modelFilaments(presets, token);
  const byBase = (base: string): FilamentPreset | null =>
    pool.find((p) => p.name === `${base} ${token}`) ??
    pool.find((p) => p.name === `${base} ${token} 0.4 nozzle`) ??
    pool.find((p) => p.name.startsWith(`${base} ${token}`)) ??
    null;
  if (slicerName) {
    const m = byBase(slicerName);
    if (m) return m;
  }
  if (material) {
    const base = MATERIAL_BASE[material.toUpperCase()] ?? MATERIAL_BASE[material];
    if (base) return byBase(base);
  }
  return null;
}

/** Build the loaded-filament options from AMS trays, enriched by inventory assignments + presets. */
export function loadedFilaments(
  trays: AmsTray[],
  assignments: AssignmentLike[],
  presets: FilamentPreset[],
  token = '@BBL A1',
): LoadedFilament[] {
  const out: LoadedFilament[] = [];
  for (const t of trays) {
    if (!t.tray_type) continue; // empty slot
    const asg = assignments.find((a) => a.tray_id === t.id);
    const slicerName = asg?.spool?.slicer_filament_name ?? null;
    const material = t.tray_type;
    const colorHex = normColor(t.tray_color) ?? (asg?.spool?.rgba ? normColor(asg.spool.rgba) : null);
    out.push({
      slot: t.id,
      material,
      colorHex,
      colorName: asg?.spool?.color_name ?? null,
      preset: matchFilamentPreset(presets, slicerName, material, token),
      isSupport: /support|^PLA-S$|^PVA$/i.test(material),
    });
  }
  return out;
}
