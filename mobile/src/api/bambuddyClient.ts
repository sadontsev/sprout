import type { PrinterStatus, SpeedMode } from './types';

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
}
