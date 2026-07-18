// iOS Live Activity for an active print — Lock Screen banner + Dynamic Island.
//
// This module is authored with expo-widgets (@expo/ui/swift-ui). The component function carries the
// 'widget' directive: babel-preset-expo's widgets plugin STRINGIFIES only this function's params +
// body and re-evaluates it in an isolated native runtime where only the @expo/ui primitives are
// injected. So the function must be FULLY SELF-CONTAINED — every constant/helper lives inside it; it
// may reference only its args (`p`, `_env`), `Math`/`Date`, and the @expo/ui components/modifiers.
import { createLiveActivity, type LiveActivityEnvironment } from 'expo-widgets';
import { HStack, VStack, Text, Image, Spacer, ProgressView } from '@expo/ui/swift-ui';
import { font, foregroundStyle, padding, tint, frame, resizable, aspectRatio, cornerRadius } from '@expo/ui/swift-ui/modifiers';
// The ContentState shape lives in the pure (jest-testable) contentState.ts; this file only renders it.
import type { PrintActivityProps } from './contentState';

const PrintActivity = (p: PrintActivityProps, _env: LiveActivityEnvironment) => {
  'widget';
  const T1 = '#F3F5F7';
  const T2 = '#A4ABB2';
  const pct = `${Math.max(0, Math.min(100, Math.round(p.progress)))}%`;
  const layers = p.totalLayers > 0 ? `${p.layer}/${p.totalLayers}` : `${p.layer}`;
  const eta = p.etaEpochMs > 0 && !p.finished;
  const endDate = new Date(p.etaEpochMs || Date.now());
  const temp = (cur: number, target: number) => (target > 0 && target !== cur ? `${cur}/${target}°` : `${cur}°`);
  const dim = (s: string) => <Text modifiers={[font({ size: 11 }), foregroundStyle(T2)]}>{s}</Text>;
  // Nozzle temps row: dual-nozzle machines (H2-series) show BOTH heads — the driven one bright, the
  // idle one dimmed — so a right-nozzle print never reads as the (idle, cool) left. Single machines
  // show one "Nozzle". `activeNozzle` (0=left, 1=right) is decided upstream in present.ts / la-push.
  const nozSeg = (label: string, cur: number, target: number, active: boolean) => (
    <HStack spacing={3}>
      {dim(label)}
      <Text modifiers={[font(active ? { size: 11, weight: 'semibold' } : { size: 11 }), foregroundStyle(active ? T1 : T2)]}>{temp(cur, target)}</Text>
    </HStack>
  );
  const nozzleTemps = () => (
    <HStack spacing={8}>
      {p.hasNozzle2 ? nozSeg('L', p.nozzle, p.nozzleTarget, p.activeNozzle === 0) : null}
      {p.hasNozzle2 ? nozSeg('R', p.nozzle2, p.nozzle2Target, p.activeNozzle === 1) : nozSeg('Nozzle', p.nozzle, p.nozzleTarget, true)}
      {dim('·')}
      {dim(`Bed ${temp(p.bed, p.bedTarget)}`)}
    </HStack>
  );
  // Brand nozzle glyph from the App Group (uiImage); falls back to the SF symbol if unavailable.
  const glyph = (s: number) =>
    p.iconUri
      ? <Image uiImage={p.iconUri} modifiers={[resizable(), aspectRatio({ contentMode: 'fit' }), frame({ width: s, height: s })]} />
      : <Image systemName={p.symbol as never} color={p.tint} size={s} />;
  // Leading visual: the model's plate thumbnail (rounded) when we have it, else the brand nozzle.
  const lead = (s: number) =>
    p.modelUri
      ? <Image uiImage={p.modelUri} modifiers={[resizable(), aspectRatio({ contentMode: 'fill' }), frame({ width: s, height: s }), cornerRadius(s * 0.22)]} />
      : glyph(s);
  const queueLine = p.queueCount > 0
    ? (p.nextName ? `Up next: ${p.nextName}${p.queueCount > 1 ? `  ·  +${p.queueCount - 1} more` : ''}` : `${p.queueCount} queued`)
    : '';

  // ---- AMS DRYING card — same activity type, different face. Countdown renders client-side from
  // etaEpochMs (dateStyle timer), so the card stays live between pushes. ----
  if (p.dry) {
    const dryIcon = (s: number) => <Image systemName={'humidity.fill' as never} color={p.tint} size={s} />;
    const dryStats = (
      <HStack spacing={8}>
        {dim('AMS')}
        <Text modifiers={[font({ size: 11, weight: 'semibold' }), foregroundStyle(T1)]}>
          {(p.amsTarget ?? 0) > 0 ? `${p.amsTemp ?? 0}/${p.amsTarget}°` : `${p.amsTemp ?? 0}°`}
        </Text>
        {dim('·')}
        {dim(`Humidity ${p.humidity ?? 0}%`)}
      </HStack>
    );
    return {
      banner: (
        <VStack alignment="leading" spacing={9} modifiers={[padding({ all: 14 })]}>
          <HStack spacing={12}>
            {dryIcon(34)}
            <VStack alignment="leading" spacing={2}>
              <Text modifiers={[font({ size: 15, weight: 'semibold' }), foregroundStyle(T1)]}>{p.printerName || 'AMS'} · Drying</Text>
              <Text modifiers={[font({ size: 12 }), foregroundStyle(T2)]}>{p.name}</Text>
            </VStack>
            <Spacer />
            <VStack alignment="trailing" spacing={1}>
              {eta ? (
                <Text modifiers={[font({ size: 20, weight: 'bold', design: 'rounded' }), foregroundStyle(p.tint)]} date={endDate} dateStyle="timer" />
              ) : (
                <Text modifiers={[font({ size: 20, weight: 'bold', design: 'rounded' }), foregroundStyle(p.tint)]}>—</Text>
              )}
              {eta ? (
                <HStack spacing={3}>
                  <Text modifiers={[font({ size: 11 }), foregroundStyle(T2)]}>ends</Text>
                  <Text modifiers={[font({ size: 11, weight: 'medium' }), foregroundStyle(T1)]} date={endDate} dateStyle="time" />
                </HStack>
              ) : null}
            </VStack>
          </HStack>
          {dryStats}
        </VStack>
      ),
      compactLeading: dryIcon(16),
      compactTrailing: eta ? (
        <Text modifiers={[font({ size: 13, weight: 'semibold', design: 'rounded' }), foregroundStyle(p.tint)]} date={endDate} dateStyle="timer" />
      ) : (
        <Text modifiers={[font({ size: 13, weight: 'semibold', design: 'rounded' }), foregroundStyle(p.tint)]}>dry</Text>
      ),
      minimal: dryIcon(14),
      expandedLeading: (
        <VStack alignment="leading" spacing={1} modifiers={[padding({ leading: 6 })]}>
          <Text modifiers={[font({ size: 13, weight: 'semibold' }), foregroundStyle(T1)]}>{p.printerName || 'AMS'} · Drying</Text>
          <Text modifiers={[font({ size: 11 }), foregroundStyle(T2)]}>{p.name}</Text>
        </VStack>
      ),
      expandedTrailing: (
        <VStack alignment="trailing" spacing={1} modifiers={[padding({ trailing: 6 })]}>
          {eta ? (
            <Text modifiers={[font({ size: 17, weight: 'bold', design: 'rounded' }), foregroundStyle(p.tint)]} date={endDate} dateStyle="timer" />
          ) : null}
        </VStack>
      ),
      expandedBottom: (
        <VStack spacing={6} modifiers={[padding({ horizontal: 6, top: 4 })]}>
          <HStack spacing={8}>
            {dryStats}
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
  }

  return {
    // Lock-screen / Notification Center banner
    banner: (
      <VStack alignment="leading" spacing={9} modifiers={[padding({ all: 14 })]}>
        <HStack spacing={12}>
          {lead(40)}
          <VStack alignment="leading" spacing={2}>
            <Text modifiers={[font({ size: 15, weight: 'semibold' }), foregroundStyle(T1)]}>{p.printerName || 'Printer'}</Text>
            <Text modifiers={[font({ size: 12 }), foregroundStyle(T2)]}>{p.name ? `${p.name}  ·  L${layers}` : `${p.stateLabel}  ·  L${layers}`}</Text>
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
          {nozzleTemps()}
          <Spacer />
          {eta ? (
            <Text modifiers={[font({ size: 11, weight: 'semibold', design: 'rounded' }), foregroundStyle(T2)]} date={endDate} dateStyle="timer" />
          ) : null}
        </HStack>
        {queueLine ? (
          <HStack spacing={6}>
            <Image systemName="square.stack.3d.up" color={T2} size={11} />
            <Text modifiers={[font({ size: 11 }), foregroundStyle(T2)]}>{queueLine}</Text>
          </HStack>
        ) : null}
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
        <Text modifiers={[font({ size: 13, weight: 'semibold' }), foregroundStyle(T1)]}>{p.printerName || p.stateLabel}</Text>
        <Text modifiers={[font({ size: 11 }), foregroundStyle(T2)]}>{p.stateLabel} · L{layers}</Text>
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
          {nozzleTemps()}
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
