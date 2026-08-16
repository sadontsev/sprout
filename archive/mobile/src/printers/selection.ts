import type { Printer } from '../api/types';

/** Running state for the fleet-selection reconciler (held in a ref by the Shell). */
export interface SelectionState {
  /** Consecutive fleet responses in which the selected id was absent. */
  missed: number;
  /** Whether the selected id has EVER appeared in a fleet response. */
  everMatched: boolean;
}

export const initialSelectionState: SelectionState = { missed: 0, everMatched: false };

export type SelectionAction = { type: 'keep' } | { type: 'select'; id: number; name: string };

/**
 * Pure decision for "which printer should be selected" given the freshly-loaded fleet, the current
 * selection, and the running state. Mutates nothing — returns the next state plus an action.
 *
 * - Current id present in the fleet → keep it (and mark it confirmed).
 * - Current id absent:
 *   - NEVER confirmed (a fresh connect, or a guessed default like id 1 when the real printer is id 2)
 *     → adopt the first printer IMMEDIATELY. No reason to sit on "Connecting" for a minute while a
 *     two-strike heal counts up.
 *   - Previously confirmed, then vanished → wait for a SECOND consecutive miss before switching. A
 *     single absence can be a transient list blip (is_active toggled during maintenance, a flaky
 *     response); switching on a blip would rewrite a good persisted selection.
 * - Empty fleet → keep (nothing to select; not counted as a miss).
 */
export function reconcileSelection(
  fleet: Pick<Printer, 'id' | 'name'>[],
  current: number,
  state: SelectionState,
): { state: SelectionState; action: SelectionAction } {
  if (fleet.length === 0) return { state, action: { type: 'keep' } };
  if (fleet.some((p) => p.id === current)) {
    return { state: { missed: 0, everMatched: true }, action: { type: 'keep' } };
  }
  const threshold = state.everMatched ? 2 : 1;
  const missed = state.missed + 1;
  if (missed < threshold) return { state: { ...state, missed }, action: { type: 'keep' } };
  const next = fleet[0];
  return { state: { missed: 0, everMatched: state.everMatched }, action: { type: 'select', id: next.id, name: next.name } };
}
