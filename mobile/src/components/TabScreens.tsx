import React, { useCallback, useEffect, useRef, useState } from 'react';
import { View, Text, ScrollView, RefreshControl, ActivityIndicator, Alert } from 'react-native';
import { Image } from 'expo-image';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { Feather } from '@expo/vector-icons';
import { c, mono, shadow1 } from '@/theme';
import type { BambuddyClient } from '@/api/bambuddyClient';
import type { Printer, LibraryFile, QueueItem, PrinterStatus, SmartPlug, PrintLogEntry, ArchiveStats, AppSettings, SlotAssignment, MaintenanceItem, MaintenancePrinter, PrinterFileList } from '@/api/types';
import { spoolGramsRemaining } from '@/api/types';
import { presentDashboard, fmtDuration, normColor, asNum } from '@/dashboard/present';
import { Tap, RollingNumber, PulseDot, ProgressRing, HeatBar, ExtrudeBar, Spark, Breathe, Toggle, FadeRise } from './anim';

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

function Page({ title, right, refreshControl, children }: { title: string; right?: React.ReactNode; sub?: string; refreshControl?: React.ReactElement<import('react-native').RefreshControlProps>; children: React.ReactNode }) {
  const insets = useSafeAreaInsets();
  return (
    <ScrollView
      style={{ flex: 1, backgroundColor: c.bg }}
      showsVerticalScrollIndicator={false}
      refreshControl={refreshControl}
      contentContainerStyle={{ paddingTop: insets.top + 8, paddingBottom: 120 }}>
      <View style={{ paddingHorizontal: 20, flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' }}>
        <Text style={{ fontWeight: '700', fontSize: 30, color: c.t1, letterSpacing: -0.8 }}>{title}</Text>
        {right}
      </View>
      {children}
    </ScrollView>
  );
}

/** A list fetch failed — distinct from a real empty state. */
function LoadFailed({ onRetry }: { onRetry: () => void }) {
  return (
    <View style={{ marginHorizontal: 20, marginTop: 20, padding: 16, borderRadius: 16, backgroundColor: c.s1, borderWidth: 1, borderColor: c.line, flexDirection: 'row', alignItems: 'center', gap: 12 }}>
      <Feather name="wifi-off" size={18} color={c.t3} />
      <Text style={{ flex: 1, fontWeight: '500', fontSize: 13, color: c.t2 }}>Couldn’t reach the server.</Text>
      <Tap onPress={onRetry} style={{ paddingHorizontal: 14, paddingVertical: 8, borderRadius: 10, backgroundColor: c.s3 }}>
        <Text style={{ fontWeight: '600', fontSize: 13, color: c.t1 }}>Retry</Text>
      </Tap>
    </View>
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
        <Tap onPress={onCta} style={{ marginTop: 4, paddingHorizontal: 24, height: 48, borderRadius: 14, backgroundColor: c.accent, alignItems: 'center', justifyContent: 'center' }}>
          <Text style={{ fontWeight: '600', fontSize: 15, color: c.accentInk }}>{cta}</Text>
        </Tap>
      )}
    </View>
  );
}

// ---------------- LIBRARY ----------------
type LibSource = 'library' | 'printer';
type TypeFilter = 'all' | 'models' | 'sliced';
/** Sliced = ready-to-print G-code (or a 3MF already sliced for a model); otherwise a raw model. */
const isSlicedFile = (f: LibraryFile) => (f.file_type || '').includes('gcode') || !!f.sliced_for_model;

function Segmented<T extends string>({ value, options, onChange }: { value: T; options: [T, string][]; onChange: (v: T) => void }) {
  return (
    <View style={{ flexDirection: 'row', gap: 4, padding: 4, borderRadius: 12, backgroundColor: c.s2 }}>
      {options.map(([k, label]) => {
        const on = value === k;
        return (
          <Tap key={k} onPress={() => onChange(k)} style={{ flex: 1, height: 38, borderRadius: 9, backgroundColor: on ? c.s4 : 'transparent', alignItems: 'center', justifyContent: 'center' }}>
            <Text style={{ fontWeight: '600', fontSize: 13.5, color: on ? c.t1 : c.t2 }}>{label}</Text>
          </Tap>
        );
      })}
    </View>
  );
}

