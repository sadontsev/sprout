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

/**
 * The selectable quality profiles for a printer's default (0.4 mm) nozzle, merged across every
 * preset group the server returns (standard + the user's own local/cloud/orca_cloud profiles),
 * deduped by id. `token` is the "@BBL <model>" suffix BambuStudio stamps on its presets.
 *
 * Stock 0.4-nozzle presets carry NO nozzle suffix; 0.2/0.6/0.8-nozzle variants (wrong hardware)
 * are suffixed and excluded. Support-enabled twins are kept OUT of the main quality list and
 * instead paired to their base in `supportByBase`, so the wizard can offer a clean "Supports"
 * toggle (base quality stays selected; the toggle swaps in the twin at slice time).
 */
export function selectProcess(
  p: PresetsResponse | null | undefined,
  token: string,
): {
  qualities: Preset[];
  supportByBase: Record<string, Preset>;
  hasSupportProfile: boolean;
} {
  const groups = [p?.standard?.process, p?.local?.process, p?.cloud?.process, p?.orca_cloud?.process];
  const seen = new Set<string>();
  const tokenRe = new RegExp(`0\\.\\d+mm .*${escapeRe(token)}(?!\\S)`);
  const proc = groups
    .flatMap((g) => g ?? [])
    .filter((x) => tokenRe.test(x.name) && !/0\.[268] nozzle/.test(x.name))
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
