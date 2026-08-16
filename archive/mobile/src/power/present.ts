import type { SmartPlug } from '@/api/types';

/** One server-side rule that can switch a plug with nobody watching.
 *  `cuts` marks the dangerous direction: it can kill power to a running print. */
export interface PlugAutomation {
  key: 'auto_on' | 'auto_off' | 'after_drying' | 'schedule';
  label: string;
  detail: string;
  cuts: boolean;
}

const hhmm = (t: string | null | undefined): string | null => (/^([01]\d|2[0-3]):[0-5]\d$/.test(t ?? '') ? (t as string) : null);

/** Every automation currently ARMED on a plug, in the order a user would want to read them.
 *  Bambuddy runs these itself — the app cannot change them (writes are admin-only), so the only
 *  honest thing the UI can do is show them accurately. */
export function plugAutomations(plug: SmartPlug | null | undefined): PlugAutomation[] {
  if (!plug) return [];
  const out: PlugAutomation[] = [];

  if (plug.auto_on) {
    out.push({ key: 'auto_on', label: 'Auto power-on', detail: 'Switches on when a print starts.', cuts: false });
  }

  if (plug.auto_off) {
    // Two shapes of the same rule; the mode decides which threshold actually applies.
    const detail =
      plug.off_delay_mode === 'temperature'
        ? `Switches off after a print, once the hotend cools below ${plug.off_temp_threshold ?? 70}°C.`
        : `Switches off ${plug.off_delay_minutes ?? 5} min after a print finishes.`;
    out.push({
      key: 'auto_off',
      label: 'Auto power-off',
      detail: plug.auto_off_persistent ? `${detail} Survives a Bambuddy restart.` : detail,
      cuts: true,
    });
  }

  if (plug.auto_off_after_drying) {
    out.push({
      key: 'after_drying',
      label: 'Off after drying',
      detail: `Switches off ${plug.off_delay_after_drying_minutes ?? 10} min after AMS drying finishes.`,
      cuts: true,
    });
  }

  // A schedule counts as armed only if it has a time to act on — an enabled schedule with both
  // fields null does nothing, and reporting it would be a phantom warning.
  if (plug.schedule_enabled) {
    const on = hhmm(plug.schedule_on_time);
    const off = hhmm(plug.schedule_off_time);
    if (on || off) {
      const parts = [on && `on at ${on}`, off && `off at ${off}`].filter(Boolean);
      out.push({ key: 'schedule', label: 'Schedule', detail: `Switches ${parts.join(', ')} every day.`, cuts: !!off });
    }
  }

  return out;
}

/** Plugs other than the printer's own, stably ordered. Disabled plugs are dropped: Bambuddy will
 *  not act on them, so a dead row would just be noise. */
export function otherPlugs(all: SmartPlug[] | null | undefined, printerPlugId: number | null | undefined): SmartPlug[] {
  return (all ?? [])
    .filter((p) => p && p.id !== printerPlugId && p.enabled !== false)
    .sort((a, b) => a.id - b.id);
}

/** One line for the whole plug: what will happen on its own, if anything. */
export function automationSummary(plug: SmartPlug | null | undefined): string {
  const list = plugAutomations(plug);
  if (!list.length) return 'Nothing switches this plug automatically.';
  return list.map((a) => a.label).join(' · ');
}

export const plugLabel = (p: SmartPlug | null | undefined): string => p?.name?.trim() || (p ? `Plug ${p.id}` : 'Smart plug');
