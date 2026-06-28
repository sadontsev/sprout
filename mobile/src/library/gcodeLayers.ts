// Pure G-code -> per-layer toolpath parser for the layer viewer.
//
// We parse on the RN/JS side (testable, off the WebView) and hand the WebView only the rendered
// geometry as JSON. Each layer is a flat array of extrusion segments [x0,y0,x1,y1, x0,y0,x1,y1, ...]
// (numbers, not objects) to keep the payload compact for large prints.

export interface GcodeLayers {
  /** One entry per layer: flat [x0,y0,x1,y1,...] of extruding XY moves. */
  layers: number[][];
  /** XY extent of all extrusion, for fit-to-view. Always finite. */
  bounds: { minX: number; minY: number; maxX: number; maxY: number };
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
  let seg: number[] = [];
  let x = 0,
    y = 0,
    z = 0,
    e = 0;
  let absXYZ = true,
    absE = true;
  let layerZ: number | null = null;
  let minX = Infinity,
    minY = Infinity,
    maxX = -Infinity,
    maxY = -Infinity;

  const pushLayer = () => {
    if (seg.length) {
      layers.push(seg);
      seg = [];
    }
  };

  for (let li = 0; li < lines.length; li++) {
    let line = lines[li];
    const sc = line.indexOf(';');
    if (sc >= 0) line = line.slice(0, sc);
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
      seg.push(x, y, nx, ny);
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
  return { layers, bounds: { minX, minY, maxX, maxY } };
}

/** Guard: don't try to render gigantic sliced files on-device. */
export const MAX_GCODE_BYTES = 14_000_000;

/**
 * Build the self-contained HTML for the WebView layer viewer. Parsing already happened in
 * parseGcodeLayers; this only embeds the geometry as JSON and renders the picked layer on a 2D
 * Canvas — NO external/CDN module import (that's what failed before with "importing layer script
 * failed"), so it works fully offline in WKWebView. Pure (no RN deps) so it's unit-testable and can
 * be exercised headlessly.
 */
export function gcodeViewerHtml(data: GcodeLayers): string {
  const lit = JSON.stringify(data).replace(/</g, '\\u003c');
  return `<!doctype html><html><head>
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no,viewport-fit=cover">
<style>
  html,body{margin:0;height:100%;background:#0A0B0C;overflow:hidden;font-family:-apple-system,system-ui}
  #c{position:absolute;top:0;left:0;right:0;bottom:0;width:100%;height:100%;display:block}
  #bar{position:absolute;left:0;right:0;bottom:calc(env(safe-area-inset-bottom) + 40px);padding:0 22px;z-index:10}
  #card{background:rgba(22,24,27,0.78);border-radius:16px;padding:14px 16px 16px}
  #lbl{color:#fff;font:600 12px ui-monospace,Menlo,monospace;text-align:center;margin-bottom:12px;letter-spacing:0.5px}
  input[type=range]{-webkit-appearance:none;appearance:none;width:100%;height:12px;border-radius:6px;background:#2A2E33;outline:none}
  input[type=range]::-webkit-slider-thumb{-webkit-appearance:none;width:32px;height:32px;border-radius:50%;background:#2BD4C0;box-shadow:0 1px 6px rgba(0,0,0,0.5)}
  #err{position:absolute;inset:0;display:none;align-items:center;justify-content:center;color:#6b7177;font-size:14px;padding:36px;text-align:center;line-height:1.5}
</style></head>
<body>
<canvas id="c"></canvas>
<div id="bar"><div id="card"><div id="lbl">Rendering…</div><input id="s" type="range" min="1" max="1" value="1"></div></div>
<div id="err"></div>
<script>
  var post=function(o){window.ReactNativeWebView&&window.ReactNativeWebView.postMessage(JSON.stringify(o));};
  function fail(m){var e=document.getElementById('err');e.style.display='flex';e.textContent='Couldn’t render the preview. '+m;post({type:'error',message:String(m)});}
  window.addEventListener('error',function(e){fail(e.message||'error');});
  try{
    var DATA=${lit}, layers=DATA.layers, b=DATA.bounds;
    var total=layers.length||1, minX=b.minX,minY=b.minY;
    var bw=(b.maxX-b.minX)||1, bh=(b.maxY-b.minY)||1;
    var RESERVE=130; // px kept clear at the bottom for the control card
    var cv=document.getElementById('c'), ctx=cv.getContext('2d'), dpr=window.devicePixelRatio||2, W=0,Hh=0;
    var base=document.createElement('canvas'), bctx=base.getContext('2d'), s=1,ox=0,oy=0,cur=total;
    function fit(){
      var pad=34; s=Math.min((W-2*pad)/bw,(Hh-2*pad-RESERVE)/bh);
      ox=(W-bw*s)/2; oy=(Hh-RESERVE-bh*s)/2;
    }
    function tx(v){return ox+(v-minX)*s;}
    function ty(v){return Hh-RESERVE-(oy+(v-minY)*s);}
    function stroke(c,L,w){ c.lineWidth=w; c.strokeStyle=(c===bctx)?'rgba(124,245,230,0.07)':'#2BD4C0'; c.lineCap='round'; c.beginPath();
      for(var i=0;i<L.length;i+=4){ c.moveTo(tx(L[i]),ty(L[i+1])); c.lineTo(tx(L[i+2]),ty(L[i+3])); } c.stroke(); }
    function buildBase(){ // faint full-model silhouette, drawn once per layout -> cheap scrubbing
      base.width=cv.width; base.height=cv.height; bctx.setTransform(dpr,0,0,dpr,0,0); bctx.clearRect(0,0,W,Hh);
      for(var k=0;k<layers.length;k++) stroke(bctx,layers[k],1);
    }
    function draw(idx){ ctx.clearRect(0,0,W,Hh); ctx.drawImage(base,0,0,W,Hh); stroke(ctx,layers[idx-1]||[],1.7); }
    function resize(){ W=cv.clientWidth;Hh=cv.clientHeight; cv.width=W*dpr;cv.height=Hh*dpr; ctx.setTransform(dpr,0,0,dpr,0,0); fit(); buildBase(); draw(cur); }
    var s2=document.getElementById('s'), lbl=document.getElementById('lbl');
    s2.max=String(total); s2.value=String(total); lbl.textContent='Layer '+total+' / '+total;
    var pending=false;
    s2.addEventListener('input',function(){ cur=+s2.value; lbl.textContent='Layer '+cur+' / '+total; if(pending)return; pending=true; requestAnimationFrame(function(){pending=false;draw(cur);}); });
    window.addEventListener('resize',resize);
    resize();
    post({type:'ready',total:total});
  }catch(e){fail((e&&e.message)||e);}
</script>
</body></html>`;
}