export function LibraryView({ client, camToken, printerId, onUpload, onPick }: { client: BambuddyClient; camToken: string | null; printerId: number; onUpload: () => void; onPick: (f: LibraryFile) => void }) {
  const [source, setSource] = useState<LibSource>('library');
  const [files, setFiles] = useState<LibraryFile[] | null>(null);
  const [loadFailed, setLoadFailed] = useState(false);
  const [refreshing, setRefreshing] = useState(false);
  const [filter, setFilter] = useState<TypeFilter>('all');
  const load = useCallback(() => {
    // A failed fetch is NOT an empty library — show a retry state instead of "No files yet".
    return client.listFiles().then((f) => { setFiles(f); setLoadFailed(false); }).catch(() => { setFiles((prev) => prev ?? []); setLoadFailed(true); });
  }, [client]);
  useEffect(() => { void load(); }, [load]);
  const refresh = useCallback(() => {
    setRefreshing(true);
    void load().finally(() => setRefreshing(false));
  }, [load]);

  // Printer onboard storage (SD card) browser.
  const [pList, setPList] = useState<PrinterFileList | null>(null);
  const [pPath, setPPath] = useState('/');
  const [pLoading, setPLoading] = useState(false);
  const loadPrinter = useCallback(
    (path: string) => {
      setPLoading(true);
      client
        .listPrinterFiles(printerId, path)
        .then((r) => { setPList(r); setPPath(r.path || path); })
        .catch(() => setPList({ path, files: [] }))
        .finally(() => setPLoading(false));
    },
    [client, printerId],
  );
  useEffect(() => { if (source === 'printer' && !pList) loadPrinter('/'); }, [source, pList, loadPrinter]);

  const confirmDelete = (f: LibraryFile) =>
    Alert.alert('Delete file?', `“${f.print_name || f.filename}” will be removed from the library. This can’t be undone.`, [
      { text: 'Cancel', style: 'cancel' },
      { text: 'Delete', style: 'destructive', onPress: () => client.deleteFile(f.id).then(load).catch((e) => Alert.alert('Couldn’t delete', String(e))) },
    ]);

  const counts: Record<TypeFilter, number> = {
    all: files?.length ?? 0,
    models: (files ?? []).filter((f) => !isSlicedFile(f)).length,
    sliced: (files ?? []).filter(isSlicedFile).length,
  };
  const shown = (files ?? []).filter((f) => (filter === 'all' ? true : filter === 'sliced' ? isSlicedFile(f) : !isSlicedFile(f)));
  const pSorted = pList ? [...pList.files].sort((a, b) => (a.is_directory === b.is_directory ? a.name.localeCompare(b.name) : a.is_directory ? -1 : 1)) : [];

  return (
    <Page
      title="Files"
      refreshControl={<RefreshControl refreshing={refreshing} onRefresh={refresh} tintColor={c.t3} />}
      right={
        source === 'library' ? (
          <Tap onPress={onUpload} style={{ width: 38, height: 38, borderRadius: 19, backgroundColor: c.accentDim, alignItems: 'center', justifyContent: 'center' }}>
            <Feather name="plus" size={22} color={c.accent} />
          </Tap>
        ) : null
      }>
      <View style={{ paddingHorizontal: 20, paddingTop: 14 }}>
        <Segmented value={source} options={[['library', 'Library'], ['printer', 'Printer']]} onChange={setSource} />
      </View>

      {source === 'library' ? (
        <>
          {loadFailed && <LoadFailed onRetry={() => void load()} />}
          {!!files?.length && (
            <View style={{ flexDirection: 'row', gap: 8, paddingHorizontal: 20, paddingTop: 14 }}>
              {(['all', 'models', 'sliced'] as TypeFilter[]).map((k) => {
                const on = filter === k;
                return (
                  <Tap key={k} onPress={() => setFilter(k)} style={{ paddingHorizontal: 13, height: 32, borderRadius: 10, backgroundColor: on ? c.accentDim : c.s2, flexDirection: 'row', alignItems: 'center', gap: 6 }}>
                    <Text style={{ fontWeight: '600', fontSize: 12, color: on ? c.accent : c.t2 }}>{k === 'all' ? 'All' : k === 'models' ? 'Models' : 'Sliced'}</Text>
                    <Text style={{ fontWeight: '600', fontSize: 11, color: on ? c.accent : c.t3, fontFamily: mono }}>{counts[k]}</Text>
                  </Tap>
                );
              })}
            </View>
          )}
          {files === null && !loadFailed && <ActivityIndicator color={c.accent} style={{ marginTop: 40 }} />}
          {files?.length === 0 && !loadFailed && <Empty icon="folder" title="No files yet" body="Upload an STL, 3MF, or sliced G-code and it'll show up here." cta="Upload a model" onCta={onUpload} />}
          {!!files?.length && (
            <>
              <View style={{ flexDirection: 'row', flexWrap: 'wrap', paddingHorizontal: 20, paddingTop: 14, gap: 13 }}>
                {shown.map((f) => {
                  const sliced = isSlicedFile(f);
                  return (
                    <Tap key={f.id} onPress={() => onPick(f)} onLongPress={() => confirmDelete(f)} style={{ width: '47%', flexGrow: 1 }}>
                      <View style={{ width: '100%', aspectRatio: 4 / 3, borderRadius: 14, overflow: 'hidden', backgroundColor: c.thumb, borderWidth: 1, borderColor: c.line, alignItems: 'center', justifyContent: 'center' }}>
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
                    </Tap>
                  );
                })}
              </View>
              <Text style={{ textAlign: 'center', marginTop: 16, fontWeight: '500', fontSize: 11, color: c.t3 }}>Tap to print · hold to delete</Text>
            </>
          )}
        </>
      ) : (
        <View style={{ paddingHorizontal: 20, paddingTop: 14 }}>
          <View style={{ flexDirection: 'row', alignItems: 'center', gap: 10, marginBottom: 12 }}>
            {pPath !== '/' && (
              <Tap onPress={() => loadPrinter(pPath.replace(/\/[^/]+\/?$/, '') || '/')} hitSlop={8} style={{ width: 32, height: 32, borderRadius: 9, backgroundColor: c.s2, alignItems: 'center', justifyContent: 'center' }}>
                <Feather name="arrow-up" size={16} color={c.t2} />
              </Tap>
            )}
            <Text numberOfLines={1} style={{ flex: 1, fontWeight: '600', fontSize: 12, color: c.t3, fontFamily: mono }}>printer:{pPath}</Text>
          </View>
          {pLoading && <ActivityIndicator color={c.accent} style={{ marginTop: 30 }} />}
          {!pLoading && pList && pSorted.length === 0 && <Empty icon="hard-drive" title="Empty folder" body="Nothing here on the printer's onboard storage." />}
          {!pLoading &&
            pSorted.map((pf) => (
              <Tap key={pf.path} onPress={() => pf.is_directory && loadPrinter(pf.path)} disabled={!pf.is_directory} style={{ flexDirection: 'row', alignItems: 'center', gap: 12, paddingVertical: 12, paddingHorizontal: 13, borderRadius: 13, backgroundColor: c.s1, borderWidth: 1, borderColor: c.line, marginBottom: 9 }}>
                <Feather name={pf.is_directory ? 'folder' : 'file'} size={18} color={pf.is_directory ? c.accent : c.t3} />
                <Text numberOfLines={1} style={{ flex: 1, fontWeight: '600', fontSize: 13.5, color: c.t1 }}>{pf.name}</Text>
                {pf.is_directory ? <Feather name="chevron-right" size={16} color={c.t3} /> : <Text style={{ fontWeight: '500', fontSize: 11, color: c.t3, fontFamily: mono }}>{fmtBytes(pf.size)}</Text>}
              </Tap>
            ))}
        </View>
      )}
    </Page>
  );
}

