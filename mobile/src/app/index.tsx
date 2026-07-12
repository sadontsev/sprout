import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { Alert, View } from 'react-native';
import { router, useFocusEffect } from 'expo-router';
import * as Linking from 'expo-linking';
import { File, Paths } from 'expo-file-system';
import { getConfig, patchConfig, type AppConfig } from '@/config/secureConfig';
import { BambuddyClient } from '@/api/bambuddyClient';
import { usePrinterStatus } from '@/realtime/usePrinterStatus';
import { useCameraStream } from '@/realtime/useCameraStream';
import { usePrinterActivities, type ActivityEntry } from '@/liveactivity/useLiveActivity';
import { useStatusNotifications } from '@/notifications/useStatusNotifications';
import { presentDashboard, type DashVM } from '@/dashboard/present';
import { printerProfile } from '@/printers/profile';
import { DashboardView, type DashHandlers, type FleetEntry } from '@/components/DashboardView';
import { TabBar, type TabKey } from '@/components/TabBar';
import { LibraryView, QueueView, AmsView, PowerView, HistoryView } from '@/components/TabScreens';
import { CameraOverlay, UploadSheet, WizardOverlay } from '@/components/Overlays';
import { FadeRise } from '@/components/anim';
import type { LibraryFile, Printer } from '@/api/types';
import { c, setTheme, useTheme } from '@/theme';

const CAM_TOKEN_TTL_MS = 55 * 60 * 1000; // backend camera tokens live 60 min; refresh early

export default function AppScreen() {
  const [config, setConfig] = useState<AppConfig | null | undefined>(undefined);
  const [reload, setReload] = useState(0);
  useTheme(); // re-render the whole app when the theme is toggled (Settings)

  useFocusEffect(
    useCallback(() => {
      let active = true;
      // A Keychain read failure must land on the onboarding screen, not an eternal blank gate.
      getConfig().catch(() => null).then((cfg) => {
        if (!active) return;
        if (cfg) setTheme(cfg.theme ?? 'dark');
        setConfig(cfg);
      });
      return () => {
        active = false;
      };
    }, [reload]),
  );

  useEffect(() => {
    if (config === null) router.replace('/settings');
  }, [config]);

  if (!config) return <View style={{ flex: 1, backgroundColor: c.bg }} />;
  return <Shell key={reload} config={config} onRetry={() => setReload((r) => r + 1)} />;
}

