// Pure G-code -> per-layer toolpath parser for the layer viewer.
//
// We parse on the RN/JS side (testable, off the WebView) and hand the WebView only the rendered
// geometry as JSON. Each layer is a flat array of extrusion segments [x0,y0,x1,y1, x0,y0,x1,y1, ...]
// (numbers, not objects) to keep the payload compact for large prints.

export interface GcodeLayers {
  /** One entry per layer: flat [x0,y0,x1,y1,...] of extruding XY moves (the model itself). */
  layers: number[][];
  /** Support-structure extrusion per layer — index-aligned with `layers` (empty where none). */
  supportLayers: number[][];
  /** Z height (mm) of each layer — index-aligned with `layers`. Drives the 3D stacking. */
  layerZ: number[];
  /** Whether the slicer's support setting was on (`; enable_support = 1` in the G-code). */
  supportEnabled: boolean;
  /** Whether any actual support toolpath was generated (the honest "this print has supports"). */
  hasSupport: boolean;
  /** XYZ extent of all extrusion, for fit-to-view. Always finite. */
  bounds: { minX: number; minY: number; maxX: number; maxY: number; minZ: number; maxZ: number };
}

const EPS = 1e-6;

/**
 * Parse G0/G1 moves into layers, splitting a new layer at the first *extruding* move whose Z differs
 * from the current layer's Z. Keying layers off extrusion Z (not raw Z changes) makes this robust to
 * travel Z-hops, which would otherwise fragment layers. Honors G90/G91 (XYZ abs/rel), M82/M83 and
 * G90/G91 (E abs/rel), and G92 E (extruder reset). Comments (`;`) are stripped.
 */
