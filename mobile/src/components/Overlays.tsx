import React, { useEffect, useState } from 'react';
import { View, Text, Pressable, ScrollView, ActivityIndicator, Alert, TextInput } from 'react-native';
import { Image } from 'expo-image';
import { WebView } from 'react-native-webview';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { Feather } from '@expo/vector-icons';
import * as DocumentPicker from 'expo-document-picker';
import { c, mono, shadow1 } from '@/theme';
import type { BambuddyClient } from '@/api/bambuddyClient';
import type { LibraryFile, PrinterStatus, MakerWorldResolved, MWInstance } from '@/api/types';
import { presentDashboard, normColor } from '@/dashboard/present';

// ---------------- CAMERA FULLSCREEN ----------------
// HTML host for the MJPEG <img>. WebKit decodes multipart/x-mixed-replace natively (expo-image /
// RN <Image> cannot). onerror/onload post back so RN can show a diagnostic fallback.
function mjpegHtml(streamUrl: string): string {
  return `<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
<style>html,body{margin:0;height:100%;background:#060708;overflow:hidden}
img{position:absolute;inset:0;width:100%;height:100%;object-fit:contain;background:#060708}</style></head>
<body><img id="cam" src="${streamUrl}"
 onerror="window.ReactNativeWebView&&window.ReactNativeWebView.postMessage('error')"
 onload="window.ReactNativeWebView&&window.ReactNativeWebView.postMessage('frame')"></body></html>`;
}

export function CameraOverlay({ client, printerId, streamUrl, status, onClose, onRefresh }: { client: BambuddyClient; printerId: number; streamUrl: string | null; status: PrinterStatus | null; onClose: () => void; onRefresh: () => void }) {
  const insets = useSafeAreaInsets();
  const vm = presentDashboard(status, Date.now());
  const [streamErr, setStreamErr] = useState(false);
  const [diag, setDiag] = useState<string | null>(null);
  const [reloadKey, setReloadKey] = useState(0);

  // When the stream <img> errors, fetch the structured diagnostic so the user sees WHY.
  useEffect(() => {
    if (!streamErr) return;
    let alive = true;
    client.diagnoseCamera(printerId)
      .then((d) => {
        if (!alive) return;
        setDiag(
          d.summary_code === 'printer_unreachable'
            ? `Server can't reach the camera (port ${d.port}). On the printer, enable LAN Mode Live View — and confirm it's on the same network.`
            : `Camera unavailable (${d.stages?.find((s) => s.status === 'failed')?.code ?? d.summary_code}).`,
        );
      })
      .catch(() => alive && setDiag('Camera unavailable.'));
    return () => { alive = false; };
  }, [streamErr, client, printerId]);

  const retry = () => { setStreamErr(false); setDiag(null); onRefresh(); setReloadKey((k) => k + 1); };
  const live = !!streamUrl && !streamErr;

  return (
    <View style={{ position: 'absolute', inset: 0, backgroundColor: '#060708', zIndex: 70 } as any}>
      {live ? (
        <WebView
          key={`${streamUrl}-${reloadKey}`}
          source={{ html: mjpegHtml(streamUrl!) }}
          originWhitelist={['*']}
          style={{ flex: 1, backgroundColor: '#060708' }}
          scrollEnabled={false}
          javaScriptEnabled
          mediaPlaybackRequiresUserAction={false}
          allowsInlineMediaPlayback
          onMessage={(e) => { if (e.nativeEvent.data === 'error') setStreamErr(true); }}
        />
      ) : (
        <View style={{ flex: 1, alignItems: 'center', justifyContent: 'center', paddingHorizontal: 36 }}>
          <Feather name="video-off" size={30} color="#3a4046" />
          <Text style={{ marginTop: 14, fontFamily: mono, color: '#3a4046', letterSpacing: 2, fontSize: 11 }}>CHAMBER · NO SIGNAL</Text>
          {diag && <Text style={{ marginTop: 12, color: '#6b7177', fontSize: 13, lineHeight: 19, textAlign: 'center' }}>{diag}</Text>}
          <Pressable onPress={retry} style={{ marginTop: 18, paddingHorizontal: 18, height: 42, borderRadius: 12, backgroundColor: 'rgba(255,255,255,0.08)', alignItems: 'center', justifyContent: 'center' }}>
            <Text style={{ color: '#fff', fontWeight: '600', fontSize: 14 }}>Retry</Text>
          </Pressable>
        </View>
      )}
      <View style={{ position: 'absolute', top: 0, left: 0, right: 0, paddingTop: insets.top + 10, paddingHorizontal: 16, paddingBottom: 16, flexDirection: 'row', alignItems: 'center', gap: 11 }}>
        <Pressable onPress={onClose} style={{ width: 40, height: 40, borderRadius: 20, backgroundColor: 'rgba(22,24,27,0.6)', alignItems: 'center', justifyContent: 'center' }}>
          <Feather name="chevron-down" size={22} color="#fff" />
        </Pressable>
        <View style={{ flex: 1, flexDirection: 'row', alignItems: 'center', gap: 8, paddingHorizontal: 13, paddingVertical: 10, borderRadius: 13, backgroundColor: 'rgba(22,24,27,0.55)' }}>
          <View style={{ width: 7, height: 7, borderRadius: 4, backgroundColor: vm.stateColor }} />
          <Text style={{ fontWeight: '600', fontSize: 13, color: '#fff' }}>{vm.stateLabel}</Text>
          <Text style={{ marginLeft: 'auto', fontWeight: '600', fontSize: 12, color: 'rgba(255,255,255,0.5)', fontFamily: mono }}>{vm.progressInt}% · L{vm.layer}</Text>
        </View>
        <Pressable onPress={retry} style={{ width: 40, height: 40, borderRadius: 20, backgroundColor: 'rgba(22,24,27,0.6)', alignItems: 'center', justifyContent: 'center' }}>
          <Feather name="refresh-cw" size={18} color="#fff" />
        </Pressable>
      </View>
      {live && (
        <View style={{ position: 'absolute', bottom: 0, left: 0, right: 0, paddingBottom: insets.bottom + 24, paddingHorizontal: 18, flexDirection: 'row', alignItems: 'center', gap: 6 }}>
          <View style={{ flexDirection: 'row', alignItems: 'center', gap: 6, paddingHorizontal: 11, paddingVertical: 7, borderRadius: 9, backgroundColor: 'rgba(22,24,27,0.55)' }}>
            <View style={{ width: 6, height: 6, borderRadius: 3, backgroundColor: c.running }} />
            <Text style={{ fontWeight: '600', fontSize: 10, letterSpacing: 0.5, color: '#fff' }}>LIVE</Text>
          </View>
        </View>
      )}
    </View>
  );
}

