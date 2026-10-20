// Facts: create returns session_id + cdp_ws_url; playwright.execute returns { success, result };
// deleteByID removes the browser; there is no browsers.delete; retrieve after delete is a 404.
import assert from 'node:assert/strict';
import Kernel from '@onkernel/sdk';

const kernel = new Kernel({ maxRetries: 0, timeout: 60_000 });
assert.equal(typeof (kernel.browsers as any).delete, 'undefined', 'browsers.delete should not exist');

const browser = await kernel.browsers.create({ headless: true, timeout_seconds: 60, tags: { lab: 'plugin-smoke', probe: 'lifecycle' } });
try {
  assert.ok(browser.session_id && browser.cdp_ws_url && browser.webdriver_ws_url, 'create response shape');
  const res = await kernel.browsers.playwright.execute(browser.session_id, {
    code: "await page.goto('https://example.com'); return await page.title();",
    timeout_sec: 30,
  });
  assert.equal(res.success, true);
  assert.equal(res.result, 'Example Domain');
} finally {
  await kernel.browsers.deleteByID(browser.session_id);
}
await assert.rejects(() => kernel.browsers.retrieve(browser.session_id), (e: any) => e.status === 404);
const gone = await kernel.browsers.retrieve(browser.session_id, { include_deleted: true });
assert.ok(gone.deleted_at, 'deleted_at is set on the deleted record');
console.log('lifecycle: ok');
