// Pure browse/search/selection logic for the library list — kept out of TabScreens so it's testable
// (the component pulls in reanimated, which jest can't load).
import type { LibraryFile } from '../api/types';

export type TypeFilter = 'all' | 'models' | 'sliced';

/** Sliced = printable as-is (G-code inside). Everything else is a model that needs slicing. */
export const isSlicedFile = (f: LibraryFile): boolean => (f.file_type || '').includes('gcode') || !!f.sliced_for_model;

/** Display name: prefer print_name; decode %20-style residue from URL-encoded uploads. */
export function displayName(f: LibraryFile): string {
  const raw = f.print_name || f.filename || `file-${f.id}`;
  try {
    return decodeURIComponent(raw);
  } catch {
    return raw;
  }
}

/**
 * Type filter + case-insensitive substring search. The query matches the DECODED display name plus
 * the raw filename (so "hexagon" finds "Adapter%20hexagon%20…" either way). Empty/whitespace query
 * matches everything.
 */
export function filterFiles(files: readonly LibraryFile[], filter: TypeFilter, query: string): LibraryFile[] {
  const q = query.trim().toLowerCase();
  return files.filter((f) => {
    if (filter === 'sliced' && !isSlicedFile(f)) return false;
    if (filter === 'models' && isSlicedFile(f)) return false;
    if (!q) return true;
    return displayName(f).toLowerCase().includes(q) || (f.filename || '').toLowerCase().includes(q);
  });
}

/** Immutable toggle for the bulk-selection set. */
export function toggleSelection(selected: ReadonlySet<number>, id: number): Set<number> {
  const next = new Set(selected);
  if (next.has(id)) next.delete(id);
  else next.add(id);
  return next;
}
