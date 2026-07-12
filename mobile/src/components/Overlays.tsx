import React, { useEffect, useRef, useState } from 'react';
import { View, Text, Pressable, ScrollView, ActivityIndicator, Alert, TextInput } from 'react-native';
import { Image } from 'expo-image';
import { WebView } from 'react-native-webview';
import Animated, { SlideInDown, FadeIn } from 'react-native-reanimated';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { Feather } from '@expo/vector-icons';
import * as DocumentPicker from 'expo-document-picker';
import { c, mono, shadow1 } from '@/theme';
import type { BambuddyClient } from '@/api/bambuddyClient';
import type { LibraryFile, Printer, PrinterStatus, MakerWorldResolved, MWInstance, PlatesResponse, FileMetadata, SlotAssignment } from '@/api/types';
import { presentDashboard, normColor } from '@/dashboard/present';
import { buildPlateReview, fmtSeconds } from '@/library/plateReview';
import { loadedFilaments, type LoadedFilament } from '@/library/filamentMatch';
import { parseGcodeLayers, gcodeViewerHtml, MAX_GCODE_BYTES } from '@/library/gcodeLayers';
import { selectProcess, pickDefaultQuality, type Preset } from '@/library/presetSelect';
import { printerProfile, slicedForMatchesPrinter } from '@/printers/profile';
import { mjpegHtml } from './mjpegHtml';
import { Tap, RollingNumber, HeatBar, FadeRise } from './anim';

