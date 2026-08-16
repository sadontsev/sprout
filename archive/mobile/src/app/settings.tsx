import React, { useEffect, useState } from 'react';
import { View, Text, TextInput, KeyboardAvoidingView, Platform, ScrollView } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { router } from 'expo-router';
import { Feather } from '@expo/vector-icons';
import Constants from 'expo-constants';
import * as Updates from 'expo-updates';
import { getConfig, setConfig, clearConfig, patchConfig } from '@/config/secureConfig';
import { c, mono, useTheme, setTheme, getThemeName, type ThemeName } from '@/theme';
import { Tap, Toggle } from '@/components/anim';
import { sanitizeBaseUrl, sanitizeApiKey, isValidApiKey } from '@/config/sanitize';
import { resolvePushUrl } from '@/config/pushConfig';
import { resolveTexturizeUrl } from '@/config/texturizeConfig';
import { BambuddyClient, classifyConnectError } from '@/api/bambuddyClient';

const DEFAULT_URL = 'https://bambuddy.example.com';

function maskKey(key: string): string {
  if (!key) return '—';
  return key.length > 9 ? `${key.slice(0, 5)}••••${key.slice(-4)}` : key;
}
function hostOf(url: string): string {
  return url.replace(/^https?:\/\//, '').replace(/\/.*$/, '');
}

function Section({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <View style={{ marginTop: 24 }}>
      <Text style={{ fontWeight: '600', fontSize: 11, color: c.t3, letterSpacing: 1, fontFamily: mono, marginBottom: 10, marginLeft: 4 }}>{title}</Text>
      <View style={{ borderRadius: 16, backgroundColor: c.s1, borderWidth: 1, borderColor: c.line, overflow: 'hidden' }}>{children}</View>
    </View>
  );
}
function Row({ label, value, last, valueColor }: { label: string; value: string; last?: boolean; valueColor?: string }) {
  return (
    <View style={{ flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', gap: 12, paddingHorizontal: 16, paddingVertical: 14, borderBottomWidth: last ? 0 : 1, borderBottomColor: c.line }}>
      <Text style={{ fontWeight: '500', fontSize: 13, color: c.t2, flexShrink: 0 }}>{label}</Text>
      <Text numberOfLines={1} style={{ fontWeight: '600', fontSize: 13, color: valueColor ?? c.t1, fontFamily: mono }}>{value}</Text>
    </View>
  );
}

export default function Settings() {
  useTheme(); // re-theme this screen live when the toggle flips
  const [baseUrl, setBaseUrl] = useState(DEFAULT_URL);
  const [apiKey, setApiKey] = useState('');
  const [hasConfig, setHasConfig] = useState(false);
  const [editing, setEditing] = useState(false);
  const [saving, setSaving] = useState(false);
  const [printerName, setPrinterName] = useState<string | null>(null);
  const [pushUrl, setPushUrl] = useState('');
  const [serverPush, setServerPush] = useState(true);
  const [texturizeUrl, setTexturizeUrl] = useState('');
  const [texturize, setTexturize] = useState(true);
  const [adminUser, setAdminUser] = useState('');
  const [adminPw, setAdminPw] = useState('');
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    getConfig().then((cfg) => {
      if (cfg) {
        setBaseUrl(cfg.baseUrl);
        setApiKey(cfg.apiKey);
        setPrinterName(cfg.printerName ?? null);
        setPushUrl(cfg.pushUrl ?? '');
        setServerPush(cfg.serverPush ?? true);
        setTexturizeUrl(cfg.texturizeUrl ?? '');
        setTexturize(cfg.texturize ?? true);
        setAdminUser(cfg.adminUsername ?? '');
        setAdminPw(cfg.adminPassword ?? '');
        setHasConfig(true);
      } else {
        setEditing(true); // first run — go straight to the form
      }
    });
  }, []);

  const canSave = sanitizeBaseUrl(baseUrl).length > 0 && isValidApiKey(apiKey);
  const effPush = resolvePushUrl({ baseUrl, pushUrl, serverPush });
  const pushLabel = !serverPush ? 'Local only' : effPush ? `Server · ${hostOf(effPush)}` : 'Server (set a URL)';
  const effTex = resolveTexturizeUrl({ baseUrl, texturizeUrl, texturize });
  const texLabel = !texturize ? 'Off' : effTex ? `${hostOf(effTex)}` : 'Off (no URL)';
  const theme = getThemeName();
  const appVersion = Constants.expoConfig?.version ?? '1.0.0';

  const save = async () => {
    setError(null);
    setSaving(true);
    const url = sanitizeBaseUrl(baseUrl);
    const key = sanitizeApiKey(apiKey);
    const aUser = adminUser.trim();
    const aPw = adminPw;
    try {
      // Pre-flight: actually reach the server with the entered URL+key before persisting, so a wrong
      // host or a rejected key surfaces here instead of as a silent, eternal "Connecting" dashboard.
      const probeClient = new BambuddyClient({ baseUrl: url, apiKey: key, adminUsername: aUser || undefined, adminPassword: aPw || undefined });
      const fleet = await probeClient.probe();
      // Same pre-flight for the optional admin login — a typo'd password should fail HERE, not later
      // on the first "mark done".
      if (aUser && aPw) await probeClient.verifyAdminLogin();
      const cur = await getConfig();
      // Auto-select a real printer from the fleet (keep the current one if it still exists), so the
      // dashboard never defaults to a guessed id that doesn't exist on this backend. Spread `cur` so
      // editing the connection doesn't wipe the camera token.
      const keepId = cur?.printerId != null && fleet.some((p) => p.id === cur.printerId) ? cur.printerId : fleet[0]?.id;
      const keepName = fleet.find((p) => p.id === keepId)?.name ?? cur?.printerName;
      await setConfig({
        ...cur,
        baseUrl: url,
        apiKey: key,
        pushUrl: pushUrl.trim() || undefined,
        serverPush,
        texturizeUrl: texturizeUrl.trim() || undefined,
        texturize,
        adminUsername: aUser || undefined,
        adminPassword: aPw || undefined,
        theme: cur?.theme ?? theme,
        printerId: keepId ?? cur?.printerId,
        printerName: keepName,
      });
      setSaving(false);
      if (hasConfig) setEditing(false);
      else router.replace('/');
    } catch (e) {
      setSaving(false);
      // Admin-login failures carry their own actionable message — classifyConnectError would misread
      // their HTTP 401 as "API key rejected".
      const msg = e instanceof Error && e.message.startsWith('Admin login failed') ? e.message : classifyConnectError(e).message;
      setError(msg);
    }
  };

  const pickTheme = (name: ThemeName) => {
    setTheme(name);
    void patchConfig({ theme: name });
  };

  const field = {
    backgroundColor: c.s2,
    borderWidth: 1,
    borderColor: c.line,
    borderRadius: 12,
    paddingHorizontal: 14,
    paddingVertical: 13,
    color: c.t1,
    fontSize: 14,
    fontFamily: mono,
  } as const;

  const form = (
    <>
      {!hasConfig && (
        <Text style={{ color: c.t2, fontSize: 14, lineHeight: 20, marginBottom: 20 }}>
          Point the app at your Bambuddy server and paste the app API key. Both are stored only in this device's Keychain.
        </Text>
      )}
      <Text style={{ fontWeight: '600', fontSize: 11, color: c.t3, letterSpacing: 1, fontFamily: mono, marginBottom: 9 }}>BAMBUDDY URL</Text>
      <TextInput value={baseUrl} onChangeText={setBaseUrl} autoCapitalize="none" autoCorrect={false} keyboardType="url" placeholder={DEFAULT_URL} placeholderTextColor={c.t3} style={field} />
      <Text style={{ fontWeight: '600', fontSize: 11, color: c.t3, letterSpacing: 1, fontFamily: mono, marginTop: 18, marginBottom: 9 }}>API KEY</Text>
      {/* Plain (NON-secure) field on purpose. secureTextEntry made iOS treat this as a password/OTP
          field and hijack it with AutoFill: pasted text didn't fire onChangeText (Connect stayed
          grey) and delete wiped the whole value as one autofilled chunk. textContentType="none" +
          autoComplete="off" + no secureTextEntry disables all of that so paste/edit behave normally.
          The key is visible while typing (you're pasting your own key on your own device); it's
          stored in the Keychain. */}
      <TextInput
        value={apiKey}
        onChangeText={setApiKey}
        autoCapitalize="none"
        autoCorrect={false}
        spellCheck={false}
        autoComplete="off"
        textContentType="none"
        placeholder="bb_…"
        placeholderTextColor={c.t3}
        style={field}
      />
      {/* PUSH & LIVE ACTIVITIES — each person runs their own Trellis next to their own Bambuddy. */}
      <View style={{ flexDirection: 'row', alignItems: 'center', gap: 14, marginTop: 24 }}>
        <View style={{ flex: 1 }}>
          <Text style={{ fontWeight: '600', fontSize: 14, color: c.t1 }}>Background push</Text>
          <Text style={{ marginTop: 4, fontWeight: '500', fontSize: 11.5, color: c.t3, lineHeight: 16 }}>
            {serverPush
              ? 'Lock-screen Live Activities keep updating after the app closes, plus print-done / error alerts. Needs a Trellis server.'
              : 'Live Activities update only while the app is open — no lock-screen alerts, no server needed.'}
          </Text>
        </View>
        <Toggle value={serverPush} onChange={setServerPush} />
      </View>
      {serverPush && (
        <>
          <Text style={{ fontWeight: '600', fontSize: 11, color: c.t3, letterSpacing: 1, fontFamily: mono, marginTop: 18, marginBottom: 9 }}>PUSH SERVER (Trellis)</Text>
          <TextInput
            value={pushUrl}
            onChangeText={setPushUrl}
            autoCapitalize="none"
            autoCorrect={false}
            autoComplete="off"
            keyboardType="url"
            placeholder={resolvePushUrl({ baseUrl: sanitizeBaseUrl(baseUrl) }) ?? 'https://lapush.your-host…'}
            placeholderTextColor={c.t3}
            style={field}
          />
          <Text style={{ marginTop: 7, fontSize: 11, color: c.t3, lineHeight: 15 }}>
            Your own Trellis URL. Leave blank to derive it from the Bambuddy host (bambuddy.→lapush.); set it if Trellis runs elsewhere.
          </Text>
        </>
      )}
      {/* TEXTURIZER (optional sidecar) — same pattern as push: toggle + optional URL; the Shell
          additionally health-probes before enabling, so a missing sidecar never breaks the app. */}
      <View style={{ flexDirection: 'row', alignItems: 'center', gap: 14, marginTop: 24 }}>
        <View style={{ flex: 1 }}>
          <Text style={{ fontWeight: '600', fontSize: 14, color: c.t1 }}>Model texturizer</Text>
          <Text style={{ marginTop: 4, fontWeight: '500', fontSize: 11.5, color: c.t3, lineHeight: 16 }}>
            {texturize
              ? 'Bake surface patterns onto STLs and restyle library previews. Needs the stl-texturize sidecar.'
              : 'Off — no texturize actions; library previews come straight from Bambuddy.'}
          </Text>
        </View>
        <Toggle value={texturize} onChange={setTexturize} />
      </View>
      {texturize && (
        <>
          <Text style={{ fontWeight: '600', fontSize: 11, color: c.t3, letterSpacing: 1, fontFamily: mono, marginTop: 18, marginBottom: 9 }}>TEXTURIZE SERVER</Text>
          <TextInput
            value={texturizeUrl}
            onChangeText={setTexturizeUrl}
            autoCapitalize="none"
            autoCorrect={false}
            autoComplete="off"
            keyboardType="url"
            placeholder={resolveTexturizeUrl({ baseUrl: sanitizeBaseUrl(baseUrl) }) ?? 'https://texturize.your-host…'}
            placeholderTextColor={c.t3}
            style={field}
          />
          <Text style={{ marginTop: 7, fontSize: 11, color: c.t3, lineHeight: 15 }}>
            Your stl-texturize URL. Leave blank to derive it from the Bambuddy host (bambuddy.→texturize.); the app checks its health before enabling.
          </Text>
        </>
      )}
      {/* ADMIN (optional) — Bambuddy refuses API keys on admin endpoints (maintenance "mark done",
          settings writes) no matter the key's permissions; those need a JWT from this login. */}
      <Text style={{ fontWeight: '600', fontSize: 11, color: c.t3, letterSpacing: 1, fontFamily: mono, marginTop: 24, marginBottom: 4 }}>ADMIN LOGIN (OPTIONAL)</Text>
      <Text style={{ fontSize: 11.5, lineHeight: 16, color: c.t3, marginBottom: 9 }}>
        Unlocks admin actions like marking maintenance done — Bambuddy doesn’t allow API keys for those. Stored only in the Keychain.
      </Text>
      <TextInput value={adminUser} onChangeText={setAdminUser} autoCapitalize="none" autoCorrect={false} autoComplete="off" textContentType="none" placeholder="admin username" placeholderTextColor={c.t3} style={field} />
      <TextInput value={adminPw} onChangeText={setAdminPw} autoCapitalize="none" autoCorrect={false} spellCheck={false} autoComplete="off" textContentType="none" placeholder="admin password" placeholderTextColor={c.t3} style={{ ...field, marginTop: 10 }} />
      {error && (
        <View style={{ marginTop: 20, padding: 13, borderRadius: 12, backgroundColor: c.s2, borderWidth: 1, borderColor: c.error }}>
          <Text style={{ color: c.error, fontSize: 13, lineHeight: 18, fontWeight: '500' }}>{error}</Text>
        </View>
      )}
      <View style={{ flexDirection: 'row', gap: 12, marginTop: 24 }}>
        {hasConfig && (
          <Tap onPress={() => setEditing(false)} style={{ paddingHorizontal: 22, height: 54, borderRadius: 16, backgroundColor: c.s3, alignItems: 'center', justifyContent: 'center' }}>
            <Text style={{ fontWeight: '600', fontSize: 16, color: c.t1 }}>Cancel</Text>
          </Tap>
        )}
        <Tap onPress={save} disabled={!canSave || saving} style={{ flex: 1, height: 54, borderRadius: 16, backgroundColor: canSave ? c.accent : c.s3, alignItems: 'center', justifyContent: 'center' }}>
          <Text style={{ fontWeight: '700', fontSize: 16, color: canSave ? c.accentInk : c.t3 }}>{saving ? 'Connecting…' : hasConfig ? 'Save' : 'Connect'}</Text>
        </Tap>
      </View>
    </>
  );

  return (
    <SafeAreaView style={{ flex: 1, backgroundColor: c.bg }}>
      <KeyboardAvoidingView behavior={Platform.OS === 'ios' ? 'padding' : undefined} style={{ flex: 1 }}>
        <ScrollView contentContainerStyle={{ padding: 24, paddingBottom: 48 }} keyboardShouldPersistTaps="handled" showsVerticalScrollIndicator={false}>
          <View style={{ flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center', marginBottom: 8 }}>
            <Text style={{ fontWeight: '700', fontSize: 30, color: c.t1, letterSpacing: -0.8 }}>{hasConfig ? 'Settings' : 'Connect'}</Text>
            {hasConfig && (
              <Tap onPress={() => router.back()} hitSlop={12} style={{ width: 38, height: 38, borderRadius: 19, backgroundColor: c.s2, alignItems: 'center', justifyContent: 'center' }}>
                <Feather name="x" size={20} color={c.t2} />
              </Tap>
            )}
          </View>

          {editing ? (
            <View style={{ marginTop: 16 }}>{form}</View>
          ) : (
            <>
              {/* CONNECTION */}
              <Section title="CONNECTION">
                <View style={{ flexDirection: 'row', alignItems: 'center', gap: 10, paddingHorizontal: 16, paddingVertical: 14, borderBottomWidth: 1, borderBottomColor: c.line }}>
                  <View style={{ width: 8, height: 8, borderRadius: 4, backgroundColor: c.running, shadowColor: c.running, shadowOpacity: 0.8, shadowRadius: 6 }} />
                  <Text style={{ flex: 1, fontWeight: '600', fontSize: 14, color: c.t1 }}>Configured</Text>
                  <Tap onPress={() => setEditing(true)} hitSlop={8} style={{ flexDirection: 'row', alignItems: 'center', gap: 5 }}>
                    <Feather name="edit-2" size={13} color={c.accent} />
                    <Text style={{ fontWeight: '600', fontSize: 13, color: c.accent }}>Edit</Text>
                  </Tap>
                </View>
                <Row label="Server" value={hostOf(baseUrl)} />
                <Row label="API key" value={maskKey(apiKey)} valueColor={c.t3} />
                <Row label="Admin login" value={adminUser && adminPw ? adminUser : 'Off'} valueColor={c.t3} />
                <Row label="Live Activities" value={pushLabel} valueColor={c.t3} />
                <Row label="Texturizer" value={texLabel} valueColor={c.t3} last />
              </Section>

              {/* APPEARANCE */}
              <View style={{ marginTop: 24 }}>
                <Text style={{ fontWeight: '600', fontSize: 11, color: c.t3, letterSpacing: 1, fontFamily: mono, marginBottom: 10, marginLeft: 4 }}>APPEARANCE</Text>
                <View style={{ flexDirection: 'row', gap: 4, padding: 4, borderRadius: 13, backgroundColor: c.s2 }}>
                  {(['dark', 'light'] as ThemeName[]).map((name) => {
                    const on = theme === name;
                    return (
                      <Tap key={name} onPress={() => pickTheme(name)} style={{ flex: 1, height: 40, borderRadius: 10, backgroundColor: on ? c.s4 : 'transparent', alignItems: 'center', justifyContent: 'center' }}>
                        <Text style={{ fontWeight: '600', fontSize: 14, color: on ? c.t1 : c.t2 }}>{name === 'dark' ? 'Dark' : 'Light'}</Text>
                      </Tap>
                    );
                  })}
                </View>
              </View>

              {/* ABOUT */}
              <Section title="ABOUT">
                <Row label="App version" value={appVersion} />
                {/* Which JS bundle is actually running: the OTA update id (short), or the build's
                    embedded bundle. This is the ground truth for "did the OTA land?" confusion. */}
                <Row label="Update" value={Updates.updateId ? Updates.updateId.slice(0, 8) : 'embedded'} />
                <Row label="Printer" value={printerName ?? '—'} last />
              </Section>

              <Tap
                onPress={async () => {
                  await clearConfig();
                  router.replace('/settings');
                }}
                style={{ marginTop: 24, height: 50, borderRadius: 14, borderWidth: 1, borderColor: c.line2, alignItems: 'center', justifyContent: 'center' }}>
                <Text style={{ color: c.error, fontSize: 15, fontWeight: '600' }}>Sign out · clear key</Text>
              </Tap>
            </>
          )}
        </ScrollView>
      </KeyboardAvoidingView>
    </SafeAreaView>
  );
}
