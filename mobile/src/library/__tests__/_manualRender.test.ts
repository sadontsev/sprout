// THROWAWAY — real-data smoke test for the layer viewer. Reads G-code fetched from the live backend,
// runs the ACTUAL parser + HTML builder, asserts ground-truth layer count, and writes the rendered
// HTML to scratchpad for a headless screenshot. Deleted after the manual test run.
import * as fs from 'fs';
import { parseGcodeLayers, gcodeViewerHtml } from '../gcodeLayers';

const S = '/private/tmp/claude-501/-Users-max-ai-projects-bambu-app/87ecab09-aea6-404d-b457-9e378effe562/scratchpad';

const SAMPLES = [
  { id: 8, label: 'caldera-E (the user sample, plate 1)' },
  { id: 6, label: 'watering-ring' },
  { id: 2, label: 'cube20' },
];

test.each(SAMPLES)('renders real sliced gcode: $label', ({ id }) => {
  const g = fs.readFileSync(`${S}/sample${id}.gcode`, 'utf8');
  const declared = Number(/total layer number:\s*(\d+)/.exec(g)?.[1] ?? 0);
  const parsed = parseGcodeLayers(g);
  const html = gcodeViewerHtml(parsed);
  fs.writeFileSync(`${S}/viewer${id}.html`, html);
  // eslint-disable-next-line no-console
  console.log(`SAMPLE ${id}: declared=${declared} parsed=${parsed.layers.length} bounds=${JSON.stringify(parsed.bounds)} html=${html.length}b`);
  expect(parsed.layers.length).toBeGreaterThan(declared * 0.85);
  expect(parsed.layers.length).toBeLessThanOrEqual(declared + 2);
  expect(html).toContain('<canvas');
  expect(html).not.toContain('import(');
  expect(html).not.toContain('esm.sh');
});
