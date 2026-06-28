import { mjpegHtml } from '../mjpegHtml';

// The CameraOverlay onMessage handler reacts to an exact set of postMessage strings, and the in-page
// script must recover from the A1 camera's silent warm-up (a 200-open-but-no-frame stall fires neither
// load nor error). These tests pin that contract so a refactor can't silently re-introduce the
// "stuck CONNECTING / doesn't stream" symptom.
describe('mjpegHtml', () => {
  const URL = 'https://bambuddy.example/api/v1/printers/1/camera/stream?token=abc&fps=10';

  it('embeds the stream URL safely (JSON-encoded, assigned via JS — not a raw src= attribute)', () => {
    const html = mjpegHtml(URL);
    expect(html).toContain(JSON.stringify(URL));
    expect(html).not.toContain(`src="${URL}"`);
  });

  it('emits exactly the protocol strings the RN onMessage handler switches on', () => {
    const html = mjpegHtml(URL);
    for (const msg of ['connecting', 'frame', 'retry', 'failed']) {
      expect(html).toContain(`'${msg}'`);
    }
  });

  it('arms a stall watchdog on connect so a silent (no load/no error) warm-up still advances', () => {
    const html = mjpegHtml(URL);
    // A timer drives miss() when the socket is open but no frame has decoded.
    expect(html).toContain('wd=setTimeout(function(){wd=null;miss()},9000)');
    // The watchdog is only armed while not yet live (a healthy stream is never reconnected).
    expect(html).toContain('if(!live){wd=setTimeout');
  });

  it('reports the first decoded frame once and disarms the watchdog on load', () => {
    const html = mjpegHtml(URL);
    expect(html).toContain("img.onload=function(){settled=true;disarm();if(!live){live=true;P('frame')}}");
  });

  it('bounds retries by a wall-clock deadline (not a fixed count) and only fails past it', () => {
    const html = mjpegHtml(URL);
    expect(html).toContain('Date.now()-startedAt<=40000');
    expect(html).toMatch(/Date\.now\(\)-startedAt<=40000\)\{P\('retry'\);t=setTimeout\(connect,2000\)\}else\{P\('failed'\)\}/);
  });

  it('self-heals a mid-stream transport error after going live (fresh budget, no immediate failure)', () => {
    const html = mjpegHtml(URL);
    // onerror while live -> reset the clock and reconnect rather than counting toward failure.
    expect(html).toContain('img.onerror=function(){if(live){live=false;startedAt=Date.now()');
  });

  it('de-dupes the stall-vs-error race so one connect attempt is only missed once', () => {
    const html = mjpegHtml(URL);
    expect(html).toContain('function miss(){if(settled)return;settled=true;');
  });

  it('cache-busts each (re)connect so a dead keep-alive socket is not reused', () => {
    const html = mjpegHtml(URL);
    expect(html).toContain("'_r='+Date.now()");
    expect(html).toContain("base.indexOf('?')<0?'?':'&'");
  });

  it('timing bounds are injectable (stallMs, retryMs, deadlineMs)', () => {
    const html = mjpegHtml(URL, 1234, 567, 8910);
    expect(html).toContain('},1234)'); // stall watchdog
    expect(html).toContain('setTimeout(connect,567)'); // retry backoff
    expect(html).toContain('<=8910'); // deadline
  });

  it('defaults give a generous warm-up window past the measured ~7s cold start', () => {
    const html = mjpegHtml(URL);
    expect(html).toContain('},9000)'); // 9s stall > 7s cold start
    expect(html).toContain('<=40000'); // ~40s total budget
  });
});