function Shell({ config, onRetry }: { config: AppConfig; onRetry: () => void }) {
  const client = useMemo(() => new BambuddyClient({ baseUrl: config.baseUrl, apiKey: config.apiKey }), [config]);

  // ---- Printer fleet + selection (persisted) ----
  const [printers, setPrinters] = useState<Printer[] | null>(null);
  const [printerId, setPrinterId] = useState<number>(config.printerId ?? 1);
  useEffect(() => {
    let alive = true;
    const load = () =>
      client
        .listPrinters()
        .then((ps) => alive && setPrinters(ps.filter((p) => p.is_active)))
        .catch(() => alive && setPrinters((prev) => prev ?? null)); // keep retrying below
    load();
    // Retry until loaded, then refresh occasionally — a one-shot fetch would hide the fleet
    // switcher forever after a single launch-time failure (and never see newly added printers).
    const id = setInterval(load, 30_000);
    return () => {
      alive = false;
      clearInterval(id);
    };
  }, [client]);
  const missedPolls = useRef(0);
  useEffect(() => {
    // If the persisted selection vanished from the backend (printer sold/removed), fall back to the
    // first printer AND persist it — otherwise every cold launch re-lives the ghost id until the
    // fleet list loads. Heal only on the SECOND consecutive fleet response missing it: a single
    // absence can be transient (is_active toggled during maintenance, a flaky list response), and
    // persisting on a blip would permanently rewrite the stored selection. Until then the selected
    // printer just shows offline — which is true. Add/remove is picked up by the 30s refresh above.
    if (!printers?.length) return;
    if (printers.some((p) => p.id === printerId)) {
      missedPolls.current = 0;
      return;
    }
    missedPolls.current += 1;
    if (missedPolls.current < 2) return;
    missedPolls.current = 0;
    const next = printers[0];
    setPrinterId(next.id);
    void patchConfig({ printerId: next.id, printerName: next.name });
  }, [printers, printerId]);
  const printer = printers?.find((p) => p.id === printerId) ?? null;
  const profile = printerProfile(printer);
  const selectPrinter = (id: number) => {
    setPrinterId(id);
    const name = printers?.find((p) => p.id === id)?.name;
    void patchConfig({ printerId: id, printerName: name });
  };

  const { status, statuses } = usePrinterStatus(client, printerId);
  const vm = useMemo(() => presentDashboard(status, Date.now()), [status]);

  // Fleet rows for the switcher: every printer with its live state (the shared WS carries all).
  const fleet: FleetEntry[] = useMemo(
    () =>
      (printers ?? []).map((p) => {
        const pvm = presentDashboard(statuses[p.id] ?? null, Date.now());
        return { printer: p, kind: pvm.kind, stateLabel: pvm.stateLabel, stateColor: pvm.stateColor, progressInt: pvm.progressInt };
      }),
    [printers, statuses],
  );

  // ---- Camera token: mint, auto-refresh before the 60-min TTL, retry failed mints ----
  const [camToken, setCamToken] = useState<string | null>(config.cameraToken ?? null);
  const camMintedAt = useRef(0);
  useEffect(() => {
    let alive = true;
    const mint = () =>
      client.mintCameraToken().then((t) => {
        if (!alive) return;
        camMintedAt.current = Date.now();
        setCamToken(t);
      }).catch(() => {});
    if (!camToken) void mint();
    const id = setInterval(() => {
      if (!camToken || Date.now() - camMintedAt.current > CAM_TOKEN_TTL_MS) void mint();
    }, 60_000);
    return () => {
      alive = false;
      clearInterval(id);
    };
  }, [client, camToken]);

  // ---- Live Activities: one lock-screen card per printer that's actively printing ----
  // Every printer in the fleet gets an entry; the hook starts/updates/ends a card per printer based
  // on its live state, so A1 and H2C show as two separate cards on the lock screen.
  const activityEntries: ActivityEntry[] = useMemo(
    () =>
      (printers ?? []).map((p) => ({
        printerId: p.id,
        printerName: p.name,
        status: statuses[p.id] ?? null,
        vm: p.id === printerId ? vm : presentDashboard(statuses[p.id] ?? null, Date.now()),
      })),
    [printers, statuses, printerId, vm],
  );
  // la-push endpoint: explicit config override, else derive from the bambuddy host (bambuddy.* -> lapush.*).
  const pushUrl = useMemo(
    () => config.pushUrl ?? (config.baseUrl.includes('bambuddy.') ? config.baseUrl.replace('bambuddy.', 'lapush.') : null),
    [config.pushUrl, config.baseUrl],
  );
  usePrinterActivities(activityEntries, pushUrl);
  useStatusNotifications(pushUrl); // print-done / error banners via la-push

  const [tab, setTab] = useState<TabKey>('printer');
  const [overlay, setOverlay] = useState<'camera' | 'upload' | null>(null);
  const [wizardFile, setWizardFile] = useState<LibraryFile | null>(null);
  const [libKey, setLibKey] = useState(0);

  // Speed: the printer's real speed_level drives the UI; a short-lived optimistic override bridges
  // the gap between tapping a mode and the next status frame reflecting it.
  const [speedOverride, setSpeedOverride] = useState<number | null>(null);
  useEffect(() => {
    if (speedOverride != null && vm.speedIdx === speedOverride) setSpeedOverride(null);
  }, [vm.speedIdx, speedOverride]);
  useEffect(() => {
    if (speedOverride == null) return;
    const t = setTimeout(() => setSpeedOverride(null), 15000);
    return () => clearTimeout(t);
  }, [speedOverride]);
  const speedIdx = speedOverride ?? vm.speedIdx;

  // Live MJPEG camera stream — mints a token only while the fullscreen camera is open.
  const cameraOpen = overlay === 'camera';
  const { streamUrl, remint } = useCameraStream(client, printerId, cameraOpen, 10);

  // Dashboard snapshot tile (1 frame / 2s). Paused while the fullscreen stream is open (the two
  // would contend for the single on-demand camera) and while the dashboard tab is hidden (it
  // stays mounted — see the render below — so the interval would otherwise poll unseen).
  const [tick, setTick] = useState(0);
  useEffect(() => {
    if (cameraOpen || tab !== 'printer') return;
    const id = setInterval(() => setTick((t) => t + 1), 2000);
    return () => clearInterval(id);
  }, [cameraOpen, tab]);
  const snapshotUri = camToken && !cameraOpen ? `${client.snapshotUrl(printerId, camToken)}&_t=${tick}` : null;

  // Maintenance due/warning rollup for the dashboard chip — scoped to the SELECTED printer.
  const [maintAlert, setMaintAlert] = useState<{ due: number; warn: number }>({ due: 0, warn: 0 });
  useEffect(() => {
    setMaintAlert({ due: 0, warn: 0 });
    const poll = () =>
      client.getMaintenance(printerId).then((m) => setMaintAlert({ due: m.due_count, warn: m.warning_count })).catch(() => {});
    poll();
    const id = setInterval(poll, 60000);
    return () => clearInterval(id);
  }, [client, printerId]);

  // Inbound files: when a .3mf/.stl/.gcode is shared/opened into the app, copy it into cache and
  // upload it to the library. The SceneDelegate forwards openURLContexts, so expo-linking sees it.
  const importingRef = useRef(false);
  useEffect(() => {
    let handledInitial = false;
    const handleUrl = async (url: string | null) => {
      if (!url || importingRef.current) return;
      if (!url.startsWith('file://') && !url.startsWith('content://')) return; // ignore our own bambu:// links
      try {
        importingRef.current = true;
        const src = new File(url);
        const name = src.name || `import-${Date.now()}.3mf`;
        const dest = new File(Paths.cache, name);
        if (dest.exists) dest.delete();
        src.copy(dest);
        await client.uploadFile(dest.uri, name);
        setLibKey((k) => k + 1);
        setTab('library');
        Alert.alert('Added to library', name);
      } catch (e) {
        Alert.alert('Couldn’t import file', String(e));
      } finally {
        importingRef.current = false;
      }
    };
    Linking.getInitialURL().then((url) => {
      handledInitial = true;
      void handleUrl(url);
    });
    const sub = Linking.addEventListener('url', ({ url }) => {
      if (handledInitial) void handleUrl(url);
    });
    return () => sub.remove();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [client]);

  const handlers: DashHandlers = {
    onSettings: () => router.push('/settings'),
    onCamera: () => setOverlay('camera'),
    onRetry,
    onTab: (t) => setTab(t as TabKey),
    onSelectPrinter: selectPrinter,
    onLight: () => client.setLight(printerId, !vm.lightOn).catch((e) => Alert.alert('Light failed', String(e))),
    onPauseResume: () =>
      (vm.isPaused ? client.resume(printerId) : client.pause(printerId)).catch((e) => Alert.alert('Action failed', String(e))),
    onStop: () =>
      Alert.alert('Stop print?', 'This cancels the current job. It can’t be undone.', [
        { text: 'Keep printing', style: 'cancel' },
        { text: 'Stop', style: 'destructive', onPress: () => client.stop(printerId).catch((e) => Alert.alert('Stop failed', String(e))) },
      ]),
    onSpeedSet: (i: number) => {
      const mode = i as 1 | 2 | 3 | 4;
      setSpeedOverride(mode);
      client.setSpeed(printerId, mode).catch((e) => {
        setSpeedOverride(null); // roll back the optimistic label
        Alert.alert('Speed failed', String(e));
      });
    },
    onHmsClear: () =>
      client.clearHms(printerId).catch((e) => Alert.alert('Couldn’t clear', String(e))),
    onPlateCleared: () =>
      client.queueResume(printerId).then(() => Alert.alert('Queue resumed', 'Next job can start.')).catch((e) => Alert.alert('Couldn’t resume queue', String(e))),
    onPrintAgain: () => {
      const archiveId = status?.current_archive_id;
      if (archiveId == null) {
        setTab('library');
        return;
      }
      Alert.alert('Print this again?', 'The finished job goes back into the queue.', [
        { text: 'Cancel', style: 'cancel' },
        {
          text: 'Print again',
          onPress: () =>
            client.reprint(archiveId, printerId).then(() => setTab('queue')).catch((e) => Alert.alert('Couldn’t reprint', String(e))),
        },
      ]);
    },
  };

  return (
    <View style={{ flex: 1, backgroundColor: c.bg }}>
      {/* The live dashboard is a dense tree of looping reanimated animations. Unmounting it
          mid-flight on a tab switch hits a reanimated-4 New-Arch teardown race (upstream #9402 /
          #9293: crash or whole-app freeze), so it stays mounted and is HIDDEN instead. */}
      <View style={{ flex: 1, display: tab === 'printer' ? 'flex' : 'none' }}>
        <DashboardView vm={vm} snapshotUri={snapshotUri} h={handlers} maintAlert={maintAlert} speedIdx={speedIdx} printer={printer} fleet={fleet} />
      </View>
      {tab !== 'printer' && (
        <FadeRise key={tab} dy={8} duration={300} style={{ flex: 1 }}>
          {tab === 'library' && <LibraryView key={libKey} client={client} camToken={camToken} printerId={printerId} onUpload={() => setOverlay('upload')} onPick={setWizardFile} />}
          {tab === 'queue' && <QueueView client={client} status={status} printerId={printerId} printers={printers ?? []} onBrowse={() => setTab('library')} />}
          {tab === 'ams' && <AmsView client={client} status={status} printerId={printerId} amsLabel={profile.amsLabel} />}
          {tab === 'power' && <PowerView client={client} printerId={printerId} status={status} />}
          {tab === 'history' && <HistoryView client={client} camToken={camToken} printerId={printerId} />}
        </FadeRise>
      )}

      <TabBar active={tab} onTab={setTab} />

      {overlay === 'camera' && (
        <CameraOverlay streamUrl={streamUrl} status={status} cameraHint={profile.cameraHint} onClose={() => setOverlay(null)} onRefresh={remint} />
      )}
      {overlay === 'upload' && (
        <UploadSheet client={client} onClose={() => setOverlay(null)} onUploaded={() => setLibKey((k) => k + 1)} />
      )}
      {wizardFile && (
        <WizardOverlay
          client={client}
          file={wizardFile}
          camToken={camToken}
          status={status}
          printerId={printerId}
          printer={printer}
          onClose={() => setWizardFile(null)}
          onStarted={() => {
            setWizardFile(null);
            setTab('printer');
          }}
        />
      )}
    </View>
  );
}
