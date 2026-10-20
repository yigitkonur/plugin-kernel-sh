// Facts: a profile is saved when the writer browser is deleted (not when the client disconnects);
// a later browser loading the profile sees the saved state. Creates and deletes one profile named kplab-smoke-<time>.
import assert from 'node:assert/strict';
import Kernel from '@onkernel/sdk';

const kernel = new Kernel({ maxRetries: 0, timeout: 60_000 });
const name = `kplab-smoke-${Date.now()}`;
const profile = await kernel.profiles.create({ name });
const tags = { lab: 'plugin-smoke', probe: 'profile' };
const run = async (save_changes: boolean | undefined, code: string) => {
  const b = await kernel.browsers.create({ headless: true, timeout_seconds: 90, tags, profile: { name, save_changes } });
  try {
    const r = await kernel.browsers.playwright.execute(b.session_id, { code, timeout_sec: 60 });
    assert.equal(r.success, true, String(r.error));
    return r.result as string;
  } finally {
    await kernel.browsers.deleteByID(b.session_id);
  }
};
try {
  await run(true, `await page.goto('https://the-internet.herokuapp.com/login');
    await page.fill('#username', 'tomsmith'); await page.fill('#password', 'SuperSecretPassword!');
    await Promise.all([page.waitForURL('**/secure'), page.click('button[type=submit]')]); return page.url();`);
  const heading = await run(undefined, `await page.goto('https://the-internet.herokuapp.com/secure'); return (await page.locator('h2').first().textContent())?.trim();`);
  assert.equal(heading, 'Secure Area');
} finally {
  await kernel.profiles.delete(profile.id);
}
console.log('profile-persist: ok');
