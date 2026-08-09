<!-- Generated as the port specification for the native Swift rewrite. -->
# G-code parsing, filament matching, presets, plate review

## library-logic

Eight pure modules under `/Users/max/ai-projects/bambu-app/mobile/src/library/` (+ `libraryBrowse.ts`, in-scope by proximity). Everything here is **React-free and unit-tested**; the two "viewers" are pure *string builders* that emit a fully self-contained HTML page executed in a `react-native-webview` `WebView`. Nothing in this directory does networking — the pages fetch for themselves.

| File | Role |
|---|---|
| `gcodeParserSource.ts` | The G-code → per-layer toolpath parser, shipped **as a JS source string** so it runs inside the WebView (and is executed verbatim by Jest). |
| `gcodeLayers.ts` | `gcodeViewerHtml()` — builds the layer-viewer page (2D Canvas plate/gizmo + WebGL instanced ribbon renderer). |
| `stlViewerHtml.ts` | `stlViewerHtml()` — builds the STL mesh viewer page (raw WebGL, perspective orbit). |
| `filamentMatch.ts` | AMS tray → slicer filament preset matching. |
| `presetSelect.ts` | Quality (process) preset selection per printer model + nozzle; support twins; nozzle detection. |
| `plateReview.ts` | `/plates` + file metadata → one render-ready `PlateReviewVM`. |
| `sliceOverrides.ts` | "Advanced" per-slice parameter deltas as ephemeral local presets. |
| `printerFiles.ts` | SD-card browser predicates: sliced 3MF, playable video, media folders, thumbnails, labels. |
| `libraryBrowse.ts` | Library list filter/search/selection helpers. |

---

### 1. G-code parser — `gcodeParserSource.ts`

Exported as `export const GCODE_PARSER_JS = String.raw\`function parseGcode(text){…}\``. It is textually inlined into the viewer page by `gcodeLayers.ts` (`${parserJs}`), and `__tests__/gcodeParserSource.test.ts` runs `new Function(\`${GCODE_PARSER_JS}; return parseGcode;\`)()` — **one implementation, no second TS copy to drift**.

**Why it lives in the WebView (hard-won, must survive the port):** parsing in React Native meant a ~70 MB G-code string was decoded in Hermes (no JIT), turned into millions of boxed JS numbers, `JSON.stringify`-ed, and re-parsed inside the page — *three full copies before a single triangle was drawn*. That, not the phone, was why big prints "couldn't be previewed". Running in JavaScriptCore, the hot loop JITs and the output feeds GPU buffers directly. Consequence: **there is no size cap, no segment budget, and no decimation** any more (`MAX_GCODE_BYTES`, `fitToBudget`, `SEG_BUDGET`, `skip=` were all deleted; a test asserts they never come back).

**Output layout** (deliberately flat + typed):

