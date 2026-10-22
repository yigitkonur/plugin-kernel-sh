# Verified facts (evidence ledger)

Date: 2026-10-20. TypeScript SDK 0.127.0, CLI 0.49.0, plan tier Hobbyist (the lab account, shared with other workloads, so org-wide counters drift).

How to read this file. Each row is one claim that was tried against the live service. `id` is probe number plus claim number (P07.4 = probe 7, claim 4); lab snippets are referred to as `lab/<probe>/<file>.ts`. Results: confirmed (the live call behaved as stated), refuted (the live call contradicted docs, an older skill, or an earlier plan), gated (the plan or a missing model key blocked it), untested (not reached). Evidence is trimmed and masked; no identifiers or URLs with tokens appear. Where the SDK types, the docs and the live service disagree, the live result is what you should code against, and the row says so.

## Browsers lifecycle

| id | claim | result | evidence |
|---|---|---|---|
| P01.1 | `browsers.create` returns session id, CDP URL, webdriver URL, base URL | confirmed | 16 keys incl. location, proxy, memory even when not requested |
| P01.2 | Create response includes a live-view URL for every browser | refuted | Absent for headless; present for headful (P18.10) |
| P01.7 | Create latency is about 30 ms | refuted | Client-side wall time p50 about 333 ms, max 836 ms (n=5); delete about 200-227 ms |
| P01.9 | Only `deleteByID` deletes; there is no `browsers.delete` | confirmed | `typeof browsers.delete` is undefined |
| P01.10 | Retrieve after delete | confirmed | Default 404 NotFoundError; `include_deleted: true` returns the record with `deleted_at`, no status field |
| P02.1 | `connectOverCDP` gives one context and one page on a fresh browser | confirmed | contexts 1, pages 1 |
| P02.2 | `browser.newContext()` is isolated from `contexts()[0]` | confirmed | Cookie set in default context not visible in the new one |
| P02.3 | Closing the Playwright client does not delete the browser | confirmed | Still listed active 30 s later; `deleteByID` then removes it |
| P02.4 | Live responses expose a standby/status/usage field | untested | None present on retrieve/list; only list membership and `deleted_at` signal state |
| P02.5 | `timeout_seconds: 10` with no client reaps the browser | confirmed | Gone between 8 and 17 s; `deleteByID` after reap returns 404 (treat as success) |
| P02.6 | Reconnect to the same CDP URL after a client disconnect | confirmed | Same page title and cookie after reconnect |
| P04.1 | Headless accepts 1, 2, 4 GiB memory | confirmed | VM MemTotal about 1, 2, 4 GiB |
| P04.2 | Headful accepts 8 GiB | confirmed | MemTotal about 8 GiB |
| P04.3 | Headful accepts 16 GiB | untested | Only one headful browser was allowed |
| P04.4 | Invalid memory is rejected | confirmed | 400 "memory must be 1GiB or 2GiB or 4GiB" (headless) |
| P04.5 | `memory` is headful-only | refuted | Headless 1/2/4 GiB work; 8 GiB headless is 400. SDK type is looser than the server |
| P04.7 | `navigator.deviceMemory` reflects VM memory | refuted | Always 4; read /proc/meminfo through `process.exec` |
| P04.9 | Window size equals the requested viewport | refuted | Headless window stays 800 wide; headful inner height is about 87 px short. Use `page.setViewportSize` |
| P04.10 | `browsers.update` viewport change mid-session | confirmed | Old CDP client stayed connected in headless and headful |
| P04.11 | Viewport update restarts Chromium | refuted | Page marker survived the update |
| P04.12 | Update with live view or replay needs `force` | untested | Not exercised |
| P09.1 | `profile: { name, save_changes: true }` persists a login to a later browser | confirmed | New browser with the profile (no save flag) opened the logged-in page |
| P09.2 | Closing only the CDP client saves the profile | refuted | `updated_at` unchanged until the browser was deleted |
| P09.3 | Sequential writers: last one wins | confirmed | Logout writer overrode login writer |
| P09.4 | `save_changes` false or omitted discards changes | confirmed | Next load showed logged-out |
| P09.6 | Profile can be renamed while a browser uses it | confirmed | Rename OK, id unchanged, old name 404 |
| P09.7 | `browsers.list({ status: 'active', query: <profile id> })` shows the writer | confirmed | `profile_save_changes` true on own browser |
| P15.2 | Pool size counts against concurrency | confirmed | Back-to-back org limits: used +1 for size 1 |

## Control surfaces

