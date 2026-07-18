import { filterFiles, toggleSelection, displayName, isSlicedFile } from '@/library/libraryBrowse';
import type { LibraryFile } from '@/api/types';

const f = (id: number, filename: string, extra: Partial<LibraryFile> = {}): LibraryFile =>
  ({ id, filename, file_type: filename.split('.').pop() || '', ...extra }) as LibraryFile;

const FILES: LibraryFile[] = [
  f(1, 'Adapter%20hexagon%20for%20electric%20drill.stl'),
  f(2, 'caldera-E-clean.gcode.3mf', { file_type: 'gcode.3mf' }),
  f(3, 'benchy.3mf'),
  f(4, 'vase-textured.stl', { print_name: 'Spiral Vase' }),
];

describe('displayName', () => {
  it('decodes %20 residue and prefers print_name', () => {
    expect(displayName(FILES[0])).toBe('Adapter hexagon for electric drill.stl');
    expect(displayName(FILES[3])).toBe('Spiral Vase');
  });
  it('survives malformed percent-sequences', () => {
    expect(displayName(f(9, 'bad%zz.stl'))).toBe('bad%zz.stl');
  });
});

describe('filterFiles', () => {
  it('empty query returns everything for the type filter', () => {
    expect(filterFiles(FILES, 'all', '')).toHaveLength(4);
    expect(filterFiles(FILES, 'sliced', '  ')).toEqual([FILES[1]]);
    expect(filterFiles(FILES, 'models', '')).toHaveLength(3);
  });
  it('searches the DECODED name (finds "hexagon" despite %20 in the raw filename)', () => {
    expect(filterFiles(FILES, 'all', 'hexagon for')).toEqual([FILES[0]]);
  });
  it('searches print_name and is case-insensitive', () => {
    expect(filterFiles(FILES, 'all', 'SPIRAL')).toEqual([FILES[3]]);
  });
  it('search composes with the type filter', () => {
    expect(filterFiles(FILES, 'sliced', 'caldera')).toEqual([FILES[1]]);
    expect(filterFiles(FILES, 'models', 'caldera')).toEqual([]);
  });
  it('no matches -> empty array (drives the "no results" state)', () => {
    expect(filterFiles(FILES, 'all', 'zzz-nope')).toEqual([]);
  });
});

describe('toggleSelection', () => {
  it('adds, removes, and never mutates the input set', () => {
    const s0 = new Set<number>();
    const s1 = toggleSelection(s0, 1);
    const s2 = toggleSelection(s1, 2);
    const s3 = toggleSelection(s2, 1);
    expect([...s3]).toEqual([2]);
    expect(s0.size).toBe(0);
    expect(s1.has(1)).toBe(true);
  });
});

test('isSlicedFile treats gcode types and sliced_for_model as sliced', () => {
  expect(isSlicedFile(FILES[1])).toBe(true);
  expect(isSlicedFile(f(5, 'x.3mf', { sliced_for_model: 'H2C' }))).toBe(true);
  expect(isSlicedFile(FILES[0])).toBe(false);
});
