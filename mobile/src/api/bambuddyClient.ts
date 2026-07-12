import { File, UploadType } from 'expo-file-system';
import type { Printer, PrinterStatus, SpeedMode, LibraryFile, QueueItem, SmartPlug, PlugStatus, PrintLogPage, ArchiveStats, AppSettings, Spool, SlotAssignment, MaintenancePrinter, MaintenanceSummary, MakerWorldStatus, MakerWorldResolved, MakerWorldImportRequest, MakerWorldImportResponse, PlatesResponse, PrinterFileList, PrinterFilePlates } from './types';

export interface BambuddyClientConfig {
  /** e.g. https://bambuddy.example.com */
  baseUrl: string;
  /** Bambuddy scoped API key, sent as X-API-Key */
  apiKey: string;
  /** Extra headers sent on every request — e.g. CF-Access-Client-Id/Secret if Cloudflare Access is added. */
  extraHeaders?: Record<string, string>;
}

/** Human message from a thrown Bambuddy error — surfaces the API's JSON `detail` (e.g. a drying
 *  409's "AMS is busy") instead of the raw `Bambuddy POST … -> HTTP 409 {...}` string. */
export function apiErrorDetail(e: unknown): string {
  const s = String(e instanceof Error ? e.message : e);
  const m = s.match(/\{"detail"\s*:\s*"([^"]+)"/);
  return m ? m[1] : s;
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

  /** All registered printers (A1, H2C, …). */
  listPrinters(): Promise<Printer[]> {
    return this.req('/api/v1/printers/').then((r) => r.json());
  }
  getStatus(printerId: number): Promise<PrinterStatus> {
    return this.req(`/api/v1/printers/${printerId}/status`).then((r) => r.json());
  }
  /** Clear the printer's HMS notices (e.g. the benign mid-print ones the H2C emits). */
  async clearHms(printerId: number): Promise<void> {
    await this.req(`/api/v1/printers/${printerId}/hms/clear`, { method: 'POST' });
  }
  /** Confirm the plate is clear so the queue can dispatch the next job. */
  async queueResume(printerId: number): Promise<void> {
    await this.req(`/api/v1/queue/printer/${printerId}/resume`, { method: 'POST' });
  }
  /** Start AMS filament drying. NOTE: duration is HOURS (Bambuddy validates 1-24 — minutes would
   *  400), temp is 45-85°C server-side but the AMS 2 Pro's hardware max is 65°C (85 = AMS-HT only)
   *  — clamp via presentDryer's maxTemp before calling. `rotate` spins the spool for even drying.
   *  A blocked start returns 409 with a human reason — show it via apiErrorDetail(). */
  async dryingStart(
    printerId: number,
    amsId: number,
    opts: { temp: number; hours: number; filament?: string; rotate?: boolean },
  ): Promise<void> {
    const q = new URLSearchParams({ ams_id: String(amsId), temp: String(opts.temp), duration: String(opts.hours) });
    if (opts.filament) q.set('filament', opts.filament);
    if (opts.rotate !== undefined) q.set('rotate_tray', String(opts.rotate));
    await this.req(`/api/v1/printers/${printerId}/drying/start?${q}`, { method: 'POST' });
  }
  async dryingStop(printerId: number, amsId: number): Promise<void> {
    await this.req(`/api/v1/printers/${printerId}/drying/stop?ams_id=${amsId}`, { method: 'POST' });
  }
  /** Queue a past print (archive) again on the given printer. */
  async reprint(archiveId: number, printerId: number): Promise<void> {
    await this.req(`/api/v1/archives/${archiveId}/reprint?printer_id=${printerId}`, { method: 'POST' });
  }
  /** Server config incl. electricity price (energy_cost_per_kwh) + currency. Read works with the
   *  API key; writes are admin-JWT only. */
  getSettings(): Promise<AppSettings> {
    return this.req('/api/v1/settings/').then((r) => r.json());
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
  /** Full file detail incl. the slicer-baked `metadata` (total_layers, layer_height, temps...). */
  getFileDetail(fileId: number): Promise<LibraryFile> {
    return this.req(`/api/v1/library/files/${fileId}`).then((r) => r.json());
  }
  /** Per-plate breakdown of a sliced .gcode.3mf (time, grams, filaments, multi-plate). */
  getPlates(fileId: number): Promise<PlatesResponse> {
    return this.req(`/api/v1/library/files/${fileId}/plates`).then((r) => r.json());
  }
  /** Rendered plate thumbnail (1-based index). Gated by the camera stream token, like fileThumbUrl. */
  plateThumbUrl(fileId: number, plateIndex: number, token: string | null): string {
    if (!token) return '';
    return `${this.baseUrl}/api/v1/library/files/${fileId}/plate-thumbnail/${plateIndex}?token=${encodeURIComponent(token)}`;
  }
  /** Raw G-code text of a sliced file — used to render the layer-by-layer preview. Can be large. */
  getGcode(fileId: number): Promise<string> {
    return this.req(`/api/v1/library/files/${fileId}/gcode`).then((r) => r.text());
  }
  /** Delete a library file. Needs the Manage-Library scope (works on Bambuddy ≥ 0.2.4.8, #1832). */
  deleteFile(fileId: number): Promise<void> {
    return this.req(`/api/v1/library/files/${fileId}`, { method: 'DELETE' }).then(() => undefined);
  }

  // --- Printer onboard storage (SD card) ---
  /** Browse the printer's onboard filesystem at `path` (directories nest; files carry a size). */
  listPrinterFiles(printerId: number, path = '/'): Promise<PrinterFileList> {
    return this.req(`/api/v1/printers/${printerId}/files?path=${encodeURIComponent(path)}`).then((r) => r.json());
  }
  /** Auth headers for endpoints fetched OUTSIDE req() — expo-image `source.headers` and
   *  File.downloadFileAsync both take a headers map. These SD-card endpoints use X-API-Key
   *  (verified live), NOT the camera `?token=` that gates library thumbnails. */
  authHeaders(): Record<string, string> {
    return this.headers();
  }
  /** Direct download URL for an SD-card file — pair with authHeaders() (401 otherwise). */
  printerFileDownloadUrl(printerId: number, path: string): string {
    return `${this.baseUrl}/api/v1/printers/${printerId}/files/download?${new URLSearchParams({ path })}`;
  }
  /** Plate preview PNG for a sliced 3MF straight off the SD card — pair with authHeaders(). */
  printerPlateThumbUrl(printerId: number, path: string, plateIndex = 1): string {
    return `${this.baseUrl}/api/v1/printers/${printerId}/files/plate-thumbnail/${plateIndex}?${new URLSearchParams({ path })}`;
  }
  /** Plate metadata (name, print time, filament grams) for a sliced 3MF on the SD card. */
  getPrinterFilePlates(printerId: number, path: string): Promise<PrinterFilePlates> {
    return this.req(`/api/v1/printers/${printerId}/files/plates?${new URLSearchParams({ path })}`).then((r) => r.json());
  }
  /** Delete a file from the printer's SD card. Irreversible. */
  async deletePrinterFile(printerId: number, path: string): Promise<void> {
    await this.req(`/api/v1/printers/${printerId}/files?${new URLSearchParams({ path })}`, { method: 'DELETE' });
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

  // --- Inventory (filament spools + AMS slot assignments) ---
  listSpools(): Promise<Spool[]> {
    return this.req('/api/v1/inventory/spools').then((r) => r.json());
  }
  /** AMS slot -> spool assignments; each item embeds the full `spool`. Returns [] on failure so the
   *  AMS view falls back to status-only tray data. */
  async listAssignments(printerId?: number): Promise<SlotAssignment[]> {
    const q = printerId != null ? `?printer_id=${printerId}` : '';
    try {
      return await (await this.req(`/api/v1/inventory/assignments${q}`)).json();
    } catch {
      return [];
    }
  }

  // --- Print history ---
  getPrintLog(limit = 50): Promise<PrintLogPage> {
    return this.req(`/api/v1/print-log/?limit=${limit}`).then((r) => r.json());
  }
  getArchiveStats(): Promise<ArchiveStats> {
    return this.req('/api/v1/archives/stats').then((r) => r.json());
  }
  /** Print-log thumbnails are gated by the camera *stream* token (?token=), NOT X-API-Key —
   *  identical to fileThumbUrl(). Returns '' with no token or no server-side thumbnail. */
  printLogThumbUrl(entryId: number, token: string | null, thumbnailPath?: string | null): string {
    if (!token || thumbnailPath === null) return '';
    return `${this.baseUrl}/api/v1/print-log/${entryId}/thumbnail?token=${encodeURIComponent(token)}`;
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

  // --- Maintenance ---
  getMaintenance(printerId: number): Promise<MaintenancePrinter> {
    return this.req(`/api/v1/maintenance/printers/${printerId}`).then((r) => r.json());
  }
  getMaintenanceSummary(): Promise<MaintenanceSummary> {
    return this.req('/api/v1/maintenance/summary').then((r) => r.json());
  }
  /** MUTATES — resets an item's counter ("mark done"). Body is REQUIRED (bodyless POST 422s). */
  async performMaintenance(itemId: number, notes?: string): Promise<void> {
    await this.req(`/api/v1/maintenance/items/${itemId}/perform`, {
      method: 'POST',
      body: JSON.stringify(notes ? { notes } : {}),
      headers: { 'Content-Type': 'application/json' },
    });
  }

  // --- MakerWorld import ---
  /** Is import configured server-side? can_download gates importMakerWorld(). */
  makerWorldStatus(): Promise<MakerWorldStatus> {
    return this.req('/api/v1/makerworld/status').then((r) => r.json());
  }
  /** Resolve a MakerWorld model URL → design + printable profiles. No cloud token needed.
   *  Throws on 400 (not a MW url) / 404 (model not found). */
  resolveMakerWorld(url: string): Promise<MakerWorldResolved> {
    return this.req('/api/v1/makerworld/resolve', {
      method: 'POST',
      body: JSON.stringify({ url }),
      headers: { 'Content-Type': 'application/json' },
    }).then((r) => r.json());
  }
  /** MUTATING — downloads the 3MF into the library. Requires status.can_download === true. */
  importMakerWorld(body: MakerWorldImportRequest): Promise<MakerWorldImportResponse> {
    return this.req('/api/v1/makerworld/import', {
      method: 'POST',
      body: JSON.stringify(body),
      headers: { 'Content-Type': 'application/json' },
    }).then((r) => r.json());
  }
  /** MakerWorld CDN thumbnail via the server proxy (unauthenticated — URL is sufficient). */
  makerworldThumbUrl(cdnUrl: string | null | undefined): string {
    if (!cdnUrl) return '';
    return `${this.baseUrl}/api/v1/makerworld/thumbnail?url=${encodeURIComponent(cdnUrl)}`;
  }
}
