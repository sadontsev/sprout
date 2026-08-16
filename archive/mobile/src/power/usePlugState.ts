import { useCallback, useEffect, useRef, useState } from 'react';
import type { BambuddyClient } from '@/api/bambuddyClient';
import type { SmartPlug } from '@/api/types';

export interface PlugState {
  on: boolean;
  reachable: boolean;
  watts: number | null;
  kwh: number | null;
  /** Optimistic write: flips immediately, reverts if Bambuddy rejects it. */
  set: (next: boolean) => Promise<void>;
}

/** Live state for one plug: polls status and applies optimistic toggles.
 *  Shared by the printer's hero control and the peripheral rows so the settle/revert behaviour
 *  can't drift between them. */
export function usePlugState(client: BambuddyClient, plug: SmartPlug | null | undefined, periodMs = 5000): PlugState {
  const [on, setOn] = useState(false);
  const [reachable, setReachable] = useState(true);
  const [watts, setWatts] = useState<number | null>(null);
  const [kwh, setKwh] = useState<number | null>(null);
  // While a toggle is settling, ignore poll results — HA takes a few seconds to reflect the new
  // state and the stale poll would visibly bounce the switch back.
  const pendingUntil = useRef(0);
  const id = plug?.id;

  useEffect(() => {
    if (id == null) return;
    let alive = true;
    const poll = () =>
      client
        .plugStatus(id)
        .then((s) => {
          if (!alive || Date.now() < pendingUntil.current) return;
          setOn(s.state?.toUpperCase() === 'ON');
          setReachable(!!s.reachable);
          const e = s.energy ?? null;
          setWatts(typeof e?.power === 'number' ? e.power : null);
          setKwh(typeof e?.today === 'number' ? e.today : null);
        })
        .catch(() => alive && setReachable(false));
    poll();
    const t = setInterval(poll, periodMs);
    return () => {
      alive = false;
      clearInterval(t);
    };
  }, [client, id, periodMs]);

  const set = useCallback(
    async (next: boolean) => {
      if (id == null) return;
      setOn(next);
      pendingUntil.current = Date.now() + 8000;
      try {
        await client.plugControl(id, next);
      } catch (e) {
        pendingUntil.current = 0;
        setOn(!next);
        throw e;
      }
    },
    [client, id],
  );

  return { on, reachable, watts, kwh, set };
}