| id | claim | result | evidence |
|---|---|---|---|
| P01.3 | `playwright.execute(id, { code, timeout_sec })` returns `{success, result, tab}` | confirmed | Title "Example Domain", HTTP 200 |
| P01.5 | Base64 screenshot returned from execute round-trips | confirmed | Valid PNG, 800x513 |
| P01.6 | A throw inside execute code | confirmed | HTTP 200 with `success: false` and `error`; the SDK does not throw |
| P03.1 | Two named executors run in parallel | confirmed | 3.3 s vs 6.3 s for the same executor |
| P03.2 | Globals persist per executor, not across executors | confirmed | `globalThis` set on a, undefined on b |
| P03.3 | Up to 8 named executors can be created | confirmed | Only on a 4 GiB headless browser. On the default 1 GiB VM, creation fails with 500 from about the 5th executor because memory runs out (not a limit) |
| P03.4 | The 9th new executor name fails | confirmed | 409 ConflictError, body has code, executors (default executor not counted), message |
| P03.6 | `executors.delete` with `close_tab`, then reuse the name | confirmed | 278 ms; name reusable immediately |
| P03.7 | Each executor owns a tab | confirmed | Distinct target ids; reuse reports `created: false` |
| P07.1 | `computer.captureScreenshot` returns a PNG | confirmed | `Response` object; read with `arrayBuffer()` |
| P07.2 | clickMouse, typeText, pressKey drive a form | confirmed | Value "123" typed; clicks use screen pixels (headful offset about 87 px) |
| P07.3 | `pressKey` accepts Return and Enter | confirmed | Both succeed |
| P07.4 | `pressKey({ keys: ['Ctrl+a'] })` selects all | confirmed | Also lowercase `ctrl+a` |
| P07.5 | `keys` may be a single string | refuted | 400 decode error; must be `string[]` (compile-time error too) |
| P07.6 | `['Ctrl','a']` is a chord | refuted | Two separate taps |
| P07.7 | `['Ctrl+a','Delete']` is a sequence | confirmed | Select-all then delete |
| P07.8 | SDK types include `smooth` and `typo_chance` on typeText | refuted | Only `text` and `delay` typed in 0.127.0 |
| P07.9 | The live API accepts `smooth` and `typo_chance` | confirmed | HTTP 200; REST path is `/computer/type` |
| P07.10 | Computer controls work on headless | confirmed | Screenshot, mouse position, click, key all succeed |
| P07.11 | Browser REPL bindings persist between calls | confirmed | Same `repl_id`, value kept |
| P07.12 | REPL call exceeding `timeout_sec` destroys the REPL | confirmed | `repl_terminated: true`; bindings gone, new `repl_id` |
| P07.13 | REPL request and result shape | confirmed | `{ code, reset?, timeout_sec? }` -> `content[]`, `repl_id`, `success`; `reset: true` starts fresh |
| P08.1 | WebMCP list on a plain page | confirmed | HTTP 200, empty `tools` |
| P08.2 | Custom tool add, list, invoke | confirmed | Statuses completed, error, awaiting_submission seen |
| P08.3 | Reusing a `tool_ref` after navigation | confirmed | SDK throws 404 "no longer available"; list again for a fresh ref |
| P08.4 | Docs field names match the API | refuted | Use `tool_ref`, `input`, `timeout_sec`; listing is nested `tool.name`, `tool.inputSchema`; unknown fields are 400 |
| P05.3 | Upload through `setInputFiles` with an in-memory buffer | confirmed | Page reported the upload |
| P22.1 | puppeteer-core `connect({ browserWSEndpoint })` works | confirmed | Title read from the page |

## Files and processes

| id | claim | result | evidence |
|---|---|---|---|
| P05.1 | A CDP download lands in a directory made with `fs.createDirectory` | refuted | The directory is created owned by root; Chromium (user kernel) cannot write and cancels the download |
| P05.2 | Download works with the default directory | confirmed | Works if you do not create the directory first (Chromium creates it); file visible in listFiles in about half a second |
| P05.5 | Custom download directory | confirmed | Create it with `process.exec` mkdir as user kernel, then set download behavior over raw CDP. In-VM Playwright `saveAs` is cancelled |
| P05.6 | `browsers.curl` with base64 encoding fetches a file | confirmed | Body decodes to the exact bytes |
| P05.7 | `fs.listFiles` on an empty directory | refuted | Returns null, not an empty array; a missing directory throws 404 |
| P05.8 | `fs.readFile` return value | confirmed | A fetch `Response`; use `arrayBuffer()` |
| P05.4 | `readFile` after `deleteByID` | confirmed | status 410 "browser session no longer exists" |
| P06.1 | `process.exec` returns output | confirmed | `stdout_b64` / `stderr_b64` (base64), `exit_code`, `duration_ms` |
| P06.2 | `process.spawn` with status and stdout stream | confirmed | Stream ends with an exit event carrying `exit_code` |
| P06.3 | `browsers.curl` shares the browser cookie jar | confirmed | Cookie set by one call seen by the next, also by `fetch` |
| P06.4 | `fetch`/`curl` handle a 2 MB body | refuted | 2 MB POST body fails 502 on both after 23-30 s; 200 KB works; `fetch` is positional `(id, input, init)` and its `timeout_ms` did not cancel a hung body |

