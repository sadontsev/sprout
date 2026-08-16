import React from 'react';
import { View, Text, ScrollView } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { Feather } from '@expo/vector-icons';
import { c, mono, shadow1 } from '@/theme';
import { Tap, FadeRise } from './anim';
import type { AlertVM, AlertActionVM } from '@/alerts/present';

/**
 * The full alert list, opened from a single dashboard row.
 *
 * Deliberately NOT on the dashboard: with three HMS notices plus a plate prompt, inline cards pushed
 * the actual print state off the screen. The dashboard keeps one summary row; everything explanatory
 * — and every action — lives here.
 */
export function AlertsOverlay({
  alerts,
  onAction,
  onClose,
}: {
  alerts: AlertVM[];
  onAction: (a: AlertVM, act: AlertActionVM) => void;
  onClose: () => void;
}) {
  const insets = useSafeAreaInsets();
  const toneOf = (level: AlertVM['level']) =>
    level === 'error' ? c.error : level === 'warning' ? c.heating : c.accent;
  const dimOf = (level: AlertVM['level']) =>
    level === 'error' ? c.errorDim : level === 'warning' ? c.heatingDim : c.accentDim;

  return (
    <View style={{ position: 'absolute', inset: 0, backgroundColor: c.bg, zIndex: 86 } as any}>
      <View style={{ paddingTop: insets.top + 12, paddingHorizontal: 20, paddingBottom: 12, flexDirection: 'row', alignItems: 'center', gap: 12 }}>
        <Text style={{ flex: 1, fontWeight: '700', fontSize: 26, color: c.t1, letterSpacing: -0.6 }}>Attention</Text>
        <Tap onPress={onClose} hitSlop={12} style={{ width: 38, height: 38, borderRadius: 19, backgroundColor: c.s2, alignItems: 'center', justifyContent: 'center' }}>
          <Feather name="x" size={20} color={c.t2} />
        </Tap>
      </View>

      <ScrollView contentContainerStyle={{ paddingHorizontal: 20, paddingBottom: insets.bottom + 28, gap: 12 }} showsVerticalScrollIndicator={false}>
        {alerts.length === 0 && (
          <View style={{ alignItems: 'center', paddingTop: 60, gap: 12 }}>
            <Feather name="check-circle" size={34} color={c.running} />
            <Text style={{ fontWeight: '600', fontSize: 15, color: c.t2 }}>Nothing needs attention</Text>
          </View>
        )}
        {alerts.map((a) => {
          const tone = toneOf(a.level);
          return (
            <FadeRise key={a.id}>
              <View style={{ padding: 16, borderRadius: 18, backgroundColor: dimOf(a.level), borderWidth: 1, borderColor: tone, ...shadow1 }}>
                <View style={{ flexDirection: 'row', alignItems: 'flex-start', gap: 12 }}>
                  <Feather name={a.level === 'info' ? 'info' : 'alert-circle'} size={18} color={tone} />
                  <View style={{ flex: 1 }}>
                    <Text style={{ fontWeight: '700', fontSize: 15, color: c.t1 }}>{a.title}</Text>
                    <Text style={{ marginTop: 4, fontWeight: '500', fontSize: 12.5, color: c.t2, lineHeight: 18 }}>{a.detail}</Text>
                    {!!a.code && (
                      <Text style={{ marginTop: 6, fontWeight: '600', fontSize: 11, color: c.t3, fontFamily: mono }}>HMS {a.code}</Text>
                    )}
                  </View>
                </View>
                {a.actions.length > 0 && (
                  <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 8, marginTop: 14 }}>
                    {a.actions.map((act) => (
                      <Tap
                        key={act.id}
                        onPress={() => onAction(a, act)}
                        style={{
                          paddingHorizontal: 15,
                          height: 40,
                          borderRadius: 12,
                          alignItems: 'center',
                          justifyContent: 'center',
                          backgroundColor: act.destructive ? c.s3 : act.id === 'lookup' ? c.s2 : tone,
                          borderWidth: act.id === 'lookup' ? 1 : 0,
                          borderColor: c.line2,
                        }}>
                        <Text style={{ fontWeight: '700', fontSize: 13, color: act.destructive ? c.error : act.id === 'lookup' ? c.t1 : c.accentInk }}>
                          {act.label}
                        </Text>
                      </Tap>
                    ))}
                  </View>
                )}
              </View>
            </FadeRise>
          );
        })}
      </ScrollView>
    </View>
  );
}
