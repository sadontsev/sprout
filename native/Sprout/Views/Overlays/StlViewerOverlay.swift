#if os(iOS)
// Overlays are a fullScreenCover idiom. macOS uses sheets and windows (§7).
// Compiled for iOS only — see docs/native-rewrite/18-mac-port-architecture.md.
import SwiftUI
import UIKit
import WebKit
import os

// The two model viewers are deliberately NOT native renderers. They are the same self-contained
// HTML/JS pages the app has always shipped, hosted in a WKWebView:
//
//  - Parsing a 70 MB G-code file or a 1 M-triangle STL is FASTER in JavaScriptCore than anywhere a
//    Swift port could reach without a week of `UnsafeRawBufferPointer` work, because the page also
//    feeds the parsed floats straight into GPU buffers with no copy in between.
//  - The pages carry zero CDN imports, so they work with no internet at all.
//  - The bytes never cross into Swift: the page fetches its own payload from the server.
//
// The one structural requirement: the document must be loaded ON the Bambuddy origin. Bambuddy
// sends no CORS headers, so a page loaded from `about:blank` or a file URL has its in-page fetch
// blocked outright. `loadHTMLString(_:baseURL:)` with the server origin is what makes it same-origin.

// MARK: - Shared page plumbing

/// Both viewers log here. Shared rather than file-private because a failure in either one is the
/// same question — "which URL did the page actually ask for?" — and it should read the same way.
let viewerLog = Logger(subsystem: "com.mvks5.bambu", category: "viewer")

/// What a viewer page reports back over the JS bridge.
enum ViewerEvent: Equatable {
    /// Layer viewer finished parsing and drew its first frame.
    case ready(hasSupport: Bool)
    /// STL viewer finished parsing the mesh.
    case loaded(tris: Int)
    /// Download / parse / WebGL failure. The page renders its own message too.
    ///
    /// `status` is the HTTP status of the in-page fetch when that is what failed, and 0 for a parse
    /// or WebGL failure. It is carried separately from the message because the caller has to ACT on
    /// it: 401/403 on the STL page means the one-shot download token was spent or aged out, which is
    /// recoverable by minting another, while 404 means the URL had the wrong shape and re-minting
    /// would rebuild the same broken URL.
    case failed(String, status: Int)
}


/// Hosts a viewer page and relays its `postMessage` traffic.
///
/// `baseURL` is load-bearing, not cosmetic — see the file header.
struct ViewerWebView: UIViewRepresentable {
    let html: String
    let baseURL: URL
    let onEvent: (ViewerEvent) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onEvent: onEvent) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.userContentController.addUserScript(
            WKUserScript(source: ViewerJS.bridge, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
        config.userContentController.add(context.coordinator, name: ViewerJS.bridgeName)

        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = UIColor(Palette.dark.bg)
        web.scrollView.backgroundColor = UIColor(Palette.dark.bg)
        web.scrollView.isScrollEnabled = false
        web.scrollView.bounces = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        // Both pages implement pinch themselves out of `touchmove` + `preventDefault`, and pinch is
        // fused with two-finger pan in a single branch. Leaving the scroll view's own pinch
        // recognizer enabled lets WKWebView eat the second finger before the DOM ever sees it.
        web.scrollView.pinchGestureRecognizer?.isEnabled = false
        web.allowsBackForwardNavigationGestures = false
        web.loadHTMLString(html, baseURL: baseURL)
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // Only the callback is refreshed. Re-loading would restart a 70 MB download and, for the
        // STL page, spend a download token that is single-use.
        context.coordinator.onEvent = onEvent
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        // Closing mid-download has to actually stop the transfer, and the content controller holds a
        // strong reference to the coordinator until the handler is removed.
        uiView.stopLoading()
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: ViewerJS.bridgeName)
        uiView.configuration.userContentController.removeAllUserScripts()
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler {
        var onEvent: (ViewerEvent) -> Void

        init(onEvent: @escaping (ViewerEvent) -> Void) {
            self.onEvent = onEvent
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard
                let json = message.body as? String,
                let data = json.data(using: .utf8),
                let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { return }

            switch obj["type"] as? String {
            case "error":
                onEvent(.failed(
                    (obj["message"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "render error",
                    status: obj["status"] as? Int ?? 0
                ))
            case "ready":
                onEvent(.ready(hasSupport: obj["hasSupport"] as? Bool ?? false))
            case "loaded":
                onEvent(.loaded(tris: obj["tris"] as? Int ?? 0))
            default:
                break
            }
        }
    }
}

// MARK: - Shared chrome

/// Dark chrome for both viewers.
///
/// These are dark-palette literals on purpose: the page underneath is a fixed dark surface that the
/// app's light theme cannot reach, so light-mode chrome would be invisible on top of it.
enum ViewerChrome {
    static let pill = Palette.dark.sheet
    static let ink = Color.white
    static let dim = Palette.dark.t3
    static let glyph = Color(hex: 0x3A4046)
    static let offDot = Color(hex: 0x4F555B)
    static let offInk = Color(hex: 0x9AA0A6)
}

/// Close pill + title pill + an optional trailing pill, floated over a viewer page.
struct ViewerTopBar<Trailing: View>: View {
    let title: String
    let onClose: () -> Void
    private let trailing: () -> Trailing

    init(title: String, onClose: @escaping () -> Void, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.onClose = onClose
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 11) {
            Tap(action: onClose) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(ViewerChrome.ink)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(ViewerChrome.pill.opacity(0.6)))
            }

            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ViewerChrome.ink)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(ViewerChrome.pill.opacity(0.55)))

            trailing()
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }
}

