import React, { useCallback, useEffect, useMemo, useState } from 'react';
import { Alert, View } from 'react-native';
import { router, useFocusEffect } from 'expo-router';
import { getConfig, type AppConfig } from '@/config/secureConfig';
import { BambuddyClient } from '@/api/bambuddyClient';
import { usePrinterStatus } from '@/realtime/usePrinterStatus';
import { presentDashboard } from '@/dashboard/present';
import { DashboardView, type DashHandlers } from '@/components/DashboardView';
import { TabBar, type TabKey } from '@/components/TabBar';
import { LibraryView, QueueView, AmsView, PowerView } from '@/components/TabScreens';
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
  const [tick, setTick] = useState(0);
  useEffect(() => {
    if (!camToken) client.mintCameraToken().then(setCamToken).catch(() => {});
  }, [client, camToken]);
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
      {tab === 'printer' && <DashboardView vm={{ ...vm, speedLabel: SPEED_LABELS[speedIdx] }} snapshotUri={snapshotUri} h={handlers} />}
      {tab === 'library' && <LibraryView key={libKey} client={client} onUpload={() => setOverlay('upload')} onPick={setWizardFile} />}
      {tab === 'queue' && <QueueView client={client} status={status} onBrowse={() => setTab('library')} />}
      {tab === 'ams' && <AmsView client={client} status={status} printerId={PRINTER_ID} />}
      {tab === 'power' && <PowerView client={client} printerId={PRINTER_ID} />}

      <TabBar active={tab} onTab={setTab} />

      {overlay === 'camera' && (
        <CameraOverlay snapshotUri={snapshotUri} status={status} onClose={() => setOverlay(null)} onRefresh={() => setTick((t) => t + 1)} />
      )}
      {overlay === 'upload' && (
        <UploadSheet client={client} onClose={() => setOverlay(null)} onUploaded={() => setLibKey((k) => k + 1)} />
      )}
      {wizardFile && (
        <WizardOverlay
          client={client}
          file={wizardFile}
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
