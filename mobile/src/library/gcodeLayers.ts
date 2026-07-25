import { GCODE_PARSER_JS } from './gcodeParserSource';
// Pure G-code -> per-layer toolpath parser for the layer viewer.
//
// We parse on the RN/JS side (testable, off the WebView) and hand the WebView only the rendered
// geometry as JSON. Each layer is a flat array of extrusion segments [x0,y0,x1,y1, x0,y0,x1,y1, ...]
// (numbers, not objects) to keep the payload compact for large prints.

// The parser itself now lives in gcodeParserSource.ts and runs INSIDE the WebView — see the note
// there. This module builds the viewer page; it no longer touches G-code text at all, which is why
// MAX_GCODE_BYTES, fitToBudget and the segment budget are gone rather than merely raised.

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
export function gcodeViewerHtml(
  src: { url: string; headers?: Record<string, string> },
  plate: { w: number; d: number } = { w: 256, d: 256 },
): string {
  const urlLit = JSON.stringify(src.url).replace(/</g, '\\u003c');
  // Bambu gcode is plate-origin (0,0 = front-left corner); grow the drawn plate to a 50 mm multiple
  // if the toolpath somehow exceeds the declared footprint (never draw the model off the plate).
  const plateLit = JSON.stringify({ w: plate.w, d: plate.d });
  const hdrLit = JSON.stringify(src.headers ?? {}).replace(/</g, '\\u003c');
  const parserJs = GCODE_PARSER_JS;
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
  #chips{display:flex;gap:8px;margin-top:12px}
  .chip{flex:1;text-align:center;padding:8px 0;border-radius:10px;background:#2A2E33;color:#c8cdd4;font:600 12px -apple-system;border:1px solid transparent}
  .chip.on{background:rgba(43,212,192,0.16);color:#2BD4C0;border-color:rgba(43,212,192,0.35)}
  #err{position:absolute;inset:0;display:none;align-items:center;justify-content:center;color:#6b7177;font-size:14px;padding:36px;text-align:center;line-height:1.5}
</style></head>
<body>
<canvas id="c"></canvas>
<canvas id="cg"></canvas>
<div id="reset">⌂</div>
<div id="bar"><div id="card"><div id="top"><span id="lbl">Rendering…</span><span id="hint">drag rotate · pinch zoom · 2-finger pan · double-tap reset</span></div><input id="s" type="range" min="1" max="1" value="1"><div id="chips"><div class="chip on" data-m="steel">Steel</div><div class="chip" data-m="ivory">Ivory</div><div class="chip" data-m="bg">Light bg</div></div></div></div>
<div id="err"></div>
<script>
  var URL_=${urlLit}, HDRS=${hdrLit};
  var post=function(o){window.ReactNativeWebView&&window.ReactNativeWebView.postMessage(JSON.stringify(o));};
  function fail(m){var e=document.getElementById('err');e.style.display='flex';e.textContent='Couldn’t render the preview. '+m;post({type:'error',message:String(m)});}
  window.addEventListener('error',function(e){fail(e.message||'error');});
  try{
    var PLATE=${plateLit}, KEPT=1, layers=[], sup=[], zs=[], b=null;
${parserJs}
    // Fetch + parse HERE, not in React Native. The old path decoded the G-code in Hermes (no JIT),
    // boxed millions of numbers, JSON-stringified them into this page and re-parsed — three copies of
    // ~70 MB before drawing anything, which is why big prints "couldn't be previewed". JavaScriptCore
    // JITs this loop and the result feeds GPU buffers directly, so there is no size cap any more.
    fetch(URL_, { headers: HDRS })
      .then(function (r) { if (!r.ok) throw new Error('download failed (HTTP ' + r.status + ')'); return r.text(); })
      .then(function (text) {
        var P = parseGcode(text);
        if (!P.layers.length) throw new Error('no printable layers were found in this file');
        boot(P);
      })
      .catch(function (e) { fail((e && e.message) || String(e)); });

    function boot(P){
    layers=P.layers; sup=P.sup; zs=P.zs; b=P.bounds;
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
    var INST=gl.getExtension('ANGLE_instanced_arrays');
    if(!INST) throw new Error('WebGL instancing unavailable');
    function mkShader(ty,src){ var s=gl.createShader(ty); gl.shaderSource(s,src); gl.compileShader(s);
      if(!gl.getShaderParameter(s,gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(s)); return s; }
    var vsrc=
      'attribute vec2 aA;attribute vec2 aB;attribute float aZ;attribute vec2 aES;'+ // aES.x: 0=at A / 1=at B, aES.y: side ±1
      'uniform vec3 uCtr;uniform vec2 uRot;uniform vec2 uPit;uniform float uS;uniform vec2 uOff;'+
      'uniform vec2 uVP;uniform float uHalf;varying float vZ;varying float vSide;varying float vDir;'+
      'vec2 scr(vec3 p){float xr=(p.x-uCtr.x)*uRot.x-(p.y-uCtr.y)*uRot.y;'+
      'float yr=(p.x-uCtr.x)*uRot.y+(p.y-uCtr.y)*uRot.x;'+
      'return vec2(uOff.x+xr*uS, uOff.y-((yr*uPit.x)+(p.z-uCtr.z)*uPit.y)*uS);}'+
      'void main(){vec2 sA=scr(vec3(aA,aZ));vec2 sB=scr(vec3(aB,aZ));vec2 d=sB-sA;float L=max(length(d),0.0001);'+
      'vec2 dir=d/L;vec2 perp=vec2(-dir.y,dir.x);vec2 xy=mix(sA,sB,aES.x);'+
      // extend past the endpoint by half a width: joints between consecutive segments overlap
      // instead of leaving butt-cap notches (the "falling apart" ragged silhouette)
      'xy+=dir*(aES.x*2.0-1.0)*uHalf+perp*aES.y*uHalf;'+
      // wall shading: the extrusion's outward normal in WORLD XY vs a fixed light — walls facing
      // the light read bright, side walls dark, so FORM is visible (height ramp alone is not)
      'vec2 nw=normalize(vec2(-(aB.y-aA.y),(aB.x-aA.x))+vec2(0.0001));'+
      'vDir=abs(dot(nw,vec2(0.5547,0.8321)));'+
      'gl_Position=vec4(xy.x/uVP.x*2.0-1.0, 1.0-xy.y/uVP.y*2.0, 0.0, 1.0);vZ=aZ;vSide=aES.y;}';
    var fsrc=
      'precision mediump float;varying float vZ;varying float vSide;varying float vDir;'+
      'uniform float uMinZ;uniform float uSpanZ;uniform float uCurZ;uniform float uEps;uniform float uIsSup;'+
      'uniform vec3 uColBot;uniform vec3 uColTop;'+
      'void main(){float t=clamp((vZ-uMinZ)/uSpanZ,0.0,1.0);'+
      'vec3 col=uIsSup>0.5?vec3(0.73,0.51,0.18):mix(uColBot,uColTop,t);'+
      'col=mix(col,vec3(1.0),step(abs(vZ-uCurZ),uEps)*0.8);'+
      'float shade=(0.68+0.32*vDir)*(0.90+0.10*(1.0-vSide*vSide));'+ // lambert wall x round cross-section
      'gl_FragColor=vec4(col*shade,1.0);}';
    var prog=gl.createProgram();
    gl.attachShader(prog,mkShader(gl.VERTEX_SHADER,vsrc));
    gl.attachShader(prog,mkShader(gl.FRAGMENT_SHADER,fsrc));
    gl.linkProgram(prog);
    if(!gl.getProgramParameter(prog,gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(prog));
    gl.useProgram(prog);
    var U={}; ['uCtr','uRot','uPit','uS','uOff','uVP','uHalf','uMinZ','uSpanZ','uCurZ','uEps','uIsSup','uColBot','uColTop'].forEach(function(n){U[n]=gl.getUniformLocation(prog,n);});
    // INSTANCED geometry: one shared 4-vertex quad, plus 5 floats PER SEGMENT (x0,y0,x1,y1,z) =
    // 20 bytes. The previous non-instanced layout wrote 4 verts x 8 floats + 6 uint32 indices =
    // 152 bytes/segment, i.e. 172 MB for the user's 1.13M-segment print; this is ~23 MB. That is the
    // whole reason a cap and decimation existed, and why neither is needed now.
    var quad=gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER,quad);
    gl.bufferData(gl.ARRAY_BUFFER,new Float32Array([0,-1, 0,1, 1,-1, 1,1]),gl.STATIC_DRAW);

    function buildGeo(perLayer){
      var segs=0,k;
      for(k=0;k<perLayer.length;k++) segs+=perLayer[k].length>>2;
      var data=new Float32Array(segs*5), n=0, layerEnd=new Uint32Array(perLayer.length), inst=0;
      for(k=0;k<perLayer.length;k++){
        var L=perLayer[k], z=zs[k];
        for(var q=0;q<L.length;q+=4){
          // Degenerate moves become uHalf-sized dots via the cap extension — drop them.
          if(Math.abs(L[q+2]-L[q])<0.05 && Math.abs(L[q+3]-L[q+1])<0.05) continue;
          data[n++]=L[q]; data[n++]=L[q+1]; data[n++]=L[q+2]; data[n++]=L[q+3]; data[n++]=z;
          inst++;
        }
        layerEnd[k]=inst;
      }
      var vbo=gl.createBuffer();
      gl.bindBuffer(gl.ARRAY_BUFFER,vbo);
      gl.bufferData(gl.ARRAY_BUFFER,data.subarray(0,n),gl.STATIC_DRAW);
      return {vbo:vbo, layerEnd:layerEnd, count:inst};
    }
    var geoModel=buildGeo(layers), geoSup=buildGeo(sup);
    var supTotal=geoSup.count;
    var locQ=gl.getAttribLocation(prog,'aES'), locA=gl.getAttribLocation(prog,'aA'),
        locB=gl.getAttribLocation(prog,'aB'), locZ=gl.getAttribLocation(prog,'aZ');
    function bindGeo(gm){
      gl.bindBuffer(gl.ARRAY_BUFFER,quad);
      gl.enableVertexAttribArray(locQ); gl.vertexAttribPointer(locQ,2,gl.FLOAT,false,0,0);
      INST.vertexAttribDivisorANGLE(locQ,0);
      gl.bindBuffer(gl.ARRAY_BUFFER,gm.vbo);
      gl.enableVertexAttribArray(locA); gl.vertexAttribPointer(locA,2,gl.FLOAT,false,20,0);
      gl.enableVertexAttribArray(locB); gl.vertexAttribPointer(locB,2,gl.FLOAT,false,20,8);
      gl.enableVertexAttribArray(locZ); gl.vertexAttribPointer(locZ,1,gl.FLOAT,false,20,16);
      INST.vertexAttribDivisorANGLE(locA,1); INST.vertexAttribDivisorANGLE(locB,1); INST.vertexAttribDivisorANGLE(locZ,1);
    }
    function drawRange(gm,from,to){
      if(to<=from) return;
      bindGeo(gm);
      // Offset the per-instance attributes instead of re-uploading: draws layers [from,to).
      gl.bindBuffer(gl.ARRAY_BUFFER,gm.vbo);
      gl.vertexAttribPointer(locA,2,gl.FLOAT,false,20,from*20);
      gl.vertexAttribPointer(locB,2,gl.FLOAT,false,20,from*20+8);
      gl.vertexAttribPointer(locZ,1,gl.FLOAT,false,20,from*20+16);
      INST.drawArraysInstancedANGLE(gl.TRIANGLE_STRIP,0,4,to-from);
    }
    // Painter's order (bottom layer -> top), NO depth buffer: same-layer crossings just overdraw
    // (a depth test z-fights them into speckle), and pitch is clamped above the horizon so layer
    // order IS depth order — the property the old canvas renderer relied on.
    // Shading palettes (bottom->top height ramp) — chips switch these like the STL viewer's.
    var TINTS={steel:{bot:[0.33,0.38,0.48],top:[0.78,0.81,0.87]},ivory:{bot:[0.52,0.47,0.40],top:[0.93,0.90,0.83]}};
    var tint='steel', lightBg=false;

    function drawPlate(){
      // Surface: subtly lit quad with 10 mm grid, 50 mm majors, edge accents, origin dot.
      var PD=lightBg
        ?{surf:'rgba(255,255,255,0.9)',edge:'rgba(70,78,90,0.45)',g1:'rgba(0,0,0,0.05)',g2:'rgba(0,0,0,0.12)',dot:'rgba(0,0,0,0.45)',sh:0.16}
        :{surf:'rgba(32,36,43,0.92)',edge:'rgba(120,128,140,0.55)',g1:'rgba(255,255,255,0.045)',g2:'rgba(255,255,255,0.10)',dot:'rgba(255,255,255,0.7)',sh:0.42};
      var corners=[[0,0],[pw,0],[pw,pd],[0,pd]];
      ctx.beginPath();
      ctx.moveTo(prX(corners[0][0],corners[0][1]),prY(corners[0][0],corners[0][1],0));
      for(var i=1;i<4;i++) ctx.lineTo(prX(corners[i][0],corners[i][1]),prY(corners[i][0],corners[i][1],0));
      ctx.closePath();
      ctx.fillStyle=PD.surf; ctx.fill();
      ctx.strokeStyle=PD.edge; ctx.lineWidth=1.2; ctx.stroke();
      // grid
      function gridLines(step,style,width){
        ctx.beginPath();
        for(var gx=0;gx<=pw+0.01;gx+=step){ ctx.moveTo(prX(gx,0),prY(gx,0,0)); ctx.lineTo(prX(gx,pd),prY(gx,pd,0)); }
        for(var gy=0;gy<=pd+0.01;gy+=step){ ctx.moveTo(prX(0,gy),prY(0,gy,0)); ctx.lineTo(prX(pw,gy),prY(pw,gy,0)); }
        ctx.strokeStyle=style; ctx.lineWidth=width; ctx.stroke();
      }
      if(S*10>4) gridLines(10,PD.g1,0.7); // hide the fine grid when zoomed way out
      gridLines(50,PD.g2,1.0);
      // X (red-ish) / Y (green-ish) edge accents along the front/left edges + origin dot, like slicers
      ctx.beginPath(); ctx.moveTo(prX(0,0),prY(0,0,0)); ctx.lineTo(prX(pw,0),prY(pw,0,0));
      ctx.strokeStyle='rgba(240,90,90,0.55)'; ctx.lineWidth=2; ctx.stroke();
      ctx.beginPath(); ctx.moveTo(prX(0,0),prY(0,0,0)); ctx.lineTo(prX(0,pd),prY(0,pd,0));
      ctx.strokeStyle='rgba(90,200,120,0.55)'; ctx.lineWidth=2; ctx.stroke();
      ctx.beginPath(); ctx.arc(prX(0,0),prY(0,0,0),3.5,0,6.283); ctx.fillStyle=PD.dot; ctx.fill();
      // soft ground shadow under the model footprint (radius clamped — gradients reject r < 0)
      var sx=prX(cx,cy), sy=prY(cx,cy,0), rx=Math.max(4,Math.max(bw,bh)*0.62*S), ry=rx*Math.abs(cpit)*0.9+4;
      var grad=ctx.createRadialGradient(sx,sy,0,sx,sy,rx);
      grad.addColorStop(0,'rgba(0,0,0,'+PD.sh+')'); grad.addColorStop(1,'rgba(0,0,0,0)');
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
      gl.clearColor(0,0,0,0); gl.clear(gl.COLOR_BUFFER_BIT);
      if(!cur) return;
      gl.uniform3f(U.uCtr,cx,cy,cz); gl.uniform2f(U.uRot,cyaw,syaw); gl.uniform2f(U.uPit,cpit,spit);
      gl.uniform1f(U.uS,S); gl.uniform2f(U.uOff,ox+px,oy+py); gl.uniform2f(U.uVP,W,Hh);
      gl.uniform1f(U.uHalf,Math.max(1.2,0.23*S)); // ~10% over half of 0.42mm: adjacent lines overlap, no hairline gaps
      gl.uniform1f(U.uMinZ,b.minZ); gl.uniform1f(U.uSpanZ,zspan);
      gl.uniform1f(U.uCurZ,zs[cur-1]||0); gl.uniform1f(U.uEps,minGap*0.45);
      var T=TINTS[tint]||TINTS.steel;
      gl.uniform3f(U.uColBot,T.bot[0],T.bot[1],T.bot[2]); gl.uniform3f(U.uColTop,T.top[0],T.top[1],T.top[2]);
      if(!supTotal){
        gl.uniform1f(U.uIsSup,0);
        drawRange(geoModel,0,geoModel.layerEnd[cur-1]||0);
        return;
      }
      // Supports exist: interleave per layer so painter's order stays faithful (a lower support
      // must not paint over a higher model layer).
      var prevM=0,prevS=0;
      for(var k=0;k<cur;k++){
        var em=geoModel.layerEnd[k], es=geoSup.layerEnd[k];
        if(es>prevS){ gl.uniform1f(U.uIsSup,1); drawRange(geoSup,prevS,es); }
        if(em>prevM){ gl.uniform1f(U.uIsSup,0); drawRange(geoModel,prevM,em); }
        prevM=em; prevS=es;
      }
    }
    function draw(){
      if(W<2||Hh<2) return; // layout not settled yet — nothing sane to draw
      cam();
      // background gradient — never a flat black void
      var bg=ctx.createLinearGradient(0,0,0,Hh);
      if(lightBg){ bg.addColorStop(0,'#EDEFF3'); bg.addColorStop(1,'#D9DDE3'); } else { bg.addColorStop(0,'#181B21'); bg.addColorStop(1,'#0C0E11'); }
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

    // Shading/background chips — tint switches the GL palette, bg reflows the whole 2D scene.
    document.querySelectorAll('.chip').forEach(function(ch){ ch.addEventListener('click',function(){
      var m3=ch.getAttribute('data-m');
      if(m3==='bg'){ lightBg=!lightBg; ch.classList.toggle('on',lightBg); }
      else { tint=m3; document.querySelectorAll('.chip').forEach(function(o){ if(o.getAttribute('data-m')!=='bg') o.classList.toggle('on',o===ch); }); }
      schedule();
    }); });

    var s2=document.getElementById('s'), lbl=document.getElementById('lbl');
    function setLbl(){ var zmm=zs[Math.max(0,cur-1)]||0;
      lbl.textContent='Layer '+cur+' / '+total+' · '+zmm.toFixed(1)+'mm'+(KEPT>1?'  ·  1 in '+KEPT:''); }
    s2.max=String(total); s2.value=String(total); setLbl();
    s2.addEventListener('input',function(){ cur=+s2.value; setLbl(); schedule(); });
    window.addEventListener('resize',resize);
    resize();
    post({type:'ready',total:total,hasSupport:P.hasSupport,segments:P.segTotal+P.supTotal});
    }
  }catch(e){fail((e&&e.message)||e);}
</script>
</body></html>`;
}
