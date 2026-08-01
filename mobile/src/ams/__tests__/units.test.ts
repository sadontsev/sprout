import { extruderSide, globalTrayId, presentAms, switchExtruderForTray } from '@/ams/units';
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
    expect(presentAms(null)).toEqual({ units: [], slots: [], routing: 'fixed' });
    expect(presentAms({ connected: true } as PrinterStatus)).toEqual({ units: [], slots: [], routing: 'fixed' });
  });
});

describe('extruder routing with a Filament Track Switch', () => {
  // The owner's live H2C (2026-08-01): two AMS 2 Pro + an AMS HT + an FTS. The extruder map is
  // STALE RESIDUE from before the switch was fitted — Bambuddy builds it from each unit's `info`
  // bits and skips units reporting 0xE ("no fixed extruder"), which is what FTS-routed units report
  // permanently. The map is merge-only and never pruned, so unit 1 (added after the switch) can
  // never gain an entry while units 0 and 128 keep theirs forever.
  const threeUnits = {
    connected: true,
    ams: [
      { id: 0, module_type: 'n3f', tray: [{ id: 0 }, { id: 1, tray_type: 'PETG' }, { id: 2, tray_type: 'PETG' }, { id: 3 }] },
      { id: 1, module_type: 'n3f', tray: [{ id: 0 }, { id: 1, tray_type: 'PETG' }, { id: 2 }, { id: 3, tray_type: 'PETG' }] },
      { id: 128, module_type: 'n3s', is_ams_ht: true, tray: [{ id: 0, tray_type: 'PETG-CF' }] },
    ],
    ams_extruder_map: { '0': 0, '128': 1 },
  } as unknown as PrinterStatus;

  it('reports every unit and every slot for a three-unit machine', () => {
    const { units, slots } = presentAms(threeUnits);
    expect(units.map((u) => u.label)).toEqual(['AMS 1', 'AMS 2', 'AMS HT']);
    expect(slots).toHaveLength(9);
    expect(slots.map((s) => s.globalId)).toEqual([0, 1, 2, 3, 4, 5, 6, 7, 128]);
  });

  it('IGNORES the stale extruder map once a switch is installed', () => {
    const withSwitch = { ...threeUnits, fila_switch: { installed: true, in_slots: [-1, 1], out_extruders: [1, 0] } } as PrinterStatus;
    const { units, routing } = presentAms(withSwitch);
    expect(routing).toBe('switch');
    // Showing "AMS 1 -> Right" here would be a lie: routing is dynamic.
    expect(units.map((u) => u.extruder)).toEqual([null, null, null]);
  });

  it('still honours the map when NO switch is installed', () => {
    const { units, routing } = presentAms(threeUnits);
    expect(routing).toBe('fixed');
    expect(units.map((u) => u.extruder)).toEqual([0, null, 1]);
  });

  it('leaves an unmapped unit null rather than defaulting it to extruder 0', () => {
    // extruder 0 is a REAL head (the right one); defaulting to it would invent a binding.
    expect(presentAms(threeUnits).units[1].extruder).toBeNull();
  });

  it('treats a missing or false fila_switch as classic fixed wiring', () => {
    for (const fs of [undefined, { installed: false }, {}]) {
      const st = { ...threeUnits, fila_switch: fs } as PrinterStatus;
      expect(presentAms(st).routing).toBe('fixed');
    }
  });
});

describe('extruderSide', () => {
  it('maps 0 to RIGHT and 1 to LEFT — the H2 convention, which the AMS tab had inverted', () => {
    expect(extruderSide(0)).toBe('Right');
    expect(extruderSide(1)).toBe('Left');
  });

  it('is empty for an unknown binding, so callers render nothing rather than guessing', () => {
    for (const e of [null, undefined, 2, -1]) expect(extruderSide(e)).toBe('');
  });
});