## Profiles

| id | claim | result | evidence |
|---|---|---|---|
| P09.5 | Profile download format | confirmed | Default is zstd; `format: 'tar'` gives plain tar; not zip |
| P09.8 | Downloading a never-saved profile | untested | Returned 0 bytes with no error shown |
| P15.11 | Acquire-time profile with `save_changes` writes back | confirmed | Cookie written in one lease visible in the next |
| P15.12 | Pool-level profile is read-only for leases | untested | Needs a second profile-bound pool |

## Managed Auth

| id | claim | result | evidence |
|---|---|---|---|
| P10.2 | New connection starts unauthenticated | confirmed | Status NEEDS_AUTH, `can_reauth` false |
| P10.3 | Health checks can be disabled at create | confirmed | `health_checks: false` accepted |
| P10.4 | Minimum `health_check_interval` | refuted | 3600 s on this plan (400 below), not the 21600 in the SDK docstring |
| P10.5 | `login(id)` returns a hosted URL and a one-time handoff code | confirmed | Treat both as secrets |
| P10.6 | `follow(id)` reaches AUTHENTICATED with a stored credential | confirmed | IN_PROGRESS -> SUCCESS/COMPLETED without a human |
| P10.6b | Heartbeat event name | refuted | Live name is `sse_heartbeat`; the SDK union says `heartbeat` |
| P10.7 | Duplicate create returns 409 | confirmed | Body has `code`, `existing_id`, `message` |
| P10.8 | `login` on a live flow | confirmed | Starts a new flow with a different hosted URL; earlier flow CANCELED |
| P10.10 | New browser with `profile: { name }` is logged in | confirmed | Protected page opened; control without profile hit the login page |
| P10.11 | Delete connection, credential, profile | confirmed | Lists empty afterwards |
| P10.12 | Periodic health checks, auto-reauth, MFA steps | untested | Needs hours or a site with MFA |

## Vaults

| id | claim | result | evidence |
|---|---|---|---|
| P10.1 | `credentials.create` never echoes the secret | confirmed | Response has only `has_values`, `value_keys` |
| P11.1 | Vault and item upsert; get/list never return secrets | confirmed | Sensitive fields show `has_value` only; non-sensitive fields return their value |
| P11.2 | Browser created with `vaults` can run item `fill` | confirmed | Fields filled, form not submitted (`completed` is not logged in) |
| P11.3 | Fill with wrong `page_url` or selector | confirmed | HTTP 400 `page_not_found` / `element_not_found` / `timeout`, "no fields were written". `page_url` must match exactly, query included |
| P11.3b | HTTP 200 with per-field failed status after writing starts | untested | Not reproducible with pre-write failures |
| P11.5 | Delete item and vault | confirmed | Lookup returns "not found" |

## Stealth, proxies, captcha

| id | claim | result | evidence |
|---|---|---|---|
| P12.1 | Config registry `lookup` | confirmed | Returns null recommendation for some targets, a recommendation (managed proxy) for others; `resolve` + `analyses.waitForResult` completes in minutes |
| P12.3 | `proxy: { mode: 'direct' }` is valid | confirmed | Accepted; stealth false |
| P12.4 | Create shape with and without stealth | confirmed | Same keys; `proxy` is `{ mode }`, no proxy id key |
| P12.5 | Egress differs between stealth default and direct | confirmed | Addresses differ (stealth alone not isolated by this test) |
| P12.2 | Fingerprint failures differ between stealth and non-stealth | untested | Scanner rows could not be extracted |
| P13.1 | Stealth browser emits captcha events on a reCAPTCHA v2 demo | confirmed | solve_started, solve_result success (about 1.3 s), challenge_result solved |
| P13.2 | Do not click; wait; submit | confirmed | "Verification Success" after the solver set the token (5-67 s across runs) |
| P13.3 | Non-stealth browser solves | refuted | No token after 25 s, zero captcha events |
| P13.4 | Captcha event fields | confirmed | `captcha_provider`, task kind, status, `duration_ms`; `captcha_type` reads "other" (deprecated) |
| P14.1 | ISP proxy create, check, delete | confirmed | Available on Hobbyist; check returns the proxy object |
| P14.4 | `proxy: { mode: 'direct' }` gives direct egress | confirmed | Address differs from stealth |
| P14.5 | `proxy: { id }` routes through that proxy | confirmed | Egress equals the proxy's reported address |
| P14.6 | Deprecated `disable_default_proxy` still accepted | confirmed | Accepted, response still `mode: default` |
| P14.7 | `disable_default_proxy` yields direct egress | refuted | Egress stayed a stealth address; use `proxy.mode: 'direct'` |
| P14.8 | Deprecated `proxy_id` still accepted | confirmed | Echoed as `proxy: { id }` |
| P14.9 | `proxy: { type: 'datacenter' }` | refuted | 400 with a misleading "provide exactly one of proxy.mode, proxy.id, or proxy.name" |
| P14.10 | `network.allowed_hosts` allows and blocks | confirmed | Allowed host 200; other host 403 with proxy-error header `network_policy_denied` |
| P14.11 | Navigation to a blocked host throws | refuted | `page.goto` resolves with a 403 response |
| P14.13 | CLI flag for the allowlist | confirmed | `--allowed-host` (repeatable, max 100) |
| P14.14 | A stealth browser cannot load a .gov site | refuted | usa.gov loaded 200 with no proxy-error header |

