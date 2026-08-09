<!-- Generated as the port specification for the native Swift rewrite. -->
# Camera, upload, MakerWorld, the 7-step print wizard, texturize, STL

## overlays

`src/components/Overlays.tsx` (1545 lines) is the whole modal layer of the app: fullscreen camera, the add-file sheet, MakerWorld import, the texturize sheet, the G-code layer viewer, the STL viewer, the plate-review block, and the 7-step print wizard. Everything here is rendered as `position:'absolute'` siblings of the tab content inside `src/app/index.tsx` — there is **no navigator**; layering is pure `zIndex`.

### 0. Shared conventions

**z-index stack** (higher wins; all overlays are absolutely positioned over the whole app including the tab bar):

| Overlay | zIndex |
|---|---|
| `CameraOverlay` (and its wrapper `View` in `index.tsx`) | 70 |
| `UploadSheet` / `MakerWorldSheet` / `TexturizeSheet` / `WizardOverlay` | 72 |
| `GcodeViewerOverlay` | 80 |
| `StlViewerOverlay` | 84 |

**Bottom-sheet chrome** (identical in UploadSheet, MakerWorldSheet, TexturizeSheet):
- Root: `Pressable` filling `inset:0`, `justifyContent:'flex-end'` — tapping the backdrop dismisses.
- Scrim: `Animated.View entering={FadeIn.duration(220)}` `pointerEvents="none"`, `backgroundColor:'rgba(0,0,0,0.5)'` (WizardOverlay uses `0.55`).
- Card: `Animated.View entering={SlideInDown.duration(320)}` (Wizard: `340`) wrapping an inner `Pressable onPress={()=>{}}` that **swallows taps so they don't reach the backdrop**.
- Grabber: `width 38, height 5, borderRadius 3, backgroundColor c.line2, alignSelf 'center'`.
- Card: `backgroundColor c.sheet`, `borderTopLeftRadius/borderTopRightRadius 26` (Wizard: 24), `paddingBottom insets.bottom + 20` (MW: `+18`, Texturize: `+16`), `...shadow1` = `{shadowColor:'#000', shadowOpacity:0.5, shadowRadius:2, shadowOffset:{width:0,height:1}}`.

**Theme tokens** (`src/theme.ts`, dark / light). `c` is a *mutable live object* — components read `c.x` inline at render, `setTheme()` `Object.assign`s it and notifies `useSyncExternalStore` subscribers.

```
bg      #0A0B0C / #EFF1F3      s1 #131517 / #FFFFFF   s2 #191C1F / #F5F6F8
s3      #23272B / #EAECEF      s4 #2D3237 / #DEE1E5
line    rgba(255,255,255,0.07) / rgba(0,0,0,0.08)
line2   rgba(255,255,255,0.12) / rgba(0,0,0,0.13)
t1      #F3F5F7 / #0D1012      t2 #A4ABB2 / #585E64   t3 #6B7177 / #878D94
accent  #2BD4C0 / #0EAE9C      accentInk #04201D / #FFFFFF
accentDim rgba(43,212,192,0.15) / rgba(14,174,156,0.14)
running #30D158 / #23B24A      heating #FF9F0A / #E0860A   paused #0A84FF
error   #FF453A / #E5392E      errorDim rgba(255,69,58,0.15) / rgba(229,57,46,0.12)
heatingDim rgba(255,159,10,0.15) / rgba(224,134,10,0.14)
idle    #8E9398 / #9AA0A6      sheet #16181B / #FFFFFF
thumb   #0e1113 / #E4E7EA      supports #E8A23D / #C77E14   swatchRing #8E9398 / #6E7378
mono    = Menlo on iOS
```
Fullscreen overlays (camera / gcode / STL) are **theme-independent** — they hardcode `#060708` (camera), `#0A0B0C` (gcode/STL), chrome pills `rgba(22,24,27,0.55–0.6)`, muted text `#6b7177`, dim text `#3a4046`, `#4f555b`, `#9aa0a6`.

