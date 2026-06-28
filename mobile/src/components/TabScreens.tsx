import React, { useCallback, useEffect, useState } from 'react';
import { View, Text, Pressable, ScrollView, RefreshControl, ActivityIndicator } from 'react-native';
import { Image } from 'expo-image';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { Feather } from '@expo/vector-icons';
import { c, mono, shadow1 } from '@/theme';
import type { BambuddyClient } from '@/api/bambuddyClient';
import type { LibraryFile, QueueItem, PrinterStatus, SmartPlug, PrintLogEntry, ArchiveStats, AppSettings } from '@/api/types';
import { presentDashboard, fmtDuration, normColor } from '@/dashboard/present';

function fmtBytes(n?: number): string {
  if (!n) return '';
  if (n > 1e6) return `${(n / 1e6).toFixed(1)} MB`;
  if (n > 1e3) return `${(n / 1e3).toFixed(0)} KB`;
  return `${n} B`;
}

function currencySymbol(code?: string): string {
  switch ((code || '').toUpperCase()) {
    case 'GBP': return '£';
    case 'USD': case 'AUD': case 'CAD': case 'NZD': return '$';
    case 'EUR': return '€';
    case 'JPY': case 'CNY': return '¥';
    default: return code ? `${code} ` : '$';
  }
}
function fmtMoney(sym: string, n: number): string {
  return `${sym}${n.toFixed(2)}`;
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
export function PowerView({ client, printerId, status }: { client: BambuddyClient; printerId: number; status: PrinterStatus | null }) {
  const [plug, setPlug] = useState<SmartPlug | null | undefined>(undefined);
  const [on, setOn] = useState(false);
  const [reachable, setReachable] = useState(true);
  const [watts, setWatts] = useState<number | null>(null);
  const [kwh, setKwh] = useState<number | null>(null);
  const [autoOff, setAutoOff] = useState(false);
  const [settings, setSettings] = useState<AppSettings | null>(null);

  useEffect(() => {
    client.getPlug(printerId).then((p) => setPlug(p ?? null)).catch(() => setPlug(null));
    client.getSettings().then(setSettings).catch(() => setSettings(null));
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

  const price = settings?.energy_cost_per_kwh ?? null;
  const sym = currencySymbol(settings?.currency);
  const todayCost = price != null && kwh != null ? kwh * price : null;

  // Live-print projection: extrapolate this print's energy from current draw.
  const running = status?.state?.toUpperCase() === 'RUNNING';
  const pct = typeof status?.progress === 'number' ? status.progress : null;
  const remainMin = typeof status?.remaining_time === 'number' ? status.remaining_time : null;
  let projCost: number | null = null;
  let soFarCost: number | null = null;
  if (running && price != null && watts != null && remainMin != null && pct != null && pct > 0 && pct < 100) {
    const elapsedMin = (remainMin * pct) / (100 - pct); // total = elapsed + remain; pct = elapsed/total
    const kwhPerMin = watts / 1000 / 60;
    soFarCost = elapsedMin * kwhPerMin * price;
    projCost = (elapsedMin + remainMin) * kwhPerMin * price;
  }

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
        <View style={{ flex: 1, padding: 16, borderRadius: 18, backgroundColor: c.s1, borderWidth: 1, borderColor: c.line }}>
          <Text style={{ fontWeight: '600', fontSize: 10, letterSpacing: 1, color: c.t3, fontFamily: mono }}>DRAWING NOW</Text>
          <View style={{ marginTop: 9, flexDirection: 'row', alignItems: 'baseline', gap: 4 }}>
            <Text style={{ fontWeight: '700', fontSize: 28, color: c.t1, fontVariant: ['tabular-nums'], letterSpacing: -1 }}>{watts == null ? '—' : `${Math.round(watts)}`}</Text>
            <Text style={{ fontWeight: '600', fontSize: 13, color: c.t3 }}>W</Text>
          </View>
        </View>
        <View style={{ flex: 1, padding: 16, borderRadius: 18, backgroundColor: c.s1, borderWidth: 1, borderColor: c.line }}>
          <Text style={{ fontWeight: '600', fontSize: 10, letterSpacing: 1, color: c.t3, fontFamily: mono }}>TODAY</Text>
          <View style={{ marginTop: 9, flexDirection: 'row', alignItems: 'baseline', gap: 4 }}>
            <Text style={{ fontWeight: '700', fontSize: 28, color: c.t1, fontVariant: ['tabular-nums'], letterSpacing: -1 }}>{kwh == null ? '—' : kwh.toFixed(2)}</Text>
            <Text style={{ fontWeight: '600', fontSize: 13, color: c.t3 }}>kWh</Text>
          </View>
          <Text style={{ marginTop: 6, fontWeight: '600', fontSize: 13, color: c.accent, fontVariant: ['tabular-nums'] }}>
            {todayCost == null ? (price == null ? 'price not set' : '—') : `${fmtMoney(sym, todayCost)} today`}
          </Text>
        </View>
      </View>

      {running && (
        <View style={{ marginHorizontal: 20, marginTop: 12, padding: 16, borderRadius: 18, backgroundColor: c.s1, borderWidth: 1.5, borderColor: c.running }}>
          <View style={{ flexDirection: 'row', alignItems: 'center', gap: 7 }}>
            <View style={{ width: 7, height: 7, borderRadius: 4, backgroundColor: c.running }} />
            <Text style={{ fontWeight: '600', fontSize: 10, letterSpacing: 1, color: c.running, fontFamily: mono }}>THIS PRINT</Text>
          </View>
          <Text numberOfLines={1} style={{ marginTop: 8, fontWeight: '600', fontSize: 13, color: c.t1 }}>{status?.subtask_name || 'Current print'}</Text>
          <View style={{ marginTop: 12, flexDirection: 'row', gap: 24 }}>
            <View>
              <Text style={{ fontWeight: '600', fontSize: 10, letterSpacing: 0.5, color: c.t3, fontFamily: mono }}>SO FAR</Text>
              <Text style={{ marginTop: 4, fontWeight: '700', fontSize: 20, color: c.t1, fontVariant: ['tabular-nums'], letterSpacing: -0.5 }}>{soFarCost == null ? '—' : fmtMoney(sym, soFarCost)}</Text>
            </View>
            <View>
              <Text style={{ fontWeight: '600', fontSize: 10, letterSpacing: 0.5, color: c.t3, fontFamily: mono }}>PROJECTED</Text>
              <Text style={{ marginTop: 4, fontWeight: '700', fontSize: 20, color: c.accent, fontVariant: ['tabular-nums'], letterSpacing: -0.5 }}>{projCost == null ? '—' : fmtMoney(sym, projCost)}</Text>
            </View>
          </View>
          <Text style={{ marginTop: 10, fontWeight: '500', fontSize: 11, color: c.t3 }}>
            {price == null ? 'Set an electricity price in Bambuddy to see cost.' : `Estimate from ${watts == null ? '—' : Math.round(watts)} W live draw · ${remainMin ?? '—'} min left`}
          </Text>
        </View>
      )}
      <View style={{ marginHorizontal: 20, marginTop: 14, padding: 16, borderRadius: 18, backgroundColor: c.s1, borderWidth: 1, borderColor: c.line, flexDirection: 'row', alignItems: 'center', gap: 14 }}>
        <View style={{ flex: 1 }}>
          <Text style={{ fontWeight: '600', fontSize: 14, color: c.t1 }}>Auto power-off</Text>
          <Text style={{ marginTop: 5, fontWeight: '500', fontSize: 12, lineHeight: 17, color: c.t3 }}>Turn off the plug after a print finishes and the hotend cools below 50°C.</Text>
        </View>
        <Pressable onPress={() => setAutoOff((v) => !v)} style={{ width: 48, height: 30, borderRadius: 15, backgroundColor: autoOff ? c.accent : c.s3, justifyContent: 'center' }}>
          <View style={{ width: 24, height: 24, borderRadius: 12, backgroundColor: '#fff', marginLeft: autoOff ? 21 : 3 }} />
        </Pressable>
      </View>
      <View style={{ marginHorizontal: 20, marginTop: 14, paddingHorizontal: 16, paddingVertical: 13, borderRadius: 14, backgroundColor: c.s1, borderWidth: 1, borderColor: c.line, flexDirection: 'row', alignItems: 'center', gap: 10 }}>
        <Feather name="zap" size={14} color={c.t3} />
        <Text style={{ flex: 1, fontWeight: '500', fontSize: 12, lineHeight: 17, color: c.t3 }}>
          {price == null
            ? 'Electricity price not set. Add it in Bambuddy → Settings → Energy.'
            : `Tariff ${fmtMoney(sym, price)}/kWh · set in Bambuddy → Settings → Energy`}
        </Text>
      </View>
    </Page>
  );
}

// ---------------- HISTORY ----------------
const STATUS_META: Record<string, { label: string; color: string; dim: string }> = {
  completed: { label: 'Done', color: c.running, dim: c.runningDim },
  failed: { label: 'Failed', color: c.error, dim: c.errorDim },
  cancelled: { label: 'Canceled', color: c.idle, dim: c.idleDim },
};
function statusMeta(s: string) {
  return STATUS_META[s] ?? { label: s ? s[0].toUpperCase() + s.slice(1) : 'Unknown', color: c.idle, dim: c.idleDim };
}

/** "2026-06-28T15:07:35.681213" is naive *local* time (no Z); new Date() parses naive as local. */
function relTime(iso: string | null): string {
  if (!iso) return '';
  const ms = Date.now() - new Date(iso).getTime();
  if (!isFinite(ms)) return '';
  const m = Math.floor(ms / 60000);
  if (m < 1) return 'just now';
  if (m < 60) return `${m}m ago`;
  const h = Math.floor(m / 60);
  if (h < 24) return `${h}h ago`;
  const d = Math.floor(h / 24);
  if (d < 7) return `${d}d ago`;
  return new Date(iso).toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
}

/** First swatch from a possibly comma-joined "#565656,#000000". */
function firstColor(s: string | null): string | null {
  if (!s) return null;
  const first = s.split(',')[0]?.trim();
  return normColor(first || undefined);
}

function StatBlock({ label, value, unit, accent }: { label: string; value: string; unit?: string; accent?: boolean }) {
  return (
    <View style={{ flex: 1, minWidth: '30%' }}>
      <Text style={{ fontWeight: '600', fontSize: 9.5, letterSpacing: 1, color: c.t3, fontFamily: mono }}>{label}</Text>
      <View style={{ marginTop: 6, flexDirection: 'row', alignItems: 'baseline', gap: 3 }}>
        <Text style={{ fontWeight: '700', fontSize: 25, color: accent ? c.accent : c.t1, fontVariant: ['tabular-nums'], letterSpacing: -1 }}>{value}</Text>
        {unit ? <Text style={{ fontWeight: '600', fontSize: 12, color: c.t3 }}>{unit}</Text> : null}
      </View>
    </View>
  );
}

/** Pure-RN circular success gauge (no SVG dep): two stacked rotated bordered circles. */
function SuccessRing({ pct }: { pct: number }) {
  const size = 76;
  const ring = 7;
  return (
    <View style={{ width: size, height: size, alignItems: 'center', justifyContent: 'center' }}>
      <View style={{ position: 'absolute', width: size, height: size, borderRadius: size / 2, borderWidth: ring, borderColor: c.s3 }} />
      <View style={{ position: 'absolute', width: size, height: size, borderRadius: size / 2, borderWidth: ring, borderColor: 'transparent', borderTopColor: c.accent, borderRightColor: pct >= 50 ? c.accent : 'transparent', transform: [{ rotate: `${-90 + Math.min(pct, 100) * 3.6}deg` }] }} />
      <View style={{ alignItems: 'center' }}>
        <Text style={{ fontWeight: '700', fontSize: 20, color: c.t1, fontVariant: ['tabular-nums'], letterSpacing: -0.5 }}>{pct}</Text>
        <Text style={{ fontWeight: '600', fontSize: 8, letterSpacing: 0.5, color: c.t3, fontFamily: mono, marginTop: -2 }}>SUCCESS</Text>
      </View>
    </View>
  );
}

function StatsBanner({ stats }: { stats: ArchiveStats }) {
  const total = stats.total_prints || 0;
  const success = total > 0 ? Math.round((stats.successful_prints / total) * 100) : 0;
  const grams = stats.total_filament_grams || 0;
  const filamentVal = grams >= 1000 ? (grams / 1000).toFixed(2) : Math.round(grams).toString();
  const filamentUnit = grams >= 1000 ? 'kg' : 'g';
  const showCost = stats.total_cost > 0;
  const showEnergy = stats.total_energy_kwh > 0;

  return (
    <View style={{ marginHorizontal: 20, marginTop: 18 }}>
      <View style={{ padding: 20, borderRadius: 22, backgroundColor: c.s1, borderWidth: 1, borderColor: c.line, ...shadow1 }}>
        <View style={{ flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' }}>
          <View>
            <Text style={{ fontWeight: '600', fontSize: 10, letterSpacing: 1.2, color: c.t3, fontFamily: mono }}>LIFETIME PRINTS</Text>
            <Text style={{ fontWeight: '700', fontSize: 46, color: c.t1, letterSpacing: -2, fontVariant: ['tabular-nums'], marginTop: 7 }}>{total}</Text>
            <View style={{ flexDirection: 'row', alignItems: 'center', gap: 7, marginTop: 4 }}>
              <View style={{ width: 7, height: 7, borderRadius: 4, backgroundColor: c.running }} />
              <Text style={{ fontWeight: '500', fontSize: 12, color: c.t2 }}>{stats.successful_prints} done</Text>
              {stats.failed_prints > 0 && (
                <>
                  <View style={{ width: 7, height: 7, borderRadius: 4, backgroundColor: c.error, marginLeft: 6 }} />
                  <Text style={{ fontWeight: '500', fontSize: 12, color: c.t2 }}>{stats.failed_prints} failed</Text>
                </>
              )}
            </View>
          </View>
          <SuccessRing pct={success} />
        </View>
      </View>

      <View style={{ marginTop: 12, padding: 18, borderRadius: 22, backgroundColor: c.s1, borderWidth: 1, borderColor: c.line, flexDirection: 'row', flexWrap: 'wrap', rowGap: 18, columnGap: 12 }}>
        <StatBlock label="PRINT HOURS" value={stats.total_print_time_hours.toFixed(1)} unit="h" />
        <StatBlock label="FILAMENT" value={filamentVal} unit={filamentUnit} />
        {showCost && <StatBlock label="EST. COST" value={`$${stats.total_cost.toFixed(2)}`} accent />}
        <StatBlock label="ENERGY" value={showEnergy ? stats.total_energy_kwh.toFixed(2) : '—'} unit={showEnergy ? 'kWh' : undefined} />
      </View>
      {stats.energy_data_warming_up && (
        <Text style={{ marginTop: 8, marginLeft: 4, fontWeight: '500', fontSize: 11, color: c.t3 }}>
          Energy data is warming up — costs appear after the next full job.
        </Text>
      )}
    </View>
  );
}

function HistoryRow({ entry, client, camToken }: { entry: PrintLogEntry; client: BambuddyClient; camToken: string | null }) {
  const meta = statusMeta(entry.status);
  const swatch = firstColor(entry.filament_color);
  const thumb = client.printLogThumbUrl(entry.id, camToken, entry.thumbnail_path);
  const mins = entry.duration_seconds != null ? entry.duration_seconds / 60 : null;

  const facts: string[] = [];
  if (mins != null) facts.push(fmtDuration(mins));
  if (entry.filament_used_grams != null) facts.push(`${Math.round(entry.filament_used_grams)}g`);
  if (entry.energy_kwh != null) facts.push(`${entry.energy_kwh.toFixed(2)} kWh`);
  const cost = entry.cost ?? entry.energy_cost;

  return (
    <View style={{ flexDirection: 'row', gap: 13, padding: 12, borderRadius: 16, backgroundColor: c.s1, borderWidth: 1, borderColor: c.line }}>
      <View style={{ width: 58, height: 58, borderRadius: 12, overflow: 'hidden', backgroundColor: '#0e1113', borderWidth: 1, borderColor: c.line, alignItems: 'center', justifyContent: 'center' }}>
        {thumb ? (
          <Image source={{ uri: thumb }} style={{ width: '100%', height: '100%' }} contentFit="cover" transition={120} cachePolicy="memory-disk" />
        ) : (
          <Feather name="box" size={22} color={c.t3} />
        )}
      </View>
      <View style={{ flex: 1, justifyContent: 'center' }}>
        <View style={{ flexDirection: 'row', alignItems: 'center', gap: 8 }}>
          <Text numberOfLines={1} style={{ flex: 1, fontWeight: '600', fontSize: 14, color: c.t1 }}>{entry.print_name || `Print ${entry.id}`}</Text>
          <View style={{ paddingHorizontal: 8, paddingVertical: 3, borderRadius: 7, backgroundColor: meta.dim }}>
            <Text style={{ fontWeight: '700', fontSize: 9.5, letterSpacing: 0.4, color: meta.color, fontFamily: mono }}>{meta.label.toUpperCase()}</Text>
          </View>
        </View>
        <View style={{ flexDirection: 'row', alignItems: 'center', gap: 8, marginTop: 6 }}>
          {swatch && <View style={{ width: 11, height: 11, borderRadius: 3, backgroundColor: swatch, borderWidth: 1, borderColor: c.line2 }} />}
          <Text style={{ fontWeight: '500', fontSize: 11, color: c.t3, fontFamily: mono }}>{relTime(entry.started_at)}</Text>
          {facts.length > 0 && <Text style={{ fontWeight: '500', fontSize: 11, color: c.t3, fontFamily: mono }}>· {facts.join(' · ')}</Text>}
          {cost != null && cost > 0 && (
            <Text style={{ fontWeight: '600', fontSize: 11, color: c.accent, fontFamily: mono }}>· ${cost.toFixed(2)}</Text>
          )}
        </View>
      </View>
    </View>
  );
}

export function HistoryView({ client, camToken }: { client: BambuddyClient; camToken: string | null }) {
  const [entries, setEntries] = useState<PrintLogEntry[] | null>(null);
  const [stats, setStats] = useState<ArchiveStats | null>(null);

  const load = useCallback(() => {
    client.getPrintLog(50).then((p) => setEntries(p.items)).catch(() => setEntries([]));
    client.getArchiveStats().then(setStats).catch(() => setStats(null));
  }, [client]);
  useEffect(() => {
    load();
    const id = setInterval(load, 15000);
    return () => clearInterval(id);
  }, [load]);

  return (
    <Page title="History">
      {entries === null && <ActivityIndicator color={c.accent} style={{ marginTop: 40 }} />}
      {entries !== null && stats && stats.total_prints > 0 && <StatsBanner stats={stats} />}
      {entries?.length === 0 && (
        <Empty icon="clock" title="No prints yet" body="Once you finish a print it's archived here with its stats, filament, and cost." />
      )}
      {!!entries?.length && (
        <>
          <Text style={{ fontWeight: '600', fontSize: 11, letterSpacing: 1, color: c.t3, fontFamily: mono, paddingHorizontal: 20, paddingTop: 26, paddingBottom: 12 }}>RECENT PRINTS</Text>
          <View style={{ paddingHorizontal: 20, gap: 10 }}>
            {entries.map((e) => (
              <HistoryRow key={e.id} entry={e} client={client} camToken={camToken} />
            ))}
          </View>
        </>
      )}
    </Page>
  );
}