## Pools and limits

| id | claim | result | evidence |
|---|---|---|---|
| P15.1 | Pool create needs `size` | confirmed | 400 "size must be at least 1" without it |
| P15.3 | `acquire` returns a browser when ready | confirmed | Session id and CDP URL present |
| P15.4 | `acquire` with nothing ready | confirmed | HTTP 204 with no Retry-After header; the SDK returns null |
| P15.5 | Acquire is faster than on-demand create | refuted | Median 338 ms vs 347 ms (n=3) |
| P15.6 | `release({ reuse: true })` keeps state | confirmed | Same browser, cookie leaked to the next lease |
| P15.7 | `release({ reuse: false })` gives a fresh browser | confirmed | New session, cookie absent |
| P15.8 | `flush` destroys idle browsers | confirmed | Refill took about 44 s; leased browsers untouched |
| P15.9 | `update` with `discard_all_idle` | confirmed | Refill took about 58 s |
| P15.10 | Delete a pool with a leased browser | confirmed | 400 without `force`; with `force: true` it deletes and the leased browser is gone |
| P15.13 | Pools are gated off on Hobbyist | refuted | Pools worked on Hobbyist |
| P16.1 | Org limits fields | confirmed | `max_concurrent_sessions`, used/available counters |
| P16.2 | A create changes concurrency counters by 1 | confirmed | +1 per browser (not +2) |
| P16.3 | Counters return to baseline after cleanup | refuted | Drifted by another workload on the shared account |
| P16.4 | SDK error classes | confirmed | 400/401/403/404/409/422/429/5xx classes; no 529 or capacity class (it would be InternalServerError) |
| P16.5 | 429 versus 529 semantics and headers | untested | Not produced; no rate-limit headers on read endpoints |
| P16.6 | SDK auto-retries | confirmed | Also 409 and all 5xx, 2 retries by default (source read) |
| P16.7 | Entitlements for gpu, custom proxies, search, proxy bypass hosts | gated | All false on Hobbyist |
| P16.8 | GPU create | gated | Headless + gpu: 400 first; headful gpu: 403 `insufficient_plan` (Start-Up or Enterprise) |

## Apps

| id | claim | result | evidence |
|---|---|---|---|
| P17.1 | `kernel create -y` then `kernel deploy index.ts --version v1` | confirmed | Deploy finished in about 24 s with the action list |
| P17.2 | `kernel invoke` without a version after a versioned deploy | refuted | 400 deployment_not_found; pass `-v` |
| P17.3 | CLI invoke blocks until the run ends | confirmed | Streams events to a terminal state; `--sync` prints one object. Docs saying it returns immediately are wrong |
| P17.4 | SDK async invoke plus `follow` | confirmed | queued -> succeeded with output; use `{ maxRetries: 0 }` |
| P17.5 | `invocations.update(id, { status: 'failed' })` reaps tagged browsers | refuted | Browser still active after 10 s; `invocations.deleteBrowsers` removed it |
| P17.6 | Payload limit is 64 KB | refuted | 100 KB and 1 MB accepted through `--payload-file` |
| P17.7 | Subdirectory entrypoint | refuted | `src/app.ts` fails "entrypoint not found in archive"; entrypoint must be at the project root |
| P17.8 | `kernel logs <app> --since` shows action output | refuted | Only header lines; use `-i <invocation id>` |
| P17.9 | Reserved `KERNEL_API_KEY` env var in deploy | confirmed | Accepted silently; the injected key wins |
| P17.10 | Delete the app | confirmed | Deployments deleted; list empty |

## Telemetry and replays

