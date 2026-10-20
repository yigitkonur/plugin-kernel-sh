# Browsers: create, size, time out, delete

Read this before you write `kernel.browsers.create(...)`. Every choice below is made at create time and several cannot be changed later. Exact method names: `references/api-map.md`. Driving the page: `references/control.md`.

## B1. Headful or headless

**If** a human may watch (live view), you record a replay, or the target site defends itself -> **Do** keep the default (headful). **If** the work is unwatched, undefended and high-volume -> **Do** `headless: true`. -> **Avoid** headless for anything you will need to debug visually: it has no live view and no replays, and some bot detectors spot it. -> **Source** https://www.kernel.sh/docs/browsers/headless

- Headless is lighter (1 GiB default vs 8 GiB) and cheaper. Per the pricing page, headful costs about 8x headless and a GPU headful browser about 48x headless (per-second rates, not re-measured). -> https://www.kernel.sh/docs/info/pricing
- Lab (P18): a headful create returns `browser_live_view_url`; a headless create omits it. The SDK type marks it optional, so handle `undefined`.

```ts
import Kernel from '@onkernel/sdk';

const kernel = new Kernel();
const browser = await kernel.browsers.create({
  headless: true,
  timeout_seconds: 60,
  tags: { lab: 'plugin-test', probe: 'P01' },
});
try {
  // ... use browser.session_id / browser.cdp_ws_url
} finally {
  await kernel.browsers.deleteByID(browser.session_id);
}
```

Source: probe P01 `create-delete.ts` (ran_ok).

## B2. Memory

**If** one browser runs many tabs or named executors, or pages are heavy -> **Do** set `memory` on purpose. **Avoid** assuming `memory` is headful-only, or that the SDK type tells you what is legal: the SDK type is a flat union of sizes (0.127 d.ts: `'1GiB' | '2GiB' | '4GiB' | '8GiB' | '16GiB'`; 0.128.0 adds `6GiB` and `12GiB` and documents headless 1/2/4, headful 8/16 in its doc comment), but the server checks the mode. -> **Source** probe P04, https://www.kernel.sh/docs/browsers/headless

| Mode | Accepted | Default | Lab |
|---|---|---|---|
| headless | `1GiB`, `2GiB`, `4GiB` (SDK version needed for 2 and 4: unverified) | `1GiB` | confirmed; `8GiB` and `3GiB` return 400 `invalid_request` "memory must be 1GiB or 2GiB or 4GiB" |
| headful | `8GiB`, `16GiB` | `8GiB` | `8GiB` confirmed; `16GiB` untested |

- Older notes claimed memory is headful-only. The headless docs page (`browsers__headless.md` line 11) and P04 show 2GiB and 4GiB work headless.
- Read the real size from inside the VM: `browsers.process.exec(id, { command: 'sh', args: ['-c', 'grep MemTotal /proc/meminfo'] })` (the value tracks the requested size). `navigator.deviceMemory` read 4 on all three headless sizes; do not use it.
- Pools take the same field (`references/scale.md`).

## B3. Timeout and standby

**If** you create a browser -> **Do** pass `timeout_seconds` on purpose (default 60 and max 72 h = 259200 per docs; minimum 10 per the SDK type) and still delete it yourself in `finally`. The timeout is a backstop that counts from standby, not a lease from create. -> **Avoid** using `timeout_seconds` to free a slot (delete instead); fearing idle cost (standby is free but still holds a concurrency slot). -> **Source** https://www.kernel.sh/docs/browsers/termination, https://www.kernel.sh/docs/browsers/standby, probe P02

- Active means: a CDP or WebDriver client is connected, a live view viewer is open, or a computer-controls request is in flight. After about 5 s with none of those the browser enters standby and the timeout clock starts.
- Lab (P02): with `timeout_seconds: 10` and no client, three runs were gone between 5 and 17 s after create. With `timeout_seconds: 120` and no client, the browser was still listed active at 30 s.
- No status, standby or usage field appeared in live retrieve/list responses (P02), although the SDK types declare `usage` and `usage_status`. Do not branch on them; use list membership and `deleted_at`. The active list can lag by a few seconds (P02 run B: browser missing at t=9 s, unexplained), so confirm with `retrieve` before acting.
- GPU browsers never enter standby (B8).

## B4. Delete: `deleteByID`, not `close()`

**If** a browser is done -> **Do** `await kernel.browsers.deleteByID(id)` in `finally` (CLI: `kernel browsers delete <id-or-name> [more...]`). Treat a 404 as already gone (a timeout may have reaped it). **Avoid** `browser.close()` from Playwright as cleanup, and `kernel.browsers.delete` (it does not exist). -> **Source** https://www.kernel.sh/docs/browsers/termination, probes P01 and P02

