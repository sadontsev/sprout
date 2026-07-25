import { globalTrayId, presentAms } from '@/ams/units';
import type { PrinterStatus } from '@/api/types';

// Verbatim shape of the owner's live H2C (2026-07-19): an AMS 2 Pro at id 0 alongside an AMS HT at
// id 128. The HT's single tray is LOCAL id 0 — the same number as AMS-0's first tray, which is the
// whole reason tray_now must be compared against the global id.
const live = (over: Partial<PrinterStatus> = {}): PrinterStatus =>
  ({
    connected: true,
    state: 'RUNNING',
    tray_now: 0,
    ams_extruder_map: { '0': 0, '128': 1 },
    ams: [
      {
        id: 0,
        module_type: 'n3f',
        is_ams_ht: false,
        humidity: 19,
        temp: 40.7,
        serial_number: 'FAKESERIALAMS001',
        dry_time: 0,
        tray: [
          { id: 0, tray_type: 'PETG', tray_color: '000000FF', remain: 18 },
          { id: 1, tray_type: 'PETG', tray_color: 'C9A38180', remain: 81 },
          { id: 2, tray_type: 'PETG', tray_color: '000000FF', remain: 75 },
          { id: 3, tray_type: 'PETG', tray_color: 'F330F9FF', remain: -1 },
        ],
      },
      {
        id: 128,
        module_type: 'n3s',
        is_ams_ht: true,
        humidity: 17,
        temp: 32,
        serial_number: 'FAKESERIALHT0002',
        dry_time: 0,
        tray: [{ id: 0, tray_type: 'PETG-CF', tray_color: '565656FF', remain: 96 }],
      },
    ],
    ...over,
  }) as unknown as PrinterStatus;

describe('globalTrayId', () => {
  it('packs regular units 4 trays apart', () => {
    expect(globalTrayId(0, 0)).toBe(0);
    expect(globalTrayId(0, 3)).toBe(3);
    expect(globalTrayId(1, 0)).toBe(4); // the second AMS 2 Pro
    expect(globalTrayId(1, 3)).toBe(7);
  });
  it('an AMS HT IS its own tray id (128+)', () => {
    expect(globalTrayId(128, 0)).toBe(128);
    expect(globalTrayId(129, 0)).toBe(129);
  });
});

describe('presentAms', () => {
  it('returns both units with the right kind, capacity and drying ceiling', () => {
    const { units } = presentAms(live());
    expect(units).toHaveLength(2);
    expect(units[0]).toMatchObject({ id: 0, label: 'AMS 1', kind: 'ams', capacity: 4, loaded: 4, maxDryTemp: 65, extruder: 0, serialTail: 'S001' });
    expect(units[1]).toMatchObject({ id: 128, label: 'AMS HT', kind: 'ht', capacity: 1, loaded: 1, maxDryTemp: 85, extruder: 1 });
  });

  it('flattens every slot across units, keeping unit + global ids', () => {
    const { slots } = presentAms(live());
    expect(slots).toHaveLength(5); // 4 + 1 — the HT slot was invisible before
    expect(slots.map((s) => s.globalId)).toEqual([0, 1, 2, 3, 128]);
    expect(slots[4]).toMatchObject({ unitId: 128, unitLabel: 'AMS HT', localId: 0, label: 'PETG-CF' });
  });

  it('THE TRAP: tray_now 0 lights AMS-0 slot 0 only — never the HT tray, which is also local 0', () => {
    const { slots } = presentAms(live({ tray_now: 0 } as Partial<PrinterStatus>));
    expect(slots[0].active).toBe(true);
    expect(slots[4].active).toBe(false);
  });

  it('tray_now 128 lights the HT tray', () => {
    const { slots } = presentAms(live({ tray_now: 128 } as Partial<PrinterStatus>));
    expect(slots.filter((s) => s.active).map((s) => s.unitId)).toEqual([128]);
  });

  it('an empty tray is never active, and renders as Empty', () => {
    const s = live();
    (s.ams as { tray: { tray_type?: string }[] }[])[0].tray[0].tray_type = undefined;
    const { slots } = presentAms({ ...s, tray_now: 0 } as PrinterStatus);
    expect(slots[0]).toMatchObject({ empty: true, active: false, label: 'Empty', pct: '—' });
  });

  it('numbers a SECOND AMS 2 Pro from its own id, not array position', () => {
    const s = live();
    (s.ams as unknown[]).splice(1, 0, {
      id: 1, module_type: 'n3f', is_ams_ht: false, humidity: 20, temp: 30, tray: [{ id: 0, tray_type: 'PLA' }],
    });
    const { units, slots } = presentAms(s);
    expect(units.map((u) => u.label)).toEqual(['AMS 1', 'AMS 2', 'AMS HT']);
    expect(slots.find((x) => x.unitId === 1)?.globalId).toBe(4);
  });

  it('tolerates WebSocket string numbers (ids, temps, remain all arrive as strings)', () => {
    const s = live();
    const u = s.ams as unknown as Record<string, unknown>[];
    u[1].id = '128';
    u[1].humidity = '17';
    (u[0].tray as Record<string, unknown>[])[0].id = '0';
    const { units, slots } = presentAms({ ...s, tray_now: '128' } as unknown as PrinterStatus);
    expect(units[1]).toMatchObject({ id: 128, kind: 'ht', humidity: 17 });
    expect(slots.find((x) => x.globalId === 128)?.active).toBe(true);
  });

  it('an HT identified only by module_type/id still gets the 85° ceiling', () => {
    const s = live();
    delete (s.ams as unknown as Record<string, unknown>[])[1].is_ams_ht;
    expect(presentAms(s).units[1]).toMatchObject({ kind: 'ht', maxDryTemp: 85 });
  });

  it('no AMS at all is empty, not a crash', () => {
    expect(presentAms(null)).toEqual({ units: [], slots: [] });
    expect(presentAms({ connected: true } as PrinterStatus)).toEqual({ units: [], slots: [] });
  });
});