// ---------------- CAMERA FULLSCREEN ----------------
export function CameraOverlay({ streamUrl, snapshotUrl, status, cameraHint, onClose, onRefresh }: { streamUrl: string | null; snapshotUrl?: string | null; status: PrinterStatus | null; cameraHint?: string; onClose: () => void; onRefresh: () => void }) {
  const insets = useSafeAreaInsets();
  const vm = presentDashboard(status, Date.now());
  // connecting = minting token / camera warming up; live = ≥1 frame decoded; failed = gave up (warm-up
  // deadline hit, or no stream URL ever materialized because the token mint kept failing).
  const [phase, setPhase] = useState<'connecting' | 'live' | 'failed'>('connecting');
  const [reloadKey, setReloadKey] = useState(0);

  // Re-arm to "connecting" whenever a fresh stream URL arrives (token (re)mint) or we manually retry.
  useEffect(() => { setPhase('connecting'); }, [streamUrl, reloadKey]);

  // Safety net: if no stream URL ever arrives (mintCameraToken rejecting/hanging), no WebView mounts to
  // report 'failed', so surface the recoverable failed card instead of an endless spinner.
  useEffect(() => {
    if (streamUrl) return; // a mounted WebView reports its own outcome via onMessage
    const id = setTimeout(() => setPhase((p) => (p === 'connecting' ? 'failed' : p)), 8000);
    return () => clearTimeout(id);
  }, [streamUrl, reloadKey]);

  // Fast-fail probe: a disabled H2C camera rejects the SNAPSHOT endpoint deterministically
  // (HTTP 503 in ~60 ms) while its /stream returns HTTP 200 whose only multipart part is a
  // text/plain error — the <img> never decodes a frame, so without this the overlay sits on
  // "waking…" for the full 40 s watchdog deadline (read: forever, nobody waits that long).
  // Only a clean HTTP error short-circuits; a probe NETWORK failure proves nothing about the
  // stream path and is ignored. Re-probes on retry (reloadKey) and token refresh.
  useEffect(() => {
    if (!snapshotUrl) return;
    let alive = true;
    fetch(snapshotUrl)
      .then((r) => {
        if (alive && !r.ok) setPhase((p) => (p === 'live' ? p : 'failed'));
      })
      .catch(() => {});
    return () => {
      alive = false;
    };
  }, [snapshotUrl, reloadKey]);

  // reloadKey re-arms the effects above (so a retry that yields the same/no token still shows feedback)
  // but is intentionally NOT in the WebView key — keying the WebView on streamUrl alone means a fresh
  // token triggers exactly one remount/warm-up instead of two (sync reloadKey bump + async new URL).
  const retry = () => { onRefresh(); setReloadKey((k) => k + 1); };
  const onMessage = (data: string) => {
    if (data === 'frame') setPhase('live');
    else if (data === 'failed') setPhase('failed');
    else setPhase((p) => (p === 'live' ? p : 'connecting')); // 'connecting' | 'retry'
  };
  const live = phase === 'live';
  // A known-offline printer won't ever produce a frame — show the actionable card now, not after a
  // full warm-up deadline of spinning.
  const failedView = phase === 'failed' || (!live && vm.kind === 'offline');

  return (
    <View style={{ position: 'absolute', inset: 0, backgroundColor: '#060708', zIndex: 70 } as any}>
      {streamUrl && (
        <WebView
          key={streamUrl}
          source={{ html: mjpegHtml(streamUrl) }}
          originWhitelist={['*']}
          style={{ flex: 1, backgroundColor: '#060708' }}
          scrollEnabled={false}
          javaScriptEnabled
          mediaPlaybackRequiresUserAction={false}
          allowsInlineMediaPlayback
          onMessage={(e) => onMessage(e.nativeEvent.data)}
        />
      )}
      {!live && (
        <View pointerEvents={failedView ? 'auto' : 'none'} style={{ position: 'absolute', inset: 0, alignItems: 'center', justifyContent: 'center', paddingHorizontal: 36 } as any}>
          {failedView ? (
            <>
              <Feather name="video-off" size={30} color="#3a4046" />
              <Text style={{ marginTop: 14, fontFamily: mono, color: '#3a4046', letterSpacing: 2, fontSize: 11 }}>CHAMBER · NO SIGNAL</Text>
              <Text style={{ marginTop: 12, color: '#6b7177', fontSize: 13, lineHeight: 19, textAlign: 'center' }}>
                {vm.kind === 'offline'
                  ? 'Printer is offline. The chamber camera needs the printer powered on and connected to Wi-Fi, then tap Retry.'
                  : `Couldn’t wake the chamber camera. ${cameraHint ?? 'Give it a moment and tap Retry.'} Make sure the printer is powered on.`}
              </Text>
              <Tap onPress={retry} style={{ marginTop: 18, paddingHorizontal: 18, height: 42, borderRadius: 12, backgroundColor: 'rgba(255,255,255,0.08)', alignItems: 'center', justifyContent: 'center' }}>
                <Text style={{ color: '#fff', fontWeight: '600', fontSize: 14 }}>Retry</Text>
              </Tap>
            </>
          ) : (
            <>
              <ActivityIndicator color="#6b7177" />
              <Text style={{ marginTop: 14, fontFamily: mono, color: '#6b7177', letterSpacing: 2, fontSize: 11 }}>CONNECTING…</Text>
              <Text style={{ marginTop: 10, color: '#4f555b', fontSize: 12.5, lineHeight: 18, textAlign: 'center' }}>
                Waking the chamber camera — the first frame can take a few seconds.
              </Text>
            </>
          )}
        </View>
      )}
      <View style={{ position: 'absolute', top: 0, left: 0, right: 0, paddingTop: insets.top + 10, paddingHorizontal: 16, paddingBottom: 16, flexDirection: 'row', alignItems: 'center', gap: 11 }}>
        <Tap onPress={onClose} style={{ width: 40, height: 40, borderRadius: 20, backgroundColor: 'rgba(22,24,27,0.6)', alignItems: 'center', justifyContent: 'center' }}>
          <Feather name="chevron-down" size={22} color="#fff" />
        </Tap>
        <View style={{ flex: 1, flexDirection: 'row', alignItems: 'center', gap: 8, paddingHorizontal: 13, paddingVertical: 10, borderRadius: 13, backgroundColor: 'rgba(22,24,27,0.55)' }}>
          <View style={{ width: 7, height: 7, borderRadius: 4, backgroundColor: vm.stateColor }} />
          <Text style={{ fontWeight: '600', fontSize: 13, color: '#fff' }}>{vm.stateLabel}</Text>
          <Text style={{ marginLeft: 'auto', fontWeight: '600', fontSize: 12, color: 'rgba(255,255,255,0.5)', fontFamily: mono }}>{vm.progressInt}% · L{vm.layer}</Text>
        </View>
        <Tap onPress={retry} style={{ width: 40, height: 40, borderRadius: 20, backgroundColor: 'rgba(22,24,27,0.6)', alignItems: 'center', justifyContent: 'center' }}>
          <Feather name="refresh-cw" size={18} color="#fff" />
        </Tap>
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
    <Pressable onPress={onClose} style={{ position: 'absolute', inset: 0, justifyContent: 'flex-end', zIndex: 72 } as any}>
      <Animated.View entering={FadeIn.duration(220)} pointerEvents="none" style={{ position: 'absolute', inset: 0, backgroundColor: 'rgba(0,0,0,0.5)' } as any} />
      <Animated.View entering={SlideInDown.duration(320)}>
      <Pressable onPress={() => {}} style={{ backgroundColor: c.sheet, borderTopLeftRadius: 26, borderTopRightRadius: 26, paddingHorizontal: 14, paddingTop: 10, paddingBottom: insets.bottom + 20, ...shadow1 }}>
        <View style={{ width: 38, height: 5, borderRadius: 3, backgroundColor: c.line2, alignSelf: 'center', marginBottom: 16 }} />
        <Text style={{ fontWeight: '700', fontSize: 17, color: c.t1, textAlign: 'center', marginBottom: 14 }}>Add a file</Text>
        <Tap onPress={pick} disabled={busy} style={{ flexDirection: 'row', alignItems: 'center', gap: 13, padding: 14, borderRadius: 14, backgroundColor: c.s2 }}>
          <View style={{ width: 36, height: 36, borderRadius: 10, backgroundColor: c.accentDim, alignItems: 'center', justifyContent: 'center' }}>
            <Feather name="folder" size={19} color={c.accent} />
          </View>
          <Text style={{ flex: 1, fontWeight: '600', fontSize: 15, color: c.t1 }}>{busy ? `Uploading… ${pct}%` : 'From Files'}</Text>
          {busy ? <ActivityIndicator color={c.t3} /> : <Feather name="chevron-right" size={16} color={c.t3} />}
        </Tap>
        <Tap onPress={() => setShowMW(true)} disabled={busy} style={{ flexDirection: 'row', alignItems: 'center', gap: 13, padding: 14, borderRadius: 14, backgroundColor: c.s2, marginTop: 10 }}>
          <View style={{ width: 36, height: 36, borderRadius: 10, backgroundColor: c.accentDim, alignItems: 'center', justifyContent: 'center' }}>
            <Feather name="globe" size={19} color={c.accent} />
          </View>
          <View style={{ flex: 1 }}>
            <Text style={{ fontWeight: '600', fontSize: 15, color: c.t1 }}>From MakerWorld</Text>
            <Text style={{ marginTop: 2, fontWeight: '500', fontSize: 11.5, color: c.t3 }}>Paste a model link</Text>
          </View>
          <Feather name="chevron-right" size={16} color={c.t3} />
        </Tap>
        <Tap onPress={onClose} style={{ marginTop: 14, height: 50, borderRadius: 14, backgroundColor: c.s3, alignItems: 'center', justifyContent: 'center' }}>
          <Text style={{ fontWeight: '600', fontSize: 16, color: c.t1 }}>Cancel</Text>
        </Tap>
      </Pressable>
      </Animated.View>
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
    <Pressable onPress={onClose} style={{ position: 'absolute', inset: 0, justifyContent: 'flex-end', zIndex: 72 } as any}>
      <Animated.View entering={FadeIn.duration(220)} pointerEvents="none" style={{ position: 'absolute', inset: 0, backgroundColor: 'rgba(0,0,0,0.5)' } as any} />
      <Animated.View entering={SlideInDown.duration(320)}>
      <Pressable onPress={() => {}} style={{ maxHeight: '88%', backgroundColor: c.sheet, borderTopLeftRadius: 26, borderTopRightRadius: 26, paddingHorizontal: 14, paddingTop: 10, paddingBottom: insets.bottom + 18, ...shadow1 }}>
        <View style={{ width: 38, height: 5, borderRadius: 3, backgroundColor: c.line2, alignSelf: 'center', marginBottom: 12 }} />
        <View style={{ flexDirection: 'row', alignItems: 'center', marginBottom: 14 }}>
          <Tap onPress={onBack} hitSlop={10} style={{ width: 40 }}><Feather name="chevron-left" size={22} color={c.t2} /></Tap>
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
            <Tap onPress={resolve} disabled={resolving || !url.trim()} style={{ paddingHorizontal: 18, height: 48, borderRadius: 13, backgroundColor: c.accent, alignItems: 'center', justifyContent: 'center', opacity: !url.trim() ? 0.4 : 1 }}>
              {resolving ? <ActivityIndicator color={c.accentInk} /> : <Text style={{ fontWeight: '700', fontSize: 14, color: c.accentInk }}>Resolve</Text>}
            </Tap>
          </View>

          {err && (
            <View style={{ flexDirection: 'row', gap: 9, padding: 12, borderRadius: 12, backgroundColor: c.errorDim, marginTop: 12 }}>
              <Feather name="x-circle" size={16} color={c.error} />
              <Text style={{ flex: 1, fontWeight: '500', fontSize: 12.5, lineHeight: 18, color: c.t2 }}>{err}</Text>
            </View>
          )}

          {design && (
            <>
              <View style={{ marginTop: 18, width: '100%', aspectRatio: 16 / 10, borderRadius: 16, overflow: 'hidden', backgroundColor: c.thumb, borderWidth: 1, borderColor: c.line }}>
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
                        <Tap key={inst.id} onPress={() => setPicked(inst)} style={{ flexDirection: 'row', alignItems: 'center', gap: 12, padding: 11, borderRadius: 13, backgroundColor: c.s2, borderWidth: sel ? 1.5 : 0, borderColor: c.accent }}>
                          <View style={{ width: 52, height: 52, borderRadius: 10, overflow: 'hidden', backgroundColor: c.thumb, alignItems: 'center', justifyContent: 'center' }}>
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
                        </Tap>
                      );
                    })}
                  </View>
                </View>
              )}
            </>
          )}
        </ScrollView>

        {design && (
          <Tap
            onPress={doImport}
            disabled={importing || canDownload !== true}
            style={{ marginTop: 14, height: 52, borderRadius: 15, backgroundColor: canDownload === true ? c.accent : c.s3, alignItems: 'center', justifyContent: 'center', flexDirection: 'row', gap: 9 }}
          >
            {importing && <ActivityIndicator color={c.accentInk} />}
            <Text style={{ fontWeight: '700', fontSize: 16, color: canDownload === true ? c.accentInk : c.t3 }}>
              {importing ? 'Importing…' : canDownload === true ? (alreadyImported ? 'Import again' : 'Import to library') : 'Import unavailable'}
            </Text>
          </Tap>
        )}
      </Pressable>
      </Animated.View>
    </Pressable>
  );
}

