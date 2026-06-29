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

  if (!isFinite(minX)) {
    minX = 0;
    minY = 0;
    maxX = 256;
    maxY = 256;
  }
  const minZ = zs.length ? zs[0] : 0;
  const maxZ = zs.length ? zs[zs.length - 1] : 1;
  return { layers, supportLayers, layerZ: zs, supportEnabled, hasSupport, bounds: { minX, minY, maxX, maxY, minZ, maxZ } };
}

/** Guard: don't try to render gigantic sliced files on-device. */
export const MAX_GCODE_BYTES = 14_000_000;

/**
 * Build the self-contained HTML for the WebView layer viewer. Parsing already happened in
 * parseGcodeLayers; this only embeds the geometry as JSON and renders it as a ROTATABLE 3D model on a
 * 2D Canvas (orthographic orbit projection — drag to rotate, pinch/wheel to zoom). The layer slider
 * peels the model down by showing only layers 0..N (cumulative), like Bambu Studio. NO external/CDN
 * module import (that's what failed before with "importing layer script failed"), so it works fully
 * offline in WKWebView. Pure (no RN deps) → unit-testable and exercisable headlessly.
 */
export function gcodeViewerHtml(data: GcodeLayers): string {
  const lit = JSON.stringify(data).replace(/</g, '\\u003c');
  return `<!doctype html><html><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no,viewport-fit=cover">
<style>
  html,body{margin:0;height:100%;background:#0A0B0C;overflow:hidden;font-family:-apple-system,system-ui}
  #c{position:absolute;top:0;left:0;right:0;bottom:0;width:100%;height:100%;display:block;touch-action:none}
  #bar{position:absolute;left:0;right:0;bottom:calc(env(safe-area-inset-bottom) + 40px);padding:0 22px;z-index:10}
  #card{background:rgba(22,24,27,0.80);border-radius:16px;padding:13px 16px 16px}
  #top{display:flex;align-items:baseline;justify-content:space-between;margin-bottom:11px}
  #lbl{color:#fff;font:600 12px ui-monospace,Menlo,monospace;letter-spacing:0.5px}
  #hint{color:#7b8187;font:500 10px ui-monospace,Menlo,monospace;letter-spacing:0.3px}
  input[type=range]{-webkit-appearance:none;appearance:none;width:100%;height:12px;border-radius:6px;background:#2A2E33;outline:none}
  input[type=range]::-webkit-slider-thumb{-webkit-appearance:none;width:32px;height:32px;border-radius:50%;background:#2BD4C0;box-shadow:0 1px 6px rgba(0,0,0,0.5)}
  #err{position:absolute;inset:0;display:none;align-items:center;justify-content:center;color:#6b7177;font-size:14px;padding:36px;text-align:center;line-height:1.5}
</style></head>
<body>
<canvas id="c"></canvas>
<div id="bar"><div id="card"><div id="top"><span id="lbl">Rendering…</span><span id="hint">drag to rotate · pinch to zoom</span></div><input id="s" type="range" min="1" max="1" value="1"></div></div>
<div id="err"></div>
<script>
  var post=function(o){window.ReactNativeWebView&&window.ReactNativeWebView.postMessage(JSON.stringify(o));};
  function fail(m){var e=document.getElementById('err');e.style.display='flex';e.textContent='Couldn’t render the preview. '+m;post({type:'error',message:String(m)});}
  window.addEventListener('error',function(e){fail(e.message||'error');});
  try{
    var DATA=${lit}, layers=DATA.layers, sup=DATA.supportLayers||[], zs=DATA.layerZ, b=DATA.bounds;
    var total=layers.length||1;
    var cx=(b.minX+b.maxX)/2, cy=(b.minY+b.maxY)/2, cz=(b.minZ+b.maxZ)/2;
    var bw=(b.maxX-b.minX)||1, bh=(b.maxY-b.minY)||1, bd=(b.maxZ-b.minZ)||1;
    var radius=0.5*Math.sqrt(bw*bw+bh*bh+bd*bd)||1, zspan=(b.maxZ-b.minZ)||1;
    var segTotal=0; for(var k0=0;k0<layers.length;k0++) segTotal+=layers[k0].length>>2;
    var RESERVE=150; // px kept clear at the bottom for the control card

    var cv=document.getElementById('c'), ctx=cv.getContext('2d'), dpr=window.devicePixelRatio||2, W=0,Hh=0;
    var yaw=-0.62, pitch=1.02, zoom=1, cur=total, baseScale=1, ox=0, oy=0, interacting=false;
    function fit(){ baseScale=(Math.min(W,Hh-RESERVE)*0.40)/radius; ox=W/2; oy=(Hh-RESERVE)/2; }
    // teal that brightens with height -> a depth cue that reads as 3D under rotation
    function heightColor(t,top){ if(top) return '#A7FBEF';
      return 'rgb('+Math.round(24+98*t)+','+Math.round(120+125*t)+','+Math.round(108+122*t)+')'; }
    // stroke one layer's flat [x0,y0,x1,y1,...] segments at height z, projected through the orbit camera
    function strokeLayer(L,z,step,cyaw,syaw,cpit,spit,s){
      ctx.beginPath();
      for(var i=0;i<L.length;i+=4*step){
        var ax=L[i]-cx, ay=L[i+1]-cy, bx2=L[i+2]-cx, by2=L[i+3]-cy;
        // orbit: yaw about Z, then tilt — +z must raise the point on screen (was subtracted -> model rendered upside-down/mirrored)
        var x1=ax*cyaw-ay*syaw, y1=(ax*syaw+ay*cyaw)*cpit + z*spit;
        var x2=bx2*cyaw-by2*syaw, y2=(bx2*syaw+by2*cyaw)*cpit + z*spit;
        ctx.moveTo(ox+x1*s, oy-y1*s); ctx.lineTo(ox+x2*s, oy-y2*s);
      }
      ctx.stroke();
    }
    function draw(){
      var s=baseScale*zoom, cyaw=Math.cos(yaw), syaw=Math.sin(yaw), cpit=Math.cos(pitch), spit=Math.sin(pitch);
      var step=(interacting && segTotal>30000)?2:1; // while dragging a dense model, draw every other segment for a smooth framerate; full detail on release
      ctx.clearRect(0,0,W,Hh); ctx.lineWidth=1.0; ctx.lineCap='round';
      for(var k=0;k<cur;k++){
        var z=zs[k]-cz, t=(zs[k]-b.minZ)/zspan, L=layers[k], SL=sup[k];
        if(L&&L.length){ ctx.strokeStyle=heightColor(t,k===cur-1); strokeLayer(L,z,step,cyaw,syaw,cpit,spit,s); }
        if(SL&&SL.length){ ctx.strokeStyle='#E8A23D'; strokeLayer(SL,z,step,cyaw,syaw,cpit,spit,s); } // supports in amber
      }
    }
    var pending=false; function schedule(){ if(pending)return; pending=true; requestAnimationFrame(function(){pending=false;draw();}); }
    function resize(){ W=cv.clientWidth;Hh=cv.clientHeight; cv.width=W*dpr;cv.height=Hh*dpr; ctx.setTransform(dpr,0,0,dpr,0,0); fit(); draw(); }

    function rotate(dx,dy){ yaw+=dx*0.01; pitch=Math.max(0.05,Math.min(Math.PI-0.05,pitch+dy*0.01)); schedule(); }
    function dist(t){ var a=t[0],b2=t[1],dx=a.clientX-b2.clientX,dy=a.clientY-b2.clientY; return Math.sqrt(dx*dx+dy*dy); }
    var g=null; // gesture state
    cv.addEventListener('touchstart',function(e){ if(e.touches.length===2){g={m:'z',d:dist(e.touches),z0:zoom};} else {g={m:'r',x:e.touches[0].clientX,y:e.touches[0].clientY};} interacting=true; },{passive:true});
    cv.addEventListener('touchmove',function(e){ if(!g)return; e.preventDefault();
      if(e.touches.length===2){ if(g.m!=='z')g={m:'z',d:dist(e.touches),z0:zoom}; zoom=Math.max(0.3,Math.min(7,g.z0*(dist(e.touches)/g.d))); schedule(); }
      else if(g.m==='r'){ var nx=e.touches[0].clientX,ny=e.touches[0].clientY; rotate(nx-g.x,ny-g.y); g.x=nx; g.y=ny; } },{passive:false});
    cv.addEventListener('touchend',function(e){ if(e.touches.length===0){g=null;interacting=false;schedule();} else {g={m:'r',x:e.touches[0].clientX,y:e.touches[0].clientY};} },{passive:true});
    // mouse + wheel: trackpad use AND headless testing
    cv.addEventListener('mousedown',function(e){ g={m:'r',x:e.clientX,y:e.clientY}; interacting=true; });
    window.addEventListener('mousemove',function(e){ if(!g||g.m!=='r')return; rotate(e.clientX-g.x,e.clientY-g.y); g.x=e.clientX; g.y=e.clientY; });
    window.addEventListener('mouseup',function(){ if(g&&g.m==='r'){g=null;interacting=false;schedule();} });
    cv.addEventListener('wheel',function(e){ e.preventDefault(); zoom=Math.max(0.3,Math.min(7,zoom*(e.deltaY<0?1.1:0.9))); schedule(); },{passive:false});

    var s2=document.getElementById('s'), lbl=document.getElementById('lbl');
    s2.max=String(total); s2.value=String(total); lbl.textContent='Layer '+total+' / '+total;
    s2.addEventListener('input',function(){ cur=+s2.value; lbl.textContent='Layer '+cur+' / '+total; schedule(); });
    window.addEventListener('resize',resize);
    resize();
    post({type:'ready',total:total});
  }catch(e){fail((e&&e.message)||e);}
</script>
</body></html>`;
}
