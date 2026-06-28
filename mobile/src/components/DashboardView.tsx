import React from 'react';
import { View, Text, Pressable, ScrollView, ActivityIndicator } from 'react-native';
import { Image } from 'expo-image';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import Svg, { Circle } from 'react-native-svg';
import { Feather } from '@expo/vector-icons';
import { c, mono, shadow1 } from '@/theme';
import type { DashVM } from '@/dashboard/present';

export interface DashHandlers {
  onSettings: () => void;
  onCamera: () => void;
  onPauseResume: () => void;
  onStop: () => void;
  onLight: () => void;
  onSpeed: () => void;
  onRetry: () => void;
  onTab: (tab: string) => void;
}

const RING_R = 56;
const RING_C = 2 * Math.PI * RING_R;

function Tap({ children, onPress, style }: { children: React.ReactNode; onPress?: () => void; style?: any }) {
  return (
    <Pressable onPress={onPress} style={({ pressed }) => [style, pressed && { opacity: 0.6, transform: [{ scale: 0.98 }] }]}>
      {children}
    </Pressable>
  );
}

function ProgressRing({ pct, color }: { pct: number; color: string }) {
  const offset = RING_C * (1 - Math.max(0, Math.min(100, pct)) / 100);
  return (
    <View style={{ width: 128, height: 128 }}>
      <Svg width={128} height={128} viewBox="0 0 128 128">
        <Circle cx={64} cy={64} r={RING_R} fill="none" stroke={c.s3} strokeWidth={9} />
        <Circle
          cx={64}
          cy={64}
          r={RING_R}
          fill="none"
          stroke={color}
          strokeWidth={9}
          strokeLinecap="round"
          strokeDasharray={RING_C}
          strokeDashoffset={offset}
          transform="rotate(-90 64 64)"
        />
      </Svg>
      <View style={{ position: 'absolute', inset: 0, alignItems: 'center', justifyContent: 'center' } as any}>
        <Text style={{ fontWeight: '700', fontSize: 32, color: c.t1, letterSpacing: -1, fontVariant: ['tabular-nums'] }}>
          {pct}
          <Text style={{ fontSize: 15, color: c.t3 }}>%</Text>
        </Text>
      </View>
    </View>
  );
}