// ---------------- PRINT WIZARD ----------------
// Build plates come from the printer's profile (src/printers/profile.ts) — they differ per model.

// ---------------- GCODE LAYER VIEWER (scrub the sliced model layer by layer) ----------------
// Pure parser + HTML builder live in @/library/gcodeLayers (unit-tested, headless-renderable).
// `load` fetches the raw gcode — library files pass () => client.getGcode(id), the SD-card browser
// passes () => client.getPrinterFileGcode(printerId, path). Same viewer either way.
export function GcodeViewerOverlay({ load, title, onClose, plate }: { load: () => Promise<string>; title: string; onClose: () => void; plate?: { w: number; d: number } }) {
  const insets = useSafeAreaInsets();
  const [html, setHtml] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [hasSupport, setHasSupport] = useState<boolean | null>(null);

  useEffect(() => {
    let alive = true;
    load()
      .then((g) => {
        if (!alive) return;
        if (g.length > MAX_GCODE_BYTES) {
          setErr('This sliced file is too large to preview on the phone.');
          return;
        }
        const parsed = parseGcodeLayers(g);
        if (parsed.layers.length === 0) {
          setErr('No printable layers were found in this file.');
          return;
        }
        setHasSupport(parsed.hasSupport);
        setHtml(gcodeViewerHtml(parsed, plate));
      })
      .catch((e) => alive && setErr(String(e)));
    return () => {
      alive = false;
    };
    // Mounted per-file (callers conditionally render one overlay per viewed file) — fetch exactly
    // once. Depending on `load` would refetch+reparse on every parent re-render (inline arrow).
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  return (
    <View style={{ position: 'absolute', inset: 0, backgroundColor: '#0A0B0C', zIndex: 80 } as any}>
      {html && !err ? (
        <WebView
          source={{ html, baseUrl: 'https://localhost/' }}
          originWhitelist={['*']}
          style={{ flex: 1, backgroundColor: '#0A0B0C' }}
          scrollEnabled={false}
          javaScriptEnabled
          domStorageEnabled
          allowsInlineMediaPlayback
          onMessage={(e) => {
            try {
              const m = JSON.parse(e.nativeEvent.data);
              if (m.type === 'error') setErr(m.message || 'render error');
            } catch {
              /* ignore */
            }
          }}
        />
      ) : (
        <View style={{ flex: 1, alignItems: 'center', justifyContent: 'center', paddingHorizontal: 36 }}>
          {err ? (
            <>
              <Feather name="layers" size={30} color="#3a4046" />
              <Text style={{ marginTop: 14, color: '#6b7177', fontSize: 14, textAlign: 'center', lineHeight: 20 }}>{err}</Text>
            </>
          ) : (
            <>
              <ActivityIndicator color={c.accent} />
              <Text style={{ marginTop: 14, fontFamily: mono, color: '#3a4046', letterSpacing: 2, fontSize: 11 }}>LOADING G-CODE…</Text>
            </>
          )}
        </View>
      )}
      <View style={{ position: 'absolute', top: 0, left: 0, right: 0, paddingTop: insets.top + 10, paddingHorizontal: 16, flexDirection: 'row', alignItems: 'center', gap: 11 }}>
        <Tap onPress={onClose} style={{ width: 40, height: 40, borderRadius: 20, backgroundColor: 'rgba(22,24,27,0.6)', alignItems: 'center', justifyContent: 'center' }}>
          <Feather name="chevron-down" size={22} color="#fff" />
        </Tap>
        <View style={{ flex: 1, paddingHorizontal: 13, paddingVertical: 10, borderRadius: 13, backgroundColor: 'rgba(22,24,27,0.55)' }}>
          <Text numberOfLines={1} style={{ fontWeight: '600', fontSize: 13, color: '#fff' }}>{title}</Text>
        </View>
        {hasSupport != null && (
          <View style={{ flexDirection: 'row', alignItems: 'center', gap: 6, paddingHorizontal: 11, height: 40, borderRadius: 13, backgroundColor: 'rgba(22,24,27,0.55)' }}>
            <View style={{ width: 7, height: 7, borderRadius: 4, backgroundColor: hasSupport ? c.supports : '#4f555b' }} />
            <Text style={{ fontWeight: '600', fontSize: 12, color: hasSupport ? c.supports : '#9aa0a6' }}>{hasSupport ? 'Supports' : 'No supports'}</Text>
          </View>
        )}
      </View>
    </View>
  );
}

// ---------------- PLATE REVIEW (sliced model: plates · time · layers · filament) ----------------
function PStat({ label, value, sub }: { label: string; value: string; sub?: string }) {
  return (
    <View style={{ flex: 1, padding: 13, borderRadius: 14, backgroundColor: c.s2 }}>
      <Text style={{ fontWeight: '600', fontSize: 9, letterSpacing: 0.8, color: c.t3, fontFamily: mono }}>{label}</Text>
      <Text style={{ marginTop: 7, fontWeight: '700', fontSize: 19, color: c.t1, fontVariant: ['tabular-nums'], letterSpacing: -0.5 }}>{value}</Text>
      {sub ? <Text style={{ marginTop: 2, fontWeight: '500', fontSize: 10.5, color: c.t3, fontFamily: mono }}>{sub}</Text> : null}
    </View>
  );
}

export function PlateReview({ client, fileId, camToken, plateIndex, onSelectPlate, onViewLayers, sliced = true }: { client: BambuddyClient; fileId: number; camToken: string | null; plateIndex: number; onSelectPlate?: (i: number) => void; onViewLayers?: () => void; sliced?: boolean }) {
  const [plates, setPlates] = useState<PlatesResponse | null>(null);
  const [meta, setMeta] = useState<FileMetadata | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    let alive = true;
    setLoading(true);
    Promise.allSettled([
      client.getPlates(fileId).then((p) => alive && setPlates(p)),
      client.getFileDetail(fileId).then((d) => alive && setMeta(d.metadata ?? null)),
    ]).finally(() => alive && setLoading(false));
    return () => {
      alive = false;
    };
  }, [client, fileId]);

  const vm = buildPlateReview(plates, meta, plateIndex);
  const plate = plates?.plates?.find((p) => p.index === vm.plateIndex);
  const thumb = plate?.has_thumbnail ? client.plateThumbUrl(fileId, vm.plateIndex, camToken) : '';
  const detail = [
    vm.heightMm != null ? `${vm.heightMm} mm tall` : null,
    vm.nozzleTemp != null ? `${vm.nozzleTemp}°C nozzle` : null,
    vm.bedType,
  ].filter(Boolean).join('  ·  ');
  const settings = [vm.printer, vm.process].filter(Boolean).join('  ·  ');

  return (
    <View>
      {vm.plateCount > 1 && (
        <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 8, marginBottom: 14 }}>
          {plates!.plates.map((p) => {
            const sel = p.index === vm.plateIndex;
            return (
              <Tap key={p.index} onPress={() => onSelectPlate?.(p.index)} style={{ paddingHorizontal: 14, paddingVertical: 8, borderRadius: 11, backgroundColor: sel ? c.accentDim : c.s2, borderWidth: sel ? 1.5 : 0, borderColor: c.accent }}>
                <Text style={{ fontWeight: '600', fontSize: 13, color: sel ? c.accent : c.t2 }}>Plate {p.index}</Text>
              </Tap>
            );
          })}
        </View>
      )}

      <View style={{ width: '100%', aspectRatio: 4 / 3, borderRadius: 16, overflow: 'hidden', backgroundColor: c.thumb, borderWidth: 1, borderColor: c.line, alignItems: 'center', justifyContent: 'center' }}>
        {thumb ? (
          <Image source={{ uri: thumb }} style={{ width: '100%', height: '100%' }} contentFit="cover" cachePolicy="memory-disk" />
        ) : loading ? (
          <ActivityIndicator color={c.t3} />
        ) : (
          <Feather name="box" size={30} color={c.t3} />
        )}
        {onViewLayers && !loading && (
          <Tap onPress={onViewLayers} style={{ position: 'absolute', right: 10, bottom: 10, flexDirection: 'row', alignItems: 'center', gap: 6, paddingHorizontal: 11, paddingVertical: 7, borderRadius: 10, backgroundColor: 'rgba(10,11,12,0.72)' }}>
            <Feather name="layers" size={13} color={c.accent} />
            <Text style={{ fontWeight: '600', fontSize: 11.5, color: '#fff' }}>View layers</Text>
          </Tap>
        )}
      </View>

      {sliced ? (
        <View style={{ flexDirection: 'row', gap: 10, marginTop: 14 }}>
          <PStat label="PRINT TIME" value={fmtSeconds(vm.timeSeconds)} />
          <PStat label="LAYERS" value={vm.layers != null ? String(vm.layers) : '—'} sub={vm.layerHeight != null ? `${vm.layerHeight.toFixed(2)} mm/layer` : undefined} />
          <PStat label="FILAMENT" value={vm.grams != null ? `${vm.grams.toFixed(1)} g` : '—'} />
        </View>
      ) : (
        vm.plateCount > 1 && (
          <Text style={{ marginTop: 13, fontWeight: '500', fontSize: 12, color: c.t3, lineHeight: 17 }}>
            This file has {vm.plateCount} plates. Pick the one to print — only it gets sliced. Time and material are estimated after slicing.
          </Text>
        )
      )}

      {!!detail && <Text style={{ marginTop: 12, fontWeight: '500', fontSize: 11.5, color: c.t3, fontFamily: mono }}>{detail}</Text>}

      {vm.filaments.length > 0 && (
        <View style={{ marginTop: 14, borderRadius: 14, backgroundColor: c.s2, overflow: 'hidden' }}>
          {vm.filaments.map((f, i) => (
            <View key={f.slot} style={{ flexDirection: 'row', alignItems: 'center', gap: 12, paddingHorizontal: 14, paddingVertical: 12, borderTopWidth: i === 0 ? 0 : 1, borderTopColor: c.line }}>
              <View style={{ width: 22, height: 22, borderRadius: 7, backgroundColor: normColor(f.color ?? undefined) ?? c.s4, borderWidth: 1, borderColor: c.line2 }} />
              <Text style={{ flex: 1, fontWeight: '600', fontSize: 13, color: c.t1 }}>{f.type}</Text>
              <Text style={{ fontWeight: '500', fontSize: 12, color: c.t3, fontFamily: mono }}>
                {f.grams != null ? `${f.grams.toFixed(1)} g` : ''}{f.meters != null ? `  ·  ${f.meters.toFixed(2)} m` : ''}
              </Text>
            </View>
          ))}
        </View>
      )}

      {!!settings && <Text style={{ marginTop: 12, fontWeight: '500', fontSize: 11, color: c.t3, fontFamily: mono }}>{settings}</Text>}
    </View>
  );
}

