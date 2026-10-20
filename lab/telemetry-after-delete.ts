// Facts: telemetry stays readable after the browser is deleted; events are wrapped as { seq, event: { type, category, ... } };
// the type filter works on telemetry.events().
import assert from 'node:assert/strict';
import Kernel from '@onkernel/sdk';

const kernel = new Kernel({ maxRetries: 0, timeout: 60_000 });
const browser = await kernel.browsers.create({
  headless: true,
  timeout_seconds: 60,
  tags: { lab: 'plugin-smoke', probe: 'telemetry' },
  telemetry: { browser: { console: { enabled: true } } },
} as any);
const id = browser.session_id;
try {
  await kernel.browsers.playwright.execute(id, {
    code: "await page.goto('https://example.com'); await page.evaluate(() => console.error('boom')); return 1;",
    timeout_sec: 30,
  });
  await new Promise((r) => setTimeout(r, 2000));
} finally {
  await kernel.browsers.deleteByID(id);
}
const types: string[] = [];
for await (const e of kernel.browsers.telemetry.events(id, { since: '10m', type: ['console_error'], limit: 50 } as any)) {
  types.push((e as any).event.type);
}
assert.ok(types.length >= 1 && types.every((t) => t === 'console_error'), `expected only console_error, got ${types.join(',')}`);
console.log('telemetry-after-delete: ok');
