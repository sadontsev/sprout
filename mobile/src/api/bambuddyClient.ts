import { File, UploadType } from 'expo-file-system';
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
  /** MJPEG multipart live stream (multipart/x-mixed-replace) — render in a WebView <img>.
   *  Token MUST be in the query; the X-API-Key header is rejected (401) on stream/snapshot. */
  streamUrl(printerId: number, token: string, fps = 10): string {
    return `${this.baseUrl}/api/v1/printers/${printerId}/camera/stream?token=${encodeURIComponent(token)}&fps=${fps}`;
  }
  /** Read-only staged camera diagnostics — explains *why* the stream is unavailable (e.g. port 6000 timeout). */
  diagnoseCamera(printerId: number): Promise<{ protocol: string; port: number; overall_status: string; summary_code: string; stages: { name: string; status: string; code: string | null }[] }> {
    return this.req(`/api/v1/printers/${printerId}/camera/diagnose`, { method: 'POST' }).then((r) => r.json());
  }

  /** Library thumbnails are gated by a camera *stream* token (?token=), NOT X-API-Key — the same
   *  token type as snapshotUrl(). Returns '' when there's no token or no server-side thumbnail. */
  fileThumbUrl(fileId: number, token: string | null, thumbnailPath?: string | null): string {
    if (!token || thumbnailPath === null) return '';
    return `${this.baseUrl}/api/v1/library/files/${fileId}/thumbnail?token=${encodeURIComponent(token)}`;
  }

  // --- Library ---
  listFiles(): Promise<LibraryFile[]> {
    return this.req('/api/v1/library/files').then((r) => r.json());
  }
  /**
   * Upload a local file (RN `file://` URI) to the library via expo-file-system's native multipart
   * upload — NOT global fetch. Expo's WinterCG fetch rejects RN's {uri,name,type} FormData parts
   * ("Unsupported FormDataPart implementation"); the native File.upload reads the URI natively.
   * Backend field name is `file`; response is { id, ... }.
   */
  async uploadFile(uri: string, name: string, onProgress?: (fraction: number) => void): Promise<{ id: number }> {
    const res = await new File(uri).upload(this.baseUrl + '/api/v1/library/files', {
      httpMethod: 'POST',
      uploadType: UploadType.MULTIPART,
      fieldName: 'file',
      mimeType: 'application/octet-stream',
      headers: this.headers(),
      onProgress: onProgress ? ({ bytesSent, totalBytes }) => onProgress(totalBytes > 0 ? bytesSent / totalBytes : 0) : undefined,
    });
    if (res.status < 200 || res.status >= 300) {
      throw new Error(`Bambuddy POST /api/v1/library/files -> HTTP ${res.status} ${res.body}`.trim());
    }
    return JSON.parse(res.body) as { id: number };
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
