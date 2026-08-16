import { reconcileSelection, initialSelectionState, type SelectionState } from '../selection';

const fleet = (ids: number[]) => ids.map((id) => ({ id, name: `P${id}` }));
const confirmed: SelectionState = { missed: 0, everMatched: true };

test('adopts the first printer immediately when the selection was never confirmed (guessed id 1, real id 2)', () => {
  const r = reconcileSelection(fleet([2]), 1, initialSelectionState);
  expect(r.action).toEqual({ type: 'select', id: 2, name: 'P2' });
});

test('keeps the selection when present in the fleet, marking it confirmed', () => {
  const r = reconcileSelection(fleet([1, 2]), 2, initialSelectionState);
  expect(r.action).toEqual({ type: 'keep' });
  expect(r.state).toEqual({ missed: 0, everMatched: true });
});

test('a confirmed selection that vanishes heals only on the SECOND consecutive miss', () => {
  const first = reconcileSelection(fleet([9]), 2, confirmed); // 2 gone once
  expect(first.action).toEqual({ type: 'keep' });
  expect(first.state.missed).toBe(1);
  const second = reconcileSelection(fleet([9]), 2, first.state); // gone again
  expect(second.action).toEqual({ type: 'select', id: 9, name: 'P9' });
  expect(second.state.missed).toBe(0);
});

test('a transient single miss does NOT rewrite a confirmed selection that reappears', () => {
  const miss = reconcileSelection(fleet([9]), 2, confirmed); // blip: 2 missing
  expect(miss.action).toEqual({ type: 'keep' });
  const back = reconcileSelection(fleet([2, 9]), 2, miss.state); // 2 back next poll
  expect(back.action).toEqual({ type: 'keep' });
  expect(back.state).toEqual({ missed: 0, everMatched: true });
});

test('empty fleet is a no-op and does not count as a miss', () => {
  const r = reconcileSelection([], 1, initialSelectionState);
  expect(r.action).toEqual({ type: 'keep' });
  expect(r.state).toEqual(initialSelectionState);
});

test('once adopted, the new id is kept on the next fleet response', () => {
  const adopt = reconcileSelection(fleet([2]), 1, initialSelectionState);
  expect(adopt.action).toEqual({ type: 'select', id: 2, name: 'P2' });
  // Shell now sets printerId=2; next effect run sees current=2.
  const keep = reconcileSelection(fleet([2]), 2, adopt.state);
  expect(keep.action).toEqual({ type: 'keep' });
  expect(keep.state.everMatched).toBe(true);
});
