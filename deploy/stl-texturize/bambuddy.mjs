// Bambuddy client for the sidecar — fetches the source model and uploads the textured result, using
// the SAME slicer-token download path the real slicers use. OUR code. Node 24 global fetch/FormData.
// The sidecar holds the Bambuddy API key (like la-push); the app never sees model bytes.

export class Bambuddy {
  constructor({ baseUrl, apiKey }) {
    this.baseUrl = baseUrl.replace(/\/+$/, '');
    this.apiKey = apiKey;
  }

  async #req(path, init = {}) {
    const res = await fetch(this.baseUrl + path, {
      ...init,
      headers: { 'X-API-Key': this.apiKey, ...(init.headers ?? {}) },
    });
    if (!res.ok) {
      const body = await res.text().catch(() => '');
      throw new Error(`Bambuddy ${init.method ?? 'GET'} ${path} -> HTTP ${res.status} ${body}`.trim());
    }
    return res;
  }

  /** Library file record — we need `name` (or `filename`) for the download URL + a sensible output name. */
  async getFileDetail(fileId) {
    return (await this.#req(`/api/v1/library/files/${fileId}`)).json();
  }

  /** Mint a short-lived, single-use download token (POST /slicer-token). The response field name has
   *  varied across Bambuddy versions, so accept the common shapes; throw a clear error otherwise. */
  async mintSlicerToken(fileId) {
    const data = await (await this.#req(`/api/v1/library/files/${fileId}/slicer-token`, { method: 'POST' })).json();
    const token = data.token ?? data.slicer_token ?? data.download_token ?? data.value;
    if (!token) throw new Error(`slicer-token response had no recognizable token field: ${JSON.stringify(data).slice(0, 200)}`);
    return token;
  }

  /** Download raw model bytes via the token path (no auth header — the token IS the auth). */
  async downloadModel(fileId, token, filename) {
    const safe = encodeURIComponent(filename || `model-${fileId}.stl`);
    const res = await fetch(`${this.baseUrl}/api/v1/library/files/${fileId}/dl/${token}/${safe}`);
    if (!res.ok) throw new Error(`Bambuddy download -> HTTP ${res.status}`);
    return Buffer.from(await res.arrayBuffer());
  }

  /** Upload the textured STL back into the library (multipart field `file`, like the app). → { id }. */
  async uploadModel(bytes, name) {
    const form = new FormData();
    form.append('file', new Blob([bytes], { type: 'application/octet-stream' }), name);
    const data = await (await this.#req('/api/v1/library/files', { method: 'POST', body: form })).json();
    if (data.id == null) throw new Error(`upload response had no id: ${JSON.stringify(data).slice(0, 200)}`);
    return data;
  }
}

/** Pick a friendly output name: decode any %20-style residue from an URL-encoded upload, strip the
 *  extension, append "-textured.stl". */
export function texturedName(sourceName, fileId) {
  let name = sourceName || `model-${fileId}`;
  try { name = decodeURIComponent(name); } catch { /* keep raw if malformed */ }
  const base = name.replace(/\.(stl|3mf|obj|gcode(\.3mf)?)$/i, '');
  return `${base}-textured.stl`;
}
