# Audit checklist: judgments a regex cannot make

Used by `/kernel:audit`. One row per judgment. Each is: **If** you see this -> **Look for** the evidence -> **Fix** -> **Source**. Report a row only with a `file:line`. Single-regex rules (deprecated names, key literals, logged URLs) come from `kernel-plugin lint` (`rules/stale-api.tsv`); this file covers what the linter misses and how to judge its hits.

Severity guide: **high** = leaks money, slots, secrets or data now; **med** = breaks under load or on failure; **low** = hygiene.

| Id | Severity | Situation |
|---|---|---|
| C01 | high | A browser is created and not deleted on every path |
| C02 | high | `browser.close()` is the cleanup |
| C03 | med | `newContext()` after `connectOverCDP` |
| C04 | high | A literal key or credential in code or history |
| C05 | med | A long job runs as a synchronous invoke |
| C06 | high | A retry can repeat a side effect |
| C07 | high | A pool lease is reused after per-user work |
| C08 | med | More than one writer for one profile |
| C09 | high | A payment is retried or "recovered" |
| C10 | low | No telemetry or replay where failures get debugged |
| C11 | med | A CDP, live-view, replay or hosted-login URL leaves the process |
| C12 | high | A Kernel key can reach a frontend bundle |
| C13 | med | `projectID` / `KERNEL_PROJECT` misuse |
| C14 | low | Two Kernel MCP servers |
| C15 | high | `.env` tracked by git |
| C16 | med | Browsers created without a deliberate `timeout_seconds` or run tag |
| C17 | med | Pool `acquire` result used without a null check |

## C01. No deletion on every code path

**If** code calls `kernel.browsers.create`, `browserPools.acquire` or an app action that creates a browser. **Look for** a `deleteByID` (or pool `release`) that runs on success, on throw, on early `return`, and on timeout. Typical miss: delete placed after the work in the happy path, or inside `try` instead of `finally`; a `create` in one module and the cleanup owned by nobody; an app action that creates a browser and returns it still running. **Fix** wrap from the line after `create` in `try { ... } finally { await kernel.browsers.deleteByID(browser.session_id) }`. Treat a 404 from `deleteByID` as success (the timeout may have reaped it first). **Avoid** relying on `timeout_seconds` to clean up: a browser holds its concurrency slot until deleted or reaped, and a profile marked `save_changes` is saved on delete or timeout only. **Source** https://www.kernel.sh/docs/browsers/termination; lab P01 (`deleteByID` is the only delete method; `kernel.browsers.delete` is undefined), P02 (a reaped browser makes `deleteByID` 404).

```ts
// lab P01 create-delete.ts (trimmed): create, then delete in finally
const browser = await kernel.browsers.create({ timeout_seconds: 60, tags: { run: runId } });
try {
  // ... work ...
} finally {
  await kernel.browsers.deleteByID(browser.session_id);
}
```

App actions are the same trap: lab P17 showed a browser created inside an action stays active after `invocations.update(id, { status: 'failed' })` (still active 10 s later; only `invocations.deleteBrowsers(invocationId)` removed it). **Look for** `kernel.browsers.create` inside `app.action` handlers with no `finally`, and pass `invocation_id` so `deleteBrowsers` can find it.

## C02. Close-only cleanup

**If** the cleanup is `browser.close()`, `context.close()` or `await pw.close()` from `playwright-core`. **Look for** a `connectOverCDP` whose only teardown is `close()`. **Fix** keep `close()` if you like, but add `deleteByID` in `finally`. **Avoid** reading `close()` as "done": lab P02 listed the browser `active` at 0.9 s after the first `close()`, and again at 25 s and 30 s after a reconnect and a second `close()`, and a reconnect to the same `cdp_ws_url` found the cookie still there. For a profile writer, `close()` does not save: lab P09 left `updated_at` unchanged after closing the client and waiting 10 s; it moved only when the browser was deleted. **Source** lab P02, P09; https://www.kernel.sh/docs/browsers/termination.

## C03. `newContext()` after a CDP connect

**If** code does `chromium.connectOverCDP(browser.cdp_ws_url)` then `browser.newContext()`. **Look for** a login, profile, extension or cookie that the page then lacks. **Fix** use `pw.contexts()[0]` and `ctx.pages()[0]` (both exist on a fresh browser). For new code prefer `kernel.browsers.playwright.execute`, which has no context to get wrong. **Avoid** `newContext()` when state matters: lab P02 set a cookie in `contexts()[0]` and `newContext()` saw none. (That a profile and extensions live only in `contexts()[0]` is inferred from this isolation, not tested.) `newContext()` is fine when isolation is the goal. **Source** lab P02; https://www.kernel.sh/docs/apps/develop.

## C04. Literal keys and credentials