- Lab (P02): after `pw.close()` the browser stayed listed active (checked at 0.9 s, 25 s and 30 s); reconnecting to the same `cdp_ws_url` worked and cookies were kept. Only `deleteByID` removed it.
- Lab (P01): `typeof kernel.browsers.delete` is `undefined`; `deleteByID` took about 200 to 227 ms.
- After delete, `retrieve(id)` throws `NotFoundError` (404); `retrieve(id, { include_deleted: true })` returns the record with `deleted_at` set (no status field). The 404 message embeds the session id, so do not log raw error messages.
- A profile loaded with `save_changes` is saved on delete; a CDP close does not save it; save on timeout was not tested (`references/profiles.md`).
- Report any browser you left alive: `kernel browsers list --status active --tag <your-tag> -o json`.

```ts
// P02 02-close-standby-reconnect.ts, trimmed: close() does not delete.
const pw = await chromium.connectOverCDP(browser.cdp_ws_url);
await pw.close();                       // browser is still active and still holds its slot
await kernel.browsers.deleteByID(browser.session_id); // this ends it
```

## B5. Connection drops

**If** a CDP socket closes mid-run -> **Do** reconnect to the same `cdp_ws_url`; the browser is independent of the socket. -> **Avoid** treating a dropped socket as browser death. Sockets typically live up to about 1 hour (docs; the 1 h limit was not tested). -> **Source** https://www.kernel.sh/docs/browsers/faq, probe P02 (reconnect confirmed)

For new code prefer `playwright.execute` over CDP (`references/control.md`). If you must use `connectOverCDP`: `contexts()[0]` and `pages()[0]` exist on a fresh browser; `browser.newContext()` is isolated from `contexts()[0]` (a cookie set in one was invisible in the other, P02), so it loses profile cookies and extensions. Close the CDP client, then `deleteByID`.

## B6. Viewport, extensions, kiosk: decide at create

**If** you need a custom viewport, extensions, or kiosk mode -> **Do** set them in the create call. If create latency matters at steady traffic, put that fixed config in a pool (`references/scale.md`). -> **Avoid** changing them mid-session: docs say they restart Chromium and can drop CDP connections. -> **Source** https://www.kernel.sh/docs/browsers/performance, https://www.kernel.sh/docs/browsers/viewport, https://www.kernel.sh/docs/browsers/extensions, https://www.kernel.sh/docs/browsers/live-view

| Fact | Evidence |
|---|---|
| Default viewport 1920x1080@25 | docs viewport |
| `viewport` is the window, not the page. Headful 1280x720 gave `innerWidth` 1280, `innerHeight` 633 (UI takes about 87 px) | P04 confirmed (width matches, height short) |
| Headless: viewport is echoed in the response, but the window stayed 800x600 (`innerWidth` 800). `page.setViewportSize({ width, height })` fixed it at page level | P04 refuted the docs' "matches the viewport" for headless |
| `browsers.update` with a new viewport mid-session did not drop the CDP connection, headless or headful, and no Chromium restart was seen (headless only: a window marker survived) | P04 refuted the docs' restart warning for these cases. Not tested: `force: true`, live view or replay active, reconnect with the old URL (the `cdp_ws_url` value changed) |
| 1280x720 (create) and 1024x768 (update) were accepted in the lab; `refresh_rate` is auto-assigned (60 for 1280x720). `refresh_rate` only matters for live view | P04, SDK types |
| Exact page size wanted -> kiosk mode removes the UI (kiosk create restarts Chromium: several seconds) | docs viewport and live-view (untested) |
| Extensions: `extensions: [{ name }]` at create; `kernel browsers create --extension <name>`; loading into a running browser (`kernel browsers extensions upload <session_id> <dir>`) restarts Chromium and may disrupt CDP | docs extensions (untested) |

## B7. Chrome policy and extension-only needs

**If** you must set homepage, bookmarks, download or popup behavior -> **Do** pass `chrome_policy` at create (payload cap 5 MiB). **Avoid** policies for extensions, proxy or CDP/automation: Kernel manages them and rejects them. -> **Source** https://www.kernel.sh/docs/browsers/chrome-policies (untested in lab)

## B8. GPU

**If** the page needs WebGL, canvas-heavy rendering or video -> **Do** `gpu: true` with headful. **Avoid** `gpu: true` for anything else (it is billed separately and never goes to standby), or with `headless: true`. Unverified: GPU in pools was not tested. -> **Source** https://www.kernel.sh/docs/browsers/gpu-acceleration, probe LEAD gpu-gate

- Lab (LEAD, Hobbyist plan): `create({ gpu: true, headless: false })` returned 403 `insufficient_plan` "GPU acceleration requires an active paid Start-Up or Enterprise plan"; nothing was created. `gpu: true` with `headless: true` returns 400 `invalid_request` "headless mode is not supported with gpu=true" (checked first).
- Branch on the 403 code, then check `kernel org entitlements -o json` before retrying. A GPU browser itself was never created in the lab (unverified: performance, `video_memory`).
- Regional GPU support is not yet available (regions docs); the default region is us-east.

