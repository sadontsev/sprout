import { buildPlateReview, fmtSeconds } from '../plateReview';
import type { PlatesResponse, FileMetadata } from '@/api/types';

// Real shapes captured from the live backend (cube20.gcode.3mf).
const PLATES: PlatesResponse = {
  file_id: 2,
  filename: 'cube20.gcode.3mf',
  is_multi_plate: false,
  embedded_printer: 'Bambu Lab A1 0.4 nozzle',
  embedded_process: '0.20mm Standard @BBL A1',
  plates: [
    {
      index: 1,
      name: 'cube20.stl',
      object_count: 1,
      has_thumbnail: false,
      print_time_seconds: 738,
      filament_used_grams: 3.75,
      filaments: [{ slot_id: 1, type: 'PLA', color: '#00AE42', used_grams: 3.8, used_meters: 1.24 }],
    },
  ],
};
const META: FileMetadata = {
  total_layers: 100,
  layer_height: 0.2,
  nozzle_temperature: 220,
  bed_type: 'Cool Plate',
  print_time_seconds: 738,
  filament_used_g: 3.75,
  filament_slots: [{ slot_id: 1, used_g: 3.75, type: 'PLA', color: '#00AE42' }],
};

describe('buildPlateReview', () => {
  it('merges plate + metadata into a render-ready VM', () => {
    const vm = buildPlateReview(PLATES, META, 1);
    expect(vm.plateIndex).toBe(1);
    expect(vm.plateCount).toBe(1);
    expect(vm.isMultiPlate).toBe(false);
    expect(vm.timeSeconds).toBe(738);
    expect(vm.grams).toBe(3.75);
    expect(vm.layers).toBe(100);
    expect(vm.layerHeight).toBe(0.2);
    expect(vm.heightMm).toBe(20); // 100 × 0.2
    expect(vm.nozzleTemp).toBe(220);
    expect(vm.bedType).toBe('Cool Plate');
    expect(vm.printer).toBe('Bambu Lab A1 0.4 nozzle');
    expect(vm.process).toBe('0.20mm Standard @BBL A1');
    expect(vm.filaments).toEqual([{ slot: 1, type: 'PLA', color: '#00AE42', grams: 3.8, meters: 1.24 }]);
  });

  it('prefers the plate filament list, falling back to metadata slots', () => {
    const noPlateFil = buildPlateReview({ ...PLATES, plates: [{ index: 1 }] }, META, 1);
    expect(noPlateFil.filaments).toEqual([{ slot: 1, type: 'PLA', color: '#00AE42', grams: 3.75, meters: null }]);
  });

  it('falls back to the first plate when the requested index is absent', () => {
    const vm = buildPlateReview(PLATES, META, 5);
    expect(vm.plateIndex).toBe(1);
  });

  it('is null-safe with no data', () => {
    const vm = buildPlateReview(null, null, 1);
    expect(vm.timeSeconds).toBeNull();
    expect(vm.layers).toBeNull();
    expect(vm.heightMm).toBeNull();
    expect(vm.filaments).toEqual([]);
    expect(vm.plateCount).toBe(0);
  });

  it('computes heightMm only when both layers and layerHeight are known', () => {
    expect(buildPlateReview(null, { total_layers: 110, layer_height: 0.2 }, 1).heightMm).toBe(22);
    expect(buildPlateReview(null, { total_layers: 110 }, 1).heightMm).toBeNull();
  });
});

describe('fmtSeconds', () => {
  it('formats minutes and hours', () => {
    expect(fmtSeconds(738)).toBe('12 min');
    expect(fmtSeconds(3660)).toBe('1 h 1 min');
    expect(fmtSeconds(0)).toBe('—');
    expect(fmtSeconds(null)).toBe('—');
  });
});
