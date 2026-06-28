import type { PlatesResponse, PlateInfo, FileMetadata } from '@/api/types';

export interface ReviewFilament {
  slot: number;
  type: string;
  color: string | null;
  grams: number | null;
  meters: number | null;
}

/** Normalized, render-ready review of one plate of a sliced model. Merges /plates (per-plate) over
 *  the file's slicer metadata (layers, temps), each filling the other's gaps. Pure + tested. */
export interface PlateReviewVM {
  plateIndex: number;
  plateCount: number;
  isMultiPlate: boolean;
  timeSeconds: number | null;
  grams: number | null;
  layers: number | null;
  layerHeight: number | null;
  heightMm: number | null; // layers × layerHeight, when both known
  nozzleTemp: number | null;
  bedType: string | null;
  objectCount: number | null;
  printer: string | null;
  process: string | null;
  filaments: ReviewFilament[];
}

function num(v: unknown): number | null {
  return typeof v === 'number' && isFinite(v) ? v : null;
}

function pickPlate(plates: PlatesResponse | null, plateIndex: number): PlateInfo | null {
  if (!plates?.plates?.length) return null;
  return plates.plates.find((p) => p.index === plateIndex) ?? plates.plates[0];
}

/** Filaments for the plate: prefer the plate's own list, else derive from file metadata slots. */
function filamentsFor(plate: PlateInfo | null, meta: FileMetadata | null): ReviewFilament[] {
  const fromPlate = plate?.filaments;
  if (fromPlate?.length) {
    return fromPlate.map((f) => ({
      slot: f.slot_id,
      type: f.type ?? '—',
      color: f.color ?? null,
      grams: num(f.used_grams),
      meters: num(f.used_meters),
    }));
  }
  const slots = meta?.filament_slots;
  if (slots?.length) {
    return slots.map((s) => ({
      slot: s.slot_id,
      type: s.type ?? '—',
      color: s.color ?? null,
      grams: num(s.used_g),
      meters: null,
    }));
  }
  return [];
}

/**
 * Build the review view-model for a sliced model. `plateIndex` is 1-based; falls back to the first
 * plate when the requested index isn't present. Both inputs may be null (still returns a safe VM).
 */
export function buildPlateReview(
  plates: PlatesResponse | null,
  meta: FileMetadata | null,
  plateIndex = 1,
): PlateReviewVM {
  const plate = pickPlate(plates, plateIndex);
  const layers = num(meta?.total_layers);
  const layerHeight = num(meta?.layer_height);
  const heightMm = layers != null && layerHeight != null ? Math.round(layers * layerHeight * 100) / 100 : null;

  return {
    plateIndex: plate?.index ?? plateIndex,
    plateCount: plates?.plates?.length ?? 0,
    isMultiPlate: !!plates?.is_multi_plate,
    timeSeconds: num(plate?.print_time_seconds) ?? num(meta?.print_time_seconds),
    grams: num(plate?.filament_used_grams) ?? num(meta?.filament_used_g),
    layers,
    layerHeight,
    heightMm,
    nozzleTemp: num(meta?.nozzle_temperature),
    bedType: meta?.bed_type ?? null,
    objectCount: num(plate?.object_count),
    printer: plates?.embedded_printer ?? meta?.sliced_for_model ?? null,
    process: plates?.embedded_process ?? null,
    filaments: filamentsFor(plate, meta),
  };
}

/** "12 min" / "1 h 2 min" from seconds. */
export function fmtSeconds(s: number | null): string {
  if (s == null || !isFinite(s) || s <= 0) return '—';
  const m = Math.round(s / 60);
  if (m < 60) return `${m} min`;
  const h = Math.floor(m / 60);
  return `${h} h ${m % 60} min`;
}
