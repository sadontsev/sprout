import { Stack } from 'expo-router';
import { StatusBar } from 'expo-status-bar';
import { c, useTheme } from '@/theme';

export default function RootLayout() {
  const theme = useTheme(); // re-render on theme switch so the status bar + background follow
  return (
    <>
      <StatusBar style={theme === 'light' ? 'dark' : 'light'} />
      <Stack
        screenOptions={{
          headerShown: false,
          contentStyle: { backgroundColor: c.bg },
        }}>
        <Stack.Screen name="index" />
        <Stack.Screen name="settings" options={{ presentation: 'modal' }} />
      </Stack>
    </>
  );
}