// ---------------- QUEUE ----------------
export function QueueView({ client, status, printerId, printers, onBrowse }: { client: BambuddyClient; status: PrinterStatus | null; printerId: number; printers: Printer[]; onBrowse: () => void }) {
  const [items, setItems] = useState<QueueItem[] | null>(null);
  const [loadFailed, setLoadFailed] = useState(false);
  const load = useCallback(
    () => client.listQueue().then((i) => { setItems(i); setLoadFailed(false); }).catch(() => { setItems((prev) => prev ?? []); setLoadFailed(true); }),
    [client],
  );
  useEffect(() => {
    load();
    const id = setInterval(load, 5000);
    return () => clearInterval(id);
  }, [load]);
  const vm = presentDashboard(status, Date.now());
  const pending = (items ?? []).filter((i) => i.status === 'pending' || i.status === 'queued');
  // The queue is backend-global; this tab shows the selected printer's lane (untargeted jobs included).
  const upcoming = pending.filter((i) => i.printer_id == null || i.printer_id === printerId);
  const elsewhere = pending.length - upcoming.length;
  const otherNames = [...new Set(pending.filter((i) => !upcoming.includes(i)).map((i) => i.printer_name || printers.find((p) => p.id === i.printer_id)?.name || 'another printer'))];
  const printing = vm.kind === 'live';

  return (
    <Page title="Queue">
      {items === null && !loadFailed && <ActivityIndicator color={c.accent} style={{ marginTop: 40 }} />}
      {loadFailed && <LoadFailed onRetry={() => void load()} />}
      {items?.length === 0 && !printing && !loadFailed && <Empty icon="list" title="Queue is empty" body="Files you send to print line up here. Start one from your library." cta="Browse files" onCta={onBrowse} />}
      {printing && (
        <>
          <Text style={{ fontWeight: '600', fontSize: 11, letterSpacing: 1, color: c.t3, fontFamily: mono, paddingHorizontal: 20, paddingTop: 18, paddingBottom: 11 }}>NOW PRINTING</Text>
          <View style={{ marginHorizontal: 20, padding: 16, borderRadius: 18, backgroundColor: c.s1, borderWidth: 1.5, borderColor: c.running }}>
            <Text numberOfLines={1} style={{ fontWeight: '600', fontSize: 14, color: c.t1 }}>{vm.heroSub || 'Current print'}</Text>
            <View style={{ marginTop: 5, flexDirection: 'row', alignItems: 'center', gap: 6 }}>
              <PulseDot color={c.running} size={6} period={2000} />
              <Text style={{ fontWeight: '600', fontSize: 11, color: c.running, fontFamily: mono }}>{vm.progressInt}% · {vm.etaText} left</Text>
            </View>
            <ExtrudeBar pct={vm.progressInt} color={c.running} height={5} />
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
                <Tap
                  onPress={() =>
                    Alert.alert(
                      'Remove from queue?',
                      `“${j.library_file_name || j.archive_name || `Job ${j.id}`}” won't print.`,
                      [
                        { text: 'Keep', style: 'cancel' },
                        { text: 'Remove', style: 'destructive', onPress: () => client.queueAction(j.id, 'cancel').then(load).catch((e) => Alert.alert('Couldn’t remove', String(e))) },
                      ],
                    )
                  }
                  hitSlop={8}
                  style={{ width: 30, height: 30, alignItems: 'center', justifyContent: 'center' }}>
                  <Feather name="x" size={16} color={c.t3} />
                </Tap>
              </View>
            ))}
          </View>
        </>
      )}
      {elsewhere > 0 && (
        <Text style={{ paddingHorizontal: 20, paddingTop: 18, fontWeight: '500', fontSize: 12, color: c.t3 }}>
          {elsewhere} more {elsewhere === 1 ? 'job' : 'jobs'} queued for {otherNames.join(', ')}.
        </Text>
      )}
    </Page>
  );
}