extension ViewerTopBar where Trailing == EmptyView {
    init(title: String, onClose: @escaping () -> Void) {
        self.init(title: title, onClose: onClose, trailing: { EmptyView() })
    }
}

/// Opaque full-bleed placeholder shown while a page downloads and parses.
///
/// Opaque because both pages carry their own in-page "Loading…" text; a translucent cover would
/// show two loading labels at once.
struct ViewerLoading: View {
    let label: String
    var compact = false

    var body: some View {
        VStack(spacing: compact ? 10 : 14) {
            ProgressView().tint(Palette.dark.accent)
            Text(label)
                .font(.mono(compact ? 10 : 11, weight: .semibold))
                .tracking(2)
                .foregroundStyle(ViewerChrome.glyph)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.dark.bg)
    }
}

/// Terminal failure: the page is torn down (freeing whatever it had parsed) and its message shown.
struct ViewerFailure: View {
    let icon: String
    let message: String
    var compact = false
    var onRetry: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: icon)
                .font(.system(size: compact ? 22 : 30, weight: .regular))
                .foregroundStyle(ViewerChrome.glyph)
            Text(message)
                .font(.system(size: compact ? 12 : 14, weight: .regular))
                .foregroundStyle(ViewerChrome.dim)
                .multilineTextAlignment(.center)
                .lineSpacing(compact ? 4 : 6)
                .padding(.top, compact ? 10 : 14)

            if let onRetry {
                Tap(action: onRetry) {
                    Text("Retry")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.dark.accent)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Palette.dark.accentDim))
                }
                .padding(.top, 18)
            }
        }
        .padding(.horizontal, compact ? 24 : 36)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.dark.bg)
    }
}

// MARK: - STL page

/// ~2.4 M triangles binary — beyond phone-GPU comfort. Enforced in-page, after the download, so the
/// message names the real problem instead of a stalled render.
let maxStlBytes = 120 * 1024 * 1024

/// Where the STL page pulls its mesh from.
enum StlSource: Equatable {
    /// A library file. The page fetches a tokenized download URL where the TOKEN IS THE AUTH, so
    /// the in-page fetch needs no headers. That token is single-use and short-lived.
    case library(fileId: Int, name: String)
    /// An arbitrary same-origin path (e.g. a texturize preview parked on the slicer sidecar), with
    /// optional auth headers for the in-page fetch.
    case direct(origin: String, path: String, name: String, headers: [String: String])
}

/// Builds the self-contained STL viewer page: raw WebGL, perspective orbit, flat-shaded mesh.
///
/// Canvas2D is not an option here — a textured STL is 100 k–1 M triangles and painter's-order
/// drawing dies well below that. Normals mode doubles as the "see the surface" affordance: colouring
/// faces by orientation makes displacement-texture detail pop far better than any single colour.
enum StlPage {

