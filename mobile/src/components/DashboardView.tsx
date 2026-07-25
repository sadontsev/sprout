import React, { useEffect, useState } from 'react';
import { View, Text, ScrollView, Pressable } from 'react-native';
import { Image } from 'expo-image';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { Feather } from '@expo/vector-icons';
import { c, mono, shadow1, type Palette } from '@/theme';
import type { DashVM, DashKind } from '@/dashboard/present';
import type { AlertVM, AlertActionVM } from '@/alerts/present';
import type { Printer } from '@/api/types';
import { Tap, RollingNumber, PulseDot, ProgressRing, HeatBar, Confetti, FadeRise, Skeleton, Pop, Breathe } from './anim';

export interface DashHandlers {
  onSettings: () => void;
  onCamera: () => void;
  onPauseResume: () => void;
  onStop: () => void;
  onLight: () => void;
  onSpeedSet: (i: number) => void;
  onSelectPrinter: (id: number) => void;
  /** Fired with the alert + the chosen action; the Shell maps it to the real endpoint. */
  onAlertAction: (alert: AlertVM, action: AlertActionVM) => void;
  onPlateCleared: () => void;
  onPrintAgain: () => void;
  onRetry: () => void;
  onTab: (tab: string) => void;
}

/** A printer + its live state, for the fleet switcher. */
export interface FleetEntry {
  printer: Printer;
  kind: DashKind;
  stateLabel: string;
  stateColor: string;
  progressInt: number;
}

// Bambu print-speed modes (design: the speed popover). Dot colors are palette KEYS resolved at
// render — the live `c` object mutates on theme switch, so captured values would go stale.
const SPEEDS: { i: number; name: string; hint: string; dot: keyof Palette }[] = [
  { i: 1, name: 'Silent', hint: '50%', dot: 'paused' },
  { i: 2, name: 'Standard', hint: '100%', dot: 'running' },
  { i: 3, name: 'Sport', hint: '124%', dot: 'heating' },
  { i: 4, name: 'Ludicrous', hint: '166%', dot: 'error' },
];