**`Tap`** (`src/components/anim/index.tsx`) is used for *every* button: an `AnimatedPressable` that on press-in animates `scale → 0.955` and `opacity → 0.62` over 90 ms `Easing.out(quad)`, and back over 170 ms with a spring easing. It `cancelAnimation` on unmount (reanimated-4 New-Arch teardown race, swmansion/react-native-reanimated#9402).

---

### 1. `CameraOverlay` — fullscreen chamber camera

```ts
CameraOverlay({ streamUrl, snapshotUrl, status, cameraHint, onClose, onRefresh, onPipChange })
```
Mounted from `src/app/index.tsx:437-441`:
```tsx
{(overlay === 'camera' || pipActive) && (
  <View style={{position:'absolute', inset:0, zIndex:70,
                display: overlay === 'camera' ? 'flex' : 'none'}}
        pointerEvents={overlay === 'camera' ? 'auto' : 'none'}>
    <CameraOverlay streamUrl={streamUrl}
      snapshotUrl={camToken ? client.snapshotUrl(printerId, camToken) : null}
      status={status} cameraHint={profile.cameraHint}
      onClose={() => setOverlay(null)} onRefresh={remint} onPipChange={setPipActive} />
  </View>
)}
```
**Gotcha (must survive the port):** the overlay stays **mounted but hidden** while Picture-in-Picture is up — unmounting it tears down the `AVSampleBufferDisplayLayer` and takes the floating window with it. A watchdog clears `pipActive` 30 s after the overlay closes so a stuck flag can't hold the camera token alive forever (`index.tsx:263-268`).

**Token lifecycle** (`src/realtime/useCameraStream.ts`): `POST /api/v1/auth/…` no — camera uses `POST /api/v1/printers/camera/stream-token` → `{token}`. TTL treated as **55 min** (`TOKEN_TTL_MS = 55*60*1000`; server TTL is 60 min), re-checked on a 60 s interval while enabled; cleared to `null` when disabled.
- stream: `GET {base}/api/v1/printers/{printerId}/camera/stream?token=<enc>&fps=10` (multipart/x-mixed-replace)
- snapshot: `GET {base}/api/v1/printers/{printerId}/camera/snapshot?token=<enc>`
- **The token goes in the query string; `X-API-Key` is rejected with 401 on stream/snapshot.**

#### State machine

```
phase: 'connecting' | 'live' | 'failed'      (initial 'connecting')
reloadKey: number                            (bumped by Retry)
landscape: boolean                           (false)
```

Transitions:

| Trigger | Effect |
|---|---|
| `streamUrl` changes (token re-mint) **or** `reloadKey` changes | `setPhase('connecting')` |
| `!streamUrl` for 8000 ms | `phase==='connecting' → 'failed'` (safety net: with no URL no native view mounts, so nothing else would ever report failure) |
| `fetch(snapshotUrl)` resolves with `!r.ok` | `phase → 'failed'` unless already `'live'` |
| `fetch(snapshotUrl)` **rejects** (network error) | **ignored** — proves nothing about the stream path |
| native `onLive` | `phase → 'live'` |
| native `onError` with `retryable === false` | `phase → 'failed'` |
| Retry tap | `onRefresh()` (re-mint) **and** `reloadKey++` |

Derived:
```ts
const live = phase === 'live';
const failedView = phase === 'failed' || (!live && vm.kind === 'offline');
```

**Gotchas, verbatim from the comments:**
- *Fast-fail probe:* “a disabled H2C camera rejects the SNAPSHOT endpoint deterministically (HTTP 503 in ~60 ms) while its `/stream` returns HTTP 200 whose only multipart part is a text/plain error — the `<img>` never decodes a frame, so without this the overlay sits on ‘waking…’ for the full 40 s watchdog deadline.”
- *reloadKey is deliberately NOT in the native view's key*: “keying the WebView on `streamUrl` alone means a fresh token triggers exactly one remount/warm-up instead of two (sync reloadKey bump + async new URL).”
- *`CameraPiPView` is not keyed on `streamUrl` at all*: “the token refreshes hourly and remounting would destroy the display layer, taking any active PiP window down with it. The view hot-swaps internally.”
- A known-offline printer shows the failed card immediately rather than after the warm-up deadline.

#### Rendering

Root: `position:'absolute'`, `backgroundColor:'#060708'`, `zIndex:70`, plus `landscapeStyle`.

**Manual landscape (no native rotation):**
```ts
const landscapeStyle = landscape
  ? { width: winH, height: winW, left: (winW - winH)/2, top: (winH - winW)/2,
      transform: [{ rotate: '90deg' }] }
  : { inset: 0 };
```
Rationale in the comment: the app is portrait-locked in `app.json` (Info.plist) and `expo-screen-orientation` isn't installed, so true auto-rotate needs a native rebuild; a manual toggle also keeps working when the phone's own rotation lock is ON. **The whole overlay including chrome rotates**, so the controls read the right way up.

Video surface — native, *not* a WebView (an `<img>` can never enter PiP):
```tsx
<CameraPiPView ref={pipRef} url={streamUrl} active
  style={{ flex:1, backgroundColor:'#060708' }}
  onLive={() => setPhase('live')}
  onError={(e) => { if (!e.nativeEvent.retryable) setPhase('failed'); }}
  onPipStart={() => onPipChange?.(true)}
  onPipStop={() => onPipChange?.(false)} />
```
`isPictureInPictureSupported()` (native `CameraPiP.isSupported()`, `false` if the module is missing) gates the PiP button: “a control that silently does nothing is worse than no control.”

**Non-live overlay card** (`pointerEvents` = `'auto'` when failed, `'none'` while connecting; centered, `paddingHorizontal:36`):

*Failed:* `Feather "video-off" size 30 color #3a4046`; label `CHAMBER · NO SIGNAL` (mono, `#3a4046`, letterSpacing 2, 11 pt, marginTop 14); body (13 pt / lineHeight 19 / `#6b7177`, centered, marginTop 12) —
- offline: `"Printer is offline. The chamber camera needs the printer powered on and connected to Wi-Fi, then tap Retry."`
- else: `` `Couldn’t wake the chamber camera. ${cameraHint ?? 'Give it a moment and tap Retry.'} Make sure the printer is powered on.` ``
  `cameraHint` comes from `printerProfile(printer).cameraHint`:
  - A1: `"The A1’s camera is on-demand and can be slow — give it a moment and tap Retry."`
  - H2C: `"If this persists, enable LAN Mode Liveview in the printer’s settings screen (Settings → General)."`
  - unknown model: `"Give the camera a moment and tap Retry. Make sure the printer is powered on."`
- Retry button: marginTop 18, `paddingHorizontal 18, height 42, borderRadius 12, bg rgba(255,255,255,0.08)`, text `Retry` `#fff` 14 pt weight 600.

*Connecting:* `ActivityIndicator color #6b7177`; `CONNECTING…` (mono, `#6b7177`, letterSpacing 2, 11 pt); body `"Waking the chamber camera — the first frame can take a few seconds."` (12.5 pt / lineHeight 18 / `#4f555b`).

**Top chrome bar** (absolute, row, `gap: 11`):
```
paddingTop:    landscape ? 12 : insets.top + 10
paddingBottom: 16
paddingLeft:   (landscape ? insets.top : 0) + 16    // rotated, the notch runs down the left edge
paddingRight:  16
```
Order: **[rotate]** 40×40 r20 `rgba(22,24,27,0.6)` — icon `Feather` `landscape ? 'smartphone' : 'monitor'` size 17 `#fff`; **[close]** same chip, `chevron-down` 22; **[status pill]** `flex:1`, row, gap 8, `px 13 / py 10 / r 13 / rgba(22,24,27,0.55)` containing a 7×7 r4 dot in `vm.stateColor`, `vm.stateLabel` (13 pt/600/#fff), and right-aligned `` `${vm.progressInt}% · L${vm.layer}` `` (mono, 12 pt, `rgba(255,255,255,0.5)`); **[PiP]** (only if `pipSupported`) `MaterialIcons "picture-in-picture-alt"` 17 — *comment:* Feather has no equivalent and “minimize” read as a generic square; **[retry]** `refresh-cw` 18.

**Bottom LIVE badge** (only when `live`): `paddingBottom insets.bottom + 24`, `paddingHorizontal 18`; pill `px 11 / py 7 / r 9 / rgba(22,24,27,0.55)` with a 6×6 r3 `c.running` dot and text `LIVE` (10 pt, weight 600, letterSpacing 0.5, `#fff`).

---

### 2. `mjpegHtml.ts` — the WebView MJPEG fallback page

Still shipped and unit-tested (`src/components/__tests__/mjpegHtml.test.ts`); the native `CameraPiPView` superseded it in the overlay but **its retry algorithm is the reference semantics for MJPEG on this backend** and must be reproduced by whatever renders the stream.

Signature: `mjpegHtml(streamUrl, stallMs = 9000, retryMs = 2000, deadlineMs = 40000)`.

Why it exists (verbatim): WebKit decodes `multipart/x-mixed-replace` natively (expo-image / RN `<Image>` cannot). The A1 chamber camera is **on-demand**: the backend returns the `/stream` response (HTTP 200 + multipart headers) in ~7 ms but the cold camera needs **~7 s** to emit the first JPEG part, and a cold connect can stall or drop once or twice before frames flow. The `camera/diagnose` port-6000 probe is a **known false negative** on this A1.

> **CRITICAL:** during warm-up the socket is open and successful, so the `<img>` fires **neither `onload` nor `onerror`**. An onerror-only retry loop waits forever — the exact “stuck connecting / doesn't stream” symptom.

The page body (port this logic, not necessarily the HTML):

```js
var base=<url>, img=..., live=false, settled=false, startedAt=Date.now(), t=null, wd=null;
function disarm(){ if(wd){clearTimeout(wd); wd=null} }
function connect(){ disarm(); settled=false;
  if(!live){ wd=setTimeout(function(){wd=null;miss()}, 9000) }        // STALL WATCHDOG
  img.src = base + (base.indexOf('?')<0?'?':'&') + '_r=' + Date.now(); }  // cache-bust every attempt
function miss(){ if(settled)return; settled=true; disarm(); live=false; if(t)clearTimeout(t);
  if(Date.now()-startedAt <= 40000){ P('retry'); t=setTimeout(connect, 2000) } else { P('failed') } }
img.onload  = function(){ settled=true; disarm(); if(!live){ live=true; P('frame') } };
img.onerror = function(){ if(live){ live=false; startedAt=Date.now(); if(t)clearTimeout(t);
                                    t=setTimeout(connect,2000) } else { miss() } };
```
Key properties: retries are bounded by a **wall-clock deadline (40 s)**, not a fixed count, so a slow warm-up and a fast-erroring dead camera converge on the same deadline. Once a frame decodes the watchdog is **disarmed** (a healthy stream is never reconnected). A transport error *after* going live resets `startedAt`, i.e. self-heals with a fresh budget.

Messages posted to RN, exactly: `'connecting'`, `'frame'`, `'retry'`, `'failed'`, `'fps:<n>'`.

**Delivered-FPS counter** — WebKit does *not* fire `onload` per MJPEG part, so it samples the rendered `<img>` into a 16×16 canvas each animation frame and counts signature changes:
```js
fctx.drawImage(img,0,0,16,16);
var d=fctx.getImageData(0,0,16,16).data, s='';
for(var i=0;i<d.length;i+=16) s+=d[i]+',';   // 64 sample points
if(s!==fsig){ fsig=s; fcount++ }
// throws once if the canvas is tainted -> fpsDead=true, permanently disabled
setInterval(function(){ if(live&&!fpsDead) P('fps:'+fcount); fcount=0 }, 1000);
```
This **requires the document to be same-origin with the stream** — Bambuddy sends no CORS headers, so a cross-origin `<img>` taints the canvas. Hence `streamOrigin()`:
```ts
export function streamOrigin(u) { const m=/^(https?:\/\/[^/]+)/i.exec(u ?? ''); return m ? m[1] : null; }
```
used as the WebView `baseUrl`.

Page CSS: `html,body{margin:0;height:100%;background:#060708;overflow:hidden}` and `img{position:absolute;inset:0;width:100%;height:100%;object-fit:contain;background:#060708}`.

---

### 3. `UploadSheet` — "Add a file"

```ts
UploadSheet({ client, onClose, onUploaded })
```
State: `busy: boolean`, `pct: number`, `showMW: boolean`. When `showMW` is true it **returns `<MakerWorldSheet …/>` instead** (same modal slot, `onBack={() => setShowMW(false)}`).

`pick()`:
```ts
const res = await DocumentPicker.getDocumentAsync({ copyToCacheDirectory: true });
if (res.canceled || !res.assets?.[0]) return;
setBusy(true); setPct(0);
await client.uploadFile(a.uri, a.name, (f) => setPct(Math.round(f * 100)));
setBusy(false); onUploaded(); onClose();
// catch: setBusy(false); Alert.alert('Upload failed', String(e))
```
`client.uploadFile` → `POST {base}/api/v1/library/files`, **multipart, field name `file`**, mimeType `application/octet-stream`, headers `X-API-Key` (+ extras), response `{id}`.
> **Gotcha:** Expo's WinterCG `fetch` rejects RN's `{uri,name,type}` FormData part (“Unsupported FormDataPart implementation”), so this uses `expo-file-system`'s native `new File(uri).upload(...)` with `UploadType.MULTIPART` and an `onProgress({bytesSent,totalBytes})` callback. Progress fraction = `totalBytes > 0 ? bytesSent/totalBytes : 0`.

Layout: `paddingHorizontal 14, paddingTop 10`; title `Add a file` (17 pt/700/`c.t1`, centered, marginBottom 14).
Rows are `Tap` cards `padding 14, borderRadius 14, backgroundColor c.s2, gap 13`, each with a 36×36 r10 `c.accentDim` icon tile (icon `c.accent` size 19):
1. `Feather "folder"` → label `busy ? \`Uploading… ${pct}%\` : 'From Files'`; trailing `ActivityIndicator` while busy else `chevron-right` 16 `c.t3`.
2. `Feather "globe"` → `From MakerWorld` + subtitle `Paste a model link` (11.5 pt `c.t3`); `marginTop 10`; disabled while busy.
3. Cancel: `marginTop 14, height 50, r 14, bg c.s3`, text `Cancel` 16 pt/600.

---

### 4. `MakerWorldSheet` — import from a MakerWorld link

```ts
MakerWorldSheet({ client, onClose, onBack, onImported })
```
Card is `maxHeight: '88%'`.

State: `url` (string), `canDownload: boolean|null`, `resolving`, `resolved: MakerWorldResolved|null`, `err: string|null`, `picked: MWInstance|null`, `importing`.

**Mount:** `client.makerWorldStatus()` → `GET /api/v1/makerworld/status` → `{has_cloud_token, can_download}`; sets `canDownload = s.can_download`, `false` on any error (guarded by an `alive` flag).

If `canDownload === false`, a banner above the scroll (`bg c.heatingDim`, r13, p13, gap 10, `Feather "alert-triangle"` 17 `c.heating`):
> “MakerWorld isn’t connected on your Bambuddy server. You can preview a model, but to import it, sign in to Bambu Cloud in Bambuddy → Settings → MakerWorld.”

**Resolve** (`Resolve` button or keyboard `go` / `onSubmitEditing`; disabled when `resolving || !url.trim()`, and the button dims to `opacity 0.4` on empty input):
```ts
const u = url.trim(); if (!u) return;
setResolving(true); setErr(null); setResolved(null); setPicked(null);
const r = await client.resolveMakerWorld(u);        // POST /api/v1/makerworld/resolve {url}
setResolved(r); setPicked(r.instances?.[0] ?? null);
// on error: pull the API's detail out of the thrown message
const detail = String(e?.message ?? e).match(/\{"detail":"([^"]+)"\}/)?.[1];
setErr(detail ?? 'Couldn’t resolve that link. Paste a makerworld.com model URL.');
```
Error card: row, gap 9, p12, r12, `bg c.errorDim`, `Feather "x-circle"` 16 `c.error`, text 12.5/lineHeight 18 `c.t2`.

TextInput: `height 48, r 13, bg c.s2, px 14, color c.t1, fontSize 14`, placeholder `https://makerworld.com/en/models/…` in `c.t3`, `autoCapitalize="none" autoCorrect={false} keyboardType="url" returnKeyType="go"`. ScrollView uses `keyboardShouldPersistTaps="handled"`.

**Design block** (when `resolved.design` exists):
- Cover: `aspectRatio 16/10`, r16, `bg c.thumb`, `borderWidth 1 borderColor c.line`; image via `client.makerworldThumbUrl(design.coverUrl)` = `{base}/api/v1/makerworld/thumbnail?url=<enc>` (**server-proxied, unauthenticated**), `contentFit="cover"`, `cachePolicy="memory-disk"`; fallback `Feather "box"` 30 `c.t3`.
- Title: `design.title ?? \`Model ${resolved.model_id}\`` — 18 pt/700, letterSpacing −0.3.
- Byline (mono, 12 pt, `c.t3`): `` `@${design.designCreator.name}` `` + (if `downloadCount` is a number) `` `  ·  ${design.downloadCount} downloads` ``.
- `alreadyImported = !!resolved.already_imported_library_ids?.length` → chip `Already in your library` (`Feather "check"` 13 `c.accent`, `bg c.accentDim`, px11 py6 r9).

**Profile (instance) picker** when `instances.length > 0`. Label: `` `PROFILE${n>1 ? `  ·  ${n}` : ''}` ``. Each row (`padding 11, r 13, bg c.s2, borderWidth sel?1.5:0, borderColor c.accent`):
- 52×52 r10 cover (`inst.cover` via the same thumbnail proxy) or `Feather "layers"` 18.
- Title `inst.title || 'Default profile'` (13.5 pt/600).
- Meta line (mono, 11.5 pt, `c.t3`): `` `${t ? `${Math.round(t/60)} min` : '—'}${w ? `  ·  ${w} g` : ''}${inst.needAms ? '  ·  AMS' : ''}` ``.
- Up to 4 filament swatches: `fils.slice(0,4).map(f => <Swatch value={normColor(f.color)} size={9} radius={5}/>)`.
- `Feather "check"` 16 `c.accent` when selected.

Field fallbacks (multi-level, because MakerWorld's payload is inconsistent):
```ts
const instTime   = (i) => i.prediction ?? i.extention?.modelInfo?.plates?.[0]?.prediction ?? null;  // seconds
const instWeight = (i) => i.weight     ?? i.extention?.modelInfo?.plates?.[0]?.weight     ?? null;  // grams
const fils = inst.instanceFilaments ?? inst.extention?.modelInfo?.plates?.[0]?.filaments ?? [];
```

**Import** (button only rendered once a design is resolved; `height 52, r 15`, disabled when `importing || canDownload !== true`; background `canDownload===true ? c.accent : c.s3`):
```ts
const res = await client.importMakerWorld({          // POST /api/v1/makerworld/import
  model_id: resolved.model_id,
  profile_id: picked?.profileId ?? resolved.profile_id ?? undefined,
  instance_id: picked?.id ?? undefined,
});
onImported(); onClose();
Alert.alert(res.was_existing ? 'Already in library' : 'Added to library', res.filename);
// catch: setImporting(false); Alert.alert('Import failed', String(e?.message ?? e))
```
Button label: `importing ? 'Importing…' : canDownload===true ? (alreadyImported ? 'Import again' : 'Import to library') : 'Import unavailable'`.

Header: `Feather "chevron-left"` 22 `c.t2` in a 40 pt slot (`onBack`), centered title `From MakerWorld` 17 pt/700, 40 pt spacer for symmetry.

---

### 5. `TexturizeSheet` — bake a displacement texture onto an STL

```ts
TexturizeSheet({ texClient, file, onClose, onDone })
```
Backed by the **stl-texturize sidecar** (`TexturizeClient`, `X-API-Key` auth, its own `baseUrl`). Endpoints: `GET /textures`, `GET /textures/{id}/thumb`, `POST /texturize`, `GET /texturize-jobs/{id}`, `GET /texturize-jobs/{id}/result.stl`, `POST /texturize-jobs/{id}/commit`, `DELETE /texturize-jobs/{id}`, `GET /health` (unauthenticated; gates the whole feature — `texClient` is `null` if unhealthy and then the Texturize entry points disappear).

Helpers in this file:
```ts
function Chips<T>({ value, options: [T,string][], onChange })   // px13, height 34, r10;
   // selected: bg c.accentDim, text c.accent; else bg c.s2, text c.t2; 12.5pt/600
function SheetLabel({ children, first })                        // 11pt/600, letterSpacing 1, mono,
   // color c.t3, marginTop first?0:18, marginBottom 9
/** "-textured.stl" name, mirroring the sidecar's texturedName(). */
function texturedDisplayName(f) {
  return `${displayName(f).replace(/\.(stl|3mf|obj|gcode(\.3mf)?)$/i,'')}-textured.stl`;
}
```

**State:** `textures: TexturizeTexture[]|null`, `texId: string|null`, `amplitude=0.5`, `scale=0.5`, `mapping: TexturizeMappingMode='triplanar'`, `detail=0.4`, `job:{id,stage,progress}|null`, `preview:{jobId,tris?}|null`, `keeping`, `error: string|null`, `pollRef`, `previewRef` (mirror of `preview.jobId` for the unmount cleanup).

**Lifecycle:**
```ts
useEffect(() => {
  texClient.listTextures().then(t => { setTextures(t); if (t.length && !texId) setTexId(t[0].id); })
    .catch(e => setError(`Couldn't reach the texturize server: ${String(e?.message ?? e)}`));
  return () => {
    if (pollRef.current) clearInterval(pollRef.current);
    if (previewRef.current) void texClient.discard(previewRef.current).catch(()=>{});  // held preview = server memory
  };
}, [texClient]);
```

**Start:**
```ts
const { job_id } = await texClient.start({
  file_id: file.id, texture: { builtin: texId },
  amplitude, scale_u: scale, mapping_mode: mapping, refine_length: detail,
  protect_bed: true,
  commit: false,          // PREVIEW flow — nothing enters the library until Keep
});
setJob({ id: job_id, stage: 'queued', progress: 0 });
pollRef.current = setInterval(async () => {
  try {
    const j = await texClient.getJob(job_id);
    setJob({ id: job_id, stage: j.stage, progress: j.progress });
    if (j.status === 'done')  { clearInterval(pollRef.current); setJob(null);
                                setPreview({ jobId: job_id, tris: j.out_triangles }); }   // auto-open
    else if (j.status === 'error') { clearInterval(pollRef.current); setJob(null);
                                     setError(j.error ?? 'Texturize failed'); }
  } catch { /* transient poll failure — keep polling */ }
}, 1000);
```
`keep()`: `await texClient.commit(preview.jobId)` → `previewRef.current = null` (**must clear first so the unmount cleanup can't discard a committed job**) → `onDone()` (library refresh) → `onClose()`. On failure: `setKeeping(false); Alert.alert('Couldn’t save', apiErrorDetail(e))` where `apiErrorDetail` extracts `{"detail":"…"}` from the thrown message.
`adjust()`: best-effort `texClient.discard(preview.jobId)` (server TTLs anyway) then `setPreview(null)` → back to unchanged settings.

**Backdrop dismiss is disabled while `busy || preview`** (`onPress={busy||preview ? undefined : onClose}`).

**Controls** (`Chips` rows, in order):
| Label | Options (`value`, label) |
|---|---|
| TEXTURE | horizontal thumbnail strip, 74×74 r12, `borderWidth 2` `c.accent` when selected else `c.line`; image `texClient.textureThumbUrl(t.id)` **with `headers: texClient.authHeaders()`** (`X-API-Key`), `contentFit="cover"`, `transition={100}`, `cachePolicy="memory-disk"`; caption `t.name` 10.5 pt |
| DEPTH (`amplitude`) | `0.25 Subtle` · `0.5 Medium` · `1 Bold` |
| PATTERN SIZE (`scale_u`) | `0.25 Fine` · `0.5 Medium` · `1 Large` |
| WRAP (`mapping_mode`) | `triplanar Auto` · `cubic Boxy` · `cylindrical Round` |
| DETAIL (`refine_length`) | `0.4 Standard` · `0.25 Fine · slower` |

**Scroll height gotcha (real bug):**
```tsx
<ScrollView style={{ maxHeight: Math.max(220, winH - insets.top - insets.bottom - 320) }}
            showsVerticalScrollIndicator={false} bounces={false}>
```
> “Settings scroll inside a BOUNDED height; buttons are pinned BELOW the scroll so they can never be pushed off-screen (tall content used to overflow past maxHeight without scrolling — RN clips nothing by default, so the buttons landed under the home bar).”

Error card: `marginTop 14, p 12, r 12, bg c.s2, borderWidth 1, borderColor c.error`, text `c.error` 12.5/17.
Progress (while `busy`): 6 pt track r3 `c.s3` with an `c.accent` fill at `${Math.round(job.progress*100)}%`, caption `` `${job.stage} · ${pct}%` `` (mono, 11.5, centered).
Buttons row: `Cancel` (px22, h50, r14, `c.s3`, `opacity 0.5` when busy) + primary (flex 1, h50, r14): label `busy ? 'Texturizing…' : 'Texturize'`, background `busy || !texId ? c.s3 : c.accent`, text color `busy || !texId ? c.t3 : c.accentInk`.
Footnote (10.5/14, centered, `c.t3`): “The result opens for review first — nothing is saved until you Keep it. The bed face stays flat.”

**Fullscreen preview** (auto-opens on `done`, `bg '#0A0B0C'`, `inset:0`):
```tsx
<Pressable onPress={() => {}} style={{position:'absolute', inset:0, backgroundColor:'#0A0B0C'}}>
  <StlWebView name={texturedDisplayName(file)}
    direct={{ origin: texClient.baseUrl, path: texClient.resultPath(preview.jobId),
              headers: texClient.authHeaders() }} />
```
> **Gotcha:** “MUST be a tap-swallowing `Pressable`: it sits inside the backdrop `Pressable`, and once the job ends (`busy=false`) an unhandled tap here would bubble up and dismiss the whole sheet (reported: ‘drawer closed once I pressed Texturize’).”

Top bar (`paddingTop insets.top+10, px 16, gap 10`): info pill (`flex 1`, h44, r13, `rgba(22,24,27,0.55)`) reading `` `Result${tris ? ` · ${tris.toLocaleString()} tris` : ''}` ``; `Adjust` (px16, h44, r13, `rgba(42,46,51,0.92)`, text `#E7E9EC`); `Keep` (px18, h44, r13, `c.accent`, text `c.accentInk` 700, or an `ActivityIndicator` while `keeping`).
> Comment: actions live in the **top** bar because the bottom belongs to the STL page's own shading chips — **Normals is the best mode for judging texture depth before committing.**

---

### 6. `GcodeViewerOverlay` — layer-by-layer scrub

```ts
GcodeViewerOverlay({ src: {url, headers?}, title, onClose, plate?: {w,d} })   // zIndex 80
```
`html` is built once on mount from `gcodeViewerHtml(src, plate)`; `plate` is `printerProfile(printer).plate` (A1 `256×256`, H2C `350×320`, unknown `256×256`).

```ts
const pageOrigin = (/^(https?:\/\/[^/]+)/i.exec(src.url)?.[1] ?? 'https://localhost') + '/';
<WebView source={{ html, baseUrl: pageOrigin }} originWhitelist={['*']} scrollEnabled={false}
         javaScriptEnabled domStorageEnabled allowsInlineMediaPlayback ... />
```
> **Two load-bearing gotchas:** (1) “No fetch here on purpose: the page pulls the G-code itself and parses it with JIT. Handing a 70 MB string across the bridge (then JSON-ing it back into the page) was the actual reason large prints ‘couldn't be previewed’.” (2) “Load the page on the SERVER's origin so its in-page fetch is same-origin: Bambuddy sends no CORS headers, so a localhost origin would get the request blocked outright.”

`onMessage` handles exactly two message types: `{type:'error', message}` → `setErr`; `{type:'ready', hasSupport}` → `setHasSupport`. Malformed JSON is swallowed.

Chrome: close chip (`chevron-down` 22) + title pill (`flex 1`, `numberOfLines 1`) + — once `hasSupport != null` — a supports pill (dot 7×7 in `c.supports` / `#4f555b`; text `Supports` / `No supports`).
Loading state: `ActivityIndicator c.accent` + `LOADING G-CODE…` (mono, `#3a4046`, letterSpacing 2, 11 pt). Error state: `Feather "layers"` 30 `#3a4046` + the message (14 pt `#6b7177`).

The page itself (`src/library/gcodeLayers.ts`, ~369 lines, pure builder + `GCODE_PARSER_JS` running **inside** the WebView): Canvas2D orthographic orbit, real build plate with 10 mm grid + bolder 50 mm lines + X/Y edge accents + origin dot, ground shadow, background gradient, steel height ramp (dim bottom → bright top) with the **current layer in white and supports in amber `#E8A23D`**, a range slider for the layer, chips `Steel / Ivory / Light bg`, XYZ gizmo, layer label with real Z; gestures: 1-finger rotate + inertia, 2-finger pinch zoom + pan, double-tap reset, pitch clamped above the horizon (also keeps painter's-order z-sorting correct). Posts `{type:'ready', total, hasSupport, segments}`.

Where it's opened from: the wizard (`View layers` on the plate thumbnail, steps 1 and 5) via `client.gcodePath(fileId)` = `/api/v1/library/files/{id}/gcode` + `client.authHeaders()`; and `TabScreens.tsx:531` for a sliced 3MF on the printer's SD card via `client.printerGcodePath(printerId, path)` = `/api/v1/printers/{id}/files/gcode?path=…`.

---

### 7. `StlWebView` / `StlViewerOverlay` — interactive mesh preview

```ts
StlWebView({ client?, fileId?, name, compact?, style?, direct? })
StlViewerOverlay({ client, fileId, name, onClose })   // zIndex 84
```
Two modes:
- **library mode**: `client.mintFileDownloadUrl(fileId, name)` → `POST /api/v1/library/files/{id}/slicer-token` → token read from `data.token ?? data.slicer_token ?? data.download_token ?? data.value` → URL `{base}/api/v1/library/files/{id}/dl/{enc(token)}/{enc(filename||`model-${id}.stl`)}`. **Single-use, short-lived → minted exactly once per mount** (`useEffect` with `[]` deps and an explicit comment).
- **direct mode**: `direct={{origin, path, headers}}` — page points at an arbitrary same-origin path with optional auth headers for the in-page fetch (used by the texturize preview).

`baseUrl` for the WebView is `${direct ? direct.origin : client.baseUrl}/`, so the page's own `fetch` is same-origin and the mesh bytes never cross the RN bridge.

`compact` hides the in-page control card and reset button (`<style>#bar,#reset{display:none}</style>`) — used for the inline preview in wizard step 1; orbit/pinch/double-tap still work.

Loading UI: `ActivityIndicator c.accent` + `LOADING MODEL…` (mono, `#3a4046`, letterSpacing 2, 10 pt). Error UI: `Feather "box"` (22 compact / 30) + `apiErrorDetail(e)` text (12/14 pt `#6b7177`). `onMessage` only reacts to `{type:'error'}`.

The page (`stlViewerHtml`, 214 lines): **raw WebGL, no CDN imports** (offline WKWebView constraint). `MAX_STL_BYTES = 120*1024*1024` (~2.4M tris) → error `"model too large to preview on the phone"`.
- Parses **binary and ASCII** STL; ASCII detected by `/^\s*solid/` in the first 512 bytes *and* the presence of `facet`; binary layout: tri count at byte 80 (LE uint32), each facet 50 bytes, vertices at `84 + t*50 + 12`; validity checks `u8.length<84 → 'not an STL'`, `84+n*50>u8.length → 'truncated STL'`.
- **Face normals are recomputed from geometry** (cross product, normalized), not read from the file.
- Camera fit gotcha (caught numerically before shipping): the initial distance fits the bounding **sphere** through the **narrower** screen axis, because 0.9 rad is the *vertical* fov and on a portrait phone the horizontal fov is ~⅓ of it, so a height-only fit clipped wide models:
```js
var rad = 0.5*Math.sqrt(dx*dx+dy*dy+dz*dz) || 1;
var asp0 = Math.max(0.3, innerWidth/Math.max(innerHeight,1));
var vHalf = 0.45, hHalf = Math.atan(Math.tan(vHalf)*asp0);
var DEF = { yaw:-0.62, pitch:0.5, dist: rad/Math.tan(Math.min(vHalf,hHalf))*1.15 };
```
- Z-up orbit; pitch clamped to ±1.45; rotate sensitivity `d*0.006` with inertia damping `*0.92`; pinch zoom clamped to `[span*0.15, span*8]`; 2-finger pan scale `dist*0.0016`; double-tap (<280 ms) resets to `DEF`.
- Materials: `steel [0.62,0.67,0.76]`, `ivory [0.91,0.89,0.84]`, `teal [0.17,0.83,0.75]`; `normals` mode outputs `n*0.5+0.5` as color; two-light Lambert `lum = 0.22 + 0.62*d1 + 0.22*d2` with light dirs `(0.5,0.4,0.8)` and `(-0.6,-0.3,0.2)`. Chips: `Steel / Ivory / Normals / Light bg`; light bg clear color `(0.91,0.92,0.93)`, dark `(0.063,0.07,0.086)`. `dpr = min(devicePixelRatio, 2.5)`.
- Label shows `` `${NAME} · ${tris.toLocaleString()} tris` `` once loaded; hint text `drag rotate · pinch zoom · 2-finger pan`.

---

### 8. `PlateReview` — sliced-model summary block (used inside the wizard)

```ts
PlateReview({ client, fileId, camToken, plateIndex, onSelectPlate?, onViewLayers?, sliced = true })
```
Loads in parallel with `Promise.allSettled`: `client.getPlates(fileId)` (`GET /api/v1/library/files/{id}/plates`) and `client.getFileDetail(fileId)` (`GET /api/v1/library/files/{id}` → `.metadata`). Merged by the **pure** `buildPlateReview(plates, meta, plateIndex)` (`src/library/plateReview.ts`, 1-based `plateIndex`, falls back to the first plate; both inputs may be null):

```ts
timeSeconds = plate.print_time_seconds ?? meta.print_time_seconds
grams       = plate.filament_used_grams ?? meta.filament_used_g
layers      = meta.total_layers;  layerHeight = meta.layer_height
heightMm    = round(layers * layerHeight * 100)/100        // when both known
printer     = plates.embedded_printer ?? meta.sliced_for_model
process     = plates.embedded_process
filaments   = plate.filaments (slot_id/type/color/used_grams/used_meters)
              ?? meta.filament_slots (slot_id/type/color/used_g, meters=null)
fmtSeconds(s) => s<=0/null ? '—' : m<60 ? `${m} min` : `${h} h ${m%60} min`   // m = round(s/60)
```

Render:
- Plate chips when `plateCount > 1`: `Plate {index}` — px14 py8 r11, selected `bg c.accentDim, borderWidth 1.5 c.accent`, text `c.accent`, else `bg c.s2` / `c.t2`.
- Thumbnail: `aspectRatio 4/3`, r16, `bg c.thumb`, `border c.line`; URL `client.plateThumbUrl(fileId, plateIndex, camToken)` = `{base}/api/v1/library/files/{id}/plate-thumbnail/{plateIndex}?token=<camera stream token>` — **only rendered if `plate.has_thumbnail`**; otherwise `ActivityIndicator` while loading, else `Feather "box"` 30.
  > **Gotcha:** library/plate thumbnails are gated by the **camera stream token in `?token=`**, not `X-API-Key` (401 otherwise).
- `View layers` button (when `onViewLayers` and not loading): bottom-right of the thumbnail, `rgba(10,11,12,0.72)`, r10, px11 py7, `Feather "layers"` 13 `c.accent` + white 11.5 pt label.
- If `sliced`: three `PStat` cards (flex 1, p13, r14, `c.s2`; label 9 pt mono `c.t3` letterSpacing 0.8; value 19 pt/700 tabular-nums; optional sub 10.5 pt mono): `PRINT TIME` = `fmtSeconds(timeSeconds)`, `LAYERS` = count with sub `${layerHeight.toFixed(2)} mm/layer`, `FILAMENT` = `${grams.toFixed(1)} g`.
- If **not** `sliced` and multi-plate: “This file has {n} plates. Pick the one to print — only it gets sliced. Time and material are estimated after slicing.”
- Detail line (mono, 11.5 pt `c.t3`), joined with `'  ·  '`: `${heightMm} mm tall`, `${nozzleTemp}°C nozzle`, `bedType`.
- Filament list: rows in a `c.s2` r14 container, separated by `borderTopWidth 1 c.line`; `Swatch value={normColor(f.color)} size 22 radius 7`, type name, then `${grams.toFixed(1)} g  ·  ${meters.toFixed(2)} m` (mono).
- Settings line (mono, 11 pt): `${printer}  ·  ${process}`.

`Swatch` has **three states** (empty = transparent + dashed ring; unknown colour = dashed ring + `help-circle` glyph when `size>=16`; known = solid fill + solid ring) and always draws a 1 pt ring in `c.swatchRing` — chosen for ≥3:1 contrast against every surface, because a white spool on a white card was an invisible hole.

---

### 9. `WizardOverlay` — the 7-step print wizard

```ts
WizardOverlay({ client, file, camToken, status, printerId, printer,
                onClose, onStarted, onTexturize?, onView3D?, lanMode })   // zIndex 72
```

#### 9.1 Step model

```ts
const alreadySliced = (file.file_type || '').includes('gcode');
const steps = alreadySliced ? [1, 2, 6, 7] : [1, 2, 3, 4, 5, 6, 7];
const idx   = steps.indexOf(step);            // step state starts at 1
const next  = () => setStep(steps[Math.min(idx + 1, steps.length - 1)]);
const back  = () => {
  // Review's natural "back" is Material: step 4 is a transient progress screen, and landing on it
  // re-runs the slice with unchanged settings. Skipping it lets the user actually change settings.
  if (step === 5 && !alreadySliced) return setStep(3);
  setStep(steps[Math.max(idx - 1, 0)]);
};
const titles   = {1:'File',2:'Printer',3:'Material',4:'Slicing',5:'Review',6:'Map filament',7:'Start print'};
const captions = {1:'The model you picked', 2:'Confirm the target printer',
                  3:'Pick filament and quality', 4:'Preparing G-code on your server',
                  5:'Check time and material', 6:'Choose which AMS tray to print from',
                  7:'Review, then send it to the queue'};
```
So a **pre-sliced** file skips Material/Slicing/Review entirely: `File → Printer → Map filament → Start print` (4 steps, counter shows `1/4`…`4/4`).

**Footer** (recomputed each render):
```ts
if (step === 4) footer = null;                                    // no footer during slicing
else if (step === 7) footer = { label: starting ? 'Starting…' : 'Start print',
                                bg: c.accent, fg: c.accentInk,
                                onPress: lock.press('startPrint', start),
                                locked: lock.blocked('startPrint') };
else if (step === 5) footer = { label: 'Looks good', bg: c.accent, fg: c.accentInk, onPress: next };
else                 footer = { label: 'Continue',   bg: c.s3,     fg: c.t1,        onPress: next };
```
`Back` is shown when `idx > 0 && step !== 7` (px22, h52, r15, `c.s3`). Primary button: `flex 1, h52, r15`, `opacity LOCKED_OPACITY (0.4)` when locked, with a `Feather "lock"` 15 glyph prepended, and `disabled={starting}`.

**LAN gate:** `useLockedAction(lanMode)`; `startPrint` is in the blocked set, so with `developer_mode === false` the button dims and tapping shows `Alert.alert('Printer controls are locked', 'Turn on LAN Developer Mode on the printer (Settings → Network), then re-enter its new access code in this app.')`. `lanMode` is tri-state — `'unknown'` never blocks. Comment: “Slicing and uploading work fine without Developer Mode; only the final ‘go’ is refused.”

#### 9.2 Layout / chrome

Sheet: `height: '92%'`, `borderTopRadius 24`, `overflow:'hidden'`, `bg c.sheet`.
> **Gotcha:** “No safe-area padding here: this is a BOTTOM sheet at 92% height, so its top edge already sits below the notch. Adding `insets.top` pushed the header ~59 pt further down on top of that, leaving a dead band above ‘Cancel’.”

Header row (`px 18, paddingTop 16`): **Cancel** on the left as `c.accent` text 15 pt/600 (“Cancel is the primary escape from a 4-step flow — tinted like a real button, not muted secondary text that reads as disabled”), centered title + caption (15 pt `c.t1` / 11 pt `c.t3`), and `{idx+1}/{steps.length}` in mono `c.t3` 12 pt on the right.

Step rail (`px 18, paddingTop 15, gap 4`): one column per step — a 3 pt r2 bar (`i <= idx ? c.accent : c.s3`) plus the uppercased title at 8.5 pt mono, same color rule.

Body: `<ScrollView contentContainerStyle={{padding:18}}>` wrapping `<FadeRise key={step} dy={10} duration={300}>` — remounting on `key={step}` replays a 300 ms fade+rise on every step change.

`L` = section label (11 pt/600, letterSpacing 1, mono, `c.t3`, marginBottom 12). `Row` = key/value line (`padding 14`, `borderBottomWidth 1 c.line`, key 13 pt `c.t2`, value 13 pt/600 `c.t1` `maxWidth 200 numberOfLines 1`).

#### 9.3 Data loading effects

**(a) Presets + AMS assignments** — re-runs on `[client, printerId, token, profile.printerPresetBase, nozzle]`:
```ts
Promise.all([ client.getPresets(),                         // GET /api/v1/slicer/presets
              client.listAssignments(printerId).catch(()=>[]) ])  // GET /api/v1/inventory/assignments?printer_id=
.then(([p, a]) => {
  const std = p.standard ?? {};
  const printerPreset =
      std.printer?.find(x => x.name === printerPresetNameFor(profile.printerPresetBase, nozzle))  // "Bambu Lab A1 0.6 nozzle"
   ?? std.printer?.find(x => x.name === `${profile.printerPresetBase} 0.4 nozzle`)
   ?? std.printer?.find(x => x.name === profile.printerPresetBase);
  const { qualities, hasSupportProfile, supportByBase } = selectProcess(p, token, nozzle);
  const allFilaments = std.filament ?? [];
  const catalog = catalogFilaments(allFilaments, token, nozzle);
  setPresets({ printer: printerPreset, qualities, catalog, allFilaments, hasSupportProfile, supportByBase });
  setAssigns(a); setQuality(pickDefaultQuality(qualities));
})
.catch(() => setPresets({ qualities: [], catalog: [], allFilaments: [], supportByBase: {} }));
```
`token = printerProfile(printer).presetToken` — `"@BBL A1"` / `"@BBL H2C"` / `` `@BBL ${model}` `` for unknown models.

`selectProcess` (pure, `src/library/presetSelect.ts`) merges `standard.process + local.process + cloud.process + orca_cloud.process`, dedupes by `id`, then filters by **an asymmetric naming convention verified against the live preset list**:
```ts
const tokenRe  = new RegExp(`0\\.\\d+mm .*${escape(token)}(?!\\S)`);
const suffixRe = new RegExp(`${escape(token)} ${escape(nozzle)} nozzle$`);
filter: nozzle === '0.4' ? tokenRe.test(name) && !/0\.[268] nozzle/.test(name)
                         : suffixRe.test(name)
```
i.e. **0.4-nozzle presets carry NO nozzle suffix**; 0.2/0.6/0.8 are suffixed. Support twins (`/\+ supports|support|tree/i`) are pulled OUT of `qualities` and paired to their base via `supportTwinName(base, token)` = `"0.20mm Standard @BBL A1"` → `"0.20mm Standard + Supports @BBL A1"`. `pickDefaultQuality` = first `/0\.20mm Standard/`, else first containing `"0.20"`, else `qualities[0]`.

**(b) Nozzle default** — `mountedNozzles(status)` reads `status.nozzles[].nozzle_diameter`, keeping only `'0.2'|'0.4'|'0.6'|'0.8'` in extruder order, deduped. Until the user touches the picker (`nozzleTouchedRef`), the wizard follows the hardware: `defaultNozzle(mounted)` prefers `'0.4'` when mounted (richest preset family incl. support twins), else `mounted[0]`, else `'0.4'`. Effect dep is `[mounted.join(',')]`.

**(c) Pre-sliced target machine** (only when `alreadySliced`):
```ts
client.getPlates(file.id).then(p => setSlicedFor(p.embedded_printer ?? file.sliced_for_model ?? null));
const printerMismatch = alreadySliced && !slicedForMatchesPrinter(slicedFor, profile);
```
`slicedForMatchesPrinter` (pure): empty/null ⇒ allowed; otherwise upper-cases both, strips `"BAMBU LAB "`, and requires **exact model equality or model + `" 0."` nozzle suffix** — so `"Bambu Lab A1 mini"` must NOT pass for the A1.

**(d) Loaded-filament default selection** — runs once (`defaultedRef`) when presets + AMS are known, keyed on `[presets, loadedKey]` where `loadedKey = loaded.map(f => `${f.slot}:${f.preset?.id ?? ''}`).join(',')`:
```ts
// f.slot is the GLOBAL id, which is the same space as tray_now.
const active = loaded.find(f => f.slot === (status?.tray_now ?? -1) && f.preset) ?? loaded.find(f => f.preset);
if (active?.preset) { setFilament(active.preset); setSlot(active.slot); defaultedRef.current = true; }
else if (trays.length > 0 && presets.catalog[0]) { setFilament(presets.catalog[0]); defaultedRef.current = true; }
```

**AMS topology** — `trays = amsTrayRefs(status)`: **every tray across EVERY unit**, flat, in unit order.
> **Gotcha:** “This used to be `status.ams[0].tray`, which made 5 of the 9 slots on a three-unit machine invisible and unprintable.”
Global tray id math (the *one* place it lives): `globalTrayId(unitId, localId) = unitId >= 128 ? unitId : unitId*4 + localId` — regular AMS units pack 4 trays each; an AMS HT (128..135) *is* its own tray id. `tray_now`, `ams/load`'s `tray_id` and `ams_mapping` **values** all speak this space.

`loaded = loadedFilaments(trays, assigns, presets.allFilaments, token, nozzle).filter(f => !f.isSupport)`:
- skips empty trays; matches an assignment on **both** `tray_id === localId` **and** `ams_id === unitId` (falling back to a legacy record with `ams_id == null`) — matching `tray_id` alone made AMS 2 slot 0 inherit AMS 1 slot 0's spool, i.e. the wrong preset drove the slice;
- `colorHex = normColor(tray.tray_color) ?? normColor(assignment.spool.rgba)`;
- preset = `matchFilamentPreset(presets, spool.slicer_filament_name, tray_type, token, nozzle)`: pool is names where the text after `token` is `''` **or** `" ${nozzle} nozzle"`, then `` `${base} ${token} ${nozzle} nozzle` `` first, else `` `${base} ${token}` ``, **no `startsWith` fallback**; raw material types map through `MATERIAL_BASE` (`PLA→Bambu PLA Basic`, `PETG→Bambu PETG HF`, `PETG-CF→Bambu PETG-CF`, `ABS→Bambu ABS`, `ABS-GF→Bambu ABS-GF`, `ASA→Bambu ASA`, `TPU→Bambu TPU 95A HF`, `PC→Bambu PC`, `PA-CF→Bambu PA-CF`, `PLA-S`/`PVA→Bambu Support For PLA`);
- `isSupport = /support|^PLA-S$|^PVA$/i.test(material)`.

`catalogFilaments` uses the same pool with a fixed curated list: `Bambu PLA Basic, Bambu PLA Matte, Bambu PETG HF, Bambu PETG-CF, Bambu ABS, Bambu ASA, Bambu TPU 95A HF, Bambu Support For PLA`.
> **Gotcha:** “Overlays.tsx used to rebuild this with its own 0.4-only regex, which is how the nozzle-size bug came to exist in two places at once.”

#### 9.4 Step 1 — File

State seeds: `selectedPlate = 1`, `bedType = profile.bedTypes[0].id`.

*Pre-sliced branch:* `displayName(file)` (19 pt/700, letterSpacing −0.3) + `` `${file.file_type} · pre-sliced` `` (mono 12 pt `c.t3`). If `printerMismatch`, a hard warning card (`bg c.errorDim`, `borderWidth 1 c.error`, r13, p13):
> “Sliced for {slicedFor} — not for {printer?.name ?? 'this printer'}. G-code from another machine can crash the toolhead. Reslice the model instead.”
Then `<PlateReview … onSelectPlate={setSelectedPlate} onViewLayers={…} />` (sliced=true).

*Unsliced branch:* name + `` `${file.file_type} · will be sliced` ``, then:
- if `file_type.toLowerCase() === 'stl'`: a **live inline mesh** in a `aspectRatio 4/3` r16 box (`bg #0A0B0C`, `border c.line`) — `<StlWebView client fileId name compact />`. Comment: “Raw STLs have no slicer plates yet — PlateReview would be an empty grey box.”
  Plus two action cards (only for STL, `bg c.s2` r14 p14 gap 13, 36×36 r10 `c.accentDim` icon tile):
  - `View in 3D` / “Inspect the full-resolution mesh — rotate, zoom, switch shading” (`Feather "box"` 18) → `onView3D(file)`
  - `Texturize first` / “Bake a surface pattern onto the model, then print the textured copy” (`Feather "droplet"` 18) → `onTexturize(file)` (which in `index.tsx` closes the wizard and opens `TexturizeSheet`)
  Both are conditional on the callback being provided (`onTexturize` is `undefined` when the texturize sidecar is unhealthy).
- else: `<PlateReview … sliced={false} />` so a multi-plate project exposes all plates for selection.

`displayName(f)` = `decodeURIComponent(f.print_name || f.filename || \`file-${f.id}\`)`, falling back to the raw string if decoding throws.

#### 9.5 Step 2 — Printer (confirmation only)

One card (`p 16, r 16, bg c.s2, gap 14`): 52×52 r13 `c.s3` tile with `Feather "cpu"` 26 `c.t2`; `printer?.name ?? 'Printer'` 17 pt/700; status line — 6 pt dot in `status?.connected ? c.running : c.idle` plus `` `${profile.printerPresetBase}${printer.location ? ` · ${location}` : ''} · ` `` + `Connected`/`Offline`. Footnote: “Switch printers from the dashboard header.” No validation, no selection.

#### 9.6 Step 3 — Material (the dense one)

**NOZZLE** — four equal chips `0.2 / 0.4 / 0.6 / 0.8` (`flexGrow 1, py 12, r 13, bg c.s2, borderWidth on?1.5:0 c.accent`): value 15 pt/700 tabular-nums (`c.accent` when selected), sub-label 9.5 pt — `mounted` in `c.running` when that size is physically installed, else `mm` in `c.t3`. Tapping sets `nozzleTouchedRef.current = true` (stops hardware auto-follow) and re-runs the presets effect.
Warning when `mounted.length > 0 && !mounted.includes(nozzle)` (`bg c.heatingDim`, r12, p12):
> “A {nozzle} mm nozzle isn’t mounted right now ({mounted.join(' / ')} mm installed). Slicing works, but swap the nozzle before printing.”

**LOADED IN THE PRINTER** (label is `MATERIAL` when `loaded.length === 0`) — one row per loaded, non-support filament (`p 14, r 13, bg c.s2, borderWidth sel?1.5:0 c.accent`, `opacity 0.5` and disabled when no preset matched):
- `Swatch value={f.colorHex} size 30 radius 9`
- title: `` colorName ? `${colorName} · ${material}` : material `` where `colorName = f.colorName ?? colorName(f.colorHex)` (the pure HSL-bucket namer in `present.ts`: `chroma < 0.06` ⇒ White/Off-white/Light grey/Grey/Dark grey/Black by luminance, else a hue bucket)
- sub: `` `Slot ${f.slot + 1}` `` + `' · no matching profile'` when `preset === null`
- selecting sets **both** `filament` and `slot` (`f.slot` is the global id)

**OR PICK ANOTHER FILAMENT** disclosure (`CHOOSE A FILAMENT` when nothing is loaded; auto-expanded in that case): chevron toggles `showCatalog`; the catalog list renders `m.name.replace(\` ${token}\`, '')` per row with a check when selected.

**QUALITY** — 2-up grid (`width '47%', flexGrow 1, p 15, r 13`):
```ts
const h = q.name.match(/0\.\d+mm/)?.[0] ?? '';                 // "0.20mm"
const label = q.name.replace(/0\.\d+mm /, '').replace(` ${token}`, '');   // "Standard"
```
Big number = `h.replace('mm','')` (19 pt/700, tabular-nums, `c.accent` when selected), label under it (12 pt `c.t2`).

**BUILD PLATE** — chips from `profile.bedTypes` (first is the default):
- A1: `Textured PEI Plate`/“Textured PEI”, `Smooth PEI Plate`/“Smooth PEI”, `Cool Plate`, `Engineering Plate`/“Engineering”
- H2C: Textured PEI, Smooth PEI, `High Temp Plate`/“High Temp”, Engineering
The `id` is the canonical `bed_type` the slicer expects; the label is display-only.

**SUPPORTS** — rendered only when `quality && presets.supportByBase[quality.name]` exists: a full-width toggle card (`bg c.s2`, `borderWidth supports?1.5:0 borderColor c.supports`, `Feather "git-merge"` 19, custom 48×29 r15 track with a 23 pt white knob):
> “Tree supports under overhangs. Adds print time + material; shown in amber in the layer view.”
Else if `presets.hasSupportProfile === false`, an info card:
> “Supports aren’t set up yet. Run the one-time provisioning on your server (deploy/bambuddy/ensure-support-profiles.py) and a Supports toggle appears here.”
Else nothing.

**ADVANCED** — rendered **only when `client.hasAdminLogin`** (“hidden entirely without admin creds so the feature never dead-ends on a 403”). Collapsible; shows an `{n} changed` badge (`bg c.accentDim`, `c.accent` 10.5 pt/700) and a `Reset` link (`setAdv({})`) when `overrideCount(adv) > 0`. Each row is a `Chips` where the first option is `undefined` labelled **`Preset`** (= keep the profile's value):

| Row | Options |
|---|---|
| WALL LOOPS (`wallLoops`) | Preset, 2, 3, 4, 6 |
| INFILL DENSITY (`infillDensity`) | Preset, 10%, 15%, 25%, 40%, 100% |
| INFILL PATTERN (`infillPattern`) | Preset + `grid, gyroid, cubic, triangles, honeycomb, lightning, adaptivecubic, crosshatch` (raw slicer values as labels) |
| TOP SURFACE (`topPattern`) | Preset + first 3 of `monotonic, monotonicline, concentric, alignedrectilinear` |
| PRIME TOWER (`primeTower`) | Preset, On (`true`), Off (`false`) |
| SUPPORT STYLE (`supportStyle`) | Preset + `default, snug, tree_slim, tree_strong, tree_hybrid, tree_organic` |
| SUPPORT ANGLE (`supportAngle`) | Preset, 25°, 30°, 40°, 55° |
| FLOW RATIO (`flowRatio`) | Preset, 0.95, 0.98, 1.02, 1.05 |

Footnote: “‘Preset’ keeps the profile’s value. Changes apply to this slice via a reusable “Sprout Custom” profile on your server — stock presets are never modified.”

#### 9.7 Step 4 — Slicing (transient; no footer)

UI: `RollingNumber value={slicePct} fontSize 46 weight 700 color c.t1 letterSpacing -1` + a 22 pt `%` glyph in `c.t3`; `HeatBar pct={slicePct} color={c.accent} height 5` at `width '78%'` marginTop 18 (animates width over 600 ms `Easing.out(quad)`); caption “Slicing on your server…”.

The effect fires on `step === 4` (dep array is literally `[step]`):

```ts
if (alreadySliced) {                       // nothing to slice — fake a beat and move on
  setResult({ print_time_seconds: file.print_time_seconds ?? undefined,
              filament_used_g:   file.filament_used_grams ?? undefined,
              library_file_id:   file.id });
  setSlicePct(100);
  const t = setTimeout(() => setStep(5), 600);
  return () => clearTimeout(t);
}
let cancelled = false;
setSlicePct(5);
// Supports ON -> slice with the quality's "+ Supports" twin profile (provisioned in Bambuddy)
const processPreset = (supports && quality && presets?.supportByBase?.[quality.name]) || quality;

let processRef = processPreset, filamentRef = filament;
if (client.hasAdminLogin && processPreset && hasProcessOverrides(adv)) {
  const setting = buildProcessDelta(processPreset.name, adv, `Sprout Custom ${token}`)!;
  const id = await client.upsertLocalPreset(`Sprout Custom ${token}`, 'process', setting);
  processRef = { source: 'local', id: String(id) };
}
if (client.hasAdminLogin && filament && hasFilamentOverrides(adv)) {
  const variants = (printer?.nozzle_count ?? 1) > 1 ? 3 : 1;
  const setting = buildFilamentDelta(filament.name, adv, `Sprout Custom Filament ${token}`, variants)!;
  const id = await client.upsertLocalPreset(`Sprout Custom Filament ${token}`, 'filament', setting);
  filamentRef = { source: 'local', id: String(id) };
}
const { job_id } = await client.slice(file.id, {         // POST /api/v1/library/files/{id}/slice
  printer_preset: presets?.printer,
  process_preset: processRef,
  filament_preset: filamentRef,
  plate: selectedPlate,
  bed_type: bedType,
  export_3mf: true,
});
for (let i = 0; i < 90 && !cancelled; i++) {             // GET /api/v1/slice-jobs/{job_id}
  const j = await client.getSliceJob(job_id);
  setSlicePct(p => Math.min(95, p + 6));                 // fake progress: +6 per poll, capped at 95
  if (j.status === 'completed') { setResult(j.result ?? {}); setSlicePct(100);
                                  if (!cancelled) setStep(5); return; }
  if (j.status === 'failed' || j.status === 'error') throw new Error(j.error || 'Slice failed');
  await new Promise(r => setTimeout(r, 1500));
}
throw new Error('Slice timed out');
// catch (not cancelled): Alert.alert('Slicing failed', String(e)); setStep(3);
```
So the wall-clock ceiling is **90 polls × 1.5 s ≈ 135 s**, and any failure drops the user back on **Material** (step 3), not on a dead progress screen. `cancelled` is set in the effect cleanup, i.e. leaving step 4 abandons the poll loop (the server job keeps running).

`upsertLocalPreset` is `GET /api/v1/local-presets/` to find an existing row by name, then `PUT /api/v1/local-presets/{id}` `{setting}` or `POST /api/v1/local-presets/` `{name, preset_type, setting}` — **admin-JWT only** (`POST /api/v1/auth/login` → `access_token`, cached 23 h, one retry on 401/403). One row per name, updated in place, so rows don't accumulate per slice.

`buildProcessDelta` emits **string** values (BambuStudio preset JSON is all strings) with clamps:
```
type:'process', name:<presetName>, from:'User', inherits:<baseQualityName>
wall_loops = String(max(0, round(v)))
sparse_infill_density = `${min(100,max(0,round(v)))}%`
sparse_infill_pattern / top_surface_pattern / support_type / support_style = raw
enable_prime_tower / enable_support = '1' | '0'
prime_tower_width = String(max(2, v))
support_threshold_angle = String(min(90, max(1, round(v))))
```
`buildFilamentDelta` → `{type:'filament', name, from:'User', inherits, filament_flow_ratio: Array(variants).fill(String(clamp(v, 0.5, 2)))}` — H2-series filament keys are per-(extruder,variant) arrays of length 3; single-extruder is 1.
> Comment: per-extruder ARRAY keys (speeds: 5-element arrays on H2-series) are **deliberately excluded** until the app can read base preset content to rewrite whole arrays.

#### 9.8 Step 5 — Review

`<PlateReview client fileId={result?.library_file_id ?? file.id} camToken plateIndex={selectedPlate} onSelectPlate={setSelectedPlate} onViewLayers={…} />` — note it reviews the **newly produced** sliced file when the slice returned one. Below it, an info card (`bg c.accentDim`, `Feather "info"` 17 `c.accent`):
> “Nothing prints yet. Review the plate, then map filament to a tray.”
Footer button label is `Looks good` (accent).

#### 9.9 Step 6 — Map filament

One row per **real** tray from `amsTrayRefs(status)` (`p 13, r 13, bg c.s2`, `opacity 0.4` when empty, `borderWidth slot===globalId ? 1.5 : 0` `c.accent`). Empty trays are non-selectable (`onPress={() => !empty && setSlot(t.globalId)}`).
Label: `multi ? \`${t.unitLabel} · Slot ${t.localId + 1}\` : \`Slot ${t.localId + 1}\`` + `' · '` + (`empty ? 'Empty' : [colorName(normColor(t.trayColor)), t.trayType].filter(Boolean).join(' ')`), where `multi = new Set(trays.map(x => x.unitId)).size > 1`.
Swatch: `<Swatch value={normColor(t.trayColor)} size={28} radius={8} empty={empty} />`.
Footnote: “Tap a slot to map this print's filament.”
> **Gotcha:** “the list was hardcoded to four rows, which on a three-unit machine showed AMS 1 only and labelled them ambiguously.”

`slot` is initialised from live status, avoiding the idle sentinel:
```ts
const trayNow = status?.tray_now;   // 255 == "no active tray"
const [slot, setSlot] = useState(typeof trayNow === 'number' && trayNow >= 0 && trayNow <= 3 ? trayNow : 0);
```

#### 9.10 Step 7 — Start print

Summary card (`r 16, bg c.s2`) of `Row`s:
| Key | Value |
|---|---|
| File | `displayName(file)` |
| Printer | `printer?.name ?? '—'` |
| Material | `` (filament?.name ?? 'As sliced').replace(` ${token}`, '') `` |
| Mapped to | `` `Slot ${slot + 1}` `` |
| Est. time | `` result?.print_time_seconds ? `${Math.round(s/60)} min` : '—' `` |

Warning card (`bg c.heatingDim`, `Feather "thermometer"` 17 `c.heating`):
> “Nozzle and bed heat first (~3 min). You can pause or stop anytime.”

**`start()` — validation then enqueue:**
```ts
if (printerMismatch) {
  Alert.alert('Wrong printer',
    `This file was sliced for ${slicedFor}. Reslice it for ${printer?.name ?? 'this printer'} before printing.`);
  return;
}
if (!trays.some(t => t.globalId === slot && t.trayType)) {
  Alert.alert('Pick a slot', 'Choose which AMS slot to print from first.');
  return;
}
setStarting(true);
// ams_mapping is Bambu's own print-command field: indexed by FILAMENT, valued by GLOBAL tray id
// (Bambuddy decodes it with gid>=254 -> external, >=128 -> HT, else gid//4, gid%4). The old
// `Array(4).fill(-1); mapping[slot] = 0` had index and value SWAPPED, so it debited the wrong
// spool and could not address anything past the first unit at all.
const mapping = [slot];
await client.enqueue({                       // POST /api/v1/queue/
  printer_id: printerId,
  library_file_id: result?.library_file_id ?? file.id,
  use_ams: true,
  ams_mapping: mapping,
  plate_id: selectedPlate,
});
onStarted();                                 // closes the wizard and switches to the Printer tab
// catch: setStarting(false); Alert.alert('Couldn’t start', String(e));
```

#### 9.11 Nested layer viewer

`viewLayers: {fileId, title} | null` renders, as a sibling of the sheet inside the wizard root:
```tsx
{viewLayers && <GcodeViewerOverlay key={viewLayers.fileId}
  src={{ url: client.baseUrl + client.gcodePath(viewLayers.fileId), headers: client.authHeaders() }}
  title={viewLayers.title} plate={profile.plate} onClose={() => setViewLayers(null)} />}
```
At zIndex 80 it covers the wizard (72) without unmounting it, so all wizard state survives.

---

### Port notes

**Structural mapping**

| RN piece | SwiftUI equivalent | Notes / risks |
|---|---|---|
| Absolute overlays + `zIndex` | A `ZStack` in the root view with explicit `.zIndex(70/72/80/84)`, or `.fullScreenCover` for camera/gcode/STL and `.sheet(detents:)` for the bottom sheets | **Do not** use `.fullScreenCover` for the camera: covers unmount their content, which kills PiP. Keep the camera view in the root `ZStack` with `.opacity(0)/.allowsHitTesting(false)` while PiP is up — the exact same trick the RN code uses. |
| `Animated.View entering={SlideInDown.duration(320)}` + `FadeIn(220)` scrim | `.transition(.move(edge:.bottom))` + `.opacity` inside `withAnimation(.easeOut(duration:0.32))` — or a real `.sheet` with `.presentationDetents([.height(x)])`/`.large` | Native sheets give the grabber, backdrop dismiss and keyboard avoidance for free. The Wizard's `height:'92%'` maps to `.presentationDetents([.fraction(0.92)])`. |
| `Tap` | A `ButtonStyle` that scales to `0.955` and dims to `0.62` over 0.09 s in, 0.17 s out | Make it one shared `struct TapButtonStyle: ButtonStyle`; every button in this file uses it. |
| `FadeRise key={step}` | `.transition(.opacity.combined(with:.offset(y:10)))` with `.id(step)` and `.animation(.easeOut(duration:0.3), value: step)` | |
| `RollingNumber` | `Text(...).contentTransition(.numericText())` | Built-in and better; the RN version is a hand-rolled digit ticker. |
| `HeatBar` | `GeometryReader` + `Capsule().frame(width: pct*w)` with `.animation(.easeOut(duration:0.6), value: pct)` | |
| `useSafeAreaInsets()` | `.safeAreaInset` / `GeometryReader.safeAreaInsets` | The wizard header's "no top inset" gotcha disappears with a real sheet. |
| `c` live token object + `useSyncExternalStore` | An `@Observable ThemeStore` in the environment, or an `Asset Catalog` colour set with light/dark variants | Prefer asset-catalog colours; keep the *exact* hex values from §0, including the deliberate hardcoded near-black chrome in fullscreen overlays. |
| `Swatch` | A small `View` with `RoundedRectangle` fill + a 1 pt `swatchRing` stroke; dashed via `StrokeStyle(dash:[3,3])` | Preserve the three states (empty / unknown / known). |
| `Alert.alert(title, body)` | `.alert(title, isPresented:) { } message: { }` | Every literal string is listed above; keep the curly apostrophes (`’`) — they are in the shipped copy. |

**Camera (the hard part is already native)**

`modules/camera-pip/` is Swift already — `CameraPiPView` (an `ExpoView` hosting an `AVSampleBufferDisplayLayer`), `CameraPiPRenderer` (AVKit `AVPictureInPictureController` with `canStartPictureInPictureAutomaticallyFromInline = true`, an `AVAudioSession` keep-alive so the app isn't suspended when backgrounded — otherwise the PiP window freezes on its last frame — plus an interruption observer), `MJPEGStream` (URLSession `timeoutIntervalForRequest = 15` **idle** timeout, `timeoutIntervalForResource = .greatestFiniteMagnitude`, a first-frame wall-clock watchdog, reconnect with short ceiling because the camera self-terminates ~7 s after the last viewer), and `MJPEGParser`. **Port = delete the Expo view wrapper and use `CameraPiPView`/`CameraPiPRenderer` directly from a `UIViewRepresentable`.** The event names (`live`, `error{message,retryable}`, `pipStart`, `pipStop`, `stats{frames,pip}`, `audio{ok,message}`) become a delegate or an `AsyncStream`.

Things that must survive:
- The **three-phase state machine** with the 8 s no-URL fallback and the snapshot fast-fail probe (HTTP-error-only, ignore network errors). In Swift: `URLSession.shared.data(for:)` on the snapshot URL, check `(response as? HTTPURLResponse)?.statusCode`.
- **Never recreate the display layer on token refresh.** In SwiftUI terms: no `.id(streamUrl)` on the representable; push the new URL through `updateUIView` and let the renderer hot-swap.
- The `mjpegHtml` watchdog constants (9 s stall / 2 s retry / 40 s deadline) are the semantic contract for any MJPEG client, including a from-scratch Swift one.
- The 55-minute token refresh and the "token must outlive the overlay while PiP is up" rule (plus the 30 s failsafe that clears `pipActive`).

**Manual landscape** — the RN hack (rotate the whole overlay 90° and swap width/height) exists only because the app is portrait-locked in Info.plist and `expo-screen-orientation` isn't installed. Natively you can do this properly: keep the app portrait-locked but let *this* screen request landscape via `UIWindowScene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape))` + overriding `supportedInterfaceOrientations` on the hosting controller. **But keep the manual toggle button** — the comment records a real reason: a manual toggle still works when the phone's own rotation lock is ON. Also keep the `paddingLeft = insets.top + 16` insight (rotated, the Dynamic Island runs down the left edge) — natively the safe-area insets update on real rotation, so this becomes free.

**WebViews → native (biggest decision)**

Three pages are HTML/JS today: `stlViewerHtml` (raw WebGL), `gcodeViewerHtml` (Canvas2D + an in-page G-code parser), `mjpegHtml` (superseded).
- Easiest path: keep them in `WKWebView` (`WKWebViewConfiguration`, `loadHTMLString(_:baseURL:)` with the **server origin as baseURL** — that CORS constraint is unchanged, Bambuddy sends no CORS headers), and replace `window.ReactNativeWebView.postMessage` with a `WKScriptMessageHandler`. Lowest risk, zero feature loss, ~600 lines of JS reused.
- Better path: **SceneKit/RealityKit or Metal** for the STL viewer — `SCNScene` + `SCNGeometry` from the parsed triangle soup, `SCNCameraController` gives orbit/pan/zoom for free. The STL parser (binary + ASCII, recomputed face normals) is ~40 lines of Swift over `Data`/`withUnsafeBytes` and is trivially unit-testable. Keep the **bounding-sphere-through-the-narrower-axis** camera fit (`dist = rad / tan(min(vHalf, hHalf)) * 1.15`, `vHalf = 0.45`) — a naive `SCNNode.look(at:)` or `.allowsCameraControl` default framing will clip wide models on a portrait phone, which is precisely the bug that was fixed numerically. Keep `MAX_STL_BYTES = 120 MB`, the `Normals` shading mode (the reason it exists is judging texturize depth), and the material colours.
- The G-code viewer is the one to leave in a WebView first: it streams and JIT-parses a **70 MB** file in-page, and the whole reason it works is that the bytes never cross a bridge. A native port must download to disk and parse incrementally (`FileHandle`/`InputStream` line reader on a background queue), then build one `MTLBuffer`/`SCNGeometry` per layer. Budget this as its own project.

**Networking / clients**

`BambuddyClient` and `TexturizeClient` are React-free classes — port them 1:1 to `actor BambuddyClient` with `async` methods and `Codable` models (`src/api/types.ts` is the schema). Preserve:
- `X-API-Key` on everything **except** camera stream/snapshot, library thumbnails, plate thumbnails and print-log thumbnails, which use `?token=<camera stream token>` and 401 on the header.
- The admin-JWT path (`POST /api/v1/auth/login`, cached 23 h, one retry on 401/403) for `local-presets` writes and `maintenance/*/perform`; `requires_2fa` in the login body must throw the 2FA message.
- `apiErrorDetail` — regex `\{"detail"\s*:\s*"([^"]+)"` over the error message. Natively, decode `{detail: String}` from the error body instead and keep a raw fallback.
- Upload: `URLSession.uploadTask` with a multipart body, field name `file`, `URLSessionTaskDelegate.didSendBodyData` for progress. **The whole `expo-file-system` workaround evaporates natively** — that gotcha is RN-only.

**Pure logic to port verbatim (all unit-tested today; port the tests too)**

`presetSelect.ts` (`selectProcess` / `printerPresetNameFor` / `mountedNozzles` / `defaultNozzle` / `pickDefaultQuality` / `supportTwinName`), `filamentMatch.ts` (`modelFilaments` / `matchFilamentPreset` / `catalogFilaments` / `MATERIAL_BASE`), `sliceOverrides.ts` (`buildProcessDelta` / `buildFilamentDelta` / `overrideCount` — note values are **strings**, `'1'`/`'0'`, `'15%'`), `plateReview.ts` (`buildPlateReview` / `fmtSeconds`), `ams/units.ts` (`globalTrayId`, `amsTrayRefs`, `presentAms`), `printers/profile.ts` (`printerProfile`, `slicedForMatchesPrinter`), `libraryBrowse.displayName`, `present.normColor/colorName`, `lanMode.isBlocked`. These encode multiple shipped bug fixes (nozzle-variant leakage, AMS-unit blindness, assignment cross-matching, wrong-printer G-code) and are the highest-value part of the port. Swift `Regex`/`NSRegularExpression` handles all of the name matching; watch out that `escapeRe` + `(?!\S)` lookahead has a direct `Regex` equivalent.

**Things that will be harder or need a different approach**

1. **PiP + a SwiftUI navigation stack.** `AVPictureInPictureController` requires its source layer to live in a visible window. Any presentation API that unmounts (`.sheet`, `.fullScreenCover`, `NavigationStack` pop) will kill the floating window. Plan for a persistent, app-lifetime camera host view in the root `ZStack` from day one — retrofitting it later is painful.
2. **Live-token URL swapping without a layer rebuild.** `UIViewRepresentable.updateUIView` is called freely; guard on `url != previous` exactly as `CameraPiPView.setURL` does today, or you'll restart the stream on every unrelated state change.
3. **The wizard's "presets reload on nozzle change" effect** is a `useEffect` with 5 deps. In SwiftUI use an `@Observable` view model with an explicit `func reloadPresets(nozzle:)` called from `.task(id: nozzle)` — don't try to reproduce dependency-array semantics with `onChange` chains. Same for `defaultedRef` (a one-shot latch — make it a plain `Bool` on the model) and `nozzleTouchedRef`.
4. **The slice poll loop** maps cleanly to `Task { }` + `try await Task.sleep(for: .seconds(1.5))`, cancelled by `.task`'s automatic cancellation when the step view disappears — but note the RN version cancels on *leaving step 4* while the server job keeps running. Preserve that: cancellation must not attempt to cancel the server job.
5. **Texturize preview cleanup.** The "discard on unmount unless committed" rule is a `deinit`/`onDisappear` concern; in Swift, `Task` cancellation is not `deinit`, so put the discard in `onDisappear` **and** clear the stored job id *before* awaiting `commit`'s success, exactly as `previewRef.current = null` does — otherwise a committed file can be deleted by the cleanup.
6. **Theme.** `c` being mutated in place lets every inline style pick up a theme change for free. SwiftUI can't do that; use semantic `Color` assets so light/dark is automatic, and audit the fullscreen overlays, which intentionally stay dark in both themes.
7. **`ScrollView` clipping.** The `maxHeight: Math.max(220, winH - insets.top - insets.bottom - 320)` hack in TexturizeSheet exists because RN doesn't clip overflow. SwiftUI sheets with detents make this a non-issue — put the action buttons in a `.safeAreaInset(edge: .bottom)` and let the form scroll.
8. **Tap-swallowing Pressables.** The nested-`Pressable` bug (texturize preview bubbling a tap to the sheet backdrop) has no analogue in SwiftUI — hit testing doesn't bubble the same way — but keep the intent: the review surface must be modal over the sheet, not a child of a dismiss-on-tap region.

Endpoints referenced in this section (placeholders only; real host/keys live on the home server and are never committed):
`POST /api/v1/printers/camera/stream-token` · `GET /api/v1/printers/{id}/camera/stream?token=&fps=` · `GET /api/v1/printers/{id}/camera/snapshot?token=` · `POST /api/v1/library/files` · `GET /api/v1/library/files/{id}` · `GET /api/v1/library/files/{id}/plates` · `GET /api/v1/library/files/{id}/plate-thumbnail/{n}?token=` · `GET /api/v1/library/files/{id}/gcode` · `POST /api/v1/library/files/{id}/slicer-token` · `GET /api/v1/library/files/{id}/dl/{token}/{name}` · `POST /api/v1/library/files/{id}/slice` · `GET /api/v1/slice-jobs/{id}` · `GET /api/v1/slicer/presets` · `GET /api/v1/local-presets/` · `POST|PUT /api/v1/local-presets/[{id}]` · `GET /api/v1/inventory/assignments?printer_id=` · `POST /api/v1/queue/` · `GET /api/v1/makerworld/status` · `POST /api/v1/makerworld/resolve` · `POST /api/v1/makerworld/import` · `GET /api/v1/makerworld/thumbnail?url=` · `POST /api/v1/auth/login` · texturize sidecar: `GET /health`, `GET /textures`, `GET /textures/{id}/thumb`, `POST /texturize`, `GET /texturize-jobs/{id}`, `GET /texturize-jobs/{id}/result.stl`, `POST /texturize-jobs/{id}/commit`, `DELETE /texturize-jobs/{id}`.
