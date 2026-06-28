# Expo App — Phase 1 (Foundation + Live Dashboard) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** A TestFlight-installable Expo iOS app that connects to the validated Bambuddy backend over HTTPS, authenticates with the scoped API key from the Keychain, and shows a **live Dashboard** (state, temps, progress, ETA, camera snapshot) plus the first quick controls (light/pause/resume/stop).

**Architecture:** Thin native client. The app talks ONLY to Bambuddy's REST + WebSocket API at `https://bambuddy.example.com` (works home + remote via the cloudflared tunnel — no VPN dependency). A typed `BambuddyClient` wraps the handful of endpoints we use; a WebSocket hook streams `printer_status`; React Query manages REST + mutations; `expo-secure-store` holds the API key. No on-device MQTT/TLS/printer protocol — the backend already solved that (see `docs/phase0-results.md`).

**Tech Stack:** Expo (managed, SDK current) + Expo Router + TypeScript; `@tanstack/react-query`; `expo-secure-store`; `expo-image`; Jest + `@testing-library/react-native`; EAS Build + TestFlight.

## Global Constraints

_(verbatim from `docs/phase0-results.md` — every task inherits these)_

- Backend base URL: **`https://bambuddy.example.com`** (LAN fallback `http://192.168.1.10:8910`, but default to the HTTPS URL).
- Auth: header **`X-API-Key: <key>`** (the `bb_…` key; lives in the Keychain, entered once via Settings — never hardcoded, never committed). Header injection must be extensible to also send `CF-Access-Client-Id`/`CF-Access-Client-Secret` later (Cloudflare Access).
- Printer id: **`1`**.
- WebSocket: `wss://bambuddy.example.com/api/v1/ws` — first `POST /api/v1/auth/ws-token` (with the API key) to get a token, then connect with `?token=`. Server pushes `{type:"printer_status", printer_id, data:{...}}`. REST `GET /api/v1/printers/1/status` is the poll fallback.
- Camera: `GET /api/v1/printers/1/camera/snapshot?token=<cam-token>` → JPEG (mint cam token via `POST /api/v1/printers/camera/stream-token`). ~1–5 fps; present as a refreshing snapshot.
- Apple: bundle id **`com.mvks5.bambu`**, EAS/Apple team `mvks5` (owner@example.com), distribute via **TestFlight internal**.
- No fan-speed / raw-gcode endpoints exist (don't build UI for them).
- Reference patterns (not code) from the existing Expo app at `/Users/max/ai-projects/theknowledge/apps/frontend`.

---

## File Structure

Expo app lives under `mobile/` (keeps it separate from `deploy/` and `docs/`):

- `mobile/app/_layout.tsx` — Expo Router root layout + React Query provider + config gate.
- `mobile/app/(tabs)/index.tsx` — Dashboard screen.
- `mobile/app/(tabs)/_layout.tsx` — tab navigator (Dashboard now; Camera/Files/Power added later phases).
- `mobile/app/settings.tsx` — onboarding/settings (base URL + API key entry).
- `mobile/src/config/secureConfig.ts` — Keychain-backed config (base URL, API key, cam token).
- `mobile/src/api/bambuddyClient.ts` — typed REST client.
- `mobile/src/api/types.ts` — `PrinterStatus` and related types.
- `mobile/src/api/queries.ts` — React Query hooks (status, mutations).
- `mobile/src/realtime/usePrinterStatus.ts` — WebSocket hook (live status + REST fallback).
- `mobile/src/components/StatBadge.tsx`, `TempGauge.tsx`, `ProgressRing.tsx`, `CameraSnapshot.tsx`, `QuickControls.tsx`.
- `mobile/src/**/__tests__/*.test.ts(x)` — colocated tests.
- `mobile/app.json`, `mobile/eas.json` — Expo + EAS config.

Design units: `bambuddyClient` (transport + endpoints, no React), `secureConfig` (storage only), `usePrinterStatus` (realtime state, no UI), components (presentational, take props). Each is independently testable.

---

## Task 1: Scaffold the Expo app (TestFlight-ready shell)

**Files:** Create `mobile/` (Expo app), `mobile/app.json`, `mobile/eas.json`.

**Interfaces:** Produces a runnable Expo Router app with bundle id `com.mvks5.bambu`.

- [ ] **Step 1: Create the app**

```bash
cd /Users/max/ai-projects/bambu-app
npx --yes create-expo-app@latest mobile --template default   # TS + Expo Router
cd mobile
npx --yes expo install expo-secure-store expo-image @tanstack/react-query
npm i -D jest-expo @testing-library/react-native @testing-library/jest-native
```

- [ ] **Step 2: Set identity + iOS config in `mobile/app.json`** (merge into the generated file)

```jsonc
{
  "expo": {
    "name": "Bambu",
    "slug": "bambu",
    "scheme": "bambu",
    "ios": { "bundleIdentifier": "com.mvks5.bambu", "supportsTablet": false },
    "plugins": ["expo-router", "expo-secure-store"],
    "userInterfaceStyle": "automatic"
  }
}
```

- [ ] **Step 3: Add the Jest preset** to `mobile/package.json`

```jsonc
{
  "scripts": { "test": "jest" },
  "jest": { "preset": "jest-expo", "setupFilesAfterEnv": ["@testing-library/jest-native/extend-expect"] }
}
```

- [ ] **Step 4: Verify it boots + tests run**

Run: `cd mobile && npx expo export --platform ios >/dev/null 2>&1 && echo EXPORT_OK` and `npm test -- --passWithNoTests`
Expected: `EXPORT_OK`; Jest runs (0 tests, passes).

- [ ] **Step 5: Commit**

```bash
git add mobile && git commit -m "feat(app): scaffold Expo Router app (com.mvks5.bambu)"
```

---

## Task 2: Keychain-backed config + Settings entry

**Files:** Create `mobile/src/config/secureConfig.ts`, `mobile/src/config/__tests__/secureConfig.test.ts`, `mobile/app/settings.tsx`.

**Interfaces:**
- Produces: `getConfig(): Promise<AppConfig|null>`, `setConfig(c: AppConfig): Promise<void>`, `clearConfig(): Promise<void>` where `AppConfig = { baseUrl: string; apiKey: string; cameraToken?: string }`.

- [ ] **Step 1: Write the failing test** (`secureConfig.test.ts`) — mock `expo-secure-store`:

```ts
import * as SecureStore from 'expo-secure-store';
import { getConfig, setConfig } from '../secureConfig';
jest.mock('expo-secure-store');
const store: Record<string,string> = {};
(SecureStore.setItemAsync as jest.Mock).mockImplementation(async (k,v)=>{store[k]=v;});
(SecureStore.getItemAsync as jest.Mock).mockImplementation(async (k)=>store[k] ?? null);

test('round-trips config through secure storage', async () => {
  await setConfig({ baseUrl: 'https://bambuddy.example.com', apiKey: 'bb_x' });
  expect(await getConfig()).toEqual({ baseUrl: 'https://bambuddy.example.com', apiKey: 'bb_x' });
});
```

- [ ] **Step 2: Run it, confirm it fails** — `npm test secureConfig` → FAIL (module not found).

- [ ] **Step 3: Implement `secureConfig.ts`**

```ts
import * as SecureStore from 'expo-secure-store';
export type AppConfig = { baseUrl: string; apiKey: string; cameraToken?: string };
const KEY = 'bambu.config';
const OPTS = { keychainAccessible: SecureStore.WHEN_UNLOCKED_THIS_DEVICE_ONLY };
export async function getConfig(): Promise<AppConfig | null> {
  const raw = await SecureStore.getItemAsync(KEY, OPTS);
  return raw ? (JSON.parse(raw) as AppConfig) : null;
}
export async function setConfig(c: AppConfig): Promise<void> {
  await SecureStore.setItemAsync(KEY, JSON.stringify(c), OPTS);
}
export async function clearConfig(): Promise<void> { await SecureStore.deleteItemAsync(KEY, OPTS); }
```

- [ ] **Step 4: Run test, confirm pass** — `npm test secureConfig` → PASS.

- [ ] **Step 5: Build the Settings screen** (`app/settings.tsx`) — two `TextInput`s (base URL prefilled `https://bambuddy.example.com`, API key secure) + Save calling `setConfig`. (Presentational; no test required beyond the store.)

- [ ] **Step 6: Commit** — `git commit -am "feat(app): Keychain config + settings entry"`

---

## Task 3: Typed `BambuddyClient`

**Files:** Create `mobile/src/api/types.ts`, `mobile/src/api/bambuddyClient.ts`, `mobile/src/api/__tests__/bambuddyClient.test.ts`.

**Interfaces:**
- Produces: `class BambuddyClient { constructor(cfg:{baseUrl:string; apiKey:string; extraHeaders?:Record<string,string>}); getStatus(printerId:number): Promise<PrinterStatus>; setLight(printerId:number, on:boolean): Promise<void>; pause/resume/stop(printerId:number): Promise<void>; setSpeed(printerId:number, mode:1|2|3|4): Promise<void>; mintWsToken(): Promise<string>; mintCameraToken(): Promise<string>; snapshotUrl(printerId:number, token:string): string; }`

- [ ] **Step 1: Define `types.ts`** (the status subset we consume)

```ts
export interface PrinterStatus {
  connected: boolean;
  state: string;                 // RUNNING | PAUSE | IDLE | FINISH | ...
  progress: number | null;       // %
  remaining_time: number | null; // minutes
  layer_num: number | null;
  total_layers: number | null;
  subtask_name: string | null;
  chamber_light: boolean | null;
  temperatures: { nozzle?: number; nozzle_target?: number; bed?: number; bed_target?: number } | null;
  ams?: Array<{ id: number; tray: Array<{ id: number; tray_type?: string; tray_color?: string; remain?: number }> }>;
}
```

- [ ] **Step 2: Write the failing test** (`bambuddyClient.test.ts`) — mock `global.fetch`:

```ts
import { BambuddyClient } from '../bambuddyClient';
const fetchMock = jest.fn();
global.fetch = fetchMock as any;
const client = new BambuddyClient({ baseUrl: 'https://x', apiKey: 'bb_k' });

test('getStatus hits the right URL with the API key header', async () => {
  fetchMock.mockResolvedValueOnce({ ok: true, json: async () => ({ connected: true, state: 'IDLE' }) });
  const s = await client.getStatus(1);
  expect(s.state).toBe('IDLE');
  const [url, opts] = fetchMock.mock.calls[0];
  expect(url).toBe('https://x/api/v1/printers/1/status');
  expect(opts.headers['X-API-Key']).toBe('bb_k');
});

test('setLight POSTs chamber-light with on query', async () => {
  fetchMock.mockResolvedValueOnce({ ok: true, json: async () => ({}) });
  await client.setLight(1, false);
  const [url, opts] = fetchMock.mock.calls.at(-1)!;
  expect(url).toBe('https://x/api/v1/printers/1/chamber-light?on=false');
  expect(opts.method).toBe('POST');
});

test('throws on non-ok', async () => {
  fetchMock.mockResolvedValueOnce({ ok: false, status: 401, text: async () => 'no' });
  await expect(client.getStatus(1)).rejects.toThrow(/401/);
});
```

- [ ] **Step 3: Run, confirm fail** — `npm test bambuddyClient` → FAIL.

- [ ] **Step 4: Implement `bambuddyClient.ts`**

```ts
import type { PrinterStatus } from './types';
export class BambuddyClient {
  constructor(private cfg: { baseUrl: string; apiKey: string; extraHeaders?: Record<string,string> }) {}
  private headers(json = false) {
    return { 'X-API-Key': this.cfg.apiKey, ...(json ? { 'Content-Type': 'application/json' } : {}), ...(this.cfg.extraHeaders ?? {}) };
  }
  private async req(path: string, init?: RequestInit) {
    const res = await fetch(this.cfg.baseUrl + path, { ...init, headers: { ...this.headers(!!init?.body), ...(init?.headers ?? {}) } });
    if (!res.ok) throw new Error(`Bambuddy ${init?.method ?? 'GET'} ${path} -> HTTP ${res.status}`);
    return res;
  }
  async getStatus(printerId: number): Promise<PrinterStatus> { return (await this.req(`/api/v1/printers/${printerId}/status`)).json(); }
  async setLight(printerId: number, on: boolean) { await this.req(`/api/v1/printers/${printerId}/chamber-light?on=${on}`, { method: 'POST' }); }
  async pause(printerId: number) { await this.req(`/api/v1/printers/${printerId}/print/pause`, { method: 'POST' }); }
  async resume(printerId: number) { await this.req(`/api/v1/printers/${printerId}/print/resume`, { method: 'POST' }); }
  async stop(printerId: number) { await this.req(`/api/v1/printers/${printerId}/print/stop`, { method: 'POST' }); }
  async setSpeed(printerId: number, mode: 1|2|3|4) { await this.req(`/api/v1/printers/${printerId}/print-speed?mode=${mode}`, { method: 'POST' }); }
  async mintWsToken(): Promise<string> { return (await (await this.req(`/api/v1/auth/ws-token`, { method: 'POST' })).json()).token; }
  async mintCameraToken(): Promise<string> { return (await (await this.req(`/api/v1/printers/camera/stream-token`, { method: 'POST' })).json()).token; }
  snapshotUrl(printerId: number, token: string) { return `${this.cfg.baseUrl}/api/v1/printers/${printerId}/camera/snapshot?token=${token}`; }
}
```

- [ ] **Step 5: Run, confirm pass** — `npm test bambuddyClient` → PASS.

- [ ] **Step 6: Commit** — `git commit -am "feat(app): typed BambuddyClient + tests"`

> NOTE on `chamber-light?on=`: verified working against the live A1 in Phase 0. If a later Bambuddy version changes the param, re-check `/openapi.json` and adjust this one method.

---

## Task 4: `usePrinterStatus` WebSocket hook (live telemetry + REST fallback)

**Files:** Create `mobile/src/realtime/usePrinterStatus.ts`, `mobile/src/realtime/__tests__/parse.test.ts`, plus a pure helper `parseWsMessage`.

**Interfaces:**
- Consumes: `BambuddyClient` (Task 3).
- Produces: `parseWsMessage(raw: string, printerId: number): PrinterStatus | null` (pure, tested) and `usePrinterStatus(client, printerId): { status: PrinterStatus | null; connected: boolean }` (hook; opens WS with a ws-token, falls back to REST polling on disconnect).

- [ ] **Step 1: Write the failing test for the pure parser** (`parse.test.ts`)

```ts
import { parseWsMessage } from '../usePrinterStatus';
test('extracts printer_status for our printer', () => {
  const raw = JSON.stringify({ type: 'printer_status', printer_id: 1, data: { connected: true, state: 'RUNNING', progress: 42 } });
  expect(parseWsMessage(raw, 1)?.state).toBe('RUNNING');
});
test('ignores other printers and other message types', () => {
  expect(parseWsMessage(JSON.stringify({ type: 'printer_status', printer_id: 2, data: { state: 'X' } }), 1)).toBeNull();
  expect(parseWsMessage(JSON.stringify({ type: 'pong' }), 1)).toBeNull();
});
test('returns null on malformed json', () => { expect(parseWsMessage('{bad', 1)).toBeNull(); });
```

- [ ] **Step 2: Run, confirm fail.**

- [ ] **Step 3: Implement `parseWsMessage` + the hook** (`usePrinterStatus.ts`)

```ts
import { useEffect, useRef, useState } from 'react';
import type { BambuddyClient } from '../api/bambuddyClient';
import type { PrinterStatus } from '../api/types';

export function parseWsMessage(raw: string, printerId: number): PrinterStatus | null {
  try {
    const m = JSON.parse(raw);
    if (m?.type === 'printer_status' && m.printer_id === printerId && m.data) return m.data as PrinterStatus;
    return null;
  } catch { return null; }
}

export function usePrinterStatus(client: BambuddyClient, printerId: number) {
  const [status, setStatus] = useState<PrinterStatus | null>(null);
  const [connected, setConnected] = useState(false);
  const wsRef = useRef<WebSocket | null>(null);
  useEffect(() => {
    let cancelled = false, pollTimer: any;
    const wsUrl = (p: string) => client['cfg'].baseUrl.replace(/^http/, 'ws');
    async function connect() {
      try {
        const token = await client.mintWsToken();
        if (cancelled) return;
        const ws = new WebSocket(`${wsUrl('')}/api/v1/ws?token=${token}`);
        wsRef.current = ws;
        ws.onopen = () => setConnected(true);
        ws.onmessage = (e) => { const s = parseWsMessage(String(e.data), printerId); if (s) setStatus(s); };
        ws.onclose = () => { setConnected(false); if (!cancelled) startPolling(); };
        ws.onerror = () => ws.close();
      } catch { if (!cancelled) startPolling(); }
    }
    function startPolling() {
      clearInterval(pollTimer);
      pollTimer = setInterval(async () => {
        try { const s = await client.getStatus(printerId); if (!cancelled) setStatus(s); } catch {}
      }, 3000);
    }
    connect();
    return () => { cancelled = true; clearInterval(pollTimer); wsRef.current?.close(); };
  }, [client, printerId]);
  return { status, connected };
}
```

- [ ] **Step 4: Run parser test, confirm pass.**

- [ ] **Step 5: Commit** — `git commit -am "feat(app): usePrinterStatus WS hook + parser tests"`

> The `baseUrl.replace(/^http/, 'ws')` turns `https://…` into `wss://…`. Expose `baseUrl` on the client (or pass it to the hook) rather than reaching into a private field when implementing — adjust the constructor to keep `baseUrl` readable.

---

## Task 5: Dashboard screen (live, read-only first)

**Files:** Create `mobile/src/components/{StatBadge,TempGauge,ProgressRing}.tsx`, `mobile/app/_layout.tsx` (React Query + config gate), `mobile/app/(tabs)/index.tsx`, and a render test `mobile/src/components/__tests__/dashboard.test.tsx`.

**Interfaces:**
- Consumes: `usePrinterStatus`, `getConfig`, `BambuddyClient`.
- Produces: a Dashboard that renders live state/temps/progress/ETA; routes to Settings when unconfigured.

- [ ] **Step 1: Write a failing render test** for a presentational summary that takes a `PrinterStatus`:

```tsx
import { render } from '@testing-library/react-native';
import { DashboardView } from '../../app/(tabs)/index';
test('shows state and nozzle temp', () => {
  const { getByText } = render(<DashboardView status={{ connected:true, state:'RUNNING', progress:42, remaining_time:90, layer_num:5, total_layers:100, subtask_name:'cube', chamber_light:true, temperatures:{ nozzle:210, nozzle_target:220, bed:60, bed_target:60 } }} onLight={()=>{}} onPause={()=>{}} onResume={()=>{}} onStop={()=>{}} />);
  getByText('RUNNING'); getByText(/210/); getByText(/42%/);
});
```

- [ ] **Step 2: Run, confirm fail.**

- [ ] **Step 3: Implement `DashboardView`** (pure, prop-driven) — state badge, nozzle/bed temp text, a progress value + ETA, layer x/y, and a `QuickControls` row (Task 7 wires handlers). Export it separately from the screen container so it's testable without hooks.

- [ ] **Step 4: Implement the screen container** (`index.tsx`) — load `getConfig()`; if null, `redirect` to `/settings`; else build a memoized `BambuddyClient`, call `usePrinterStatus`, render `<DashboardView status={status} … />`.

- [ ] **Step 5: Wire `_layout.tsx`** — wrap in `QueryClientProvider`; Stack with `(tabs)` + `settings`.

- [ ] **Step 6: Run test, confirm pass.** Then manual: `npx expo start`, load in Expo Go / dev build, enter the key in Settings, confirm live numbers. (Camera in Task 6.)

- [ ] **Step 7: Commit** — `git commit -am "feat(app): live Dashboard"`

---

## Task 6: Camera snapshot

**Files:** Create `mobile/src/components/CameraSnapshot.tsx`, test `mobile/src/components/__tests__/cameraSnapshot.test.tsx`.

**Interfaces:** Produces `<CameraSnapshot client printerId cameraToken />` that polls the snapshot URL at ~1 fps using `expo-image`, with manual refresh and graceful error state.

- [ ] **Step 1: Failing test** — render with a fake client; assert it renders an `expo-image` with the snapshot URL (mint a cam token via `client.mintCameraToken` on mount; assert the `source.uri` contains `/camera/snapshot?token=`).
- [ ] **Step 2: Run, confirm fail.**
- [ ] **Step 3: Implement** — on mount mint the camera token (store in config), build `client.snapshotUrl(printerId, token)`, add a cache-busting `&t=${counter}` updated on a 1s interval; render with `expo-image` (`recyclingKey` to force reload); show a "tap to refresh" + error fallback.
- [ ] **Step 4: Run test, confirm pass.** Manual: confirm the A1 image appears (printer must be powered on).
- [ ] **Step 5: Commit** — `git commit -am "feat(app): camera snapshot"`

---

## Task 7: Quick controls (mutations)

**Files:** Create `mobile/src/api/queries.ts` (React Query mutations), `mobile/src/components/QuickControls.tsx`, test `mobile/src/api/__tests__/mutations.test.ts`.

**Interfaces:** Produces `useControls(client, printerId)` → `{ light, pause, resume, stop, speed }` mutations that invalidate status; `<QuickControls .../>` buttons.

- [ ] **Step 1: Failing test** — a mutation calls the right client method (mock `BambuddyClient`), and `stop` requires a confirm flag (the mutation accepts `{confirmed:true}` and throws otherwise) — encodes the "destructive actions need confirmation" rule.
- [ ] **Step 2: Run, confirm fail.**
- [ ] **Step 3: Implement** mutations (wrap `client.setLight/pause/resume/stop/setSpeed`, invalidate the status query on success); `QuickControls` renders buttons, disables pause/resume by state, and shows a confirm dialog before `stop`.
- [ ] **Step 4: Run test, confirm pass.** Manual: toggle light on the real printer (it's a safe control) and confirm the badge reflects it.
- [ ] **Step 5: Commit** — `git commit -am "feat(app): quick controls with stop confirmation"`

---

## Task 8: EAS Build → TestFlight (the Phase 1 acceptance gate)

**Files:** `mobile/eas.json`.

- [ ] **Step 1: Configure EAS** — `cd mobile && eas build:configure -p ios`. Set an `internal`/`preview` profile producing an iOS build for TestFlight.
- [ ] **Step 2: Build** — `eas build -p ios --profile preview` (signs with the existing `mvks5` credentials; let EAS manage them).
- [ ] **Step 3: Submit to TestFlight** — `eas submit -p ios --latest` (Apple ID owner@example.com). 
- [ ] **Step 4: ACCEPTANCE** — install via TestFlight on the iPhone; enter the API key in Settings; confirm the Dashboard shows **live** telemetry over the cloudflared HTTPS endpoint (both on home wifi and on cellular), the camera snapshot loads (printer on), and a light toggle works. This is the Phase 1 done-gate.
- [ ] **Step 5: Commit** — `git commit -am "build(app): EAS iOS profile + TestFlight"`

---

## Self-Review

- **Spec coverage (Phase 1 portion of the design spec §5 Dashboard/Camera + §4.5 stack):** Dashboard → Task 5; Camera → Task 6; controls (light/pause/resume/stop/speed) → Task 7; API key in Keychain + Tailscale/HTTPS transport → Tasks 2/3 (HTTPS via cloudflared per the user's choice); WS realtime → Task 4; TestFlight → Task 8. AMS display, Power screen, Files/Print Wizard, Queue, and push are **Phase 2–4** (roadmap below), correctly out of this plan.
- **Placeholder scan:** none — code is complete for the logic layer; UI tasks give the component contract + a render test. The one runtime value is the API key (entered in Settings, by design).
- **Type consistency:** `PrinterStatus` (Task 3) is the single shape consumed by Tasks 4/5/7; `BambuddyClient` method names are used identically across Tasks 4/5/7.

---

## Roadmap (separate plans, written just-in-time)

- **Phase 2 — Control depth + Power:** full AMS view (trays type/color/remaining, load/unload), speed selector, and the **Power** screen (`switch.3d_printer_plug` via Bambuddy's HA smart-plug integration — configure that integration first; live watts + auto-off-after-print + cooldown). Plan written after Phase 1, once the component patterns exist.
- **Phase 3 — Library + Print Wizard:** upload → pick printer/filament/quality → slice (Bambu Studio CLI) → **review on device** (plate metadata + STL-thumbnail/gcode-viewer preview) → confirm AMS mapping → print, per spec §5.1. Uses the exact slice contract proven in `docs/phase0-results.md` §3.
- **Phase 4 — Native push + polish:** the **push relay** (small service on homeserver: Bambuddy webhook → Expo Push → APNs, deep-linked), notification handling in-app, and UI polish via **Claude Design / the frontend-design skill**.
- **Owner follow-ups (not app code):** Cloudflare Access service token (then add `CF-Access-Client-*` headers to `BambuddyClient.extraHeaders`); physical test print.
