// The G-code parser that runs INSIDE the WebView, kept as source so there is exactly one
// implementation and jest can still execute it (see gcodeParserSource.test.ts, which evaluates this
// string and runs the full semantic suite against it).
//
// Why it moved out of React Native: parsing there meant the 70 MB G-code string was decoded in
// Hermes (no JIT), turned into millions of boxed JS numbers, JSON-stringified, and re-parsed inside
// the WebView — three full copies before a single triangle was drawn. That, not the phone, was the
// reason big prints "couldn't be previewed". Running here, JavaScriptCore JITs the hot loop and the
// output feeds GPU buffers directly.
//
// Output layout is deliberately flat and typed:
//   layers[i] / sup[i] : Float32Array of [x0,y0,x1,y1, ...] — 16 bytes per segment
//   zs[i]              : that layer's Z
// 1.13M segments (the user's spike ball) is ~18 MB here and ~27 MB on the GPU — comfortable.
export const GCODE_PARSER_JS = String.raw`
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

  // Leading PRIME/PURGE layers: the H2C purges at an ELEVATED Z before the first real layer. A
  // leading layer followed by a >0.5 mm DROP is priming, not model — exclude it from the bounds so
  // fit/pivot track the actual print (it still renders).
  var firstReal=0;
  while(firstReal<zs.length-1 && zs[firstReal]>zs[firstReal+1]+0.5) firstReal++;
  if(firstReal>0){
    minX=Infinity; minY=Infinity; maxX=-Infinity; maxY=-Infinity;
    for(var k=firstReal;k<layers.length;k++){
      var arrs=[layers[k],sup[k]];
      for(var ai=0;ai<2;ai++){ var L=arrs[ai];
        for(var q=0;q<L.length;q+=2){
          var vx=L[q], vy=L[q+1];
          if(vx<minX)minX=vx; if(vx>maxX)maxX=vx; if(vy<minY)minY=vy; if(vy>maxY)maxY=vy;
        }
      }
    }
  }
  if(!isFinite(minX)){ minX=0; minY=0; maxX=256; maxY=256; }
  var minZ=Infinity, maxZ=-Infinity;
  for(var k2=firstReal;k2<zs.length;k2++){ if(zs[k2]<minZ)minZ=zs[k2]; if(zs[k2]>maxZ)maxZ=zs[k2]; }
  if(!isFinite(minZ)){ minZ=0; maxZ=1; }

  var segTotal=0; for(var k3=0;k3<layers.length;k3++) segTotal+=layers[k3].length>>2;
  var supTotal=0; for(var k4=0;k4<sup.length;k4++) supTotal+=sup[k4].length>>2;
  return { layers:layers, sup:sup, zs:zs, supportEnabled:supportEnabled, hasSupport:hasSupport,
           segTotal:segTotal, supTotal:supTotal,
           bounds:{ minX:minX, minY:minY, maxX:maxX, maxY:maxY, minZ:minZ, maxZ:maxZ } };
}
`;
