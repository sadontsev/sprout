import type { PrinterStatus, SpeedMode, LibraryFile, QueueItem, SmartPlug, PlugStatus } from './types';

export interface BambuddyClientConfig {
  /** e.g. https://bambuddy.example.com */
  baseUrl: string;
  /** Bambuddy scoped API key, sent as X-API-Key */
  apiKey: string;
  /** Extra headers sent on every request — e.g. CF-Access-Client-Id/Secret if Cloudflare Access is added. */
  extraHeaders?: Record<string, string>;
}

/** Thin typed wrapper over the Bambuddy endpoints the app uses. No React. */
export class BambuddyClient {
  readonly baseUrl: string;
  private readonly apiKey: string;
  private readonly extraHeaders: Record<string, string>;

  constructor(cfg: BambuddyClientConfig) {
    this.baseUrl = cfg.baseUrl.replace(/\/+$/, '');
    this.apiKey = cfg.apiKey;
    this.extraHeaders = cfg.extraHeaders ?? {};
  }

  /** ws(s):// origin derived from baseUrl, for the realtime hook. */
  get wsBaseUrl(): string {
    return this.baseUrl.replace(/^http/, 'ws');
  }

  private headers(): Record<string, string> {
    return { 'X-API-Key': this.apiKey, ...this.extraHeaders };
  }

  private async req(path: string, init?: RequestInit): Promise<Response> {
    const res = await fetch(this.baseUrl + path, {
      ...init,
      headers: { ...this.headers(), ...(init?.headers ?? {}) },
    });
    if (!res.ok) {
      const body = await res.text().catch(() => '');
      throw new Error(`Bambuddy ${init?.method ?? 'GET'} ${path} -> HTTP ${res.status} ${body}`.trim());
    }
    return res;
  }

  getStatus(printerId: number): Promise<PrinterStatus> {
    return this.req(`/api/v1/printers/${printerId}/status`).then((r) => r.json());
  }
  async setLight(printerId: number, on: boolean): Promise<void> {
    await this.req(`/api/v1/printers/${printerId}/chamber-light?on=${on}`, { method: 'POST' });
  }
  async pause(printerId: number): Promise<void> {
    await this.req(`/api/v1/printers/${printerId}/print/pause`, { method: 'POST' });
  }
  async resume(printerId: number): Promise<void> {
    await this.req(`/api/v1/printers/${printerId}/print/resume`, { method: 'POST' });
  }
  async stop(printerId: number): Promise<void> {
    await this.req(`/api/v1/printers/${printerId}/print/stop`, { method: 'POST' });
  }
  async setSpeed(printerId: number, mode: SpeedMode): Promise<void> {
    await this.req(`/api/v1/printers/${printerId}/print-speed?mode=${mode}`, { method: 'POST' });
  }
  async mintWsToken(): Promise<string> {
    return (await (await this.req(`/api/v1/auth/ws-token`, { method: 'POST' })).json()).token;
  }
  async mintCameraToken(): Promise<string> {
    return (await (await this.req(`/api/v1/printers/camera/stream-token`, { method: 'POST' })).json()).token;
  }
  snapshotUrl(printerId: number, token: string): string {
    return `${this.baseUrl}/api/v1/printers/${printerId}/camera/snapshot?token=${encodeURIComponent(token)}`;
  }

  /** Headers so <expo-image> can load authenticated thumbnails. */
  imageHeaders(): Record<string, string> {
    return { 'X-API-Key': this.apiKey, ...this.extraHeaders };
  }
  fileThumbUrl(fileId: number): string {
    return `${this.baseUrl}/api/v1/library/files/${fileId}/thumbnail`;
  }

  // --- Library ---
  listFiles(): Promise<LibraryFile[]> {
    return this.req('/api/v1/library/files').then((r) => r.json());
  }
  async uploadFile(uri: string, name: string): Promise<{ id: number }> {
    const fd = new FormData();
    fd.append('file', { uri, name, type: 'application/octet-stream' } as any);
    return (await this.req('/api/v1/library/files', { method: 'POST', body: fd as any })).json();
  }
  getPlates(fileId: number): Promise<any> {
    return this.req(`/api/v1/library/files/${fileId}/plates`).then((r) => r.json());
  }

  // --- Slicing ---
  getPresets(): Promise<any> {
    return this.req('/api/v1/slicer/presets').then((r) => r.json());
  }
  async slice(fileId: number, body: Record<string, unknown>): Promise<{ job_id: number }> {
    return (
      await this.req(`/api/v1/library/files/${fileId}/slice`, {
        method: 'POST',
        body: JSON.stringify(body),
        headers: { 'Content-Type': 'application/json' },
      })
    ).json();
  }
  getSliceJob(jobId: number): Promise<any> {
    return this.req(`/api/v1/slice-jobs/${jobId}`).then((r) => r.json());
  }

  // --- Queue ---
  listQueue(): Promise<QueueItem[]> {
    return this.req('/api/v1/queue/').then((r) => r.json());
  }
  async enqueue(body: Record<string, unknown>): Promise<any> {
    return (
      await this.req('/api/v1/queue/', {
        method: 'POST',
        body: JSON.stringify(body),
        headers: { 'Content-Type': 'application/json' },
      })
    ).json();
  }
  async queueAction(itemId: number, action: 'start' | 'stop' | 'cancel'): Promise<void> {
    await this.req(`/api/v1/queue/${itemId}/${action}`, { method: 'POST' });
  }

  // --- AMS ---
  async amsLoad(printerId: number, trayId: number): Promise<void> {
    await this.req(`/api/v1/printers/${printerId}/ams/load?tray_id=${trayId}`, { method: 'POST' });
  }
  async amsUnload(printerId: number): Promise<void> {
    await this.req(`/api/v1/printers/${printerId}/ams/unload`, { method: 'POST' });
  }

  // --- Smart plug ---
  async getPlug(printerId: number): Promise<SmartPlug | null> {
    try {
      return await (await this.req(`/api/v1/smart-plugs/by-printer/${printerId}`)).json();
    } catch {
      return null;
    }
  }
  plugStatus(plugId: number): Promise<PlugStatus> {
    return this.req(`/api/v1/smart-plugs/${plugId}/status`).then((r) => r.json());
  }
  async plugControl(plugId: number, on: boolean): Promise<void> {
    await this.req(`/api/v1/smart-plugs/${plugId}/control`, {
      method: 'POST',
      body: JSON.stringify({ action: on ? 'on' : 'off' }),
      headers: { 'Content-Type': 'application/json' },
    });
  }
}