**If** a string that looks like a Kernel key (`sk_<uuid>.<token>`, linter id K019), a site password, a card number or a TOTP seed appears in source, a test, a README, a Dockerfile or CI config. **Look for** `new Kernel({ apiKey: '...' })`, `--api-key`, keys in `docker-compose` or workflow files, passwords in prompts or `fill` payloads. **Fix** `new Kernel()` reads `KERNEL_API_KEY`; keep the key in the environment or a gitignored `.env`; move site credentials to a vault or Managed Auth; rotate any key that was committed (history keeps it). The linter ignores a gitignored `.env`, so a K019 hit is a real exposure. **Avoid** printing the literal in your report. **Source** https://www.kernel.sh/docs/vaults/overview, https://www.kernel.sh/docs/info/api-keys; the shipped SDK `client.js`.

## C05. Synchronous invoke for long work

**If** `kernel.invocations.create({ app_name, action_name, version, payload })` is awaited and its `output` is used, or a CLI `kernel invoke` runs in a foreground step, for work that can take minutes (a crawl, a batch, a login flow with MFA). **Look for** missing `async: true`; a comment like "takes ~20 minutes" next to a sync call. **Fix** invoke async, then follow or poll:

```ts
// lab P17 async-invoke.ts (trimmed; ran ok)
const invocation = await kernel.invocations.create(
  { app_name, action_name, version, payload: JSON.stringify(body), async: true, async_timeout_seconds: 120 },
  { maxRetries: 0 },
);
const stream = await kernel.invocations.follow(invocation.id);
for await (const evt of stream) {
  if (evt.event === 'invocation_state' && evt.invocation.status !== 'queued' && evt.invocation.status !== 'running') break;
}
const done = await kernel.invocations.retrieve(invocation.id); // done.status, done.output
```

**Avoid** assuming the CLI returns immediately: lab P17 showed `kernel invoke` blocks and streams until the run ends (`--sync` returns one JSON object). After `kernel deploy --version v1`, `kernel invoke` without `-v v1` fails with `deployment_not_found` (400), (the default version is `latest` per the docs; the lab recorded only the 400). The doc line that sync invokes time out at 100 s is (unverified: the lab did not run a sync SDK invoke past 100 s). **Source** lab P17; https://www.kernel.sh/docs/apps/invoke.

## C06. Retries on side-effecting calls

**If** a call that is not idempotent runs under the SDK default (`maxRetries` 2) or inside your own retry loop: `invocations.create`, deploys, REPL / code execution, fill-and-submit, payments, search with cost, browser or pool creation. **Look for** a bare `kernel.invocations.create(params)` with no second argument; `for (let i = 0; i < 3; i++) try { create }`; a `p-retry` or `while (429)` wrapper around those calls. **Fix** pass `{ maxRetries: 0 }` per request; to recover from an ambiguous failure, tag the resource with a run id (`tags`, `name`) and `list` before creating again. **Avoid** counting on an idempotency key: the SDK sends none. The SDK retries connection errors, timeouts, 408, 409, 429 and any status >= 500, so a timed-out invoke can run twice (read from SDK source; no real 5xx was provoked in the lab, so this is (unverified in lab)). Lab P17 used `{ maxRetries: 0 }` on invoke without incident. **Source** `../../kernel/references/sdk-client.md`; the shipped SDK `client.js` (status 408 handled near line 441).

## C07. Pool reuse after per-user work

**If** a browser pool lease did work for one user, tenant or login and is released with `reuse: true` (or the default). **Look for** `browserPools.release(pool, { session_id, reuse: true })` after logins, carts, form fills or `save_changes` profiles. **Fix** release with `reuse: false` after any per-user work so the next acquirer gets a fresh browser. **Avoid** `reuse: true` for anything but identical, stateless work: lab P15 set a cookie in lease 1, released with `reuse: true`, and the next lease got the same `session_id` with the cookie present; with `reuse: false` lease 4 was a new session with no cookie (the fresh browser took about 4 s to refill). **Source** lab P15; https://www.kernel.sh/docs/browsers/pools.

```ts
// lab P15 04-release-reuse-cookie-leak.ts (trimmed)
await release(b3.session_id, false); // helper: kernel.browserPools.release(POOL, { session_id: sessionId, reuse })
```

## C08. Multiple writers on one profile

**If** more than one worker, request or script can start a browser with `profile: { name, save_changes: true }` for the same profile, or a long-lived writer runs while another job loads it. **Look for** `save_changes: true` in code that runs per request or in parallel; one profile name shared by all users (`profile: { name: 'shop' }`); a rename of a profile that a running browser uses. **Fix** one writer per profile at a time (one profile per user, or a single setup job as the only writer); every other consumer loads the profile without `save_changes`. Before starting a writer, check `kernel.browsers.list({ status: 'active', query: profile.id })` for `profile_save_changes`. **Avoid** assuming merges: lab P09 ran writers one after another and the last writer won (login, then logout, then a third browser saw logged-out). Concurrent racing writers were not tested (unverified). A profile saves on delete or timeout, not on `close()`. **Source** lab P09; https://www.kernel.sh/docs/browsers/profiles/concurrency.

