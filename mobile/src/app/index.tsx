import React, { useCallback, useEffect, useMemo, useState } from 'react';
import { Alert, View } from 'react-native';
import { router, useFocusEffect } from 'expo-router';
import { getConfig, type AppConfig } from '@/config/secureConfig';
import { BambuddyClient } from '@/api/bambuddyClient';
import { usePrinterStatus } from '@/realtime/usePrinterStatus';
import { presentDashboard } from '@/dashboard/present';
import { DashboardView, type DashHandlers } from '@/components/DashboardView';
import { c } from '@/theme';

const PRINTER_ID = 1;
const SPEED_LABELS = ['', 'Silent', 'Standard', 'Sport', 'Ludicrous'];

export default function DashboardScreen() {
  const [config, setConfig] = useState<AppConfig | null | undefined>(undefined);
  const [reload, setReload] = useState(0);

  // Re-read config whenever the screen regains focus (e.g. returning from Settings).
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

  if (!config) {
    // loading or redirecting to onboarding
    return <View style={{ flex: 1, backgroundColor: c.bg }} />;
  }
  return <DashboardLive key={reload} config={config} onRetry={() => setReload((r) => r + 1)} />;
}

function DashboardLive({ config, onRetry }: { config: AppConfig; onRetry: () => void }) {
  const client = useMemo(() => new BambuddyClient({ baseUrl: config.baseUrl, apiKey: config.apiKey }), [config]);
  const { status } = usePrinterStatus(client, PRINTER_ID);
  const vm = useMemo(() => presentDashboard(status, Date.now()), [status]);

  // camera snapshot: mint a token, refresh the URL on an interval
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

  const [speedIdx, setSpeedIdx] = useState(2);

  const soon = (what: string) => Alert.alert(what, 'Coming in a later update.');

  const handlers: DashHandlers = {
    onSettings: () => router.push('/settings'),
    onCamera: () => soon('Full-screen camera'),
    onRetry,
    onTab: (tab) => soon(tab[0].toUpperCase() + tab.slice(1)),
    onLight: () => client.setLight(PRINTER_ID, !vm.lightOn).catch((e) => Alert.alert('Light failed', String(e))),
    onPauseResume: () =>
      (vm.isPaused ? client.resume(PRINTER_ID) : client.pause(PRINTER_ID)).catch((e) =>
        Alert.alert('Action failed', String(e)),
      ),
    onStop: () =>
      Alert.alert('Stop print?', 'This cancels the current job. It can’t be undone.', [
        { text: 'Keep printing', style: 'cancel' },
        { text: 'Stop', style: 'destructive', onPress: () => client.stop(PRINTER_ID).catch((e) => Alert.alert('Stop failed', String(e))) },
      ]),
    onSpeed: () => {
      const next = ((speedIdx % 4) + 1) as 1 | 2 | 3 | 4;
      setSpeedIdx(next);
      client.setSpeed(PRINTER_ID, next).catch((e) => Alert.alert('Speed failed', String(e)));
    },
  };

  return <DashboardView vm={{ ...vm, speedLabel: SPEED_LABELS[speedIdx] }} snapshotUri={snapshotUri} h={handlers} />;
}
