import * as SecureStore from 'expo-secure-store';
import { getConfig, setConfig, clearConfig } from '../secureConfig';

jest.mock('expo-secure-store');

const store: Record<string, string> = {};
beforeEach(() => {
  for (const k of Object.keys(store)) delete store[k];
  (SecureStore.setItemAsync as jest.Mock).mockImplementation(async (k: string, v: string) => {
    store[k] = v;
  });
  (SecureStore.getItemAsync as jest.Mock).mockImplementation(async (k: string) => store[k] ?? null);
  (SecureStore.deleteItemAsync as jest.Mock).mockImplementation(async (k: string) => {
    delete store[k];
  });
});

test('returns null when nothing stored', async () => {
  expect(await getConfig()).toBeNull();
});

test('round-trips config through secure storage', async () => {
  await setConfig({ baseUrl: 'https://bambuddy.example.com', apiKey: 'bb_x' });
  expect(await getConfig()).toEqual({ baseUrl: 'https://bambuddy.example.com', apiKey: 'bb_x' });
});

test('clearConfig removes it', async () => {
  await setConfig({ baseUrl: 'https://x', apiKey: 'bb_y' });
  await clearConfig();
  expect(await getConfig()).toBeNull();
});

test('getConfig tolerates corrupt json', async () => {
  store['bambu.config'] = '{not json';
  expect(await getConfig()).toBeNull();
});
