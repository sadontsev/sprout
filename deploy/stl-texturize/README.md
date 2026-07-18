# stl-texturize

A Sprout **sidecar** that bakes an image as a displacement texture onto a library STL — the same idea
as CNC Kitchen's [stlTexturizer / BumpMesh](https://github.com/CNCKitchen/stlTexturizer), run headless
on your home server. The app POSTs a job; the sidecar fetches the source model from Bambuddy (via the
slicer-token download path the real slicers use), runs the texturizer, and uploads the result as a
**new library file**. Everything downstream — slicing, plates, the Print Wizard — is unchanged.

```
app ──POST /texturize {file_id, texture, params}──▶ stl-texturize
                                                       ├─ mint slicer-token + download source model
                                                       ├─ decode texture + run export pipeline
                                                       └─ upload "<name>-textured.stl" to the library
app ◀── poll GET /texturize-jobs/{id} ─────────────────┘  → result_file_id
```

## License / AGPL — read this

The texturizer (`CNCKitchen/stlTexturizer`) is **AGPL-3.0**. This directory does **not** contain it —
the Dockerfile fetches it at build from a **pinned commit** (`TEXTURIZER_SHA`) into `vendor/` (gitignored),
and only `pipeline.mjs` imports it, inside this container. It is never linked into Bambuddy or bundled
into the app. For **personal, single-user** use this is fine. If you ever expose this to other people
(a public URL, more than one user), AGPL §13 requires you offer them the corresponding source; keep the
process/network boundary intact and publish the modified source. *Not legal advice.*

## Deploy (on the home server, next to bambuddy/ and la-push/)

```bash
cd deploy/stl-texturize
cp .env.example .env          # then edit: BAMBUDDY_API_KEY=<the same key the app uses>
docker compose up -d --build  # first build fetches the pinned texturizer + npm deps (~1–2 min)
curl -s localhost:8912/health # → {"ok":true,...}
```

Textures: the build best-effort seeds `./textures` from the vendored set; you can also drop your own
`.png/.jpg/.webp` into `./textures` (it's a mounted volume) — no rebuild needed. Custom per-job textures
are sent inline by the app, so the built-in set is optional.

### Smoke test (proves the whole path against a real library file)

```bash
BAMBUDDY_API_KEY=<key> FILE_ID=<a library stl id> node smoke.mjs
```

## API (all except /health require `X-API-Key: <BAMBUDDY_API_KEY>`)

| Method | Path | Body / result |
|---|---|---|
| GET | `/health` | `{ ok, queued, running }` — open, for the healthcheck |
| GET | `/textures` | `[{ id, name, file }]` — built-in texture picker list |
| GET | `/textures/{id}/thumb` | the texture image bytes |
| POST | `/texturize` | `{ file_id, texture: {builtin} \| {image_b64}, amplitude?, scale_u?, mapping_mode?, protect_bed?, refine_length?, ... }` → `202 { job_id }` |
| GET | `/texturize-jobs/{id}` | `{ status: queued\|running\|done\|error, stage, progress, result_file_id?, warnings?, error? }` |

### Parameters (all optional; safe defaults pinned in `params.mjs`)

- `amplitude` (0–5 mm) — displacement depth. Default 0.5.
- `scale_u` / `scale_v` (+ `lock_scale`, default true) — texture tiling.
- `mapping_mode` — `triplanar` (default) · `cubic` · `cylindrical` · `spherical` · `planar_xy/xz/yz`.
- `protect_bed` (default true) — leave the bed-contact face flat so the print still adheres.
- `refine_length` (mm) — detail. **Smaller = finer = quadratically more RAM/time.** Floored at
  `TEXTURIZE_MIN_REFINE_LENGTH` (0.15). Cost ≈ surface_area / refine_length².
- `rotation`, `offset_u/v`, `invert`, `symmetric`, `bottom_angle_limit`, `top_angle_limit`, `max_triangles`.

Oversized jobs are **rejected before running** (pre-flight) with a message telling the user to use a
coarser detail — this is what keeps a fine-resolution job from OOMing the box.

## Config (env / compose)

| Var | Default | Meaning |
|---|---|---|
| `BAMBUDDY_URL` | `http://localhost:8910` | Bambuddy base (host-networked) |
| `BAMBUDDY_API_KEY` | — (required) | gates this service **and** its calls to Bambuddy |
| `TEXTURIZE_MAX_TRIANGLES` | `12000000` | pre-flight budget (~1.7 GB peak) |
| `TEXTURIZE_MIN_REFINE_LENGTH` | `0.15` | floor on detail, guards RAM |
| `PORT` | `8912` | |

## Tests

`node --test` covers the pure modules (`stl.mjs` round-trip, `params.mjs` normalization + pre-flight).
The pipeline itself is exercised by `smoke.mjs` against your live Bambuddy after deploy.