export function WizardOverlay({ client, file, camToken, status, printerId, printer, onClose, onStarted }: { client: BambuddyClient; file: LibraryFile; camToken: string | null; status: PrinterStatus | null; printerId: number; printer: Printer | null; onClose: () => void; onStarted: () => void }) {
  const insets = useSafeAreaInsets();
  const profile = printerProfile(printer);
  const token = profile.presetToken; // "@BBL A1" / "@BBL H2C" — preset-name suffix for this machine
  const alreadySliced = (file.file_type || '').includes('gcode');
  const [step, setStep] = useState(1);
  const [presets, setPresets] = useState<{ printer?: Preset; qualities: Preset[]; catalog: Preset[]; allFilaments: Preset[]; hasSupportProfile?: boolean; supportByBase?: Record<string, Preset> } | null>(null);
  const [assigns, setAssigns] = useState<SlotAssignment[]>([]);
  const [showCatalog, setShowCatalog] = useState(false);
  const defaultedRef = useRef(false);
  const [filament, setFilament] = useState<Preset | null>(null);
  const [quality, setQuality] = useState<Preset | null>(null);
  const [slicePct, setSlicePct] = useState(0);
  const [result, setResult] = useState<{ print_time_seconds?: number; filament_used_g?: number; library_file_id?: number } | null>(null);
  // tray_now's idle sentinel is 255 ("no active tray") — never seed the mapping slot with it.
  const trayNow = status?.tray_now;
  const [slot, setSlot] = useState<number>(typeof trayNow === 'number' && trayNow >= 0 && trayNow <= 3 ? trayNow : 0);
  const [selectedPlate, setSelectedPlate] = useState(1);
  const [bedType, setBedType] = useState(profile.bedTypes[0].id);
  const [supports, setSupports] = useState(false);
  const [viewLayers, setViewLayers] = useState<{ fileId: number; title: string } | null>(null);
  const [starting, setStarting] = useState(false);
  // Which machine a pre-sliced file was sliced FOR (from the 3MF) — mismatched G-code is blocked.
  const [slicedFor, setSlicedFor] = useState<string | null>(null);

  useEffect(() => {
    let alive = true;
    Promise.all([client.getPresets(), client.listAssignments(printerId).catch(() => [] as SlotAssignment[])])
      .then(([p, a]) => {
        if (!alive) return;
        const std = p.standard ?? {};
        // This machine's stock printer preset: the default-nozzle variant ("Bambu Lab H2C 0.4 nozzle").
        const printerPresets: Preset[] = std.printer ?? [];
        const printerPreset =
          printerPresets.find((x) => x.name === `${profile.printerPresetBase} 0.4 nozzle`) ??
          printerPresets.find((x) => x.name === profile.printerPresetBase);
        // Quality profiles for this machine's 0.4 nozzle, merged across all preset groups (incl. the
        // user's custom profiles), non-0.4-nozzle variants excluded. Pure + unit-tested in presetSelect.
        const { qualities, hasSupportProfile, supportByBase } = selectProcess(p, token);
        const allFilaments: Preset[] = std.filament ?? [];
        // Curated "Other filament" catalog (common materials) shown when the AMS choice isn't enough.
        const catalogRe = new RegExp(
          `Bambu (PLA Basic|PLA Matte|PETG HF|PETG-CF|ABS|ASA|TPU 95A HF|Support For PLA) ${token.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}($| 0\\.4 nozzle$)`,
        );
        const catalog = allFilaments.filter((x) => catalogRe.test(x.name));
        setPresets({ printer: printerPreset, qualities, catalog, allFilaments, hasSupportProfile, supportByBase });
        setAssigns(a as SlotAssignment[]);
        setQuality(pickDefaultQuality(qualities));
      })
      .catch(() => alive && setPresets({ qualities: [], catalog: [], allFilaments: [], supportByBase: {} }));
    return () => {
      alive = false;
    };
  }, [client, printerId, token, profile.printerPresetBase]);

  // Pre-sliced files carry the target machine in the 3MF — read it to catch wrong-printer G-code.
  useEffect(() => {
    if (!alreadySliced) return;
    let alive = true;
    client.getPlates(file.id).then((p) => alive && setSlicedFor(p.embedded_printer ?? file.sliced_for_model ?? null)).catch(() => {});
    return () => {
      alive = false;
    };
  }, [client, file.id, file.sliced_for_model, alreadySliced]);
  const printerMismatch = alreadySliced && !slicedForMatchesPrinter(slicedFor, profile);

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
    // Supports on -> slice with the quality's "+ Supports" twin profile (provisioned in Bambuddy).
    const processPreset = (supports && quality && presets?.supportByBase?.[quality.name]) || quality;
    (async () => {
      try {
        const { job_id } = await client.slice(file.id, {
          printer_preset: presets?.printer,
          process_preset: processPreset,
          filament_preset: filament,
          plate: selectedPlate,
          bed_type: bedType,
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
    if (printerMismatch) {
      Alert.alert('Wrong printer', `This file was sliced for ${slicedFor}. Reslice it for ${printer?.name ?? 'this printer'} before printing.`);
      return;
    }
    if (slot < 0 || slot > 3) {
      Alert.alert('Pick a slot', 'Choose which AMS slot to print from first.');
      return;
    }
    setStarting(true);
    try {
      const mapping = Array(4).fill(-1);
      mapping[slot] = 0;
      await client.enqueue({
        printer_id: printerId,
        library_file_id: result?.library_file_id ?? file.id,
        use_ams: true,
        ams_mapping: mapping,
        plate_id: selectedPlate,
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
  // Filaments actually loaded in the AMS, mapped to slicer presets (drops support material).
  const loaded: LoadedFilament[] = presets ? loadedFilaments(trays, assigns, presets.allFilaments, token).filter((f) => !f.isSupport) : [];

  // Default-select the loaded filament (matching the active tray) once the AMS + presets are known.
  const loadedKey = loaded.map((f) => `${f.slot}:${f.preset?.id ?? ''}`).join(',');
  useEffect(() => {
    if (defaultedRef.current || !presets) return;
    const active = loaded.find((f) => f.slot === (status?.tray_now ?? -1) && f.preset) ?? loaded.find((f) => f.preset);
    if (active?.preset) {
      setFilament(active.preset);
      setSlot(active.slot);
      defaultedRef.current = true;
    } else if (trays.length > 0 && presets.catalog[0]) {
      setFilament(presets.catalog[0]);
      defaultedRef.current = true;
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [presets, loadedKey]);

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
    <View style={{ position: 'absolute', inset: 0, justifyContent: 'flex-end', zIndex: 72 } as any}>
      <Animated.View entering={FadeIn.duration(220)} pointerEvents="none" style={{ position: 'absolute', inset: 0, backgroundColor: 'rgba(0,0,0,0.55)' } as any} />
      <Animated.View entering={SlideInDown.duration(340)} style={{ height: '92%', backgroundColor: c.sheet, borderTopLeftRadius: 24, borderTopRightRadius: 24, overflow: 'hidden' }}>
        <View style={{ paddingHorizontal: 18, paddingTop: insets.top + 6, flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' }}>
          <Tap onPress={onClose} hitSlop={10}><Text style={{ fontWeight: '500', fontSize: 15, color: c.t2 }}>Cancel</Text></Tap>
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
          <FadeRise key={step} dy={10} duration={300}>
          {step === 1 && (
            <>
              <L>SELECTED FILE</L>
              {alreadySliced ? (
                <>
                  <Text style={{ fontWeight: '700', fontSize: 19, color: c.t1, letterSpacing: -0.3 }}>{file.print_name || file.filename}</Text>
                  <Text style={{ marginTop: 5, marginBottom: 16, fontWeight: '500', fontSize: 12, color: c.t3, fontFamily: mono }}>{file.file_type} · pre-sliced</Text>
                  {printerMismatch && (
                    <View style={{ flexDirection: 'row', gap: 10, padding: 13, borderRadius: 13, backgroundColor: c.errorDim, borderWidth: 1, borderColor: c.error, marginBottom: 14 }}>
                      <Feather name="alert-triangle" size={17} color={c.error} />
                      <Text style={{ flex: 1, fontWeight: '500', fontSize: 12.5, lineHeight: 18, color: c.t1 }}>
                        Sliced for {slicedFor} — not for {printer?.name ?? 'this printer'}. G-code from another machine can crash the toolhead. Reslice the model instead.
                      </Text>
                    </View>
                  )}
                  <PlateReview client={client} fileId={file.id} camToken={camToken} plateIndex={selectedPlate} onSelectPlate={setSelectedPlate} onViewLayers={() => setViewLayers({ fileId: file.id, title: file.print_name || file.filename })} />
                </>
              ) : (
                <>
                  <Text style={{ fontWeight: '700', fontSize: 19, color: c.t1, letterSpacing: -0.3 }}>{file.print_name || file.filename}</Text>
                  <Text style={{ marginTop: 5, marginBottom: 16, fontWeight: '500', fontSize: 12, color: c.t3, fontFamily: mono }}>{file.file_type} · will be sliced</Text>
                  {/* Multi-plate files (e.g. a 6-plate project) expose all plates here — pick which one to slice. */}
                  <PlateReview client={client} fileId={file.id} camToken={camToken} plateIndex={selectedPlate} onSelectPlate={setSelectedPlate} sliced={false} />
                </>
              )}
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
                  <Text style={{ fontWeight: '700', fontSize: 17, color: c.t1 }}>{printer?.name ?? 'Printer'}</Text>
                  <View style={{ marginTop: 5, flexDirection: 'row', alignItems: 'center', gap: 6 }}>
                    <View style={{ width: 6, height: 6, borderRadius: 3, backgroundColor: status?.connected ? c.running : c.idle }} />
                    <Text style={{ fontWeight: '500', fontSize: 12, color: c.t2 }}>
                      {printer ? `${profile.printerPresetBase}${printer.location ? ` · ${printer.location}` : ''} · ` : ''}{status?.connected ? 'Connected' : 'Offline'}
                    </Text>
                  </View>
                </View>
              </View>
              <Text style={{ marginTop: 13, fontWeight: '500', fontSize: 12, color: c.t3 }}>Switch printers from the dashboard header.</Text>
            </>
          )}

          {step === 3 && (
            <>
              <L>{loaded.length > 0 ? 'LOADED IN THE PRINTER' : 'MATERIAL'}</L>
              {loaded.length > 0 && (
                <View style={{ gap: 9 }}>
                  {loaded.map((f) => {
                    const sel = !!f.preset && filament?.id === f.preset.id;
                    return (
                      <Tap
                        key={f.slot}
                        onPress={() => { if (f.preset) { setFilament(f.preset); setSlot(f.slot); } }}
                        disabled={!f.preset}
                        style={{ flexDirection: 'row', alignItems: 'center', gap: 13, padding: 14, borderRadius: 13, backgroundColor: c.s2, borderWidth: sel ? 1.5 : 0, borderColor: c.accent, opacity: f.preset ? 1 : 0.5 }}>
                        <View style={{ width: 30, height: 30, borderRadius: 9, backgroundColor: f.colorHex ?? c.s4, borderWidth: 1, borderColor: c.line2 }} />
                        <View style={{ flex: 1 }}>
                          <Text style={{ fontWeight: '600', fontSize: 14, color: c.t1 }}>{f.colorName ? `${f.colorName} · ${f.material}` : f.material}</Text>
                          <Text style={{ marginTop: 3, fontWeight: '500', fontSize: 11, color: c.t3, fontFamily: mono }}>Slot {f.slot + 1}{f.preset ? '' : ' · no matching profile'}</Text>
                        </View>
                        {sel && <Feather name="check" size={16} color={c.accent} />}
                      </Tap>
                    );
                  })}
                </View>
              )}
              <Tap onPress={() => setShowCatalog((v) => !v)} style={{ marginTop: loaded.length > 0 ? 14 : 0, flexDirection: 'row', alignItems: 'center', gap: 6 }}>
                <Feather name={showCatalog || loaded.length === 0 ? 'chevron-down' : 'chevron-right'} size={15} color={c.t3} />
                <Text style={{ fontWeight: '600', fontSize: 11, letterSpacing: 1, color: c.t3, fontFamily: mono }}>{loaded.length > 0 ? 'OR PICK ANOTHER FILAMENT' : 'CHOOSE A FILAMENT'}</Text>
              </Tap>
              {(showCatalog || loaded.length === 0) && (
                <View style={{ gap: 9, marginTop: 11 }}>
                  {(presets?.catalog ?? []).map((m) => (
                    <Tap key={m.id} onPress={() => setFilament(m)} style={{ flexDirection: 'row', alignItems: 'center', padding: 14, borderRadius: 13, backgroundColor: c.s2, borderWidth: filament?.id === m.id ? 1.5 : 0, borderColor: c.accent }}>
                      <Text style={{ flex: 1, fontWeight: '600', fontSize: 14, color: c.t1 }}>{m.name.replace(` ${token}`, '')}</Text>
                      {filament?.id === m.id && <Feather name="check" size={16} color={c.accent} />}
                    </Tap>
                  ))}
                </View>
              )}
              <View style={{ height: 22 }} />
              <L>QUALITY</L>
              <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 9 }}>
                {(presets?.qualities ?? []).map((q) => {
                  const h = q.name.match(/0\.\d+mm/)?.[0] ?? '';
                  const label = q.name.replace(/0\.\d+mm /, '').replace(` ${token}`, '');
                  return (
                    <Tap key={q.id} onPress={() => setQuality(q)} style={{ width: '47%', flexGrow: 1, padding: 15, borderRadius: 13, backgroundColor: c.s2, borderWidth: quality?.id === q.id ? 1.5 : 0, borderColor: c.accent }}>
                      <Text style={{ fontWeight: '700', fontSize: 19, color: quality?.id === q.id ? c.accent : c.t1, fontVariant: ['tabular-nums'] }}>{h.replace('mm', '')}</Text>
                      <Text style={{ marginTop: 5, fontWeight: '500', fontSize: 12, color: c.t2 }}>{label}</Text>
                    </Tap>
                  );
                })}
              </View>

              <View style={{ height: 22 }} />
              <L>BUILD PLATE</L>
              <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 9 }}>
                {profile.bedTypes.map((b) => (
                  <Tap key={b.id} onPress={() => setBedType(b.id)} style={{ flexGrow: 1, paddingVertical: 13, paddingHorizontal: 14, borderRadius: 13, backgroundColor: c.s2, borderWidth: bedType === b.id ? 1.5 : 0, borderColor: c.accent, alignItems: 'center' }}>
                    <Text style={{ fontWeight: '600', fontSize: 13.5, color: bedType === b.id ? c.accent : c.t1 }}>{b.label}</Text>
                  </Tap>
                ))}
              </View>

              <View style={{ height: 22 }} />
              {quality && presets?.supportByBase?.[quality.name] ? (
                // Supports toggle — slices with the "+ Supports" twin of the selected quality.
                <Tap onPress={() => setSupports((s) => !s)} style={{ flexDirection: 'row', alignItems: 'center', gap: 13, padding: 15, borderRadius: 14, backgroundColor: c.s2, borderWidth: supports ? 1.5 : 0, borderColor: c.supports }}>
                  <Feather name="git-merge" size={19} color={supports ? c.supports : c.t2} />
                  <View style={{ flex: 1 }}>
                    <Text style={{ fontWeight: '700', fontSize: 15, color: supports ? c.supports : c.t1 }}>Supports</Text>
                    <Text style={{ marginTop: 3, fontWeight: '500', fontSize: 11.5, lineHeight: 16, color: c.t3 }}>Tree supports under overhangs. Adds print time + material; shown in amber in the layer view.</Text>
                  </View>
                  <View style={{ width: 48, height: 29, borderRadius: 15, backgroundColor: supports ? c.supports : c.s4, justifyContent: 'center', paddingHorizontal: 3 }}>
                    <View style={{ width: 23, height: 23, borderRadius: 12, backgroundColor: '#fff', alignSelf: supports ? 'flex-end' : 'flex-start' }} />
                  </View>
                </Tap>
              ) : presets?.hasSupportProfile === false ? (
                <View style={{ flexDirection: 'row', gap: 10, padding: 13, borderRadius: 13, backgroundColor: c.s2 }}>
                  <Feather name="info" size={16} color={c.t3} style={{ marginTop: 1 }} />
                  <Text style={{ flex: 1, fontWeight: '500', fontSize: 12, lineHeight: 17, color: c.t3 }}>
                    Supports aren’t set up yet. Run the one-time provisioning on your server (deploy/bambuddy/ensure-support-profiles.py) and a Supports toggle appears here.
                  </Text>
                </View>
              ) : null}
            </>
          )}

          {step === 4 && (
            <View style={{ paddingTop: 40, alignItems: 'center' }}>
              <View style={{ flexDirection: 'row', alignItems: 'flex-end' }}>
                <RollingNumber value={slicePct} fontSize={46} weight="700" color={c.t1} letterSpacing={-1} />
                <Text style={{ fontSize: 22, fontWeight: '700', color: c.t3, marginBottom: 3 }}>%</Text>
              </View>
              <HeatBar pct={slicePct} color={c.accent} height={5} style={{ marginTop: 18, width: '78%' }} />
              <Text style={{ marginTop: 14, fontWeight: '500', fontSize: 13, color: c.t2 }}>Slicing on your server…</Text>
            </View>
          )}

          {step === 5 && (
            <>
              <PlateReview client={client} fileId={result?.library_file_id ?? file.id} camToken={camToken} plateIndex={selectedPlate} onSelectPlate={setSelectedPlate} onViewLayers={() => setViewLayers({ fileId: result?.library_file_id ?? file.id, title: file.print_name || file.filename })} />
              <View style={{ marginTop: 14, flexDirection: 'row', gap: 10, padding: 13, borderRadius: 13, backgroundColor: c.accentDim }}>
                <Feather name="info" size={17} color={c.accent} />
                <Text style={{ flex: 1, fontWeight: '500', fontSize: 12.5, lineHeight: 18, color: c.t2 }}>Nothing prints yet. Review the plate, then map filament to a tray.</Text>
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
                    <Tap key={i} onPress={() => !empty && setSlot(i)} style={{ flexDirection: 'row', alignItems: 'center', gap: 13, padding: 13, borderRadius: 13, backgroundColor: c.s2, opacity: empty ? 0.4 : 1, borderWidth: slot === i ? 1.5 : 0, borderColor: c.accent }}>
                      <View style={{ width: 28, height: 28, borderRadius: 8, backgroundColor: empty ? 'transparent' : normColor(tray?.tray_color) ?? c.s4, borderWidth: empty ? 1 : 0, borderColor: c.line2, borderStyle: 'dashed' }} />
                      <View style={{ flex: 1 }}>
                        <Text style={{ fontWeight: '600', fontSize: 13, color: c.t1 }}>Slot {i + 1} · {empty ? 'Empty' : tray?.tray_type}</Text>
                      </View>
                      {slot === i && <Feather name="check" size={16} color={c.accent} />}
                    </Tap>
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
                <Row k="Printer" v={printer?.name ?? '—'} />
                <Row k="Material" v={(filament?.name ?? 'As sliced').replace(` ${token}`, '')} />
                <Row k="Mapped to" v={`Slot ${slot + 1}`} />
                <Row k="Est. time" v={result?.print_time_seconds ? `${Math.round(result.print_time_seconds / 60)} min` : '—'} />
              </View>
              <View style={{ marginTop: 14, flexDirection: 'row', gap: 10, padding: 13, borderRadius: 13, backgroundColor: c.heatingDim }}>
                <Feather name="thermometer" size={17} color={c.heating} />
                <Text style={{ flex: 1, fontWeight: '500', fontSize: 12.5, lineHeight: 18, color: c.t2 }}>Nozzle and bed heat first (~3 min). You can pause or stop anytime.</Text>
              </View>
            </>
          )}
          </FadeRise>
        </ScrollView>

        {footer && (
          <View style={{ flexDirection: 'row', gap: 12, padding: 18, paddingBottom: insets.bottom + 16, borderTopWidth: 1, borderTopColor: c.line }}>
            {idx > 0 && step !== 7 && (
              <Tap onPress={back} style={{ paddingHorizontal: 22, height: 52, borderRadius: 15, backgroundColor: c.s3, alignItems: 'center', justifyContent: 'center' }}>
                <Text style={{ fontWeight: '600', fontSize: 16, color: c.t1 }}>Back</Text>
              </Tap>
            )}
            <Tap onPress={footer.onPress} disabled={starting} style={{ flex: 1, height: 52, borderRadius: 15, backgroundColor: footer.bg, alignItems: 'center', justifyContent: 'center' }}>
              <Text style={{ fontWeight: '600', fontSize: 16, color: footer.fg }}>{footer.label}</Text>
            </Tap>
          </View>
        )}
      </Animated.View>
      {viewLayers && <GcodeViewerOverlay key={viewLayers.fileId} load={() => client.getGcode(viewLayers.fileId)} title={viewLayers.title} plate={profile.plate} onClose={() => setViewLayers(null)} />}
    </View>
  );
}