| id | claim | result | evidence |
|---|---|---|---|
| P13.5 | Stream frame shape | refuted | `{ seq, event: { ts, type, category, source, data } }`; filtering on a top-level category matches nothing |
| P18.1 | Console-only telemetry yields only console events | refuted | Create echo enables captcha, connection, console, control, system: defaults always layer on |
| P18.2 | Events pagination and fields | confirmed | `seq` on the envelope; `ts` in microseconds; next-offset header present |
| P18.3 | CLI `telemetry stream --types` filters server-side | confirmed | Only the requested type delivered |
| P18.4 | SDK `telemetry.stream({ type })` filters | refuted | Parameter sent but not applied; filter client-side. `telemetry.events({ type })` and `{ category }` do filter |
| P18.5 | Resume a stream with `Last-Event-ID` | confirmed | Contiguous sequence after reconnect |
| P18.6 | Replays start, stop, download | confirmed | Download 200 `video/mp4`, about 272 KB for 10 s, video only |
| P18.7 | `replays.stop(rid, { id })` | refuted | Use `{ id_or_name }`; `{ id }` throws a client-side path error |
| P18.8 | Download returns 202 with Retry-After first | refuted | 200 immediately in all samples; keep handling 202 anyway |
| P18.9 | Replay on a headless browser | confirmed | 400 invalid_request "headless browsers don't support replays" |
| P18.10 | Live-view URL on headful with `readOnly=true` | confirmed | URL present; the option round-trips (not opened) |
| P18.11 | Events readable after delete | confirmed | Same events returned after `deleteByID` |
| P19.1 | Telemetry defaults plus console, network, page | confirmed | Categories layered on defaults |
| P19.2 | An uncaught page error is recorded | confirmed | Appears as `console_error` |
| P19.3 | Navigating to a bad host throws | refuted | `goto` resolves; only page events and a 502 on the favicon |
| P19.4 | In-page fetch returning 500 appears as a 500 response event | refuted | Recorded as `network_loading_failed` (aborted); no 500 response event |
| P19.6 | Deleted-session record via CLI `get --include-deleted` | confirmed | Plain `get` is 404 |
| P19.7 | CLI `telemetry events` with `--since`, `--all`, `--types`, `--categories` | confirmed | 58 events over 16 types; default window is 5 minutes; future `--until` rejected |
| P19.8 | Replay list after delete | confirmed | Replay listed with `finished_at` set |
| P19.10 | A `page_error` event type exists | refuted | Not in the SDK; errors arrive as `console_error` |
| P19.11 | Deleted record has a status field | refuted | Only `created_at` and `deleted_at` |
| R3.1 | A finished replay can be listed and downloaded after the browser is deleted | confirmed | After `deleteByID`: `replays.list` returns the replay with `finished_at` set; `download` 200 `video/mp4` (about 84 KB for a 5 s session) |

## CLI

| id | claim | result | evidence |
|---|---|---|---|
| P20.1 | List commands return valid JSON with `-o json` | confirmed | 12 commands; `vaults list` returns an object, the rest arrays |
| P20.6 | `browsers create -o json -y` non-interactive | confirmed | Exit 0 with browser keys |
| P20.7 | `browsers delete` never prompts | confirmed | Idempotent; absent browser counts as success |
| P20.8 | `browsers delete -y` exists | refuted | Exit 1 "Unknown shorthand flag" |
| P20.9 | `browsers get <id> --include-deleted` | confirmed | Plain `get` exits 1 |
| P20.10 | `browsers playwright execute <id> '<code>'` | confirmed | JSON `{ result, success, tab }` |
| P20.11 | `browsers computer screenshot --to` | confirmed | Valid PNG written |
| P20.12 | `proxies check` | untested | No lab-owned proxy at the time |
| P20.13 | `browsers logs stream` flags exist | confirmed | `--source`, `--follow`, `--path`, `--supervisor-process` |
| P20.14 | `logs stream` returns lines | untested | Exit 0 but prints "logs source not available"; check text, not exit code |
| P20.15 | Failing calls | confirmed | Exit 1, plain text `ERROR: Not_found ...` even with `-o json` |
| P20.16 | `kernel create` non-interactive | confirmed | Six files, runs a package install only if pnpm is on PATH |
| P20.17 | `kernel create` with missing flags in a non-TTY | confirmed | Fails fast with "Cannot prompt" |

## MCP

