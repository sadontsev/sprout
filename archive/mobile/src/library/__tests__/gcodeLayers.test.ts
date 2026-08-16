import { gcodeViewerHtml } from '../gcodeLayers';
import { GCODE_PARSER_JS } from '../gcodeParserSource';

// Parsing semantics live in gcodeParserSource.test.ts, which executes the exact source the page
// ships. This file covers the PAGE contract: what it fetches, what it renders with, and the
// affordances that have regressed before.
const html = gcodeViewerHtml({ url: 'https://x/api/v1/library/files/41/gcode', headers: { 'X-API-Key': 'bb_k' } });

describe('gcodeViewerHtml (viewer contract)', () => {
  test('embeds the machine plate footprint; defaults to 256x256', () => {
    expect(gcodeViewerHtml({ url: 'u' }, { w: 350, d: 320 })).toContain('{"w":350,"d":320}');
    expect(gcodeViewerHtml({ url: 'u' })).toContain('{"w":256,"d":256}');
  });

  test('fetches the G-code ITSELF, with auth headers — no payload crosses the bridge', () => {
    expect(html).toContain('"https://x/api/v1/library/files/41/gcode"');
    expect(html).toContain('"X-API-Key":"bb_k"');
    expect(html).toContain('fetch(URL_, { headers: HDRS })');
  });

  test('ships the parser source inline, so page and tests run the same code', () => {
    expect(html).toContain('function parseGcode(text)');
    expect(html).toContain(GCODE_PARSER_JS.trim().slice(0, 60));
  });

  test('renders with INSTANCED geometry (20 bytes/segment, no index buffer)', () => {
    expect(html).toContain('ANGLE_instanced_arrays');
    expect(html).toContain('drawArraysInstancedANGLE');
    expect(html).toContain('vertexAttribDivisorANGLE');
    expect(html).not.toContain('drawElements'); // the 152 B/segment indexed path is gone
    expect(html).not.toContain('OES_element_index_uint');
  });

  test('no size cap or decimation remains — that was a symptom of the old pipeline', () => {
    expect(html).not.toContain('SEG_BUDGET');
    expect(html).not.toMatch(/skip\s*=/);
  });

  test('keeps the usability affordances: plate grid, reset, pan hint, axis gizmo, Z in the label', () => {
    expect(html).toContain('drawPlate');
    expect(html).toContain('resetView');
    expect(html).toContain('2-finger pan');
    expect(html).toContain('drawGizmo');
    expect(html).toContain('mm');
  });

  test('has wired shading/background chips and directional wall shading', () => {
    for (const chip of ['Steel', 'Ivory', 'Light bg']) expect(html).toContain(chip);
    expect(html).toContain('vDir');
    expect(html).toMatch(/querySelectorAll\('\.chip'\)[\s\S]*addEventListener\('click'/);
  });

  test('reports readiness (and support presence) back to the app', () => {
    expect(html).toContain("post({type:'ready'");
    expect(html).toContain('hasSupport');
  });

  test('escapes </script> injection in the url', () => {
    const evil = gcodeViewerHtml({ url: 'https://x/</script><script>alert(1)</script>' });
    expect(evil).not.toContain('</script><script>alert(1)');
  });

  test('embedded script is syntactically valid JS', () => {
    const script = html.split('<script>')[1].split('</script>')[0];
    expect(() => new Function(script)).not.toThrow();
  });
});
