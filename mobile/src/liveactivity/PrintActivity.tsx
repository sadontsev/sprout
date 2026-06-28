// iOS Live Activity for an active print — Lock Screen banner + Dynamic Island.
//
// This module is authored with expo-widgets (@expo/ui/swift-ui). The component function carries the
// 'widget' directive: babel-preset-expo's widgets plugin STRINGIFIES only this function's params +
// body and re-evaluates it in an isolated native runtime where only the @expo/ui primitives are
// injected. So the function must be FULLY SELF-CONTAINED — every constant/helper lives inside it; it
// may reference only its args (`p`, `_env`), `Math`/`Date`, and the @expo/ui components/modifiers.
import { createLiveActivity, type LiveActivityEnvironment } from 'expo-widgets';
import { HStack, VStack, Text, Image, Spacer, ProgressView } from '@expo/ui/swift-ui';
import { font, foregroundStyle, padding, tint, frame, resizable, aspectRatio } from '@expo/ui/swift-ui/modifiers';

/** Flat, JSON-serializable ContentState the activity renders. */
export type PrintActivityProps = {
  name: string; // subtask/file name
  stateLabel: string; // "Printing" | "Heating" | "Paused" | "Complete" | "Error"
  progress: number; // 0..100
  layer: number;
  totalLayers: number; // 0 if unknown
  etaEpochMs: number; // absolute finish time, ms epoch; 0 if unknown
  finished: boolean;
  symbol: string; // SF Symbol fallback name
  iconUri: string; // file:// URI of the brand nozzle glyph in the App Group ('' -> fall back to symbol)
  tint: string; // hex accent
  nozzle: number;
  nozzleTarget: number;
  bed: number;
  bedTarget: number;
};

const PrintActivity = (p: PrintActivityProps, _env: LiveActivityEnvironment) => {
  'widget';
  const T1 = '#F3F5F7';
  const T2 = '#A4ABB2';
  const pct = `${Math.max(0, Math.min(100, Math.round(p.progress)))}%`;
  const layers = p.totalLayers > 0 ? `${p.layer}/${p.totalLayers}` : `${p.layer}`;
  const eta = p.etaEpochMs > 0 && !p.finished;
  const endDate = new Date(p.etaEpochMs || Date.now());
  const temp = (cur: number, target: number) => (target > 0 && target !== cur ? `${cur}/${target}°` : `${cur}°`);
  const tempsLine = `Nozzle ${temp(p.nozzle, p.nozzleTarget)}  ·  Bed ${temp(p.bed, p.bedTarget)}`;
  // Brand nozzle glyph from the App Group (uiImage); falls back to the SF symbol if unavailable.
  const glyph = (s: number) =>
    p.iconUri
      ? <Image uiImage={p.iconUri} modifiers={[resizable(), aspectRatio({ contentMode: 'fit' }), frame({ width: s, height: s })]} />
      : <Image systemName={p.symbol as never} color={p.tint} size={s} />;

  return {
    // Lock-screen / Notification Center banner
    banner: (
      <VStack alignment="leading" spacing={9} modifiers={[padding({ all: 14 })]}>
        <HStack spacing={12}>
          {glyph(26)}
          <VStack alignment="leading" spacing={2}>
            <Text modifiers={[font({ size: 15, weight: 'semibold' }), foregroundStyle(T1)]}>{p.name || 'Bambu A1'}</Text>
            <Text modifiers={[font({ size: 12 }), foregroundStyle(T2)]}>{p.stateLabel} · Layer {layers}</Text>
          </VStack>
          <Spacer />
          <VStack alignment="trailing" spacing={1}>
            <Text modifiers={[font({ size: 22, weight: 'bold', design: 'rounded' }), foregroundStyle(p.tint)]}>{pct}</Text>
            {eta ? (
              <HStack spacing={3}>
                <Text modifiers={[font({ size: 11 }), foregroundStyle(T2)]}>ends</Text>
                <Text modifiers={[font({ size: 11, weight: 'medium' }), foregroundStyle(T1)]} date={endDate} dateStyle="time" />
              </HStack>
            ) : (
              <Text modifiers={[font({ size: 11 }), foregroundStyle(T2)]}>{p.finished ? 'Done' : '—'}</Text>
            )}
          </VStack>
        </HStack>
        <ProgressView value={Math.max(0, Math.min(1, p.progress / 100))} modifiers={[tint(p.tint)]} />
        <HStack spacing={8}>
          <Text modifiers={[font({ size: 11 }), foregroundStyle(T2)]}>{tempsLine}</Text>
          <Spacer />
          {eta ? (
            <Text modifiers={[font({ size: 11, weight: 'semibold', design: 'rounded' }), foregroundStyle(T2)]} date={endDate} dateStyle="timer" />
          ) : null}
        </HStack>
      </VStack>
    ),
    // Dynamic Island — compact: glyph + end clock time (not %, per request)
    compactLeading: glyph(16),
    compactTrailing: eta ? (
      <Text modifiers={[font({ size: 13, weight: 'semibold', design: 'rounded' }), foregroundStyle(p.tint)]} date={endDate} dateStyle="time" />
    ) : (
      <Text modifiers={[font({ size: 13, weight: 'semibold', design: 'rounded' }), foregroundStyle(p.tint)]}>{p.finished ? 'Done' : pct}</Text>
    ),
    // Dynamic Island — minimal
    minimal: glyph(14),
    // Dynamic Island — expanded
    expandedLeading: (
      <VStack alignment="leading" spacing={1} modifiers={[padding({ leading: 6 })]}>
        <Text modifiers={[font({ size: 13, weight: 'semibold' }), foregroundStyle(T1)]}>{p.stateLabel}</Text>
        <Text modifiers={[font({ size: 11 }), foregroundStyle(T2)]}>Layer {layers}</Text>
      </VStack>
    ),
    expandedTrailing: (
      <VStack alignment="trailing" spacing={1} modifiers={[padding({ trailing: 6 })]}>
        <Text modifiers={[font({ size: 17, weight: 'bold', design: 'rounded' }), foregroundStyle(p.tint)]}>{pct}</Text>
        {eta ? (
          <Text modifiers={[font({ size: 11 }), foregroundStyle(T2)]} date={endDate} dateStyle="timer" />
        ) : (
          <Text modifiers={[font({ size: 11 }), foregroundStyle(T2)]}>{p.finished ? 'Done' : ''}</Text>
        )}
      </VStack>
    ),
    expandedBottom: (
      <VStack spacing={6} modifiers={[padding({ horizontal: 6, top: 4 })]}>
        <ProgressView value={Math.max(0, Math.min(1, p.progress / 100))} modifiers={[tint(p.tint)]} />
        <HStack spacing={8}>
          <Text modifiers={[font({ size: 11 }), foregroundStyle(T2)]}>{tempsLine}</Text>
          <Spacer />
          {eta ? (
            <HStack spacing={3}>
              <Text modifiers={[font({ size: 11 }), foregroundStyle(T2)]}>ends</Text>
              <Text modifiers={[font({ size: 11, weight: 'medium' }), foregroundStyle(T1)]} date={endDate} dateStyle="time" />
            </HStack>
          ) : null}
        </HStack>
      </VStack>
    ),
  };
};

export const printActivity = createLiveActivity<PrintActivityProps>('PrintActivity', PrintActivity);
export default printActivity;