    /// - Parameter compact: inline embed (the wizard's step-1 preview) — hides the control card and
    ///   the reset button. Orbit / pinch / double-tap still work.
    static func html(url: String, name: String, compact: Bool, headers: [String: String]) -> String {
        let urlLit = ViewerJS.literal(url)
        let nameLit = ViewerJS.literal(name)
        let hdrsLit = ViewerJS.object(headers)
        let compactCss = compact ? "<style>#bar,#reset{display:none}</style>" : ""

        return #"""
        <!doctype html><html><head>
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
        </style>\#(compactCss)</head>
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
          // Carried out with every failure so the host can tell a SPENT one-shot token (401/403,
          // re-mintable) from a URL whose shape is wrong (404, re-minting rebuilds the same URL).
          var HTTPSTATUS=0;
          function fail(m){document.getElementById('load').style.display='none';var e=document.getElementById('err');e.style.display='flex';e.textContent='Couldn’t show the model. '+m;post({type:'error',message:String(m),status:HTTPSTATUS});}
          window.addEventListener('error',function(e){fail(e.message||'error');});
          var URL_=\#(urlLit), NAME=\#(nameLit), HDRS=\#(hdrsLit), MAXB=\#(maxStlBytes);
          document.getElementById('lbl').textContent=NAME;

          // ---- STL parse (binary + ASCII), face normals recomputed from geometry ----
          function parseSTL(buf){
            var u8=new Uint8Array(buf);
            var isAscii=false;
            if(u8.length>=6){ var head=''; for(var i=0;i<Math.min(512,u8.length);i++) head+=String.fromCharCode(u8[i]);
              if(/^\s*solid/.test(head) && head.indexOf('facet')>=0) isAscii=true; }
            var pos;
            if(!isAscii){
              if(u8.length<84) throw new Error('not an STL');
              var dv=new DataView(buf), n=dv.getUint32(80,true);
              if(84+n*50>u8.length) throw new Error('truncated STL');
              pos=new Float32Array(n*9);
              for(var t=0;t<n;t++){ var o=84+t*50+12; for(var k=0;k<9;k++) pos[t*9+k]=dv.getFloat32(o+k*4,true); }
            }else{
              var txt=new TextDecoder().decode(u8), re=/vertex\s+([-\d.eE+]+)\s+([-\d.eE+]+)\s+([-\d.eE+]+)/g, arr=[], m;
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

          fetch(URL_,{headers:HDRS}).then(function(r){
            if(!r.ok){ HTTPSTATUS=r.status; throw new Error('download failed (HTTP '+r.status+')'); }
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
        </body></html>
        """#
    }
}

// MARK: - Views

/// The STL viewer without chrome, so it can also be embedded inline (the print wizard's step-1
/// preview passes `compact: true`, which hides the page's own control card).
///
/// For a library file this first mints a tokenized download URL, then hands the page a URL it can
/// fetch with no headers at all. The mesh bytes never enter Swift.
struct StlModelView: View {
    let model: AppModel
    let source: StlSource
    var compact = false

    @State private var page: String?
    /// The absolute URL handed to the page, kept so a failure can be logged as the URL that was
    /// actually asked for rather than the one the reader assumes it was.
    @State private var pageUrl: String?
    @State private var failure: String?
    @State private var loaded = false
    @State private var attempt = 0
    /// One automatic re-mint has already been spent on this file.
    @State private var reminted = false

    var body: some View {
        ZStack {
            if let page, failure == nil {
                ViewerWebView(html: page, baseURL: documentBase, onEvent: handle)
                    .id(attempt)
            }
            if let failure {
                ViewerFailure(icon: "cube", message: failure, compact: compact, onRetry: retry)
            } else if !loaded {
                ViewerLoading(label: "LOADING MODEL…", compact: compact)
            }
        }
        .background(Palette.dark.bg)
        .task(id: attempt) { await build() }
    }

    private var documentBase: URL {
        switch source {
        case .library: ViewerJS.documentBase(of: model.client?.baseUrl ?? "")
        case .direct(let origin, _, _, _): ViewerJS.documentBase(of: origin)
        }
    }

    private func build() async {
        guard page == nil, failure == nil else { return }

        switch source {
        case .direct(let origin, let path, let name, let headers):
            // Resolve against the document base HERE rather than leaving a bare path for the page to
            // resolve. Two reasons: the page's own resolution silently depended on the base keeping
            // its path prefix (it did not), and a relative URL cannot be logged when it fails —
            // whatever the page fetched would be a guess.
            guard let resolved = URL(string: path, relativeTo: ViewerJS.documentBase(of: origin))?.absoluteURL else {
                failure = "That preview URL isn’t valid."
                return
            }
            pageUrl = resolved.absoluteString
            page = StlPage.html(url: resolved.absoluteString, name: name, compact: compact, headers: headers)

        case .library(let fileId, let name):
            guard let client = model.client else {
                failure = "Not connected to Bambuddy."
                return
            }
            do {
                // Minted once per attempt: the slicer token is single-use and short-lived, so a
                // second mint on a re-render would hand the page a URL the first one already spent.
                //
                // The name is only a Content-Disposition courtesy to the server, but it lands in a
                // PATH SEGMENT, so it has to be reduced to something that can be one — see
                // `LibraryDownloadName`.
                let safeName = LibraryDownloadName.pathSegment(name, fallback: "model-\(fileId).stl")
                let url = try await client.mintFileDownloadUrl(fileId, filename: safeName)
                guard !Task.isCancelled else { return }
                pageUrl = url.absoluteString
                page = StlPage.html(url: url.absoluteString, name: name, compact: compact, headers: [:])
            } catch let e as BambuddyError {
                failure = e.detail
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    private func handle(_ event: ViewerEvent) {
        switch event {
        case .loaded: loaded = true
        case .ready: break
        case .failed(let message, let status):
            viewerLog.error("STL page failed (HTTP \(status, privacy: .public)) on \(ViewerJS.loggableUrl(self.pageUrl ?? "<no url>"), privacy: .public) — \(message, privacy: .public)")
            // A spent or expired one-shot token answers 401/403. The page CAN be re-run on the same
            // token without the app asking — WebKit reloads it after a content-process recycle — so
            // treating that as terminal strands a perfectly good file behind a dead credential.
            // Mint another and reload, exactly once: 404 is deliberately excluded because it means
            // the URL's shape is wrong and a fresh token would rebuild the same broken URL.
            if !reminted, isTokenRejection(status), case .library = source {
                reminted = true
                viewerLog.notice("STL page: re-minting a download token after HTTP \(status, privacy: .public)")
                rebuild()
                return
            }
            failure = message
        }
    }

    private func isTokenRejection(_ status: Int) -> Bool { status == 401 || status == 403 }

    /// A fresh attempt has to re-mint — the previous token is gone either way.
    private func rebuild() {
        page = nil
        pageUrl = nil
        failure = nil
        loaded = false
        attempt += 1
    }

    /// The manual Retry. Unlike the automatic one it also re-arms the automatic re-mint, because the
    /// user asking again is a new decision, not the same attempt continuing.
    private func retry() {
        reminted = false
        rebuild()
    }
}

/// Full-screen interactive STL preview for a library file: flat-shaded WebGL mesh with orbit, pinch
/// zoom, two-finger pan and double-tap reset, plus Steel / Ivory / Normals / Light-bg chips.
struct StlViewerOverlay: View {
    let model: AppModel
    let file: LibraryFile

    var body: some View {
        ZStack(alignment: .top) {
            Palette.dark.bg.ignoresSafeArea()

            StlModelView(model: model, source: .library(fileId: file.id, name: title))
                .ignoresSafeArea()

            ViewerTopBar(title: title) { model.overlay = nil }
        }
        .preferredColorScheme(.dark)
    }

    /// Library names arrive percent-encoded often enough that the raw string is unreadable; a
    /// malformed escape decodes to nil, in which case the raw name is still better than nothing.
    private var title: String {
        let raw = [file.printName ?? "", file.filename].first { !$0.isEmpty } ?? "file-\(file.id)"
        return raw.removingPercentEncoding ?? raw
    }
}
#endif
