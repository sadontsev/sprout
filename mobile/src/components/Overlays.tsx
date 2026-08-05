import React, { useEffect, useMemo, useRef, useState } from 'react';
import { View, Text, Pressable, ScrollView, ActivityIndicator, Alert, TextInput, useWindowDimensions } from 'react-native';
import { Image } from 'expo-image';
import { WebView } from 'react-native-webview';
import Animated, { SlideInDown, FadeIn } from 'react-native-reanimated';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { Feather, MaterialIcons } from '@expo/vector-icons';
import { amsTrayRefs } from '@/ams/units';
import { Swatch } from './Swatch';
import * as DocumentPicker from 'expo-document-picker';
import { c, mono, shadow1 } from '@/theme';
import { apiErrorDetail, type BambuddyClient } from '@/api/bambuddyClient';
import type { TexturizeClient, TexturizeTexture, TexturizeMappingMode } from '@/api/texturizeClient';
import type { LibraryFile, Printer, PrinterStatus, MakerWorldResolved, MWInstance, PlatesResponse, FileMetadata, SlotAssignment } from '@/api/types';
import { presentDashboard, normColor, colorName } from '@/dashboard/present';
import { buildPlateReview, fmtSeconds } from '@/library/plateReview';
import { displayName } from '@/library/libraryBrowse';
import { loadedFilaments, catalogFilaments, type LoadedFilament } from '@/library/filamentMatch';
import { gcodeViewerHtml } from '@/library/gcodeLayers';
import { stlViewerHtml } from '@/library/stlViewerHtml';
import { selectProcess, pickDefaultQuality, mountedNozzles, defaultNozzle, printerPresetNameFor, type Preset, type NozzleSize } from '@/library/presetSelect';
import { buildProcessDelta, buildFilamentDelta, hasProcessOverrides, hasFilamentOverrides, overrideCount, INFILL_PATTERNS, TOP_PATTERNS, SUPPORT_STYLES, type SliceOverrides } from '@/library/sliceOverrides';
import { printerProfile, slicedForMatchesPrinter } from '@/printers/profile';
import { CameraPiPView, isPictureInPictureSupported, type CameraPiPViewRef } from '../../modules/camera-pip/src';
import { Tap, RollingNumber, HeatBar, FadeRise } from './anim';