// ---------------- UPLOAD SHEET ----------------
export function UploadSheet({ client, onClose, onUploaded }: { client: BambuddyClient; onClose: () => void; onUploaded: () => void }) {
  const insets = useSafeAreaInsets();
  const [busy, setBusy] = useState(false);
  const [pct, setPct] = useState(0);
  const [showMW, setShowMW] = useState(false);
  const pick = async () => {
    try {
      const res = await DocumentPicker.getDocumentAsync({ copyToCacheDirectory: true });
      if (res.canceled || !res.assets?.[0]) return;
      const a = res.assets[0];
      setBusy(true);
      setPct(0);
      await client.uploadFile(a.uri, a.name, (f) => setPct(Math.round(f * 100)));
      setBusy(false);
      onUploaded();
      onClose();
    } catch (e) {
      setBusy(false);
      Alert.alert('Upload failed', String(e));
    }
  };

  if (showMW) {
    return <MakerWorldSheet client={client} onClose={onClose} onBack={() => setShowMW(false)} onImported={onUploaded} />;
  }

  return (
    <Pressable onPress={onClose} style={{ position: 'absolute', inset: 0, backgroundColor: 'rgba(0,0,0,0.5)', justifyContent: 'flex-end', zIndex: 72 } as any}>
      <Pressable onPress={() => {}} style={{ backgroundColor: c.sheet, borderTopLeftRadius: 26, borderTopRightRadius: 26, paddingHorizontal: 14, paddingTop: 10, paddingBottom: insets.bottom + 20, ...shadow1 }}>
        <View style={{ width: 38, height: 5, borderRadius: 3, backgroundColor: c.line2, alignSelf: 'center', marginBottom: 16 }} />
        <Text style={{ fontWeight: '700', fontSize: 17, color: c.t1, textAlign: 'center', marginBottom: 14 }}>Add a file</Text>
        <Pressable onPress={pick} disabled={busy} style={({ pressed }) => [{ flexDirection: 'row', alignItems: 'center', gap: 13, padding: 14, borderRadius: 14, backgroundColor: c.s2 }, pressed && { opacity: 0.7 }]}>
          <View style={{ width: 36, height: 36, borderRadius: 10, backgroundColor: c.accentDim, alignItems: 'center', justifyContent: 'center' }}>
            <Feather name="folder" size={19} color={c.accent} />
          </View>
          <Text style={{ flex: 1, fontWeight: '600', fontSize: 15, color: c.t1 }}>{busy ? `Uploading… ${pct}%` : 'From Files'}</Text>
          {busy ? <ActivityIndicator color={c.t3} /> : <Feather name="chevron-right" size={16} color={c.t3} />}
        </Pressable>
        <Pressable onPress={() => setShowMW(true)} disabled={busy} style={({ pressed }) => [{ flexDirection: 'row', alignItems: 'center', gap: 13, padding: 14, borderRadius: 14, backgroundColor: c.s2, marginTop: 10 }, pressed && { opacity: 0.7 }]}>
          <View style={{ width: 36, height: 36, borderRadius: 10, backgroundColor: c.accentDim, alignItems: 'center', justifyContent: 'center' }}>
            <Feather name="globe" size={19} color={c.accent} />
          </View>
          <View style={{ flex: 1 }}>
            <Text style={{ fontWeight: '600', fontSize: 15, color: c.t1 }}>From MakerWorld</Text>
            <Text style={{ marginTop: 2, fontWeight: '500', fontSize: 11.5, color: c.t3 }}>Paste a model link</Text>
          </View>
          <Feather name="chevron-right" size={16} color={c.t3} />
        </Pressable>
        <Pressable onPress={onClose} style={({ pressed }) => [{ marginTop: 14, height: 50, borderRadius: 14, backgroundColor: c.s3, alignItems: 'center', justifyContent: 'center' }, pressed && { opacity: 0.7 }]}>
          <Text style={{ fontWeight: '600', fontSize: 16, color: c.t1 }}>Cancel</Text>
        </Pressable>
      </Pressable>
    </Pressable>
  );
}

