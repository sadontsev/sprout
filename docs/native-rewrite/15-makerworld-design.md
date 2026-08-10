# 15 — MakerWorld → printed object, entirely from the app

Design for the end-to-end path: find a model on MakerWorld, get it into the library, get it sliced
for **this** H2C with **these** spools, and get it printing — without leaving Sprout.

This is a design document. No application code is proposed here; every claim below is either read
out of the repository, read out of the running Bambuddy container, or probed against the live API,
and the probe is quoted so the next person can re-run it.

> Placeholders: `<BAMBUDDY>` is the Bambuddy base URL (LAN or the tunnelled host), `<KEY>` the app's
> `X-API-Key`. Never print either. The owner's printer is **printer id 2, model `H2C`**.

---

## 0. TL;DR

| | |
|---|---|
| **What works today** | Paste a `makerworld.com/models/…` URL → server resolves it anonymously → pick a profile → import the 3MF into the library. |
| **What is broken today** | The profile rows are decoded from a payload that *does not contain* the fields they read, so every row shows `—` for time, no weight, no AMS badge and no filament swatches. `can_download` conflates two unrelated conditions and currently tells the owner to fix the wrong thing. |
| **What is missing** | Discovery (search/browse), licence display, the hand-off from import into printing, multi-filament mapping, and any honest statement about what an imported file actually is. |
| **The big surprise** | **MakerWorld search and browse work fine, anonymously, from a server.** Bambuddy's "search returns empty for server-originated requests" note is about `design-service/design/search`; the endpoint the site actually uses is `search-service/search/design`, and it returns 7 070 hits for `benchy` from the home server with no token at all. |
| **The load-bearing constraint** | An imported MakerWorld profile is an **unsliced project 3MF prepared for someone else's printer**. It must be re-sliced for the H2C before it can print. There is no shortcut. |
| **Phase 1** | Stop lying: fix the profile decode, split the `can_download` predicate, show the licence, and route a successful import straight into the existing wizard with its answers pre-seeded. No new backend, no new network dependency. |

---

## 1. What exists today

### 1.1 In the app

| Where | What |
|---|---|
| `native/Sprout/Api/BambuddyClient.swift:604-623` | `makerWorldStatus()`, `resolveMakerWorld(_:)`, `importMakerWorld(_:)`, `makerworldThumbUrl(_:)`. |
| `native/Sprout/Api/Models.swift:512-586` | `MakerWorldStatus`, `MWFilament`, `MWInstance`, `MWDesign`, `MakerWorldResolved`, `MakerWorldImportRequest`, `MakerWorldImportResponse`. |
| `native/Sprout/Views/Overlays/UploadSheet.swift:308-760` | `MakerWorldPanel` — the whole feature: link field, cover, byline, "Already in your library" badge, profile list, import button. Reached from the Add-file sheet's *From MakerWorld* row (`:207`). |
| `docs/native-rewrite/06-overlays.md:230-300` | The ported RN spec for the same panel. |

Flow: `MakerWorldPanel.task` calls `makerWorldStatus()` once and latches `canDownload`; `resolve()`
posts the URL and shows the design; tapping a row sets `picked`; `doImport()` posts
`{model_id, profile_id, instance_id}`, fires `onImported` (which refetches the Files list), sets a
toast and closes the sheet. **The user is returned to the Files list. Nothing else happens.**

### 1.2 On the server

Bambuddy **0.2.4.9**, 548 OpenAPI paths. The MakerWorld surface is exactly five endpoints:

```
GET  /api/v1/makerworld/status           → {has_cloud_token, can_download}
POST /api/v1/makerworld/resolve          → {model_id, profile_id, design, instances[], already_imported_library_ids[]}
POST /api/v1/makerworld/import           → {library_file_id, filename, folder_id, profile_id, was_existing}
GET  /api/v1/makerworld/recent-imports   → [{library_file_id, filename, folder_id, thumbnail_path, source_url, created_at}]
GET  /api/v1/makerworld/thumbnail?url=   → image bytes (UNAUTHENTICATED, CDN-host allowlisted)
```

Plus the Bambu Cloud account plumbing that gates imports:

```
GET  /api/v1/cloud/status   POST /api/v1/cloud/login   POST /api/v1/cloud/verify
POST /api/v1/cloud/token    POST /api/v1/cloud/logout
```

Server implementation, read out of the container
(`/app/backend/app/services/makerworld.py`, `/app/backend/app/api/routes/makerworld.py`):

- Upstream base is **`https://api.bambulab.com/v1/design-service`**, not `makerworld.com` — the
  website is behind Cloudflare and fingerprints plain HTTP clients as bots. The service identifies
  itself honestly (`User-Agent: Bambuddy/1.0 (+https://github.com/maziggy/bambuddy)`).
- `resolve` = `GET /design/{id}` + `GET /design/{id}/instances`, **both anonymous**. It then merges
  `compatibility`/`otherCompatibility` from `design.instances[]` onto the `/instances` hits, and
  looks up any `LibraryFile` whose `source_url` matches `https://makerworld.com/models/{id}` or
  `…#profileId-%`.
- `import` = `GET /design/{id}` (to get the **alphanumeric** `modelId`, e.g. `US2262720d55a8f6`) →
  `GET https://api.bambulab.com/v1/iot-service/api/user/profile/{profileId}?model_id={modelId}`
  **with the stored Bambu Cloud bearer** → `{url, name}` where `url` is a ~5-minute signed CDN or S3
  URL → download (200 MB cap, host allowlist, no redirects) → `save_3mf_bytes_to_library`.