| id | claim | result | evidence |
|---|---|---|---|
| P21.1 | Hosted MCP initialize with a Bearer key | confirmed | 200 plus a session header; without a key: 401 with WWW-Authenticate |
| P21.2 | Tool count | refuted | 31 tools listed (docs say 13, source about 34); web search and two auth-login tools are gated out |
| P21.3 | `get_connection_context` | confirmed | Reports org-wide connection scope |
| P21.4 | `search_docs` | confirmed | Returns ranked doc sections as text |
| P21.5 | `context` argument required on every call | refuted | Schema says required, server accepted calls without it (create/delete untested) |
| P21.6 | Create, execute, delete lifecycle through MCP | confirmed | Browser appeared in the CLI list while alive and was removed |
| P21.7 | `execute_playwright_code` | confirmed | Same `{ result, success, tab }` shape |
| P21.8 | `manage_browser_files` and `manage_replays` exist | confirmed | File reads default 10 MiB, max 25 MiB; calls not exercised |
| P21.9 | Deprecated aliases in tool schemas | confirmed | `proxy_id`, `proxy_routes`, `clear_proxy`, `disable_default_proxy`, `project_id` marked deprecated; nested `proxy` is current |

## Integrations

| id | claim | result | evidence |
|---|---|---|---|
| P22.2 | `@onkernel/ai-sdk` Playwright execute tool runs without a model | confirmed | Export `playwrightExecuteTool`; `client` is required at runtime |
| P22.3 | `@onkernel/browser-loop` and `@onkernel/cua-agent` are installable | confirmed | Registry metadata only; Node 22.19+; cua-agent pins the SDK to an old exact version |
| P22.4 | browser-loop / cua-agent runtime | gated | Needs a model provider key |
| P22.5 | Stagehand latest version | confirmed | 4.2.1 (docs say 4.2.0) |
| P22.6 | Stagehand with a Kernel browser | gated | Needs a model key |
| P22.8 | `agent-browser` with the Kernel provider env vars | confirmed | Opened a page and closed it; its browsers carry no tags |
| P22.9 | `agent-browser` profile variable and documented defaults | untested | Not exercised |

## Account

| id | claim | result | evidence |
|---|---|---|---|
| P23.1 | API key list item shape | confirmed | Id, name, project fields, expiry, masked key; no policy field in the list |
| P23.2 | Usage, billing or invoice API | refuted | None in the public spec; closest are org limits and entitlements |
| P23.3 | Audit logs on this plan | gated | 403 insufficient plan (Start-Up or Enterprise); CLI has search/download/export |
| P23.4 | Hobbyist is limited to one project | refuted | The lab account lists several projects; not enforced |
| P23.5 | Project header semantics | confirmed | The id header takes an id only; the project header takes a name or an id; wrong values give 404 `project_not_found` |
| P23.6 | Environment variables the SDK reads | confirmed | API key, base URL, log level, custom headers, Bun warning, browser routing; it does not read a project variable |
| P23.7 | Scoped API keys with `policy` and `expires_at` | untested | Documentation only; no key was created |

## Dogfood (naive agents that know Kernel only from the plugin files)

Haiku agents were given a realistic user request (24 tasks: screenshots, scraping, logins, vault fill, parallel visits, pools, Apps, debugging a failed session, downloads and uploads, stealth, profiles, an audit, a Next.js route, a negative case that needs no browser, and cleanup of leftover browsers). They could read the plugin files and the installed SDK types, nothing else, and had to run their code live on the lab account, delete what they created, and report every wrong, missing, ambiguous or hard-to-find line.

| round | tasks run | succeeded | cleanup verified | guidance problems reported |
|---|---|---|---|---|
| 1 | 23 | 20 | 22 | 159 |
| 2 | 10 (killed by a rate limit) | 10 | 10 | 72 |
| 3 | 23 (final skill text, minus the leftover-cleanup task) | 23 | 23 | 128 |
| 4 | 13 (tasks whose guidance had just changed, plus the leftover-cleanup task) | 13 | 13 | 84 |

Pool refill (task D08): a size-2 pool at the default `fill_rate_per_minute`, recycled with `reuse: false`, replaced released browsers at about 0.5 per minute; the later jobs of a 4-job run waited 178 s and 238 s to acquire. `references/scale.md` S3 now sizes pools from this.

Round 1 failures: the audit task ran code instead of staying read-only, and both Managed Auth tasks stalled for ten minutes because no stored credential existed (the hosted flow then waits for a person). Both led to changes: the audit skill is read-only by rule, and the login skill now stores a credential first through a script that keeps the password off command lines. All three passed in rounds 3 and 4. After each round the real defects (contradictions between files, snippets that were not copy-paste, wrong facts, missing cleanup, flags that need `--yes`) were fixed and the rest was triaged as environment artifacts of the test harness.

Still open after round 4, by design: the interactive OAuth sign-in to the Kernel MCP server (needs a person), the payment flows, TOTP and captcha-solving beyond what the lab touched, and ambiguity reports about secrets handling for public demo accounts, which the plugin answers with one policy (a password never goes in project code or on a command line; throwaway accounts read it from the environment at run time).

