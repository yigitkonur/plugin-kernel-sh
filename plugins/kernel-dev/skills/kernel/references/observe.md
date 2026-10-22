# Observe: telemetry, replays, live view

Read this before the first run you might have to debug, and whenever a human must watch or step in. The rule: turn recording on at create time. Kernel cannot record a failure that already happened.

Pick the tool:

| You need | Use |
|---|---|
| Why did run X fail, after the fact | telemetry (events stay readable after the browser is deleted) + a replay |
| React to the page while it runs | telemetry stream |
| A person watches or takes over | live view |
| Events in your own logging backend | OTLP export |
| A video to show someone | replay |
| One frame at a decision point | `kernel.browsers.computer.captureScreenshot` (see `references/control.md`) |

## O1. Anything you may need to debug

**If** a run could fail in a way you must explain later (any agent run, any unattended job). **Do** create the browser headful, with telemetry for console, network and page on top of the defaults, tagged with a run id, and start a replay before the first action. Stop the replay and delete the browser in `finally`. **Avoid** turning telemetry on after the failure (nothing was captured), and a headless browser when you want a replay (400). **Source** https://www.kernel.sh/docs/browsers/telemetry/overview

```ts
import Kernel from '@onkernel/sdk';

const kernel = new Kernel();
const browser = await kernel.browsers.create(
  {
    headless: false,
    timeout_seconds: 300,
    tags: { run: 'run-123' },
    telemetry: {
      enabled: true,
      browser: { console: { enabled: true }, network: { enabled: true }, page: { enabled: true } },
    },
  },
  { maxRetries: 0, timeout: 30_000 },
);
const id = browser.session_id;
let replayId: string | undefined;
try {
  replayId = (await kernel.browsers.replays.start(id)).replay_id;
  const r = await kernel.browsers.playwright.execute(
    id,
    { code: `await page.goto('https://example.com'); return await page.title();`, timeout_sec: 30 },
    { maxRetries: 0, timeout: 40_000 },
  );
  if (!r.success) throw new Error(String(r.error));
} finally {
  if (replayId) await kernel.browsers.replays.stop(replayId, { id_or_name: id }).catch((e) => {
    if (!(e instanceof Kernel.NotFoundError)) throw e; // already stopped or gone: fine
  });
  // a 404 means the timeout already reaped the browser: that is fine
  await kernel.browsers.deleteByID(id).catch((e) => {
    if (!(e instanceof Kernel.NotFoundError)) throw e;
  });
  console.log('debug with:', id); // keep the id, it is the key to everything below
}
```