export function parseGcodeLayers(gcode: string): GcodeLayers {
  const lines = gcode.split('\n');
  const layers: number[][] = [];
  const supportLayers: number[][] = [];
  const zs: number[] = [];
  let seg: number[] = [];
  let supSeg: number[] = [];
  let x = 0,
    y = 0,
    z = 0,
    e = 0;
  let absXYZ = true,
    absE = true;
  let layerZ: number | null = null;
  let feature = ''; // current `; FEATURE: ...` block — slicers tag support toolpaths this way
  let isSupport = false;
  let supportEnabled = false;
  let hasSupport = false;
  let minX = Infinity,
    minY = Infinity,
    maxX = -Infinity,
    maxY = -Infinity;

  // Close the current layer, recording the Z it was extruded at (index-aligned with `layers`).
  const pushLayer = () => {
    if (seg.length || supSeg.length) {
      layers.push(seg);
      supportLayers.push(supSeg);
      zs.push(layerZ ?? 0);
      seg = [];
      supSeg = [];
    }
  };

  for (let li = 0; li < lines.length; li++) {
    let line = lines[li];
    const sc = line.indexOf(';');
    if (sc >= 0) {
      // Read slicer metadata from the comment before stripping it: which feature we're printing, and
      // whether supports were enabled at all.
      const comment = line.slice(sc + 1);
      const fm = /FEATURE:\s*(.+)/i.exec(comment);
      if (fm) {
        feature = fm[1].trim();
        isSupport = /support/i.test(feature);
      } else {
        const em = /\benable_support\s*=\s*([01])/i.exec(comment);
        if (em) supportEnabled = em[1] === '1';
      }
      line = line.slice(0, sc);
    }
    line = line.trim();
    if (!line) continue;
    const t = line.split(/\s+/);
    const cmd = t[0];

    if (cmd === 'G90') {
      absXYZ = true;
      absE = true;
      continue;
    }
    if (cmd === 'G91') {
      absXYZ = false;
      absE = false;
      continue;
    }
    if (cmd === 'M82') {
      absE = true;
      continue;
    }
    if (cmd === 'M83') {
      absE = false;
      continue;
    }
    if (cmd === 'G92') {
      for (let i = 1; i < t.length; i++) {
        if (t[i][0] === 'E') {
          const v = parseFloat(t[i].slice(1));
          if (!isNaN(v)) e = v;
        }
      }
      continue;
    }
    if (cmd !== 'G0' && cmd !== 'G1') continue;

    let nx = x,
      ny = y,
      nz = z,
      ne = e,
      hasE = false,
      movedXY = false;
    for (let i = 1; i < t.length; i++) {
      const p = t[i];
      const v = parseFloat(p.slice(1));
      if (isNaN(v)) continue;
      const a = p[0];
      if (a === 'X') {
        nx = absXYZ ? v : x + v;
        movedXY = true;
      } else if (a === 'Y') {
        ny = absXYZ ? v : y + v;
        movedXY = true;
      } else if (a === 'Z') {
        nz = absXYZ ? v : z + v;
      } else if (a === 'E') {
        ne = absE ? v : e + v;
        hasE = true;
      }
    }

    const extruding = hasE && ne > e + EPS && movedXY && (nx !== x || ny !== y);
    if (extruding) {
      if (layerZ === null) layerZ = nz;
      else if (Math.abs(nz - layerZ) > 0.001) {
        pushLayer();
        layerZ = nz;
      }
      if (isSupport) {
        supSeg.push(x, y, nx, ny);
        hasSupport = true;
      } else {
        seg.push(x, y, nx, ny);
      }
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
      if (nx < minX) minX = nx;
      if (nx > maxX) maxX = nx;
      if (ny < minY) minY = ny;
      if (ny > maxY) maxY = ny;
    }

    x = nx;
    y = ny;
    z = nz;
    if (hasE) e = ne;
  }
  pushLayer();

  // Leading PRIME/PURGE layers: the H2C purges at an ELEVATED Z (observed: 5.8 mm, X≈290) before
  // the first real 0.2 mm layer. A leading layer followed by a >0.5 mm DROP in Z is priming, not
  // model — exclude those from the bounds so fit/pivot/shadow/height-ramp track the actual print
  // (they still render). Without this the viewer centers between model and purge line and reports
  // minZ as the purge height, which made the model look like it floats above the plate.
  let firstReal = 0;
  while (firstReal < zs.length - 1 && zs[firstReal] > zs[firstReal + 1] + 0.5) firstReal++;
  if (firstReal > 0) {
    minX = Infinity;
    minY = Infinity;
    maxX = -Infinity;
    maxY = -Infinity;
    for (let k = firstReal; k < layers.length; k++) {
      for (const L of [layers[k], supportLayers[k]]) {
        for (let i = 0; i < L.length; i += 2) {
          const vx = L[i],
            vy = L[i + 1];
          if (vx < minX) minX = vx;
          if (vx > maxX) maxX = vx;
          if (vy < minY) minY = vy;
          if (vy > maxY) maxY = vy;
        }
      }
    }
  }
  if (!isFinite(minX)) {
    minX = 0;
    minY = 0;
    maxX = 256;
    maxY = 256;
  }
  // True extremes over the REAL layers — never assume zs is sorted (the purge layer isn't).
  let minZ = Infinity,
    maxZ = -Infinity;
  for (let k = firstReal; k < zs.length; k++) {
    if (zs[k] < minZ) minZ = zs[k];
    if (zs[k] > maxZ) maxZ = zs[k];
  }
  if (!isFinite(minZ)) {
    minZ = 0;
    maxZ = 1;
  }
  return { layers, supportLayers, layerZ: zs, supportEnabled, hasSupport, bounds: { minX, minY, maxX, maxY, minZ, maxZ } };
}

/** Guard: don't try to render gigantic sliced files on-device. */
export const MAX_GCODE_BYTES = 14_000_000;

/**
 * Build the self-contained HTML for the WebView layer viewer. Parsing already happened in
 * parseGcodeLayers; this only embeds the geometry as JSON and renders it as a ROTATABLE 3D scene on
 * a 2D Canvas (orthographic orbit projection). Usability essentials (all user-reported gaps):
 * - a real BUILD PLATE (10 mm grid, bolder 50 mm lines, X/Y edge accents, origin dot) so the model
 *   has a ground reference and never floats in a black void;
 * - a soft ground shadow under the model + a subtle background gradient (not flat black);
 * - a neutral steel height ramp (bottom dim -> top bright) with the CURRENT layer in white and
 *   supports in amber — no more all-green;
 * - navigation: 1-finger rotate (with inertia), 2-finger pinch zoom + PAN, double-tap to reset,
 *   pitch clamped above the horizon (also keeps painter's-order z sorting correct);
 * - an XYZ axis gizmo and a layer label that includes the real Z height.
 * The `plate` argument is the machine's physical bed footprint in mm (from printerProfile). NO
 * external/CDN imports — fully offline in WKWebView. Pure (no RN deps) → unit-testable.
 */
