import React from 'react';
import { View, Text, Pressable } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { Feather } from '@expo/vector-icons';
import { c } from '@/theme';

export type TabKey = 'printer' | 'library' | 'queue' | 'ams' | 'power';

const TABS: [TabKey, string, keyof typeof Feather.glyphMap][] = [
  ['printer', 'Printer', 'cpu'],
  ['library', 'Files', 'folder'],
  ['queue', 'Queue', 'list'],
  ['ams', 'AMS', 'grid'],
  ['power', 'Power', 'power'],
];

export function TabBar({ active, onTab }: { active: TabKey; onTab: (t: TabKey) => void }) {
  const insets = useSafeAreaInsets();
  return (
    <View
      style={{
        position: 'absolute',
        left: 0,
        right: 0,
        bottom: 0,
        paddingTop: 9,
        paddingBottom: insets.bottom || 12,
        backgroundColor: c.s1,
        borderTopWidth: 1,
        borderTopColor: c.line,
        flexDirection: 'row',
      }}>
      {TABS.map(([key, label, icon]) => {
        const on = key === active;
        return (
          <Pressable
            key={key}
            onPress={() => onTab(key)}
            style={({ pressed }) => [{ flex: 1, alignItems: 'center', gap: 4, paddingVertical: 5 }, pressed && { opacity: 0.6 }]}>
            <Feather name={icon} size={23} color={on ? c.accent : c.t3} />
            <Text style={{ fontWeight: '600', fontSize: 10, color: on ? c.accent : c.t3 }}>{label}</Text>
          </Pressable>
        );
      })}
    </View>
  );
}
