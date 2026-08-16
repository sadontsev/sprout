// Pure, model-keyed printer knowledge. Everything the UI/wizard needs to behave correctly per
// machine lives here (not scattered as 'A1' literals) so adding a printer is a table entry.

import type { Printer } from '@/api/types';

export interface BedType {
  id: string; // canonical bed_type the slicer expects
  label: string;
}

export interface PrinterProfile {
  /** Preset-name token: BambuStudio suffixes profiles with "@BBL <token>". */
  presetToken: string;
  /** The stock printer-preset base name in /slicer/presets, e.g. "Bambu Lab A1". */
  printerPresetBase: string;
  /** Marketing name of the filament hub. */
  amsLabel: string;
  dualNozzle: boolean;
  /** Build plates this machine accepts (first = default). */
  bedTypes: BedType[];
  /** Physical build-plate footprint in mm (X width × Y depth) — drives the layer viewer's plate. */
  plate: { w: number; d: number };
  /** Camera behavior copy — the A1's camera is on-demand/slow; H2-series streams need
   *  LAN Mode Liveview enabled on the printer screen. */
  cameraHint: string;
}

const TEXTURED = { id: 'Textured PEI Plate', label: 'Textured PEI' };
const SMOOTH = { id: 'Smooth PEI Plate', label: 'Smooth PEI' };
const COOL = { id: 'Cool Plate', label: 'Cool Plate' };
const ENGINEERING = { id: 'Engineering Plate', label: 'Engineering' };
const HIGH_TEMP = { id: 'High Temp Plate', label: 'High Temp' };

const PROFILES: Record<string, PrinterProfile> = {
  A1: {
    presetToken: '@BBL A1',
    printerPresetBase: 'Bambu Lab A1',
    amsLabel: 'AMS Lite',
    dualNozzle: false,
    bedTypes: [TEXTURED, SMOOTH, COOL, ENGINEERING],
    plate: { w: 256, d: 256 },
    cameraHint: 'The A1’s camera is on-demand and can be slow — give it a moment and tap Retry.',
  },
  H2C: {
    presetToken: '@BBL H2C',
    printerPresetBase: 'Bambu Lab H2C',
    amsLabel: 'AMS 2 Pro',
    dualNozzle: true,
    bedTypes: [TEXTURED, SMOOTH, HIGH_TEMP, ENGINEERING],
    plate: { w: 350, d: 320 },
    cameraHint: 'If this persists, enable LAN Mode Liveview in the printer’s settings screen (Settings → General).',
  },
};

/** Profile for a Bambuddy printer record. Unknown models get a best-effort generic profile
 *  (preset token derived from the model string) instead of silently behaving like an A1. */
export function printerProfile(printer: Pick<Printer, 'model' | 'nozzle_count'> | null | undefined): PrinterProfile {
  const model = (printer?.model ?? 'A1').trim();
  const known = PROFILES[model.toUpperCase()];
  if (known) return known;
  return {
    presetToken: `@BBL ${model}`,
    printerPresetBase: `Bambu Lab ${model}`,
    amsLabel: 'AMS',
    dualNozzle: (printer?.nozzle_count ?? 1) > 1,
    bedTypes: [TEXTURED, SMOOTH, COOL, ENGINEERING],
    plate: { w: 256, d: 256 },
    cameraHint: 'Give the camera a moment and tap Retry. Make sure the printer is powered on.',
  };
}

/** Does a sliced file's embedded printer name match this machine? Null/empty = unknown = allowed.
 *  Exact-model match: "Bambu Lab A1 mini" must NOT pass for the A1 (different machine). */
export function slicedForMatchesPrinter(embeddedPrinter: string | null | undefined, profile: PrinterProfile): boolean {
  const emb = (embeddedPrinter ?? '').trim().toUpperCase();
  if (!emb) return true;
  const model = profile.printerPresetBase.replace('Bambu Lab ', '').toUpperCase();
  const embModel = emb.replace('BAMBU LAB ', '');
  // Exact, or exact followed by a nozzle suffix ("A1 0.4 NOZZLE") — but never a longer model name.
  return embModel === model || embModel.startsWith(`${model} 0.`);
}