// ---------------- MAKERWORLD IMPORT SHEET ----------------
function instTime(i: MWInstance): number | null {
  return i.prediction ?? i.extention?.modelInfo?.plates?.[0]?.prediction ?? null;
}
function instWeight(i: MWInstance): number | null {
  return i.weight ?? i.extention?.modelInfo?.plates?.[0]?.weight ?? null;
}

export function MakerWorldSheet({ client, onClose, onBack, onImported }: { client: BambuddyClient; onClose: () => void; onBack: () => void; onImported: () => void }) {
  const insets = useSafeAreaInsets();
  const [url, setUrl] = useState('');
  const [canDownload, setCanDownload] = useState<boolean | null>(null);
  const [resolving, setResolving] = useState(false);
  const [resolved, setResolved] = useState<MakerWorldResolved | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [picked, setPicked] = useState<MWInstance | null>(null);
  const [importing, setImporting] = useState(false);

  useEffect(() => {
    let alive = true;
    client.makerWorldStatus().then((s) => alive && setCanDownload(s.can_download)).catch(() => alive && setCanDownload(false));
    return () => { alive = false; };
  }, [client]);

  const resolve = async () => {
    const u = url.trim();
    if (!u) return;
    setResolving(true); setErr(null); setResolved(null); setPicked(null);
    try {
      const r = await client.resolveMakerWorld(u);
      setResolved(r);
      setPicked(r.instances?.[0] ?? null);
    } catch (e) {
      const m = String((e as Error)?.message ?? e);
      const detail = m.match(/\{"detail":"([^"]+)"\}/)?.[1];
      setErr(detail ?? 'Couldn’t resolve that link. Paste a makerworld.com model URL.');
    } finally {
      setResolving(false);
    }
  };

  const doImport = async () => {
    if (!resolved) return;
    setImporting(true);
    try {
      const res = await client.importMakerWorld({
        model_id: resolved.model_id,
        profile_id: picked?.profileId ?? resolved.profile_id ?? undefined,
        instance_id: picked?.id ?? undefined,
      });
      onImported();
      onClose();
      Alert.alert(res.was_existing ? 'Already in library' : 'Added to library', res.filename);
    } catch (e) {
      setImporting(false);
      Alert.alert('Import failed', String((e as Error)?.message ?? e));
    }
  };

  const design = resolved?.design;
  const alreadyImported = !!resolved?.already_imported_library_ids?.length;
  const L = ({ children }: { children: React.ReactNode }) => (
    <Text style={{ fontWeight: '600', fontSize: 11, letterSpacing: 1, color: c.t3, fontFamily: mono, marginBottom: 10 }}>{children}</Text>
  );

  return (
    <Pressable onPress={onClose} style={{ position: 'absolute', inset: 0, backgroundColor: 'rgba(0,0,0,0.5)', justifyContent: 'flex-end', zIndex: 72 } as any}>
      <Pressable onPress={() => {}} style={{ maxHeight: '88%', backgroundColor: c.sheet, borderTopLeftRadius: 26, borderTopRightRadius: 26, paddingHorizontal: 14, paddingTop: 10, paddingBottom: insets.bottom + 18, ...shadow1 }}>
        <View style={{ width: 38, height: 5, borderRadius: 3, backgroundColor: c.line2, alignSelf: 'center', marginBottom: 12 }} />
        <View style={{ flexDirection: 'row', alignItems: 'center', marginBottom: 14 }}>
          <Pressable onPress={onBack} hitSlop={10} style={{ width: 40 }}><Feather name="chevron-left" size={22} color={c.t2} /></Pressable>
          <Text style={{ flex: 1, textAlign: 'center', fontWeight: '700', fontSize: 17, color: c.t1 }}>From MakerWorld</Text>
          <View style={{ width: 40 }} />
        </View>

        {canDownload === false && (
          <View style={{ flexDirection: 'row', gap: 10, padding: 13, borderRadius: 13, backgroundColor: c.heatingDim, marginBottom: 14 }}>
            <Feather name="alert-triangle" size={17} color={c.heating} />
            <Text style={{ flex: 1, fontWeight: '500', fontSize: 12.5, lineHeight: 18, color: c.t2 }}>
              MakerWorld isn’t connected on your Bambuddy server. You can preview a model, but to import it, sign in to Bambu Cloud in Bambuddy → Settings → MakerWorld.
            </Text>
          </View>
        )}

        <ScrollView keyboardShouldPersistTaps="handled" contentContainerStyle={{ paddingBottom: 6 }}>
          <L>MODEL LINK</L>
          <View style={{ flexDirection: 'row', gap: 10 }}>
            <TextInput
              value={url}
              onChangeText={setUrl}
              placeholder="https://makerworld.com/en/models/…"
              placeholderTextColor={c.t3}
              autoCapitalize="none"
              autoCorrect={false}
              keyboardType="url"
              returnKeyType="go"
              onSubmitEditing={resolve}
              style={{ flex: 1, height: 48, borderRadius: 13, backgroundColor: c.s2, paddingHorizontal: 14, color: c.t1, fontSize: 14 }}
            />
            <Pressable onPress={resolve} disabled={resolving || !url.trim()} style={({ pressed }) => [{ paddingHorizontal: 18, height: 48, borderRadius: 13, backgroundColor: c.accent, alignItems: 'center', justifyContent: 'center', opacity: !url.trim() ? 0.4 : 1 }, pressed && { opacity: 0.8 }]}>
              {resolving ? <ActivityIndicator color={c.accentInk} /> : <Text style={{ fontWeight: '700', fontSize: 14, color: c.accentInk }}>Resolve</Text>}
            </Pressable>
          </View>

          {err && (
            <View style={{ flexDirection: 'row', gap: 9, padding: 12, borderRadius: 12, backgroundColor: c.errorDim, marginTop: 12 }}>
              <Feather name="x-circle" size={16} color={c.error} />
              <Text style={{ flex: 1, fontWeight: '500', fontSize: 12.5, lineHeight: 18, color: c.t2 }}>{err}</Text>
            </View>
          )}

          {design && (
            <>
              <View style={{ marginTop: 18, width: '100%', aspectRatio: 16 / 10, borderRadius: 16, overflow: 'hidden', backgroundColor: '#0e1113', borderWidth: 1, borderColor: c.line }}>
                {design.coverUrl ? (
                  <Image source={{ uri: client.makerworldThumbUrl(design.coverUrl) }} style={{ width: '100%', height: '100%' }} contentFit="cover" cachePolicy="memory-disk" />
                ) : (
                  <View style={{ flex: 1, alignItems: 'center', justifyContent: 'center' }}><Feather name="box" size={30} color={c.t3} /></View>
                )}
              </View>
              <Text style={{ marginTop: 14, fontWeight: '700', fontSize: 18, color: c.t1, letterSpacing: -0.3 }}>{design.title ?? `Model ${resolved!.model_id}`}</Text>
              <Text style={{ marginTop: 5, fontWeight: '500', fontSize: 12, color: c.t3, fontFamily: mono }}>
                {design.designCreator?.name ? `@${design.designCreator.name}` : ''}{typeof design.downloadCount === 'number' ? `  ·  ${design.downloadCount} downloads` : ''}
              </Text>
              {alreadyImported && (
                <View style={{ flexDirection: 'row', alignItems: 'center', gap: 7, marginTop: 10, alignSelf: 'flex-start', paddingHorizontal: 11, paddingVertical: 6, borderRadius: 9, backgroundColor: c.accentDim }}>
                  <Feather name="check" size={13} color={c.accent} />
                  <Text style={{ fontWeight: '600', fontSize: 11.5, color: c.accent }}>Already in your library</Text>
                </View>
              )}

              {(resolved!.instances?.length ?? 0) > 0 && (
                <View style={{ marginTop: 20 }}>
                  <L>{`PROFILE${resolved!.instances.length > 1 ? `  ·  ${resolved!.instances.length}` : ''}`}</L>
                  <View style={{ gap: 9 }}>
                    {resolved!.instances.map((inst) => {
                      const sel = picked?.id === inst.id;
                      const t = instTime(inst);
                      const w = instWeight(inst);
                      const fils = inst.instanceFilaments ?? inst.extention?.modelInfo?.plates?.[0]?.filaments ?? [];
                      return (
                        <Pressable key={inst.id} onPress={() => setPicked(inst)} style={({ pressed }) => [{ flexDirection: 'row', alignItems: 'center', gap: 12, padding: 11, borderRadius: 13, backgroundColor: c.s2, borderWidth: sel ? 1.5 : 0, borderColor: c.accent }, pressed && { opacity: 0.7 }]}>
                          <View style={{ width: 52, height: 52, borderRadius: 10, overflow: 'hidden', backgroundColor: '#0e1113', alignItems: 'center', justifyContent: 'center' }}>
                            {inst.cover ? (
                              <Image source={{ uri: client.makerworldThumbUrl(inst.cover) }} style={{ width: '100%', height: '100%' }} contentFit="cover" cachePolicy="memory-disk" />
                            ) : (
                              <Feather name="layers" size={18} color={c.t3} />
                            )}
                          </View>
                          <View style={{ flex: 1 }}>
                            <Text numberOfLines={1} style={{ fontWeight: '600', fontSize: 13.5, color: c.t1 }}>{inst.title || 'Default profile'}</Text>
                            <View style={{ flexDirection: 'row', alignItems: 'center', gap: 8, marginTop: 4 }}>
                              <Text style={{ fontWeight: '500', fontSize: 11.5, color: c.t3, fontFamily: mono }}>
                                {t ? `${Math.round(t / 60)} min` : '—'}{w ? `  ·  ${w} g` : ''}{inst.needAms ? '  ·  AMS' : ''}
                              </Text>
                              <View style={{ flexDirection: 'row', gap: 3 }}>
                                {fils.slice(0, 4).map((f, k) => (
                                  <View key={k} style={{ width: 9, height: 9, borderRadius: 5, backgroundColor: f.color || c.s4, borderWidth: 1, borderColor: c.line2 }} />
                                ))}
                              </View>
                            </View>
                          </View>
                          {sel && <Feather name="check" size={16} color={c.accent} />}
                        </Pressable>
                      );
                    })}
                  </View>
                </View>
              )}
            </>
          )}
        </ScrollView>

        {design && (
          <Pressable
            onPress={doImport}
            disabled={importing || canDownload !== true}
            style={({ pressed }) => [{ marginTop: 14, height: 52, borderRadius: 15, backgroundColor: canDownload === true ? c.accent : c.s3, alignItems: 'center', justifyContent: 'center', flexDirection: 'row', gap: 9 }, pressed && { opacity: 0.85 }]}
          >
            {importing && <ActivityIndicator color={c.accentInk} />}
            <Text style={{ fontWeight: '700', fontSize: 16, color: canDownload === true ? c.accentInk : c.t3 }}>
              {importing ? 'Importing…' : canDownload === true ? (alreadyImported ? 'Import again' : 'Import to library') : 'Import unavailable'}
            </Text>
          </Pressable>
        )}
      </Pressable>
    </Pressable>
  );
}

