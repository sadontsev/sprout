// Pure selection of a printer's slicing quality (process) presets from a Bambuddy /slicer/presets
// response. Extracted from the print wizard so it can be unit-tested — this is where a regression
// (0.2/0.6/0.8-nozzle variants leaking into the 0.4 mm list) slipped through once.

export type Preset = { id: string; name: string; source?: string };

/** Bambuddy returns presets grouped by origin; only the shape we read is typed. */
export interface PresetsResponse {
  standard?: { printer?: Preset[]; process?: Preset[]; filament?: Preset[] };
  local?: { process?: Preset[] };
  cloud?: { process?: Preset[] };
  orca_cloud?: { process?: Preset[] };
}

const escapeRe = (s: string): string => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

/** A1 (the 0.4-nozzle single-extruder), excluding the A1 Mini / A1M. */
export const isA1 = (name: string): boolean => name.includes('A1') && !name.includes('A1M') && !/mini/i.test(name);

/** The support-enabled twin of a base quality, per the convention the provisioning script uses:
 *  "0.20mm Standard @BBL A1" -> "0.20mm Standard + Supports @BBL A1". */
export const supportTwinName = (baseName: string, token = '@BBL A1'): string =>
  baseName.includes(` ${token}`) ? baseName.replace(` ${token}`, ` + Supports ${token}`) : baseName + ' + Supports';

const isSupportPreset = (name: string): boolean => /\+ supports|support|tree/i.test(name);

/** Stock nozzle sizes BambuStudio ships preset families for. */
export type NozzleSize = '0.2' | '0.4' | '0.6' | '0.8';

/** The stock printer-preset name for a nozzle variant ("Bambu Lab H2C 0.6 nozzle"). */
export const printerPresetNameFor = (base: string, nozzle: NozzleSize): string => `${base} ${nozzle} nozzle`;

/**
 * The selectable quality profiles for a printer + NOZZLE variant, merged across every preset group
 * the server returns (standard + the user's own local/cloud/orca_cloud profiles), deduped by id.
 * `token` is the "@BBL <model>" suffix BambuStudio stamps on its presets.
 *
 * Naming convention (verified against the live preset list): 0.4-nozzle presets carry NO nozzle
 * suffix; 0.2/0.6/0.8 variants are suffixed "@BBL <model> <d> nozzle". So for 0.4 we exclude all
 * suffixed names; for other sizes we require exactly that suffix. Support-enabled twins are kept
 * OUT of the main quality list and instead paired to their base in `supportByBase`, so the wizard
 * can offer a clean "Supports" toggle (base quality stays selected; the toggle swaps in the twin
 * at slice time). Twins are provisioned for 0.4 only (ensure-support-profiles.py).
 */
export function selectProcess(
  p: PresetsResponse | null | undefined,
  token: string,
  nozzle: NozzleSize = '0.4',
): {
  qualities: Preset[];
  supportByBase: Record<string, Preset>;
  hasSupportProfile: boolean;
} {
  const groups = [p?.standard?.process, p?.local?.process, p?.cloud?.process, p?.orca_cloud?.process];
  const seen = new Set<string>();
  const tokenRe = new RegExp(`0\\.\\d+mm .*${escapeRe(token)}(?!\\S)`);
  const suffixRe = new RegExp(`${escapeRe(token)} ${escapeRe(nozzle)} nozzle$`);
  const proc = groups
    .flatMap((g) => g ?? [])
    .filter((x) => (nozzle === '0.4' ? tokenRe.test(x.name) && !/0\.[268] nozzle/.test(x.name) : suffixRe.test(x.name)))
    .filter((x) => (seen.has(x.id) ? false : (seen.add(x.id), true)));

  const qualities = proc.filter((x) => !isSupportPreset(x.name));
  const twins = proc.filter((x) => isSupportPreset(x.name));
  const supportByBase: Record<string, Preset> = {};
  for (const base of qualities) {
    const twin = twins.find((t) => t.name === supportTwinName(base.name, token));
    if (twin) supportByBase[base.name] = twin;
  }
  return { qualities, supportByBase, hasSupportProfile: twins.length > 0 };
}

/** Nozzle diameters physically mounted right now, from the live status (e.g. H2C: left 0.6 +
 *  right-vortex 0.4). Order preserved (extruder order); unknown/garbage entries dropped. */
export function mountedNozzles(status: { nozzles?: { nozzle_diameter?: string | number }[] } | null): NozzleSize[] {
  const out: NozzleSize[] = [];
  for (const n of status?.nozzles ?? []) {
    const d = String(n.nozzle_diameter ?? '');
    if (d === '0.2' || d === '0.4' || d === '0.6' || d === '0.8') {
      if (!out.includes(d)) out.push(d);
    }
  }
  return out;
}

/** Default nozzle selection: prefer 0.4 when mounted (richest preset family incl. support twins),
 *  else the first mounted size, else 0.4. */
export function defaultNozzle(mounted: NozzleSize[]): NozzleSize {
  if (mounted.includes('0.4')) return '0.4';
  return mounted[0] ?? '0.4';
}

/** Back-compat wrapper: the A1's process presets. */
export function selectA1Process(p: PresetsResponse | null | undefined): ReturnType<typeof selectProcess> {
  return selectProcess(p, '@BBL A1');
}

/** Default quality: prefer 0.20 mm Standard, then any 0.20 mm, else the first available. */
export function pickDefaultQuality(qualities: Preset[]): Preset | null {
  return (
    qualities.find((q) => /0\.20mm Standard/.test(q.name)) ??
    qualities.find((q) => q.name.includes('0.20')) ??
    qualities[0] ??
    null
  );
}