describe('HT labelling stays consistent with HT classification', () => {
  it('numbers multiple HTs even when they omit is_ams_ht and are known only by their 128+ id', () => {
    // htTotal used to count is_ams_ht===true while `kind` also accepted id>=128, so two such units
    // both rendered a bare "AMS HT" and were indistinguishable.
    const twoHt = {
      connected: true,
      ams: [
        { id: 128, module_type: 'n3s', tray: [{ id: 0, tray_type: 'PLA' }] },
        { id: 129, module_type: 'n3s', tray: [{ id: 0, tray_type: 'PETG' }] },
      ],
    } as unknown as PrinterStatus;
    const { units } = presentAms(twoHt);
    expect(units.map((u) => u.label)).toEqual(['AMS HT 1', 'AMS HT 2']);
    expect(units.every((u) => u.kind === 'ht')).toBe(true);
  });
});

describe('switchExtruderForTray — live routing through the Filament Track Switch', () => {
  // The FTS has TWO tracks regardless of how many AMS units are chained in. in_slots[track] is the
  // GLOBAL tray id on that track, out_extruders[track] is the nozzle it terminates at. This mirrors
  // Bambuddy's own web UI, and it is the only routing answer that exists once a switch is fitted.
  const live = {
    connected: true,
    ams: [
      { id: 0, module_type: 'n3f', tray: [{ id: 0 }, { id: 1, tray_type: 'PETG' }, { id: 2 }, { id: 3 }] },
      { id: 1, module_type: 'n3f', tray: [{ id: 0 }, { id: 1, tray_type: 'PETG' }, { id: 2 }, { id: 3 }] },
    ],
    // Track 0 empty -> left; track 1 holds global tray 1 -> right. Exactly the owner's live values.
    fila_switch: { installed: true, in_slots: [-1, 1], out_extruders: [1, 0] },
  } as unknown as PrinterStatus;

  it('resolves the loaded tray to the nozzle its track feeds', () => {
    expect(switchExtruderForTray(live, 1)).toBe(0); // track 1 -> extruder 0 (Right)
  });

  it('is null for a tray that is not on a track', () => {
    for (const gid of [0, 2, 4, 5, 128]) expect(switchExtruderForTray(live, gid)).toBeNull();
  });

  it('is null when no switch is installed', () => {
    expect(switchExtruderForTray({ ...live, fila_switch: { installed: false, in_slots: [-1, 1], out_extruders: [1, 0] } } as PrinterStatus, 1)).toBeNull();
    expect(switchExtruderForTray({ ...live, fila_switch: undefined } as PrinterStatus, 1)).toBeNull();
    expect(switchExtruderForTray(null, 1)).toBeNull();
  });

  it('treats 0xE as "no outlet" rather than extruder 14', () => {
    const noOut = { ...live, fila_switch: { installed: true, in_slots: [1, -1], out_extruders: [0xe, 0] } } as PrinterStatus;
    expect(switchExtruderForTray(noOut, 1)).toBeNull();
  });

  it('survives malformed/short arrays', () => {
    for (const fs of [{ installed: true }, { installed: true, in_slots: [1] }, { installed: true, in_slots: [1], out_extruders: [] }])
      expect(switchExtruderForTray({ ...live, fila_switch: fs } as PrinterStatus, 1)).toBeNull();
  });

  it('puts the routing on the SLOT, since the unit no longer has one', () => {
    const { slots, units } = presentAms(live);
    const loaded = slots.find((s) => s.globalId === 1)!;
    expect(loaded.extruder).toBe(0); // this spool feeds the Right nozzle
    expect(slots.find((s) => s.globalId === 5)!.extruder).toBeNull(); // loaded, but not on a track
    expect(units.every((u) => u.extruder === null)).toBe(true); // no unit-level binding exists
  });

  it('falls back to the unit binding on a machine with no switch', () => {
    const classic = { ...live, fila_switch: undefined, ams_extruder_map: { '0': 0, '1': 1 } } as PrinterStatus;
    const { slots } = presentAms(classic);
    expect(slots.find((s) => s.globalId === 1)!.extruder).toBe(0);
    expect(slots.find((s) => s.globalId === 5)!.extruder).toBe(1);
  });
});