// ---------------- CAMERA FULLSCREEN ----------------
export function CameraOverlay({ streamUrl, snapshotUrl, status, cameraHint, onClose, onRefresh, onPipChange }: { streamUrl: string | null; snapshotUrl?: string | null; status: PrinterStatus | null; cameraHint?: string; onClose: () => void; onRefresh: () => void; onPipChange?: (active: boolean) => void }) {
  const insets = useSafeAreaInsets();
  const vm = presentDashboard(status, Date.now());
  // connecting = minting token / camera warming up; live = ≥1 frame decoded; failed = gave up (warm-up
  // deadline hit, or no stream URL ever materialized because the token mint kept failing).
  const [phase, setPhase] = useState<'connecting' | 'live' | 'failed'>('connecting');
  const [reloadKey, setReloadKey] = useState(0);
  const [landscape, setLandscape] = useState(false);
  const { width: winW, height: winH } = useWindowDimensions();
  const pipRef = useRef<CameraPiPViewRef>(null);
  // Gate the button: PiP is unavailable on some devices, and a control that silently does nothing
  // is worse than no control.
  const pipSupported = useMemo(() => isPictureInPictureSupported(), []);

  // Re-arm to "connecting" whenever a fresh stream URL arrives (token (re)mint) or we manually retry.
  useEffect(() => { setPhase('connecting'); }, [streamUrl, reloadKey]);

  // Safety net: if no stream URL ever arrives (mintCameraToken rejecting/hanging), no WebView mounts to
  // report 'failed', so surface the recoverable failed card instead of an endless spinner.
  useEffect(() => {
    if (streamUrl) return; // the mounted native view reports its own outcome via onLive/onError
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
  const live = phase === 'live';
  // A known-offline printer won't ever produce a frame — show the actionable card now, not after a
  // full warm-up deadline of spinning.
  const failedView = phase === 'failed' || (!live && vm.kind === 'offline');

  // Landscape without touching the native orientation. The app is portrait-locked in app.json
  // (Info.plist), and expo-screen-orientation is not installed, so true auto-rotate needs a native
  // rebuild. A manual toggle also keeps working when the phone's own rotation lock is ON, which
  // auto-rotate would not. Rotating the whole overlay — chrome included — means you turn the phone
  // and everything reads the right way up.
  const landscapeStyle = landscape
    ? { width: winH, height: winW, left: (winW - winH) / 2, top: (winH - winW) / 2, transform: [{ rotate: '90deg' }] }
    : { inset: 0 };

  return (
    <View style={{ position: 'absolute', backgroundColor: '#060708', zIndex: 70, ...landscapeStyle } as any}>
      {/* Native sample-buffer view, not a WebView: an <img> can never enter Picture-in-Picture.
          NOT keyed on streamUrl — the token refreshes hourly and remounting would destroy the
          display layer, taking any active PiP window down with it. The view hot-swaps internally. */}
      <CameraPiPView
        ref={pipRef}
        url={streamUrl}
        active
        style={{ flex: 1, backgroundColor: '#060708' }}
        onLive={() => setPhase('live')}
        onError={(e) => { if (!e.nativeEvent.retryable) setPhase('failed'); }}
        onPipStart={() => onPipChange?.(true)}
        onPipStop={() => onPipChange?.(false)}
      />
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
      <View
        style={{
          position: 'absolute', top: 0, left: 0, right: 0, flexDirection: 'row', alignItems: 'center', gap: 11,
          paddingTop: landscape ? 12 : insets.top + 10,
          paddingBottom: 16,
          // Rotated, the notch/Dynamic Island runs down what is now the left edge.
          paddingLeft: (landscape ? insets.top : 0) + 16,
          paddingRight: 16,
        }}>
        <Tap
          onPress={() => setLandscape((v) => !v)}
          style={{ width: 40, height: 40, borderRadius: 20, backgroundColor: 'rgba(22,24,27,0.6)', alignItems: 'center', justifyContent: 'center' }}>
          <Feather name={landscape ? 'smartphone' : 'monitor'} size={17} color="#fff" />
        </Tap>
        <Tap onPress={onClose} style={{ width: 40, height: 40, borderRadius: 20, backgroundColor: 'rgba(22,24,27,0.6)', alignItems: 'center', justifyContent: 'center' }}>
          <Feather name="chevron-down" size={22} color="#fff" />
        </Tap>
        <View style={{ flex: 1, flexDirection: 'row', alignItems: 'center', gap: 8, paddingHorizontal: 13, paddingVertical: 10, borderRadius: 13, backgroundColor: 'rgba(22,24,27,0.55)' }}>
          <View style={{ width: 7, height: 7, borderRadius: 4, backgroundColor: vm.stateColor }} />
          <Text style={{ fontWeight: '600', fontSize: 13, color: '#fff' }}>{vm.stateLabel}</Text>
          <Text style={{ marginLeft: 'auto', fontWeight: '600', fontSize: 12, color: 'rgba(255,255,255,0.5)', fontFamily: mono }}>{vm.progressInt}% · L{vm.layer}</Text>
        </View>
        {pipSupported && (
          <Tap
            onPress={() => pipRef.current?.startPiP().catch(() => {})}
            style={{ width: 40, height: 40, borderRadius: 20, backgroundColor: 'rgba(22,24,27,0.6)', alignItems: 'center', justifyContent: 'center' }}>
            {/* The real PiP glyph. Feather has no equivalent, and "minimize" (arrows inward) read
                as a generic square that gave no hint what it did. */}
            <MaterialIcons name="picture-in-picture-alt" size={17} color="#fff" />
          </Tap>
        )}
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

// ---------------- TEXTURIZE SHEET ----------------
// Bakes an image as a displacement texture onto a library STL via the stl-texturize sidecar; the
// result lands as a NEW library file (the original is untouched). Chips over sliders on purpose —
// matches the house style and the sidecar's parameter space is forgiving.
function Chips<T>({ value, options, onChange }: { value: T; options: [T, string][]; onChange: (v: T) => void }) {
  return (
    <View style={{ flexDirection: 'row', gap: 8, flexWrap: 'wrap' }}>
      {options.map(([v, label]) => {
        const on = value === v;
        return (
          <Tap key={String(v)} onPress={() => onChange(v)} style={{ paddingHorizontal: 13, height: 34, borderRadius: 10, backgroundColor: on ? c.accentDim : c.s2, alignItems: 'center', justifyContent: 'center' }}>
            <Text style={{ fontWeight: '600', fontSize: 12.5, color: on ? c.accent : c.t2 }}>{label}</Text>
          </Tap>
        );
      })}
    </View>
  );
}
function SheetLabel({ children, first }: { children: React.ReactNode; first?: boolean }) {
  return <Text style={{ fontWeight: '600', fontSize: 11, color: c.t3, letterSpacing: 1, fontFamily: mono, marginTop: first ? 0 : 18, marginBottom: 9 }}>{children}</Text>;
}

/** "-textured.stl" name for a texturize result, mirroring the sidecar's texturedName(). */
function texturedDisplayName(f: LibraryFile): string {
  return `${displayName(f).replace(/\.(stl|3mf|obj|gcode(\.3mf)?)$/i, '')}-textured.stl`;
}

export function TexturizeSheet({ texClient, file, onClose, onDone }: { texClient: TexturizeClient; file: LibraryFile; onClose: () => void; onDone: () => void }) {
  const insets = useSafeAreaInsets();
  const { height: winH } = useWindowDimensions();
  const [textures, setTextures] = useState<TexturizeTexture[] | null>(null);
  const [texId, setTexId] = useState<string | null>(null);
  const [amplitude, setAmplitude] = useState(0.5);
  const [scale, setScale] = useState(0.5);
  const [mapping, setMapping] = useState<TexturizeMappingMode>('triplanar');
  const [detail, setDetail] = useState(0.4);
  const [job, setJob] = useState<{ id: string; stage: string; progress: number } | null>(null);
  // The finished result opens AUTOMATICALLY as a fullscreen preview held on the sidecar — the
  // library stays untouched until Keep commits it. Adjust discards and returns to the settings.
  const [preview, setPreview] = useState<{ jobId: string; tris?: number } | null>(null);
  const [keeping, setKeeping] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const pollRef = useRef<ReturnType<typeof setInterval> | null>(null);
  // Mirror for the unmount cleanup: a held preview is server memory — free it if the sheet dies
  // with one open (commit clears this first, so a kept file is never discarded).
  const previewRef = useRef<string | null>(null);
  useEffect(() => {
    previewRef.current = preview?.jobId ?? null;
  }, [preview]);

  useEffect(() => {
    texClient.listTextures().then((t) => {
      setTextures(t);
      if (t.length && !texId) setTexId(t[0].id);
    }).catch((e) => setError(`Couldn't reach the texturize server: ${String(e?.message ?? e)}`));
    return () => {
      if (pollRef.current) clearInterval(pollRef.current);
      if (previewRef.current) void texClient.discard(previewRef.current).catch(() => {});
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [texClient]);

  const start = async () => {
    if (!texId) return;
    setError(null);
    try {
      const { job_id } = await texClient.start({
        file_id: file.id,
        texture: { builtin: texId },
        amplitude,
        scale_u: scale,
        mapping_mode: mapping,
        refine_length: detail,
        protect_bed: true,
        commit: false, // preview flow — nothing enters the library until Keep
      });
      setJob({ id: job_id, stage: 'queued', progress: 0 });
      pollRef.current = setInterval(async () => {
        try {
          const j = await texClient.getJob(job_id);
          setJob({ id: job_id, stage: j.stage, progress: j.progress });
          if (j.status === 'done') {
            if (pollRef.current) clearInterval(pollRef.current);
            setJob(null);
            setPreview({ jobId: job_id, tris: j.out_triangles }); // auto-open the result
          } else if (j.status === 'error') {
            if (pollRef.current) clearInterval(pollRef.current);
            setJob(null);
            setError(j.error ?? 'Texturize failed');
          }
        } catch {
          /* transient poll failure — keep polling */
        }
      }, 1000);
    } catch (e) {
      setError(String(e instanceof Error ? e.message : e));
    }
  };

  const keep = async () => {
    if (!preview) return;
    setKeeping(true);
    try {
      await texClient.commit(preview.jobId);
      previewRef.current = null; // committed — the unmount cleanup must not discard it
      onDone(); // library refresh — the kept file is now real
      onClose();
    } catch (e) {
      setKeeping(false);
      Alert.alert('Couldn’t save', apiErrorDetail(e));
    }
  };
  const adjust = () => {
    if (preview) void texClient.discard(preview.jobId).catch(() => {}); // best-effort; server TTLs anyway
    setPreview(null); // back to the settings, untouched
  };

  const busy = job !== null;
  return (
    <Pressable onPress={busy || preview ? undefined : onClose} style={{ position: 'absolute', inset: 0, justifyContent: 'flex-end', zIndex: 72 } as any}>
      <Animated.View entering={FadeIn.duration(220)} pointerEvents="none" style={{ position: 'absolute', inset: 0, backgroundColor: 'rgba(0,0,0,0.5)' } as any} />
      <Animated.View entering={SlideInDown.duration(320)}>
        <Pressable onPress={() => {}} style={{ backgroundColor: c.sheet, borderTopLeftRadius: 26, borderTopRightRadius: 26, paddingHorizontal: 18, paddingTop: 10, paddingBottom: insets.bottom + 16, ...shadow1 }}>
          <View style={{ width: 38, height: 5, borderRadius: 3, backgroundColor: c.line2, alignSelf: 'center', marginBottom: 14 }} />
          <Text style={{ fontWeight: '700', fontSize: 17, color: c.t1, textAlign: 'center' }}>Texturize</Text>
          <Text numberOfLines={1} style={{ marginTop: 3, marginBottom: 12, fontWeight: '500', fontSize: 12, color: c.t3, textAlign: 'center', fontFamily: mono }}>{displayName(file)}</Text>
          {/* Settings scroll inside a BOUNDED height; buttons are pinned BELOW the scroll so they can
              never be pushed off-screen (tall content used to overflow past maxHeight without
              scrolling — RN clips nothing by default, so the buttons landed under the home bar). */}
          <ScrollView style={{ maxHeight: Math.max(220, winH - insets.top - insets.bottom - 320) }} showsVerticalScrollIndicator={false} bounces={false}>
            <SheetLabel first>TEXTURE</SheetLabel>
            {textures === null && !error && <ActivityIndicator color={c.accent} style={{ marginVertical: 16 }} />}
            {!!textures?.length && (
              <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={{ gap: 9 }}>
                {textures.map((t) => {
                  const on = t.id === texId;
                  return (
                    <Tap key={t.id} onPress={() => setTexId(t.id)} style={{ width: 74 }}>
                      <View style={{ width: 74, height: 74, borderRadius: 12, overflow: 'hidden', borderWidth: 2, borderColor: on ? c.accent : c.line, backgroundColor: c.s2 }}>
                        <Image source={{ uri: texClient.textureThumbUrl(t.id), headers: texClient.authHeaders() }} style={{ width: '100%', height: '100%' }} contentFit="cover" transition={100} cachePolicy="memory-disk" />
                      </View>
                      <Text numberOfLines={1} style={{ marginTop: 5, fontWeight: '600', fontSize: 10.5, color: on ? c.accent : c.t3, textAlign: 'center' }}>{t.name}</Text>
                    </Tap>
                  );
                })}
              </ScrollView>
            )}
            <SheetLabel>DEPTH</SheetLabel>
            <Chips value={amplitude} onChange={setAmplitude} options={[[0.25, 'Subtle'], [0.5, 'Medium'], [1, 'Bold']]} />
            <SheetLabel>PATTERN SIZE</SheetLabel>
            <Chips value={scale} onChange={setScale} options={[[0.25, 'Fine'], [0.5, 'Medium'], [1, 'Large']]} />
            <SheetLabel>WRAP</SheetLabel>
            <Chips<TexturizeMappingMode> value={mapping} onChange={setMapping} options={[['triplanar', 'Auto'], ['cubic', 'Boxy'], ['cylindrical', 'Round']]} />
            <SheetLabel>DETAIL</SheetLabel>
            <Chips value={detail} onChange={setDetail} options={[[0.4, 'Standard'], [0.25, 'Fine · slower']]} />
          </ScrollView>
          {error && (
            <View style={{ marginTop: 14, padding: 12, borderRadius: 12, backgroundColor: c.s2, borderWidth: 1, borderColor: c.error }}>
              <Text style={{ color: c.error, fontSize: 12.5, lineHeight: 17, fontWeight: '500' }}>{error}</Text>
            </View>
          )}
          {busy && (
            <View style={{ marginTop: 14 }}>
              <View style={{ height: 6, borderRadius: 3, backgroundColor: c.s3, overflow: 'hidden' }}>
                <View style={{ width: `${Math.round(job.progress * 100)}%`, height: 6, borderRadius: 3, backgroundColor: c.accent }} />
              </View>
              <Text style={{ marginTop: 7, fontWeight: '500', fontSize: 11.5, color: c.t3, textAlign: 'center', fontFamily: mono }}>{job.stage} · {Math.round(job.progress * 100)}%</Text>
            </View>
          )}
          <View style={{ flexDirection: 'row', gap: 12, marginTop: 14 }}>
            <Tap onPress={onClose} disabled={busy} style={{ paddingHorizontal: 22, height: 50, borderRadius: 14, backgroundColor: c.s3, alignItems: 'center', justifyContent: 'center', opacity: busy ? 0.5 : 1 }}>
              <Text style={{ fontWeight: '600', fontSize: 15, color: c.t1 }}>Cancel</Text>
            </Tap>
            <Tap onPress={start} disabled={busy || !texId} style={{ flex: 1, height: 50, borderRadius: 14, backgroundColor: busy || !texId ? c.s3 : c.accent, alignItems: 'center', justifyContent: 'center' }}>
              <Text style={{ fontWeight: '700', fontSize: 15, color: busy || !texId ? c.t3 : c.accentInk }}>{busy ? 'Texturizing…' : 'Texturize'}</Text>
            </Tap>
          </View>
          <Text style={{ marginTop: 9, fontSize: 10.5, lineHeight: 14, color: c.t3, textAlign: 'center' }}>
            The result opens for review first — nothing is saved until you Keep it. The bed face stays flat.
          </Text>
        </Pressable>
      </Animated.View>

      {/* Fullscreen result review — opens automatically when the job finishes. Keep commits the
          held preview into the library; Adjust discards it and returns to the settings above.
          MUST be a tap-swallowing Pressable: it sits inside the backdrop Pressable, and once the
          job ends (busy=false) an unhandled tap here would bubble up and dismiss the whole sheet
          (reported: 'drawer closed once I pressed Texturize'). */}
      {preview && (
        <Pressable onPress={() => {}} style={{ position: 'absolute', inset: 0, backgroundColor: '#0A0B0C' } as any}>
          <StlWebView
            name={texturedDisplayName(file)}
            direct={{ origin: texClient.baseUrl, path: texClient.resultPath(preview.jobId), headers: texClient.authHeaders() }}
          />
          {/* Actions live in the TOP bar — the bottom belongs to the page's own shading chips
              (Normals is the best mode for judging texture depth before committing). */}
          <View style={{ position: 'absolute', top: 0, left: 0, right: 0, paddingTop: insets.top + 10, paddingHorizontal: 16, flexDirection: 'row', alignItems: 'center', gap: 10 }}>
            <View style={{ flex: 1, paddingHorizontal: 13, height: 44, justifyContent: 'center', borderRadius: 13, backgroundColor: 'rgba(22,24,27,0.55)' }}>
              <Text numberOfLines={1} style={{ fontWeight: '600', fontSize: 13, color: '#fff' }}>
                Result{preview.tris ? ` · ${preview.tris.toLocaleString()} tris` : ''}
              </Text>
            </View>
            <Tap onPress={adjust} disabled={keeping} style={{ paddingHorizontal: 16, height: 44, borderRadius: 13, backgroundColor: 'rgba(42,46,51,0.92)', alignItems: 'center', justifyContent: 'center' }}>
              <Text style={{ fontWeight: '600', fontSize: 14, color: '#E7E9EC' }}>Adjust</Text>
            </Tap>
            <Tap onPress={keep} disabled={keeping} style={{ paddingHorizontal: 18, height: 44, borderRadius: 13, backgroundColor: c.accent, alignItems: 'center', justifyContent: 'center' }}>
              {keeping ? <ActivityIndicator color={c.accentInk} /> : <Text style={{ fontWeight: '700', fontSize: 14, color: c.accentInk }}>Keep</Text>}
            </Tap>
          </View>
        </Pressable>
      )}
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
                                  <Swatch key={k} value={normColor(f.color ?? undefined)} size={9} radius={5} />
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
export function GcodeViewerOverlay({ src, title, onClose, plate }: { src: { url: string; headers?: Record<string, string> }; title: string; onClose: () => void; plate?: { w: number; d: number } }) {
  const insets = useSafeAreaInsets();
  const [html, setHtml] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [hasSupport, setHasSupport] = useState<boolean | null>(null);

  const pageOrigin = (() => {
    const m = /^(https?:\/\/[^/]+)/i.exec(src.url);
    return m ? `${m[1]}/` : 'https://localhost/';
  })();
  // No fetch here on purpose: the page pulls the G-code itself and parses it with JIT. Handing a
  // 70 MB string across the bridge (then JSON-ing it back into the page) was the actual reason large
  // prints "couldn't be previewed" — see gcodeViewerHtml.
  useEffect(() => {
    setHtml(gcodeViewerHtml(src, plate));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  return (
    <View style={{ position: 'absolute', inset: 0, backgroundColor: '#0A0B0C', zIndex: 80 } as any}>
      {html && !err ? (
        <WebView
          // Load the page on the SERVER's origin so its in-page fetch is same-origin: Bambuddy sends
          // no CORS headers, so a localhost origin would get the request blocked outright.
          source={{ html, baseUrl: pageOrigin }}
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
              if (m.type === 'ready') setHasSupport(!!m.hasSupport);
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

// ---------------- STL 3D VIEWER (interactive mesh preview — raw WebGL in a WebView) ----------------
/** Shared mint-URL → viewer-page WebView. `compact` hides the in-page control card (inline embeds).
 *  `direct` skips the library mint and points the page at an arbitrary same-origin path (e.g. a
 *  texturize preview held on the sidecar) with optional auth headers for the in-page fetch. */
export function StlWebView({ client, fileId, name, compact, style, direct }: { client?: BambuddyClient; fileId?: number; name: string; compact?: boolean; style?: object; direct?: { origin: string; path: string; headers?: Record<string, string> } }) {
  const [html, setHtml] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const baseUrl = direct ? direct.origin : client!.baseUrl;

  useEffect(() => {
    let alive = true;
    if (direct) {
      setHtml(stlViewerHtml({ url: direct.path, name, compact, headers: direct.headers }));
      return () => {
        alive = false;
      };
    }
    // Tokenized download URL: the page fetches the model itself (same-origin via baseUrl below), so
    // the mesh bytes never cross the RN bridge and no auth headers are needed in-page.
    client!
      .mintFileDownloadUrl(fileId!, name)
      .then((url) => alive && setHtml(stlViewerHtml({ url, name, compact })))
      .catch((e) => alive && setErr(apiErrorDetail(e)));
    return () => {
      alive = false;
    };
    // Mounted per-file — mint exactly once (the token is single-use).
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  if (!html || err) {
    return (
      <View style={[{ flex: 1, alignItems: 'center', justifyContent: 'center', paddingHorizontal: 24, backgroundColor: '#0A0B0C' }, style]}>
        {err ? (
          <>
            <Feather name="box" size={compact ? 22 : 30} color="#3a4046" />
            <Text style={{ marginTop: 10, color: '#6b7177', fontSize: compact ? 12 : 14, textAlign: 'center', lineHeight: 18 }}>{err}</Text>
          </>
        ) : (
          <>
            <ActivityIndicator color={c.accent} />
            <Text style={{ marginTop: 10, fontFamily: mono, color: '#3a4046', letterSpacing: 2, fontSize: 10 }}>LOADING MODEL…</Text>
          </>
        )}
      </View>
    );
  }
  return (
    <WebView
      source={{ html, baseUrl: `${baseUrl}/` }}
      originWhitelist={['*']}
      style={[{ flex: 1, backgroundColor: '#0A0B0C' }, style]}
      scrollEnabled={false}
      javaScriptEnabled
      domStorageEnabled
      onMessage={(e) => {
        try {
          const m = JSON.parse(e.nativeEvent.data);
          if (m.type === 'error') setErr(m.message || 'render error');
        } catch {
          /* ignore */
        }
      }}
    />
  );
}

export function StlViewerOverlay({ client, fileId, name, onClose }: { client: BambuddyClient; fileId: number; name: string; onClose: () => void }) {
  const insets = useSafeAreaInsets();
  return (
    <View style={{ position: 'absolute', inset: 0, backgroundColor: '#0A0B0C', zIndex: 84 } as any}>
      <StlWebView client={client} fileId={fileId} name={name} />
      <View style={{ position: 'absolute', top: 0, left: 0, right: 0, paddingTop: insets.top + 10, paddingHorizontal: 16, flexDirection: 'row', alignItems: 'center', gap: 11 }}>
        <Tap onPress={onClose} style={{ width: 40, height: 40, borderRadius: 20, backgroundColor: 'rgba(22,24,27,0.6)', alignItems: 'center', justifyContent: 'center' }}>
          <Feather name="chevron-down" size={22} color="#fff" />
        </Tap>
        <View style={{ flex: 1, paddingHorizontal: 13, paddingVertical: 10, borderRadius: 13, backgroundColor: 'rgba(22,24,27,0.55)' }}>
          <Text numberOfLines={1} style={{ fontWeight: '600', fontSize: 13, color: '#fff' }}>{name}</Text>
        </View>
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
              <Swatch value={normColor(f.color ?? undefined)} size={22} radius={7} />
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

export function WizardOverlay({ client, file, camToken, status, printerId, printer, onClose, onStarted, onTexturize, onView3D }: { client: BambuddyClient; file: LibraryFile; camToken: string | null; status: PrinterStatus | null; printerId: number; printer: Printer | null; onClose: () => void; onStarted: () => void; onTexturize?: (f: LibraryFile) => void; onView3D?: (f: LibraryFile) => void }) {
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
  // Nozzle variant drives BOTH the machine preset and the process family. Defaults to what's
  // physically mounted (live nozzle_rack via status.nozzles) once status arrives, until touched.
  const [nozzle, setNozzle] = useState<NozzleSize>('0.4');
  const nozzleTouchedRef = useRef(false);
  const mounted = mountedNozzles(status);
  useEffect(() => {
    if (!nozzleTouchedRef.current && mounted.length) setNozzle(defaultNozzle(mounted));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [mounted.join(',')]);
  // Advanced per-slice overrides (admin-only feature — preset writes are admin-gated server-side).
  const [adv, setAdv] = useState<SliceOverrides>({});
  const [advOpen, setAdvOpen] = useState(false);
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
        // This machine's stock printer preset for the SELECTED nozzle variant.
        const printerPresets: Preset[] = std.printer ?? [];
        const printerPreset =
          printerPresets.find((x) => x.name === printerPresetNameFor(profile.printerPresetBase, nozzle)) ??
          printerPresets.find((x) => x.name === `${profile.printerPresetBase} 0.4 nozzle`) ??
          printerPresets.find((x) => x.name === profile.printerPresetBase);
        // Quality profiles for this machine + nozzle, merged across all preset groups (incl. the
        // user's custom profiles), other nozzle variants excluded. Pure + unit-tested in presetSelect.
        const { qualities, hasSupportProfile, supportByBase } = selectProcess(p, token, nozzle);
        const allFilaments: Preset[] = std.filament ?? [];
        // Curated "Other filament" catalog — resolved for the SELECTED nozzle by filamentMatch (this
        // used to be a second, 0.4-only regex here, which is how the nozzle bug lived in two places).
        const catalog = catalogFilaments(allFilaments, token, nozzle);
        setPresets({ printer: printerPreset, qualities, catalog, allFilaments, hasSupportProfile, supportByBase });
        setAssigns(a as SlotAssignment[]);
        setQuality(pickDefaultQuality(qualities));
      })
      .catch(() => alive && setPresets({ qualities: [], catalog: [], allFilaments: [], supportByBase: {} }));
    return () => {
      alive = false;
    };
  }, [client, printerId, token, profile.printerPresetBase, nozzle]);

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
        // Advanced overrides ride an ephemeral LOCAL preset inheriting the chosen profile (delta
        // keys only — see library/sliceOverrides.ts). Upserted per slice; admin-gated server-side.
        let processRef: unknown = processPreset;
        let filamentRef: unknown = filament;
        if (client.hasAdminLogin && processPreset && hasProcessOverrides(adv)) {
          const setting = buildProcessDelta(processPreset.name, adv, `Sprout Custom ${token}`)!;
          const id = await client.upsertLocalPreset(`Sprout Custom ${token}`, 'process', setting);
          processRef = { source: 'local', id: String(id) };
        }
        if (client.hasAdminLogin && filament && hasFilamentOverrides(adv)) {
          const variants = (printer?.nozzle_count ?? 1) > 1 ? 3 : 1;
          const setting = buildFilamentDelta(filament.name, adv, `Sprout Custom Filament ${token}`, variants)!;
          const id = await client.upsertLocalPreset(`Sprout Custom Filament ${token}`, 'filament', setting);
          filamentRef = { source: 'local', id: String(id) };
        }
        const { job_id } = await client.slice(file.id, {
          printer_preset: presets?.printer,
          process_preset: processRef,
          filament_preset: filamentRef,
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
    if (!trays.some((t) => t.globalId === slot && t.trayType)) {
      Alert.alert('Pick a slot', 'Choose which AMS slot to print from first.');
      return;
    }
    setStarting(true);
    try {
      // ams_mapping is Bambu's own print-command field: indexed by FILAMENT, valued by GLOBAL tray
      // id (Bambuddy decodes it with gid>=254 -> external, >=128 -> HT, else gid//4, gid%4). The old
      // `Array(4).fill(-1); mapping[slot] = 0` had index and value swapped, so it debited the wrong
      // spool and could not address anything past the first unit at all.
      const mapping = [slot];
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
  const back = () => {
    // Review's natural "back" is Material: step 4 is a transient progress screen, and landing on it
    // re-runs the slice with unchanged settings. Skipping it lets the user actually change settings
    // (Continue from Material re-slices with the new ones).
    if (step === 5 && !alreadySliced) return setStep(3);
    setStep(steps[Math.max(idx - 1, 0)]);
  };
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

  // Every tray across EVERY unit. This used to be `status.ams[0].tray`, which made 5 of the 9 slots
  // on a three-unit machine invisible and unprintable.
  const trays = amsTrayRefs(status);
  // Filaments actually loaded in the AMS, mapped to slicer presets (drops support material).
  const loaded: LoadedFilament[] = presets ? loadedFilaments(trays, assigns, presets.allFilaments, token, nozzle).filter((f) => !f.isSupport) : [];

  // Default-select the loaded filament (matching the active tray) once the AMS + presets are known.
  const loadedKey = loaded.map((f) => `${f.slot}:${f.preset?.id ?? ''}`).join(',');
  useEffect(() => {
    if (defaultedRef.current || !presets) return;
    // f.slot is the GLOBAL id, which is the same space as tray_now.
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
        <View style={{ width: 38, height: 5, borderRadius: 3, backgroundColor: c.line2, alignSelf: 'center', marginTop: 8 }} />
        {/* No safe-area padding here: this is a BOTTOM sheet at 92% height, so its top edge already
            sits below the notch. Adding insets.top pushed the header ~59pt further down on top of
            that, leaving a dead band above "Cancel". */}
        <View style={{ paddingHorizontal: 18, paddingTop: 16, flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' }}>
          {/* Cancel is the primary escape from a 4-step flow — tinted like a real button, not muted
              secondary text that reads as disabled. */}
          <Tap onPress={onClose} hitSlop={12}><Text style={{ fontWeight: '600', fontSize: 15, color: c.accent }}>Cancel</Text></Tap>
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
                  <Text style={{ fontWeight: '700', fontSize: 19, color: c.t1, letterSpacing: -0.3 }}>{displayName(file)}</Text>
                  <Text style={{ marginTop: 5, marginBottom: 16, fontWeight: '500', fontSize: 12, color: c.t3, fontFamily: mono }}>{file.file_type} · pre-sliced</Text>
                  {printerMismatch && (
                    <View style={{ flexDirection: 'row', gap: 10, padding: 13, borderRadius: 13, backgroundColor: c.errorDim, borderWidth: 1, borderColor: c.error, marginBottom: 14 }}>
                      <Feather name="alert-triangle" size={17} color={c.error} />
                      <Text style={{ flex: 1, fontWeight: '500', fontSize: 12.5, lineHeight: 18, color: c.t1 }}>
                        Sliced for {slicedFor} — not for {printer?.name ?? 'this printer'}. G-code from another machine can crash the toolhead. Reslice the model instead.
                      </Text>
                    </View>
                  )}
                  <PlateReview client={client} fileId={file.id} camToken={camToken} plateIndex={selectedPlate} onSelectPlate={setSelectedPlate} onViewLayers={() => setViewLayers({ fileId: file.id, title: displayName(file) })} />
                </>
              ) : (
                <>
                  <Text style={{ fontWeight: '700', fontSize: 19, color: c.t1, letterSpacing: -0.3 }}>{displayName(file)}</Text>
                  <Text style={{ marginTop: 5, marginBottom: 16, fontWeight: '500', fontSize: 12, color: c.t3, fontFamily: mono }}>{file.file_type} · will be sliced</Text>
                  {(file.file_type || '').toLowerCase() === 'stl' ? (
                    /* Raw STLs have no slicer plates yet — PlateReview would be an empty grey box.
                       Show the LIVE mesh inline instead (compact page: orbit works, controls hidden). */
                    <View style={{ width: '100%', aspectRatio: 4 / 3, borderRadius: 16, overflow: 'hidden', borderWidth: 1, borderColor: c.line, backgroundColor: '#0A0B0C' }}>
                      <StlWebView client={client} fileId={file.id} name={displayName(file)} compact />
                    </View>
                  ) : (
                    /* Multi-plate files (e.g. a 6-plate project) expose all plates here — pick which one to slice. */
                    <PlateReview client={client} fileId={file.id} camToken={camToken} plateIndex={selectedPlate} onSelectPlate={setSelectedPlate} sliced={false} />
                  )}
                  {(file.file_type || '').toLowerCase() === 'stl' && (
                    <>
                      {onView3D && (
                        <Tap onPress={() => onView3D(file)} style={{ flexDirection: 'row', alignItems: 'center', gap: 13, padding: 14, borderRadius: 14, backgroundColor: c.s2, marginTop: 14 }}>
                          <View style={{ width: 36, height: 36, borderRadius: 10, backgroundColor: c.accentDim, alignItems: 'center', justifyContent: 'center' }}>
                            <Feather name="box" size={18} color={c.accent} />
                          </View>
                          <View style={{ flex: 1 }}>
                            <Text style={{ fontWeight: '600', fontSize: 15, color: c.t1 }}>View in 3D</Text>
                            <Text style={{ marginTop: 2, fontWeight: '500', fontSize: 11.5, color: c.t3 }}>Inspect the full-resolution mesh — rotate, zoom, switch shading</Text>
                          </View>
                          <Feather name="chevron-right" size={16} color={c.t3} />
                        </Tap>
                      )}
                      {onTexturize && (
                        <Tap onPress={() => onTexturize(file)} style={{ flexDirection: 'row', alignItems: 'center', gap: 13, padding: 14, borderRadius: 14, backgroundColor: c.s2, marginTop: 10 }}>
                          <View style={{ width: 36, height: 36, borderRadius: 10, backgroundColor: c.accentDim, alignItems: 'center', justifyContent: 'center' }}>
                            <Feather name="droplet" size={18} color={c.accent} />
                          </View>
                          <View style={{ flex: 1 }}>
                            <Text style={{ fontWeight: '600', fontSize: 15, color: c.t1 }}>Texturize first</Text>
                            <Text style={{ marginTop: 2, fontWeight: '500', fontSize: 11.5, color: c.t3 }}>Bake a surface pattern onto the model, then print the textured copy</Text>
                          </View>
                          <Feather name="chevron-right" size={16} color={c.t3} />
                        </Tap>
                      )}
                    </>
                  )}
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
              {(
                <>
                  <L>NOZZLE</L>
                  <View style={{ flexDirection: 'row', gap: 9, marginBottom: 6 }}>
                    {(['0.2', '0.4', '0.6', '0.8'] as NozzleSize[]).map((n) => {
                      const on = nozzle === n;
                      const isMounted = mounted.includes(n);
                      return (
                        <Tap
                          key={n}
                          onPress={() => {
                            nozzleTouchedRef.current = true;
                            setNozzle(n);
                          }}
                          style={{ flexGrow: 1, paddingVertical: 12, borderRadius: 13, backgroundColor: c.s2, borderWidth: on ? 1.5 : 0, borderColor: c.accent, alignItems: 'center' }}>
                          <Text style={{ fontWeight: '700', fontSize: 15, color: on ? c.accent : c.t1, fontVariant: ['tabular-nums'] }}>{n}</Text>
                          <Text style={{ marginTop: 2, fontWeight: '500', fontSize: 9.5, color: isMounted ? c.running : c.t3 }}>{isMounted ? 'mounted' : 'mm'}</Text>
                        </Tap>
                      );
                    })}
                  </View>
                  {mounted.length > 0 && !mounted.includes(nozzle) && (
                    <View style={{ flexDirection: 'row', gap: 9, padding: 12, borderRadius: 12, backgroundColor: c.heatingDim, marginBottom: 6 }}>
                      <Feather name="alert-triangle" size={15} color={c.heating} style={{ marginTop: 1 }} />
                      <Text style={{ flex: 1, fontWeight: '500', fontSize: 12, lineHeight: 17, color: c.t2 }}>
                        A {nozzle} mm nozzle isn’t mounted right now ({mounted.join(' / ')} mm installed). Slicing works, but swap the nozzle before printing.
                      </Text>
                    </View>
                  )}
                  <View style={{ height: 16 }} />
                </>
              )}
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
                        <Swatch value={f.colorHex} size={30} radius={9} />
                        <View style={{ flex: 1 }}>
                          <Text style={{ fontWeight: '600', fontSize: 14, color: c.t1 }}>{(() => { const n = f.colorName ?? colorName(f.colorHex); return n ? `${n} · ${f.material}` : f.material; })()}</Text>
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

              {/* ADVANCED — per-slice overrides via an ephemeral local preset (admin-gated writes;
                  hidden entirely without admin creds so the feature never dead-ends on a 403). */}
              {client.hasAdminLogin && (
                <>
                  <View style={{ height: 22 }} />
                  <Tap onPress={() => setAdvOpen((v) => !v)} style={{ flexDirection: 'row', alignItems: 'center', gap: 8 }}>
                    <Feather name={advOpen ? 'chevron-down' : 'chevron-right'} size={15} color={c.t3} />
                    <Text style={{ fontWeight: '600', fontSize: 11, letterSpacing: 1, color: c.t3, fontFamily: mono }}>ADVANCED</Text>
                    {overrideCount(adv) > 0 && (
                      <View style={{ paddingHorizontal: 8, paddingVertical: 2, borderRadius: 8, backgroundColor: c.accentDim }}>
                        <Text style={{ fontWeight: '700', fontSize: 10.5, color: c.accent }}>{overrideCount(adv)} changed</Text>
                      </View>
                    )}
                    {overrideCount(adv) > 0 && (
                      <Tap onPress={() => setAdv({})} hitSlop={8} style={{ marginLeft: 'auto' }}>
                        <Text style={{ fontWeight: '600', fontSize: 11.5, color: c.accent }}>Reset</Text>
                      </Tap>
                    )}
                  </Tap>
                  {advOpen && (
                    <View style={{ marginTop: 12, gap: 16 }}>
                      <View>
                        <SheetLabel first>WALL LOOPS</SheetLabel>
                        <Chips<number | undefined> value={adv.wallLoops} onChange={(v) => setAdv({ ...adv, wallLoops: v })} options={[[undefined, 'Preset'], [2, '2'], [3, '3'], [4, '4'], [6, '6']]} />
                      </View>
                      <View>
                        <SheetLabel first>INFILL DENSITY</SheetLabel>
                        <Chips<number | undefined> value={adv.infillDensity} onChange={(v) => setAdv({ ...adv, infillDensity: v })} options={[[undefined, 'Preset'], [10, '10%'], [15, '15%'], [25, '25%'], [40, '40%'], [100, '100%']]} />
                      </View>
                      <View>
                        <SheetLabel first>INFILL PATTERN</SheetLabel>
                        <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 8 }}>
                          {[undefined, ...INFILL_PATTERNS].map((p) => {
                            const on = adv.infillPattern === p;
                            return (
                              <Tap key={p ?? 'preset'} onPress={() => setAdv({ ...adv, infillPattern: p })} style={{ paddingHorizontal: 12, height: 32, borderRadius: 10, backgroundColor: on ? c.accentDim : c.s2, alignItems: 'center', justifyContent: 'center' }}>
                                <Text style={{ fontWeight: '600', fontSize: 12, color: on ? c.accent : c.t2 }}>{p ?? 'Preset'}</Text>
                              </Tap>
                            );
                          })}
                        </View>
                      </View>
                      <View>
                        <SheetLabel first>TOP SURFACE</SheetLabel>
                        <Chips<string | undefined> value={adv.topPattern} onChange={(v) => setAdv({ ...adv, topPattern: v })} options={[[undefined, 'Preset'], ...TOP_PATTERNS.slice(0, 3).map((p): [string, string] => [p, p])]} />
                      </View>
                      <View>
                        <SheetLabel first>PRIME TOWER</SheetLabel>
                        <Chips<boolean | undefined> value={adv.primeTower} onChange={(v) => setAdv({ ...adv, primeTower: v })} options={[[undefined, 'Preset'], [true, 'On'], [false, 'Off']]} />
                      </View>
                      <View>
                        <SheetLabel first>SUPPORT STYLE</SheetLabel>
                        <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 8 }}>
                          {[undefined, ...SUPPORT_STYLES].map((p) => {
                            const on = adv.supportStyle === p;
                            return (
                              <Tap key={p ?? 'preset'} onPress={() => setAdv({ ...adv, supportStyle: p })} style={{ paddingHorizontal: 12, height: 32, borderRadius: 10, backgroundColor: on ? c.accentDim : c.s2, alignItems: 'center', justifyContent: 'center' }}>
                                <Text style={{ fontWeight: '600', fontSize: 12, color: on ? c.accent : c.t2 }}>{p ?? 'Preset'}</Text>
                              </Tap>
                            );
                          })}
                        </View>
                      </View>
                      <View>
                        <SheetLabel first>SUPPORT ANGLE</SheetLabel>
                        <Chips<number | undefined> value={adv.supportAngle} onChange={(v) => setAdv({ ...adv, supportAngle: v })} options={[[undefined, 'Preset'], [25, '25°'], [30, '30°'], [40, '40°'], [55, '55°']]} />
                      </View>
                      <View>
                        <SheetLabel first>FLOW RATIO</SheetLabel>
                        <Chips<number | undefined> value={adv.flowRatio} onChange={(v) => setAdv({ ...adv, flowRatio: v })} options={[[undefined, 'Preset'], [0.95, '0.95'], [0.98, '0.98'], [1.02, '1.02'], [1.05, '1.05']]} />
                      </View>
                      <Text style={{ fontSize: 10.5, lineHeight: 15, color: c.t3 }}>
                        “Preset” keeps the profile’s value. Changes apply to this slice via a reusable “Sprout Custom” profile on your server — stock presets are never modified.
                      </Text>
                    </View>
                  )}
                </>
              )}
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
              <PlateReview client={client} fileId={result?.library_file_id ?? file.id} camToken={camToken} plateIndex={selectedPlate} onSelectPlate={setSelectedPlate} onViewLayers={() => setViewLayers({ fileId: result?.library_file_id ?? file.id, title: displayName(file) })} />
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
                {/* One row per REAL tray across every unit — the list was hardcoded to four rows,
                    which on a three-unit machine showed AMS 1 only and labelled them ambiguously. */}
                {trays.map((t) => {
                  const empty = !t.trayType;
                  const multi = new Set(trays.map((x) => x.unitId)).size > 1;
                  return (
                    <Tap key={t.globalId} onPress={() => !empty && setSlot(t.globalId)} style={{ flexDirection: 'row', alignItems: 'center', gap: 13, padding: 13, borderRadius: 13, backgroundColor: c.s2, opacity: empty ? 0.4 : 1, borderWidth: slot === t.globalId ? 1.5 : 0, borderColor: c.accent }}>
                      <Swatch value={normColor(t.trayColor)} size={28} radius={8} empty={empty} />
                      <View style={{ flex: 1 }}>
                        <Text style={{ fontWeight: '600', fontSize: 13, color: c.t1 }}>
                          {multi ? `${t.unitLabel} · Slot ${t.localId + 1}` : `Slot ${t.localId + 1}`} · {empty ? 'Empty' : [colorName(normColor(t.trayColor)), t.trayType].filter(Boolean).join(' ')}
                        </Text>
                      </View>
                      {slot === t.globalId && <Feather name="check" size={16} color={c.accent} />}
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
                <Row k="File" v={displayName(file)} />
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
      {viewLayers && <GcodeViewerOverlay key={viewLayers.fileId} src={{ url: client.baseUrl + client.gcodePath(viewLayers.fileId), headers: client.authHeaders() }} title={viewLayers.title} plate={profile.plate} onClose={() => setViewLayers(null)} />}
    </View>
  );
}
