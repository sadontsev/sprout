import React from 'react';
import { View, Text } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { Feather } from '@expo/vector-icons';
import { c } from '@/theme';
import { NozzleIcon } from './NozzleIcon';
import { Tap } from './anim';

export type TabKey = 'printer' | 'library' | 'queue' | 'ams' | 'power' | 'history';

const TABS: [TabKey, string, keyof typeof Feather.glyphMap][] = [
  ['printer', 'Printer', 'cpu'],
  ['library', 'Files', 'folder'],
  ['queue', 'Queue', 'list'],
  ['ams', 'Hardware', 'box'],
  ['power', 'Power', 'power'],
  ['history', 'History', 'clock'],
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
          <Tap
            key={key}
            onPress={() => onTab(key)}
            scale={0.9}
            style={{ flex: 1, alignItems: 'center', gap: 4, paddingVertical: 5, paddingHorizontal: 2 }}>
            {key === 'printer' ? (
              <NozzleIcon color={on ? c.accent : c.t3} size={22} />
            ) : (
              <Feather name={icon} size={21} color={on ? c.accent : c.t3} />
            )}
            <Text numberOfLines={1} style={{ fontWeight: '600', fontSize: 10, color: on ? c.accent : c.t3 }}>{label}</Text>
          </Tap>
        );
      })}
    </View>
  );
}