## MCP inside Claude Code (lead checks)

| id | claim | result | evidence |
|---|---|---|---|
| MC1 | A Bearer API key in a project-style `.mcp.json` header (`Bearer ${KERNEL_API_KEY}`) connects to the hosted Kernel MCP | confirmed | Status connected, 31 tools; `get_connection_context` and `search_docs` answered |
| MC2 | The same config with the variable unset | confirmed | Server status failed (visible failure, not a silent unauthenticated session) |
| MC3 | The plugin-bundled `.mcp.json` (OAuth, no secret) before authentication | confirmed | Status needs-auth, registers no Kernel tools; the user authenticates once through `/mcp` |
| MC4 | Context cost of the Kernel MCP tools after authentication | confirmed | About +1,040 input tokens for a trivial prompt (tools are deferred, names only) |
| MC5 | OAuth completes in Claude Code | untested | Needs a human browser step |

## Triggering and coexistence (lead checks, Claude Code 2.1.302)

Each prompt ran as `claude -p` with the plugin loaded and only `Skill`, `Read`, `Grep`, `Glob` allowed; the table lists which skills the model loaded.

| id | prompt kind | project | result |
|---|---|---|---|
| T1-T5 | Kernel tasks (screenshot function, Cloudflare blocks, keeping a login, 429s at 50 parallel pages, "still billing after close") | TS project using `@onkernel/sdk` | `kernel:kernel` loaded in 5 of 5 |
| T6 | Linux kernel module null-deref fix | C kernel-module repo | no skill loaded |
| T7 | Add zod validation | plain TS project | no skill loaded |
| T8 | Why a Jupyter kernel restarts | plain TS project | no skill loaded |
| T9-T10 | Kernel questions with hooks disabled (`KERNEL_PLUGIN_HOOKS=off`) in a project with no Kernel files | plain TS project | `kernel:kernel` loaded in 2 of 2 (the description alone triggers it) |
| T11 | "Our run for Kernel browser session <id> failed. Why?" | TS project | `kernel:debug-session` loaded |
| T12 | "Our agent needs to log in to app.example.com ... keep the session" | TS project | `kernel:kernel` then `kernel:login` loaded |
| T13-T14 | Same screenshot and failed-session prompts with Kernel's official `kernel-cli` and `kernel-sdks` plugins also loaded | TS project | this plugin's `kernel:kernel` and `kernel:debug-session` were chosen; no official skill was loaded |

## Workflow skills run end to end in Claude Code (lead checks, Claude Code 2.1.302, `--plugin-dir`)