Facts that change what you do:
- Telemetry costs overhead and captures sensitive data (see O5). Console, network and page attach a CDP collector; do not enable them "just in case" on regulated sites.
- Events are retained 30 days (https://www.kernel.sh/docs/browsers/telemetry/overview).
- Uncaught page errors arrive as `console_error`. There is no `page_error` event.
- Read page errors from telemetry (or console events), not from a `page.on('pageerror')` listener inside `playwright.execute`. Verified live: such a listener, attached before `page.goto`, did not fire for a page's uncaught onload error, while telemetry recorded it as `console_error` (`Uncaught TypeError`, with `source_url`, line and column). A `page.on('console')` listener did catch the page's 404.

## O2. Debug ladder (after the browser is gone)

**If** a run failed and you have a session id. **Do** go in this order; `/kernel-dev:debug-session <id>` runs this ladder for you.

1. The record: `kernel browsers get <id> --include-deleted -o json`. SDK: `kernel.browsers.retrieve(id, { include_deleted: true })`. Without the flag both return 404. A deleted record has `deleted_at` and no `status`.
2. Filtered events, never the whole log:
   ```bash
   kernel browsers telemetry events <id> --since 2026-10-20T00:01:00Z --all --types console_error,network_loading_failed -o json
   kernel browsers telemetry events <id> --since 1h --categories console -o json
   ```
3. Replays: `kernel browsers replays list <id> -o json` (works after delete). The view URL is a credential; do not paste it.
4. Live-only tools (screenshot, logs, process exec) need a live browser. Do not expect them for a deleted one (per the debug skill; untested).

**Avoid**
- The default window. `--since` defaults to 5 minutes before now, so an older session looks empty. Pass an RFC-3339 time or a duration like `1h` (CLI; in SDK code pass an ISO string). `--until` in the future is rejected ("time must not be in the future").
- Dumping all events. A 12-second headful session produced 58 events of 16 types. Filter by `--types` or `--categories`, add `--limit`, use `jq`.
- Trusting the wrong signals (all verified live):
  - A top-level `page.goto` to a page that answers HTTP 500 does throw, `net::ERR_HTTP_RESPONSE_CODE_FAILURE`, so `playwright.execute` returns `success:false`. The message is in the caller's result, not in telemetry.
  - `page.goto('https://x.invalid/')` does not throw. Read `page_*` and `network_*` events and the page title instead of catching.
  - A `fetch` that returns 500 in the page shows up as `network_loading_failed` (`ERR_ABORTED`, `canceled`), not as a `network_response` with status 500.
  - Most `network_loading_failed` noise came from a service worker calling a Kernel-internal endpoint. Look at `data.target_type` and `data.url` before blaming your site.
- Printing the deleted record raw: it carries `cdp_ws_url` and `webdriver_ws_url` keys. Select fields with `jq`.

**Source** https://www.kernel.sh/docs/browsers/telemetry/categories

Event shapes you will filter on:
- Every event, from the CLI (`-o json` gives `{ "events": [ ... ] }`), the SDK (`events()` and `stream()`) and the type declarations, is wrapped as `{ seq, event: { ts, type, category, source, data } }`. `seq` is on the wrapper, `ts` is microseconds. Read `e.event.type` and `e.event.data`, never `e.type`: a filter on top-level `category` or `type` silently matches nothing. The SDK stream loop destructures it as `{ seq, event }`.
- `console_error.data`: `text`, `source_url`, `line`, `column`. `network_loading_failed.data`: `error_text`, `canceled`, `url`, `resource_type`, `target_type`.
- `kernel.browsers.telemetry.events(id, { type: [...], category: [...], since, limit })` filters server-side and pages; iterate it with `for await`. `since` is a string: the SDK types accept an RFC-3339 timestamp or a duration like `5m` (default `5m`), and `new Date(Date.now() - 3600_000).toISOString()` worked live; a duration string through the SDK is untested, so prefer the ISO form in code. `since` is ignored when `offset` is set and cannot combine with `order: 'desc'`.

## O3. React while it runs (stream)

**If** code must react to page events live (wait for settle, count failures, detect captcha solves). **Do** use `kernel.browsers.telemetry.stream(id)`, track `seq`, and on disconnect reopen with `'Last-Event-ID': String(lastSeq)`. Verified live: contiguous seqs with nothing missed after reconnect. **Avoid** assuming order or delivery: the docs say delivery is best-effort and a captcha start can arrive after its result; gaps in `seq` mean dropped events. **Source** https://www.kernel.sh/docs/browsers/telemetry/streaming

```ts
const stream = await kernel.browsers.telemetry.stream(id);
let lastSeq = 0;
try {
  for await (const { seq, event } of stream) {
    lastSeq = seq;
    if (event.category !== 'console') continue; // untested: filter here, see below
    console.log(seq, event.type);
  }
} catch { /* untested; stream ends with "TypeError: terminated" when the browser is deleted */ }
// resume later: kernel.browsers.telemetry.stream(id, { 'Last-Event-ID': String(lastSeq) })
```

Rules:
- **Filter client-side in SDK code.** The SDK `stream(id, { type })` sends `?type=` but every type was received anyway (verified live). `events({ type })` and `events({ category })` do filter. The CLI `--types` filters server-side (confirmed).
- A fresh connection only sees new events. To start from the oldest retained event pass `{ replay: 'all' }` (SDK) or `--replay=all` (CLI); `--seq N` and `--replay` are mutually exclusive. Both untested; read from the SDK types and CLI source.
- Stream end: SDK throws `TypeError: terminated` when the browser is deleted; the CLI exits 1 with empty stderr. Treat both as a normal end. A CLI stream written to a file is complete only after the process exits.
- For "page is ready" use `page_navigation_settled`: it fires once per top-level navigation after DOM content loaded and layout settled, and is independent of `network_idle`, so one hung request cannot stall it. It needs `page_load`, so a page whose `load` never fires emits none. Enable the `page` category. (Docs: https://www.kernel.sh/docs/browsers/telemetry/categories. A live session emitted `page_navigation_settled`, but it was not used as a readiness gate.)
- CLI, filtered (verified live): `kernel browsers telemetry stream <id> --types console_error -o json` emits newline-delimited envelopes.

Captcha events (verified live, `stealth: true` + captcha telemetry, which is in the default set):
- Wait for the solver; do not click the checkbox. Solved runs show `captcha_solve_started`, `captcha_solve_result` (`status: success`), then `captcha_challenge_result` (`status: solved`). A non-stealth browser emitted zero captcha events and never solved. More: `references/unblock.md`.
- Join on `task_id`. In that run only `captcha_challenge_result` carried `challenge_id`; the docs say reCAPTCHA v2 task events can omit it. Read `captcha_provider` and `task_kind`.
- `solved` means the widget cleared, not that the site accepted it. Check the page after.
- **Avoid** reading `captcha_type`: it is deprecated and read `other` on solve events.
- The token appeared about 5 s to 67 s after navigation across three stealth runs; allow a bounded wait, then fall back to page state.

## O4. Central backend (OTLP export)

**If** events must land in your own logging backend (Honeycomb, a collector). **Do** create a destination once with an organization-scoped key (`kernel.telemetry.destinations.create({ name, endpoint, headers })`), then bind it at create with `telemetry.export.otlp.destination: { name }` and capture enabled in the same request. CLI: `kernel telemetry destinations create|get|update|list|delete`, and `kernel browsers create --telemetry=console,network --telemetry-export-otlp <name>`. Check health with `destinations.retrieve(name)` (`consecutive_failures`, `last_export_at`). **Avoid**
- A project-scoped key for create/update/delete of destinations (403); projects can list, retrieve and select one.
- Expecting to change it later: `browsers update` ignores `telemetry.export`; the destination is fixed at create.
- Browser pools: pool create, update and acquire reject `telemetry.export` with 400.
- A signal path in the endpoint (`/v1/logs` is rejected; Kernel appends it). Records are OTLP logs only. `screenshot` and `monitor` are not exported.
- Embedding the ingestion key anywhere but an env var; header values are write-only.

**Source** https://www.kernel.sh/docs/browsers/telemetry/export. (unverified: no destination was created; shapes are from the docs, SDK types and CLI source.)

## O5. Regulated or sensitive data

**If** the site handles PHI, card data, credentials or personal data. **Do**
- Use the operational categories only (`control`, `connection`, `system`, `captcha`); skip `network`, `console`, `page`, `interaction`, `screenshot`.
- Keep secrets out of `playwright.execute` code. The code runs in the VM, so a value from your process can only reach it inside the code string, and `control` records that string in `api_call.data.code` (capped at 8 KB; SDK type doc). Use vault fill or Managed Auth for real credentials. If a throwaway login must go through `code`, create that browser with `telemetry: { browser: { control: { enabled: false } } }` (`references/logins.md`).
- For zero retention, talk to Kernel: ZDR is enterprise-only, set per org via support, and suppresses recordings, live view streams and telemetry (https://www.kernel.sh/docs/info/zero-data-retention). Under a BAA, `network`, `console` and `screenshot` are disabled by Kernel (https://www.kernel.sh/docs/browsers/telemetry/categories, Data sensitivity); keep regulated values out of code you submit.

**Source** https://www.kernel.sh/docs/browsers/telemetry/categories (Data sensitivity); https://www.kernel.sh/docs/info/zero-data-retention.

**Avoid** reading `telemetry.storage.enabled: false` (CLI `--telemetry-storage off`) as ZDR. It only stops persisting to Kernel storage, it requires an OTLP destination, and it cannot change after create (SDK types, CLI help). Events then live on the stream and in your backend, which may be worse for you. `network` captures `Authorization` and `Cookie` headers and bodies; treat stored telemetry like the page itself. Source: https://www.kernel.sh/docs/browsers/telemetry/categories (Data sensitivity).

## O6. Human watches or steps in (live view)

**Getting the URL.** A headful create returns `browser.browser_live_view_url`; a headless create omits it. For an EXISTING browser id, call `kernel.browsers.retrieve(id)`: the response carries `browser_live_view_url` (verified live on a headful browser; undefined means headless or not running). CLI: `kernel browsers view <id-or-name>`.

**Case 1: read-only watcher.** **If** a person only watches. **Do** append `?readOnly=true` to the URL (the docs claim it; the URL parses and round-trips, but it was never opened in a browser, so read-only behaviour is untested). Set it with `new URL(u).searchParams.set('readOnly', 'true')`. Toggle later without reload via `KERNEL_SET_READ_ONLY` (below).

**Case 2: person takes over** (MFA, a captcha you will not automate, an approval). **Do** hand over the plain URL, with no `readOnly`.

**Both cases, if you embed the view in your own page:**
- Embed it in an iframe on your own page, and gate your UI on the parent-window message `KERNEL_PLAYING` (frames are rendering). `KERNEL_CONNECTED` only means signaling is up. Start a timer when you mount the iframe, and branch on `KERNEL_CONNECTION_FAILED` / `KERNEL_CONNECTION_TIMEOUT` `reason` (remount once for `transport`; for `peer` and `unsupported` show a persistent fallback message rather than remounting blindly). Do not gate on the timeout event alone.
- Allow the live-view origins in your CSP (`frame-src` and `connect-src` for `*.onkernel.com:8443` and `*.kernel.sh:8443`, `wss:` for connect) and add `allow="autoplay; clipboard-read; clipboard-write"` for clipboard. The exact directives are on the docs page.
- Toggle interactivity without reloading by posting `KERNEL_SET_READ_ONLY`; it needs a recent browser image and a resolvable `document.referrer`.

**Handing the link to a teammate who just opens it in a tab (no iframe).** **Do** send the URL through a private channel (never print it into chat logs or output), say it is a live, controllable browser until deleted or timed out, and for a watcher append `readOnly=true`. (unverified: whether the link renders in a plain tab, and whether `readOnly=true` actually blocks clicks. The ledger only shows the URL is present and the option round-trips; it was never opened.) **Avoid** promising a watcher cannot interfere until someone has opened the read-only link and tried to click.

**Avoid**
- Treating the URL as public. It is a token for a live, controllable browser: do not log it, send it to a frontend you do not control, or put it in an LLM prompt. It becomes invalid when the browser is deleted or times out.
- Headless browsers: `browser_live_view_url` is absent from a headless create and present on a headful create. Create headful when anyone may need to watch.
- Expecting the browser to idle out while someone watches: a connected live view client keeps the browser out of standby, so the timeout does not start (https://www.kernel.sh/docs/browsers/standby).
- Exposing the URL while connected: a connected live view keeps the browser billing.
- Kiosk mode (`kiosk_mode: true`, fullscreen view) for latency-sensitive handoffs: it restarts Chromium and takes seconds; the docs suggest a pool (https://www.kernel.sh/docs/browsers/live-view). Untested.

**Source** https://www.kernel.sh/docs/browsers/live-view.

## O7. Replays

**If** you want a video of the run (post-mortem, handoff, audit). **Do** create headful, `replays.start(id)` before the first action, `replays.stop(replayId, { id_or_name: id })` before you delete, then `list` until `finished_at` is set, then `download`, all before `deleteByID`. You may start several replays per browser; each has its own `replay_id`. **Avoid**
- `replays.stop(rid, { id })` as the docs show. It throws client-side ("Path parameters result in path with invalid segments"). `stop` and `download` take `{ id_or_name }`; `start` and `list` take the id positionally.
- A headless browser: `replays.start` returns 400 `invalid_request` "headless browsers don't support replays at this time".
- A fixed sleep. Poll `finished_at`, and also handle HTTP 202 on download (a troubleshooting note reports 202 plus `Retry-After` while finalizing, not found in the Kernel docs pages; 200 came back immediately in 2 samples and never a 202, so keep the code path).
- Deleting before you stop. Stop first, then delete (do both in `finally`, in that order).
- Sharing `replay_view_url`; it is sensitive.

```ts
import { writeFileSync } from 'node:fs';

const ignoreNotFound = (e: unknown) => { if (!(e instanceof Kernel.NotFoundError)) throw e; };
const opts = { maxRetries: 0, timeout: 30_000 };
const replay = await kernel.browsers.replays.start(id, {}, opts);
try {
  // ...drive the page...
  // order matters: stop, wait for finished_at, download, and only then delete the browser
  await kernel.browsers.replays.stop(replay.replay_id, { id_or_name: id }, opts);
  for (let i = 0; i < 60; i++) {
    const hit = (await kernel.browsers.replays.list(id)).find((r) => r.replay_id === replay.replay_id);
    if (hit?.finished_at != null) break;
    await new Promise((r) => setTimeout(r, 1000));
  }
  const dl = () => kernel.browsers.replays.download(replay.replay_id, { id_or_name: id }).asResponse();
  let res = await dl();
  for (let i = 0; res.status === 202 && i < 30; i++) { // still finalizing: wait Retry-After, bounded
    await new Promise((r) => setTimeout(r, Number(res.headers.get('retry-after') ?? '2') * 1000));
    res = await dl();
  }
  if (!res.ok) throw new Error(`replay download failed: HTTP ${res.status}`);
  writeFileSync('replay.mp4', Buffer.from(await res.arrayBuffer()));
} finally {
  // stop (only NotFound is ignored: already stopped or gone), then delete last, after the file is on disk
  try { await kernel.browsers.replays.stop(replay.replay_id, { id_or_name: id }, opts); }
  catch (e) { // other stop failure: rethrow without deleting, so an unfinished replay is not lost (the timeout ends the browser)
    if (!(e instanceof Kernel.NotFoundError)) { console.error('replay stop failed; browser', id, 'kept'); throw e; }
  }
  await kernel.browsers.deleteByID(id, { timeout: 15_000 }).catch(ignoreNotFound);
}
```

After the browser is deleted, a replay that was stopped first can still be listed (`finished_at` set) and downloaded (200, video/mp4; verified live). Stop it before you delete; the snippet downloads first so you do not depend on this. The download snippet's status, polling and `Buffer` read were verified live (200, video/mp4, about 272 KB for 10 s, video only, no audio); the whole create, replay and write-file flow ran again as written (200 on the first try). The 202 retry loop has never run, because no download returned 202. CLI (from the docs, untested): `kernel browsers replays start|stop|list|download`. Managed auth logins can record too (https://www.kernel.sh/docs/auth/configuration#record-sessions-for-debugging). Source: https://www.kernel.sh/docs/browsers/replays.

## O8. Secrets in telemetry

**If** you capture `control` (on by default). **Do** use vaults or Managed Auth for site logins (`references/logins.md`, `references/vaults-payments.md`); for a throwaway login whose password must travel in `code`, turn `control` off on that browser (`control: { enabled: false }`). **Avoid** secrets in `playwright.execute({ code })` with `control` on: the code is stored in telemetry as `api_call.data.code`, and a value embedded with `JSON.stringify` is part of that code. Typed text is not captured by `cdp_command` (lengths only), and password fields are suppressed in `interaction_*` events. (api_call code capture: docs and SDK type doc, not read back live). Source: https://www.kernel.sh/docs/browsers/telemetry/categories.

## O9. Choosing categories at create

**If** you choose categories. **Do** list every category you need in the create call and read the create response's `telemetry.browser` to see what is actually on. **Avoid** relying on "exactly those categories": the docs and CLI help say selection is opt-in, but live behavior differs. A create with only `console` (and with console, network, page) came back with `captcha`, `connection`, `control`, `system` also enabled; the operational defaults always layer on (verified live). Consequences:
- A console-only session still records `cdp_connect`, `cdp_disconnect` and `cdp_command` events, but no `page_*` or `network_*` events (after navigation).
- To keep a default category off, set it explicitly: `captcha: { enabled: false }` (type-level, unverified).
- `platform` is off by default; enable it only to debug profile saves, replays or session setup.
- High-volume noise: `control.cdp.excluded_methods: ['Input.dispatchMouseEvent', 'Page.captureScreenshot']` omits those from telemetry only (untested).
- Update semantics (docs, untested): a category list patches the current selection; `{ enabled: true }` resets it to the default set plus what you pass; `{ enabled: false }` stops capture. CLI: `kernel browsers update <id> --telemetry=off`.

**Source** https://www.kernel.sh/docs/browsers/telemetry/overview.

Categories in one line each: `control` (api_call, cdp_command), `connection` (cdp_connect/disconnect, live_view_connect/disconnect), `system` (system_oom_kill, service_crashed), `captcha` (3 captcha_* types), `platform` (platform_api_call), `console` (console_log, console_error), `network` (network_request, network_response, network_loading_failed, network_idle, proxy_error), `page` (page_navigation, page_load, page_navigation_settled, page_crashed, ...), `interaction`, `screenshot` (periodic images, highest exposure). Full list: https://www.kernel.sh/docs/browsers/telemetry/categories.

## App invocation logs

**If** the code runs as a Kernel App. **Do** use `kernel.invocations.follow(invocationId)` live; for past output the CLI needs the invocation id (`kernel logs <app> -i <invocation_id>`; `--since` alone printed only headers when tried). See `references/apps.md`. Source: https://www.kernel.sh/docs/apps/logs.

Verified live 2026-10-20 (Hobbyist plan); types re-checked on @onkernel/sdk 0.129.0. Evidence ledger: https://github.com/yigitkonur/plugin-kernel-sh/blob/main/verified-facts.md
