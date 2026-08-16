// Pure builder for the WebView document that hosts the chamber-camera MJPEG stream. Kept free of any
// native import so it stays unit-testable (Overlays.tsx itself pulls in react-native-webview).
//
// WebKit decodes multipart/x-mixed-replace natively (expo-image / RN <Image> cannot). The A1's chamber
// camera is ON-DEMAND: the backend returns the /stream response (HTTP 200 + multipart headers) in ~7ms
// but the cold camera needs ~7s to emit the first JPEG part, and a cold connect can stall or drop once
// or twice before frames flow. (The camera/diagnose port-6000 probe is a known false negative on this
// A1 — snapshot + stream work even when it reports "unreachable".)
//
// CRITICAL: during that warm-up window the socket is open and successful, so the <img> fires NEITHER
// `onload` (no frame decoded yet) NOR `onerror` (no transport error). An onerror-only retry loop would
// therefore wait forever — the exact "stuck connecting / doesn't stream" symptom. So we run a STALL
// WATCHDOG: after each (re)connect, if no frame decodes within `stallMs`, we treat it as a miss, drop
// the stalled socket and reconnect with a fresh cache-busted URL. Retries are bounded by a wall-clock
// `deadlineMs` (not a fixed count) so both a slow warm-up and a fast-erroring dead camera converge to
// the same ~deadline before we post 'failed'. Once a frame decodes we go live and disarm the watchdog
// (so a healthy stream is never reconnected); a later transport error self-heals with a fresh budget.
//
// Posts to RN via postMessage — the CameraOverlay onMessage handler switches on exactly these:
//   'connecting' (initial) · 'frame' (first decode → live) · 'retry' (a miss, reconnecting) ·
//   'failed' · 'fps:<n>' (frames delivered in the last second, only while live).
export function mjpegHtml(streamUrl: string, stallMs = 9000, retryMs = 2000, deadlineMs = 40000): string {
  const u = JSON.stringify(streamUrl);
  return `<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
<style>html,body{margin:0;height:100%;background:#060708;overflow:hidden}
img{position:absolute;inset:0;width:100%;height:100%;object-fit:contain;background:#060708}</style></head>
<body><img id="cam">
<script>
var base=${u},img=document.getElementById('cam'),live=false,settled=false,startedAt=Date.now(),t=null,wd=null;
function P(m){try{window.ReactNativeWebView&&window.ReactNativeWebView.postMessage(m)}catch(e){}}
function disarm(){if(wd){clearTimeout(wd);wd=null}}
function connect(){disarm();settled=false;if(!live){wd=setTimeout(function(){wd=null;miss()},${stallMs})}img.src=base+(base.indexOf('?')<0?'?':'&')+'_r='+Date.now()}
function miss(){if(settled)return;settled=true;disarm();live=false;if(t)clearTimeout(t);if(Date.now()-startedAt<=${deadlineMs}){P('retry');t=setTimeout(connect,${retryMs})}else{P('failed')}}
img.onload=function(){settled=true;disarm();if(!live){live=true;P('frame')}};
img.onerror=function(){if(live){live=false;startedAt=Date.now();if(t)clearTimeout(t);t=setTimeout(connect,${retryMs})}else{miss()}};
// Delivered-fps counter. WebKit does NOT fire onload per MJPEG part, so sample the rendered <img>
// into a 16x16 canvas each animation frame and count signature changes. Requires the DOCUMENT to
// share the stream's origin (CameraOverlay sets WebView baseUrl = streamOrigin(url)) — Bambuddy
// sends no CORS headers, so a cross-origin <img> taints the canvas, getImageData throws once, and
// the counter permanently disables itself (fpsDead) instead of spamming exceptions.
var fcvs=document.createElement('canvas');fcvs.width=16;fcvs.height=16;
var fctx=fcvs.getContext('2d',{willReadFrequently:true}),fsig='',fcount=0,fpsDead=false;
function ftick(){
  if(live&&!fpsDead&&fctx){
    try{
      fctx.drawImage(img,0,0,16,16);
      var d=fctx.getImageData(0,0,16,16).data,s='';
      for(var i=0;i<d.length;i+=16)s+=d[i]+','; // 64 sample points — sparse enough to be cheap, dense enough that near-static frames still differ (sensor noise)
      if(s!==fsig){fsig=s;fcount++}
    }catch(e){fpsDead=true}
  }
  requestAnimationFrame(ftick);
}
requestAnimationFrame(ftick);
setInterval(function(){if(live&&!fpsDead){P('fps:'+fcount)}fcount=0},1000);
P('connecting');connect();
</script></body></html>`;
}

/** Origin of the stream URL ("https://host[:port]") — CameraOverlay sets it as the WebView baseUrl
 *  so the document is SAME-ORIGIN with the MJPEG stream (Bambuddy sends no CORS headers; a
 *  cross-origin image would taint the fps counter's canvas). Null for unparseable input. */
export function streamOrigin(streamUrl: string | null | undefined): string | null {
  const m = /^(https?:\/\/[^/]+)/i.exec(streamUrl ?? '');
  return m ? m[1] : null;
}
