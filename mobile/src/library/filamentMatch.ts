import { normColor } from '@/dashboard/present';
import type { AmsTrayRef } from '@/ams/units';
import type { Preset, NozzleSize } from '@/library/presetSelect';

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
  /** GLOBAL tray id — what tray_now, ams/load and ams_mapping VALUES all speak. NOT a local index:
   *  with three units fitted, local ids collide three ways. */
  slot: number;
  unitLabel: string; // "AMS 2"
  localId: number; // position inside its unit, for display ("Slot 3")
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

/**
 * This printer's filament presets for ONE nozzle size: the bare `<base> @BBL <model>` form plus that
 * size's ` <n> nozzle` variant. Other models ("M"/" mini") and other sizes are dropped.
 *
 * Bambu's naming is ASYMMETRIC and both halves matter (verified against the live 189-preset H2C set):
 * every material has a bare form, but size variants exist only where Bambu tuned one — e.g.
 * `Bambu PLA Basic @BBL H2C` ships 0.2/0.6/0.8 and NO 0.4, while `Bambu PETG-CF @BBL H2C` ships bare
 * AND 0.4. So the rule is uniform for every size: prefer the exact `<size> nozzle` variant, else fall
 * back to the bare form. Hard-coding 0.4 (as this did) silently stripped every 0.2/0.6/0.8 variant
 * from the pool, so picking 0.6 in the wizard sliced with 0.4-tuned flow / volumetric speed.
 */
function modelFilaments(presets: FilamentPreset[], token: string, nozzle: NozzleSize): FilamentPreset[] {
  const sized = ` ${nozzle} nozzle`;
  return presets.filter((p) => {
    const n = p.name || '';
    const at = n.indexOf(token);
    if (at < 0) return false;
    const after = n.slice(at + token.length);
    return after === '' || after === sized;
  });
}

/** Best filament preset for a slicer name (preferred) or a raw material type, for `nozzle`. */
export function matchFilamentPreset(
  presets: FilamentPreset[],
  slicerName: string | null | undefined,
  material: string | null | undefined,
  token = '@BBL A1',
  nozzle: NozzleSize = '0.4',
): FilamentPreset | null {
  const pool = modelFilaments(presets, token, nozzle);
  // Exact size first, then the bare form. NO startsWith fallback: the pool now admits more than one
  // suffix, so a prefix match could hand back a different size than the one asked for.
  const byBase = (base: string): FilamentPreset | null =>
    pool.find((p) => p.name === `${base} ${token} ${nozzle} nozzle`) ??
    pool.find((p) => p.name === `${base} ${token}`) ??
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

/** Build the loaded-filament options from AMS trays, enriched by inventory assignments + presets.
 *
 *  Takes tray REFS (unit-aware) rather than one unit's tray array: it used to be handed
 *  `status.ams[0].tray`, so every unit after the first was invisible to the print wizard. */
export function loadedFilaments(
  trays: AmsTrayRef[],
  assignments: AssignmentLike[],
  presets: FilamentPreset[],
  token = '@BBL A1',
  nozzle: NozzleSize = '0.4',
): LoadedFilament[] {
  const out: LoadedFilament[] = [];
  for (const t of trays) {
    if (!t.trayType) continue; // empty slot
    // Match on BOTH ids. Matching tray_id alone made AMS 2 slot 0 inherit AMS 1 slot 0's spool —
    // wrong brand and colour, and a wrong slicer preset driving the slice. ams_id is optional on the
    // assignment, so a legacy record with no unit still matches its tray as before.
    const asg =
      assignments.find((a) => a.tray_id === t.localId && a.ams_id === t.unitId) ??
      assignments.find((a) => a.tray_id === t.localId && a.ams_id == null);
    const slicerName = asg?.spool?.slicer_filament_name ?? null;
    const material = t.trayType;
    const colorHex = normColor(t.trayColor) ?? (asg?.spool?.rgba ? normColor(asg.spool.rgba) : null);
    out.push({
      slot: t.globalId,
      unitLabel: t.unitLabel,
      localId: t.localId,
      material,
      colorHex,
      colorName: asg?.spool?.color_name ?? null,
      preset: matchFilamentPreset(presets, slicerName, material, token, nozzle),
      isSupport: /support|^PLA-S$|^PVA$/i.test(material),
    });
  }
  return out;
}

/** Curated "other filament" catalog for the wizard — the common materials, resolved for `nozzle`.
 *  Single source of truth: Overlays.tsx used to rebuild this with its own 0.4-only regex, which is
 *  how the nozzle-size bug above came to exist in two places at once. */
export const CATALOG_MATERIALS = [
  'Bambu PLA Basic', 'Bambu PLA Matte', 'Bambu PETG HF', 'Bambu PETG-CF',
  'Bambu ABS', 'Bambu ASA', 'Bambu TPU 95A HF', 'Bambu Support For PLA',
];

export function catalogFilaments(presets: FilamentPreset[], token: string, nozzle: NozzleSize = '0.4'): FilamentPreset[] {
  const pool = modelFilaments(presets, token, nozzle);
  const out: FilamentPreset[] = [];
  for (const base of CATALOG_MATERIALS) {
    const hit =
      pool.find((p) => p.name === `${base} ${token} ${nozzle} nozzle`) ?? pool.find((p) => p.name === `${base} ${token}`);
    if (hit) out.push(hit);
  }
  return out;
}
