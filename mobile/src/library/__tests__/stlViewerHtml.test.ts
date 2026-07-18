import { stlViewerHtml, MAX_STL_BYTES } from '@/library/stlViewerHtml';

const html = stlViewerHtml({ url: 'https://x/api/v1/library/files/22/dl/tok/model.stl', name: 'model.stl' });

test('embeds the download URL and name as JSON literals', () => {
  expect(html).toContain('"https://x/api/v1/library/files/22/dl/tok/model.stl"');
  expect(html).toContain('"model.stl"');
});

test('escapes </script> injection in url and name', () => {
  const evil = stlViewerHtml({ url: 'https://x/</script><script>alert(1)</script>', name: '</script>x' });
  expect(evil).not.toContain('</script><script>alert(1)');
  expect(evil).toContain('\\u003c/script'); // JSON-escaped, inert inside the string literal
});

test('is fully self-contained — no external script/style loads (offline WKWebView constraint)', () => {
  expect(html).not.toMatch(/<script[^>]+src=/);
  expect(html).not.toMatch(/<link[^>]+href=/);
  expect(html).not.toContain('cdn.');
});

test('contains the WebGL pipeline, both STL parse paths, and the size cap', () => {
  expect(html).toContain("getContext('webgl'");
  expect(html).toContain('getUint32(80,true)'); // binary STL triangle count
  expect(html).toContain('vertex'); // ASCII fallback regex
  expect(html).toContain(String(MAX_STL_BYTES));
});

test('has the shading chips and posts loaded/error messages to RN', () => {
  for (const chip of ['Steel', 'Ivory', 'Normals', 'Light bg']) expect(html).toContain(chip);
  expect(html).toContain("post({type:'loaded'");
  expect(html).toContain("post({type:'error'");
});