## C09. Payment retries

**If** code authorizes, fills a card, submits a checkout, or calls `1pw_fill`, and any of it sits in a retry, a `catch` that tries again, a queue with redelivery, or a fallback from `fill` to typing the number. **Look for** retries wrapping the checkout step; a handler that re-runs after a timeout or after the browser was deleted. **Fix** make the payment step run at most once; on a timeout or unknown result, stop and reconcile with the merchant or the Kernel payment events before any new attempt; keep the vault id, card key and browser id until reconciled. **Avoid** retrying an indeterminate payment: deleting the browser, a timeout or a missing event does not cancel it. Payments were never run in the lab (real money): this row is from the docs (unverified in lab). **Source** https://www.kernel.sh/docs/browsers/payments; `../../kernel/references/vaults-payments.md`.

## C10. Telemetry missing where failures are debugged

**If** the project runs unattended browsers (cron, queue, app actions) and has no way to explain a failed run. **Look for** `browsers.create` with no `telemetry` option, no run `tags`, and no replay in a headful flow whose failures matter. **Fix** create headful with `telemetry` enabled for console, network and page on top of the defaults, tag with a run id, and delete in `finally`. Events stay readable after the browser is deleted (read them with `kernel browsers telemetry events <id> --since <created_at> --all`). **Avoid** turning telemetry on only after a failure (it records from when it is enabled; not lab-tested), and `headless: true` when you want a replay (replay start returns 400). Network capture keeps `Authorization` and `Cookie` headers (docs: browsers/telemetry/categories, not lab-tested): do not enable it for flows that carry secrets without a retention plan. **Source** `../../kernel/references/observe.md` (lab P18, P19); https://www.kernel.sh/docs/browsers/telemetry/overview.

## C11. URL credentials leaving the process

**If** a `cdp_ws_url`, `webdriver_ws_url`, `browser_live_view_url`, `replay_view_url`, `hosted_url` or `handoff_code` is logged, stored, sent to the frontend, put in a prompt, or passed as a CLI argument. **Look for** `console.log(browser)`, `JSON.stringify(browser)`, `logger.info({ session })`, error handlers that print the whole response, URLs in analytics, and a live-view URL given to the browser tab of a user who should not control the session. Linter K016 catches the direct `log(...cdp_ws_url...)` form; read for the indirect ones. **Fix** log `session_id` only; mask URLs as `...?jwt=***`; hand a live-view URL only to the user it belongs to, over a channel you control. **Avoid** logging raw error messages from `retrieve`: the 404 message embeds the session id (lab P01). The sample app from `kernel create` also logs `browser_live_view_url` in an action (lab P17): strip it. **Source** https://www.kernel.sh/docs/browsers/live-view; lab P01, P17.

## C12. Key in a frontend bundle