function TempCard({ label, now, target, heating }: { label: string; now: number; target: number; heating: boolean }) {
  const barColor = heating ? c.heating : c.running;
  const pct = target > 0 ? Math.max(4, Math.min(100, (now / target) * 100)) : 4;
  return (
    <View style={{ flex: 1, padding: 14, borderRadius: 18, backgroundColor: c.s1, borderWidth: 1, borderColor: c.line }}>
      <View style={{ flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' }}>
        <Text style={{ fontWeight: '600', fontSize: 12, color: c.t2 }}>{label}</Text>
        <View style={{ width: 7, height: 7, borderRadius: 4, backgroundColor: barColor, opacity: 0.9 }} />
      </View>
      <View style={{ marginTop: 9, flexDirection: 'row', alignItems: 'baseline', gap: 6 }}>
        <Text style={{ fontWeight: '700', fontSize: 26, color: c.t1, fontVariant: ['tabular-nums'], letterSpacing: -0.5 }}>
          {now}
          <Text style={{ fontSize: 13, color: c.t3 }}>°</Text>
        </Text>
        <Text style={{ fontWeight: '500', fontSize: 12, color: c.t3, fontFamily: mono }}>→ {target}°</Text>
      </View>
      <View style={{ marginTop: 11, height: 3, borderRadius: 2, backgroundColor: c.s3, overflow: 'hidden' }}>
        <View style={{ height: '100%', width: `${pct}%`, borderRadius: 2, backgroundColor: barColor }} />
      </View>
    </View>
  );
}

function Label({ children }: { children: React.ReactNode }) {
  return <Text style={{ fontWeight: '600', fontSize: 10, color: c.t3, letterSpacing: 1, fontFamily: mono }}>{children}</Text>;
}

export function DashboardView({
  vm,
  snapshotUri,
  h,
}: {
  vm: DashVM;
  snapshotUri: string | null;
  h: DashHandlers;
}) {
  const insets = useSafeAreaInsets();
  const showCamera = vm.kind === 'live' || vm.kind === 'idle' || vm.kind === 'complete' || vm.kind === 'error';

  return (
    <View style={{ flex: 1, backgroundColor: c.bg }}>
      <ScrollView
        showsVerticalScrollIndicator={false}
        contentContainerStyle={{ paddingTop: insets.top + 6, paddingBottom: 120 }}>
        {/* header */}
        <View style={{ paddingHorizontal: 20, flexDirection: 'row', alignItems: 'flex-start', justifyContent: 'space-between' }}>
          <View>
            <Text style={{ fontWeight: '600', fontSize: 11, color: c.t3, letterSpacing: 1.4, fontFamily: mono }}>BAMBU LAB A1</Text>
            <View style={{ flexDirection: 'row', alignItems: 'center', gap: 7, marginTop: 6 }}>
              <View style={{ width: 8, height: 8, borderRadius: 4, backgroundColor: vm.stateColor }} />
              <Text style={{ fontWeight: '600', fontSize: 17, color: c.t1, letterSpacing: -0.2 }}>A1 Printer</Text>
            </View>
          </View>
          <Tap onPress={h.onSettings} style={{ width: 38, height: 38, borderRadius: 19, backgroundColor: c.s2, alignItems: 'center', justifyContent: 'center' }}>
            <Feather name="settings" size={19} color={c.t2} />
          </Tap>
        </View>

        {/* hero */}
        <View style={{ paddingHorizontal: 20, paddingTop: 18, paddingBottom: 2 }}>
          <Text style={{ fontWeight: '700', fontSize: 36, letterSpacing: -1, color: vm.stateColor }}>{vm.stateLabel}</Text>
          {!!vm.heroSub && (
            <Text style={{ marginTop: 8, fontWeight: '500', fontSize: 13, lineHeight: 17, color: c.t2, fontFamily: mono }}>{vm.heroSub}</Text>
          )}
        </View>

        {/* camera tile */}
        {showCamera && (
          <View style={{ paddingHorizontal: 20, paddingTop: 16 }}>
            <Tap onPress={h.onCamera} style={{ width: '100%' }}>
              <View style={{ width: '100%', aspectRatio: 16 / 10, borderRadius: 18, overflow: 'hidden', backgroundColor: '#0d0f11', borderWidth: 1, borderColor: c.line, ...shadow1 }}>
                {snapshotUri ? (
                  <Image source={{ uri: snapshotUri }} style={{ width: '100%', height: '100%' }} contentFit="cover" transition={120} />
                ) : (
                  <View style={{ flex: 1, alignItems: 'center', justifyContent: 'center' }}>
                    <Text style={{ fontWeight: '500', fontSize: 10, letterSpacing: 1.6, color: c.t3, fontFamily: mono }}>CHAMBER · SNAPSHOT</Text>
                  </View>
                )}
                <View style={{ position: 'absolute', top: 11, left: 11, flexDirection: 'row', alignItems: 'center', gap: 5, paddingHorizontal: 8, paddingVertical: 4, borderRadius: 8, backgroundColor: 'rgba(0,0,0,0.55)' }}>
                  <View style={{ width: 6, height: 6, borderRadius: 3, backgroundColor: c.running }} />
                  <Text style={{ fontWeight: '600', fontSize: 9.5, letterSpacing: 0.6, color: '#fff' }}>LIVE · 1 fps</Text>
                </View>
                <View style={{ position: 'absolute', bottom: 9, left: 11, width: 26, height: 26, borderRadius: 7, backgroundColor: 'rgba(0,0,0,0.5)', alignItems: 'center', justifyContent: 'center' }}>
                  <Feather name="maximize-2" size={13} color="#fff" />
                </View>
              </View>
            </Tap>
          </View>
        )}

        {/* ---- LIVE ---- */}
        {vm.kind === 'live' && (
          <>
            <View style={{ marginHorizontal: 20, marginTop: 16, padding: 20, borderRadius: 22, backgroundColor: c.s1, borderWidth: 1, borderColor: c.line, flexDirection: 'row', alignItems: 'center', gap: 18, ...shadow1 }}>
              <ProgressRing pct={vm.progressInt} color={vm.stateColor} />
              <View style={{ flex: 1, gap: 15 }}>
                <View>
                  <Label>LAYER</Label>
                  <Text style={{ marginTop: 5, fontWeight: '600', fontSize: 19, color: c.t1, fontFamily: mono, fontVariant: ['tabular-nums'] }}>
                    {vm.layer} <Text style={{ color: c.t3, fontWeight: '500' }}>/ {vm.totalLayers}</Text>
                  </Text>
                </View>
                <View style={{ height: 1, backgroundColor: c.line }} />
                <View>
                  <Label>TIME LEFT</Label>
                  <Text style={{ marginTop: 5, fontWeight: '600', fontSize: 19, color: c.t1, fontVariant: ['tabular-nums'] }}>{vm.etaText}</Text>
                  <Text style={{ marginTop: 3, fontWeight: '500', fontSize: 12, color: c.t3 }}>done ~ {vm.doneText}</Text>
                </View>
              </View>
            </View>

            <View style={{ marginHorizontal: 20, marginTop: 14, flexDirection: 'row', gap: 12 }}>
              <TempCard label="Nozzle" now={vm.nozzleNow} target={vm.nozzleTarget} heating={vm.nozzleHeating} />
              <TempCard label="Bed" now={vm.bedNow} target={vm.bedTarget} heating={vm.bedHeating} />
            </View>

            {/* controls */}
            <View style={{ marginHorizontal: 20, marginTop: 18, flexDirection: 'row', gap: 12 }}>
              <Tap onPress={h.onPauseResume} style={{ flex: 2, height: 58, borderRadius: 17, backgroundColor: c.s3, flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 9 }}>
                <Feather name={vm.isPaused ? 'play' : 'pause'} size={17} color={c.t1} />
                <Text style={{ fontWeight: '600', fontSize: 16, color: c.t1 }}>{vm.isPaused ? 'Resume' : 'Pause'}</Text>
              </Tap>
              <Tap onPress={h.onStop} style={{ flex: 1, height: 58, borderRadius: 17, backgroundColor: c.errorDim, flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 8 }}>
                <Feather name="square" size={15} color={c.error} />
                <Text style={{ fontWeight: '600', fontSize: 16, color: c.error }}>Stop</Text>
              </Tap>
            </View>
            <View style={{ marginHorizontal: 20, marginTop: 12, flexDirection: 'row', gap: 12 }}>
              <Tap onPress={h.onLight} style={{ flex: 1, height: 54, borderRadius: 16, backgroundColor: vm.lightOn ? c.accentDim : c.s3, flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 9 }}>
                <Feather name="sun" size={17} color={vm.lightOn ? c.accent : c.t1} />
                <Text style={{ fontWeight: '600', fontSize: 14, color: vm.lightOn ? c.accent : c.t1 }}>Light</Text>
                <Text style={{ fontWeight: '600', fontSize: 12, color: vm.lightOn ? c.accent : c.t1, opacity: 0.7, fontFamily: mono }}>{vm.lightOn ? 'ON' : 'OFF'}</Text>
              </Tap>
              <Tap onPress={h.onSpeed} style={{ flex: 1, height: 54, borderRadius: 16, backgroundColor: c.s3, flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 9 }}>
                <Feather name="zap" size={17} color={c.t1} />
                <Text style={{ fontWeight: '600', fontSize: 14, color: c.t1 }}>{vm.speedLabel}</Text>
              </Tap>
            </View>

            {/* AMS strip */}
            <View style={{ marginHorizontal: 20, marginTop: 20, marginBottom: 8 }}>
              <View style={{ flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', marginBottom: 11 }}>
                <Text style={{ fontWeight: '600', fontSize: 11, letterSpacing: 1.2, color: c.t3, fontFamily: mono }}>AMS LITE</Text>
                <Tap onPress={() => h.onTab('ams')} style={{ flexDirection: 'row', alignItems: 'center', gap: 3 }}>
                  <Text style={{ fontWeight: '600', fontSize: 13, color: c.accent }}>Details</Text>
                  <Feather name="chevron-right" size={13} color={c.accent} />
                </Tap>
              </View>
              <View style={{ flexDirection: 'row', gap: 10 }}>
                {vm.ams.map((t, i) => (
                  <View key={i} style={{ flex: 1, paddingVertical: 11, paddingHorizontal: 8, borderRadius: 15, backgroundColor: c.s1, alignItems: 'center', gap: 8, borderWidth: t.active ? 1.5 : 1, borderColor: t.active ? c.accent : c.line }}>
                    <View style={{ width: 32, height: 32, borderRadius: 9, backgroundColor: t.empty ? 'transparent' : t.color, borderWidth: t.empty ? 1 : 0, borderColor: c.line2, borderStyle: t.empty ? 'dashed' : 'solid' }} />
                    <Text numberOfLines={1} style={{ fontWeight: '600', fontSize: 9.5, color: c.t2 }}>{t.label}</Text>
                    <Text style={{ fontWeight: '600', fontSize: 11, color: c.t1, fontFamily: mono, fontVariant: ['tabular-nums'] }}>{t.pct}</Text>
                    <View style={{ width: 5, height: 5, borderRadius: 3, backgroundColor: c.accent, opacity: t.active ? 1 : 0 }} />
                  </View>
                ))}
              </View>
            </View>
          </>
        )}

        {/* ---- IDLE ---- */}
        {vm.kind === 'idle' && (
          <>
            <View style={{ marginHorizontal: 20, marginTop: 18, padding: 22, borderRadius: 22, backgroundColor: c.s1, borderWidth: 1, borderColor: c.line, alignItems: 'center', ...shadow1 }}>
              <Text style={{ fontWeight: '600', fontSize: 14, lineHeight: 20, color: c.t2, textAlign: 'center', maxWidth: 250 }}>No active job. The bed is clear and filament is loaded.</Text>
              <Tap onPress={() => h.onTab('library')} style={{ marginTop: 16, width: '100%', height: 52, borderRadius: 15, backgroundColor: c.accent, flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 8 }}>
                <Feather name="plus" size={18} color={c.accentInk} />
                <Text style={{ fontWeight: '600', fontSize: 16, color: c.accentInk }}>New print</Text>
              </Tap>
            </View>
            <View style={{ marginHorizontal: 20, marginTop: 14, flexDirection: 'row', gap: 12 }}>
              <TempCard label="Nozzle" now={vm.nozzleNow} target={vm.nozzleTarget} heating={false} />
              <TempCard label="Bed" now={vm.bedNow} target={vm.bedTarget} heating={false} />
            </View>
          </>
        )}

        {/* ---- COMPLETE ---- */}
        {vm.kind === 'complete' && (
          <View style={{ marginHorizontal: 20, marginTop: 18, padding: 22, borderRadius: 22, backgroundColor: c.s1, borderWidth: 1, borderColor: c.line, ...shadow1 }}>
            <View style={{ flexDirection: 'row', alignItems: 'center', gap: 13 }}>
              <View style={{ width: 48, height: 48, borderRadius: 24, backgroundColor: c.runningDim, alignItems: 'center', justifyContent: 'center' }}>
                <Feather name="check" size={24} color={c.running} />
              </View>
              <View>
                <Text style={{ fontWeight: '700', fontSize: 20, color: c.t1, letterSpacing: -0.3 }}>Print complete</Text>
                <Text style={{ marginTop: 5, fontWeight: '500', fontSize: 12, color: c.t3, fontFamily: mono }}>{vm.heroSub || 'finished'}</Text>
              </View>
            </View>
            <Tap onPress={() => h.onTab('library')} style={{ marginTop: 18, height: 52, borderRadius: 15, backgroundColor: c.accent, alignItems: 'center', justifyContent: 'center' }}>
              <Text style={{ fontWeight: '600', fontSize: 16, color: c.accentInk }}>Print again</Text>
            </Tap>
          </View>
        )}

        {/* ---- ERROR ---- */}
        {vm.kind === 'error' && (
          <>
            <View style={{ marginHorizontal: 20, marginTop: 18, padding: 20, borderRadius: 22, backgroundColor: c.s1, borderWidth: 1, borderColor: c.line, ...shadow1 }}>
              <View style={{ flexDirection: 'row', alignItems: 'center', gap: 12 }}>
                <View style={{ width: 42, height: 42, borderRadius: 12, backgroundColor: c.errorDim, alignItems: 'center', justifyContent: 'center' }}>
                  <Feather name="alert-triangle" size={22} color={c.error} />
                </View>
                <View style={{ flex: 1 }}>
                  <Text style={{ fontWeight: '700', fontSize: 17, lineHeight: 20, color: c.t1 }}>Printer reported an error</Text>
                  <Text style={{ marginTop: 4, fontWeight: '500', fontSize: 11, color: c.t3, fontFamily: mono }}>{vm.heroSub || 'HMS error'}</Text>
                </View>
              </View>
            </View>
            <View style={{ marginHorizontal: 20, marginTop: 14, flexDirection: 'row', gap: 12 }}>
              <Tap onPress={h.onPauseResume} style={{ flex: 2, height: 54, borderRadius: 16, backgroundColor: c.accent, alignItems: 'center', justifyContent: 'center' }}>
                <Text style={{ fontWeight: '600', fontSize: 16, color: c.accentInk }}>Resume print</Text>
              </Tap>
              <Tap onPress={h.onStop} style={{ flex: 1, height: 54, borderRadius: 16, backgroundColor: c.errorDim, alignItems: 'center', justifyContent: 'center' }}>
                <Text style={{ fontWeight: '600', fontSize: 16, color: c.error }}>Stop</Text>
              </Tap>
            </View>
          </>
        )}

        {/* ---- OFFLINE ---- */}
        {vm.kind === 'offline' && (
          <View style={{ marginHorizontal: 24, marginTop: 48, alignItems: 'center', gap: 16 }}>
            <View style={{ width: 72, height: 72, borderRadius: 22, backgroundColor: c.s2, alignItems: 'center', justifyContent: 'center' }}>
              <Feather name="wifi-off" size={32} color={c.t3} />
            </View>
            <View style={{ alignItems: 'center' }}>
              <Text style={{ fontWeight: '700', fontSize: 20, color: c.t1, letterSpacing: -0.3 }}>Can't reach your printer</Text>
              <Text style={{ marginTop: 8, fontWeight: '500', fontSize: 13, lineHeight: 19, color: c.t3, textAlign: 'center', maxWidth: 260 }}>
                No response right now. Make sure it's powered on and on your network.
              </Text>
            </View>
            <Tap onPress={h.onRetry} style={{ marginTop: 4, paddingHorizontal: 26, height: 48, borderRadius: 14, backgroundColor: c.accent, alignItems: 'center', justifyContent: 'center' }}>
              <Text style={{ fontWeight: '600', fontSize: 15, color: c.accentInk }}>Retry connection</Text>
            </Tap>
          </View>
        )}

        {/* ---- CONNECTING ---- */}
        {vm.kind === 'connecting' && (
          <View style={{ marginTop: 60, alignItems: 'center', gap: 16 }}>
            <ActivityIndicator color={c.accent} />
            <Text style={{ fontWeight: '500', fontSize: 13, color: c.t3 }}>Connecting…</Text>
          </View>
        )}
      </ScrollView>

      {/* tab bar */}
      <View style={{ position: 'absolute', left: 0, right: 0, bottom: 0, paddingTop: 9, paddingBottom: insets.bottom || 12, backgroundColor: c.s1, borderTopWidth: 1, borderTopColor: c.line, flexDirection: 'row' }}>
        {([
          ['printer', 'Printer', 'cpu'],
          ['library', 'Files', 'folder'],
          ['queue', 'Queue', 'list'],
          ['ams', 'AMS', 'grid'],
          ['power', 'Power', 'power'],
        ] as const).map(([key, label, icon]) => {
          const active = key === 'printer';
          return (
            <Tap key={key} onPress={() => (active ? undefined : h.onTab(key))} style={{ flex: 1, alignItems: 'center', gap: 4, paddingVertical: 5 }}>
              <Feather name={icon as any} size={23} color={active ? c.accent : c.t3} />
              <Text style={{ fontWeight: '600', fontSize: 10, color: active ? c.accent : c.t3 }}>{label}</Text>
            </Tap>
          );
        })}
      </View>
    </View>
  );
}