// ---------------- AMS ----------------
export function AmsView({ client, status, printerId, amsLabel }: { client: BambuddyClient; status: PrinterStatus | null; printerId: number; amsLabel: string }) {
  const vm = presentDashboard(status, Date.now());
  const unit = status?.ams?.[0];
  const trays = unit?.tray ?? [];
  const amsId = unit?.id ?? 0;
  const drying = (unit?.dry_status ?? 0) !== 0;
  // The WS delivers AMS temp (and sometimes humidity) as STRINGS — coerce before any number method.
  const amsHumidity = asNum(unit?.humidity);
  const amsTemp = asNum(unit?.temp);
  const [dryBusy, setDryBusy] = useState(false);

  const [assigns, setAssigns] = useState<SlotAssignment[] | null>(null);
  const loadInv = useCallback(() => {
    client.listAssignments(printerId).then(setAssigns).catch(() => setAssigns([]));
  }, [client, printerId]);
  useEffect(loadInv, [loadInv]);

  // Resolve the spool assigned to AMS slot `i`. Prefer tray_uuid (RFID), fall back to (ams_id,tray_id).
  const spoolForSlot = (i: number): SlotAssignment['spool'] | null => {
    if (!assigns?.length) return null;
    const uuid = trays[i]?.tray_uuid ?? null;
    const byUuid = uuid ? assigns.find((a) => a.spool?.tray_uuid === uuid) : undefined;
    const hit = byUuid ?? assigns.find((a) => a.ams_id === amsId && a.tray_id === i);
    return hit?.spool ?? null;
  };

  const toggleDrying = () => {
    setDryBusy(true);
    const done = () => setDryBusy(false);
    if (drying) {
      client.dryingStop(printerId, amsId).then(done).catch((e) => { done(); Alert.alert('Couldn’t stop drying', String(e)); });
    } else {
      Alert.alert('Dry filament?', 'Runs the AMS heater to dry the loaded spools (uses the filament’s default temperature and time).', [
        { text: 'Cancel', style: 'cancel', onPress: done },
        { text: 'Start drying', onPress: () => client.dryingStart(printerId, amsId).then(done).catch((e) => { done(); Alert.alert('Couldn’t start drying', String(e)); }) },
      ]);
    }
  };

  return (
    <Page title={amsLabel}>
      <View style={{ paddingHorizontal: 20, marginTop: 7, flexDirection: 'row', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
        <Text style={{ fontWeight: '500', fontSize: 13, color: c.t3 }}>
          {trays.filter((t) => t.tray_type).length} of {Math.max(trays.length, 4)} slots loaded
        </Text>
        {amsHumidity != null && amsHumidity > 0 && (
          <View style={{ flexDirection: 'row', alignItems: 'center', gap: 4, paddingHorizontal: 8, paddingVertical: 3, borderRadius: 8, backgroundColor: c.s2 }}>
            <Feather name="droplet" size={11} color={c.t3} />
            <Text style={{ fontWeight: '600', fontSize: 11, color: c.t2, fontFamily: mono }}>{Math.round(amsHumidity)}%</Text>
          </View>
        )}
        {amsTemp != null && amsTemp > 0 && (
          <View style={{ flexDirection: 'row', alignItems: 'center', gap: 4, paddingHorizontal: 8, paddingVertical: 3, borderRadius: 8, backgroundColor: c.s2 }}>
            <Feather name="thermometer" size={11} color={c.t3} />
            <Text style={{ fontWeight: '600', fontSize: 11, color: c.t2, fontFamily: mono }}>{amsTemp.toFixed(1)}°</Text>
          </View>
        )}
      </View>
      {status?.supports_drying && (
        <View style={{ marginHorizontal: 20, marginTop: 14, padding: 14, borderRadius: 16, backgroundColor: drying ? c.heatingDim : c.s1, borderWidth: 1, borderColor: drying ? c.heating : c.line, flexDirection: 'row', alignItems: 'center', gap: 12 }}>
          <Feather name="wind" size={17} color={drying ? c.heating : c.t2} />
          <View style={{ flex: 1 }}>
            <Text style={{ fontWeight: '600', fontSize: 14, color: c.t1 }}>{drying ? 'Drying filament…' : 'Filament drying'}</Text>
            <Text style={{ marginTop: 3, fontWeight: '500', fontSize: 11.5, color: c.t3 }}>
              {drying ? 'The AMS heater is running.' : 'Dry damp spools right in the AMS.'}
            </Text>
          </View>
          <Tap onPress={toggleDrying} disabled={dryBusy} style={{ paddingHorizontal: 15, paddingVertical: 9, borderRadius: 11, backgroundColor: drying ? c.s3 : c.accent, opacity: dryBusy ? 0.5 : 1 }}>
            <Text style={{ fontWeight: '600', fontSize: 13, color: drying ? c.t1 : c.accentInk }}>{drying ? 'Stop' : 'Dry'}</Text>
          </Tap>
        </View>
      )}
      <View style={{ paddingHorizontal: 20, paddingTop: 18, gap: 12 }}>
        {vm.ams.map((t, i) => {
          const spool = spoolForSlot(i);
          const swatch = spool ? (normColor(spool.rgba ?? undefined) ?? t.color) : t.color;
          const title = spool
            ? (spool.color_name ? `${spool.color_name} ${spool.material}` : spool.material)
            : (t.empty ? 'Empty slot' : t.label);
          const grams = spool ? spoolGramsRemaining(spool) : null;
          const sub = spool ? [spool.brand, spool.slicer_filament_name].filter(Boolean).join(' · ') || `Slot ${i + 1}` : `Slot ${i + 1}`;

          return (
            <View key={i} style={{ padding: 16, borderRadius: 18, backgroundColor: c.s1, borderWidth: t.active ? 1.5 : 1, borderColor: t.active ? c.accent : c.line, ...shadow1 }}>
              <View style={{ flexDirection: 'row', alignItems: 'center', gap: 14 }}>
                <View style={{ width: 46, height: 46, borderRadius: 12, backgroundColor: t.empty ? 'transparent' : swatch, borderWidth: t.empty ? 1 : 0, borderColor: c.line2, borderStyle: t.empty ? 'dashed' : 'solid' }} />
                <View style={{ flex: 1 }}>
                  <View style={{ flexDirection: 'row', alignItems: 'center', gap: 8 }}>
                    <Text numberOfLines={1} style={{ fontWeight: '700', fontSize: 16, color: c.t1, flexShrink: 1 }}>{title}</Text>
                    {t.active && (
                      <View style={{ paddingHorizontal: 7, paddingVertical: 2, borderRadius: 6, backgroundColor: c.accentDim }}>
                        <Text style={{ fontWeight: '600', fontSize: 8.5, letterSpacing: 0.5, color: c.accent, fontFamily: mono }}>ACTIVE</Text>
                      </View>
                    )}
                  </View>
                  <Text numberOfLines={1} style={{ marginTop: 5, fontWeight: '500', fontSize: 11, color: c.t3, fontFamily: mono }}>{sub}</Text>
                </View>
                {!t.empty && (
                  grams != null ? (
                    <View style={{ alignItems: 'flex-end' }}>
                      <Text style={{ fontWeight: '700', fontSize: 17, color: c.t1, fontFamily: mono }}>{Math.round(grams)}g</Text>
                      <Text style={{ marginTop: 2, fontWeight: '600', fontSize: 10, color: c.t3, fontFamily: mono }}>{t.pct}</Text>
                    </View>
                  ) : (
                    <Text style={{ fontWeight: '700', fontSize: 17, color: c.t1, fontFamily: mono }}>{t.pct}</Text>
                  )
                )}
              </View>
              {!t.empty ? (
                <View style={{ marginTop: 14, flexDirection: 'row', justifyContent: 'flex-end' }}>
                  <Tap onPress={() => client.amsUnload(printerId).catch((e) => Alert.alert('Unload failed', String(e)))} style={{ paddingHorizontal: 16, paddingVertical: 8, borderRadius: 10, backgroundColor: c.s3 }}>
                    <Text style={{ fontWeight: '600', fontSize: 12, color: c.t1 }}>Unload</Text>
                  </Tap>
                </View>
              ) : (
                <Tap onPress={() => client.amsLoad(printerId, i).catch((e) => Alert.alert('Load failed', String(e)))} style={{ marginTop: 14, height: 44, borderRadius: 12, borderWidth: 1, borderColor: c.line2, alignItems: 'center', justifyContent: 'center' }}>
                  <Text style={{ fontWeight: '600', fontSize: 13, color: c.accent }}>Load filament</Text>
                </Tap>
              )}
            </View>
          );
        })}
      </View>
      <MaintenanceSection client={client} printerId={printerId} />
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
  // While a toggle command is settling, ignore poll results — HA takes a few seconds to reflect
  // the new state and the stale poll would visibly bounce the switch back.
  const pendingUntil = useRef(0);
  useEffect(() => {
    if (!plug) return;
    const poll = () =>
      client.plugStatus(plug.id).then((s) => {
        if (Date.now() < pendingUntil.current) return;
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

  const applyPlug = (next: boolean) => {
    if (!plug) return;
    setOn(next);
    pendingUntil.current = Date.now() + 8000;
    client.plugControl(plug.id, next).catch((e) => {
      pendingUntil.current = 0;
      setOn(!next);
      Alert.alert('Plug command failed', String(e));
    });
  };
  const toggle = () => {
    if (!plug) return;
    if (on) {
      // Switching OFF cuts power to the printer — confirm so an accidental tap can't kill a print.
      Alert.alert('Switch off the printer?', 'This cuts power at the smart plug. If a print is running, it will stop.', [
        { text: 'Cancel', style: 'cancel' },
        { text: 'Switch off', style: 'destructive', onPress: () => applyPlug(false) },
      ]);
    } else {
      applyPlug(true); // turning on is safe — no confirmation
    }
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
        <Breathe active={on && reachable} color={c.accent} grow={0.18} maxOpacity={0.5} style={{ borderRadius: 65 }}>
          <Tap
            onPress={toggle}
            disabled={!reachable || plug === undefined}
            style={{ width: 130, height: 130, borderRadius: 65, backgroundColor: on ? c.accent : c.s3, alignItems: 'center', justifyContent: 'center', opacity: reachable ? 1 : 0.4 }}>
            <Feather name="power" size={48} color={on ? c.accentInk : c.t2} />
          </Tap>
        </Breathe>
        <Text style={{ marginTop: 20, fontWeight: '700', fontSize: 19, color: c.t1, letterSpacing: -0.3 }}>{on ? 'Powered on' : 'Powered off'}</Text>
        <View style={{ marginTop: 8, flexDirection: 'row', alignItems: 'center', gap: 7 }}>
          {reachable ? <PulseDot color={c.running} size={7} period={2000} /> : <View style={{ width: 7, height: 7, borderRadius: 4, backgroundColor: c.idle }} />}
          <Text style={{ fontWeight: '500', fontSize: 12, color: c.t3 }}>{reachable ? 'Plug reachable' : 'Plug unreachable'}</Text>
        </View>
        <Text style={{ marginTop: 6, fontWeight: '500', fontSize: 12, color: c.t3 }}>Tap to toggle the printer's smart plug</Text>
      </View>
      <View style={{ marginHorizontal: 20, marginTop: 14, flexDirection: 'row', gap: 12 }}>
        <View style={{ flex: 1, padding: 16, borderRadius: 18, backgroundColor: c.s1, borderWidth: 1, borderColor: c.line }}>
          <View style={{ flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' }}>
            <Text style={{ fontWeight: '600', fontSize: 10, letterSpacing: 1, color: c.t3, fontFamily: mono }}>DRAWING NOW</Text>
            {watts != null && watts > 5 && <View style={{ width: 5, height: 5, borderRadius: 3, backgroundColor: c.accent }}><Spark color={c.accent} count={6} size={3} spread={14} /></View>}
          </View>
          <View style={{ marginTop: 9, flexDirection: 'row', alignItems: 'baseline', gap: 4 }}>
            {watts == null ? (
              <Text style={{ fontWeight: '700', fontSize: 28, color: c.t1, letterSpacing: -1 }}>—</Text>
            ) : (
              <RollingNumber value={Math.round(watts)} fontSize={28} weight="700" color={c.t1} letterSpacing={-1} />
            )}
            <Text style={{ fontWeight: '600', fontSize: 13, color: c.t3 }}>W</Text>
          </View>
        </View>
        <View style={{ flex: 1, padding: 16, borderRadius: 18, backgroundColor: c.s1, borderWidth: 1, borderColor: c.line }}>
          <Text style={{ fontWeight: '600', fontSize: 10, letterSpacing: 1, color: c.t3, fontFamily: mono }}>TODAY</Text>
          <View style={{ marginTop: 9, flexDirection: 'row', alignItems: 'baseline', gap: 4 }}>
            {kwh == null ? (
              <Text style={{ fontWeight: '700', fontSize: 28, color: c.t1, letterSpacing: -1 }}>—</Text>
            ) : (
              <RollingNumber value={kwh.toFixed(2)} fontSize={28} weight="700" color={c.t1} letterSpacing={-1} />
            )}
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
            <PulseDot color={c.running} size={7} period={2000} />
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
        <Toggle value={autoOff} onChange={setAutoOff} />
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
// Computed per call — `c` tokens are live-mutated on theme switch, so a module-level table would
// freeze the dark palette.
function statusMeta(s: string): { label: string; color: string; dim: string } {
  if (s === 'completed') return { label: 'Done', color: c.running, dim: c.runningDim };
  if (s === 'failed') return { label: 'Failed', color: c.error, dim: c.errorDim };
  if (s === 'cancelled') return { label: 'Canceled', color: c.idle, dim: c.idleDim };
  return { label: s ? s[0].toUpperCase() + s.slice(1) : 'Unknown', color: c.idle, dim: c.idleDim };
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
        <RollingNumber value={value} fontSize={25} weight="700" color={accent ? c.accent : c.t1} letterSpacing={-1} />
        {unit ? <Text style={{ fontWeight: '600', fontSize: 12, color: c.t3 }}>{unit}</Text> : null}
      </View>
    </View>
  );
}

/** Animated circular success gauge (kit ProgressRing). */
function SuccessRing({ pct }: { pct: number }) {
  return (
    <ProgressRing size={76} stroke={7} progress={pct} color={c.accent}>
      <View style={{ alignItems: 'center' }}>
        <RollingNumber value={pct} fontSize={20} weight="700" color={c.t1} letterSpacing={-0.5} />
        <Text style={{ fontWeight: '600', fontSize: 8, letterSpacing: 0.5, color: c.t3, fontFamily: mono, marginTop: -2 }}>SUCCESS</Text>
      </View>
    </ProgressRing>
  );
}

function StatsBanner({ stats, sym }: { stats: ArchiveStats; sym: string }) {
  const total = stats.total_prints || 0;
  const success = total > 0 ? Math.round((stats.successful_prints / total) * 100) : 0;
  const grams = stats.total_filament_grams || 0;
  const filamentVal = grams >= 1000 ? (grams / 1000).toFixed(2) : Math.round(grams).toString();
  const filamentUnit = grams >= 1000 ? 'kg' : 'g';
  const showCost = stats.total_cost > 0;
  const showEnergy = stats.total_energy_kwh > 0;

  return (
    <FadeRise style={{ marginHorizontal: 20, marginTop: 18 }}>
      <View style={{ padding: 20, borderRadius: 22, backgroundColor: c.s1, borderWidth: 1, borderColor: c.line, ...shadow1 }}>
        <View style={{ flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' }}>
          <View>
            <Text style={{ fontWeight: '600', fontSize: 10, letterSpacing: 1.2, color: c.t3, fontFamily: mono }}>LIFETIME PRINTS</Text>
            <RollingNumber value={total} fontSize={46} weight="700" color={c.t1} letterSpacing={-2} style={{ marginTop: 7 }} />
            <View style={{ flexDirection: 'row', alignItems: 'center', gap: 7, marginTop: 4 }}>
              <PulseDot color={c.running} size={7} period={2400} />
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
        {showCost && <StatBlock label="EST. COST" value={fmtMoney(sym, stats.total_cost)} accent />}
        <StatBlock label="ENERGY" value={showEnergy ? stats.total_energy_kwh.toFixed(2) : '—'} unit={showEnergy ? 'kWh' : undefined} />
      </View>
      {stats.energy_data_warming_up && (
        <Text style={{ marginTop: 8, marginLeft: 4, fontWeight: '500', fontSize: 11, color: c.t3 }}>
          Energy data is warming up — costs appear after the next full job.
        </Text>
      )}
    </FadeRise>
  );
}

function HistoryRow({ entry, client, camToken, sym, onReprint }: { entry: PrintLogEntry; client: BambuddyClient; camToken: string | null; sym: string; onReprint?: (e: PrintLogEntry) => void }) {
  const meta = statusMeta(entry.status);
  const swatch = firstColor(entry.filament_color);
  const thumb = client.printLogThumbUrl(entry.id, camToken, entry.thumbnail_path);
  const mins = entry.duration_seconds != null ? entry.duration_seconds / 60 : null;

  const facts: string[] = [];
  if (mins != null) facts.push(fmtDuration(mins));
  if (entry.filament_used_grams != null) facts.push(`${Math.round(entry.filament_used_grams)}g`);
  if (entry.energy_kwh != null) facts.push(`${entry.energy_kwh.toFixed(2)} kWh`);
  const cost = entry.cost ?? entry.energy_cost;
  const canReprint = !!onReprint && entry.archive_id != null;

  return (
    <Tap onPress={canReprint ? () => onReprint!(entry) : undefined} disabled={!canReprint} style={{ flexDirection: 'row', gap: 13, padding: 12, borderRadius: 16, backgroundColor: c.s1, borderWidth: 1, borderColor: c.line }}>
      <View style={{ width: 58, height: 58, borderRadius: 12, overflow: 'hidden', backgroundColor: c.thumb, borderWidth: 1, borderColor: c.line, alignItems: 'center', justifyContent: 'center' }}>
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
            <Text style={{ fontWeight: '600', fontSize: 11, color: c.accent, fontFamily: mono }}>· {fmtMoney(sym, cost)}</Text>
          )}
        </View>
        {!!entry.printer_name && (
          <Text style={{ marginTop: 4, fontWeight: '500', fontSize: 10, color: c.t3, fontFamily: mono }}>{entry.printer_name}</Text>
        )}
      </View>
    </Tap>
  );
}

export function HistoryView({ client, camToken, printerId }: { client: BambuddyClient; camToken: string | null; printerId: number }) {
  const [entries, setEntries] = useState<PrintLogEntry[] | null>(null);
  const [stats, setStats] = useState<ArchiveStats | null>(null);
  const [loadFailed, setLoadFailed] = useState(false);
  const [settings, setSettings] = useState<AppSettings | null>(null);
  const sym = currencySymbol(settings?.currency);

  const load = useCallback(() => {
    client.getPrintLog(50).then((p) => { setEntries(p.items); setLoadFailed(false); }).catch(() => { setEntries((prev) => prev ?? []); setLoadFailed(true); });
    client.getArchiveStats().then(setStats).catch(() => setStats(null));
  }, [client]);
  useEffect(() => {
    load();
    client.getSettings().then(setSettings).catch(() => setSettings(null));
    const id = setInterval(load, 15000);
    return () => clearInterval(id);
  }, [load, client]);

  const reprint = (e: PrintLogEntry) => {
    if (e.archive_id == null) return;
    Alert.alert('Print again?', `“${e.print_name || `Print ${e.id}`}” goes back into the queue.`, [
      { text: 'Cancel', style: 'cancel' },
      {
        text: 'Print again',
        onPress: () =>
          client.reprint(e.archive_id!, printerId).then(() => Alert.alert('Queued', 'The job is back in the queue.')).catch((err) => Alert.alert('Couldn’t reprint', String(err))),
      },
    ]);
  };

  return (
    <Page title="History">
      {entries === null && !loadFailed && <ActivityIndicator color={c.accent} style={{ marginTop: 40 }} />}
      {loadFailed && <LoadFailed onRetry={load} />}
      {entries !== null && stats && stats.total_prints > 0 && <StatsBanner stats={stats} sym={sym} />}
      {entries?.length === 0 && !loadFailed && (
        <Empty icon="clock" title="No prints yet" body="Once you finish a print it's archived here with its stats, filament, and cost." />
      )}
      {!!entries?.length && (
        <>
          <Text style={{ fontWeight: '600', fontSize: 11, letterSpacing: 1, color: c.t3, fontFamily: mono, paddingHorizontal: 20, paddingTop: 26, paddingBottom: 12 }}>RECENT PRINTS · TAP TO REPRINT</Text>
          <View style={{ paddingHorizontal: 20, gap: 10 }}>
            {entries.map((e) => (
              <HistoryRow key={e.id} entry={e} client={client} camToken={camToken} sym={sym} onReprint={reprint} />
            ))}
          </View>
        </>
      )}
    </Page>
  );
}

// ---------------- MAINTENANCE ----------------
// Lucide icon name (from API) -> closest Feather glyph.
const MAINT_ICON: Record<string, keyof typeof Feather.glyphMap> = {
  Droplet: 'droplet', Sparkles: 'star', Flame: 'thermometer', Ruler: 'sliders',
  Square: 'square', Cable: 'git-commit', Wrench: 'tool', Tool: 'tool',
};
function maintIcon(name: string | null): keyof typeof Feather.glyphMap {
  return (name && MAINT_ICON[name]) || 'tool';
}
function maintStatus(it: MaintenanceItem): { text: string; color: string; urgent: boolean } {
  if (it.is_due) return { text: 'Due now', color: c.error, urgent: true };
  if (it.is_warning) return { text: 'Soon', color: c.heating, urgent: true };
  const h = it.hours_until_due;
  const txt = h >= 1 ? `in ${Math.round(h)} h` : `in ${Math.max(0, Math.round(h * 60))} min`;
  return { text: txt, color: c.t3, urgent: false };
}
function fmtLastPerformed(iso: string | null): string {
  if (!iso) return 'Never performed';
  const d = new Date(iso);
  if (isNaN(d.getTime())) return 'Performed';
  const days = Math.floor((Date.now() - d.getTime()) / 86400000);
  if (days <= 0) return 'Done today';
  if (days === 1) return 'Done yesterday';
  if (days < 30) return `Done ${days} days ago`;
  return `Done ${d.toLocaleDateString()}`;
}

export function MaintenanceSection({ client, printerId }: { client: BambuddyClient; printerId: number }) {
  const [data, setData] = useState<MaintenancePrinter | null | undefined>(undefined);
  const [busy, setBusy] = useState<number | null>(null);

  const load = useCallback(
    () => client.getMaintenance(printerId).then((d) => setData(d)).catch(() => setData(null)),
    [client, printerId],
  );
  useEffect(() => { load(); }, [load]);

  const markDone = (it: MaintenanceItem) => {
    Alert.alert(
      `Mark "${it.maintenance_type_name}" as done?`,
      `This resets its counter. Next reminder in ${Math.round(it.interval_hours)} h of printing.`,
      [
        { text: 'Cancel', style: 'cancel' },
        {
          text: 'Mark done',
          onPress: () => {
            setBusy(it.id);
            client.performMaintenance(it.id).then(load).catch((e) => Alert.alert('Couldn’t update', String(e))).finally(() => setBusy(null));
          },
        },
      ],
    );
  };

  const items = (data?.maintenance_items ?? []).filter((i) => i.enabled);
  items.sort((a, b) => Number(b.is_due) - Number(a.is_due) || Number(b.is_warning) - Number(a.is_warning) || a.hours_until_due - b.hours_until_due);

  return (
    <View>
      <View style={{ flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', paddingHorizontal: 20, paddingTop: 26, paddingBottom: 12 }}>
        <Text style={{ fontWeight: '600', fontSize: 11, letterSpacing: 1.2, color: c.t3, fontFamily: mono }}>MAINTENANCE</Text>
        {!!data && <Text style={{ fontWeight: '600', fontSize: 11, color: c.t3, fontFamily: mono }}>{data.total_print_hours.toFixed(1)} h printed</Text>}
      </View>

      {data === undefined && <ActivityIndicator color={c.accent} style={{ marginTop: 16 }} />}
      {data === null && (
        <View style={{ marginHorizontal: 20, padding: 16, borderRadius: 18, backgroundColor: c.s1, borderWidth: 1, borderColor: c.line }}>
          <Text style={{ fontWeight: '500', fontSize: 13, color: c.t3 }}>Couldn’t load maintenance.</Text>
        </View>
      )}
      {data && items.length === 0 && (
        <View style={{ marginHorizontal: 20, padding: 18, borderRadius: 18, backgroundColor: c.s1, borderWidth: 1, borderColor: c.line, alignItems: 'center', gap: 8 }}>
          <Feather name="tool" size={22} color={c.t3} />
          <Text style={{ fontWeight: '600', fontSize: 14, color: c.t1 }}>No reminders set up</Text>
          <Text style={{ fontWeight: '500', fontSize: 12, lineHeight: 17, color: c.t3, textAlign: 'center', maxWidth: 250 }}>Add service intervals in Bambuddy (Settings → Maintenance) and they’ll track here as you print.</Text>
        </View>
      )}

      <View style={{ paddingHorizontal: 20, gap: 11 }}>
        {items.map((it) => {
          const st = maintStatus(it);
          const pct = Math.max(0, Math.min(100, (it.hours_since_maintenance / it.interval_hours) * 100));
          return (
            <View key={it.id} style={{ padding: 16, borderRadius: 18, backgroundColor: c.s1, borderWidth: st.urgent ? 1.5 : 1, borderColor: st.urgent ? st.color : c.line, ...shadow1 }}>
              <View style={{ flexDirection: 'row', alignItems: 'center', gap: 13 }}>
                <View style={{ width: 42, height: 42, borderRadius: 12, backgroundColor: st.urgent ? c.s3 : c.s2, alignItems: 'center', justifyContent: 'center' }}>
                  <Feather name={maintIcon(it.maintenance_type_icon)} size={20} color={st.urgent ? st.color : c.t2} />
                </View>
                <View style={{ flex: 1 }}>
                  <Text style={{ fontWeight: '700', fontSize: 15, color: c.t1 }}>{it.maintenance_type_name}</Text>
                  <Text style={{ marginTop: 4, fontWeight: '500', fontSize: 11, color: c.t3, fontFamily: mono }}>{fmtLastPerformed(it.last_performed_at)}</Text>
                </View>
                <View style={{ alignItems: 'flex-end', gap: 3 }}>
                  {st.urgent ? (
                    <View style={{ paddingHorizontal: 9, paddingVertical: 4, borderRadius: 7, backgroundColor: st.color === c.error ? c.errorDim : c.heatingDim }}>
                      <Text style={{ fontWeight: '700', fontSize: 10.5, letterSpacing: 0.4, color: st.color, fontFamily: mono }}>{st.text.toUpperCase()}</Text>
                    </View>
                  ) : (
                    <Text style={{ fontWeight: '600', fontSize: 12, color: c.t2, fontFamily: mono }}>{st.text}</Text>
                  )}
                  <Text style={{ fontWeight: '500', fontSize: 10, color: c.t3, fontFamily: mono }}>every {Math.round(it.interval_hours)} h</Text>
                </View>
              </View>
              <View style={{ marginTop: 13, height: 4, borderRadius: 2, backgroundColor: c.s3, overflow: 'hidden' }}>
                <View style={{ height: '100%', width: `${pct}%`, borderRadius: 2, backgroundColor: st.urgent ? st.color : c.accent }} />
              </View>
              <View style={{ marginTop: 13, flexDirection: 'row', justifyContent: 'flex-end' }}>
                <Tap onPress={() => markDone(it)} disabled={busy === it.id} style={[{ flexDirection: 'row', alignItems: 'center', gap: 7, paddingHorizontal: 15, paddingVertical: 9, borderRadius: 11, backgroundColor: st.urgent ? c.accent : c.s3 }, busy === it.id ? { opacity: 0.5 } : null]}>
                  {busy === it.id ? <ActivityIndicator size="small" color={st.urgent ? c.accentInk : c.t1} /> : <Feather name="check" size={14} color={st.urgent ? c.accentInk : c.t1} />}
                  <Text style={{ fontWeight: '600', fontSize: 13, color: st.urgent ? c.accentInk : c.t1 }}>Mark done</Text>
                </Tap>
              </View>
            </View>
          );
        })}
      </View>
    </View>
  );
}
