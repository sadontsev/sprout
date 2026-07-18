/**
 * Thin typed client for the stl-texturize sidecar (deploy/stl-texturize/) — bakes an image as a
 * displacement texture onto a library STL, producing a NEW library file. React-free, like
 * bambuddyClient. Auth is the same X-API-Key the app already holds (the sidecar checks it against
 * its BAMBUDDY_API_KEY).
 */

export interface TexturizeTexture {
  id: string;
  name: string;
  file: string;
}

export type TexturizeJobStatus = 'queued' | 'running' | 'done' | 'error';

export interface TexturizeJob {
  status: TexturizeJobStatus;
  stage: string;
  progress: number; // 0..1
  result_file_id?: number;
  out_triangles?: number;
  warnings?: string[];
  error?: string;
}

export type TexturizeMappingMode = 'triplanar' | 'cubic' | 'cylindrical' | 'spherical' | 'planar_xy' | 'planar_xz' | 'planar_yz';

export interface TexturizeRequest {
  file_id: number;
  texture: { builtin: string } | { image_b64: string };
  /** Displacement depth in mm (server clamps 0–5; default 0.5). */
  amplitude?: number;
  /** Texture tiling scale (server default 0.5; scale_v follows unless lock_scale=false). */
  scale_u?: number;
  scale_v?: number;
  lock_scale?: boolean;
  mapping_mode?: TexturizeMappingMode;
  /** Keep the bed-contact face flat (server default true). */
  protect_bed?: boolean;
  /** Detail in mm — smaller = finer = quadratically more server time/RAM (server floors at 0.15). */
  refine_length?: number;
}

export class TexturizeClient {
  readonly baseUrl: string;
  private readonly apiKey: string;

  constructor(cfg: { baseUrl: string; apiKey: string }) {
    this.baseUrl = cfg.baseUrl.replace(/\/+$/, '');
    this.apiKey = cfg.apiKey;
  }

  private async req(path: string, init?: RequestInit): Promise<Response> {
    const res = await fetch(this.baseUrl + path, {
      ...init,
      headers: { 'X-API-Key': this.apiKey, ...(init?.headers ?? {}) },
    });
    if (!res.ok) {
      const body = await res.text().catch(() => '');
      throw new Error(`texturize ${init?.method ?? 'GET'} ${path} -> HTTP ${res.status} ${body}`.trim());
    }
    return res;
  }

  /** Built-in texture set for the picker. */
  listTextures(): Promise<TexturizeTexture[]> {
    return this.req('/textures').then((r) => r.json());
  }

  /** Thumbnail URL for a built-in texture — needs the X-API-Key header (use with authHeaders()). */
  textureThumbUrl(id: string): string {
    return `${this.baseUrl}/textures/${encodeURIComponent(id)}/thumb`;
  }

  /** Headers for image requests (RN <Image source={{ uri, headers }}>). */
  authHeaders(): Record<string, string> {
    return { 'X-API-Key': this.apiKey };
  }

  /** Enqueue a texturize job. The result lands as a NEW library file. */
  async start(req: TexturizeRequest): Promise<{ job_id: string }> {
    const res = await this.req('/texturize', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(req),
    });
    return res.json();
  }

  getJob(jobId: string): Promise<TexturizeJob> {
    return this.req(`/texturize-jobs/${encodeURIComponent(jobId)}`).then((r) => r.json());
  }
}