## B9. Region

**If** automation code or viewers sit far from us-east -> **Do** set `region` at create (`'us-east' | 'us-west' | 'eu-west' | 'ap-southeast'` in the SDK type; the docs list the first, third and fourth; non-default regions need an eligible plan). **Avoid** treating it as data residency or changing it later: it is fixed at create, create a new browser instead. -> **Source** https://www.kernel.sh/docs/browsers/regions, SDK types (untested in lab; `region` came back in the create response)

- Default is us-east. Regions cover CPU browsers, pools and Managed Auth; GPU, Apps and invocations are not covered yet.
- SDK 0.128.0 adds `location` (`locale`, `timezone`) on create. Live (SDK version of that run not recorded; the lab pinned 0.127.0): the default response carries `locale_source: 'metro'` and the page matches; setting an override returned 400 "browser location is not enabled for this organization" (org-gated, not visible in entitlements). Source: probe LEAD location. The default location already matches a normal human user (timezone and locale come from the browser's region metro); an override is org-gated.

## B10. Create speed

**If** you are tempted to cache or pre-warm browsers "for speed" -> **Do** create per task; the docs quote 30 ms p50 server-side, but the lab saw a client-side create p50 of about 333 ms (max 836 ms, n=5) and delete about 200 ms. **Avoid** pooling a default config for latency alone (`references/scale.md`). Slow creates usually mean a non-default config (viewport, extensions, kiosk, profile) or the create rate limit (429; the SDK retries twice and honors `Retry-After`). -> **Source** https://www.kernel.sh/docs/browsers/performance, https://www.kernel.sh/docs/browsers/faq, probe P01

## B11. Live view URL

**If** the agent must show the user the browser, or let them step in -> **Do** read `browser_live_view_url` from a headful create and hand it to the user over a trusted channel; append `?readOnly=true` for a watch-only view (docs). **Avoid** logging it, committing it or putting it in a frontend bundle: it is a credential, and it dies when the browser is deleted or times out. -> **Source** https://www.kernel.sh/docs/browsers/live-view (headful URL present: lab P18; `readOnly` link not opened in lab). For an existing browser id, `kernel.browsers.retrieve(id)` returns `browser_live_view_url` too (`references/observe.md` O6)

Embedding in an iframe and parent-frame events: see the docs page.

## B12. Existing browser, tags, names

**If** a run may crash before cleanup -> **Do** tag at create (`tags: { run: '<id>' }`) and reconcile with `kernel.browsers.list({ status: 'active' })` or `kernel browsers list --status active --tag run=<id> -o json`. `name` works anywhere an id does (uniqueness among active sessions: unverified). **Avoid** relying on retries to be safe: create is not idempotent and the SDK sends no idempotency key (`references/sdk-client.md`). -> **Source** probes P01 and P02 (tag and list filters used), `references/api-map.md`

## B13. Agent next to Chromium

**If** the agent's loop is chatty with the page and latency matters -> **Do** upload the agent with `browsers.fs` and run it inside the VM with `browsers.process.exec` or `browsers.process.spawn`. **Avoid** running it outside the VM when it needs low-latency access to the browser. -> **Source** https://www.kernel.sh/docs/browsers/process-execution, https://github.com/kernel/cookbooks/tree/main/integrations/fx-colocated-agent (untested in lab)

## Deprecated on browsers

**If** you are about to use a removed browser field -> **Do** use the replacement. **Avoid** `proxy_id` and `disable_default_proxy` on `browsers.create`: use `proxy: { mode: 'direct' | 'default' }` or `proxy: { id | name }` (`references/unblock.md`). **Avoid** persistent browsers: use profiles (`references/profiles.md`). **Avoid** `max_pooled_sessions`: use `max_concurrent_sessions`. **Avoid** `agents.auth`: use Managed Auth (`references/logins.md`). **Avoid** datacenter proxies (removed): use `isp` first. -> **Source** `references/does-not-exist.md`

---

Verified in lab 2026-10-20 on @onkernel/sdk 0.127.0; types re-checked on 0.128.0

Probes: P01 (create/execute/delete shapes, latency, retrieve after delete: confirmed; docs' 30 ms create latency: refuted client-side; headful live view URL: confirmed present in P18), P02 (close() does not delete, reconnect, timeout reaping: confirmed; standby status field: unclear, absent from responses), P04 (headless memory 1/2/4 and rejection: confirmed; "memory is headful-only" and "viewport matches page" and "viewport update restarts Chromium": refuted; headful 16GiB, `force: true`, kiosk, extensions, chrome_policy: untested), LEAD (GPU 403 gate and `location` gate: confirmed; GPU browser itself and regions other than default: untested). Not tested: 1 h CDP socket lifetime, live view `readOnly`, `us-west`.
