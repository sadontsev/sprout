// Pure builder for the interactive STL viewer page (WebView). Renders a solid mesh with raw WebGL —
// NO external/CDN imports, same offline-WKWebView constraint as gcodeViewerHtml. The page fetches the
// model itself from a tokenized same-origin URL (mount the WebView with baseUrl = the Bambuddy
// origin), so no bytes cross the RN bridge and no CORS/auth headers are needed in-page.
//
// Why WebGL and not the gcode viewer's Canvas2D: a textured STL is 100k-1M triangles; painter's-order
// canvas drawing dies well below that, while flat-shaded WebGL is comfortable.
//
// Material modes double as the "see the surface" affordance: Normals mode colors each face by its
// orientation, which makes displacement texture detail pop far better than any single-color shading.

export const MAX_STL_BYTES = 120 * 1024 * 1024; // ~2.4M tris binary — beyond phone-GPU comfort

export function stlViewerHtml(opts: { url: string; name: string; compact?: boolean }): string {
  const urlLit = JSON.stringify(opts.url).replace(/</g, '\\u003c');
  const nameLit = JSON.stringify(opts.name).replace(/</g, '\\u003c');
  // compact: inline embed (e.g. the wizard's step-1 preview) — hide the control card / reset button
  // and pin a minimal label; interaction (orbit/pinch/double-tap) still works.
  const compactCss = opts.compact ? '<style>#bar,#reset{display:none}</style>' : '';
  return `<!doctype html><html><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no,viewport-fit=cover">
<style>
  html,body{margin:0;height:100%;background:#101216;overflow:hidden;font-family:-apple-system,system-ui}
  body.light{background:#E8EAEE}
  #c{position:absolute;top:0;left:0;right:0;bottom:0;width:100%;height:100%;display:block;touch-action:none}
  #bar{position:absolute;left:0;right:0;bottom:calc(env(safe-area-inset-bottom) + 40px);padding:0 22px;z-index:10}
  #card{background:rgba(22,24,27,0.82);border-radius:16px;padding:12px 14px;backdrop-filter:blur(10px);-webkit-backdrop-filter:blur(10px)}
  #top{display:flex;align-items:baseline;justify-content:space-between;margin-bottom:10px}
  #lbl{color:#fff;font:600 12px ui-monospace,Menlo,monospace;letter-spacing:0.5px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:60%}
  #hint{color:#7b8187;font:500 9.5px ui-monospace,Menlo,monospace;letter-spacing:0.3px}
  #chips{display:flex;gap:8px}
  .chip{flex:1;text-align:center;padding:9px 0;border-radius:10px;background:#2A2E33;color:#c8cdd4;font:600 12px -apple-system;border:1px solid transparent}
  .chip.on{background:rgba(43,212,192,0.16);color:#2BD4C0;border-color:rgba(43,212,192,0.35)}
  #reset{position:absolute;right:16px;top:calc(env(safe-area-inset-top) + 60px);width:40px;height:40px;border-radius:20px;background:rgba(22,24,27,0.82);border:1px solid rgba(255,255,255,0.08);color:#c8cdd4;font:600 16px -apple-system;display:flex;align-items:center;justify-content:center;z-index:10}
  #load{position:absolute;inset:0;display:flex;align-items:center;justify-content:center;color:#7b8187;font:500 13px ui-monospace,Menlo,monospace}
  #err{position:absolute;inset:0;display:none;align-items:center;justify-content:center;color:#6b7177;font-size:14px;padding:36px;text-align:center;line-height:1.5}
</style>${compactCss}</head>
<body>
<canvas id="c"></canvas>
<div id="reset">⌂</div>
<div id="load">Loading model…</div>
<div id="bar"><div id="card">
  <div id="top"><span id="lbl"></span><span id="hint">drag rotate · pinch zoom · 2-finger pan</span></div>
  <div id="chips">
    <div class="chip on" data-m="steel">Steel</div>
    <div class="chip" data-m="ivory">Ivory</div>
    <div class="chip" data-m="normals">Normals</div>
    <div class="chip" data-m="bg">Light bg</div>
  </div>
</div></div>
<div id="err"></div>
<script>
  var post=function(o){window.ReactNativeWebView&&window.ReactNativeWebView.postMessage(JSON.stringify(o));};
  function fail(m){document.getElementById('load').style.display='none';var e=document.getElementById('err');e.style.display='flex';e.textContent='Couldn’t show the model. '+m;post({type:'error',message:String(m)});}
  window.addEventListener('error',function(e){fail(e.message||'error');});
  var URL_=${urlLit}, NAME=${nameLit}, MAXB=${MAX_STL_BYTES};
  document.getElementById('lbl').textContent=NAME;

  // ---- STL parse (binary + ASCII), face normals recomputed from geometry ----
  function parseSTL(buf){
    var u8=new Uint8Array(buf);
    var isAscii=false;
    if(u8.length>=6){ var head=''; for(var i=0;i<Math.min(512,u8.length);i++) head+=String.fromCharCode(u8[i]);
      if(/^\\s*solid/.test(head) && head.indexOf('facet')>=0) isAscii=true; }
    var pos;
    if(!isAscii){
      if(u8.length<84) throw new Error('not an STL');
      var dv=new DataView(buf), n=dv.getUint32(80,true);
      if(84+n*50>u8.length) throw new Error('truncated STL');
      pos=new Float32Array(n*9);
      for(var t=0;t<n;t++){ var o=84+t*50+12; for(var k=0;k<9;k++) pos[t*9+k]=dv.getFloat32(o+k*4,true); }
    }else{
      var txt=new TextDecoder().decode(u8), re=/vertex\\s+([-\\d.eE+]+)\\s+([-\\d.eE+]+)\\s+([-\\d.eE+]+)/g, arr=[], m;
      while((m=re.exec(txt))) arr.push(+m[1],+m[2],+m[3]);
      pos=new Float32Array(arr);
    }
    var tris=(pos.length/9)|0;
    var nor=new Float32Array(tris*9);
    var mnx=1e30,mny=1e30,mnz=1e30,mxx=-1e30,mxy=-1e30,mxz=-1e30;
    for(var f=0;f<tris;f++){ var b=f*9;
      var ax=pos[b],ay=pos[b+1],az=pos[b+2],bx=pos[b+3],by=pos[b+4],bz=pos[b+5],cx2=pos[b+6],cy2=pos[b+7],cz2=pos[b+8];
      var ux=bx-ax,uy=by-ay,uz=bz-az,vx=cx2-ax,vy=cy2-ay,vz=cz2-az;
      var nx=uy*vz-uz*vy,ny=uz*vx-ux*vz,nz=ux*vy-uy*vx;
      var l=Math.sqrt(nx*nx+ny*ny+nz*nz)||1; nx/=l; ny/=l; nz/=l;
      for(var v3=0;v3<3;v3++){ nor[b+v3*3]=nx; nor[b+v3*3+1]=ny; nor[b+v3*3+2]=nz; }
      mnx=Math.min(mnx,ax,bx,cx2); mxx=Math.max(mxx,ax,bx,cx2);
      mny=Math.min(mny,ay,by,cy2); mxy=Math.max(mxy,ay,by,cy2);
      mnz=Math.min(mnz,az,bz,cz2); mxz=Math.max(mxz,az,bz,cz2);
    }
    return { pos:pos, nor:nor, tris:tris, min:[mnx,mny,mnz], max:[mxx,mxy,mxz] };
  }

  // ---- minimal mat4 helpers (column-major) ----
  function persp(fov,asp,n2,f2){ var t=1/Math.tan(fov/2), d=1/(n2-f2);
    return [t/asp,0,0,0, 0,t,0,0, 0,0,(f2+n2)*d,-1, 0,0,2*f2*n2*d,0]; }
  function mul(a,b){ var o=new Array(16);
    for(var c2=0;c2<4;c2++)for(var r=0;r<4;r++){ var s=0; for(var k2=0;k2<4;k2++) s+=a[k2*4+r]*b[c2*4+k2]; o[c2*4+r]=s; }
    return o; }
  function lookAt(eye,ct,up){ var zx=eye[0]-ct[0],zy=eye[1]-ct[1],zz=eye[2]-ct[2];
    var zl=Math.sqrt(zx*zx+zy*zy+zz*zz)||1; zx/=zl;zy/=zl;zz/=zl;
    var xx=up[1]*zz-up[2]*zy, xy=up[2]*zx-up[0]*zz, xz=up[0]*zy-up[1]*zx;
    var xl=Math.sqrt(xx*xx+xy*xy+xz*xz)||1; xx/=xl;xy/=xl;xz/=xl;
    var yx=zy*xz-zz*xy, yy=zz*xx-zx*xz, yz=zx*xy-zy*xx;
    return [xx,yx,zx,0, xy,yy,zy,0, xz,yz,zz,0,
      -(xx*eye[0]+xy*eye[1]+xz*eye[2]), -(yx*eye[0]+yy*eye[1]+yz*eye[2]), -(zx*eye[0]+zy*eye[1]+zz*eye[2]), 1]; }

  fetch(URL_).then(function(r){
    if(!r.ok) throw new Error('download failed (HTTP '+r.status+')');
    return r.arrayBuffer();
  }).then(function(buf){
    if(buf.byteLength>MAXB) throw new Error('model too large to preview on the phone');
    var g=parseSTL(buf);
    if(!g.tris) throw new Error('no triangles found');
    document.getElementById('load').style.display='none';
    document.getElementById('lbl').textContent=NAME+' · '+g.tris.toLocaleString()+' tris';
    post({type:'loaded',tris:g.tris});

    var cv=document.getElementById('c');
    var gl=cv.getContext('webgl',{antialias:true});
    if(!gl) throw new Error('WebGL unavailable');
    function sh(type,src){ var s=gl.createShader(type); gl.shaderSource(s,src); gl.compileShader(s);
      if(!gl.getShaderParameter(s,gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(s)); return s; }
    var vs=sh(gl.VERTEX_SHADER,
      'attribute vec3 aP;attribute vec3 aN;uniform mat4 uMVP;varying vec3 vN;'+
      'void main(){vN=aN;gl_Position=uMVP*vec4(aP,1.0);}');
    var fs=sh(gl.FRAGMENT_SHADER,
      'precision mediump float;varying vec3 vN;uniform vec3 uColor;uniform float uMode;'+
      'void main(){vec3 n=normalize(vN);'+
      'if(uMode>0.5){gl_FragColor=vec4(n*0.5+0.5,1.0);return;}'+
      'float d1=max(dot(n,normalize(vec3(0.5,0.4,0.8))),0.0);'+
      'float d2=max(dot(n,normalize(vec3(-0.6,-0.3,0.2))),0.0);'+
      'float lum=0.22+0.62*d1+0.22*d2;'+
      'gl_FragColor=vec4(uColor*lum,1.0);}');
    var pr=gl.createProgram(); gl.attachShader(pr,vs); gl.attachShader(pr,fs); gl.linkProgram(pr);
    if(!gl.getProgramParameter(pr,gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(pr));
    gl.useProgram(pr);
    function buf3(data,loc){ var b=gl.createBuffer(); gl.bindBuffer(gl.ARRAY_BUFFER,b);
      gl.bufferData(gl.ARRAY_BUFFER,data,gl.STATIC_DRAW); gl.enableVertexAttribArray(loc);
      gl.vertexAttribPointer(loc,3,gl.FLOAT,false,0,0); }
    buf3(g.pos,gl.getAttribLocation(pr,'aP'));
    buf3(g.nor,gl.getAttribLocation(pr,'aN'));
    var uMVP=gl.getUniformLocation(pr,'uMVP'), uColor=gl.getUniformLocation(pr,'uColor'), uMode=gl.getUniformLocation(pr,'uMode');
    gl.enable(gl.DEPTH_TEST);

    var ct=[(g.min[0]+g.max[0])/2,(g.min[1]+g.max[1])/2,(g.min[2]+g.max[2])/2];
    var span=Math.max(g.max[0]-g.min[0],g.max[1]-g.min[1],g.max[2]-g.min[2])||1;
    // Initial distance fits the model's bounding SPHERE through the NARROWER screen axis — 0.9 rad
    // is the VERTICAL fov, and on a portrait phone the horizontal fov is ~1/3 of that, so a
    // height-only fit clips wide models at the sides (caught numerically before shipping).
    var dx2=g.max[0]-g.min[0],dy2=g.max[1]-g.min[1],dz2=g.max[2]-g.min[2];
    var rad=0.5*Math.sqrt(dx2*dx2+dy2*dy2+dz2*dz2)||1;
    var asp0=Math.max(0.3,window.innerWidth/Math.max(window.innerHeight,1));
    var vHalf=0.45, hHalf=Math.atan(Math.tan(vHalf)*asp0);
    var DEF={yaw:-0.62,pitch:0.5,dist:rad/Math.tan(Math.min(vHalf,hHalf))*1.15};
    var yaw=DEF.yaw,pitch=DEF.pitch,dist=DEF.dist,panX=0,panY=0,vyaw=0,vpitch=0;
    var MATS={steel:[0.62,0.67,0.76],ivory:[0.91,0.89,0.84],teal:[0.17,0.83,0.75]};
    var mode='steel', lightBg=false, dpr=Math.min(window.devicePixelRatio||2,2.5);

    function draw(){
      var W=cv.clientWidth*dpr|0, H=cv.clientHeight*dpr|0;
      if(cv.width!==W||cv.height!==H){cv.width=W;cv.height=H;gl.viewport(0,0,W,H);}
      if(lightBg) gl.clearColor(0.91,0.92,0.93,1); else gl.clearColor(0.063,0.07,0.086,1);
      gl.clear(gl.COLOR_BUFFER_BIT|gl.DEPTH_BUFFER_BIT);
      // Z-up orbit: eye on a sphere around the model centre; pan shifts the target in view plane.
      var cp=Math.cos(pitch),sp=Math.sin(pitch),cy=Math.cos(yaw),sy=Math.sin(yaw);
      var eye=[ct[0]+dist*cp*sy, ct[1]-dist*cp*cy, ct[2]+dist*sp];
      var tgt=[ct[0]+panX*cy, ct[1]+panX*sy, ct[2]+panY];
      eye[0]+=panX*cy; eye[1]+=panX*sy; eye[2]+=panY;
      var mvp=mul(persp(0.9,cv.width/Math.max(cv.height,1),span*0.01,span*20), lookAt(eye,tgt,[0,0,1]));
      gl.uniformMatrix4fv(uMVP,false,new Float32Array(mvp));
      gl.uniform1f(uMode,mode==='normals'?1:0);
      var col=MATS[mode]||MATS.steel; gl.uniform3f(uColor,col[0],col[1],col[2]);
      gl.drawArrays(gl.TRIANGLES,0,g.tris*3);
    }
    var raf=null; function schedule(){ if(!raf) raf=requestAnimationFrame(function(){raf=null;draw();}); }
    window.addEventListener('resize',schedule); schedule();

    // ---- touch: 1-finger rotate (+inertia), pinch zoom, 2-finger pan, double-tap reset ----
    var t0=null,t1=null,lastTap=0,pinch0=0,dist0=0,panS=null;
    function tick(){ if(Math.abs(vyaw)>1e-4||Math.abs(vpitch)>1e-4){ yaw+=vyaw; pitch=clampP(pitch+vpitch); vyaw*=0.92; vpitch*=0.92; schedule(); requestAnimationFrame(tick);} }
    function clampP(p){ return Math.max(-1.45,Math.min(1.45,p)); }
    cv.addEventListener('touchstart',function(e){ e.preventDefault();
      if(e.touches.length===1){ var now=Date.now();
        if(now-lastTap<280){ yaw=DEF.yaw;pitch=DEF.pitch;dist=DEF.dist;panX=0;panY=0;vyaw=0;vpitch=0;schedule(); }
        lastTap=now; t0={x:e.touches[0].clientX,y:e.touches[0].clientY}; vyaw=0;vpitch=0; }
      if(e.touches.length===2){ t0=null;
        pinch0=Math.hypot(e.touches[0].clientX-e.touches[1].clientX,e.touches[0].clientY-e.touches[1].clientY);
        dist0=dist; panS={x:(e.touches[0].clientX+e.touches[1].clientX)/2,y:(e.touches[0].clientY+e.touches[1].clientY)/2,px:panX,py:panY}; }
    },{passive:false});
    cv.addEventListener('touchmove',function(e){ e.preventDefault();
      if(e.touches.length===1&&t0){ var dx=e.touches[0].clientX-t0.x, dy=e.touches[0].clientY-t0.y;
        vyaw=dx*0.006; vpitch=dy*0.006; yaw+=vyaw; pitch=clampP(pitch+vpitch);
        t0={x:e.touches[0].clientX,y:e.touches[0].clientY}; schedule(); }
      if(e.touches.length===2&&panS){ var p=Math.hypot(e.touches[0].clientX-e.touches[1].clientX,e.touches[0].clientY-e.touches[1].clientY);
        if(pinch0>0) dist=Math.max(span*0.15,Math.min(span*8,dist0*pinch0/Math.max(p,1)));
        var mx=(e.touches[0].clientX+e.touches[1].clientX)/2,my=(e.touches[0].clientY+e.touches[1].clientY)/2;
        var s=dist*0.0016; panX=panS.px-(mx-panS.x)*s; panY=panS.py+(my-panS.y)*s; schedule(); }
    },{passive:false});
    cv.addEventListener('touchend',function(e){ if(e.touches.length===0){ t0=null;panS=null; requestAnimationFrame(tick);} },{passive:false});

    // ---- chips ----
    var chips=document.querySelectorAll('.chip');
    chips.forEach(function(ch){ ch.addEventListener('click',function(){
      var m2=ch.getAttribute('data-m');
      if(m2==='bg'){ lightBg=!lightBg; ch.classList.toggle('on',lightBg); document.body.classList.toggle('light',lightBg); }
      else { mode=m2; chips.forEach(function(o){ if(o.getAttribute('data-m')!=='bg') o.classList.toggle('on',o===ch); }); }
      schedule();
    }); });
  }).catch(function(e){ fail(e&&e.message?e.message:String(e)); });
</script>
</body></html>`;
}
