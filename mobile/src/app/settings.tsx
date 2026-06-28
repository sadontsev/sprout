import React, { useEffect, useState } from 'react';
import { View, Text, TextInput, Pressable, KeyboardAvoidingView, Platform, ScrollView } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { router } from 'expo-router';
import { Feather } from '@expo/vector-icons';
import { getConfig, setConfig, clearConfig } from '@/config/secureConfig';
import { c, mono } from '@/theme';

const DEFAULT_URL = 'https://bambuddy.example.com';

/** Trim whitespace and any stray trailing slash; keep scheme + host. */
export function sanitizeBaseUrl(raw: string): string {
  return raw.trim().replace(/\s+/g, '').replace(/\/+$/, '');
}

/**
 * API keys are `bb_` + base62 ([A-Za-z0-9]). Pasting often appends a stray trailing char —
 * whitespace, a newline, or a `%` (zsh's no-newline EOL marker / a URL-encode artifact). Trim both
 * ends, then strip any leading/trailing chars that aren't valid key characters (keep `_` for the
 * `bb_` prefix). Interior characters are never touched, so a legitimate key can't be corrupted.
 */
export function sanitizeApiKey(raw: string): string {
  return raw.trim().replace(/^[^A-Za-z0-9_]+/, '').replace(/[^A-Za-z0-9_]+$/, '');
}

export default function Settings() {
  const [baseUrl, setBaseUrl] = useState(DEFAULT_URL);
  const [apiKey, setApiKey] = useState('');
  const [hasConfig, setHasConfig] = useState(false);
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    getConfig().then((cfg) => {
      if (cfg) {
        setBaseUrl(cfg.baseUrl);
        setApiKey(cfg.apiKey);
        setHasConfig(true);
      }
    });
  }, []);

  const canSave = sanitizeBaseUrl(baseUrl).length > 0 && /^bb_[A-Za-z0-9]{6,}$/.test(sanitizeApiKey(apiKey));

  const save = async () => {
    setSaving(true);
    await setConfig({ baseUrl: sanitizeBaseUrl(baseUrl), apiKey: sanitizeApiKey(apiKey) });
    setSaving(false);
    router.replace('/');
  };

  const field = {
    backgroundColor: c.s1,
    borderWidth: 1,
    borderColor: c.line,
    borderRadius: 14,
    paddingHorizontal: 15,
    paddingVertical: 14,
    color: c.t1,
    fontSize: 15,
    fontFamily: mono,
  } as const;

  return (
    <SafeAreaView style={{ flex: 1, backgroundColor: c.bg }}>
      <KeyboardAvoidingView behavior={Platform.OS === 'ios' ? 'padding' : undefined} style={{ flex: 1 }}>
        <ScrollView contentContainerStyle={{ padding: 24 }} keyboardShouldPersistTaps="handled">
          <View style={{ flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center', marginBottom: 28 }}>
            <Text style={{ fontWeight: '700', fontSize: 28, color: c.t1, letterSpacing: -0.6 }}>
              {hasConfig ? 'Settings' : 'Connect'}
            </Text>
            {hasConfig && (
              <Pressable onPress={() => router.back()} hitSlop={12}>
                <Feather name="x" size={24} color={c.t2} />
              </Pressable>
            )}
          </View>

          {!hasConfig && (
            <Text style={{ color: c.t2, fontSize: 14, lineHeight: 20, marginBottom: 24 }}>
              Point the app at your Bambuddy server and paste the app API key. Both are stored only in this device's Keychain.
            </Text>
          )}

          <Text style={{ fontWeight: '600', fontSize: 11, color: c.t3, letterSpacing: 1, fontFamily: mono, marginBottom: 9 }}>
            BAMBUDDY URL
          </Text>
          <TextInput
            value={baseUrl}
            onChangeText={setBaseUrl}
            autoCapitalize="none"
            autoCorrect={false}
            keyboardType="url"
            placeholder={DEFAULT_URL}
            placeholderTextColor={c.t3}
            style={field}
          />

          <Text style={{ fontWeight: '600', fontSize: 11, color: c.t3, letterSpacing: 1, fontFamily: mono, marginTop: 20, marginBottom: 9 }}>
            API KEY
          </Text>
          <TextInput
            value={apiKey}
            onChangeText={setApiKey}
            autoCapitalize="none"
            autoCorrect={false}
            secureTextEntry
            placeholder="bb_…"
            placeholderTextColor={c.t3}
            style={field}
          />

          <Pressable
            onPress={save}
            disabled={!canSave || saving}
            style={({ pressed }) => ({
              marginTop: 28,
              height: 54,
              borderRadius: 16,
              backgroundColor: canSave ? c.accent : c.s3,
              alignItems: 'center',
              justifyContent: 'center',
              opacity: pressed ? 0.7 : 1,
            })}>
            <Text style={{ fontWeight: '700', fontSize: 16, color: canSave ? c.accentInk : c.t3 }}>
              {saving ? 'Saving…' : hasConfig ? 'Save' : 'Connect'}
            </Text>
          </Pressable>

          {hasConfig && (
            <Pressable
              onPress={async () => {
                await clearConfig();
                router.replace('/settings');
              }}
              style={{ marginTop: 16, alignItems: 'center' }}>
              <Text style={{ color: c.error, fontSize: 14, fontWeight: '600' }}>Sign out / clear key</Text>
            </Pressable>
          )}
        </ScrollView>
      </KeyboardAvoidingView>
    </SafeAreaView>
  );
}
