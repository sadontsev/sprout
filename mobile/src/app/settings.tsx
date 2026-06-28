import React, { useEffect, useState } from 'react';
import { View, Text, TextInput, Pressable, KeyboardAvoidingView, Platform, ScrollView } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { router } from 'expo-router';
import { Feather } from '@expo/vector-icons';
import { getConfig, setConfig, clearConfig } from '@/config/secureConfig';
import { c, mono } from '@/theme';

const DEFAULT_URL = 'https://bambuddy.example.com';

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

  const canSave = baseUrl.trim().length > 0 && apiKey.trim().length > 6;

  const save = async () => {
    setSaving(true);
    await setConfig({ baseUrl: baseUrl.trim().replace(/\/+$/, ''), apiKey: apiKey.trim() });
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
