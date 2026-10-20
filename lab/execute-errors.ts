// Fact: a throw inside playwright.execute does NOT reject; it is HTTP 200 with success:false and an error string.
import assert from 'node:assert/strict';
import Kernel from '@onkernel/sdk';

const kernel = new Kernel({ maxRetries: 0, timeout: 60_000 });
const browser = await kernel.browsers.create({ headless: true, timeout_seconds: 60, tags: { lab: 'plugin-smoke', probe: 'execute-errors' } });
try {
  const res = await kernel.browsers.playwright.execute(browser.session_id, { code: "throw new Error('deliberate');", timeout_sec: 30 });
  assert.equal(res.success, false);
  assert.match(String(res.error), /deliberate/);
} finally {
  await kernel.browsers.deleteByID(browser.session_id);
}
console.log('execute-errors: ok');