- Imports land in an auto-created top-level **`MakerWorld`** folder unless `folder_id` is given.
- Dedupe is **per plate**: `source_url` is `https://makerworld.com/models/{id}#profileId-{pid}`.
- Errors are mapped: `400` bad URL, `401` cloud token rejected, `403` content-gated (paid / points /
  region / early access — MakerWorld's own message is forwarded verbatim), `404` not found, `502`
  everything else including the CAPTCHA case.

### 1.3 Live probes (run 2026-08-10)

```bash
# printers
curl -s -H "X-API-Key: <KEY>" <BAMBUDDY>/api/v1/printers/
# → [{"id":2,"name":"H2C","model":"H2C","is_active":true, …}]

curl -s -H "X-API-Key: <KEY>" <BAMBUDDY>/api/v1/makerworld/status
# → {"has_cloud_token":false,"can_download":false}

curl -s -H "X-API-Key: <KEY>" <BAMBUDDY>/api/v1/cloud/status
# → {"detail":"This API key is not authorised to access Bambu Cloud data.
#     Enable 'Allow cloud access' on the key in Settings → API Keys."}

curl -s -H "X-API-Key: <KEY>" "<BAMBUDDY>/api/v1/makerworld/recent-imports?limit=5"
# → []   (nothing has ever been imported)
```

And, from the Bambuddy SQLite (read-only, values never printed):

| Fact | Value |
|---|---|
| `users` | one row, `max`, **`cloud_token` IS set**, `cloud_region = "global"` |
| `settings` where key like `bambu_cloud%` | **none** (token lives per-user, not global) |
| `api_keys` | `1 ios-app can_access_cloud=0` · `2 Claude Mac =1` · `3 iOS-app-new =1` · `4 claude-native-test =1` |
| Key in `~/.config/bambu-phase0/bb_apikey` | matches prefix of **key 1, `ios-app`, `can_access_cloud = 0`** |

**So the server is signed in to Bambu Cloud. `can_download:false` above is purely an artefact of the
key used for the probe.** See §3.

---

## 2. Discovery: is there a browse/search API?

Bambuddy's own route file says no:

> Search/browse endpoints are intentionally NOT exposed: the public-facing `design/search` endpoint
> returns empty results from server-originated requests.
> — `/app/backend/app/api/routes/makerworld.py`

and the [Bambuddy wiki](https://wiki.bambuddy.cool/features/makerworld/) repeats it:

> Browse / search is not available. MakerWorld's public search endpoint returns empty results for
> server-originated requests (requires browser-specific session state we can't reproduce from a
> backend).

**That conclusion is about one endpoint, and it does not generalise.** Probed from the home server,
anonymously, with Bambuddy's own honest User-Agent:

| Request | Result |
|---|---|
| `GET api.bambulab.com/v1/design-service/design/search?keyword=benchy&limit=3` | `200` — `{"total":0,"hits":null}` ← **the endpoint the note is about** |
| `GET api.bambulab.com/v1/search-service/search/design?keyword=benchy&offset=0&limit=3` | `200` — **`{"total":7070,"hits":[…]}`** |
| `GET api.bambulab.com/v1/search-service/select/design/nav?navKey=Trending&offset=0&limit=5` | `200` — `{"total":799,"hits":[…]}`, 18 KB |
| `GET api.bambulab.com/v1/search-service/select/design/nav?navKey=category_400&offset=0&limit=3` | `200` — `{"total":795,"hits":[…]}` |
| `GET api.bambulab.com/v1/search-service/design/search?keyword=benchy` | `404 page not found` |

This is the codebase's own recurring bug at ecosystem scale: `design-service/design/search` and
`search-service/search/design` are two different questions that sound like synonyms, and testing the
first one and concluding "search doesn't work" is exactly the `isSliced` / `hasGcode` mistake.

Endpoint inventory corroborated by
[Doridian/OpenBambuAPI `cloud-makerworld.md`](https://github.com/Doridian/OpenBambuAPI/blob/main/cloud-makerworld.md),
which documents `search-service/homepage/nav`, `search-service/select/design/nav`,
`search-service/design/{id}/relate` and `search-service/recommand/youlike` (it claims Bearer auth is
required for all of them; the probes above show at least `search/design` and `select/design/nav`
answer anonymously — treat "auth required" in that document as "auth is what Handy sends", not "auth
is enforced").

### Search hit shape (`search-service/search/design`)

Envelope `{total, hits[], suggest}`. Each hit carries everything a browse grid needs:

```
id  title  titleHighlight  slug  cover  coverPortrait  coverLandscape
license  is_printable  is_official  is_point_redeemable  isExclusive  nsfw  status
likeCount  collectionCount  printCount  downloadCount  commentCount  tags[]
designCreator{uid,name,avatar,handle,certificated}  createTime  hotScore  designScore  score
designExtension{design_pictures[],design_video[],model_files[]}
```

Note what is **absent**: the alphanumeric `modelId`, the instance list, print time, weight. A hit is
enough for a grid tile and nothing more — the detail sheet still has to `resolve`.

A hit maps to a resolvable URL by construction: `https://makerworld.com/models/{id}` (the slug and
locale are optional; `MakerWorldService.parse_url` only needs `/models/{digits}`).

**Sorting and filtering are unverified.** `&sort=new`, `&sort=hot` and `&filterMultiColor=true` were
all silently ignored (identical `total` and first hit). Either the parameter names differ or the
endpoint only does relevance. This is a spike (§10, S-2), not a design assumption.

---

## 3. Authentication: what a Bambu Cloud token is really for, and what `can_download` really gates

### 3.1 Three independent conditions, one boolean

Downloading a MakerWorld 3MF needs a Bambu Cloud bearer, because the only known non-cookie path to a
signed download URL is `iot-service/api/user/profile/{profileId}`. Resolving does **not** — every
`design-service` call Bambuddy makes is anonymous, which is why the panel can preview a model with
no cloud account at all.

But `GET /makerworld/status` answers with one boolean derived from a chain of three:

```python
cloud_token_user = current_user or api_key_cloud_owner   # ← None if the key lacks cloud scope
token, _, _ = await get_stored_token(db, cloud_token_user)
return MakerWorldStatus(has_cloud_token=bool(token), can_download=bool(token))
```

so `can_download: false` means **any** of:

1. the server has never been signed in to Bambu Cloud; **or**
2. the token expired (Bambu Cloud tokens last ~90 days and cannot be refreshed — the user must sign
   in again); **or**
3. the caller's API key does not have **`can_access_cloud`**, in which case `resolve_api_key_cloud_owner`
   returns `None` and `get_stored_token(db, None)` falls back to the *global* `settings` table, which
   on this install is empty — so it reports "no token" while a perfectly good token sits on the user row.

Today, on this server, it is **case 3 and only case 3**. The app's copy says:

> "MakerWorld isn't connected on your Bambuddy server. You can preview a model, but to import it,
> sign in to Bambu Cloud in Bambuddy → Settings → MakerWorld."
> — `UploadSheet.swift:419`

That instruction is wrong for the situation the owner is actually in. Signing in again would change
nothing. The fix is to tick **Allow cloud access** on the API key in Bambuddy → Settings → API Keys.

And `can_download: true` still does not mean the *next* import will succeed: `403` content-gating
(paid model, points-redeemable, region-locked, early access) and `418` CAPTCHA are per-model and
per-IP and are only discovered at import time.

**Design rule.** Three predicates, named for the questions they answer, never collapsed:

| Predicate | Question | Source |
|---|---|---|
| `cloudReadable` | "Can this API key even see the cloud account?" | `GET /cloud/status` ≠ 403 |
| `serverHasCloudToken` | "Is a Bambu Cloud token stored and unexpired?" | `GET /cloud/status.is_authenticated`, or `/makerworld/status.has_cloud_token` **when `cloudReadable`** |
| `modelIsGettable` | "Will *this* model download?" | unknowable before the attempt — `design.paidSetting.isPaid`, `isPointRedeemable`, `isExclusive` are hints, the `403` body is the answer |

Which yields three different remedies in the UI instead of one wrong one:

- `!cloudReadable` → "This app's API key can't read your Bambu Cloud login. Enable **Allow cloud
  access** on the key in Bambuddy → Settings → API Keys." *(This is today's actual state.)*
- `cloudReadable && !serverHasCloudToken` → "Sign in to Bambu Cloud in Bambuddy → Profiles → Cloud
  Profiles." (Add: tokens last ~90 days.)
- `403` at import → show MakerWorld's own refusal text verbatim + **Open on MakerWorld**.

### 3.2 What is NOT needed

- No separate MakerWorld OAuth. Same SSO backend as Bambu Cloud.
- No cloud token on the **phone**. The token never leaves the server; the app only ever learns
  whether one exists. Keep it that way — nothing in this design should ever put a Bambu Cloud
  bearer in the iOS Keychain.
- No cloud token for search or resolve.

---

## 4. Picking a profile when a model has several

### 4.1 The shape, measured

`POST /makerworld/resolve` returns two lists and the app reads the wrong one.

| List | Where | Count for model 40146 | Count for model 1400373 |
|---|---|---|---|
| `instances` (what the app renders) | `GET /design/{id}/instances` → `hits` | 88 | 7 |
| `design.instances` (ignored) | inside `GET /design/{id}` | 37 | 7 |

Key frequency across all 88 hits of model 40146:

```
id 88 · creator 88 · title 88 · profileId 88 · cover 88 · pictures 88 · accessories 88
score 88 · createTime 88 · updateTime 88 · subinstances 88 · detail 88
compatibility 37 · otherCompatibility 37        ← merged in by Bambuddy, only where design.instances had it
```

`prediction`, `weight`, `needAms`, `instanceFilaments` and `extention` **never appear at the top
level of a hit**. `MWInstance` (`Models.swift:526-547`) decodes exactly those five and nothing else
of substance, and its fallback chain
(`i.prediction ?? i.extention?.modelInfo?.plates?.first?.prediction`, `UploadSheet.swift:717-735`)
walks two paths that are both nil. The hit does contain a `detail` sub-object with the same names —
but on the models probed it is a zeroed placeholder (`id: 0, profileId: 0, prediction: 0,
appCanPrint: false, instanceFilaments: null`).

**Net effect today: every profile row renders `—`, no grams, no AMS badge, and zero filament
swatches, on every model.** This is not a rare edge case; it is the default rendering.

The real data is in `design.instances[]`:

```jsonc
// design.instances[0] of model 1400373
{ "id": …, "profileId": 298919107, "title": "…",
  "prediction": 40048, "weight": 322, "needAms": false,
  "materialCnt": 3, "materialColorCnt": 3, "appCanPrint": true, "hasZipStl": true,
  "isDefault": false, "downloadCount": …, "ratingScoreTotal": …, "ratingCount": …,
  "instanceFilaments": [
    {"type":"PLA","color":"#646941","usedM":"72.06","usedG":"230"},
    {"type":"PLA","color":"#C0C0C0","usedM":"10.95","usedG":"35"},
    {"type":"PETG","color":"#FFFFFF","usedM":"18.92","usedG":"57"}],
  "extention": { "modelInfo": {
      "compatibility":      {"devModelName":"BL-P001","devProductName":"X1 Carbon","nozzleDiameter":0.4},
      "otherCompatibility": [ …, {"devModelName":"O1C2","devProductName":"H2C","nozzleDiameter":0.4}, … ],
      "projectSettings":    {"layerHeight":"0.25","wallLoops":"2","sparseInfillDensity":"10%"},
      "hasFilamentMixed":   false,
      "plates": [ {"index":1,"prediction":1895,"weight":12,
                   "filaments":[{"id":"1","type":"PLA","color":"#FFFFFF","usedM":"3.82","usedG":"12"}],
                   "thumbnail":{"url":"https://makerworld.bblmw.com/…/plate_1.png"},
                   "warning":[]}, … ] } } }
```

Also on the design: `defaultInstanceId` — MakerWorld's own answer to "which profile should be
selected first".

### 4.2 What the picker should actually say

Join on `profileId`: `design.instances[]` is the record; the `/instances` hits add nothing except a
longer tail of profiles for which MakerWorld itself publishes no metadata. Rank and label:

| Signal | Use |
|---|---|
| `extention.modelInfo.compatibility.devProductName` == `H2C`, or `otherCompatibility[].devProductName` contains `H2C` | badge **"Made for H2C"** / **"Also marked H2C"**; otherwise **"Sliced for X1 Carbon"** |
| `compatibility.nozzleDiameter` vs mounted nozzles (`status.nozzles[]` — currently `0.6 HS01` + `0.4 HH05`) | badge **"needs 0.4"** when it does not match anything mounted |
| `prediction` / `weight` | the time·grams line the row already tries to render |
| `instanceFilaments[]` | the swatch row, and the count that drives §6 mapping |
| `materialCnt` vs `materialColorCnt` | "3 materials, 3 colours" vs "1 material, 4 colours" — the difference between needing PETG loaded and just needing four spools |
| `needAms` | AMS badge |
| `plates.count > 1` | **"4 plates"** — this profile is not one print, it is four |
| `isDefault` / `design.defaultInstanceId` | pre-select |
| `appCanPrint` | see the trap below |

> **Trap — the fourth instance of the recurring bug.** `otherCompatibility` contains `H2C` ⇏ the
> downloaded file contains H2C toolpaths. `appCanPrint: true` ⇏ Sprout can print it. Both answer
> "MakerWorld considers this profile applicable to that machine", which is a *slicing-settings*
> claim. Whether there is printable G-code for *this* H2C is a different question with a different
> answer (§5). Do not gate a Print button on either.

---

## 5. Is an imported 3MF already sliced for this printer?

**No. Assume it never is.** Three independent lines of evidence:

1. **The integration's own documentation.**
   [Bambuddy wiki → MakerWorld](https://wiki.bambuddy.cool/features/makerworld/):
   > "Unsliced source files only. MakerWorld plates are project files; Bambuddy can save them to
   > your library but can't send them to a printer directly."

2. **The ingest path cannot classify it as sliced.** `save_3mf_bytes_to_library` sets
   `file_type = classify_file_type(filename)`, and `classify_file_type` only returns `gcode.3mf`
   for a name ending in `.gcode.3mf`. MakerWorld's manifest `name` is a plain `.3mf`. So
   `LibraryFile.file_type == "3mf"` and `LibraryFileCaps.hasGcode(f) == false` for every MakerWorld
   import, by construction.

3. **The profile targets someone else's machine anyway.** Both probed models' default profiles are
   `compatibility: X1 Carbon 0.4` / `A1 0.4`. Even if toolpaths were present they would be for a
   350×320 mm dual-nozzle machine's *neighbour*, and `PrinterProfile.matchesSlicedFor` would (rightly)
   refuse the print.

### 5.1 The predicate this needs

`LibraryFileCaps.hasGcode` answers *"will `/library/files/{id}/gcode` answer?"* from the filename,
which is correct for library files Sprout itself produced and correct-by-luck here. It is **not** the
predicate for "can this MakerWorld import print as-is". That one has three parts and all three must
hold:

```
importPrintableAsIs(file) =
      fileContainsToolpaths(file)          // Metadata/plate_N.gcode exists
   && plates.embedded_printer matches the H2C   // PrinterProfile.matchesSlicedFor
   && every required filament can be mapped to a loaded tray
```

Bambuddy does not expose `fileContainsToolpaths` cheaply. The exact answer is
`GET /library/files/{id}/gcode` → `200` vs `404` — verified live: file 40 (project 3MF)
`HTTP 404, 39 bytes`; file 41 (`cr.gcode.3mf`) `HTTP 200, 69 890 554 bytes`. Downloading 70 MB to
answer a yes/no is not acceptable on cellular.

The cheap proxy is `GET /library/files/{id}/plates` → `plates[].print_time_seconds != null`
(measured: `null` for the project 3MF, `36285` for the sliced one) — but it is a *proxy*: those
numbers come from `Metadata/slice_info.config`, which MakerWorld's cloud slicer may well write into
a file that has no G-code. **So do not build a "print as-is" affordance on it.**

**Design decision: MakerWorld imports always go through the slicer.** No fast path, no "maybe it's
already sliced" branch. This is not a limitation to apologise for; it is the truthful behaviour, and
it is the same thing Bambu Studio does when you press "Open in Bambu Studio" on a MakerWorld profile.
If a cheap exact signal appears later (an upstream `has_gcode` flag on the plates response — §10 S-4),
the fast path can be added then, gated on the exact predicate.

### 5.2 Slicing a MakerWorld import for the H2C

Everything needed already exists in `POST /library/files/{id}/slice`:

```jsonc
{ "printer_preset":  {"source":"standard","id":"Bambu Lab H2C 0.4 nozzle"},
  "process_preset":  {"source":"standard","id":"0.20mm Standard @BBL H2C"},
  "filament_presets":[{"source":"standard","id":"Bambu PLA Basic @BBL H2C"},
                      {"source":"standard","id":"Bambu PLA Basic @BBL H2C"},
                      {"source":"standard","id":"Bambu PETG HF @BBL H2C"}],
  "plate": 1, "bed_type": "Textured PEI Plate", "export_3mf": true }
```

Presets confirmed present on the live server: 5 H2C printer presets (`0.2/0.4/0.6/0.8` + base),
16 H2C process presets, 189 H2C filament presets.

Three things the current wizard does not do, that a multi-material MakerWorld import needs:

- **`filament_presets` (plural).** `WizardView.runSliceStep` sends only `filament_preset`
  (singular, `WizardView.swift:1219`). A 3-filament model needs three entries, in slot order.
- **`plate`.** A single MakerWorld profile can carry several plates (model 1400373's default
  profile has **4**). `plate: 0` is the sidecar's "all plates" sentinel and produces one multi-plate
  output; Bambuddy has a dedicated cross-class loop for it (`library.py:3587`) that slices each plate
  with `--arrange 1` and merges, precisely because the source's nozzle class differs from the
  target's — which is the MakerWorld case every time. Per-plate (`plate: N`) is the simpler and
  more predictable choice for v1.
- **Homogeneous unused slots.** Bambuddy already handles this (`substitute_unused_plate_filaments`) —
  worth knowing so the "temperature difference too large" failure isn't misdiagnosed as ours.

### 5.3 Filament mapping on this machine specifically

The H2C reports (live, `GET /printers/2/status`):

```jsonc
"nozzles": [ {"nozzle_type":"HS01","nozzle_diameter":"0.6"},      // extruder 0
             {"nozzle_type":"HH05","nozzle_diameter":"0.4"} ],    // extruder 1
"active_extruder": 0,
"ams": [ {"id":0,   "module_type":"n3f", "tray":[4]},             // global ids 0–3
         {"id":1,   "module_type":"n3f", "tray":[4]},             // global ids 4–7
         {"id":128, "module_type":"n3s", "is_ams_ht":true, "tray":[1]} ],   // global id 128
"vt_tray": [ {"id":254, …}, {"id":255, …} ],                      // external, deputy / main
"fila_switch": {"installed":true,"in_slots":[256,-1],"out_extruders":[0,0],"stat":0,"info":1},
"ams_extruder_map": {}, "ams_mapping": []
```

That is **9 addressable trays** (0–3, 4–7, 128) plus two virtual ones, a **Filament Track Switch**
present (`fila_switch.installed: true`), and two different nozzles.

What the wire format wants (`bambu_mqtt.py:start_print`):

- `ams_mapping` is **indexed by the 3MF's filament slot, valued by global tray id**. Global id =
  `ams_id * 4 + slot_id`; AMS-HT units use the unit id directly (≥128); `254`/`255` are the deputy
  and main external spools; `-1` is unmapped. Bambuddy derives `ams_mapping2` from it and rewrites
  `254/255` to `-1` in the flat array (H2D/H2C firmware rejects raw 254 there).
- The wizard today sends **`ams_mapping: [slot]` — a one-element array** (`WizardView.swift:1291`),
  which is correct for a single-filament print and silently wrong for a 3-filament MakerWorld model:
  filaments 2 and 3 are unmapped.

What Sprout already has to build the real array: `GET /library/files/{id}/filament-requirements[?plate_id=]`,
which on a sliced 3MF returns exactly the join key —

```jsonc
{"filaments":[{"slot_id":1,"type":"PETG","color":"#00AE42",
               "used_grams":157.2,"used_meters":51.06,
               "tray_info_idx":"GFG02","used_in_plate":true,"nozzle_id":0}]}
```

`nozzle_id` is the extruder the slicer assigned that slot to — the dual-nozzle field. It is derived
from `Metadata/slice_info.config` via `extract_nozzle_mapping_from_3mf`, so it exists **after**
Sprout's own slice, not on the raw MakerWorld import (which returned `used_grams: 0`, no
`tray_info_idx`, no `nozzle_id` on the comparable project file 40).

**The honest gap to state plainly: `PrintQueueItemCreate` has no `nozzle_mapping` field.** The
schema carries `ams_mapping`, `plate_id`, `use_ams`, `nozzle_offset_cali` and the calibration flags,
but the H2C rack-pick `nozzle_mapping` (#1780) only reaches the printer via the virtual-printer path
(Bambu Studio → Bambuddy VP). Queued prints therefore fall back to the firmware's "last matching
nozzle" auto-pick. For a single-material print that is fine. For a two-material print where the user
cares which nozzle runs which material, **Sprout cannot express the choice**, and the UI must say so
rather than offer a picker that does nothing. (Upstream request — §10 S-5.)

---

## 6. The proposed flow, screen by screen

Two entry points converge on one detail sheet, which converges on the existing wizard.

```
 Files tab  ──▶ [+] ──▶ Add a file ──▶ From MakerWorld
                                          │
   ┌──────────────────────────────────────┴──────────────────────────────────┐
   │  A. Paste a link            B. Search / Browse   (phase 2)              │
   └──────────────────────────────────────┬──────────────────────────────────┘
                                          ▼
                              ①  Model detail  (resolve)
                                          ▼
                              ②  Profile picker
                                          ▼
                              ③  Import  (+ licence acknowledgement)
                                          ▼
                              ④  Print wizard, pre-seeded   ── existing 7 steps
                                          ▼
                              ⑤  Queue → Dashboard
```

### ⓪ Entry — the Add-file sheet

Unchanged, except the *From MakerWorld* row gains a subtitle that reflects §3's three-way state:
`Paste a link` / `Search models` (phase 2) / `Needs cloud access on this key` (dimmed-with-reason,
never hidden — the panel still previews).

### ① Model detail

Existing `MakerWorldPanel` design block, plus:

| Element | Source |
|---|---|
| Cover, title, `@creator · N downloads` | `design.coverUrl`, `title`, `designCreator.name`, `downloadCount` — via `GET /makerworld/thumbnail?url=` |
| **Licence chip** | `design.license` (`"BY-ND"`, `"BY-NC"`, `"Standard Digital File License"`, …) |
| **Licence detail on tap** | `design.licenseDescriptionInfo.{title,content}` — MakerWorld ships ready-made prose; render it, do not paraphrase |
| **"Remix of …"** | `design.originals[]` → `{title, author, link}` (model 40146 credits `thingiverse.com/thing:763622`, CreativeTools) |
| **"May need payment / points"** | `design.paidSetting.isPaid`, `isPointRedeemable`, `pointRedeemDetail.price`, `isExclusive` |
| "Already in your library" | `already_imported_library_ids` (existing) |
| **Open on MakerWorld** | `https://makerworld.com/models/{model_id}` — the escape hatch for every failure in §8 |

API: `POST /api/v1/makerworld/resolve {url}` — unchanged, one call, no token.

### ② Profile picker

Rows built from the §4.2 join, not from the hits alone. Row content:

```
 ┌──────┐  0.20mm · PLA×2 + PETG · 3 colours
 │ img  │  11h 07m · 322 g · AMS · 4 plates
 └──────┘  Made for X1 Carbon 0.4  ·  also marked H2C
```

with a chevron-disclosed plate strip when `plates.count > 1` (thumbnails come straight from
`plates[].thumbnail.url`, proxied). Pre-select `design.defaultInstanceId`, else `isDefault`, else
the first with `appCanPrint`.

A profile whose `compatibility.nozzleDiameter` matches nothing mounted gets a caution line — not a
block. The H2C currently has 0.6 and 0.4 mounted, so a 0.2-nozzle profile is a real mismatch worth
saying out loud before a 40-minute download.

### ③ Import

`POST /api/v1/makerworld/import {model_id, profile_id, folder_id?}`
(`instance_id` is documented as *"Retained for backwards compatibility; no longer used by the
download flow"* — keep sending it or don't, it is inert.)

Response: `{library_file_id, filename, folder_id, profile_id, was_existing}`.
`folder_id` and `profile_id` are **not currently decoded** by `MakerWorldImportResponse`
(`Models.swift:582`) and both are useful — `folder_id` to deep-link the Files tab at the
auto-created `MakerWorld` folder, `profile_id` to match the response back to the picked row.

Before the button fires, if the licence is `Standard Digital File License` or any `-ND` variant,
show the one-line obligation inline (§7). Not a modal. Not a checkbox. One line under the button.

### ④ Hand-off into the wizard — and how much of it to skip

**Keep the 7-step wizard. Do not build a second print path.** It is where `LockedActions` /
LAN-mode gating, the wrong-printer guard, the plate review, the layer viewer, advanced overrides and
the enqueue call all already live. A parallel "quick print" would duplicate every one of those and
drift from them — which is how this codebase has produced four affordance bugs already.

What changes is that the wizard arrives **pre-seeded** from the MakerWorld metadata, so the user
confirms rather than composes. Import success sets `model.overlay = .wizard(file)` directly (with a
`MakerWorldSeed` alongside it) instead of closing to the Files list.

| Wizard step | Today | With a MakerWorld seed |
|---|---|---|
| 1 File | shows the picked file | same, plus the model title, creator and licence chip so provenance survives the hand-off |
| 2 Printer | confirm H2C | unchanged. If the profile's `compatibility` names another machine, show it here as context, not as an error — we are about to re-slice, so it is not a mismatch |
| 3 Material | one filament + quality | **N filament pickers**, one per `instanceFilaments[]` entry, each pre-selected by matching MakerWorld's `{type, color}` against `FilamentMatch.loaded(…)`. Quality pre-selected from `projectSettings.layerHeight` → nearest `…@BBL H2C` process preset |
| 4 Slicing | progress | same call, now with `filament_presets[]` and the chosen `plate` |
| 5 Review | time / grams | same, plus a **MakerWorld-said vs we-measured** comparison (`prediction`/`weight` from the profile against `slice-jobs/{id}.result`). A 3× discrepancy is the cheapest possible signal that the wrong plate or the wrong nozzle got picked |
| 6 Map filament | one tray | **N rows**, `filament-requirements` × `AmsTopology.trayRefs`, producing the full `ams_mapping` array. Unmappable slot → `-1` and a named warning, never a silent default |
| 7 Start | enqueue | unchanged shape, `ams_mapping` now length-N, plus `plate_id` |

Steps 3 and 6 are the only genuinely new UI, and both are needed for *any* multi-material print, not
just MakerWorld ones — so the work is not MakerWorld-specific and should not be scoped as if it were.

**Nothing is skipped.** The alternative — a two-tap "import and print" — would have to answer the
filament-mapping question silently, and there is no defensible silent answer for a 3-material model
on a 9-tray machine.

### ⑤ After Start

Unchanged: `model.overlay = nil`, `model.tab = .printer`.

### API call inventory for the whole flow

| Step | Call |
|---|---|
| gate | `GET /api/v1/cloud/status` · `GET /api/v1/makerworld/status` |
| search (ph. 2) | `GET https://api.bambulab.com/v1/search-service/search/design?keyword=&offset=&limit=` |
| browse (ph. 2) | `GET …/v1/search-service/select/design/nav?navKey=&offset=&limit=` |
| detail | `POST /api/v1/makerworld/resolve` |
| images | `GET /api/v1/makerworld/thumbnail?url=` (unauthenticated proxy, CDN allowlist) |
| import | `POST /api/v1/makerworld/import` |
| recents | `GET /api/v1/makerworld/recent-imports?limit=` |
| file | `GET /api/v1/library/files/{id}` · `GET /api/v1/library/files/{id}/plates` |
| mapping | `GET /api/v1/library/files/{id}/filament-requirements?plate_id=` |
| presets | `GET /api/v1/slicer/presets` |
| slice | `POST /api/v1/library/files/{id}/slice` → `GET /api/v1/slice-jobs/{job}` |
| print | `POST /api/v1/queue/` |

---

## 7. Licensing and attribution

The data is already in the resolve response — there is no excuse for not showing it.

| Field | Example values seen |
|---|---|
| `design.license` | `"BY-ND"` (model 40146) · `"Standard Digital File License"` (model 1400373) · `"BY-NC"` (a search hit). CC variants (`BY`, `BY-SA`, `BY-NC`, `BY-NC-SA`, `BY-ND`, `BY-NC-ND`) plus MakerWorld's proprietary SDFL. |
| `design.licenseDescriptionInfo` | `{title, content}` — for 1400373: *"This user content is licensed under a Standard Digital File License."* + the full "You shall not share, sub-license, sell, rent, host, transfer, or distribute…" text. |
| `design.originals[]` | upstream attribution when the model is a remix: `{title, author, homepage, link, license}`. |
| `design.designCreator.{name, handle}` | the attribution string. |
| search hit `license` | same code, so the grid can chip it before you even open the model. |

**What Sprout is obliged to do.** Printing for yourself is inside every one of these licences,
including the [Standard Digital File License](https://modelrover.com/g/makerworld-standard-digital-file-license),
which permits unlimited personal prints and prohibits redistribution of the digital or printed
object. This is a single-user app that prints on the owner's own machine, so no licence in play
restricts the *use*. Two obligations do bite:

1. **Do not redistribute.** Sprout stores the 3MF in a private library on the owner's own server.
   That is fine. It would stop being fine the moment any share/export/upload affordance appeared, so
   if one ever does, it must be gated per-licence. Nothing in this design adds one.
2. **Preserve attribution.** CC-BY-* requires credit. The cheapest correct behaviour: carry creator,
   licence code and the canonical `source_url` (which Bambuddy already stores on the `LibraryFile`)
   into the Files row, the wizard's File step and the print-history entry, so provenance survives the
   `makerworld-1400373.3mf` filename.

**Show the licence before the download, not after.** A `-ND` or SDFL chip on the import button is
the difference between an informed personal print and a surprise.

Not affiliated with or endorsed by Bambu Lab or MakerWorld; the endpoints are community-documented
and used for interoperability only. Bambuddy states the same in its module docstring, and the same
statement should appear once in Sprout's own Settings → About if search ships.

---

## 8. Offline, degraded and failure behaviour

Two networks, not one. The phone → Bambuddy hop and the Bambuddy → Bambu Cloud hop fail
independently, and the UI must not blame the wrong one.

| Failure | Where it surfaces | What the user must see |
|---|---|---|
| Phone has no route to Bambuddy | every call | The existing disconnected card in `UploadSheet`. Do not offer MakerWorld at all. |
| Bambuddy up, **server** has no internet | `resolve` → `502` (`MakerWorldUnavailableError`) | "Your Bambuddy server can't reach MakerWorld." Not "bad link". |
| Phone offline, search (phase 2, direct from phone) | `URLError` | Search unavailable; **paste-a-link still works** if Bambuddy is reachable, because resolve runs server-side. Do not disable the whole panel. |
| API key lacks `can_access_cloud` | `/cloud/status` → `403`; `/makerworld/status` → `can_download:false` | "Enable **Allow cloud access** on this key in Bambuddy → Settings → API Keys." (**today's state**) |
| No cloud token / expired (~90 d) | `can_download:false` with `cloudReadable` | "Sign in to Bambu Cloud in Bambuddy → Profiles." |
| Model is paid / points / region-locked / early-access | `import` → `403`, MakerWorld's own text forwarded | Show that text verbatim + **Open on MakerWorld**. Never "import failed". |
| CAPTCHA on the server's IP | `resolve`/`import` → `502` containing *"confirm you are not a robot"* | "MakerWorld is challenging your server's IP. This usually clears in a few hours." + **Open on MakerWorld**. Unsolvable server-side, by design. |
| Rate limited | `429` → `502` | "MakerWorld is rate-limiting. Try again shortly." Back off; do not auto-retry in a loop. |
| Signed URL expired mid-download | `502` from `download_3mf` | Plain retry — the URL is ~5 min and re-minted per attempt. |
| 3MF > 200 MB | `502` "exceeds 200 MB cap" | Say the cap. Offer **Open on MakerWorld**. |
| Duplicate import | `200` with `was_existing: true` | Existing toast, plus: jump to the existing library file rather than re-importing. |
| Slice fails | `slice-jobs` `failed` | Existing wizard alert, lands back on Material. |
| LAN Developer Mode off | step 7 | Existing `LockedActions` padlock. A MakerWorld print is still a print. |
| Printer offline / powered down | queue accepts, print doesn't start | Unchanged queue semantics. |

**Offline-first stance.** Everything in this flow is online-only by nature. The one thing worth
caching is `GET /makerworld/recent-imports` (currently unused by the app) — it gives the panel a
useful cold-start state instead of an empty text field, and the files themselves are already local
to Bambuddy.

---

## 9. Risk register — what is fragile, and what to say out loud

| Risk | Severity | Notes |
|---|---|---|
| **Every upstream endpoint is undocumented and unofficial** | High | `design-service`, `search-service` and `iot-service` are reverse-engineered from Handy traffic. Bambu can change or gate them without notice. Design so that *only* the MakerWorld feature breaks: no shared client, no shared error path, no cached shape that other screens read. |
| **Bambu's posture toward third-party cloud access is actively hostile** | High | Bambu Lab sent a cease-and-desist to an OrcaSlicer fork developer in April 2026 and published a May 2026 post recasting the dispute as being about *cloud access and impersonation* rather than open source ([3druck](https://3druck.com/en/programs/dispute-over-orcaslicer-fork-bambu-lab-is-about-cloud-access-not-open-source-customization-16157098/), [Consumer Rights Wiki](https://consumerrights.wiki/w/Bambu_Lab_cease_and_desist_against_OrcaSlicer_fork_developer)). Practical consequence: **never impersonate Bambu Studio or Handy.** Send an honest, identifying User-Agent (Bambuddy already does, deliberately, for this reason). Never spoof client headers or tokens to unblock something. |
| **Account risk from download volume** | Medium | Downloads are attributed to the owner's Bambu account. Bulk/automated importing is the behaviour most likely to draw a limit. Keep imports strictly user-initiated, one at a time; never prefetch a 3MF for a profile the user only *looked* at. |
| **CAPTCHA / 418 on the server's IP** | Medium | Bambuddy retries once on 418 then stops, correctly. Doing search from the **phone** rather than the server (§10) has a real benefit here: a flagged phone IP costs you browsing, not importing. |
| **Search from the phone leaks the phone's IP to Bambu** | Low | Same exposure as opening makerworld.com in Safari. Worth one line in the design; not worth a proxy. Note that Bambuddy's `/makerworld/thumbnail` proxy exists precisely to avoid this for images — reuse it for search-result covers and the leak is metadata-only. |
| **Payload shape drift** | Medium | The `hits` vs `design.instances` split (§4.1) is exactly this failure already having happened once. Decode defensively, treat every numeric field as optional, and render "—" only where the data is genuinely absent rather than where the decode missed. |
| **`nozzle_mapping` is not expressible via the queue API** | Medium | §5.3. Do not ship a nozzle picker until the field exists. Say "the printer chooses the nozzle" in the UI. |
| **200 MB / 5-minute signed URL** | Low | Both handled server-side. Surface, don't re-implement. |
| **Bambuddy is a third-party image** | Medium | Sprout cannot add endpoints to it. Any capability that needs a new Bambuddy endpoint is an upstream PR or a sidecar, and must be scoped as such — not assumed. |

---

## 10. Phased plan

### Phase 1 — Stop lying, and finish the sentence *(no new backend, no new network dependency)*

The smallest increment that is genuinely useful: the feature that exists becomes truthful, and it
ends at a printed object instead of at a file.

1. **Fix the profile decode.** Build the picker's rows from `design.instances[]` joined to the
   `/instances` hits on `profileId`. Concretely: `MWInstance` gains `materialCnt`, `materialColorCnt`,
   `appCanPrint`, `isDefault`, `compatibility`, `otherCompatibility`, `projectSettings`, and reads
   `prediction` / `weight` / `needAms` / `instanceFilaments` from the record that actually has them.
   *Test with model 40146 (88 hits / 37 records, all-blank today) and 1400373 (7/7, 3 filaments).*
2. **Split `can_download` into the three predicates of §3.1** and write the three different remedies.
   The current copy sends the owner to the wrong settings page for the state the server is in today.
3. **Show the licence** — chip on the detail screen, `licenseDescriptionInfo` on tap, `originals[]`
   attribution, licence line under the import button.
4. **Decode `folder_id` and `profile_id`** on the import response; surface "Already in your library"
   as a jump rather than a badge.
5. **Hand off into the wizard.** On import success, open `.wizard(file)` with a seed carrying the
   design title, creator, licence, the picked profile's `instanceFilaments`, `projectSettings`,
   `compatibility` and plate count. Seed step 3's quality from `layerHeight`; show provenance on
   step 1.
6. **Multi-filament, end to end** — the two genuinely new pieces:
   - step 3: N filament pickers, `filament_presets[]` on the slice request;
   - step 6: N mapping rows from `filament-requirements`, full-length `ams_mapping`.
   Both are prerequisites for *any* multi-material print on this machine and pay for themselves
   outside MakerWorld.
7. **Failure copy** from the §8 table, including **Open on MakerWorld** on every terminal failure.
8. **Recent imports** as the panel's cold-start state (`GET /makerworld/recent-imports`).

Deliberately **not** in phase 1: search, "print as-is" detection, nozzle assignment, plate-0
slice-all.

### Phase 2 — Discovery

Add search and browse **calling `api.bambulab.com/v1/search-service/*` directly from the app**, not
through Bambuddy. Rationale: it is anonymous (no credential ever leaves the server), it needs no
upstream change to a third-party image, and it puts the CAPTCHA risk on the phone's IP instead of on
the server IP that the import path depends on. Route cover images through Bambuddy's existing
unauthenticated `/makerworld/thumbnail` proxy so the phone's IP stays out of MakerWorld's CDN logs.

- Search field → `search-service/search/design?keyword=&offset=&limit=`; grid of hits with cover,
  title, creator, licence chip, download count, and a "not printable" marker when `is_printable` is
  false or `nsfw` is true.
- Browse → `search-service/select/design/nav?navKey=Trending|category_*`. Category list from
  `search-service/homepage/nav` (unprobed — spike S-3).
- Tapping a hit synthesises `https://makerworld.com/models/{id}` and enters the phase-1 detail
  screen unchanged. **Search adds an entry point, not a second flow.**
- Search must degrade to the paste field, not replace it.

### Phase 3 — Depth

- Plate strip and multi-plate handling (`plate: 0` + the cross-class merge path), once single-plate
  is proven.
- `nozzle_mapping` on the queue item — blocked on upstream (S-5). Until then, state in the UI that
  the printer picks the nozzle.
- A cheap exact "already printable" signal (S-4), and only then a fast path that skips slicing.
- `recent-imports` as a persistent sidebar; `design/{id}/remixed` and `search-service/design/{id}/relate`
  as "more like this".

---

## 11. Spikes — what is genuinely uncertain

| # | Question | How to settle it | Blocks |
|---|---|---|---|
| **S-1** | Is the downloaded 3MF really unsliced? | Enable `can_access_cloud` on the app's key (or use key 3/4), then `POST /makerworld/import` for one small CC-BY model and check `GET /library/files/{id}/plates` → `print_time_seconds`, `embedded_printer`, and `GET …/gcode` status. **One import, one model, chosen for a permissive licence.** | The "no fast path" decision in §5. Everything else assumes unsliced; a surprise here only *adds* an option. |
| **S-2** | Does `search-service/search/design` support sort and filters? | Capture the query string the MakerWorld web app sends for "sort by hot" and "multi-colour only" (browser devtools, one page load), then replay it server-side. `sort=new/hot` and `filterMultiColor=true` were ignored. | Phase 2 quality. Relevance-only search still ships. |
| **S-3** | What does `search-service/homepage/nav` return, and are the `navKey` values stable? | One anonymous GET. `Trending`, `category_400`, `category_800` are documented; `category_400` returned 795 hits. | Phase 2 browse tab. |
| **S-4** | Is there a cheap exact "has toolpaths" signal? | Read `Metadata/slice_info.config` presence vs `Metadata/plate_N.gcode` presence on a real MakerWorld import (S-1's file). If they diverge, the `print_time_seconds` proxy is confirmed unsafe and the upstream ask is a `has_gcode` flag on the plates response. | Phase 3 fast path only. |
| **S-5** | Can `nozzle_mapping` reach a queued print? | Upstream issue/PR against Bambuddy: add `nozzle_mapping` to `PrintQueueItemCreate` (it already exists on `PrintQueueItemResponse`/`Update` and on `printer_manager.start_print`). | Phase 3 nozzle choice. |
| **S-6** | Which API key does the installed app actually hold? | The Keychain value is not readable from here; `api_keys` shows `ios-app` (no cloud) and `iOS-app-new` (cloud). If the app already uses key 3, `can_download` is already true and §3's remedy copy is the only fix needed. | Phase 1 item 2's default copy. |

---

## 12. Sources

- Bambuddy source, read from the running container: `app/services/makerworld.py`,
  `app/api/routes/makerworld.py`, `app/api/routes/cloud.py`, `app/api/routes/library.py`,
  `app/services/filament_requirements.py`, `app/services/bambu_mqtt.py`, `app/core/permissions.py`.
- Live probes against Bambuddy 0.2.4.9 and `api.bambulab.com`, 2026-08-10 (quoted inline).
- [Bambuddy wiki — MakerWorld Integration](https://wiki.bambuddy.cool/features/makerworld/)
- [Doridian/OpenBambuAPI — cloud-makerworld.md](https://github.com/Doridian/OpenBambuAPI/blob/main/cloud-makerworld.md)
- [MakerWorld Standard Digital File License explained](https://modelrover.com/g/makerworld-standard-digital-file-license)
- [3Druck — Bambu Lab dispute is about cloud access, not open source](https://3druck.com/en/programs/dispute-over-orcaslicer-fork-bambu-lab-is-about-cloud-access-not-open-source-customization-16157098/)
- [Consumer Rights Wiki — Bambu Lab cease and desist against OrcaSlicer fork developer](https://consumerrights.wiki/w/Bambu_Lab_cease_and_desist_against_OrcaSlicer_fork_developer)
- In-repo: `docs/native-rewrite/06-overlays.md` (§230–300), `docs/phase0-results.md`, `CLAUDE.md`
  ("The recurring bug in this codebase: offering what the backend will refuse").

---

# Review

> **Second author.** Everything above is the original author's text and is left unedited. This
> section is an adversarial review: it re-ran the document's probes and challenges what did not
> survive. Where I agree, I say so briefly; the bulk below is disagreement, because that is the
> useful part. Same placeholders (`<BAMBUDDY>`, `<KEY>`); nothing secret is printed.
>
> Method: re-probed Bambuddy 0.2.4.9 and `api.bambulab.com` on 2026-08-10, read the OpenAPI schema
> and the container source, and grepped the repo. Commands are quoted so every claim here is
> re-runnable too.

## R-0. What survived, so the disagreement below is calibrated

I tried to break these and could not. They are solid:

- **Server surface.** 548 OpenAPI paths, version `0.2.4.9`, exactly five `/makerworld/*` endpoints.
- **The "big surprise" reproduces exactly.** `design-service/design/search?keyword=benchy` → `200`
  `{"total":0,"hits":null}`; `search-service/search/design?keyword=benchy` → `200` `total: 7070`;
  `select/design/nav?navKey=Trending` → `total: 800` (doc said 799 — it is a live number). The
  document's central factual claim is correct, and the `design-service` vs `search-service`
  diagnosis is a genuinely good catch.
- **The profile-decode diagnosis is correct and worse than stated.** `prediction`, `weight`,
  `needAms`, `instanceFilaments`, `extention` are absent from **100%** of top-level hits (88/88 on
  40146, 7/7 on 1400373). `detail` is a zeroed placeholder on **88/88**. The data really is only in
  `design.instances[]`.
- **`design` is an opaque passthrough.** `MakerWorldResolvedModel.design` is
  `{"additionalProperties": true, "type": "object"}` — so the Phase 1 decode fix genuinely needs no
  backend change. This was the claim most likely to sink Phase 1, and it holds.
- **The slice call is genuinely unblocked.** `filament_presets: list[PresetRef]` exists on the live
  `SliceRequest`, and `schemas/slicer.py:124-139` backfills it from the singular form — sending the
  plural alone is the *preferred* new-client path. `plate: 0` is a real "all plates" sentinel. All
  four quoted preset ids exist verbatim; H2C preset counts are exactly 5 / 16 / 189.
- **§5's evidence.** File 40 → `/gcode` `404`, `plates[0].print_time_seconds: null`; file 41 →
  `/gcode` `200`, `69 890 554` bytes, `36285`. `classify_file_type` only returns `gcode.3mf` for a
  `.gcode.3mf` suffix. The "always re-slice" conclusion is right.
- **§5.3's printer facts.** Nozzles `HS01 0.6` + `HH05 0.4`, AMS `0/1` (`n3f`, 4 trays) + `128`
  (`n3s`, `is_ams_ht`), `vt_tray` `254/255`, `fila_switch.installed: true`. Verbatim correct.
- **The repo citations.** `filament_preset` singular at `WizardView.swift:1219`, one-element
  `ams_mapping` at `:1291`, `MakerWorldImportResponse` missing `folder_id`/`profile_id`
  (`Models.swift`), `api_keys` flags, `users.cloud_token` set. All check out.
- **`instance_id` really is inert** — the OpenAPI description says so verbatim.

Now the parts that do not hold.

---

## R-1. **BLOCKER** — the prescribed join drops MakerWorld's own default profile, and leaves 58% of rows exactly as blank as they are today

§4.2 says: *"`design.instances[]` is the record; the `/instances` hits add nothing except a longer
tail of profiles for which MakerWorld itself publishes no metadata."* Phase 1 item 1 then says to
build rows from `design.instances[]`, and names model 40146 as the test case.

Measured on that exact model:

```
hits: 88   design.instances: 37   profileIds hits-only: 51   design-only: 0
hits WITH metadata after the join: 37 of 88
design.instances with isDefault == True: []          ← on BOTH probed models
design.defaultInstanceId: 42179
  → present in hits[].id?            True
  → present in design.instances[].id? FALSE
  → that hit's profileId (22111064) present in design.instances[].profileId? FALSE
```

Three separate failures fall out of this, and they compound:

1. **`hits ⊇ design.instances`, always.** There are zero design-only profileIds. So the complete
   list is the hits; `design.instances[]` is the *metadata sidecar*, not "the record". The document
   has the primary and secondary sources backwards. Build rows from `design.instances[]` and 51 of
   88 real, named, importable profiles (`"0.25mm layer, 2 walls, 10% infill"`, with valid
   `profileId`s the import endpoint accepts) silently vanish from the picker — profiles the owner
   can see on the website. That is the codebase's recurring bug running in reverse: *hiding* a
   capability that exists, on a proxy for "is this profile real".
2. **The pre-selection rule cannot fire on the document's own test model.** `defaultInstanceId` is
   an **instance `id`**, not a `profileId` — the document's join key. On 40146 that instance is not
   in `design.instances[]` at all. So "Pre-select `design.defaultInstanceId`" silently fails; the
   `isDefault` fallback is empty on **both** probed models (0/37 and 0/7), so the chain degrades all
   the way to "first with `appCanPrint`". §4.2 lists `isDefault` in the signals table as if it were
   measured. It was not; it is dead on every model probed.
3. **The stated success criterion is unreachable.** The TL;DR promises the fix stops rows showing
   `—` with no weight and no swatches. After the fix, on the named test model, **51 of 88 rows still
   render exactly that**, including the pre-selected one — MakerWorld publishes no metadata for its
   own default profile. There is no worse outcome than shipping a fix whose headline test case is
   the row that still looks broken.

**What to do instead.** Left-join *from hits*: hits are the row set, `design.instances[]` enriches
by `profileId`, and a row with no match gets an explicit, honest empty state — *"MakerWorld
publishes no details for this profile"* — not `—`. That state is missing from the design entirely
and must be specified, because it is the majority case on popular models. Pre-select by matching
`defaultInstanceId` against **`hits[].id`** (where it actually lives), then fall back.

Re-run:
```bash
# resolve, then compare the two lists
curl -s -X POST -H "X-API-Key: <KEY>" -H 'Content-Type: application/json' \
  -d '{"url":"https://makerworld.com/models/40146"}' <BAMBUDDY>/api/v1/makerworld/resolve
```

## R-2. **MAJOR** — Phase 1 is not shippable alone, and is not the "smallest increment" it claims

Two independent problems.

**(a) Half of Phase 1 cannot be executed or tested today.** `can_download` is `false` on this
server, so **no import can be performed at all**. Items 4 (decode the import response), 5 (hand off
into the wizard) and 6 (multi-filament end to end) all sit downstream of a successful import that
nobody can currently produce. Unblocking it requires ticking *Allow cloud access* on an API key in
Bambuddy's admin UI — and per `CLAUDE.md`, **settings writes are admin-only; the scoped app key gets
403**. So Phase 1 has an out-of-band human prerequisite that the app cannot perform and the document
never lists as a precondition. It is filed as spike S-1's *setup step*, which badly understates it:
it gates 5 of the 8 Phase 1 items, not one spike.

**(b) Item 6 is not "phase 1", by the document's own argument.** Item 6 is N filament pickers, a
plural slice request, N mapping rows and full-length `ams_mapping` — comfortably the largest single
piece of work in the whole plan. The document admits it "pay[s] for [itself] outside MakerWorld",
which is an argument that it is *a different project*, not an argument for bundling it into a phase
whose stated purpose is "stop lying". Items 1–5, 7, 8 are genuinely shippable and genuinely useful
without it (single-material MakerWorld models work end to end; multi-material models are honestly
gated). Splitting is free and the document gives no reason not to:

- **Phase 1a — truthfulness** (items 1, 2, 3, 4, 7, 8). No import required to build or review most
  of it; ships value immediately.
- **Phase 1b — the hand-off** (item 5). Needs one successful import.
- **Phase 1c — multi-material** (item 6). Needs 1b, is not MakerWorld-specific, and should be
  scheduled against the multi-material story, not this one.

Until 1c lands, a multi-filament model must be **refused with a stated reason** at the picker, not
allowed into a wizard that will map filament 1 and silently drop 2 and 3. The document does not say
this anywhere, and the wizard's current one-element `ams_mapping` (`WizardView.swift:1291`) makes it
the default behaviour. That is the recurring bug, shipped.

## R-3. **MAJOR** — "`nozzle_mapping` cannot reach a queued print" is asserted, not established; an existing-endpoint path was never tried

§5.3 and risk-register row 7 declare this blocked on an upstream PR (S-5, Phase 3) and instruct the
UI to say the printer picks the nozzle. The asymmetry is real:

```
PrintQueueItemCreate   | nozzle_mapping: False
PrintQueueItemResponse | nozzle_mapping: True
PrintQueueItemUpdate   | nozzle_mapping: True   ← anyOf[array<int>, null]
```

But the document stopped at `POST /queue/`. The live server also has:

```
/api/v1/queue/{item_id}          ['get', 'patch', 'delete']   ← PATCH takes PrintQueueItemUpdate
/api/v1/queue/{item_id}/start    ['post']
PrintQueueItemCreate.manual_start                              ← exists
```

So `POST /queue/ {manual_start: true, …}` → `PATCH /queue/{id} {nozzle_mapping: […]}` →
`POST /queue/{id}/start` is a plausible route to the exact capability, **entirely within existing
endpoints and requiring no upstream change to a third-party image**. It may not work — `PATCH` may
not propagate the field into `printer_manager.start_print`, and `manual_start` semantics need
checking — but "may not work" is a spike, not a blocker. The document converted an untested
assumption into a hard constraint, a UI copy decision ("the printer chooses the nozzle") and a
deferral to Phase 3. That is precisely the failure mode it warns about elsewhere. **S-5 should be
rewritten to test the PATCH path first and only escalate upstream if it fails.**

## R-4. **MAJOR** — the "~90 day" token lifetime is wrong, and "cannot be refreshed" is contradicted by the code

§3.1 states tokens "last ~90 days and cannot be refreshed", §3.1's remedy copy says *"(Add: tokens
last ~90 days.)"*, and §8 repeats "~90 d". This is asserted with no source — exactly the kind of
protocol detail the brief said not to state from memory. From `app/services/bambu_cloud.py`:

```python
# Token typically valid for ~3 months, but we'll refresh more often
self.token_expiry = datetime.now(timezone.utc) + timedelta(days=30)   # ×3 sites (login, _set_tokens, set_token)
...
self.refresh_token = data.get("refreshToken")                          # a refresh token IS stored
return not (self.token_expiry and datetime.now(timezone.utc) > self.token_expiry)
```

Two corrections. (1) **Bambuddy's own validity window is 30 days, not 90** — and it is Bambuddy's
window, not Bambu's, that flips `can_download` to `false` and that the user experiences. UI copy
saying "~90 days" would be wrong by 3× and would make a re-login prompt at day 31 look like a bug.
The "~3 months" figure exists only as an unverified comment about the *upstream* token. (2) **A
`refreshToken` is stored**, so the flat claim "cannot be refreshed" is unsupported; whether Bambuddy
*uses* it is a separate, unasked question. Say "Bambuddy treats the token as valid for 30 days" —
that is the part that is actually established.

## R-5. **MAJOR** — Phase 2's topology has no fallback that does not violate another rule in this document

Phase 2 puts `search-service` calls on the phone. I verified the feasibility claim and it is
*stronger* than the document argued — the endpoint is not User-Agent gated:

```
Bambuddy UA → 200 total=7070    Sprout/1.0 (iOS) UA → 200 total=7070
curl default → 200 total=7070   empty UA          → 200 total=7070
```

That is good news the document did not claim. The problem is what happens when it stops being true.
§9 row 1 correctly says Bambu can gate these endpoints without notice. If `search-service` starts
requiring a bearer, the phone has no token **by design** (§3.2: "nothing in this design should ever
put a Bambu Cloud bearer in the iOS Keychain" — a rule I agree with). The only remaining fix is to
proxy search through Bambuddy — which §9's last row says is an upstream PR to a third-party image.
So the failure mode is: *search dies and cannot be repaired in the app.* That is an acceptable
outcome, but it is a design consequence that should be stated in Phase 2 rather than discovered.
Add one line: **"if search is ever gated, it is removed, not worked around"** — and keep the paste
field as a first-class entry point permanently, not as a degradation path.

Also: every probe in this document ran from the home server. There is no evidence about mobile
carrier IPs. The claim that moving search to the phone "puts the CAPTCHA risk on the phone's IP
instead of the server IP" is sound in direction but untested in magnitude — a carrier CGNAT egress
shared by thousands of users is a *more* likely bot-flag candidate than a residential IP, not less.
Low severity, but the risk register rates this "Low" on the basis of an argument, not a measurement.

## R-6. **MAJOR** — the "Made for H2C" badge has almost no discriminating power, and edges into the trap §4.2 itself names

§4.2 proposes badges from `compatibility` / `otherCompatibility`. Measured:

```
model 40146 : design.instances marked otherCompatibility H2C = 36 of 37
model 1400373: design.instances marked otherCompatibility H2C =  6 of 7
```

A badge that is true 97% of the time is decoration, not information — it will read as
"this one is fine for your printer" on essentially every row, which is exactly the *slicing-settings
vs printability* conflation the document's own **Trap** box warns about two paragraphs earlier. The
document names the trap and then designs a prominent, near-constant affirmative badge into the
primary row. Either drop the badge, or invert it: surface only the **negative** case (the ~3% with
no H2C marking), which is the only state that carries information.

Related, and self-contradictory: §4.2 and §6② propose a `compatibility.nozzleDiameter` caution
("needs 0.4") — while §6 step 2 correctly reasons that *"we are about to re-slice, so it is not a
mismatch"*. Both cannot be right. Since every import is re-sliced for the H2C with our own printer
preset, the source profile's nozzle diameter has no bearing on whether the model prints; warning
about it invents a problem the pipeline already solves. §6 step 2 is the correct reasoning; §4.2's
caution line should go.

## R-7. **MAJOR** — the TL;DR states as fact a bug that §11 admits is unverified

TL;DR: *"`can_download` conflates two unrelated conditions and **currently tells the owner to fix
the wrong thing**."* §3.1: *"Today, on this server, it is **case 3 and only case 3**."* Both are
stated flatly. But S-6 concedes the premise is unknown: which key does the installed app hold?

Confirmed live (names and flags only):

```
api_keys: (1,'ios-app',0)  (2,'Claude Mac',1)  (3,'iOS-app-new',1)  (4,'claude-native-test',1)
users:    max  has_cloud_token: True  region: global
```

Every probe in the document used the key in `~/.config/bambu-phase0/bb_apikey` — key **1**, the
provisioning key. Key **3** is literally named `iOS-app-new` and **has** cloud access. If the
shipped app holds key 3, then `can_download` is already `true` on the device, the "wrong remedy" bug
**does not reproduce for the user at all**, and Phase 1 item 2 is a copy change rather than a bug
fix. The document reasoned from the wrong client's credentials to a claim about what the owner sees.

This is cheap to settle and should not be a spike: have the app call `GET /cloud/status` at startup
and branch on `403` vs `200`. That is the §3.1 design rule (`cloudReadable`) already — so **the
correct predicate makes S-6 moot**. Downgrade the TL;DR to "may tell the owner to fix the wrong
thing, depending on which key the app holds", and delete S-6 in favour of implementing `cloudReadable`.

## R-8. **MINOR** — §5's third line of evidence is factually wrong (the conclusion still stands)

*"Both probed models' default profiles are `compatibility: X1 Carbon 0.4` / `A1 0.4`."* Measured
compatibility spread:

```
40146  : {(A1,0.4):9, (A1 mini,0.4):9, (P1P,0.4):1, (P1S,0.4):9, (P2S,0.4):5,
          (A1,0.2):1, (A1,0.6):1, (P2S,0.2):1, (X2D,0.8):1}   ← no X1 Carbon anywhere
1400373: {(X1 Carbon,0.4):3, (P1S,0.4):1, (A1,0.4):2, (Elegoo Neptune 3 Pro,0.4):1}
```

Model 40146 has no X1 Carbon profile at all, and its *default* profile has no `compatibility` field
whatsoever (it is one of the 51 metadata-less hits from R-1). The "always re-slice" conclusion is
unaffected — evidence 1 (`classify_file_type`) and 2 (`/gcode` → 404) carry it on their own — but
evidence 3 as written is not reproducible and should be corrected or dropped.

## R-9. **MINOR** — the licence section rests a legal claim on a secondary source and a sample of three

§7: *"Printing for yourself is inside every one of these licences"* and *"no licence in play
restricts the *use*"*. The only citation for the Standard Digital File License is a third-party
explainer (`modelrover.com`), not MakerWorld's own licence text. The sample is two models plus one
search hit. "Every one of these licences" is a generalisation over a set the document never
enumerated from the source.

The *practical* conclusion (single user, own printer, no share affordance → fine) is almost
certainly right and I am not disputing it. But state it as what it is — "on the licences observed,
personal printing is permitted; Sprout adds no redistribution affordance, which is the obligation
that actually bites" — and cite MakerWorld's own licence page rather than a gloss. The attribution
requirement in item 2 is the genuinely load-bearing part and it is well specified.

## R-10. **MINOR** — two small things the design will trip over on contact

- **`.wizard` takes a `LibraryFile`, not an id.** `AppModel.swift:11` is `case wizard(LibraryFile)`,
  but `/makerworld/import` returns `{library_file_id, filename, …}`. §6④'s "sets
  `model.overlay = .wizard(file)` directly" needs an intervening `GET /library/files/{id}` (listed
  in the API inventory, so it is covered) *and* an enum change to carry `MakerWorldSeed`. Name it.
- **`docs/phase0-results.md` is stale where this document cites it.** It says *"Pass the full preset
  OBJECT"*; the live schema wants `PresetRef {source, id}`, which is what this document correctly
  uses. Worth a footnote so the next reader does not "fix" the design back to the old shape.
- **The thumbnail proxy is unauthenticated on a publicly-tunnelled host.** The document notes this
  neutrally and Phase 2 proposes to route *more* traffic through it. The CDN host allowlist keeps it
  from being a general SSRF, so this is not a blocker — but "unauthenticated" belongs in the risk
  register, not only in a parenthetical, since remote access is via a public tunnel.

---

## Revised spike list

| # | Change |
|---|---|
| **S-1** | Keep, but **re-scope**: it is not a spike, it is a Phase 1 *precondition*. Enabling cloud access on the app's key gates Phase 1 items 4, 5 and 6. Schedule it first. |
| **S-2** | Keep as-is. Sound. |
| **S-3** | Keep as-is. Sound. |
| **S-4** | Keep. Lower priority than the document implies — nothing before Phase 3 depends on it. |
| **S-5** | **Rewrite (R-3).** Before any upstream ask: test `POST /queue/ {manual_start:true}` → `PATCH /queue/{id} {nozzle_mapping}` → `POST /queue/{id}/start` and check whether the mapping reaches `start_print`. Escalate upstream only if it does not. |
| **S-6** | **Delete (R-7).** Implementing the `cloudReadable` predicate (`GET /cloud/status` ≠ 403) answers it at runtime on every launch. |
| **S-7** *(new)* | Of the 51 metadata-less profiles on model 40146, does `POST /makerworld/import` accept their `profileId` and return a usable 3MF? Decides whether R-1's empty-state rows are importable-but-undocumented (list them) or genuinely dead (filter them, and say why). One import, permissive licence. |
| **S-8** *(new)* | Does `search-service/search/design` answer from a mobile carrier IP as it does from the home IP (R-5)? One request from the phone on cellular before committing to Phase 2's topology. |

## Bottom line

The document's research is real and its two headline findings — the `search-service` discovery and
the profile-decode diagnosis — both survive re-probing. The failures are not in the evidence, they
are in the step from evidence to design: the join direction is inverted (R-1), the phase boundary is
drawn around work that cannot be tested yet (R-2), one hard blocker was declared without trying the
adjacent endpoint that has the field (R-3), and the two most confident sentences in the TL;DR rest
on a credential the author never verified the app uses (R-7). Fix R-1, R-2 and R-7 before anyone
writes code; R-3 changes what Phase 3 even contains.

---

# Implementation notes — what the probes settled (2026-08-10)

> **Third pass.** Phase 1a and 1b are built. Everything below was measured against the live server
> while building, and it changes several conclusions above. Where this section and anything earlier
> disagree, this section wins — it is the only part that was tested end to end rather than reasoned
> from a payload.

## Spikes now closed

| # | Answer |
|---|---|
| **S-1** | **Closed — imports are never sliced.** Imported models 40146 and 1400373. Both land as `file_type: "3mf"`, `GET /library/files/{id}/gcode` → **404**, `sliced_for_model: "A1"` / `"A1 Mini"`. §5's "always re-slice" is confirmed, and `LibraryFileCaps.hasGcode` answers correctly for them without change. |
| **S-4** | **Closed, and the news is bad for the proxy.** File 44 reports `print_time_seconds: 1895` while `/gcode` answers 404. So `print_time_seconds != null` is **confirmed unsafe** as a "has toolpaths" signal, exactly as §5.1 feared. No fast path may be built on it. |
| **S-6** | **Closed — deleted, as R-7 asked.** The app holds key 4 (`claude-native-test`, `can_access_cloud = 1`). Live: `GET /cloud/status` → `200 {"is_authenticated":true}`, `GET /makerworld/status` → `can_download: true`. **Imports work today**, so the TL;DR's "currently tells the owner to fix the wrong thing" never reproduced for the owner. The `cloudReadable` predicate is implemented, so the question is now answered at runtime on every launch. |
| **S-7** | **Closed — and it splits the difference between §4.2 and R-1.** See below. |

## S-7: importability is not predictable from the payload

This was the load-bearing disagreement, so it was tested rather than argued. On model 40146:

```
profile 35438952 (has a design.instances record) → 200, library_file_id 44
profile 40144192 (no record)                     → 200, library_file_id 45
profile 21931235 (no record)                     → 400  "Bambu Lab API unexpected status 400"
profile 21931374 (no record)                     → 400
profile 21936041 (no record)                     → 400
profile 22111064 (no record, AND the model's own defaultInstanceId) → 400
profile 22435442 (no record)                     → 400
```

**Neither earlier position survives intact.**

- §4.2 and Phase 1 item 1 said build rows from `design.instances[]`. That would hide profile
  40144192, which downloads fine. **R-1 is right that the hits are the row set.**
- R-1 said the 51 metadata-less hits are "real, named, **importable** profiles… with valid
  profileIds the import endpoint accepts". That was asserted, not tested — it *was* S-7 — and 5 of 6
  answered `400`. **The doc's instinct that those rows are second-class is right.**

So the implemented behaviour is: **list every hit, pre-select only a described one.** The rows that
publish no metadata stay visible and selectable, because one of them does import and hiding it would
hide real capability; but `MakerWorld.preselect` skips `defaultInstanceId` when that profile has no
record, because on this model MakerWorld's own default pick answers `400` — pre-selecting it would
have made the default action a guaranteed failure. The refusal copy now names the next thing to try rather than
reporting a dead end.

**Correction, measured after the first pass:** the refusal does **not** reach the app as a `400`.
Bambuddy wraps MakerWorld's status in a **`502`** of its own —
`{"detail": "Bambu Lab API unexpected status 400 for profile 21931235"}` — and through the public
tunnel the proxy replaces even that body, so the app sees a `502` with no detail at all. The first
implementation branched on `400` and therefore shipped its actionable remedy as dead code, showing a
generic "your server couldn't download this model" instead. Verified in the simulator, fixed, and
pinned by a test. The wrapper's own text is also deliberately discarded: naming an upstream status
code explains nothing to the person holding the phone.

Note this is *not* the recurring bug. The affordance is not gated on a proxy — it is left open
precisely because the exact capability is unknowable before the attempt (`modelIsGettable`, §3.1),
and the attempt now explains itself.

## Three things the design did not anticipate

1. **`filament-requirements` must be asked per plate.** Unfiltered, the 3-material seed tray reports
   **6** slots, every one `used_in_plate: true`. With `?plate_id=N` it reports **1**. Asking without
   the filter would block a perfectly printable plate.

2. **A multi-material *model* is usually not a multi-material *print*.** All four plates of that
   profile are single-material — the three filaments are spread across plates, not mixed within one:

   ```
   plate 1 → slot 1 (PLA)   plate 2 → slot 2 (PLA)
   plate 3 → slot 1 (PLA)   plate 4 → slot 3 (PETG)
   ```

   So `materialCnt: 3` on the profile row describes the profile, and §6②'s row text should not be
   read as "this print needs 3 spools". The per-plate answer is the one that gates anything.

3. **Slicing renumbers, and stale metadata is returned for the plates it did not touch.** Slicing
   plate 2 of file 46 produced file 47, whose `?plate_id=2` correctly reports one slot with
   `used_grams: 33.0`, `tray_info_idx: "GFA00"` and `nozzle_id: 1` — while `?plate_id=1` on the same
   output returns the source's stale 6-slot list. The wizard is safe because it always asks about the
   pair *(file it will enqueue, plate it will enqueue)*, which by construction is the plate that was
   sliced. Anything that asks a different pair will get a wrong answer.

## What is built, and what is deliberately not

**Phase 1a — shipped.** Rows joined from hits with an explicit "MakerWorld publishes no details for
this profile" empty state; the three-way access gate with three remedies; licence chip with
MakerWorld's own prose disclosed verbatim, remix attribution and the obligation line under the import
button; paid/points/exclusive cautions *before* the download; per-failure copy with **Open on
MakerWorld**; `folder_id`/`profile_id` decoded; recent imports as the cold-start state.
`MWLicence` parses CC clauses as tokens after a test caught the substring match reading the
**"STANDARD"** in "Standard Digital File License" as a `-ND` clause.

**Phase 1b — shipped.** A successful import fetches the library file and opens
`overlay = .wizard(file)` directly, so the flow ends at a print rather than at the Files list. No
second print path: the LAN gate, wrong-printer guard, plate review and enqueue all stay where they
are.

**Phase 1c — not built, and now blocked honestly.** The enqueue still sends a one-element
`ams_mapping`. The wizard asks `filament-requirements` for the exact (file, plate) it will enqueue,
and when that needs more than one slot the mapping step says so and **Start refuses with the
reason** — rather than mapping filament 1 and letting the firmware guess the rest. This is a
pre-existing gap for any multi-material file, not a MakerWorld one; it is now visible instead of
silent. The remaining work is §10 item 6 and is unchanged.

**Still open:** R-3's `POST /queue/ {manual_start} → PATCH {nozzle_mapping} → POST /start` spike, and
all of Phase 2 (search).

## Corrections to earlier sections

- **§3.1's "~90 days"** is wrong, as R-4 established. The shipped copy says *"Bambuddy treats a
  sign-in as valid for 30 days"*, which is Bambuddy's own window and the one the user experiences.
- **§4.2's nozzle-diameter caution** is not implemented, per R-6: every import is re-sliced for this
  printer, so the source profile's nozzle diameter has no bearing on whether it prints.
- **§4.2's "Made for H2C" badge** is not implemented either, for the same reason R-6 gives — it was
  true for 36 of 37 profiles. `MWProfileDetail.marked(for:)` exists and is tested, but nothing renders
  it as a positive badge.
- **§5's third line of evidence** is wrong (R-8) and did not need to be right: evidence 1 and 2 are
  now confirmed live.

## Test artefacts left on the server

Library files **44, 45** (Benchy profiles), **46** (seed tray) and **47** (46's plate 2 sliced for the
H2C), plus slice job 1. All in the auto-created `MakerWorld` folder. Safe to delete; kept because they
are the only multi-plate and multi-material files in the library to test the wizard against.
