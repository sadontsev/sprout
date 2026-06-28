// iOS Live Activity for an active print — Lock Screen banner + Dynamic Island.
//
// This module is authored with expo-widgets (@expo/ui/swift-ui). The component function carries the
// 'widget' directive: it runs in an ISOLATED runtime (no hooks, no app imports, no closures over app
// state) — only the `props`/`environment` args and @expo/ui primitives. Keep it pure; colors are
// hardcoded or passed in via props (the app theme can't be imported here).
import { createLiveActivity, type LiveActivityEnvironment } from 'expo-widgets';
import { HStack, VStack, Text, Image, Spacer, ProgressView } from '@expo/ui/swift-ui';
import { font, foregroundStyle, padding, tint } from '@expo/ui/swift-ui/modifiers';

/** Flat, JSON-serializable ContentState the activity renders (also the APNs content-state shape for v2). */
export type PrintActivityProps = {
  name: string; // subtask/file name
  stateLabel: string; // "Printing" | "Heating" | "Paused" | "Complete" | "Error"
  progress: number; // 0..100
  layer: number;
  totalLayers: number; // 0 if unknown
  etaEpochMs: number; // absolute finish time, ms epoch; 0 if unknown
  finished: boolean;
  symbol: string; // SF Symbol name
  tint: string; // hex accent
};

const PrintActivity = (p: PrintActivityProps, _env: LiveActivityEnvironment) => {
  'widget';
  // NOTE: this function is stringified by babel-preset-expo's widgets plugin and re-evaluated in an
  // isolated native runtime. It must NOT reference any module-scope identifiers except the @expo/ui
  // primitives the runtime injects — so all constants/helpers live INSIDE the function body.
  const T1 = '#F3F5F7';
  const T2 = '#A4ABB2';
  const pct = `${Math.max(0, Math.min(100, Math.round(p.progress)))}%`;
  const layers = p.totalLayers > 0 ? `${p.layer}/${p.totalLayers}` : `${p.layer}`;
  const eta = p.etaEpochMs > 0 && !p.finished;

  return {
    // Lock-screen / Notification Center banner
    banner: (
      <VStack alignment="leading" spacing={10} modifiers={[padding({ all: 14 })]}>
        <HStack spacing={12}>
          <Image systemName={p.symbol as never} color={p.tint} size={26} />
          <VStack alignment="leading" spacing={2}>
            <Text modifiers={[font({ size: 15, weight: 'semibold' }), foregroundStyle(T1)]}>{p.name || 'Bambu A1'}</Text>
            <Text modifiers={[font({ size: 12 }), foregroundStyle(T2)]}>{p.stateLabel} · Layer {layers}</Text>
          </VStack>
          <Spacer />
          <VStack alignment="trailing" spacing={2}>
            <Text modifiers={[font({ size: 20, weight: 'bold', design: 'rounded' }), foregroundStyle(p.tint)]}>{pct}</Text>
            {eta ? (
              <Text modifiers={[font({ size: 12 }), foregroundStyle(T2)]} date={new Date(p.etaEpochMs)} dateStyle="timer" />
            ) : (
              <Text modifiers={[font({ size: 12 }), foregroundStyle(T2)]}>{p.finished ? 'Done' : '—'}</Text>
            )}
          </VStack>
        </HStack>
        <ProgressView value={Math.max(0, Math.min(1, p.progress / 100))} modifiers={[tint(p.tint)]} />
      </VStack>
    ),
    // Dynamic Island — compact
    compactLeading: <Image systemName={p.symbol as never} color={p.tint} size={16} />,
    compactTrailing: <Text modifiers={[font({ size: 13, weight: 'semibold', design: 'rounded' }), foregroundStyle(p.tint)]}>{pct}</Text>,
    // Dynamic Island — minimal (when multiple activities)
    minimal: <Image systemName={p.symbol as never} color={p.tint} size={14} />,
    // Dynamic Island — expanded
    expandedLeading: (
      <VStack alignment="leading" spacing={1} modifiers={[padding({ leading: 6 })]}>
        <Text modifiers={[font({ size: 13, weight: 'semibold' }), foregroundStyle(T1)]}>{p.stateLabel}</Text>
        <Text modifiers={[font({ size: 11 }), foregroundStyle(T2)]}>Layer {layers}</Text>
      </VStack>
    ),
    expandedTrailing: (
      <VStack alignment="trailing" spacing={1} modifiers={[padding({ trailing: 6 })]}>
        <Text modifiers={[font({ size: 16, weight: 'bold', design: 'rounded' }), foregroundStyle(p.tint)]}>{pct}</Text>
        {eta ? (
          <Text modifiers={[font({ size: 11 }), foregroundStyle(T2)]} date={new Date(p.etaEpochMs)} dateStyle="timer" />
        ) : (
          <Text modifiers={[font({ size: 11 }), foregroundStyle(T2)]}>{p.finished ? 'Done' : ''}</Text>
        )}
      </VStack>
    ),
    expandedBottom: (
      <VStack spacing={6} modifiers={[padding({ horizontal: 6, top: 4 })]}>
        <ProgressView value={Math.max(0, Math.min(1, p.progress / 100))} modifiers={[tint(p.tint)]} />
        <Text modifiers={[font({ size: 12 }), foregroundStyle(T2)]}>{p.name || 'Bambu A1'}</Text>
      </VStack>
    ),
  };
};

export const printActivity = createLiveActivity<PrintActivityProps>('PrintActivity', PrintActivity);
export default printActivity;
