// Pure selection of the A1's slicing quality (process) presets from a Bambuddy /slicer/presets
// response. Extracted from the print wizard so it can be unit-tested — this is where a regression
// (0.2/0.6/0.8-nozzle variants leaking into the A1's 0.4 mm list) slipped through once.

export type Preset = { id: string; name: string; source?: string };

/** Bambuddy returns presets grouped by origin; only the shape we read is typed. */
export interface PresetsResponse {
  standard?: { printer?: Preset[]; process?: Preset[]; filament?: Preset[] };
  local?: { process?: Preset[] };
  cloud?: { process?: Preset[] };
  orca_cloud?: { process?: Preset[] };
}

/** A1 (the 0.4-nozzle single-extruder), excluding the A1 Mini / A1M. */
export const isA1 = (name: string): boolean => name.includes('A1') && !name.includes('A1M') && !/mini/i.test(name);

/**
 * The selectable quality profiles for this A1's 0.4 mm nozzle, merged across every preset group the
 * server returns (standard + the user's own local/cloud/orca_cloud profiles, so a support-enabled
 * profile saved in Studio/Bambuddy shows up too), deduped by id.
 *
 * Stock 0.4-nozzle presets carry NO nozzle suffix; 0.2/0.6/0.8-nozzle variants (wrong hardware for
 * this A1) are suffixed and excluded. Custom profiles have no such suffix, so they're kept.
 */
export function selectA1Process(p: PresetsResponse | null | undefined): { qualities: Preset[]; hasSupportProfile: boolean } {
  const groups = [p?.standard?.process, p?.local?.process, p?.cloud?.process, p?.orca_cloud?.process];
  const a1proc = groups.flatMap((g) => g ?? []).filter((x) => isA1(x.name));
  const seen = new Set<string>();
  const qualities = a1proc
    .filter((x) => /0\.\d+mm .*@BBL A1/.test(x.name) && !/0\.[268] nozzle/.test(x.name))
    .filter((x) => (seen.has(x.id) ? false : (seen.add(x.id), true)));
  const hasSupportProfile = a1proc.some((x) => /support|tree/i.test(x.name));
  return { qualities, hasSupportProfile };
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