function TempCard({ label, now, target, heating, active }: { label: string; now: number; target: number; heating: boolean; active?: boolean }) {
  const barColor = heating ? c.heating : c.running;
  const pct = target > 0 ? Math.max(4, Math.min(100, (now / target) * 100)) : 4;
  return (
    <View style={{ flex: 1, padding: 14, borderRadius: 18, backgroundColor: c.s1, borderWidth: 1, borderColor: active ? c.accent : c.line }}>
      <View style={{ flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' }}>
        <Text style={{ fontWeight: '600', fontSize: 12, color: c.t2 }}>{label}</Text>
        {heating ? <PulseDot color={barColor} size={7} period={1400} /> : <View style={{ width: 7, height: 7, borderRadius: 4, backgroundColor: barColor, opacity: 0.9 }} />}
      </View>
      <View style={{ marginTop: 9, flexDirection: 'row', alignItems: 'baseline', gap: 6 }}>
        <View style={{ flexDirection: 'row', alignItems: 'flex-end' }}>
          <RollingNumber value={now} fontSize={26} weight="700" color={c.t1} letterSpacing={-0.5} />
          <Text style={{ fontWeight: '700', fontSize: 13, color: c.t3 }}>°</Text>
        </View>
        <Text style={{ fontWeight: '500', fontSize: 12, color: c.t3, fontFamily: mono }}>→ {target}°</Text>
      </View>
      <HeatBar pct={pct} color={barColor} heating={heating} height={3} style={{ marginTop: 11 }} />
    </View>
  );
}

/** Nozzle(s) + bed (+ chamber on enclosed machines), 2 cards per row. */
function TempGrid({ vm, heatingEnabled }: { vm: DashVM; heatingEnabled: boolean }) {
  const dual = vm.nozzles.length > 1;
  const cards: { label: string; now: number; target: number; heating: boolean; active?: boolean }[] = dual
    ? vm.nozzles.map((n, i) => ({ label: i === 0 ? 'Left nozzle' : 'Right nozzle', now: n.now, target: n.target, heating: heatingEnabled && n.heating, active: n.active }))
    : [{ label: 'Nozzle', now: vm.nozzleNow, target: vm.nozzleTarget, heating: heatingEnabled && vm.nozzleHeating }];
  cards.push({ label: 'Bed', now: vm.bedNow, target: vm.bedTarget, heating: heatingEnabled && vm.bedHeating });
  if (vm.hasChamber) cards.push({ label: 'Chamber', now: vm.chamberNow, target: vm.chamberTarget, heating: heatingEnabled && vm.chamberHeating });
  const rows: (typeof cards)[] = [];
  for (let i = 0; i < cards.length; i += 2) rows.push(cards.slice(i, i + 2));
  return (
    <>
      {rows.map((row, r) => (
        <View key={r} style={{ marginHorizontal: 20, marginTop: r === 0 ? 14 : 12, flexDirection: 'row', gap: 12 }}>
          {row.map((card) => (
            <TempCard key={card.label} {...card} />
          ))}
          {row.length === 1 && <View style={{ flex: 1 }} />}
        </View>
      ))}
    </>
  );
}

function Label({ children }: { children: React.ReactNode }) {
  return <Text style={{ fontWeight: '600', fontSize: 10, color: c.t3, letterSpacing: 1, fontFamily: mono }}>{children}</Text>;
}

export function DashboardView({
  vm,
  alerts,
  snapshotUri,
  h,
  maintAlert,
  speedIdx,
  printer,
  fleet,
}: {
  vm: DashVM;
  /** Things needing attention, each with only the actions currently possible (alerts/present.ts). */
  alerts: AlertVM[];
  snapshotUri: string | null;
  h: DashHandlers;
  maintAlert?: { due: number; warn: number };
  speedIdx: number;
  printer: Printer | null;
  fleet: FleetEntry[];
}) {
  const insets = useSafeAreaInsets();
  const showCamera = vm.kind === 'live' || vm.kind === 'idle' || vm.kind === 'complete' || vm.kind === 'error';
  // A cold camera can take seconds to produce a frame — don't claim "LIVE" over a blank tile.
  const [camLoaded, setCamLoaded] = useState(false);
  useEffect(() => { if (!snapshotUri) setCamLoaded(false); }, [snapshotUri]);
  const [speedOpen, setSpeedOpen] = useState(false);
  const [switcherOpen, setSwitcherOpen] = useState(false);

  const printerName = printer?.name ?? 'Printer';
  const brand = printer ? `BAMBU LAB ${printer.model.toUpperCase()}` : 'BAMBU LAB';
  const canSwitch = fleet.length > 1;

  return (
    <ScrollView
      style={{ flex: 1, backgroundColor: c.bg }}
      showsVerticalScrollIndicator={false}
      contentContainerStyle={{ paddingTop: insets.top + 6, paddingBottom: 120 }}>
        {/* header */}
        <View style={{ paddingHorizontal: 20, flexDirection: 'row', alignItems: 'flex-start', justifyContent: 'space-between' }}>
          <Tap onPress={() => canSwitch && setSwitcherOpen((o) => !o)} disabled={!canSwitch}>
            <Text style={{ fontWeight: '600', fontSize: 11, color: c.t3, letterSpacing: 1.4, fontFamily: mono }}>{brand}</Text>
            <View style={{ flexDirection: 'row', alignItems: 'center', gap: 7, marginTop: 6 }}>
              <PulseDot color={vm.stateColor} size={8} />
              <Text style={{ fontWeight: '600', fontSize: 17, color: c.t1, letterSpacing: -0.2 }}>{printerName}</Text>
              {canSwitch && <Feather name={switcherOpen ? 'chevron-up' : 'chevron-down'} size={15} color={c.t3} />}
            </View>
          </Tap>
          <Tap onPress={h.onSettings} style={{ width: 38, height: 38, borderRadius: 19, backgroundColor: c.s2, alignItems: 'center', justifyContent: 'center' }}>
            <Feather name="settings" size={19} color={c.t2} />
          </Tap>
        </View>

        {/* Tap-away layer (under the switcher, over everything else) */}
        {switcherOpen && <Pressable onPress={() => setSwitcherOpen(false)} style={{ position: 'absolute', inset: 0 } as any} />}

        {/* fleet switcher */}
        {switcherOpen && (
          <FadeRise dy={-6} duration={180}>
            <View style={{ marginHorizontal: 20, marginTop: 12, borderRadius: 16, backgroundColor: c.s1, borderWidth: 1, borderColor: c.line2, padding: 5, ...shadow1 }}>
              {fleet.map((f) => {
                const on = f.printer.id === printer?.id;
                return (
                  <Tap
                    key={f.printer.id}
                    onPress={() => { setSwitcherOpen(false); if (!on) h.onSelectPrinter(f.printer.id); }}
                    style={{ flexDirection: 'row', alignItems: 'center', gap: 11, paddingHorizontal: 12, paddingVertical: 12, borderRadius: 12, backgroundColor: on ? c.s3 : 'transparent' }}>
                    <PulseDot color={f.stateColor} size={8} />
                    <View style={{ flex: 1 }}>
                      <Text style={{ fontWeight: '600', fontSize: 14, color: c.t1 }}>{f.printer.name}</Text>
                      <Text style={{ marginTop: 2, fontWeight: '500', fontSize: 11, color: c.t3, fontFamily: mono }}>
                        {f.printer.model}{f.printer.location ? ` · ${f.printer.location}` : ''} · {f.kind === 'live' ? `${f.stateLabel} ${f.progressInt}%` : f.stateLabel}
                      </Text>
                    </View>
                    {on && <Feather name="check" size={15} color={c.accent} />}
                  </Tap>
                );
              })}
            </View>
          </FadeRise>
        )}

        {/* maintenance alert chip — only when something needs attention */}
        {!!maintAlert && (maintAlert.due > 0 || maintAlert.warn > 0) && (
          <FadeRise>
          <Tap
            onPress={() => h.onTab('ams')}
            style={{ marginHorizontal: 20, marginTop: 14, paddingVertical: 12, paddingHorizontal: 14, borderRadius: 14, flexDirection: 'row', alignItems: 'center', gap: 11, backgroundColor: maintAlert.due > 0 ? c.errorDim : c.heatingDim, borderWidth: 1, borderColor: maintAlert.due > 0 ? c.error : c.heating }}>
            <Feather name="tool" size={16} color={maintAlert.due > 0 ? c.error : c.heating} />
            <Text style={{ flex: 1, fontWeight: '600', fontSize: 13, color: c.t1 }}>
              {maintAlert.due > 0
                ? `${maintAlert.due} maintenance ${maintAlert.due === 1 ? 'task is' : 'tasks are'} due`
                : `${maintAlert.warn} maintenance ${maintAlert.warn === 1 ? 'task is' : 'tasks are'} coming up`}
            </Text>
            <Feather name="chevron-right" size={16} color={c.t3} />
          </Tap>
          </FadeRise>
        )}

        {/* NEEDS ATTENTION — every alert with only the actions that are possible right now (see
            alerts/present.ts). Renders nothing at all when the printer is happy. */}
        {alerts.length > 0 && (
          <FadeRise>
          <View style={{ marginHorizontal: 20, marginTop: 14, gap: 10 }}>
            {alerts.map((a) => {
              const tone = a.level === 'error' ? c.error : a.level === 'warning' ? c.heating : c.accent;
              const toneDim = a.level === 'error' ? c.errorDim : a.level === 'warning' ? c.heatingDim : c.accentDim;
              return (
                <View key={a.id} style={{ paddingVertical: 12, paddingHorizontal: 14, borderRadius: 14, backgroundColor: toneDim, borderWidth: 1, borderColor: tone }}>
                  <View style={{ flexDirection: 'row', alignItems: 'center', gap: 11 }}>
                    <Feather name={a.level === 'info' ? 'info' : 'alert-circle'} size={16} color={tone} />
                    <View style={{ flex: 1 }}>
                      <Text style={{ fontWeight: '600', fontSize: 13, color: c.t1 }}>{a.title}</Text>
                      <Text style={{ marginTop: 2, fontWeight: '500', fontSize: 11, color: c.t2, lineHeight: 15 }}>{a.detail}</Text>
                      {!!a.code && <Text style={{ marginTop: 3, fontWeight: '500', fontSize: 10.5, color: c.t3, fontFamily: mono }}>HMS {a.code}</Text>}
                    </View>
                  </View>
                  {a.actions.length > 0 && (
                    <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 8, marginTop: 11 }}>
                      {a.actions.map((act) => (
                        <Tap
                          key={act.id}
                          onPress={() => h.onAlertAction(a, act)}
                          style={{ paddingHorizontal: 14, height: 36, borderRadius: 10, alignItems: 'center', justifyContent: 'center', backgroundColor: act.destructive ? c.s3 : tone }}>
                          <Text style={{ fontWeight: '700', fontSize: 12.5, color: act.destructive ? c.error : c.accentInk }}>{act.label}</Text>
                        </Tap>
                      ))}
                    </View>
                  )}
                </View>
              );
            })}
          </View>
          </FadeRise>
        )}

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
              <View style={{ width: '100%', aspectRatio: 16 / 10, borderRadius: 18, overflow: 'hidden', backgroundColor: c.thumb, borderWidth: 1, borderColor: c.line, ...shadow1 }}>
                {snapshotUri ? (
                  <Image source={{ uri: snapshotUri }} style={{ width: '100%', height: '100%' }} contentFit="cover" transition={120} onLoad={() => setCamLoaded(true)} />
                ) : (
                  <View style={{ flex: 1, alignItems: 'center', justifyContent: 'center' }}>
                    <Text style={{ fontWeight: '500', fontSize: 10, letterSpacing: 1.6, color: c.t3, fontFamily: mono }}>CHAMBER · SNAPSHOT</Text>
                  </View>
                )}
                <View style={{ position: 'absolute', top: 11, left: 11, flexDirection: 'row', alignItems: 'center', gap: 5, paddingHorizontal: 8, paddingVertical: 4, borderRadius: 8, backgroundColor: 'rgba(0,0,0,0.55)' }}>
                  {camLoaded ? <PulseDot color={c.running} size={6} period={2000} /> : <View style={{ width: 6, height: 6, borderRadius: 3, backgroundColor: c.t3 }} />}
                  <Text style={{ fontWeight: '600', fontSize: 9.5, letterSpacing: 0.6, color: '#fff' }}>{camLoaded ? 'LIVE · 1 fps' : 'WAKING…'}</Text>
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
              <ProgressRing progress={vm.progressInt} color={vm.stateColor} glow={!vm.isPaused}>
                <View style={{ flexDirection: 'row', alignItems: 'flex-end' }}>
                  <RollingNumber value={vm.progressInt} fontSize={32} weight="700" color={c.t1} letterSpacing={-1} />
                  <Text style={{ fontSize: 15, fontWeight: '700', color: c.t3, marginBottom: 2 }}>%</Text>
                </View>
              </ProgressRing>
              <View style={{ flex: 1, gap: 15 }}>
                <View>
                  <Label>LAYER</Label>
                  <View style={{ marginTop: 5, flexDirection: 'row', alignItems: 'flex-end' }}>
                    <RollingNumber value={vm.layer} fontSize={19} weight="600" color={c.t1} />
                    <Text style={{ fontWeight: '500', fontSize: 19, color: c.t3, fontFamily: mono }}> / {vm.totalLayers}</Text>
                  </View>
                </View>
                <View style={{ height: 1, backgroundColor: c.line }} />
                <View>
                  <Label>TIME LEFT</Label>
                  <RollingNumber value={vm.etaText} fontSize={19} weight="600" color={c.t1} style={{ marginTop: 5 }} />
                  <Text style={{ marginTop: 3, fontWeight: '500', fontSize: 12, color: c.t3 }}>done ~ {vm.doneText}</Text>
                </View>
              </View>
            </View>

            <TempGrid vm={vm} heatingEnabled />

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
                <Breathe active={vm.lightOn} color={c.accent} grow={0.8} maxOpacity={0.5}>
                  <Feather name="sun" size={17} color={vm.lightOn ? c.accent : c.t1} />
                </Breathe>
                <Text style={{ fontWeight: '600', fontSize: 14, color: vm.lightOn ? c.accent : c.t1 }}>Light</Text>
                <Text style={{ fontWeight: '600', fontSize: 12, color: vm.lightOn ? c.accent : c.t1, opacity: 0.7, fontFamily: mono }}>{vm.lightOn ? 'ON' : 'OFF'}</Text>
              </Tap>
              <View style={{ flex: 1, zIndex: speedOpen ? 30 : 0 } as any}>
                <Tap onPress={() => setSpeedOpen((o) => !o)} style={{ width: '100%', height: 54, borderRadius: 16, backgroundColor: speedOpen ? c.s4 : c.s3, flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 9 }}>
                  <Feather name="zap" size={17} color={c.t1} />
                  <Text style={{ fontWeight: '600', fontSize: 14, color: c.t1 }}>{SPEEDS.find((s) => s.i === speedIdx)?.name ?? vm.speedLabel}</Text>
                  <Feather name="chevrons-up" size={13} color={c.t3} />
                </Tap>
                {speedOpen && (
                  <FadeRise dy={6} duration={170} style={{ position: 'absolute', left: -6, right: -6, bottom: 62, zIndex: 30 } as any}>
                    <View style={{ backgroundColor: c.s1, borderWidth: 1, borderColor: c.line2, borderRadius: 16, padding: 5, ...shadow1, shadowOpacity: 0.55, shadowRadius: 24, shadowOffset: { width: 0, height: 12 } }}>
                      <Text style={{ paddingHorizontal: 10, paddingTop: 7, paddingBottom: 6, fontWeight: '600', fontSize: 9, letterSpacing: 1, color: c.t3, fontFamily: mono }}>SPEED</Text>
                      {SPEEDS.map((s) => {
                        const on = speedIdx === s.i;
                        return (
                          <Tap key={s.i} onPress={() => { h.onSpeedSet(s.i); setSpeedOpen(false); }} style={{ flexDirection: 'row', alignItems: 'center', gap: 10, paddingHorizontal: 11, paddingVertical: 11, borderRadius: 11, backgroundColor: on ? c.s3 : 'transparent' }}>
                            <View style={{ width: 8, height: 8, borderRadius: 4, backgroundColor: c[s.dot] as string }} />
                            <Text style={{ flex: 1, fontWeight: '600', fontSize: 14, color: c.t1 }}>{s.name}</Text>
                            <Text style={{ fontWeight: '500', fontSize: 11, color: c.t3, fontFamily: mono }}>{s.hint}</Text>
                            {on && <Feather name="check" size={15} color={c.accent} />}
                          </Tap>
                        );
                      })}
                    </View>
                  </FadeRise>
                )}
              </View>
            </View>

            {/* AMS strip */}
            <View style={{ marginHorizontal: 20, marginTop: 20, marginBottom: 8 }}>
              <View style={{ flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', marginBottom: 11 }}>
                <Text style={{ fontWeight: '600', fontSize: 11, letterSpacing: 1.2, color: c.t3, fontFamily: mono }}>AMS</Text>
                <Tap onPress={() => h.onTab('ams')} style={{ flexDirection: 'row', alignItems: 'center', gap: 3 }}>
                  <Text style={{ fontWeight: '600', fontSize: 13, color: c.accent }}>Details</Text>
                  <Feather name="chevron-right" size={13} color={c.accent} />
                </Tap>
              </View>
              {/* Scrolls once a second unit is attached: a fixed flex row sized for 4 collapses to
                  slivers at 5 (AMS 2 Pro + HT) and is unreadable at 9. Chips keep a minimum width and
                  the row simply scrolls; with <=4 slots it still fills the width exactly as before. */}
              <ScrollView
                horizontal
                showsHorizontalScrollIndicator={false}
                scrollEnabled={vm.ams.length > 4}
                contentContainerStyle={{ flexDirection: 'row', gap: 10, flexGrow: 1 }}>
                {vm.ams.map((t, i) => (
                  <View key={`${t.unitId}:${t.localId}`} style={{ flex: vm.ams.length > 4 ? undefined : 1, minWidth: vm.ams.length > 4 ? 74 : undefined, paddingVertical: 11, paddingHorizontal: 8, borderRadius: 15, backgroundColor: c.s1, alignItems: 'center', gap: 8, borderWidth: t.active ? 1.5 : 1, borderColor: t.active ? c.accent : c.line }}>
                    <View style={{ width: 32, height: 32, borderRadius: 9, backgroundColor: t.empty ? 'transparent' : t.color, borderWidth: t.empty ? 1 : 0, borderColor: c.line2, borderStyle: t.empty ? 'dashed' : 'solid' }} />
                    <Text numberOfLines={1} style={{ fontWeight: '600', fontSize: 9.5, color: c.t2 }}>{t.label}</Text>
                    <Text style={{ fontWeight: '600', fontSize: 11, color: c.t1, fontFamily: mono, fontVariant: ['tabular-nums'] }}>{t.pct}</Text>
                    {t.active ? <PulseDot color={c.accent} size={5} period={2000} /> : <View style={{ width: 5, height: 5, borderRadius: 3, backgroundColor: c.accent, opacity: 0 }} />}
                  </View>
                ))}
              </ScrollView>
            </View>
          </>
        )}

        {/* ---- IDLE ---- */}
        {vm.kind === 'idle' && (
          <>
            <FadeRise>
            <View style={{ marginHorizontal: 20, marginTop: 18, padding: 22, borderRadius: 22, backgroundColor: c.s1, borderWidth: 1, borderColor: c.line, alignItems: 'center', ...shadow1 }}>
              <Text style={{ fontWeight: '600', fontSize: 14, lineHeight: 20, color: c.t2, textAlign: 'center', maxWidth: 250 }}>No active job. The bed is clear and filament is loaded.</Text>
              <Tap onPress={() => h.onTab('library')} style={{ marginTop: 16, width: '100%', height: 52, borderRadius: 15, backgroundColor: c.accent, flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 8 }}>
                <Feather name="plus" size={18} color={c.accentInk} />
                <Text style={{ fontWeight: '600', fontSize: 16, color: c.accentInk }}>New print</Text>
              </Tap>
            </View>
            </FadeRise>
            <TempGrid vm={vm} heatingEnabled={false} />
          </>
        )}

        {/* ---- COMPLETE ---- */}
        {vm.kind === 'complete' && (
          <View style={{ marginHorizontal: 20, marginTop: 18 }}>
            <Confetti count={22} />
            <FadeRise>
            <View style={{ padding: 22, borderRadius: 22, backgroundColor: c.s1, borderWidth: 1, borderColor: c.line, ...shadow1 }}>
              <View style={{ flexDirection: 'row', alignItems: 'center', gap: 13 }}>
                <Pop>
                  <View style={{ width: 48, height: 48, borderRadius: 24, backgroundColor: c.runningDim, alignItems: 'center', justifyContent: 'center' }}>
                    <Feather name="check" size={24} color={c.running} />
                  </View>
                </Pop>
                <View>
                  <Text style={{ fontWeight: '700', fontSize: 20, color: c.t1, letterSpacing: -0.3 }}>Fresh off the bed</Text>
                  <Text style={{ marginTop: 5, fontWeight: '500', fontSize: 12, color: c.t3, fontFamily: mono }}>{vm.heroSub || 'finished'}</Text>
                </View>
              </View>
              {vm.awaitingPlateClear && (
                <Tap onPress={h.onPlateCleared} style={{ marginTop: 18, height: 52, borderRadius: 15, backgroundColor: c.accent, flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 8 }}>
                  <Feather name="check-square" size={16} color={c.accentInk} />
                  <Text style={{ fontWeight: '600', fontSize: 16, color: c.accentInk }}>Plate cleared — continue queue</Text>
                </Tap>
              )}
              <Tap onPress={h.onPrintAgain} style={{ marginTop: vm.awaitingPlateClear ? 10 : 18, height: 52, borderRadius: 15, backgroundColor: vm.awaitingPlateClear ? c.s3 : c.accent, alignItems: 'center', justifyContent: 'center' }}>
                <Text style={{ fontWeight: '600', fontSize: 16, color: vm.awaitingPlateClear ? c.t1 : c.accentInk }}>Print again</Text>
              </Tap>
            </View>
            </FadeRise>
          </View>
        )}

        {/* ---- ERROR ---- */}
        {vm.kind === 'error' && (
          <>
            <FadeRise>
            <View style={{ marginHorizontal: 20, marginTop: 18, padding: 20, borderRadius: 22, backgroundColor: c.s1, borderWidth: 1, borderColor: c.line, ...shadow1 }}>
              <View style={{ flexDirection: 'row', alignItems: 'center', gap: 12 }}>
                <View style={{ width: 42, height: 42, borderRadius: 12, backgroundColor: c.errorDim, alignItems: 'center', justifyContent: 'center' }}>
                  <Feather name="alert-triangle" size={22} color={c.error} />
                </View>
                <View style={{ flex: 1 }}>
                  <Text style={{ fontWeight: '700', fontSize: 17, lineHeight: 20, color: c.t1 }}>Printer reported an error</Text>
                  <Text style={{ marginTop: 4, fontWeight: '500', fontSize: 11, color: c.t3, fontFamily: mono }}>
                    {vm.hmsCode ? `HMS ${vm.hmsCode}` : vm.heroSub || 'Print error'}
                  </Text>
                </View>
              </View>
            </View>
            </FadeRise>
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
          <FadeRise>
          <View style={{ marginHorizontal: 24, marginTop: 48, alignItems: 'center', gap: 16 }}>
            <View style={{ width: 72, height: 72, borderRadius: 22, backgroundColor: c.s2, alignItems: 'center', justifyContent: 'center' }}>
              <Feather name="wifi-off" size={32} color={c.t3} />
            </View>
            <View style={{ alignItems: 'center' }}>
              <Text style={{ fontWeight: '700', fontSize: 20, color: c.t1, letterSpacing: -0.3 }}>Can't reach {printerName}</Text>
              <Text style={{ marginTop: 8, fontWeight: '500', fontSize: 13, lineHeight: 19, color: c.t3, textAlign: 'center', maxWidth: 260 }}>
                No response right now. Make sure it's powered on and on your network.
              </Text>
            </View>
            <Tap onPress={h.onRetry} style={{ marginTop: 4, paddingHorizontal: 26, height: 48, borderRadius: 14, backgroundColor: c.accent, alignItems: 'center', justifyContent: 'center' }}>
              <Text style={{ fontWeight: '600', fontSize: 15, color: c.accentInk }}>Retry connection</Text>
            </Tap>
          </View>
          </FadeRise>
        )}

        {/* ---- CONNECTING ---- */}
        {vm.kind === 'connecting' && (
          <View style={{ paddingHorizontal: 20, paddingTop: 16 }}>
            <Skeleton style={{ width: '100%', aspectRatio: 16 / 10, borderRadius: 18 }} />
            <View style={{ marginTop: 16, padding: 20, borderRadius: 22, backgroundColor: c.s1, borderWidth: 1, borderColor: c.line, flexDirection: 'row', alignItems: 'center', gap: 18 }}>
              <Skeleton style={{ width: 110, height: 110, borderRadius: 55 }} />
              <View style={{ flex: 1, gap: 12 }}>
                <Skeleton style={{ height: 13, width: '55%', borderRadius: 5 }} />
                <Skeleton style={{ height: 22, width: '85%', borderRadius: 6 }} />
                <Skeleton style={{ height: 13, width: '42%', borderRadius: 5 }} />
              </View>
            </View>
            <Text style={{ marginTop: 20, textAlign: 'center', fontWeight: '500', fontSize: 12, color: c.t3 }}>Reaching {printerName}…</Text>
          </View>
        )}

    </ScrollView>
  );
}