| id | skill and input | result |
|---|---|---|
| W1 | `/kernel:debug-session <id of a deleted session that failed on an HTTP 500 page>` | Report cited telemetry rows (`network_loading_failed` / `ERR_ABORTED` on the failing document), listed what it ruled out and what it did not check, made no live calls against the deleted session, left no temp files |
| W2 | `/kernel:audit` on a copy of a project seeded with 8 known problems | 8 of 8 found with `file:line`, plus 3 extra low findings; the account block flagged an org-wide browser as "possibly not this project" and deleted nothing |
| W3 | `/kernel:audit` on two projects written by the dogfood agents | 0 findings on both, with the rows it judged not applicable named; two uncertain items listed |
| W4 | `/kernel:login the-internet.herokuapp.com` with the public demo account | Stored credential, connection `AUTHENTICATED` / `SUCCESS` with no person present, a fresh browser on the profile showed `/secure` with a logout link, then it deleted browser, connection, profile and credential and listed them empty |
| W5 | `/kernel:profile-site https://quotes.toscrape.com` | Registry lookup `ok`; two headful browsers (stealth and normal, direct egress); the analyzer said "possible block page" for both while all four screenshots showed the normal site, and the report treated it as an analyzer false positive as the skill instructs; both browsers deleted |
| W6 | `kernel-plugin detect .` from two different non-git projects | A relative `.` used to share one cache entry (the second project was told the first one's result). Fixed by resolving the directory to an absolute path; covered by a regression test |

## kernel-browser live runs (2026-10-22, Claude Code 2.1.306)

Rows ran as `claude -p` with `--plugin-dir plugins/kernel-browser` and a project MCP config pointing at the hosted Kernel MCP with a Bearer key (server named `kernel`, so the hooks see `mcp__kernel__<tool>`), except where noted. Hobbyist plan, org limit 10 concurrent browsers.

| id | check | result | evidence |
|---|---|---|---|
| KB1 | Do Playwright executor or REPL connections keep a browser active (billing, never timing out)? CLI `browsers create --headless -t 30`: (a) no call, (b) one `playwright execute`, (c) a REPL cell holding `connectOverCDP` | refuted | Gone at +60 s and +180 s in all three cases, same as the control. The idle timeout reaps a touched browser |
| KB2 | Hook payload shapes for Kernel MCP tools | confirmed | `tool_name` `mcp__kernel__manage_browsers`; `tool_response` is `[{type:"text", text:"<json or prose>"}]`; create text has `browser` (with `cdp_ws_url`, `webdriver_ws_url`, `base_url`, `browser_live_view_url` when headful, `tags`, `timeout_seconds`) and `next_actions`; delete text "browser session deleted successfully"; SessionEnd `reason` "other" under `-p` |
| KB3 | Create guard | confirmed | Model asked for `timeout_seconds` 86400: "PreToolUse ... hook error: kernel-browser: resend this manage_browsers create and use timeout_seconds <= 1800"; it resent 1800 with `tags.cc_session` |
| KB4 | Stop reminder and SessionEnd delete | confirmed | "Stop hook feedback: ... still alive: <id>" once; the model kept the browser (the user said so); after the session `get --include-deleted` showed `deleted_at` 13 s after create (timeout was 1800): the SessionEnd delete |
| KB5 | `/kernel-browser:browse` on a public page with a screenshot | confirmed | Tagged create (600 s, name `cc-hn-top5`), titles via `execute_playwright_code`, `computer_action` screenshot saved by Claude Code as a PNG under the session's `tool-results/`, delete; tag list `[]` afterwards; $0.14 |
| KB6 | `/kernel-browser:login` path C (stored credential, demo site) | confirmed | Credential from env via the script, connection with `credential_name` and `login_url`; first flow failed `provider_unavailable` ("model providers were temporarily unavailable"), one retry `AUTHENTICATED`; a fresh browser on the profile showed the Logout link on `/secure` |
| KB7 | Two browsers loading one profile read-only at the same time | confirmed | Both returned `{path: "/secure", logout: 1}` |
| KB8 | Two candidate profiles for a site (one with a connection) | refuted, then fixed | Before the fix the skill used the connected profile without asking (2 of 2 runs). After: "I found two saved profiles ... Which one should I use?" and no browser created |
| KB9 | Reuse a live browser of the same session (resumed session, browser pre-created with its `cc_session` tag) | refuted, then fixed | Before the fix the skill never listed and created a second browser. After: `list` first, ran on the existing browser, deleted it |
| KB10 | URL masking and key guard on MCP traffic | confirmed | Tool results showed `cdp_ws_url`, `webdriver_ws_url`, `base_url` as `***`; a fake key in `manage_browsers` input: "hook error: kernel-browser: this manage_browsers call carries a Kernel API key literal" |
| KB11 | 1Password Agentic Autofill through the MCP | gated | `manage_vault_credentials` `connect_account` (`provider: "1password"`) returned "404 not found [code: not_found]" while a `provider: "kernel"` credential in the same vault worked: the preview is not enabled on this org |
| KB12 | Both plugins installed | confirmed | `claude mcp list` shows one Kernel server: the copy of the plugin installed first (`plugin:kernel-browser:kernel` or `plugin:kernel-dev:kernel`) |
| KB13 | Installed copy with `api_key` set by the README's `claude plugin configure ... --values-stdin` line, `KERNEL_API_KEY` unset | confirmed | "Configuration saved"; an MCP header `Bearer ${user_config.api_key}` connected; the primer reported "1 Kernel browser(s) from earlier Claude Code sessions are still alive" for a browser pre-tagged with another session id, so the option reaches the hooks. The value went to a keychain item for that config dir |
| KB14 | Hooks under plugin-prefixed tool names (`--plugin-dir`, the plugin's own MCP config) including profile setup | confirmed | `mcp__plugin_kernel-browser_kernel__manage_browsers` 86400 s create denied, resent 1800; `manage_profiles setup` tracked; one stop reminder; after the session the setup browser (timeout 300) was deleted 15 s after create and the other browser (timeout 1800) 8 s after |
| KB15 | README install commands from GitHub after release (clean configs, Claude Code 2.1.306) | confirmed | `claude plugin install kernel-browser --marketplace yigitkonur/plugin-kernel-sh` and the same for `kernel-dev`: 1.0.0 (6 skills, 7 hooks, 1 MCP) and 2.0.0 (7 skills, 4 hooks, 1 MCP); installed files identical to `main` apart from Claude Code's `.in_use` marker; `marketplace update` + `update`: already latest; `uninstall`: no plugins left. Upgrade from 1.x: `kernel` 1.0.2 installed, marketplace moved to the release, `kernel` shows "failed to load", the README's uninstall + install leaves `kernel-dev` 2.0.0 |
