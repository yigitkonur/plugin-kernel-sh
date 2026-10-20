# Scale: concurrency, pools, queueing

Read this when you run many browsers, hit a 429 on create, or are about to create a browser pool. Default answer: on-demand `browsers.create`, delete in `finally`, a queue in front. Pools are the exception, not the next step after "it works".

Three separate limits, easy to confuse (https://www.kernel.sh/docs/browsers/concurrency-and-limits):

| Limit | What it caps | What you do about it |
|---|---|---|
| Concurrency | Browsers alive at once, org-wide (plus optional per-project caps) | Delete browsers when done; preflight; queue |
| Create rate | How fast `browsers.create` may be called | Queue on your side; or use a pool (acquire is exempt) |
| Per-browser resources | Memory = how many tabs / how heavy a page | More browsers, not more tabs; set `memory` |

## S1. Default: on-demand

**If** you are building, scaling, or config differs per user or task -> **Do** `kernel.browsers.create` per task, `deleteByID` in `finally`. Put a queue in front when volume exceeds your concurrency. -> **Avoid** a pool "just in case"; caching browsers for speed (a create was 315-747 ms in the lab, n=3, API call only). -> **Source** https://www.kernel.sh/docs/introduction/scale, probe P15 (on-demand create timing).

## S2. When a pool is worth it

**If** every run uses the same config AND at least one of: traffic is steady enough to keep the pool utilized, `browsers.create` returns 429 at your volume, or you need the lowest acquisition latency for a heavy config (custom viewport, extensions, kiosk mode: these restart Chromium on a fresh create) -> **Do** one pool per fixed config. -> **Avoid** pools for per-user config, GPU browsers (not available in pools), low-volume one-offs, and for "speed" alone.

- Lab refuted the docs claim "acquire is faster than create" for a light config: acquire 1478/303/338 ms vs create 747/347/315 ms (n=3, API call only). Do not pool a default-config browser to save time. Whether a heavy config gains is (unverified: not measured).
- The real documented reasons: acquire is not subject to the create rate limit, and the heavy config is already applied.
- A pool of size N holds N concurrency slots for as long as it exists, acquired or not. Idle pooled browsers are not billed.
- The docs say pools suit steady traffic and also say "bursty" workloads gain from them (create-rate argument). Both appear; the 429 argument is the one that holds for bursts. Low-volume bursty work stays on-demand.

**Source** https://www.kernel.sh/docs/introduction/scale, https://www.kernel.sh/docs/browsers/pools, probe P15.

## S3. Pool lifecycle

**If** you chose a pool -> **Do**:
1. Create it once at deploy or startup. `size` is required (omitting it is a 400 "size must be at least 1").
2. Wait for fill (`retrieve(...).available_count`) before sending traffic. First fill of a size-1 pool took 6 s in the lab; refills after `reuse: false` took about 4 s; after `flush` 44 s; after `update({ discard_all_idle: true })` 58 s. Docs say a pool "takes a few minutes to fill" at size. Never create a pool inside a request.
3. `acquire` with `acquire_timeout_seconds`; null-check the result.
4. `release` in `finally`.

```ts
import Kernel from '@onkernel/sdk';

const kernel = new Kernel();
const POOL = 'my-pool';

const browser = await kernel.browserPools.acquire(POOL, { acquire_timeout_seconds: 60 });
if (!browser) throw new Error('no browser ready before the deadline'); // 204 surfaces as null
try {
  // drive browser.cdp_ws_url or kernel.browsers.playwright.execute(browser.session_id, ...)
} finally {
  await kernel.browserPools.release(POOL, { session_id: browser.session_id, reuse: false });
}
```

(Trimmed from probe P15 `03-pool-acquire-timing-and-204.ts` and `04-release-reuse-cookie-leak.ts`, which ran ok; the `if (!browser)` guard and `reuse: false` choice are the only changes.)

**Avoid**:
- **Treating 204 as an error or a hang.** When no browser is ready, `acquire` waits `acquire_timeout_seconds`, then returns HTTP 204; the SDK type is `BrowserPoolAcquireResponse | null`. Lab: 204 after 5.8 s on a 5 s wait, and no `Retry-After` header. Retry yourself until your own deadline (loop below), do not tighten the loop.
- **Pools in the request path** (create/delete per request defeats the point).
- **Forgetting release.** An acquired browser stays out of the pool until you release it or its `timeout_seconds` idle timer (default 600, starts only after acquire) destroys it and the pool replaces it. The timeout is a backstop.
- **Leaving a pool behind.** `browserPools.delete(name)` while a browser is leased is refused with 400 (not 409): "Cannot delete pool. 1 browser(s) are currently in use. Use force=true to terminate them." `delete(name, { force: true })` kills the leased browser too (it 404s afterwards).

```ts
// untested: deadline loop around a null-returning acquire
async function acquireBy(pool: string, deadlineMs: number) {
  const end = Date.now() + deadlineMs;
  while (Date.now() < end) {
    const b = await kernel.browserPools.acquire(pool, { acquire_timeout_seconds: 30 });
    if (b) return b;
  }
  throw new Error(`pool ${pool}: no browser before deadline`);
}
```

**Sizing**: watch `available_count` (ready now) and `acquired_count` via `browserPools.retrieve`. Regularly 0 -> too small, tasks queue behind acquire. Steady 10-20% -> target. Consistently above 30-40% -> you are holding concurrency you never use, shrink. Resize with `update({ size })` before a peak, not during (new capacity fills at `fill_rate_per_minute`, on create defaults to 25 percent of the pool per minute per the MCP tool docs; the SDK cap is 25 for most organizations, raisable per organization). Resizing was NOT tested live (extra slots).

**Source** https://www.kernel.sh/docs/browsers/pools, probe P15 (create, acquire/204, delete, fill timings).

## S4. Per-user work on a pool

**If** pooled browsers serve different end users -> **Do** one of:
- **Acquire-time profile** (lab-verified): `acquire(pool, { profile: { name, save_changes: true } })` on a profile-free pool, then release. Lab: cookie written in lease 1 was present in the next acquire of the same profile.
- **Attach after acquire**: `kernel.browsers.update(session_id, { profile: { name, save_changes: true } })`, then `release({ reuse: false })`. This is the docs pattern; (unverified in the lab: the lab used the acquire-time form).
- No persistent state needed: just release with `reuse: false`.

```ts
// from probe P15 06-acquire-profile-save-changes.ts (ran ok), trimmed
const w = await kernel.browserPools.acquire(POOL, {
  acquire_timeout_seconds: 120,
  profile: { name: 'user-8f21c3', save_changes: true },
});
if (!w) throw new Error('no browser ready before the deadline');
try {
  // drive w.cdp_ws_url as that user
} finally {
  await kernel.browserPools.release(POOL, { session_id: w.session_id, reuse: false });
}
```

**Avoid**:
- **`reuse: true` after user work.** Lab (confirmed): after a cookie was set in lease 1 and released with `reuse: true`, the next acquire got the same `session_id` and the cookie was present (one user's session leaked to the next acquirer). With `reuse: false` the next lease was a new session and the cookie was absent. `reuse` defaults to true.
- A profile on the pool itself for per-user state: docs say it loads read-only and `save_changes` is silently ignored, and a pool holds one profile. (Read-only behavior not live-tested: needs a second profile-bound pool.) Use a pool profile only for one shared identity, e.g. a Managed Auth login every browser should start with (`references/profiles.md`).
- Expecting your lease `name` / `tags` to persist: acquire-time `name` and `tags` apply to that lease only (`name` must be unique among active sessions in the project). Pool create has no `tags` field.
- Vaults on pooled browsers: pool create has no `vaults`; attach vaults with `browsers.create` (`references/vaults-payments.md`).

Lab note: a browser acquired with an acquire-time profile is destroyed and replaced on release even with `reuse: true` (observed: new session; SDK comment in `browser-pools.ts` says the same), so the refill delay applies.

**Source** https://www.kernel.sh/docs/browsers/pools, probe P15 (leak demo, acquire-time profile).

## S5. Changing a pool's config

**If** you change a pool's config (stealth, proxy, extensions, viewport, ...) -> **Do** `update(pool, { ..., discard_all_idle: true })` or `flush(pool)` after in-use browsers are released; or release the in-use ones with `reuse: false`. -> **Avoid** assuming leased browsers pick up the change: they keep their old config, and a `reuse: true` release returns them to the pool still carrying it.

- `update` without `discard_all_idle` only affects browsers created afterwards. Lab: `update(POOL, { discard_all_idle: true })` returned the pool object; the idle browser was rebuilt (58 s).
- `flush(pool)` (CLI `kernel browser-pools flush <id-or-name>`) destroys idle browsers only. Lab: while a browser was leased, flush left `acquired_count` at 1 and the leased browser alive.
- `network` replaces the whole object, not individual fields: resend every network setting you want to keep. Omit `network` to leave it, `network: {}` clears it. `update` also takes `expected_network`: pass the network config from your last pool response and the whole update is rejected with 409 `stale_network` if it changed (SDK types; (unverified: not run)).
- Changing `network.allowed_hosts` auto-replaces idle browsers; leased ones reset to the pool baseline on release (docs; not run).
- Pool `memory` applies to newly warmed pool browsers: 1, 2 or 4 GiB for headless, 8 or 16 GiB for headful. Existing browsers keep their allocation until replaced (`discard_all_idle`).

**Source** https://www.kernel.sh/docs/browsers/pools, probe P15 (flush, update discard_all_idle).

## S6. Plan gate for pools

**If** a pool create fails, or you must know before designing around pools -> **Do** read `features.browser_pools.enabled`:

```bash
# untested
kernel org entitlements -o json | jq '.features.browser_pools'
```

```ts
// untested
const ent = await kernel.organization.entitlements.retrieve();
if (!ent.features.browser_pools.enabled) { /* stay on-demand */ }
```

**Avoid** hard-coding a plan name. The docs contradict each other: the pools page says "Start-Up and Enterprise plans" while the pricing page lists browser pools on every plan. A Hobbyist account in the lab created and used a pool without any gate, so the pricing page matched there (one account, one point in time). The gate error shape itself was not observed. The entitlements call itself is verified (P16: `kernel org entitlements -o json` returned `features.*.enabled`, `plan.id`).

**Source** https://www.kernel.sh/docs/browsers/pools, https://www.kernel.sh/docs/info/pricing, probes P15, P16.

## S7. Concurrency: preflight, queue, back off

**If** you are about to start more than a handful of browsers -> **Do** read the limits first:

```bash
kernel org limits get -o json
# {"max_concurrent_sessions":10,"concurrent_sessions_used":4,"concurrent_sessions_available":6,...}
```

```ts
const l = await kernel.organization.limits.retrieve();
const free = l.concurrent_sessions_available; // cap your worker count at this, minus a margin
```

- Preflight is a snapshot, not a reservation. The counter is org-wide and moves with other activity: in the lab it read 4, then 5, then 6 after two creates (+1 per browser, a pool of size 1 also +1), then 3 after deleting both (the extra -1 is unexplained; not investigated). Trust back-to-back deltas, not a remembered baseline.
- Counted toward the limit: on-demand browsers, every pool slot (acquired or not), browsers in standby. Delete to free a slot.
- Split one org limit across teams or environments with project concurrency caps (`kernel projects limits get|set`, https://www.kernel.sh/docs/info/projects#concurrency-limits). `kernel org limits set` sets the default per-project cap, not the org limit.
- Per plan the limits differ (Developer 5, Hobbyist 10, Start-Up 150 concurrent browsers; Enterprise custom): read them from `org limits get`, do not hard-code.

**If** you get 429 on create -> **Do** queue on your side (BullMQ or any queue, worker concurrency at or below `concurrent_sessions_available` or pool size), back off, honor `Retry-After`. The SDK already retries 429 up to 2 times honoring `Retry-After`, then throws `RateLimitError` with the headers. -> **Avoid** tightening the retry loop (a 429 means the org is over budget for the minute) and hand-rolled retry stacked on the SDK's.

**If** you get a 5xx -> the SDK maps every status >= 500 to `InternalServerError`; there is no capacity or 529 class (read from `core/error.ts`, probe P16). Treat it like 429: slow down. Whether the API ever returns 529, and what status a concurrency overflow returns, is (unverified: not documented, not produced live).

```ts
// untested: slow-down branch
try {
  const b = await kernel.browsers.create({ timeout_seconds: 300 });
  // ...
} catch (e) {
  if (e instanceof Kernel.RateLimitError) { /* requeue after e.headers?.get('retry-after') */ }
  else if (e instanceof Kernel.InternalServerError) { /* requeue with backoff */ }
  else throw e;
}
```

- The installed SDK retries 409, 429 and every 5xx up to `maxRetries` (default 2), not only 429 as the docs say (source read, `client.mjs`; not tested live). Create is not idempotent and sends no idempotency key: where a duplicate would cost you, pass `{ maxRetries: 0 }` and reconcile with `list` by tag.
- Rate-limit headers (`X-RateLimit-Limit`, `X-RateLimit-Remaining`) are documented for "rate-limited endpoints" but were absent on `GET /org/limits` and `GET /browsers` 200 responses. Do not build logic on them.

**Source** https://www.kernel.sh/docs/browsers/concurrency-and-limits, probes P15, P16.

## C8. Before cost-bearing work, and on a 403

**If** you start cost-bearing work (many browsers, GPU, a pool), or get a 403 -> **Do**:

```bash
kernel org limits get -o json
# untested jq filter below (lab verified gpu, custom_proxies, search, proxy_bypass_hosts, plan.id only)
kernel org entitlements -o json | jq '{plan: .plan.id, gpu: .features.gpu.enabled, pools: .features.browser_pools.enabled}'
```

Then read the 403 body: it can be a plan gate, an exhausted spending cap, `insufficient_scope`, or a project mismatch. At 100% of a spending cap new browser sessions and app invocations return 403 for that scope while running work continues; a pool can hold idle capacity but you cannot acquire from a capped scope (https://www.kernel.sh/docs/info/spending-caps). -> **Avoid** inferring access from plan names or from one docs page.

- Lab: on a Hobbyist account `gpu`, `custom_proxies`, `search`, `proxy_bypass_hosts` were all false. A `gpu: true` create with `headless: true` fails 400 `invalid_request` ("headless mode is not supported with gpu=true") before any plan check, creates nothing, and so does not tell you whether GPU is plan-gated. The plan-gate error for GPU (headful) was not observed. GPU is on-demand only; it cannot come from a pool.

**Source** https://www.kernel.sh/docs/info/spending-caps, https://www.kernel.sh/docs/browsers/concurrency-and-limits, https://www.kernel.sh/docs/info/api-keys (`insufficient_scope`), https://www.kernel.sh/docs/info/projects (project mismatch), probe P16.

## Parallel tabs on one browser (not a pool)

**If** several tasks need the same profiled identity at once and the profile must save -> **Do** one browser, one named Playwright executor per task (each gets its own tab), up to eight executors; delete each executor (`close_tab: true`) before reusing its name, then delete the browser so the profile saves. -> **Avoid** one browser per task writing the same profile (concurrent writers). Memory, CPU and site behavior bound the real parallelism; raise `memory` if tabs are heavy. Not run in the lab. **Source** https://www.kernel.sh/docs/browsers/parallel-task-execution (docs only).

## Pool cheat sheet (names)

| Task | SDK | CLI |
|---|---|---|
| Create | `browserPools.create({ name, size, ... })` | `kernel browser-pools create --name --size ...` |
| Inspect | `browserPools.retrieve(idOrName)` -> `available_count`, `acquired_count` | `kernel browser-pools get` |
| Lease | `browserPools.acquire(idOrName, { acquire_timeout_seconds, profile?, name?, tags?, start_url? })` | `kernel browser-pools acquire` (`--timeout`; the profile flags `--save-changes`, `--profile-id`, `--profile-name` belong to create and update) |
| Return | `browserPools.release(idOrName, { session_id, reuse? })` (the browser id, not the pool) | `kernel browser-pools release` (`--reuse`) |
| Rebuild idle | `browserPools.flush(idOrName)`, `update(..., { discard_all_idle: true })` | `kernel browser-pools flush`, `update --discard-all-idle` |
| Remove | `browserPools.delete(idOrName, { force? })` | `kernel browser-pools delete --force` |

Pool create params, from the installed types: `size` (required), `name`, `fill_rate_per_minute`, `timeout_seconds`, `profile`, `refresh_on_profile_update`, `proxy_id`, `region` (fixed at creation), `network`, `headless`, `stealth`, `memory`, `viewport`, `telemetry`, `extensions`. Avoid `max_pooled_sessions`: it is gone from org limits and a request that sets it returns 400 (docs, https://www.kernel.sh/docs/info/projects; not run, P16 confirmed only the missing field) (pool size is the only pool capacity knob). Avoid `proxy_id` on browsers (use `proxy`); on pool create it is still the right field. Full list: `references/api-map.md`.

---

> Verified in lab: 2026-10-20, @onkernel/sdk 0.127.0, kernel CLI 0.49.0. Probes: P15 (pool create/size-required, acquire, 204 null, acquire vs create timing refuted, reuse leak, reuse:false isolation, flush, update discard_all_idle, delete without/with force, acquire-time profile save_changes: all confirmed except timing refuted); P16 (org limits fields confirmed; counter +1 per browser, return-to-baseline refuted; SDK error classes confirmed; 429/529 semantics and concurrency-overflow status unclear/untested; GPU plan-gate error not reached). NOT tested: pool-level profile read-only, pool resize via `update`, `expected_network`, allowlist behavior on pools, attach-after-acquire via `browsers.update`, a real 429, 529, the pool plan-gate error, fill-rate caps, pool timing beyond n=3, executors-on-one-browser pattern, SDK retry of 409/5xx (source read only).
