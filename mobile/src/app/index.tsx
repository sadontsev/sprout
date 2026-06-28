import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { Alert, View } from 'react-native';
import { router, useFocusEffect } from 'expo-router';
import * as Linking from 'expo-linking';
import { File, Paths } from 'expo-file-system';
import { getConfig, type AppConfig } from '@/config/secureConfig';
import { BambuddyClient } from '@/api/bambuddyClient';
import { usePrinterStatus } from '@/realtime/usePrinterStatus';
import { useCameraStream } from '@/realtime/useCameraStream';
import { useLiveActivity } from '@/liveactivity/useLiveActivity';
import { writeModelThumb } from '@/liveactivity/modelThumb';
import { presentDashboard } from '@/dashboard/present';
import { DashboardView, type DashHandlers } from '@/components/DashboardView';
import { TabBar, type TabKey } from '@/components/TabBar';
import { LibraryView, QueueView, AmsView, PowerView, HistoryView } from '@/components/TabScreens';
import { CameraOverlay, UploadSheet, WizardOverlay } from '@/components/Overlays';
import type { LibraryFile } from '@/api/types';
import { c } from '@/theme';

const PRINTER_ID = 1;
const SPEED_LABELS = ['', 'Silent', 'Standard', 'Sport', 'Ludicrous'];

