import React, { useCallback, useEffect, useState } from 'react';
import { View, Text, Pressable, ScrollView, RefreshControl, ActivityIndicator } from 'react-native';
import { Image } from 'expo-image';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { Feather } from '@expo/vector-icons';
import { c, mono, shadow1 } from '@/theme';
import type { BambuddyClient } from '@/api/bambuddyClient';
import type { LibraryFile, QueueItem, PrinterStatus, SmartPlug } from '@/api/types';
import { presentDashboard, fmtDuration, normColor } from '@/dashboard/present';

function fmtBytes(n?: number): string {
  if (!n) return '';
  if (n > 1e6) return `${(n / 1e6).toFixed(1)} MB`;
  if (n > 1e3) return `${(n / 1e3).toFixed(0)} KB`;
  return `${n} B`;
}

function Page({ title, right, children }: { title: string; right?: React.ReactNode; sub?: string; children: React.ReactNode }) {
  const insets = useSafeAreaInsets();
  return (
    <ScrollView
      style={{ flex: 1, backgroundColor: c.bg }}
      showsVerticalScrollIndicator={false}
      contentContainerStyle={{ paddingTop: insets.top + 8, paddingBottom: 120 }}>
      <View style={{ paddingHorizontal: 20, flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' }}>
        <Text style={{ fontWeight: '700', fontSize: 30, color: c.t1, letterSpacing: -0.8 }}>{title}</Text>
        {right}
      </View>
      {children}
    </ScrollView>
  );
}

function Empty({ icon, title, body, cta, onCta }: { icon: keyof typeof Feather.glyphMap; title: string; body: string; cta?: string; onCta?: () => void }) {
  return (
    <View style={{ marginHorizontal: 24, marginTop: 48, alignItems: 'center', gap: 15 }}>
      <View style={{ width: 72, height: 72, borderRadius: 22, backgroundColor: c.s2, alignItems: 'center', justifyContent: 'center' }}>
        <Feather name={icon} size={32} color={c.t3} />
      </View>
      <View style={{ alignItems: 'center' }}>
        <Text style={{ fontWeight: '700', fontSize: 20, color: c.t1, letterSpacing: -0.3 }}>{title}</Text>
        <Text style={{ marginTop: 8, fontWeight: '500', fontSize: 13, lineHeight: 19, color: c.t3, textAlign: 'center', maxWidth: 250 }}>{body}</Text>
      </View>
      {cta && (
        <Pressable onPress={onCta} style={({ pressed }) => [{ marginTop: 4, paddingHorizontal: 24, height: 48, borderRadius: 14, backgroundColor: c.accent, alignItems: 'center', justifyContent: 'center' }, pressed && { opacity: 0.7 }]}>
          <Text style={{ fontWeight: '600', fontSize: 15, color: c.accentInk }}>{cta}</Text>
        </Pressable>
      )}
    </View>
  );
}

// ---------------- LIBRARY ----------------
export function LibraryView({ client, camToken, onUpload, onPick }: { client: BambuddyClient; camToken: string | null; onUpload: () => void; onPick: (f: LibraryFile) => void }) {
  const [files, setFiles] = useState<LibraryFile[] | null>(null);
  const [refreshing, setRefreshing] = useState(false);
  const load = useCallback(() => {
    client.listFiles().then(setFiles).catch(() => setFiles([]));
  }, [client]);
  useEffect(load, [load]);

  return (
    <Page
      title="Files"
      right={
        <Pressable onPress={onUpload} style={({ pressed }) => [{ width: 38, height: 38, borderRadius: 19, backgroundColor: c.accentDim, alignItems: 'center', justifyContent: 'center' }, pressed && { opacity: 0.6 }]}>
          <Feather name="plus" size={22} color={c.accent} />
        </Pressable>
      }>
      {files === null && <ActivityIndicator color={c.accent} style={{ marginTop: 40 }} />}
      {files?.length === 0 && <Empty icon="folder" title="No files yet" body="Upload an STL, 3MF, or sliced G-code and it'll show up here." cta="Upload a model" onCta={onUpload} />}
      {!!files?.length && (
        <View style={{ flexDirection: 'row', flexWrap: 'wrap', paddingHorizontal: 20, paddingTop: 16, gap: 13 }}>
          {files.map((f) => {
            const sliced = (f.file_type || '').includes('gcode') || !!f.sliced_for_model;
            return (
              <Pressable key={f.id} onPress={() => onPick(f)} style={({ pressed }) => [{ width: '47%', flexGrow: 1 }, pressed && { opacity: 0.7 }]}>
                <View style={{ width: '100%', aspectRatio: 4 / 3, borderRadius: 14, overflow: 'hidden', backgroundColor: '#0e1113', borderWidth: 1, borderColor: c.line, alignItems: 'center', justifyContent: 'center' }}>
                  {f.thumbnail_path ? (
                    <Image source={{ uri: client.fileThumbUrl(f.id, camToken, f.thumbnail_path) }} style={{ width: '100%', height: '100%' }} contentFit="cover" transition={120} cachePolicy="memory-disk" />
                  ) : (
                    <Feather name={(f.file_type || '').includes('gcode') ? 'box' : 'file'} size={26} color={c.t3} />
                  )}
                  <View style={{ position: 'absolute', top: 8, left: 8, paddingHorizontal: 6, paddingVertical: 3, borderRadius: 6, backgroundColor: 'rgba(0,0,0,0.5)' }}>
                    <Text style={{ fontWeight: '600', fontSize: 8.5, letterSpacing: 0.5, color: 'rgba(255,255,255,0.8)', fontFamily: mono }}>{(f.file_type || '').toUpperCase()}</Text>
                  </View>
                  {sliced && (
                    <View style={{ position: 'absolute', top: 7, right: 7, width: 18, height: 18, borderRadius: 9, backgroundColor: c.accent, alignItems: 'center', justifyContent: 'center' }}>
                      <Feather name="check" size={11} color={c.accentInk} />
                    </View>
                  )}
                </View>
                <Text numberOfLines={1} style={{ marginTop: 9, fontWeight: '600', fontSize: 13, color: c.t1 }}>{f.print_name || f.filename}</Text>
                <Text style={{ marginTop: 3, fontWeight: '500', fontSize: 11, color: c.t3, fontFamily: mono }}>{fmtBytes(f.file_size)}</Text>
              </Pressable>
            );
          })}
        </View>
      )}
    </Page>
  );
}

// ---------------- QUEUE ----------------
export function QueueView({ client, status, onBrowse }: { client: BambuddyClient; status: PrinterStatus | null; onBrowse: () => void }) {
  const [items, setItems] = useState<QueueItem[] | null>(null);
  const load = useCallback(() => client.listQueue().then(setItems).catch(() => setItems([])), [client]);
  useEffect(() => {
    load();
    const id = setInterval(load, 5000);
    return () => clearInterval(id);
  }, [load]);
  const vm = presentDashboard(status, Date.now());
  const upcoming = (items ?? []).filter((i) => i.status === 'pending' || i.status === 'queued');
  const printing = vm.kind === 'live';

  return (
    <Page title="Queue">
      {items === null && <ActivityIndicator color={c.accent} style={{ marginTop: 40 }} />}
      {items?.length === 0 && !printing && <Empty icon="list" title="Queue is empty" body="Files you send to print line up here. Start one from your library." cta="Browse files" onCta={onBrowse} />}
      {printing && (
        <>
          <Text style={{ fontWeight: '600', fontSize: 11, letterSpacing: 1, color: c.t3, fontFamily: mono, paddingHorizontal: 20, paddingTop: 18, paddingBottom: 11 }}>NOW PRINTING</Text>
          <View style={{ marginHorizontal: 20, padding: 16, borderRadius: 18, backgroundColor: c.s1, borderWidth: 1.5, borderColor: c.running }}>
            <Text numberOfLines={1} style={{ fontWeight: '600', fontSize: 14, color: c.t1 }}>{vm.heroSub || 'Current print'}</Text>
            <Text style={{ marginTop: 5, fontWeight: '600', fontSize: 11, color: c.running, fontFamily: mono }}>{vm.progressInt}% · {vm.etaText} left</Text>
            <View style={{ marginTop: 13, height: 4, borderRadius: 2, backgroundColor: c.s3, overflow: 'hidden' }}>
              <View style={{ height: '100%', width: `${vm.progressInt}%`, backgroundColor: c.running }} />
            </View>
          </View>
        </>
      )}
      {!!upcoming.length && (
        <>
          <View style={{ flexDirection: 'row', justifyContent: 'space-between', paddingHorizontal: 20, paddingTop: 22, paddingBottom: 11 }}>
            <Text style={{ fontWeight: '600', fontSize: 11, letterSpacing: 1, color: c.t3, fontFamily: mono }}>UP NEXT</Text>
            <Text style={{ fontWeight: '600', fontSize: 11, color: c.t3, fontFamily: mono }}>{upcoming.length} jobs</Text>
          </View>
          <View style={{ paddingHorizontal: 20, gap: 10 }}>
            {upcoming.map((j, i) => (
              <View key={j.id} style={{ flexDirection: 'row', alignItems: 'center', gap: 12, padding: 12, borderRadius: 15, backgroundColor: c.s1, borderWidth: 1, borderColor: c.line }}>
                <Text style={{ fontWeight: '600', fontSize: 13, color: c.t3, width: 16, textAlign: 'center', fontFamily: mono }}>{i + 1}</Text>
                <View style={{ flex: 1 }}>
                  <Text numberOfLines={1} style={{ fontWeight: '600', fontSize: 13, color: c.t1 }}>{j.library_file_name || j.archive_name || `Job ${j.id}`}</Text>
                  <Text style={{ marginTop: 4, fontWeight: '500', fontSize: 11, color: c.t3, fontFamily: mono }}>{j.print_time_seconds ? fmtDuration(j.print_time_seconds / 60) : j.status}</Text>
                </View>
                <Pressable onPress={() => client.queueAction(j.id, 'cancel').then(load)} style={({ pressed }) => [{ width: 30, height: 30, alignItems: 'center', justifyContent: 'center' }, pressed && { opacity: 0.5 }]}>
                  <Feather name="x" size={16} color={c.t3} />
                </Pressable>
              </View>
            ))}
          </View>
        </>
      )}
    </Page>
  );
}

// ---------------- AMS ----------------
export function AmsView({ client, status, printerId }: { client: BambuddyClient; status: PrinterStatus | null; printerId: number }) {
  const vm = presentDashboard(status, Date.now());
  const trays = status?.ams?.[0]?.tray ?? [];
  return (
    <Page title="AMS Lite">
      <Text style={{ paddingHorizontal: 20, marginTop: 7, fontWeight: '500', fontSize: 13, color: c.t3 }}>
        {trays.filter((t) => t.tray_type).length} of {Math.max(trays.length, 4)} slots loaded
      </Text>
      <View style={{ paddingHorizontal: 20, paddingTop: 18, gap: 12 }}>
        {vm.ams.map((t, i) => (
          <View key={i} style={{ padding: 16, borderRadius: 18, backgroundColor: c.s1, borderWidth: t.active ? 1.5 : 1, borderColor: t.active ? c.accent : c.line, ...shadow1 }}>
            <View style={{ flexDirection: 'row', alignItems: 'center', gap: 14 }}>
              <View style={{ width: 46, height: 46, borderRadius: 12, backgroundColor: t.empty ? 'transparent' : t.color, borderWidth: t.empty ? 1 : 0, borderColor: c.line2, borderStyle: t.empty ? 'dashed' : 'solid' }} />
              <View style={{ flex: 1 }}>
                <View style={{ flexDirection: 'row', alignItems: 'center', gap: 8 }}>
                  <Text style={{ fontWeight: '700', fontSize: 16, color: c.t1 }}>{t.empty ? 'Empty slot' : t.label}</Text>
                  {t.active && (
                    <View style={{ paddingHorizontal: 7, paddingVertical: 2, borderRadius: 6, backgroundColor: c.accentDim }}>
                      <Text style={{ fontWeight: '600', fontSize: 8.5, letterSpacing: 0.5, color: c.accent, fontFamily: mono }}>ACTIVE</Text>
                    </View>
                  )}
                </View>
                <Text style={{ marginTop: 5, fontWeight: '500', fontSize: 11, color: c.t3, fontFamily: mono }}>Slot {i + 1}</Text>
              </View>
              {!t.empty && <Text style={{ fontWeight: '700', fontSize: 17, color: c.t1, fontFamily: mono }}>{t.pct}</Text>}
            </View>
            {!t.empty ? (
              <View style={{ marginTop: 14, flexDirection: 'row', justifyContent: 'flex-end' }}>
                <Pressable onPress={() => client.amsUnload(printerId).catch(() => {})} style={({ pressed }) => [{ paddingHorizontal: 16, paddingVertical: 8, borderRadius: 10, backgroundColor: c.s3 }, pressed && { opacity: 0.6 }]}>
                  <Text style={{ fontWeight: '600', fontSize: 12, color: c.t1 }}>Unload</Text>
                </Pressable>
              </View>
            ) : (
              <Pressable onPress={() => client.amsLoad(printerId, i).catch(() => {})} style={({ pressed }) => [{ marginTop: 14, height: 44, borderRadius: 12, borderWidth: 1, borderColor: c.line2, alignItems: 'center', justifyContent: 'center' }, pressed && { opacity: 0.6 }]}>
                <Text style={{ fontWeight: '600', fontSize: 13, color: c.accent }}>Load filament</Text>
              </Pressable>
            )}
          </View>
        ))}
      </View>
    </Page>
  );
}

// ---------------- POWER ----------------
export function PowerView({ client, printerId }: { client: BambuddyClient; printerId: number }) {
  const [plug, setPlug] = useState<SmartPlug | null | undefined>(undefined);
  const [on, setOn] = useState(false);
  const [reachable, setReachable] = useState(true);
  const [watts, setWatts] = useState<number | null>(null);
  const [kwh, setKwh] = useState<number | null>(null);
  const [autoOff, setAutoOff] = useState(false);

  useEffect(() => {
    client.getPlug(printerId).then((p) => setPlug(p ?? null)).catch(() => setPlug(null));
  }, [client, printerId]);
  useEffect(() => {
    if (!plug) return;
    const poll = () =>
      client.plugStatus(plug.id).then((s) => {
        setOn(s.state?.toUpperCase() === 'ON');
        setReachable(!!s.reachable);
        const e = s.energy ?? null;
        setWatts(typeof e?.power === 'number' ? e.power : null);
        setKwh(typeof e?.today === 'number' ? e.today : null);
      }).catch(() => setReachable(false));
    poll();
    const id = setInterval(poll, 5000);
    return () => clearInterval(id);
  }, [client, plug]);

  const toggle = () => {
    if (!plug) return;
    const next = !on;
    setOn(next);
    client.plugControl(plug.id, next).catch(() => setOn(!next));
  };

  if (plug === null) {
    return (
      <Page title="Power">
        <Empty icon="power" title="No smart plug linked" body="Link the printer's plug in Bambuddy (Settings → Smart Plugs) to control power here." />
      </Page>
    );
  }
  return (
    <Page title="Power">
      <Text style={{ paddingHorizontal: 20, marginTop: 7, fontWeight: '500', fontSize: 13, color: c.t3 }}>{plug?.name ?? 'Printer smart plug'}</Text>
      <View style={{ marginHorizontal: 20, marginTop: 20, paddingVertical: 30, borderRadius: 22, backgroundColor: c.s1, borderWidth: 1, borderColor: c.line, alignItems: 'center' }}>
        <Pressable
          onPress={toggle}
          disabled={!reachable || plug === undefined}
          style={({ pressed }) => [
            { width: 130, height: 130, borderRadius: 65, backgroundColor: on ? c.accent : c.s3, alignItems: 'center', justifyContent: 'center', opacity: reachable ? 1 : 0.4 },
            on && reachable && { shadowColor: c.accent, shadowOpacity: 0.5, shadowRadius: 24, shadowOffset: { width: 0, height: 0 } },
            pressed && { opacity: 0.8 },
          ]}>
          <Feather name="power" size={48} color={on ? c.accentInk : c.t2} />
        </Pressable>
        <Text style={{ marginTop: 20, fontWeight: '700', fontSize: 19, color: c.t1, letterSpacing: -0.3 }}>{on ? 'Powered on' : 'Powered off'}</Text>
        <View style={{ marginTop: 8, flexDirection: 'row', alignItems: 'center', gap: 7 }}>
          <View style={{ width: 7, height: 7, borderRadius: 4, backgroundColor: reachable ? c.running : c.idle }} />
          <Text style={{ fontWeight: '500', fontSize: 12, color: c.t3 }}>{reachable ? 'Plug reachable' : 'Plug unreachable'}</Text>
        </View>
        <Text style={{ marginTop: 6, fontWeight: '500', fontSize: 12, color: c.t3 }}>Tap to toggle the printer's smart plug</Text>
      </View>
      <View style={{ marginHorizontal: 20, marginTop: 14, flexDirection: 'row', gap: 12 }}>
        {[['DRAWING NOW', watts == null ? '—' : `${Math.round(watts)}`, 'W'], ['TODAY', kwh == null ? '—' : kwh.toFixed(2), 'kWh']].map(([label, val, unit], i) => (
          <View key={i} style={{ flex: 1, padding: 16, borderRadius: 18, backgroundColor: c.s1, borderWidth: 1, borderColor: c.line }}>
            <Text style={{ fontWeight: '600', fontSize: 10, letterSpacing: 1, color: c.t3, fontFamily: mono }}>{label}</Text>
            <View style={{ marginTop: 9, flexDirection: 'row', alignItems: 'baseline', gap: 4 }}>
              <Text style={{ fontWeight: '700', fontSize: 28, color: c.t1, fontFamily: undefined, fontVariant: ['tabular-nums'], letterSpacing: -1 }}>{val}</Text>
              <Text style={{ fontWeight: '600', fontSize: 13, color: c.t3 }}>{unit}</Text>
            </View>
          </View>
        ))}
      </View>
      <View style={{ marginHorizontal: 20, marginTop: 14, padding: 16, borderRadius: 18, backgroundColor: c.s1, borderWidth: 1, borderColor: c.line, flexDirection: 'row', alignItems: 'center', gap: 14 }}>
        <View style={{ flex: 1 }}>
          <Text style={{ fontWeight: '600', fontSize: 14, color: c.t1 }}>Auto power-off</Text>
          <Text style={{ marginTop: 5, fontWeight: '500', fontSize: 12, lineHeight: 17, color: c.t3 }}>Turn off the plug after a print finishes and the hotend cools below 50°C.</Text>
        </View>
        <Pressable onPress={() => setAutoOff((v) => !v)} style={{ width: 48, height: 30, borderRadius: 15, backgroundColor: autoOff ? c.accent : c.s3, justifyContent: 'center' }}>
          <View style={{ width: 24, height: 24, borderRadius: 12, backgroundColor: '#fff', marginLeft: autoOff ? 21 : 3 }} />
        </Pressable>
      </View>
    </Page>
  );
}