```
layers[i] : Float32Array [x0,y0,x1,y1, …]   // model extrusions of layer i — 16 bytes/segment
sup[i]    : Float32Array [x0,y0,x1,y1, …]   // support extrusions of layer i (parallel array, same length)
zs[i]     : number                          // that layer's Z in mm
supportEnabled, hasSupport : boolean
segTotal, supTotal : number                 // = Σ arr.length >> 2
bounds    : {minX,minY,maxX,maxY,minZ,maxZ}
```
1.13 M segments (the owner's "spike ball") ≈ 18 MB here, ~23 MB on the GPU.

**Full algorithm (verbatim):**

```js
function parseGcode(text){
  var EPS=1e-6, total=text.length;
  var layers=[], sup=[], zs=[];
  // Growable typed buffers: doubling beats a 2nd pass over 70 MB of text.
  var seg=new Float32Array(4096), segN=0, sSeg=new Float32Array(1024), sN=0;
  function grow(a,n){ if(n<=a.length) return a; var b=new Float32Array(Math.max(a.length*2,n)); b.set(a); return b; }
  var x=0,y=0,z=0,e=0, absXYZ=true, absE=true, layerZ=null;
  var isSupport=false, supportEnabled=false, hasSupport=false;
  var minX=Infinity,minY=Infinity,maxX=-Infinity,maxY=-Infinity;

  function pushLayer(){
    if(segN||sN){
      layers.push(seg.subarray(0,segN).slice());
      sup.push(sSeg.subarray(0,sN).slice());
      zs.push(layerZ===null?0:layerZ);
      segN=0; sN=0;
    }
  }

  for(var pos=0; pos<total; ){
    var nl=text.indexOf('\n',pos); if(nl<0) nl=total;
    var line=text.slice(pos,nl); pos=nl+1;
    var sc=line.indexOf(';');
    if(sc>=0){
      var comment=line.slice(sc+1);
      var fm=/FEATURE:\s*(.+)/i.exec(comment);
      if(fm){ isSupport=/support/i.test(fm[1]); }
      else { var em=/\benable_support\s*=\s*([01])/i.exec(comment); if(em) supportEnabled=em[1]==='1'; }
      line=line.slice(0,sc);
    }
    line=line.trim(); if(!line) continue;
    var t=line.split(/\s+/), cmd=t[0];
    if(cmd==='G90'){ absXYZ=true; absE=true; continue; }
    if(cmd==='G91'){ absXYZ=false; absE=false; continue; }
    if(cmd==='M82'){ absE=true; continue; }
    if(cmd==='M83'){ absE=false; continue; }
    if(cmd==='G92'){
      for(var gi=1; gi<t.length; gi++) if(t[gi][0]==='E'){ var gv=parseFloat(t[gi].slice(1)); if(!isNaN(gv)) e=gv; }
      continue;
    }
    if(cmd!=='G0'&&cmd!=='G1') continue;

    var nx=x, ny=y, nz=z, ne=e, hasE=false, movedXY=false;
    for(var i=1; i<t.length; i++){
      var p=t[i], v=parseFloat(p.slice(1));
      if(isNaN(v)) continue;
      var a=p[0];
      if(a==='X'){ nx=absXYZ?v:x+v; movedXY=true; }
      else if(a==='Y'){ ny=absXYZ?v:y+v; movedXY=true; }
      else if(a==='Z'){ nz=absXYZ?v:z+v; }
      else if(a==='E'){ ne=absE?v:e+v; hasE=true; }
    }

    if(hasE && ne>e+EPS && movedXY && (nx!==x||ny!==y)){
      if(layerZ===null) layerZ=nz;
      else if(Math.abs(nz-layerZ)>0.001){ pushLayer(); layerZ=nz; }
      if(isSupport){
        sSeg=grow(sSeg,sN+4); sSeg[sN++]=x; sSeg[sN++]=y; sSeg[sN++]=nx; sSeg[sN++]=ny; hasSupport=true;
      } else {
        seg=grow(seg,segN+4); seg[segN++]=x; seg[segN++]=y; seg[segN++]=nx; seg[segN++]=ny;
      }
      if(x<minX)minX=x; if(x>maxX)maxX=x; if(y<minY)minY=y; if(y>maxY)maxY=y;
      if(nx<minX)minX=nx; if(nx>maxX)maxX=nx; if(ny<minY)minY=ny; if(ny>maxY)maxY=ny;
    }
    x=nx; y=ny; z=nz; if(hasE) e=ne;
  }
  pushLayer();
  …
}
```

**State machine** (all mutated per line, reset never):

| Var | Init | Transitions |
|---|---|---|
| `x,y,z` | 0 | updated on **every** `G0/G1` (even travels) after the segment test |
| `e` | 0 | updated only when the move carried an `E` word; also set by `G92 E<v>` |
| `absXYZ` | `true` | `G90`→true, `G91`→false |
| `absE` | `true` | `G90`→true, `G91`→false, `M82`→true, `M83`→false |
| `layerZ` | `null` | first extruding move sets it; an extruding move with `abs(nz-layerZ) > 0.001` **flushes a layer** and adopts `nz` |
| `isSupport` | `false` | any `; FEATURE: <text>` comment sets it to `/support/i.test(text)` |
| `supportEnabled` | `false` | `; … enable_support = 0|1` (only checked when the comment is *not* a FEATURE line) |
| `hasSupport` | `false` | latched true the first time a support segment is emitted |

**Extrusion test (the whole point):** `hasE && ne > e + 1e-6 && movedXY && (nx!==x || ny!==y)`. Retractions/priming (E decrease), pure travels (`G0`, no E), and E-only moves emit nothing.

**Layer splitting only happens on extruding moves** — this is what makes a travel **Z-hop** (`G1 Z1.0` / `G0 …` / `G1 Z0.2`) *not* create a spurious layer. Test-asserted.

**Purge/prime-layer bounds trim** (H2C purges at an elevated Z before layer 1):

```js
var firstReal=0;
while(firstReal<zs.length-1 && zs[firstReal]>zs[firstReal+1]+0.5) firstReal++;
if(firstReal>0){
  minX=Infinity; minY=Infinity; maxX=-Infinity; maxY=-Infinity;
  for(var k=firstReal;k<layers.length;k++){
    var arrs=[layers[k],sup[k]];
    for(var ai=0;ai<2;ai++){ var L=arrs[ai];
      for(var q=0;q<L.length;q+=2){ var vx=L[q], vy=L[q+1];
        if(vx<minX)minX=vx; if(vx>maxX)maxX=vx; if(vy<minY)minY=vy; if(vy>maxY)maxY=vy; } }
  }
}
if(!isFinite(minX)){ minX=0; minY=0; maxX=256; maxY=256; }
var minZ=Infinity, maxZ=-Infinity;
for(var k2=firstReal;k2<zs.length;k2++){ if(zs[k2]<minZ)minZ=zs[k2]; if(zs[k2]>maxZ)maxZ=zs[k2]; }
if(!isFinite(minZ)){ minZ=0; maxZ=1; }
```
A leading layer followed by a **> 0.5 mm drop** is priming: excluded from bounds (so fit/pivot track the real print) but **still rendered**. Verified by a test: purge at Z 5.8 then 0.2/0.4 ⇒ `layers.length === 3`, `bounds.minZ === 0.2`, `bounds.maxX === 20` (the X 280–290 purge line does not skew the fit).

**Other test-locked behaviours:** empty layers are never pushed (`if(segN||sN)`); a final line with no trailing `\n` is parsed; non-print input returns `layers: []` and bounds `{0,0,256,256,0,1}`; buffer doubling preserves order (3000 segments across two doublings, first `[0,0,1,0]`, last `[2999,0,3000,0]`); support and model segments interleave correctly within one layer (`; FEATURE: Support` → sup array, next FEATURE returns to model, and the **segment start point is the previous position regardless of which array it lands in**).

**Sharp edges:** axis letters are matched **case-sensitively uppercase** (`p[0]==='X'`); tokens are whitespace-split so `G1X10Y0` (no spaces) parses as a single token `G1X10Y0` and is skipped — real Bambu output always has spaces. `G91` also flips `absE` (not strictly Marlin-correct, but matches observed output). `parseFloat(p.slice(1))` means `F3000`, `S…`, etc. are read then ignored by the axis `if`-chain.

---

### 2. Layer viewer page — `gcodeLayers.ts`

```ts
export function gcodeViewerHtml(
  src: { url: string; headers?: Record<string, string> },
  plate: { w: number; d: number } = { w: 256, d: 256 },
): string
```
Literals are injected as `JSON.stringify(x).replace(/</g,'\\u003c')` — **XSS/`</script>` escaping is test-asserted** for the URL and headers.

**Plumbing (from `Overlays.tsx` / `TabScreens.tsx`):**
- Library file: `src.url = client.baseUrl + client.gcodePath(fileId)` → `GET /api/v1/library/files/{id}/gcode`.
- SD card file: `client.printerGcodePath(printerId, path)` → `GET /api/v1/printers/{id}/files/gcode?path=<urlencoded>`.
- `src.headers = client.authHeaders()` = `{ 'X-API-Key': … }` (SD-card + library G-code use the API key, **not** the camera `?token=`).
- `plate = printerProfile(printer).plate` — A1 `{w:256,d:256}`, H2C `{w:350,d:320}`, unknown model `{256,256}`.
- **The `WebView` must be mounted with `baseUrl = <origin of src.url> + '/'`** (regex `^(https?:\/\/[^/]+)`, fallback `https://localhost/`): Bambuddy sends **no CORS headers**, so an in-page `fetch` from a `localhost` origin is blocked outright. `originWhitelist={['*']}`, `scrollEnabled={false}`, `javaScriptEnabled`, `domStorageEnabled`.
- RN never fetches the G-code. Overlay chrome: full-screen `#0A0B0C`, `zIndex 80`, chevron-down close pill, and a supports pill fed by the `ready` message (`#E8A23D` on / `#4f555b` off).

**Page → RN messages** (`window.ReactNativeWebView.postMessage(JSON.stringify(o))`):
- `{type:'error', message}` — also renders `#err` with `Couldn’t render the preview. <msg>`.
- `{type:'ready', total, hasSupport, segments}`.

**Load sequence:** `fetch(URL_, {headers: HDRS})` → `if(!r.ok) throw 'download failed (HTTP '+status+')'` → `r.text()` → `parseGcode(text)` → `if(!P.layers.length) throw 'no printable layers were found in this file'` → `boot(P)`. A top-level `try/catch` plus `window.addEventListener('error')` funnel everything into `fail()`.

**Exact page chrome (CSS):**
- `html,body{background:#101216;overflow:hidden;font-family:-apple-system,system-ui}`
- Two stacked full-bleed canvases: `#c` (2D — background, plate, gizmo; `touch-action:none`; receives *all* gestures) and `#cg` (WebGL — the model; `pointer-events:none`).
- `#bar` bottom `calc(env(safe-area-inset-bottom) + 40px)`, padding `0 22px`, `z-index:10`.
- `#card` `rgba(22,24,27,0.82)`, radius 16, padding `13px 16px 16px`, `backdrop-filter: blur(10px)`.
- `#lbl` `#fff 600 12px ui-monospace/Menlo`, ls 0.5px. `#hint` `#7b8187 500 9.5px` mono, ls 0.3px, text `drag rotate · pinch zoom · 2-finger pan · double-tap reset`.
- `#reset` circle 40×40 at right 16, top `calc(env(safe-area-inset-top) + 60px)`, bg `rgba(22,24,27,0.82)`, border `1px solid rgba(255,255,255,0.08)`, color `#c8cdd4`, glyph `⌂`.
- Layer slider: `input[type=range]` height 12, radius 6, track `#2A2E33`; thumb **32×32** circle `#2BD4C0`, `box-shadow 0 1px 6px rgba(0,0,0,0.5)`.
- Chips (`Steel` on / `Ivory` / `Light bg`): flex 1, padding `8px 0`, radius 10, `#2A2E33` / `#c8cdd4`; `.on` → bg `rgba(43,212,192,0.16)`, color `#2BD4C0`, border `rgba(43,212,192,0.35)`.
- `#err` `#6b7177 14px`, padding 36, line-height 1.5.
- Label text: `Layer {cur} / {total} · {z.toFixed(1)}mm` (+ `  ·  1 in {KEPT}` only when `KEPT>1` — `KEPT` is hard-wired to 1 now, a leftover of the deleted decimation path).

**Geometry / camera math:**

```js
var pw=Math.max(PLATE.w, Math.ceil(Math.max(b.maxX,1)/50)*50);   // grow plate in 50 mm steps
var pd=Math.max(PLATE.d, Math.ceil(Math.max(b.maxY,1)/50)*50);   // never draw the model off the plate
var cx=(b.minX+b.maxX)/2, cy=(b.minY+b.maxY)/2, cz=(b.minZ+b.maxZ)*0.4;  // pivot: footprint centre, 40% up
var bw=(b.maxX-b.minX)||1, bh=(b.maxY-b.minY)||1, bd=(b.maxZ-b.minZ)||1;
var radius=0.5*Math.sqrt(bw*bw+bh*bh+bd*bd)||1, zspan=(b.maxZ-b.minZ)||1;
var RESERVE=150;   // px kept clear at the bottom for the control card
function fit(){ baseScale=Math.max((Math.min(W,Hh-RESERVE)*0.33)/radius, 1e-6); ox=W/2; oy=(Hh-RESERVE)/2; }
// orthographic orbit projection (2D canvas + shader use the SAME formula)
function prX(x,y){   return ox+px+((x-cx)*cyaw-(y-cy)*syaw)*S; }
function prY(x,y,z){ return oy+py-((((x-cx)*syaw+(y-cy)*cyaw)*cpit)+(z-cz)*spit)*S; }
// cyaw=cos(yaw), syaw=sin(yaw), cpit=cos(pitch), spit=sin(pitch), S=baseScale*zoom
```
**Gotcha:** the `Math.max(…, 1e-6)` clamp exists because a zero-size canvas on the first layout pass gave a **negative** scale and crashed `createRadialGradient` with `r1 < 0` (caught rendering a real file headlessly). `draw()` also early-returns when `W<2||Hh<2`.

**Interaction state machine** (`g` = active gesture, `null` | `{m:'r',x,y}` | `{m:'zp',d,z0,c,px0,py0}`):

| Event | Behaviour |
|---|---|
| `touchstart` 1 finger | if `Date.now()-lastTap < 280` → `resetView()`, clear `lastTap`, `g=null`, return. Else `lastTap=now`, `g={m:'r',…}`, kill inertia velocities. |
| `touchstart` 2 fingers | `g={m:'zp', d:dist, z0:zoom, c:midpoint, px0:px, py0:py}` |
| `touchmove` 2 fingers | `zoom = clamp(z0*(dist/d), 0.15, 14)`; `px = px0+(mid.x-c.x)`, `py = py0+(mid.y-c.y)` — pinch **and** pan simultaneously. Re-seeds `g` if the gesture upgraded from 1→2 fingers. |
| `touchmove` 1 finger | `vyaw=dx; vpitch=dy; rotate(dx,dy)` where `rotate(dx,dy){ yaw+=dx*0.01; pitch=clamp(pitch+dy*0.01, 0.12, 1.45) }` |
| `touchend` (last finger) | if `|vyaw|>1.5 || |vpitch|>1.5` start inertia |
| `touchend` (fingers remain) | degrade to `{m:'r'}` at the remaining touch |
| inertia frame | `v*=0.90` each frame; stops when `|vyaw|<0.06 && |vpitch|<0.06`, or immediately if `interacting` |
| mouse / wheel / dblclick | trackpad **and headless testing**: drag-rotate, `zoom *= (deltaY<0 ? 1.1 : 0.9)` same clamp, `dblclick → resetView` |

Defaults `DEF={yaw:-0.62, pitch:1.02, zoom:1}`, `px=py=0`. **Pitch clamp `PMIN=0.12 … PMAX=1.45` keeps the camera above the horizon — this is not cosmetic: it is what makes layer order == depth order, which the depth-buffer-free painter's algorithm depends on.** Rendering is `requestAnimationFrame`-coalesced through `schedule()` with a `pending` flag.

**2D layer — plate:**

```
dark:  surf rgba(32,36,43,0.92) | edge rgba(120,128,140,0.55) | minor rgba(255,255,255,0.045)
       major rgba(255,255,255,0.10) | origin dot rgba(255,255,255,0.7) | shadow alpha 0.42
light: surf rgba(255,255,255,0.9) | edge rgba(70,78,90,0.45)   | minor rgba(0,0,0,0.05)
       major rgba(0,0,0,0.12)      | origin dot rgba(0,0,0,0.45) | shadow alpha 0.16
```
Quad `[0,0]→[pw,0]→[pw,pd]→[0,pd]` at Z 0, filled + stroked (lineWidth 1.2). 10 mm minor grid at lineWidth 0.7 **only when `S*10 > 4`** (hidden when zoomed out); 50 mm major always, lineWidth 1.0. X edge accent `rgba(240,90,90,0.55)` along y=0, Y edge accent `rgba(90,200,120,0.55)` along x=0, both lineWidth 2; origin dot radius 3.5. Ground shadow: radial gradient at the model's projected centre, `rx = max(4, max(bw,bh)*0.62*S)`, `ry = rx*|cpit|*0.9 + 4`, drawn with a vertical `ctx.scale(1, max(ry/rx, 0.12))` — **both clamps exist because gradients reject `r < 0`.**

Background gradient (never a flat black void): dark `#181B21 → #0C0E11`, light `#EDEFF3 → #D9DDE3`.

Gizmo: origin `(26, (window.safeTop||44)+30)`, arm length 17 px, axes `X #F05A5A`, `Y #5AC878`, `Z #5A9CF0`, labels `600 9px -apple-system` offset `(+2,+3)`. Note `window.safeTop` is **never assigned by the app** — it always falls back to 44.

**WebGL renderer (the model).** Context `getContext('webgl',{antialias:true,alpha:true,premultipliedAlpha:true})`; hard requirement `ANGLE_instanced_arrays` (throws `WebGL instancing unavailable` otherwise). Toolpaths are camera-facing **ribbons at true extrusion width**, so adjacent perimeters touch and surfaces read as solid plastic rather than a wool of 1 px strokes.

```glsl
// VERTEX  (aES.x: 0=at A / 1=at B ; aES.y: side ±1)
vec2 scr(vec3 p){ float xr=(p.x-uCtr.x)*uRot.x-(p.y-uCtr.y)*uRot.y;
                  float yr=(p.x-uCtr.x)*uRot.y+(p.y-uCtr.y)*uRot.x;
                  return vec2(uOff.x+xr*uS, uOff.y-((yr*uPit.x)+(p.z-uCtr.z)*uPit.y)*uS); }
void main(){ vec2 sA=scr(vec3(aA,aZ)), sB=scr(vec3(aB,aZ));
  vec2 d=sB-sA; float L=max(length(d),0.0001);
  vec2 dir=d/L, perp=vec2(-dir.y,dir.x), xy=mix(sA,sB,aES.x);
  xy += dir*(aES.x*2.0-1.0)*uHalf + perp*aES.y*uHalf;   // extend past endpoints: joints overlap
  vec2 nw=normalize(vec2(-(aB.y-aA.y),(aB.x-aA.x))+vec2(0.0001));
  vDir=abs(dot(nw,vec2(0.5547,0.8321)));                // fixed light in world XY
  gl_Position=vec4(xy.x/uVP.x*2.0-1.0, 1.0-xy.y/uVP.y*2.0, 0.0, 1.0); vZ=aZ; vSide=aES.y; }

// FRAGMENT
float t=clamp((vZ-uMinZ)/uSpanZ,0.0,1.0);
vec3 col = uIsSup>0.5 ? vec3(0.73,0.51,0.18) : mix(uColBot,uColTop,t);
col = mix(col, vec3(1.0), step(abs(vZ-uCurZ), uEps)*0.8);            // current layer → 80% white
float shade=(0.68+0.32*vDir)*(0.90+0.10*(1.0-vSide*vSide));          // lambert wall × round cross-section
gl_FragColor=vec4(col*shade,1.0);
```
The `dir*(aES.x*2-1)*uHalf` cap extension is the fix for **butt-cap notches between consecutive segments** ("the falling-apart ragged silhouette"). The `vDir` wall shading exists because the height ramp alone made form invisible.

Uniform values per frame: `uCtr=(cx,cy,cz)`, `uRot=(cyaw,syaw)`, `uPit=(cpit,spit)`, `uS=S`, `uOff=(ox+px, oy+py)`, `uVP=(W,Hh)` (CSS px — the canvas is `W*dpr`, the shader divides by CSS px, and `gl.viewport` uses the device-pixel size), `uHalf=max(1.2, 0.23*S)` (≈10 % over half of a 0.42 mm extrusion so adjacent lines overlap with no hairline gaps), `uMinZ=b.minZ`, `uSpanZ=zspan`, `uCurZ=zs[cur-1]||0`, `uEps=minGap*0.45`.

`minGap` = smallest positive Z step across `zs` (init 0.2), so the current-layer highlight tolerance adapts to variable layer heights.

Tints: `steel {bot:[0.33,0.38,0.48], top:[0.78,0.81,0.87]}`, `ivory {bot:[0.52,0.47,0.40], top:[0.93,0.90,0.83]}`. Supports amber `[0.73,0.51,0.18]` (matches theme `supports: #E8A23D`).

**Instanced buffer packing (the memory fix):**

```js
function buildGeo(perLayer){
  var segs=0; for(k…) segs+=perLayer[k].length>>2;
  var data=new Float32Array(segs*5), n=0, layerEnd=new Uint32Array(perLayer.length), inst=0;
  for(k…){ var L=perLayer[k], z=zs[k];
    for(var q=0;q<L.length;q+=4){
      if(Math.abs(L[q+2]-L[q])<0.05 && Math.abs(L[q+3]-L[q+1])<0.05) continue;  // drop degenerates:
      data[n++]=L[q]; …; data[n++]=z; inst++;   // the cap extension would turn them into uHalf dots
    }
    layerEnd[k]=inst;   // PREFIX count → draw range for "layers 0..cur"
  }
  … gl.bufferData(…, data.subarray(0,n), gl.STATIC_DRAW); return {vbo, layerEnd, count:inst};
}
```
5 floats **per segment** = 20 bytes, plus one shared 4-vertex quad `Float32Array([0,-1, 0,1, 1,-1, 1,1])` drawn as `TRIANGLE_STRIP`. The previous non-instanced layout was 4 verts × 8 floats + 6 uint32 indices = **152 bytes/segment**, i.e. 172 MB for the 1.13 M-segment print; this is ~23 MB. *That is the entire reason the cap and decimation existed.* Attribute divisors: quad `aES` divisor 0, `aA`/`aB`/`aZ` divisor 1 (stride 20, offsets 0 / 8 / 16).

`drawRange(gm, from, to)` re-points the per-instance attribute pointers at `from*20 (+8,+16)` instead of re-uploading, then `INST.drawArraysInstancedANGLE(gl.TRIANGLE_STRIP, 0, 4, to-from)`.

**Draw order — no depth buffer at all.** With no supports: one range `[0, layerEnd[cur-1]]`. With supports, layers are **interleaved** so a lower support never paints over a higher model layer:

```js
var prevM=0,prevS=0;
for(var k=0;k<cur;k++){
  var em=geoModel.layerEnd[k], es=geoSup.layerEnd[k];
  if(es>prevS){ uIsSup=1; drawRange(geoSup,prevS,es); }
  if(em>prevM){ uIsSup=0; drawRange(geoModel,prevM,em); }
  prevM=em; prevS=es;
}
```
Rationale in the source: same-layer crossings should simply overdraw — a depth test z-fights them into speckle — and the pitch clamp guarantees layer order *is* depth order.

Chips: `bg` toggles `lightBg` (reflows the whole 2D scene); `steel`/`ivory` swap the GL palette and are mutually exclusive (`bg` is excluded from the exclusivity loop).

---

### 3. STL viewer page — `stlViewerHtml.ts`

```ts
export const MAX_STL_BYTES = 120 * 1024 * 1024;   // ~2.4M tris binary — beyond phone-GPU comfort
export function stlViewerHtml(opts: { url: string; name: string; compact?: boolean; headers?: Record<string, string> }): string
```
Same offline constraint (**no CDN scripts/styles/fonts — test-asserted**), same `\\u003c` escaping of `url` and `name`. `compact: true` appends `<style>#bar,#reset{display:none}</style>` — used for the wizard's step-1 inline preview; orbit/pinch/double-tap still work.

**Plumbing (`StlWebView` in `Overlays.tsx`):** two modes.
1. Library file — `client.mintFileDownloadUrl(fileId, name)`: `POST /api/v1/library/files/{id}/slicer-token` → token from `token | slicer_token | download_token | value` → URL `${baseUrl}/api/v1/library/files/{id}/dl/{encodeURIComponent(token)}/{encodeURIComponent(name || 'model-{id}.stl')}`. **The token IS the auth**, so the in-page fetch needs no headers; it is **single-use and short-lived** → minted exactly once per mount (`useEffect` with empty deps and an explicit comment).
2. `direct: {origin, path, headers}` — an arbitrary same-origin path (e.g. a texturize preview held on the sidecar) with optional auth headers.

Either way `WebView source={{html, baseUrl: `${baseUrl}/`}}` so the page fetch is same-origin (no CORS from Bambuddy). Mesh bytes never cross the RN bridge.

**Why raw WebGL and not the layer viewer's Canvas2D:** a textured STL is 100k–1M triangles; painter's-order canvas drawing dies well below that.

**STL parse** (binary + ASCII, face normals **recomputed from geometry** — the stored normals are ignored):

```js
var isAscii=false;
if(u8.length>=6){ var head=''; for(i<min(512,len)) head+=String.fromCharCode(u8[i]);
  if(/^\s*solid/.test(head) && head.indexOf('facet')>=0) isAscii=true; }   // 'solid' alone is not enough
if(!isAscii){
  if(u8.length<84) throw new Error('not an STL');
  var dv=new DataView(buf), n=dv.getUint32(80,true);                       // little-endian tri count
  if(84+n*50>u8.length) throw new Error('truncated STL');
  pos=new Float32Array(n*9);
  for(t…){ var o=84+t*50+12; for(k<9) pos[t*9+k]=dv.getFloat32(o+k*4,true); }  // +12 skips the stored normal
} else {
  var re=/vertex\s+([-\d.eE+]+)\s+([-\d.eE+]+)\s+([-\d.eE+]+)/g …           // TextDecoder + global regex
}
// per face: u=B-A, v=C-A, n=u×v, normalize with (len||1); replicated to all 3 verts; min/max accumulated
```
Size gate is checked **after download**: `if(buf.byteLength > MAXB) throw 'model too large to preview on the phone'`.

**Camera (perspective, Z-up), and its hard-won fit:**

```js
var ct=[(min+max)/2 …], span=max(dx,dy,dz)||1;
var rad=0.5*Math.sqrt(dx*dx+dy*dy+dz*dz)||1;
var asp0=Math.max(0.3, window.innerWidth/Math.max(window.innerHeight,1));
var vHalf=0.45, hHalf=Math.atan(Math.tan(vHalf)*asp0);          // 0.9 rad FOV is VERTICAL
var DEF={yaw:-0.62, pitch:0.5, dist: rad/Math.tan(Math.min(vHalf,hHalf))*1.15};
```
> The initial distance fits the model's bounding **sphere** through the **narrower** screen axis — on a portrait phone the horizontal FOV is ~1/3 of the vertical one, so a height-only fit clipped wide models at the sides (caught numerically before shipping).

Per frame: `eye = [ct.x + d·cos(pitch)·sin(yaw), ct.y − d·cos(pitch)·cos(yaw), ct.z + d·sin(pitch)]`, `tgt = ct + pan`, and `eye` gets the same pan added; `mvp = persp(0.9, cv.width/cv.height, span*0.01, span*20) × lookAt(eye, tgt, [0,0,1])`. Hand-rolled column-major `persp`/`mul`/`lookAt` (16-float arrays) are in the file.

**Gestures:** rotate `v = d·0.006` per px, `pitch` clamped `±1.45`, inertia decay `0.92` with `1e-4` cutoff started on `touchend`; double-tap window **280 ms** resets yaw/pitch/dist/pan; pinch `dist = clamp(dist0·pinch0/max(p,1), span*0.15, span*8)`; two-finger pan scale `s = dist*0.0016`, `panX = px0 − (mx−x0)·s`, `panY = py0 + (my−y0)·s`. All listeners `{passive:false}` with `e.preventDefault()`. `dpr = min(devicePixelRatio||2, 2.5)`.

**Shading:** `gl.enable(DEPTH_TEST)` (unlike the layer viewer), `drawArrays(TRIANGLES, 0, tris*3)`, no index buffer, no back-face culling.

```glsl
if(uMode>0.5){ gl_FragColor=vec4(n*0.5+0.5,1.0); return; }   // Normals mode
float d1=max(dot(n,normalize(vec3( 0.5, 0.4,0.8))),0.0);
float d2=max(dot(n,normalize(vec3(-0.6,-0.3,0.2))),0.0);
float lum=0.22+0.62*d1+0.22*d2;
gl_FragColor=vec4(uColor*lum,1.0);
```
Materials `steel [0.62,0.67,0.76]`, `ivory [0.91,0.89,0.84]`, `teal [0.17,0.83,0.75]` (defined, no chip). Clear color dark `(0.063,0.07,0.086,1)` / light `(0.91,0.92,0.93,1)`; `body.light{background:#E8EAEE}`. Chips: `Steel` (on) / `Ivory` / `Normals` / `Light bg`. **Normals mode doubles as the "see the surface" affordance** — it makes displacement-texture detail pop far better than any single-color shading.

Label: `#lbl` = `NAME` then `NAME + ' · ' + tris.toLocaleString() + ' tris'` after load; hint `drag rotate · pinch zoom · 2-finger pan`; `#load` shows `Loading model…`. Messages: `{type:'loaded',tris}` and `{type:'error',message}`; failure text `Couldn’t show the model. <msg>`. A test compiles the extracted `<script>` body with `new Function` to guarantee syntactic validity.

---

### 4. Filament matching — `filamentMatch.ts`

```ts
const MATERIAL_BASE: Record<string,string> = {
  PLA:'Bambu PLA Basic', 'PLA-S':'Bambu Support For PLA', PETG:'Bambu PETG HF',
  'PETG-CF':'Bambu PETG-CF', ABS:'Bambu ABS', 'ABS-GF':'Bambu ABS-GF', ASA:'Bambu ASA',
  TPU:'Bambu TPU 95A HF', PC:'Bambu PC', 'PA-CF':'Bambu PA-CF', PVA:'Bambu Support For PLA',
};
```

**Nozzle-aware preset pool** — the asymmetry gotcha, verified against the live 189-preset H2C set:

```ts
function modelFilaments(presets, token, nozzle) {          // token e.g. '@BBL A1' / '@BBL H2C'
  const sized = ` ${nozzle} nozzle`;
  return presets.filter((p) => {
    const at = (p.name||'').indexOf(token);
    if (at < 0) return false;
    const after = (p.name||'').slice(at + token.length);
    return after === '' || after === sized;          // bare form OR exactly this size
  });
}
```
> Every material has a bare form, but **size variants exist only where Bambu tuned one** — `Bambu PLA Basic @BBL H2C` ships 0.2/0.6/0.8 and **no** 0.4, while `Bambu PETG-CF @BBL H2C` ships bare **and** 0.4. Hard-coding 0.4 (as this once did) silently stripped every 0.2/0.6/0.8 variant from the pool, so picking 0.6 in the wizard sliced with 0.4-tuned flow / volumetric speed.

`matchFilamentPreset(presets, slicerName, material, token='@BBL A1', nozzle='0.4')`:
1. `byBase(base)` = exact `\`${base} ${token} ${nozzle} nozzle\`` → else exact `\`${base} ${token}\`` → else null. **No `startsWith` fallback** — the pool now admits more than one suffix, so a prefix match could return a different size than asked for.
2. Try `slicerName` (the inventory spool's `slicer_filament_name`) first; if it resolves, return.
3. Else map `material` through `MATERIAL_BASE[material.toUpperCase()] ?? MATERIAL_BASE[material]` and `byBase` that.
4. Else `null`.

`loadedFilaments(trays: AmsTrayRef[], assignments, presets, token, nozzle) → LoadedFilament[]`:
- Skips trays with no `trayType` (empty slot).
- **Assignment lookup matches on BOTH ids:** `assignments.find(a => a.tray_id === t.localId && a.ams_id === t.unitId)` ?? `find(a => a.tray_id === t.localId && a.ams_id == null)`. *Matching `tray_id` alone made AMS 2 slot 0 inherit AMS 1 slot 0's spool — wrong brand, wrong colour, and a wrong slicer preset driving the slice.* The `ams_id == null` second pass keeps legacy records working.
- `colorHex = normColor(t.trayColor) ?? (asg?.spool?.rgba ? normColor(asg.spool.rgba) : null)`. `normColor` (from `dashboard/present.ts`): strips `#`, requires `^[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$`, returns `null` when an 8-digit value ends in alpha `00`, else `'#' + first6.toUpperCase()`.
- `slot` is the **GLOBAL** tray id (`globalTrayId(unitId, localId) = unitId >= 128 ? unitId : unitId*4 + localId`) — what `tray_now`, `ams/load` and `ams_mapping` values all speak. `localId` is kept only for display (`Slot {localId+1}`).
- `isSupport = /support|^PLA-S$|^PVA$/i.test(material)` — the wizard filters these out of the pickable list.
- Takes tray **refs** (unit-aware, via `amsTrayRefs(status)`), not `status.ams[0].tray` — the old shape made every unit after the first invisible (5 of 9 slots on the owner's three-unit H2C).

`CATALOG_MATERIALS` (exact order, drives the "Other filament" list):
`['Bambu PLA Basic','Bambu PLA Matte','Bambu PETG HF','Bambu PETG-CF','Bambu ABS','Bambu ASA','Bambu TPU 95A HF','Bambu Support For PLA']`

`catalogFilaments(presets, token, nozzle='0.4')` resolves each in order with the same sized→bare fallback, skipping misses. **Single source of truth** — `Overlays.tsx` used to rebuild this with its own 0.4-only regex, which is how the nozzle bug lived in two places at once.

---

### 5. Preset selection — `presetSelect.ts`

```ts
export type Preset = { id: string; name: string; source?: string };
export type NozzleSize = '0.2' | '0.4' | '0.6' | '0.8';
export interface PresetsResponse {   // GET /api/v1/slicer/presets
  standard?: { printer?: Preset[]; process?: Preset[]; filament?: Preset[] };
  local?: { process?: Preset[] };  cloud?: { process?: Preset[] };  orca_cloud?: { process?: Preset[] };
}
const escapeRe = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
export const isA1 = (n) => n.includes('A1') && !n.includes('A1M') && !/mini/i.test(n);
export const supportTwinName = (b, token='@BBL A1') =>
  b.includes(` ${token}`) ? b.replace(` ${token}`, ` + Supports ${token}`) : b + ' + Supports';
const isSupportPreset = (n) => /\+ supports|support|tree/i.test(n);
export const printerPresetNameFor = (base, nozzle) => `${base} ${nozzle} nozzle`;
```

`selectProcess(p, token, nozzle='0.4') → { qualities, supportByBase, hasSupportProfile }`:

```ts
const groups = [p?.standard?.process, p?.local?.process, p?.cloud?.process, p?.orca_cloud?.process];
const tokenRe  = new RegExp(`0\\.\\d+mm .*${escapeRe(token)}(?!\\S)`);      // note the (?!\S) — stops "@BBL A1M"
const suffixRe = new RegExp(`${escapeRe(token)} ${escapeRe(nozzle)} nozzle$`);
const proc = groups.flatMap(g => g ?? [])
  .filter(x => nozzle === '0.4'
      ? tokenRe.test(x.name) && !/0\.[268] nozzle/.test(x.name)             // 0.4 presets carry NO suffix
      : suffixRe.test(x.name))
  .filter(x => (seen.has(x.id) ? false : (seen.add(x.id), true)));          // dedupe by id across groups
const qualities = proc.filter(x => !isSupportPreset(x.name));
const twins     = proc.filter(x =>  isSupportPreset(x.name));
for (const base of qualities) { const twin = twins.find(t => t.name === supportTwinName(base.name, token));
  if (twin) supportByBase[base.name] = twin; }
```
**Naming convention (verified live):** 0.4-nozzle process presets carry **no** nozzle suffix; 0.2/0.6/0.8 are suffixed `@BBL <model> <d> nozzle`. Support twins are kept **out** of the quality grid and paired to their base, so the wizard offers a clean "Supports" toggle that swaps in the twin at slice time (`"0.20mm Standard @BBL A1"` → `"0.20mm Standard + Supports @BBL A1"`, provisioned by `deploy/bambuddy/ensure-support-profiles.py`, 0.4 only).

Test-locked: `A1M` and `P1P` never leak into the A1 list; a preset echoed into `standard` and `cloud` with the same id appears once; `null`/`{}` input returns `{qualities:[], supportByBase:{}, hasSupportProfile:false}`.

```ts
mountedNozzles(status)   // from status.nozzles[].nozzle_diameter, String()-compared against
                         // '0.2'|'0.4'|'0.6'|'0.8'; unknown dropped; deduped; extruder order preserved
defaultNozzle(mounted)   // '0.4' if mounted, else mounted[0], else '0.4'  (0.4 = richest family incl. twins)
selectA1Process(p)       // back-compat: selectProcess(p, '@BBL A1')
pickDefaultQuality(qs)   // /0\.20mm Standard/ → name.includes('0.20') → qs[0] → null
```

**Wizard plumbing that consumes this** (`Overlays.tsx`): printer preset resolution is `printerPresets.find(name === printerPresetNameFor(base, nozzle))` ?? `find(name === \`${base} 0.4 nozzle\`)` ?? `find(name === base)`. Nozzle defaults to `defaultNozzle(mountedNozzles(status))` **until the user touches the control** (`nozzleTouchedRef`). Changing the nozzle re-runs the whole preset effect (`token`, `profile.printerPresetBase`, `nozzle` deps).

---

### 6. Plate review — `plateReview.ts`

`buildPlateReview(plates: PlatesResponse|null, meta: FileMetadata|null, plateIndex = 1): PlateReviewVM` — merges `GET /api/v1/library/files/{id}/plates` (per-plate) **over** the file's slicer metadata (`GET /api/v1/library/files/{id}` → `.metadata`), each filling the other's gaps. Both inputs may be null and it still returns a safe VM.

- `num(v)` = `typeof v === 'number' && isFinite(v) ? v : null` (so `0` survives, `null`/`NaN`/strings do not).
- `pickPlate`: `plates.plates.find(p => p.index === plateIndex) ?? plates.plates[0]` — **`plateIndex` is 1-based**; falls back to the first plate when the requested index is absent; `null` when there are no plates.
- Field precedence: `timeSeconds = plate.print_time_seconds ?? meta.print_time_seconds`; `grams = plate.filament_used_grams ?? meta.filament_used_g`; `printer = plates.embedded_printer ?? meta.sliced_for_model`; `process = plates.embedded_process`; `nozzleTemp`/`bedType`/`layers`/`layerHeight` come from `meta` only; `objectCount` from the plate only.
- `heightMm = layers != null && layerHeight != null ? Math.round(layers * layerHeight * 100) / 100 : null` (2 dp).
- `plateIndex: plate?.index ?? plateIndex`, `plateCount: plates?.plates?.length ?? 0`, `isMultiPlate: !!plates?.is_multi_plate`.
- `filamentsFor`: prefer `plate.filaments` → `{slot: f.slot_id, type: f.type ?? '—', color, grams: num(used_grams), meters: num(used_meters)}`; else `meta.filament_slots` → `{slot: s.slot_id, type ?? '—', color, grams: num(s.used_g), meters: null}`; else `[]`.

`fmtSeconds(s)`: `null` / non-finite / `<= 0` → `'—'`; `m = Math.round(s/60)`; `m < 60` → `` `${m} min` ``; else `` `${Math.floor(m/60)} h ${m%60} min` ``.

Related plate assets: `plateThumbUrl(fileId, plateIndex, token)` = `${base}/api/v1/library/files/{id}/plate-thumbnail/{1-based}?token={cameraStreamToken}` — **plate/library thumbnails are gated by the camera *stream* token, not `X-API-Key`**; SD-card variant `printerPlateThumbUrl` uses `?path=` + `authHeaders()`.

---

### 7. Slice overrides — `sliceOverrides.ts`

Bambuddy's slice API takes only preset **references**, but local presets support `inherits` + a delta of keys (Bambuddy resolves the base; the slicer sidecar flattens inheritance too). So **"advanced mode" = upsert an ephemeral local preset carrying just the changed keys, then slice referencing it** — the same mechanism the "+ Supports" twins use, generalized.

Key names and value shapes were **verified against BambuStudio's `PrintConfig.cpp`: preset JSON values are STRINGS** (`"1"`/`"0"` bools, `"15%"` percents). Only scalar-safe keys are exposed — per-extruder **array** keys (speeds: 5-element `(extruder,variant)` arrays on the H2 series) are deliberately excluded until the app can read base preset content to rewrite whole arrays.

```ts
export const INFILL_PATTERNS = ['grid','gyroid','cubic','triangles','honeycomb','lightning','adaptivecubic','crosshatch'] as const;
export const TOP_PATTERNS    = ['monotonic','monotonicline','concentric','alignedrectilinear'] as const;
export const SUPPORT_TYPES   = ['tree(auto)','normal(auto)'] as const;
export const SUPPORT_STYLES  = ['default','snug','tree_slim','tree_strong','tree_hybrid','tree_organic'] as const;
const PROCESS_KEYS = ['wallLoops','infillDensity','infillPattern','topPattern','primeTower',
                      'primeTowerWidth','support','supportType','supportStyle','supportAngle'];
```

`buildProcessDelta(baseQualityName, o, presetName)` → `null` when no process key is set, else:

| Override | Preset key | Encoding |
|---|---|---|
| — | `type` / `name` / `from` / `inherits` | `'process'` / `presetName` / `'User'` / `baseQualityName` |
| `wallLoops` | `wall_loops` | `String(max(0, round(v)))` |
| `infillDensity` | `sparse_infill_density` | `` `${min(100, max(0, round(v)))}%` `` |
| `infillPattern` | `sparse_infill_pattern` | verbatim |
| `topPattern` | `top_surface_pattern` | verbatim |
| `primeTower` | `enable_prime_tower` | `'1'` / `'0'` |
| `primeTowerWidth` | `prime_tower_width` | `String(max(2, v))` (no rounding) |
| `support` | `enable_support` | `'1'` / `'0'` — supersedes the twin swap when set |
| `supportType` | `support_type` | verbatim |
| `supportStyle` | `support_style` | verbatim |
| `supportAngle` | `support_threshold_angle` | `String(min(90, max(1, round(v))))` |

`buildFilamentDelta(baseFilamentName, o, presetName, variants = 3)` → `null` unless `flowRatio` is set, else `{type:'filament', name, from:'User', inherits, filament_flow_ratio: Array(max(1,variants)).fill(String(clamp(v, 0.5, 2)))}`. `variants` = the machine's per-(extruder,variant) array length for filament keys — **H2 series: 3; single-extruder: 1** (caller: `(printer?.nozzle_count ?? 1) > 1 ? 3 : 1`). Same value replicated across, the safe uniform override. Note `filament_flow_ratio` is the only value that is an **array of strings**, everything else is a bare string.

`overrideCount(o)` = count of defined keys among `PROCESS_KEYS + ['flowRatio']` → drives the "n changed" badge.

**Wizard integration + gating** (`Overlays.tsx`, step 4):
```ts
const processPreset = (supports && quality && presets?.supportByBase?.[quality.name]) || quality;
if (client.hasAdminLogin && processPreset && hasProcessOverrides(adv)) {
  const setting = buildProcessDelta(processPreset.name, adv, `Sprout Custom ${token}`)!;
  const id = await client.upsertLocalPreset(`Sprout Custom ${token}`, 'process', setting);
  processRef = { source: 'local', id: String(id) };
}
// same shape for filament with `Sprout Custom Filament ${token}` and variants
const { job_id } = await client.slice(file.id, { printer_preset, process_preset: processRef,
  filament_preset: filamentRef, plate: selectedPlate, bed_type: bedType, export_3mf: true });
```
- **Preset writes are admin-gated server-side (403 on a scoped key)** — the whole Advanced accordion is hidden unless `client.hasAdminLogin`, "so the feature never dead-ends on a 403".
- `upsertLocalPreset` = `GET /api/v1/local-presets/` → `PUT /api/v1/local-presets/{id}` with `{setting}` if a row of that name exists, else `POST /api/v1/local-presets/` with `{name, preset_type, setting}`. **One reusable row per name, updated in place** so rows don't accumulate per slice. Stock presets are never modified.
- Slice: `POST /api/v1/library/files/{id}/slice`; poll `GET /api/v1/slice-jobs/{job_id}` up to **90 times at 1500 ms** (`status === 'completed'` → done; `'failed'|'error'` → throw `j.error`); progress bar is fake (`setSlicePct(p => min(95, p+6))`, 100 on completion), timeout message `'Slice timed out'`.

**UI chip values (the only values reachable from the app):** Wall loops `Preset|2|3|4|6`; Infill density `Preset|10|15|25|40|100`; Infill pattern `Preset` + all 8 `INFILL_PATTERNS`; Top surface `Preset` + `TOP_PATTERNS.slice(0,3)`; Prime tower `Preset|On|Off`; Support style `Preset` + all 6 `SUPPORT_STYLES`; Support angle `Preset|25|30|40|55`; Flow ratio `Preset|0.95|0.98|1.02|1.05`. `undefined` (= "Preset") means *don't emit the key*. Footer copy: *"'Preset' keeps the profile's value. Changes apply to this slice via a reusable 'Sprout Custom' profile on your server — stock presets are never modified."*

**Adjacent wizard rules worth porting with it:**
- 7 steps `File, Printer, Material, Slicing, Review, Map filament, Start print`; a **pre-sliced** file uses only `[1,2,6,7]`. Back from step 5 goes to **3**, not 4 — step 4 is a transient progress screen and landing on it re-slices with unchanged settings.
- `ams_mapping` is **indexed by FILAMENT, valued by GLOBAL tray id** (`mapping = [slot]`). Bambuddy decodes `gid>=254 → external`, `>=128 → HT`, else `gid//4, gid%4`. The old `Array(4).fill(-1); mapping[slot] = 0` had index and value **swapped**, debiting the wrong spool and unable to address anything past the first unit.
- `tray_now`'s idle sentinel is **255** ("no active tray") — never seed the mapping slot with it.
- `POST /api/v1/queue/` body: `{printer_id, library_file_id, use_ams:true, ams_mapping, plate_id}`.
- Wrong-printer guard: `slicedForMatchesPrinter(embedded, profile)` — empty = unknown = allowed; otherwise exact model match or model followed by a nozzle suffix (`"A1 0.4 NOZZLE"`), never a longer model name (`"A1 mini"` must not pass for A1).

---

### 8. Printer SD-card helpers — `printerFiles.ts`

```ts
export const isSliced3mf     = (name) => /\.3mf$/i.test(name);
export const isPlayableVideo = (name) => /\.mp4$/i.test(name);   // iOS AVPlayer: .avi (older firmware) is NOT playable
export const isMediaFolder   = (path) => /^\/(timelapse|ipcam)\/?$/i.test(path);
export function mediaThumbPath(videoPath) {                       // dotted basenames must survive
  const m = videoPath.match(/^(.*)\/([^/]+)\.[^./]+$/);
  return m ? `${m[1]}/thumbnail/${m[2]}.jpg` : videoPath;
}
const MONTHS = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
export function mediaLabel(name) {                                // "Jul 5, 15:16"
  const m = name.match(/(\d{4})-(\d{2})-(\d{2})_(\d{2})-(\d{2})/);
  if (!m) return name;
  const month = MONTHS[Number(m[2]) - 1];
  return month ? `${month} ${Number(m[3])}, ${m[4]}:${m[5]}` : name;
}
```
Verified on the live SD card: `/timelapse/video_x.mp4 → /timelapse/thumbnail/video_x.jpg`, and `/ipcam/ipcam-record.<d>.0.mp4 → /ipcam/thumbnail/ipcam-record.<d>.0.jpg` — **the basename contains dots**, hence `[^./]+$` for the extension rather than a greedy split. `/ipcam` holds raw camera recordings in ~250 MB 10-minute chunks. Media folders render as a thumbnail grid; other folders as a list where the icon is `folder` / `film` (media folder) / `box` (sliced 3MF) / `film` (mp4) / `file`. Thumbnails are fetched with `printerFileDownloadUrl(printerId, mediaThumbPath(path))` + `authHeaders()` (**X-API-Key**, verified live — not the camera token).

---

### 9. Library browse — `libraryBrowse.ts`

```ts
isSlicedFile(f)   = (f.file_type || '').includes('gcode') || !!f.sliced_for_model;
displayName(f)    = decodeURIComponent(f.print_name || f.filename || `file-${f.id}`)  // try/catch → raw on malformed %
filterFiles(files, filter: 'all'|'models'|'sliced', query)
   // type gate, then case-insensitive substring against BOTH displayName and raw filename
   // (so "hexagon" finds "Adapter%20hexagon%20…" either way); empty/whitespace query matches all
safeShareName(n)  = n.replace(/[/\\:]+/g,'-').trim() || 'file'   // display names are user-derived and may
                                                                 // contain separators a File() would misread
toggleSelection(set, id) → new Set                               // immutable bulk-selection toggle
```

---

### Port notes

**Direct 1:1 Swift ports (pure value logic — do these first, they're free):**

| TS | Swift |
|---|---|
| `filamentMatch.ts`, `presetSelect.ts`, `plateReview.ts`, `sliceOverrides.ts`, `printerFiles.ts`, `libraryBrowse.ts` | plain `struct`s + free functions in a `Library` module; `Codable` for `PresetsResponse`/`PlatesResponse`/`FileMetadata`. Keep every function pure and port the existing Jest suites to XCTest **case for case** — they encode the bugs. |
| `Record<string,string>` deltas | `[String: String]` → `JSONSerialization`/`JSONEncoder`. `filament_flow_ratio` must stay `[String]`, everything else a bare `String`. Do **not** let Swift encode numbers as JSON numbers — Bambu presets are string-typed. |
| `num(v)` | `func num(_ v: Double?) -> Double? { v.flatMap { $0.isFinite ? $0 : nil } }`. Decode with `Double?` so JSON `null` and missing both land on `nil`. |
| Regexes | Swift `Regex`/`NSRegularExpression`. Watch three: `(?!\S)` in `tokenRe` (negative lookahead, supported), `/\+ supports|support|tree/i`, and `/0\.[268] nozzle/`. Case sensitivity is load-bearing in the *string equality* paths (`p.name === \`${base} ${token}\``) — use `==`, never `caseInsensitiveCompare`. |
| `MATERIAL_BASE[material.toUpperCase()] ?? MATERIAL_BASE[material]` | keep **both** lookups — some `tray_type` values arrive already-cased (`PETG-CF`) and some don't. |
| `fmtSeconds` | avoid `DateComponentsFormatter` (it localizes and drops the `h`/`min` spelling); reimplement the exact arithmetic. |
| `mediaLabel` | do **not** route through `DateFormatter` — the printer's stamp is local-naive with no timezone; keep the pure string→`"Jul 5, 15:16"` transform. |
| `toggleSelection` | `Set<Int>` in an `@Observable`/`@Published` model; SwiftUI `List(selection:)` if the bulk UI allows. |

**G-code parser → Swift.** This is the one place where a naive port will be *slower* than the JS it replaces.
- Do **not** build `String` lines. Read the body as `Data` (or better, stream it to a file with `URLSession.downloadTask` and `mmap` it) and scan `UnsafeRawBufferPointer<UInt8>` for `\n` / `;` / spaces. Parse floats with `strtof` on a `CChar` cursor, not `Float(String(...))` — the latter is ~20× slower and will dominate.
- Growable buffers: `[Float]` with `reserveCapacity` already amortizes doubling; or allocate `UnsafeMutableBufferPointer<Float>` and hand it straight to `MTLDevice.makeBuffer(bytesNoCopy:)` to avoid one copy.
- Keep the state machine variables and the extrusion predicate **byte for byte** — `hasE && ne > e + 1e-6 && movedXY && (nx != x || ny != y)`, the `0.001` layer-split epsilon, the `> 0.5 mm` purge-drop rule, the "layer splits only on extruding moves" property (that's the Z-hop fix), the empty-layer suppression, and the `{0,0,256,256}` / `{0,1}` fallbacks.
- Run it off the main actor (`Task.detached` / a serial `DispatchQueue`) with a progress callback — a 70 MB file will take seconds even in Swift, and this is the moment to show real progress instead of the current fake bar.
- **Big win:** with a native parser, the whole WebView/CORS/`baseUrl`-must-be-the-server-origin hack disappears. `URLSession` sends `X-API-Key` directly; nothing needs same-origin.

**Layer renderer → Metal.** Port the WebGL path rather than reaching for SceneKit — the look depends on details SceneKit won't give you.
- One `MTKView`. Per-instance buffer: `struct Seg { var a: SIMD2<Float>; var b: SIMD2<Float>; var z: Float }` = 20 bytes, `MemoryLayout.stride` will pad to 20 (check with a `static_assert`-style test; if it pads, use a packed tuple or three separate buffers).
- The unit quad + `drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: to-from, baseInstance: from)` — **`baseInstance` replaces the WebGL pointer-offset trick exactly** and is available on every device this app targets.
- Vertex/fragment shaders translate to MSL almost literally (`mix`→`mix`, `step`→`step`, `normalize`, `clamp`). Keep `uHalf = max(1.2, 0.23 * S)`, the `dir*(aES.x*2-1)*uHalf` cap extension, the `vDir` wall-shading light `(0.5547, 0.8321)`, the support colour `(0.73,0.51,0.18)`, the tints, `uEps = minGap*0.45`, and the 80 % white current-layer mix.
- **No depth attachment.** Set `depthStencilState` to nil / `.always` with no write, and preserve the *exact* per-layer support↔model interleave loop. Pair it with the pitch clamp `0.12…1.45`, which is what makes painter's order correct. If you enable depth "because Metal makes it easy", same-layer crossings z-fight into speckle — the original bug.
- The plate, gizmo, ground shadow and background gradient are the 2D layer: easiest faithful route is a SwiftUI `Canvas` (or `CAGradientLayer` + `CAShapeLayer`) **behind** the `MTKView`, sharing the same `prX/prY` projection functions so the two layers stay locked. Keep the `1e-6` scale clamp and the shadow-radius clamps — `CGGradient` will not crash on a negative radius the way `createRadialGradient` did, but a negative scale still inverts the scene.
- `RESERVE = 150` px, `baseScale = max(min(W, H-150)*0.33/radius, 1e-6)`, `oy = (H-150)/2` — port as-is, then re-tune against the real SwiftUI safe-area insets rather than guessing.

**STL viewer → Metal (or SceneKit with a custom `SCNProgram`).** ModelIO cannot read STL, so the parser ports anyway: binary path (`getUint32(80, littleEndian)`, `84 + t*50 + 12` stride, ignore the stored normal), ASCII detection (`^\s*solid` **and** contains `facet` within the first 512 bytes), recomputed face normals, `120 MB` gate checked after download. Keep the **narrower-axis** fit (`hHalf = atan(tan(0.45) * aspect)`, `dist = rad / tan(min(vHalf, hHalf)) * 1.15`) — a `SCNNode.look(at:)`/`allowsCameraControl` default will clip wide models on a portrait phone, which is precisely the bug that was caught numerically before shipping. Normals mode (`n*0.5+0.5`) and the two-light `0.22 + 0.62·d1 + 0.22·d2` term are trivial in MSL; they are *not* reachable through SceneKit's stock materials.

**Gestures.** `UIPanGestureRecognizer` (rotate, `×0.01` rad/pt for layers, `×0.006` for STL) + `UIPinchGestureRecognizer` + a **two-finger** `UIPanGestureRecognizer` for pan, all with `simultaneousRecognitionWith` — the JS handles pinch+pan in one branch, so the pinch and two-finger-pan recognizers must fire together. Double-tap: `UITapGestureRecognizer(numberOfTapsRequired: 2)` — cleaner than the manual 280 ms `lastTap` bookkeeping, and it removes the "double tap while a rotate is in flight" edge case. Inertia: a `CADisplayLink` decaying `v *= 0.90` (layers) / `0.92` (STL) with the same start/stop thresholds; `UIScrollView`-style deceleration will feel different, so hand-roll it. Clamp pitch in the recognizer, not after.

**Networking.** No change in shape, but every URL and header rule must survive:
- `X-API-Key` for G-code (`/api/v1/library/files/{id}/gcode`, `/api/v1/printers/{id}/files/gcode?path=`), SD-card downloads and plate thumbnails **on the SD-card endpoints**.
- Camera **stream** token in `?token=` for library/plate thumbnails (`/api/v1/library/files/{id}/thumbnail`, `/plate-thumbnail/{n}`) — a `X-API-Key` there 401s.
- `POST /api/v1/library/files/{id}/slicer-token` mints a **single-use, short-lived** download token; mint exactly once per view. In Swift this stops being needed for the viewer at all (just send the API key), but it is still the right endpoint if you ever hand a URL to something that can't set headers (e.g. `QLPreviewController`, `ShareLink`).
- Local-preset writes (`/api/v1/local-presets/`) and settings writes are **admin-only**; keep the "hide the whole Advanced section unless admin creds exist" rule rather than letting it 403.

**Things that will be harder or need a different approach natively:**
1. **Peak memory.** A 1.13 M-segment print is ~18 MB of parsed floats + ~23 MB in the GPU buffer. In JS the intermediate text was garbage-collected; in Swift, `mmap` the downloaded file and never materialize a `String`, or you will hold 70 MB + 18 MB + 23 MB simultaneously and get jetsammed on an older device. Free the parsed CPU arrays as soon as the `MTLBuffer` is built (`.storageModeShared` on Apple silicon avoids a blit).
2. **`Seg` struct alignment.** Metal buffer strides must match the vertex-descriptor layout exactly. Verify `MemoryLayout<Seg>.stride == 20`; if the compiler pads to 24, either accept it (28 MB) or split into three parallel buffers.
3. **Two coordinated render layers.** The current page gets a 2D canvas and a WebGL canvas for free with perfect alignment. Natively, either draw the plate in the same Metal pass (more shader work, guaranteed alignment) or overlay a SwiftUI `Canvas` and be disciplined about sharing one projection function and one `dpr`/`displayScale`. Don't duplicate the projection math.
4. **`toFixed(1)` / `toLocaleString()`.** `String(format: "%.1f")` and a `NumberFormatter` with `.decimal` — but pin the locale so `1,234 tris` doesn't become `1.234` for a European user and confuse a decimal reading.
5. **The `KEPT` label suffix and `window.safeTop`** are dead code (`KEPT` is always 1; `safeTop` is never assigned, always falling back to 44). Drop the first; replace the second with the real `safeAreaInsets.top`.
6. **Support detection depends on slicer comments.** `; FEATURE:` and `; enable_support = 0|1` are BambuStudio/Orca conventions, not G-code. If a file is sliced elsewhere, `hasSupport` is simply false and everything renders as model — keep that graceful degradation rather than throwing.
7. **Chips/light-bg mode.** In the page these are DOM toggles; natively they become `@State` on the SwiftUI overlay driving uniform values. Trivial — but note the layer viewer's `bg` chip reflows the **2D** layer only, while `steel`/`ivory` swap **GL uniforms**; keeping them as one enum with two consumers is cleaner than mirroring the DOM's odd split.
8. **The `originWhitelist`/`baseUrl` CORS workaround, the `\u003c` script-injection escaping, and the `postMessage` bridge all disappear** — that is ~40 % of the surface area of these two files gone. Budget the saved effort for the parser performance work, which is where the native rewrite actually has to earn its keep.