**If** a Kernel key can reach client code. **Look for** `NEXT_PUBLIC_`, `VITE_`, `REACT_APP_`, `EXPO_PUBLIC_`, `NUXT_PUBLIC_` or `GATSBY_` prefixes on a name containing `KERNEL` and `KEY` (linter K015); `new Kernel(...)` in a file under `app/`, `pages/`, `src/components/`, or any `'use client'` file; a Kernel key passed to a React component prop. **Fix** call Kernel from a server route and give the browser a result, not the key. For Managed Auth in React, the backend starts the login and hands the component only the connection `id` and a one-time `handoff_code` (https://www.kernel.sh/docs/auth/react); the key stays on the server. **Avoid** "it is only a dev key": a bundled key is public to every visitor. **Source** https://www.kernel.sh/docs/auth/react; https://www.kernel.sh/docs/info/api-keys.

## C13. Project scoping misuse

**If** code sets `projectID` or reads `KERNEL_PROJECT`. **Look for** `projectID: process.env.KERNEL_PROJECT`; `X-Kernel-Project-Id` set by hand; a project-scoped key used with a different project. **Fix** `projectID` takes an ID only. `project` takes an ID or an exact name and is what the CLI's `--project` and `KERNEL_PROJECT` mean, so use `new Kernel({ project: process.env.KERNEL_PROJECT })` (the SDK itself does not read `KERNEL_PROJECT`). **Avoid** one org-wide key for every tenant; a conflicting project header returns 403 (docs; the 403 was not run in the lab, unverified). **Source** https://www.kernel.sh/docs/info/projects; `../../kernel/references/account.md` (lab P23).

## C14. Duplicate Kernel MCP servers

**If** `claude mcp list` shows two servers that point at `https://mcp.onkernel.com/mcp`: the one this plugin bundles (`plugins/kernel/.mcp.json`) and one added by `kernel mcp install --target claude-code`. **Look for** it in the environment step, not in code. **Fix** keep one; remove the other with `claude mcp remove <name>` (tell the user, do not run it). **Avoid** two tool sets under different prefixes: the model sees duplicate tools. (That two servers appear is inferred from the prefix naming, not tested.) **Source** https://www.kernel.sh/docs/reference/cli/mcp; `../../kernel/references/mcp.md`.

## C15. `.env` tracked by git

**If** `git ls-files` lists `.env`, `.env.local`, `.env.production` (not `.env.example`). **Look for** the file name only, then a count of `KERNEL_API_KEY` lines with `git grep -c`. Never print the contents. **Fix** `git rm --cached <file>`, add it to `.gitignore`, rotate any key it held (history keeps it). A gitignored `.env` is the supported place for a key (the linter drops K019 there). **Source** https://www.kernel.sh/docs/info/api-keys.

## C16. No deliberate timeout or run tag

**If** `browsers.create` has no `timeout_seconds`, a very long one (the sample app uses 3600), or no `tags`. **Look for** a browser created at module load or kept in a module-level variable "to save time". **Fix** create per task, set `timeout_seconds` on purpose, tag with a run id so leaks are findable (`kernel browsers list --tag run=<id>`). The timeout counts from idle (the browser must have no client): lab P02 reaped a `timeout_seconds: 10` browser between 5 and 17 s after create across three runs, and a 120 s browser stayed active for at least 30 s after the client left. **Avoid** a long timeout as a substitute for deleting (C01). Create takes about 330 ms client-side (lab P01, n=5), so caching a browser for speed buys nothing. **Source** lab P01, P02; https://www.kernel.sh/docs/browsers/standby.

## C17. Pool `acquire` result not null-checked

**If** `kernel.browserPools.acquire(pool, ...)` result is used directly. **Look for** `.cdp_ws_url` or `.session_id` read on the return value with no `if (!browser)`. **Fix** null-check, then back off or fail with a clear error. **Avoid** assuming a browser is ready: lab P15 got HTTP 204 (no `Retry-After`) when the only browser was leased; the SDK return type is `BrowserPoolAcquireResponse | null`. Also release in `finally` (C01). A pool of size N holds N concurrency slots while it exists. **Source** lab P15; https://www.kernel.sh/docs/browsers/pools.

## Reading linter hits

| Id | Avoid (what the linter found) | Use instead | Judge before reporting |
|---|---|---|---|
| K001, K002 | `disable_default_proxy`, or `proxy_id` on a browser | `proxy: { mode: 'direct' }`, or `proxy: { id }` | `proxy_id` is still valid on browser pools: check the call target before reporting K002 |
| K003 | the removed datacenter proxy type | `type: 'isp'` | It returns 400 now (lab P14) |
| K004 | the removed browser persistence options | a profile with `save_changes`, deleted explicitly (C08) | Also drop any persistence id the code stored |
| K005 | the old pool size field | `max_concurrent_sessions` | The old name returns 400 (changelog) |
| K006 | the old agents auth API | `auth.connections` | Check `package.json` SDK version |
| K015, K016, K019 | public-bundle key variable, logged URL, key literal | see C12, C11, C04 | Quote file:line only |
| other K0xx | see the linter message | the linter replacement | Confirm the line is code, not a comment |

A hit inside a comment, a string that documents the old name, or a test fixture is not a finding. A hit in `node_modules`, `dist` or a lockfile is noise; skip it.

> Verified in lab: 2026-10-20, @onkernel/sdk 0.127.0 (lab install now 0.128.0), kernel CLI 0.49.0 (self-reports 0.47 in places, see P20). Probes: P01 (deleteByID only, 404 after delete, error shape: confirmed; create latency: measured), P02 (close() does not delete, reconnect, newContext isolation, timeout reaping: confirmed), P09 (CDP close does not save, sequential last-writer-wins, `profile_save_changes` in list: confirmed; racing writers: untested), P15 (reuse:true keeps cookies, reuse:false fresh, acquire 204 -> null: confirmed; pool-level profile read-only: untested), P14 (removed datacenter proxy returns 400), P18 and P19 (telemetry and replay, C10), P23 (project scoping, C13), P17 (async invoke + follow, CLI invoke blocks, `-v` required, update(failed) does not reap, deleteBrowsers: confirmed). Docs-only, not lab-tested: payments (C09), SDK retry on real 408/409/429/5xx (C06), sync invoke past 100 s (C05), project 403 (C13), duplicate MCP servers (C14), `claude mcp list` output, React token flow (C12). The linter output was run on the bad-kernel-app fixture only.