export default function AppScreen() {
  const [config, setConfig] = useState<AppConfig | null | undefined>(undefined);
  const [reload, setReload] = useState(0);

  useFocusEffect(
    useCallback(() => {
      let active = true;
      getConfig().then((cfg) => active && setConfig(cfg));
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
  const { status } = usePrinterStatus(client, PRINTER_ID);
  const vm = useMemo(() => presentDashboard(status, Date.now()), [status]);

  const [camToken, setCamToken] = useState<string | null>(config.cameraToken ?? null);
  useEffect(() => {
    if (!camToken) client.mintCameraToken().then(setCamToken).catch(() => {});
  }, [client, camToken]);

  // Live Activity model picture: match the active print to a library file by name, then cache its
  // plate thumbnail to the App Group so the widget (separate process) can show it.
  const [modelUri, setModelUri] = useState<string | null>(null);
  const modelForRef = useRef<string | null>(null);
  useEffect(() => {
    const name = vm.kind === 'live' ? status?.subtask_name ?? null : null;
    if (!name) {
      if (modelForRef.current) { modelForRef.current = null; setModelUri(null); }
      return;
    }
    if (modelForRef.current === name) return; // already resolved for this print
    modelForRef.current = name;
    setModelUri(null);
    (async () => {
      try {
        const files = await client.listFiles();
        const m = files.find((f) => (f.filename && f.filename.includes(name)) || (f.print_name && f.print_name.includes(name)));
        if (m?.thumbnail_path) {
          const uri = await writeModelThumb(client, m.id, camToken);
          if (modelForRef.current === name) setModelUri(uri);
        }
      } catch {
        /* no library match -> the activity falls back to the nozzle glyph */
      }
    })();
  }, [vm.kind, status?.subtask_name, client, camToken]);

  // Live Activity queue summary.
  const [queue, setQueue] = useState<{ count: number; next: string | null }>({ count: 0, next: null });
  useEffect(() => {
    const poll = () =>
      client.listQueue().then((items) => {
        const up = items.filter((i) => i.status === 'pending' || i.status === 'queued');
        setQueue({ count: up.length, next: up[0]?.library_file_name ?? up[0]?.archive_name ?? null });
      }).catch(() => {});
    poll();
    const id = setInterval(poll, 15000);
    return () => clearInterval(id);
  }, [client]);

  useLiveActivity(vm, status, { modelUri, queueCount: queue.count, nextName: queue.next });

  const [tick, setTick] = useState(0);
  useEffect(() => {
    const id = setInterval(() => setTick((t) => t + 1), 2000);
    return () => clearInterval(id);
  }, []);
  const snapshotUri = camToken ? `${client.snapshotUrl(PRINTER_ID, camToken)}&_t=${tick}` : null;

  const [tab, setTab] = useState<TabKey>('printer');
  const [overlay, setOverlay] = useState<'camera' | 'upload' | null>(null);
  const [wizardFile, setWizardFile] = useState<LibraryFile | null>(null);
  const [speedIdx, setSpeedIdx] = useState(2);
  const [libKey, setLibKey] = useState(0);

  // Live MJPEG camera stream — mints a token only while the fullscreen camera is open.
  const cameraOpen = overlay === 'camera';
  const { streamUrl, remint } = useCameraStream(client, PRINTER_ID, cameraOpen, 10);

  // Maintenance due/warning rollup for the dashboard chip (invisible when all-clear).
  const [maintAlert, setMaintAlert] = useState<{ due: number; warn: number }>({ due: 0, warn: 0 });
  useEffect(() => {
    const poll = () => client.getMaintenanceSummary().then((s) => setMaintAlert({ due: s.total_due, warn: s.total_warning })).catch(() => {});
    poll();
    const id = setInterval(poll, 60000);
    return () => clearInterval(id);
  }, [client]);

  // Inbound files: when a .3mf/.stl/.gcode is shared/opened into the app, copy it into cache and
  // upload it to the library. The SceneDelegate forwards openURLContexts, so expo-linking sees it.
  const [importing, setImporting] = useState(false);
  useEffect(() => {
    let handledInitial = false;
    const handleUrl = async (url: string | null) => {
      if (!url || importing) return;
      if (!url.startsWith('file://') && !url.startsWith('content://')) return; // ignore our own bambu:// links
      try {
        setImporting(true);
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
        setImporting(false);
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
    onLight: () => client.setLight(PRINTER_ID, !vm.lightOn).catch((e) => Alert.alert('Light failed', String(e))),
    onPauseResume: () =>
      (vm.isPaused ? client.resume(PRINTER_ID) : client.pause(PRINTER_ID)).catch((e) => Alert.alert('Action failed', String(e))),
    onStop: () =>
      Alert.alert('Stop print?', 'This cancels the current job. It can’t be undone.', [
        { text: 'Keep printing', style: 'cancel' },
        { text: 'Stop', style: 'destructive', onPress: () => client.stop(PRINTER_ID).catch((e) => Alert.alert('Stop failed', String(e))) },
      ]),
    onSpeed: () => {
      const nextI = ((speedIdx % 4) + 1) as 1 | 2 | 3 | 4;
      setSpeedIdx(nextI);
      client.setSpeed(PRINTER_ID, nextI).catch((e) => Alert.alert('Speed failed', String(e)));
    },
  };

  return (
    <View style={{ flex: 1, backgroundColor: c.bg }}>
      {tab === 'printer' && <DashboardView vm={{ ...vm, speedLabel: SPEED_LABELS[speedIdx] }} snapshotUri={snapshotUri} h={handlers} maintAlert={maintAlert} />}
      {tab === 'library' && <LibraryView key={libKey} client={client} camToken={camToken} onUpload={() => setOverlay('upload')} onPick={setWizardFile} />}
      {tab === 'queue' && <QueueView client={client} status={status} onBrowse={() => setTab('library')} />}
      {tab === 'ams' && <AmsView client={client} status={status} printerId={PRINTER_ID} />}
      {tab === 'power' && <PowerView client={client} printerId={PRINTER_ID} status={status} />}
      {tab === 'history' && <HistoryView client={client} camToken={camToken} />}

      <TabBar active={tab} onTab={setTab} />

      {overlay === 'camera' && (
        <CameraOverlay client={client} printerId={PRINTER_ID} streamUrl={streamUrl} status={status} onClose={() => setOverlay(null)} onRefresh={remint} />
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
          printerId={PRINTER_ID}
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