export function gcodeViewerHtml(data: GcodeLayers, plate: { w: number; d: number } = { w: 256, d: 256 }): string {
  const lit = JSON.stringify(data).replace(/</g, '\\u003c');
  // Bambu gcode is plate-origin (0,0 = front-left corner); grow the drawn plate to a 50 mm multiple
  // if the toolpath somehow exceeds the declared footprint (never draw the model off the plate).
  const plateLit = JSON.stringify({ w: plate.w, d: plate.d });
  return `<!doctype html><html><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no,viewport-fit=cover">
<style>
  html,body{margin:0;height:100%;background:#101216;overflow:hidden;font-family:-apple-system,system-ui}
  #c{position:absolute;top:0;left:0;right:0;bottom:0;width:100%;height:100%;display:block;touch-action:none}
  #cg{position:absolute;top:0;left:0;right:0;bottom:0;width:100%;height:100%;display:block;pointer-events:none}
  #bar{position:absolute;left:0;right:0;bottom:calc(env(safe-area-inset-bottom) + 40px);padding:0 22px;z-index:10}
  #card{background:rgba(22,24,27,0.82);border-radius:16px;padding:13px 16px 16px;backdrop-filter:blur(10px);-webkit-backdrop-filter:blur(10px)}
  #top{display:flex;align-items:baseline;justify-content:space-between;margin-bottom:11px}
  #lbl{color:#fff;font:600 12px ui-monospace,Menlo,monospace;letter-spacing:0.5px}
  #hint{color:#7b8187;font:500 9.5px ui-monospace,Menlo,monospace;letter-spacing:0.3px}
  #reset{position:absolute;right:16px;top:calc(env(safe-area-inset-top) + 60px);width:40px;height:40px;border-radius:20px;background:rgba(22,24,27,0.82);border:1px solid rgba(255,255,255,0.08);color:#c8cdd4;font:600 16px -apple-system;display:flex;align-items:center;justify-content:center;z-index:10}
  input[type=range]{-webkit-appearance:none;appearance:none;width:100%;height:12px;border-radius:6px;background:#2A2E33;outline:none}
  input[type=range]::-webkit-slider-thumb{-webkit-appearance:none;width:32px;height:32px;border-radius:50%;background:#2BD4C0;box-shadow:0 1px 6px rgba(0,0,0,0.5)}
  #err{position:absolute;inset:0;display:none;align-items:center;justify-content:center;color:#6b7177;font-size:14px;padding:36px;text-align:center;line-height:1.5}
</style></head>
<body>
<canvas id="c"></canvas>
<canvas id="cg"></canvas>
<div id="reset">⌂</div>
<div id="bar"><div id="card"><div id="top"><span id="lbl">Rendering…</span><span id="hint">drag rotate · pinch zoom · 2-finger pan · double-tap reset</span></div><input id="s" type="range" min="1" max="1" value="1"></div></div>
<div id="err"></div>
<script>
  var post=function(o){window.ReactNativeWebView&&window.ReactNativeWebView.postMessage(JSON.stringify(o));};
  function fail(m){var e=document.getElementById('err');e.style.display='flex';e.textContent='Couldn’t render the preview. '+m;post({type:'error',message:String(m)});}
  window.addEventListener('error',function(e){fail(e.message||'error');});
  try{
    var DATA=${lit}, PLATE=${plateLit}, layers=DATA.layers, sup=DATA.supportLayers||[], zs=DATA.layerZ, b=DATA.bounds;
    var total=layers.length||1;
    // Grow the plate to cover stray toolpaths, in 50 mm steps.
    var pw=Math.max(PLATE.w, Math.ceil(Math.max(b.maxX,1)/50)*50), pd=Math.max(PLATE.d, Math.ceil(Math.max(b.maxY,1)/50)*50);
    // Orbit pivot: the MODEL's footprint centre, ~40% up its height — rotation pivots around the
    // print (not the plate middle), and tall prints stay vertically centred instead of running off
    // the top of the screen.
    var cx=(b.minX+b.maxX)/2, cy=(b.minY+b.maxY)/2, cz=(b.minZ+b.maxZ)*0.4;
    var bw=(b.maxX-b.minX)||1, bh=(b.maxY-b.minY)||1, bd=(b.maxZ-b.minZ)||1;
    var radius=0.5*Math.sqrt(bw*bw+bh*bh+bd*bd)||1, zspan=(b.maxZ-b.minZ)||1;
    var segTotal=0; for(var k0=0;k0<layers.length;k0++) segTotal+=layers[k0].length>>2;
    var RESERVE=150; // px kept clear at the bottom for the control card

    var cv=document.getElementById('c'), ctx=cv.getContext('2d'), dpr=window.devicePixelRatio||2, W=0,Hh=0;
    var DEF={yaw:-0.62,pitch:1.02,zoom:1};
    var yaw=DEF.yaw, pitch=DEF.pitch, zoom=DEF.zoom, cur=total, baseScale=1, ox=0, oy=0, px=0, py=0, interacting=false;
    var vyaw=0, vpitch=0, inertiaOn=false; // rotate inertia
    // Clamp positive: a zero-size canvas on the first layout pass would give a NEGATIVE scale and
    // crash createRadialGradient ("r1 < 0" — caught rendering a real file headlessly).
    function fit(){ baseScale=Math.max((Math.min(W,Hh-RESERVE)*0.33)/radius, 1e-6); ox=W/2; oy=(Hh-RESERVE)/2; }
    function resetView(){ yaw=DEF.yaw; pitch=DEF.pitch; zoom=DEF.zoom; px=0; py=0; vyaw=0; vpitch=0; schedule(); }

    // Project world (x,y,z in mm, plate-origin) -> screen px through the orbit camera.
    var cyaw=1,syaw=0,cpit=0,spit=1,S=1;
    function cam(){ cyaw=Math.cos(yaw); syaw=Math.sin(yaw); cpit=Math.cos(pitch); spit=Math.sin(pitch); S=baseScale*zoom; }
    function prX(x,y){ return ox+px+((x-cx)*cyaw-(y-cy)*syaw)*S; }
    function prY(x,y,z){ return oy+py-((((x-cx)*syaw+(y-cy)*cyaw)*cpit)+(z-cz)*spit)*S; }

    // ---- WebGL extrusion renderer (the model itself) ----
    // Toolpaths render as camera-facing ribbons at TRUE extrusion width (0.42mm * zoom): adjacent
    // perimeter lines touch, so surfaces read as solid plastic instead of a wool of 1px strokes
    // (the old Canvas2D look). Ribbon cross-section shading (bright centre, dark edges) gives the
    // printed-lines look; height ramp (steel, in-shader) + white current layer + amber supports kept.
    var cvg=document.getElementById('cg');
    var gl=cvg.getContext('webgl',{antialias:true,alpha:true,premultipliedAlpha:true});
    if(!gl) throw new Error('WebGL unavailable');
    if(!gl.getExtension('OES_element_index_uint')) throw new Error('WebGL uint indices unavailable');
    function mkShader(ty,src){ var s=gl.createShader(ty); gl.shaderSource(s,src); gl.compileShader(s);
      if(!gl.getShaderParameter(s,gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(s)); return s; }
    var vsrc=
      'attribute vec3 aA;attribute vec3 aB;attribute vec2 aES;'+ // aES.x: 0=at A / 1=at B, aES.y: side ±1
      'uniform vec3 uCtr;uniform vec2 uRot;uniform vec2 uPit;uniform float uS;uniform vec2 uOff;'+
      'uniform vec2 uVP;uniform float uHalf;uniform float uDepthR;varying float vZ;varying float vSide;'+
      'vec3 scr(vec3 p){float xr=(p.x-uCtr.x)*uRot.x-(p.y-uCtr.y)*uRot.y;'+
      'float yr=(p.x-uCtr.x)*uRot.y+(p.y-uCtr.y)*uRot.x;'+
      'return vec3(uOff.x+xr*uS, uOff.y-((yr*uPit.x)+(p.z-uCtr.z)*uPit.y)*uS, (yr*uPit.y-(p.z-uCtr.z)*uPit.x)/uDepthR);}'+
      'void main(){vec3 sA=scr(aA);vec3 sB=scr(aB);vec2 d=sB.xy-sA.xy;float L=max(length(d),0.0001);'+
      'vec2 perp=vec2(-d.y,d.x)/L;vec3 s=mix(sA,sB,aES.x);vec2 xy=s.xy+perp*aES.y*uHalf;'+
      'gl_Position=vec4(xy.x/uVP.x*2.0-1.0, 1.0-xy.y/uVP.y*2.0, s.z, 1.0);vZ=aA.z;vSide=aES.y;}';
    var fsrc=
      'precision mediump float;varying float vZ;varying float vSide;'+
      'uniform float uMinZ;uniform float uSpanZ;uniform float uCurZ;uniform float uEps;uniform float uIsSup;'+
      'void main(){float t=clamp((vZ-uMinZ)/uSpanZ,0.0,1.0);'+
      'vec3 col=uIsSup>0.5?vec3(0.73,0.51,0.18):mix(vec3(0.33,0.38,0.48),vec3(0.87,0.89,0.94),t);'+
      'col=mix(col,vec3(1.0),step(abs(vZ-uCurZ),uEps)*0.85);'+
      'float shade=0.58+0.42*(1.0-vSide*vSide);'+ // round-line cross-section: bright centre, dark edges
      'gl_FragColor=vec4(col*shade,1.0);}';
    var prog=gl.createProgram();
    gl.attachShader(prog,mkShader(gl.VERTEX_SHADER,vsrc));
    gl.attachShader(prog,mkShader(gl.FRAGMENT_SHADER,fsrc));
    gl.linkProgram(prog);
    if(!gl.getProgramParameter(prog,gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(prog));
    gl.useProgram(prog);
    var U={}; ['uCtr','uRot','uPit','uS','uOff','uVP','uHalf','uDepthR','uMinZ','uSpanZ','uCurZ','uEps','uIsSup'].forEach(function(n){U[n]=gl.getUniformLocation(prog,n);});
    var locA=gl.getAttribLocation(prog,'aA'), locB=gl.getAttribLocation(prog,'aB'), locES=gl.getAttribLocation(prog,'aES');

    // Geometry: 4 verts/segment (A-1,A+1,B-1,B+1), 8 floats each [ax,ay,az, bx,by,bz, end,side];
    // 6 uint32 indices/segment. Ordered by layer, so "draw up to layer N" is one prefix drawElements
    // per buffer. Dense models decimate every 2nd segment (visual density is unaffected at phone size).
    var SEG_BUDGET=800000, skip=segTotal>SEG_BUDGET?2:1;
    function buildGeo(perLayer){
      var segs=0,k,Lr;
      for(k=0;k<perLayer.length;k++){ Lr=perLayer[k]; if(Lr) segs+=Math.ceil((Lr.length>>2)/skip); }
      var vb=new Float32Array(segs*4*8), ib=new Uint32Array(segs*6), idxEnd=new Uint32Array(perLayer.length);
      var v=0,i2=0,seg=0;
      for(k=0;k<perLayer.length;k++){
        Lr=perLayer[k]||[]; var z=zs[k];
        for(var q=0;q<Lr.length;q+=4*skip){
          var ax=Lr[q],ay=Lr[q+1],bx2=Lr[q+2],by2=Lr[q+3];
          for(var e2=0;e2<4;e2++){ // (end,side): (0,-1)(0,1)(1,-1)(1,1)
            vb[v++]=ax;vb[v++]=ay;vb[v++]=z; vb[v++]=bx2;vb[v++]=by2;vb[v++]=z;
            vb[v++]=e2>>1; vb[v++]=(e2&1)?1:-1;
          }
          var b0=seg*4;
          ib[i2++]=b0;ib[i2++]=b0+1;ib[i2++]=b0+2; ib[i2++]=b0+2;ib[i2++]=b0+1;ib[i2++]=b0+3;
          seg++;
        }
        idxEnd[k]=i2;
      }
      var vbo=gl.createBuffer(); gl.bindBuffer(gl.ARRAY_BUFFER,vbo); gl.bufferData(gl.ARRAY_BUFFER,vb,gl.STATIC_DRAW);
      var ibo=gl.createBuffer(); gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER,ibo); gl.bufferData(gl.ELEMENT_ARRAY_BUFFER,ib,gl.STATIC_DRAW);
      return {vbo:vbo,ibo:ibo,idxEnd:idxEnd};
    }
    var geoModel=buildGeo(layers), geoSup=buildGeo(sup);
    var diag=Math.sqrt(bw*bw+bh*bh+bd*bd)||1;
    function bindGeo(gm){
      gl.bindBuffer(gl.ARRAY_BUFFER,gm.vbo); gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER,gm.ibo);
      gl.enableVertexAttribArray(locA); gl.vertexAttribPointer(locA,3,gl.FLOAT,false,32,0);
      gl.enableVertexAttribArray(locB); gl.vertexAttribPointer(locB,3,gl.FLOAT,false,32,12);
      gl.enableVertexAttribArray(locES); gl.vertexAttribPointer(locES,2,gl.FLOAT,false,32,24);
    }
    gl.enable(gl.DEPTH_TEST); gl.depthFunc(gl.LEQUAL);

    function drawPlate(){
      // Surface: subtly lit quad with 10 mm grid, 50 mm majors, edge accents, origin dot.
      var corners=[[0,0],[pw,0],[pw,pd],[0,pd]];
      ctx.beginPath();
      ctx.moveTo(prX(corners[0][0],corners[0][1]),prY(corners[0][0],corners[0][1],0));
      for(var i=1;i<4;i++) ctx.lineTo(prX(corners[i][0],corners[i][1]),prY(corners[i][0],corners[i][1],0));
      ctx.closePath();
      ctx.fillStyle='rgba(32,36,43,0.92)'; ctx.fill();
      ctx.strokeStyle='rgba(120,128,140,0.55)'; ctx.lineWidth=1.2; ctx.stroke();
      // grid
      function gridLines(step,style,width){
        ctx.beginPath();
        for(var gx=0;gx<=pw+0.01;gx+=step){ ctx.moveTo(prX(gx,0),prY(gx,0,0)); ctx.lineTo(prX(gx,pd),prY(gx,pd,0)); }
        for(var gy=0;gy<=pd+0.01;gy+=step){ ctx.moveTo(prX(0,gy),prY(0,gy,0)); ctx.lineTo(prX(pw,gy),prY(pw,gy,0)); }
        ctx.strokeStyle=style; ctx.lineWidth=width; ctx.stroke();
      }
      if(S*10>4) gridLines(10,'rgba(255,255,255,0.045)',0.7); // hide the fine grid when zoomed way out
      gridLines(50,'rgba(255,255,255,0.10)',1.0);
      // X (red-ish) / Y (green-ish) edge accents along the front/left edges + origin dot, like slicers
      ctx.beginPath(); ctx.moveTo(prX(0,0),prY(0,0,0)); ctx.lineTo(prX(pw,0),prY(pw,0,0));
      ctx.strokeStyle='rgba(240,90,90,0.55)'; ctx.lineWidth=2; ctx.stroke();
      ctx.beginPath(); ctx.moveTo(prX(0,0),prY(0,0,0)); ctx.lineTo(prX(0,pd),prY(0,pd,0));
      ctx.strokeStyle='rgba(90,200,120,0.55)'; ctx.lineWidth=2; ctx.stroke();
      ctx.beginPath(); ctx.arc(prX(0,0),prY(0,0,0),3.5,0,6.283); ctx.fillStyle='rgba(255,255,255,0.7)'; ctx.fill();
      // soft ground shadow under the model footprint (radius clamped — gradients reject r < 0)
      var sx=prX(cx,cy), sy=prY(cx,cy,0), rx=Math.max(4,Math.max(bw,bh)*0.62*S), ry=rx*Math.abs(cpit)*0.9+4;
      var grad=ctx.createRadialGradient(sx,sy,0,sx,sy,rx);
      grad.addColorStop(0,'rgba(0,0,0,0.42)'); grad.addColorStop(1,'rgba(0,0,0,0)');
      ctx.save(); ctx.translate(sx,sy); ctx.scale(1,Math.max(ry/rx,0.12)); ctx.translate(-sx,-sy);
      ctx.beginPath(); ctx.arc(sx,sy,rx,0,6.283); ctx.fillStyle=grad; ctx.fill(); ctx.restore();
    }

    function drawGizmo(){
      // Small XYZ triad, top-left — orientation at a glance.
      var gx=26, gy=(window.safeTop||44)+30, L=17;
      function axis(dx,dy,dz,color,label){
        var ex=gx+((dx)*cyaw-(dy)*syaw)*L, ey=gy-((((dx)*syaw+(dy)*cyaw)*cpit)+(dz)*spit)*L;
        ctx.beginPath(); ctx.moveTo(gx,gy); ctx.lineTo(ex,ey); ctx.strokeStyle=color; ctx.lineWidth=2; ctx.stroke();
        ctx.fillStyle=color; ctx.font='600 9px -apple-system'; ctx.fillText(label,ex+2,ey+3);
      }
      axis(1,0,0,'#F05A5A','X'); axis(0,1,0,'#5AC878','Y'); axis(0,0,1,'#5A9CF0','Z');
    }

    // Smallest layer step drives the current-layer highlight tolerance (layer heights vary per print).
    var minGap=0.2; for(var gi=1;gi<zs.length;gi++){ var dg=zs[gi]-zs[gi-1]; if(dg>1e-4&&dg<minGap) minGap=dg; }
    function drawGL(){
      gl.viewport(0,0,cvg.width,cvg.height);
      gl.clearColor(0,0,0,0); gl.clear(gl.COLOR_BUFFER_BIT|gl.DEPTH_BUFFER_BIT);
      if(!cur) return;
      gl.uniform3f(U.uCtr,cx,cy,cz); gl.uniform2f(U.uRot,cyaw,syaw); gl.uniform2f(U.uPit,cpit,spit);
      gl.uniform1f(U.uS,S); gl.uniform2f(U.uOff,ox+px,oy+py); gl.uniform2f(U.uVP,W,Hh);
      gl.uniform1f(U.uHalf,Math.max(0.75,0.21*S)); // half of 0.42mm extrusion width, min 1.5px total
      gl.uniform1f(U.uDepthR,diag*1.5);
      gl.uniform1f(U.uMinZ,b.minZ); gl.uniform1f(U.uSpanZ,zspan);
      gl.uniform1f(U.uCurZ,zs[cur-1]||0); gl.uniform1f(U.uEps,minGap*0.45);
      var n1=geoModel.idxEnd[cur-1]||0;
      if(n1){ gl.uniform1f(U.uIsSup,0); bindGeo(geoModel); gl.drawElements(gl.TRIANGLES,n1,gl.UNSIGNED_INT,0); }
      var n2=geoSup.idxEnd[cur-1]||0;
      if(n2){ gl.uniform1f(U.uIsSup,1); bindGeo(geoSup); gl.drawElements(gl.TRIANGLES,n2,gl.UNSIGNED_INT,0); }
    }
    function draw(){
      if(W<2||Hh<2) return; // layout not settled yet — nothing sane to draw
      cam();
      // background gradient — never a flat black void
      var bg=ctx.createLinearGradient(0,0,0,Hh);
      bg.addColorStop(0,'#181B21'); bg.addColorStop(1,'#0C0E11');
      ctx.fillStyle=bg; ctx.fillRect(0,0,W,Hh);
      drawPlate();
      drawGizmo();
      drawGL();
    }
    var pending=false; function schedule(){ if(pending)return; pending=true; requestAnimationFrame(function(){pending=false;draw();}); }
    function resize(){ W=cv.clientWidth;Hh=cv.clientHeight; cv.width=W*dpr;cv.height=Hh*dpr; cvg.width=W*dpr;cvg.height=Hh*dpr; ctx.setTransform(dpr,0,0,dpr,0,0); fit(); draw(); }

    var PMIN=0.12, PMAX=1.45; // stay above the horizon: keeps orientation obvious AND painter's z-order valid
    function rotate(dx,dy){ yaw+=dx*0.01; pitch=Math.max(PMIN,Math.min(PMAX,pitch+dy*0.01)); schedule(); }
    function inertia(){ if(interacting){inertiaOn=false;return;}
      vyaw*=0.90; vpitch*=0.90;
      if(Math.abs(vyaw)<0.06&&Math.abs(vpitch)<0.06){inertiaOn=false;return;}
      rotate(vyaw,vpitch); requestAnimationFrame(inertia); }
    function dist(t){ var a=t[0],b2=t[1],dx=a.clientX-b2.clientX,dy=a.clientY-b2.clientY; return Math.sqrt(dx*dx+dy*dy); }
    function mid(t){ return {x:(t[0].clientX+t[1].clientX)/2, y:(t[0].clientY+t[1].clientY)/2}; }
    var g=null, lastTap=0;
    cv.addEventListener('touchstart',function(e){
      if(e.touches.length===2){ g={m:'zp',d:dist(e.touches),z0:zoom,c:mid(e.touches),px0:px,py0:py}; }
      else {
        var now=Date.now();
        if(now-lastTap<280){ resetView(); lastTap=0; g=null; return; }
        lastTap=now;
        g={m:'r',x:e.touches[0].clientX,y:e.touches[0].clientY}; vyaw=0; vpitch=0;
      }
      interacting=true; inertiaOn=false;
    },{passive:true});
    cv.addEventListener('touchmove',function(e){ if(!g)return; e.preventDefault();
      if(e.touches.length===2){
        if(g.m!=='zp')g={m:'zp',d:dist(e.touches),z0:zoom,c:mid(e.touches),px0:px,py0:py};
        var m2=mid(e.touches);
        zoom=Math.max(0.15,Math.min(14,g.z0*(dist(e.touches)/g.d)));
        px=g.px0+(m2.x-g.c.x); py=g.py0+(m2.y-g.c.y); // two-finger PAN rides along with the pinch
        schedule();
      } else if(g.m==='r'){
        var nx=e.touches[0].clientX,ny=e.touches[0].clientY, dx=nx-g.x, dy=ny-g.y;
        vyaw=dx; vpitch=dy; rotate(dx,dy); g.x=nx; g.y=ny;
      } },{passive:false});
    cv.addEventListener('touchend',function(e){
      if(e.touches.length===0){
        g=null; interacting=false;
        if(Math.abs(vyaw)>1.5||Math.abs(vpitch)>1.5){ inertiaOn=true; requestAnimationFrame(inertia); }
        schedule();
      } else { g={m:'r',x:e.touches[0].clientX,y:e.touches[0].clientY}; }
    },{passive:true});
    // mouse + wheel: trackpad use AND headless testing
    cv.addEventListener('mousedown',function(e){ g={m:'r',x:e.clientX,y:e.clientY}; interacting=true; });
    window.addEventListener('mousemove',function(e){ if(!g||g.m!=='r')return; rotate(e.clientX-g.x,e.clientY-g.y); g.x=e.clientX; g.y=e.clientY; });
    window.addEventListener('mouseup',function(){ if(g&&g.m==='r'){g=null;interacting=false;schedule();} });
    cv.addEventListener('dblclick',resetView);
    cv.addEventListener('wheel',function(e){ e.preventDefault(); zoom=Math.max(0.15,Math.min(14,zoom*(e.deltaY<0?1.1:0.9))); schedule(); },{passive:false});
    document.getElementById('reset').addEventListener('click',resetView);

    var s2=document.getElementById('s'), lbl=document.getElementById('lbl');
    function setLbl(){ var zmm=zs[Math.max(0,cur-1)]||0; lbl.textContent='Layer '+cur+' / '+total+' · '+zmm.toFixed(1)+'mm'; }
    s2.max=String(total); s2.value=String(total); setLbl();
    s2.addEventListener('input',function(){ cur=+s2.value; setLbl(); schedule(); });
    window.addEventListener('resize',resize);
    resize();
    post({type:'ready',total:total});
  }catch(e){fail((e&&e.message)||e);}
</script>
</body></html>`;
}