// ---------------- PRINT WIZARD ----------------
type Preset = { id: string; name: string; source?: string };

export function WizardOverlay({ client, file, camToken, status, printerId, onClose, onStarted }: { client: BambuddyClient; file: LibraryFile; camToken: string | null; status: PrinterStatus | null; printerId: number; onClose: () => void; onStarted: () => void }) {
  const insets = useSafeAreaInsets();
  const alreadySliced = (file.file_type || '').includes('gcode');
  const [step, setStep] = useState(1);
  const [presets, setPresets] = useState<{ printer?: Preset; filaments: Preset[]; qualities: Preset[] } | null>(null);
  const [filament, setFilament] = useState<Preset | null>(null);
  const [quality, setQuality] = useState<Preset | null>(null);
  const [slicePct, setSlicePct] = useState(0);
  const [result, setResult] = useState<{ print_time_seconds?: number; filament_used_g?: number; library_file_id?: number } | null>(null);
  const [slot, setSlot] = useState<number>(status?.tray_now ?? 0);
  const [starting, setStarting] = useState(false);

  useEffect(() => {
    client.getPresets().then((p) => {
      const std = p.standard ?? {};
      const a1 = (arr: Preset[] = []) => arr.filter((x) => x.name.includes('A1') && !x.name.includes('A1M') && !x.name.toLowerCase().includes('mini'));
      const printer = a1(std.printer).find((x) => x.name.includes('0.4 nozzle'));
      const filaments = a1(std.filament).filter((x) => /Bambu (PLA Basic|PETG Basic|PLA Matte|ABS) @BBL A1$/.test(x.name));
      const qualities = a1(std.process).filter((x) => /0\.(12|16|20|28)mm .*@BBL A1$/.test(x.name));
      setPresets({ printer, filaments, qualities });
      setFilament(filaments[0] ?? null);
      setQuality(qualities.find((q) => q.name.includes('0.20')) ?? qualities[0] ?? null);
    }).catch(() => setPresets({ filaments: [], qualities: [] }));
  }, [client]);

  // Slicing step
  useEffect(() => {
    if (step !== 4) return;
    if (alreadySliced) {
      setResult({ print_time_seconds: file.print_time_seconds ?? undefined, filament_used_g: file.filament_used_grams ?? undefined, library_file_id: file.id });
      setSlicePct(100);
      const t = setTimeout(() => setStep(5), 600);
      return () => clearTimeout(t);
    }
    let cancelled = false;
    setSlicePct(5);
    (async () => {
      try {
        const { job_id } = await client.slice(file.id, {
          printer_preset: presets?.printer,
          process_preset: quality,
          filament_preset: filament,
          plate: 1,
          export_3mf: true,
        });
        for (let i = 0; i < 90 && !cancelled; i++) {
          const j = await client.getSliceJob(job_id);
          setSlicePct((p) => Math.min(95, p + 6));
          if (j.status === 'completed') {
            setResult(j.result ?? {});
            setSlicePct(100);
            if (!cancelled) setStep(5);
            return;
          }
          if (j.status === 'failed' || j.status === 'error') throw new Error(j.error || 'Slice failed');
          await new Promise((r) => setTimeout(r, 1500));
        }
        throw new Error('Slice timed out');
      } catch (e) {
        if (!cancelled) {
          Alert.alert('Slicing failed', String(e));
          setStep(3);
        }
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [step]);

  const start = async () => {
    setStarting(true);
    try {
      const mapping = Array(4).fill(-1);
      mapping[slot] = 0;
      await client.enqueue({
        printer_id: printerId,
        library_file_id: result?.library_file_id ?? file.id,
        use_ams: true,
        ams_mapping: mapping,
        plate_id: 1,
      });
      onStarted();
    } catch (e) {
      setStarting(false);
      Alert.alert('Couldn’t start', String(e));
    }
  };

  const steps = alreadySliced ? [1, 2, 6, 7] : [1, 2, 3, 4, 5, 6, 7];
  const idx = steps.indexOf(step);
  const next = () => setStep(steps[Math.min(idx + 1, steps.length - 1)]);
  const back = () => setStep(steps[Math.max(idx - 1, 0)]);
  const titles: Record<number, string> = { 1: 'File', 2: 'Printer', 3: 'Material', 4: 'Slicing', 5: 'Review', 6: 'Map filament', 7: 'Start print' };
  const captions: Record<number, string> = {
    1: 'The model you picked',
    2: 'Confirm the target printer',
    3: 'Pick filament and quality',
    4: 'Preparing G-code on your server',
    5: 'Check time and material',
    6: 'Choose which AMS tray to print from',
    7: 'Review, then send it to the queue',
  };

  const trays = status?.ams?.[0]?.tray ?? [];
  const footer = (() => {
    if (step === 4) return null;
    if (step === 7) return { label: starting ? 'Starting…' : 'Start print', bg: c.accent, fg: c.accentInk, onPress: start };
    if (step === 5) return { label: 'Looks good', bg: c.accent, fg: c.accentInk, onPress: next };
    return { label: 'Continue', bg: c.s3, fg: c.t1, onPress: next };
  })();

  const L = ({ children }: { children: React.ReactNode }) => <Text style={{ fontWeight: '600', fontSize: 11, letterSpacing: 1, color: c.t3, fontFamily: mono, marginBottom: 12 }}>{children}</Text>;
  const Row = ({ k, v }: { k: string; v: string }) => (
    <View style={{ flexDirection: 'row', justifyContent: 'space-between', padding: 14, borderBottomWidth: 1, borderBottomColor: c.line }}>
      <Text style={{ fontWeight: '500', fontSize: 13, color: c.t2 }}>{k}</Text>
      <Text numberOfLines={1} style={{ fontWeight: '600', fontSize: 13, color: c.t1, maxWidth: 200 }}>{v}</Text>
    </View>
  );

  return (
    <View style={{ position: 'absolute', inset: 0, backgroundColor: 'rgba(0,0,0,0.55)', justifyContent: 'flex-end', zIndex: 72 } as any}>
      <View style={{ height: '92%', backgroundColor: c.sheet, borderTopLeftRadius: 24, borderTopRightRadius: 24, overflow: 'hidden' }}>
        <View style={{ paddingHorizontal: 18, paddingTop: insets.top + 6, flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' }}>
          <Pressable onPress={onClose} hitSlop={10}><Text style={{ fontWeight: '500', fontSize: 15, color: c.t2 }}>Cancel</Text></Pressable>
          <View style={{ alignItems: 'center', flex: 1 }}>
            <Text style={{ fontWeight: '600', fontSize: 15, color: c.t1 }}>{titles[step]}</Text>
            <Text numberOfLines={1} style={{ marginTop: 2, fontWeight: '500', fontSize: 11, color: c.t3 }}>{captions[step]}</Text>
          </View>
          <Text style={{ fontWeight: '600', fontSize: 12, color: c.t3, fontFamily: mono }}>{idx + 1}/{steps.length}</Text>
        </View>
        <View style={{ flexDirection: 'row', gap: 4, paddingHorizontal: 18, paddingTop: 15 }}>
          {steps.map((s, i) => (
            <View key={s} style={{ flex: 1, alignItems: 'center', gap: 5 }}>
              <View style={{ width: '100%', height: 3, borderRadius: 2, backgroundColor: i <= idx ? c.accent : c.s3 }} />
              <Text numberOfLines={1} style={{ fontWeight: '600', fontSize: 8.5, letterSpacing: 0.3, color: i <= idx ? c.accent : c.t3, fontFamily: mono }}>{titles[s].toUpperCase()}</Text>
            </View>
          ))}
        </View>

        <ScrollView style={{ flex: 1 }} contentContainerStyle={{ padding: 18 }}>
          {step === 1 && (
            <>
              <L>SELECTED FILE</L>
              <View style={{ width: '100%', aspectRatio: 16 / 10, borderRadius: 16, overflow: 'hidden', backgroundColor: '#0e1113', borderWidth: 1, borderColor: c.line, alignItems: 'center', justifyContent: 'center' }}>
                {file.thumbnail_path ? (
                  <Image source={{ uri: client.fileThumbUrl(file.id, camToken, file.thumbnail_path) }} style={{ width: '100%', height: '100%' }} contentFit="cover" cachePolicy="memory-disk" />
                ) : (
                  <Feather name="box" size={32} color={c.t3} />
                )}
              </View>
              <Text style={{ marginTop: 15, fontWeight: '700', fontSize: 19, color: c.t1, letterSpacing: -0.3 }}>{file.print_name || file.filename}</Text>
              <Text style={{ marginTop: 6, fontWeight: '500', fontSize: 12, color: c.t3, fontFamily: mono }}>{file.file_type}{alreadySliced ? ' · pre-sliced' : ''}</Text>
            </>
          )}

          {step === 2 && (
            <>
              <L>PRINT ON</L>
              <View style={{ flexDirection: 'row', alignItems: 'center', gap: 14, padding: 16, borderRadius: 16, backgroundColor: c.s2 }}>
                <View style={{ width: 52, height: 52, borderRadius: 13, backgroundColor: c.s3, alignItems: 'center', justifyContent: 'center' }}>
                  <Feather name="cpu" size={26} color={c.t2} />
                </View>
                <View>
                  <Text style={{ fontWeight: '700', fontSize: 17, color: c.t1 }}>Bambu Lab A1</Text>
                  <View style={{ marginTop: 5, flexDirection: 'row', alignItems: 'center', gap: 6 }}>
                    <View style={{ width: 6, height: 6, borderRadius: 3, backgroundColor: status?.connected ? c.running : c.idle }} />
                    <Text style={{ fontWeight: '500', fontSize: 12, color: c.t2 }}>{status?.connected ? 'Connected' : 'Offline'}</Text>
                  </View>
                </View>
              </View>
            </>
          )}

          {step === 3 && (
            <>
              <L>MATERIAL</L>
              <View style={{ gap: 9 }}>
                {(presets?.filaments ?? []).map((m) => (
                  <Pressable key={m.id} onPress={() => setFilament(m)} style={({ pressed }) => [{ flexDirection: 'row', alignItems: 'center', padding: 14, borderRadius: 13, backgroundColor: c.s2, borderWidth: filament?.id === m.id ? 1.5 : 0, borderColor: c.accent }, pressed && { opacity: 0.7 }]}>
                    <Text style={{ flex: 1, fontWeight: '600', fontSize: 14, color: c.t1 }}>{m.name.replace(' @BBL A1', '')}</Text>
                    {filament?.id === m.id && <Feather name="check" size={16} color={c.accent} />}
                  </Pressable>
                ))}
              </View>
              <View style={{ height: 22 }} />
              <L>QUALITY</L>
              <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 9 }}>
                {(presets?.qualities ?? []).map((q) => {
                  const h = q.name.match(/0\.\d+mm/)?.[0] ?? '';
                  const label = q.name.replace(/0\.\d+mm /, '').replace(' @BBL A1', '');
                  return (
                    <Pressable key={q.id} onPress={() => setQuality(q)} style={({ pressed }) => [{ width: '47%', flexGrow: 1, padding: 15, borderRadius: 13, backgroundColor: c.s2, borderWidth: quality?.id === q.id ? 1.5 : 0, borderColor: c.accent }, pressed && { opacity: 0.7 }]}>
                      <Text style={{ fontWeight: '700', fontSize: 19, color: quality?.id === q.id ? c.accent : c.t1, fontVariant: ['tabular-nums'] }}>{h.replace('mm', '')}</Text>
                      <Text style={{ marginTop: 5, fontWeight: '500', fontSize: 12, color: c.t2 }}>{label}</Text>
                    </Pressable>
                  );
                })}
              </View>
            </>
          )}

          {step === 4 && (
            <View style={{ paddingTop: 40, alignItems: 'center' }}>
              <Text style={{ fontWeight: '700', fontSize: 46, color: c.t1, fontVariant: ['tabular-nums'], letterSpacing: -1 }}>{slicePct}<Text style={{ fontSize: 22, color: c.t3 }}>%</Text></Text>
              <View style={{ marginTop: 18, width: '78%', height: 5, borderRadius: 3, backgroundColor: c.s3, overflow: 'hidden' }}>
                <View style={{ height: '100%', width: `${slicePct}%`, backgroundColor: c.accent }} />
              </View>
              <Text style={{ marginTop: 14, fontWeight: '500', fontSize: 13, color: c.t2 }}>Slicing on your server…</Text>
            </View>
          )}

          {step === 5 && (
            <>
              <View style={{ width: '100%', aspectRatio: 4 / 3, borderRadius: 16, overflow: 'hidden', backgroundColor: '#0e1113', borderWidth: 1, borderColor: c.line }}>
                <Image source={{ uri: client.fileThumbUrl(result?.library_file_id ?? file.id, camToken) }} style={{ width: '100%', height: '100%' }} contentFit="cover" cachePolicy="memory-disk" />
              </View>
              <View style={{ marginTop: 16, borderRadius: 16, backgroundColor: c.s2, overflow: 'hidden' }}>
                <Row k="Print time" v={result?.print_time_seconds ? `${Math.round(result.print_time_seconds / 60)} min` : '—'} />
                <Row k="Filament" v={result?.filament_used_g ? `${result.filament_used_g.toFixed(2)} g` : '—'} />
                <Row k="Quality" v={quality?.name.replace(' @BBL A1', '') ?? '—'} />
              </View>
              <View style={{ marginTop: 14, flexDirection: 'row', gap: 10, padding: 13, borderRadius: 13, backgroundColor: c.accentDim }}>
                <Feather name="info" size={17} color={c.accent} />
                <Text style={{ flex: 1, fontWeight: '500', fontSize: 12.5, lineHeight: 18, color: c.t2 }}>Nothing prints yet. Review the estimate, then map filament to a tray.</Text>
              </View>
            </>
          )}

          {step === 6 && (
            <>
              <L>AMS SLOT</L>
              <View style={{ gap: 9 }}>
                {[0, 1, 2, 3].map((i) => {
                  const tray = trays[i];
                  const empty = !tray?.tray_type;
                  return (
                    <Pressable key={i} onPress={() => !empty && setSlot(i)} style={({ pressed }) => [{ flexDirection: 'row', alignItems: 'center', gap: 13, padding: 13, borderRadius: 13, backgroundColor: c.s2, opacity: empty ? 0.4 : 1, borderWidth: slot === i ? 1.5 : 0, borderColor: c.accent }, pressed && { opacity: 0.7 }]}>
                      <View style={{ width: 28, height: 28, borderRadius: 8, backgroundColor: empty ? 'transparent' : normColor(tray?.tray_color) ?? c.s4, borderWidth: empty ? 1 : 0, borderColor: c.line2, borderStyle: 'dashed' }} />
                      <View style={{ flex: 1 }}>
                        <Text style={{ fontWeight: '600', fontSize: 13, color: c.t1 }}>Slot {i + 1} · {empty ? 'Empty' : tray?.tray_type}</Text>
                      </View>
                      {slot === i && <Feather name="check" size={16} color={c.accent} />}
                    </Pressable>
                  );
                })}
              </View>
              <Text style={{ marginTop: 13, fontWeight: '500', fontSize: 12, color: c.t3 }}>Tap a slot to map this print's filament.</Text>
            </>
          )}

          {step === 7 && (
            <>
              <L>READY TO PRINT</L>
              <View style={{ borderRadius: 16, backgroundColor: c.s2, overflow: 'hidden' }}>
                <Row k="File" v={file.print_name || file.filename} />
                <Row k="Material" v={(filament?.name ?? 'As sliced').replace(' @BBL A1', '')} />
                <Row k="Mapped to" v={`Slot ${slot + 1}`} />
                <Row k="Est. time" v={result?.print_time_seconds ? `${Math.round(result.print_time_seconds / 60)} min` : '—'} />
              </View>
              <View style={{ marginTop: 14, flexDirection: 'row', gap: 10, padding: 13, borderRadius: 13, backgroundColor: c.heatingDim }}>
                <Feather name="thermometer" size={17} color={c.heating} />
                <Text style={{ flex: 1, fontWeight: '500', fontSize: 12.5, lineHeight: 18, color: c.t2 }}>Nozzle and bed heat first (~3 min). You can pause or stop anytime.</Text>
              </View>
            </>
          )}
        </ScrollView>

        {footer && (
          <View style={{ flexDirection: 'row', gap: 12, padding: 18, paddingBottom: insets.bottom + 16, borderTopWidth: 1, borderTopColor: c.line }}>
            {idx > 0 && step !== 7 && (
              <Pressable onPress={back} style={({ pressed }) => [{ paddingHorizontal: 22, height: 52, borderRadius: 15, backgroundColor: c.s3, alignItems: 'center', justifyContent: 'center' }, pressed && { opacity: 0.7 }]}>
                <Text style={{ fontWeight: '600', fontSize: 16, color: c.t1 }}>Back</Text>
              </Pressable>
            )}
            <Pressable onPress={footer.onPress} disabled={starting} style={({ pressed }) => [{ flex: 1, height: 52, borderRadius: 15, backgroundColor: footer.bg, alignItems: 'center', justifyContent: 'center' }, pressed && { opacity: 0.8 }]}>
              <Text style={{ fontWeight: '600', fontSize: 16, color: footer.fg }}>{footer.label}</Text>
            </Pressable>
          </View>
        )}
      </View>
    </View>
  );
}
