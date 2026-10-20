---
name: debug-session
description: >-
  Debug a failed, hung, blocked or timed-out Kernel browser session from its session id or name: read session state and telemetry events (they stay readable after the browser is deleted), check live page state, replays and logs, then diagnose and propose a fix. Use when a Kernel run fails or misbehaves, or the user gives a Kernel session id.
argument-hint: "<session-id-or-name>"
---

# Debug a Kernel browser session

You are diagnosing one Kernel browser session. Evidence order: session record, then telemetry events, then (only if the browser is still alive) live checks, then replays. Telemetry and the session record stay readable after the browser is deleted (lab P18, P19), so start there.

The argument is the text after the skill name in the user's message (or the line starting `ARGUMENTS:`). It is a session id or a browser name. If it is missing, ask for it and stop. Also ask for the symptom (error text, "hung", "blocked", "timed out") if the user did not give one; it decides which signals to weight.

Rules for the whole run:
- Read-only. Do not create, update or delete browsers, and do not change routing or proxies. If a repro needs a new browser, say so in the report and let the user decide.
- Never print `cdp_ws_url`, `webdriver_ws_url`, `base_url`, `browser_live_view_url`, `replay_view_url`, API keys, or full event payloads. Event `data` can hold Cookie/Authorization headers, bodies and URL tokens (https://kernel.sh/docs/browsers/telemetry/categories). Project fields with `jq` and cut URL query strings (`sub("\\?.*";"?***")`).
- Never dump an event stream into context. Use `--types`, `--categories`, `jq`, and `head`.
- Check the exit code before parsing: `-o json` errors are plain text such as `ERROR: Not_found: ...` with exit 1 (P20).

## 1. Check the CLI

Run `command -v kernel`. If it prints nothing, print these install commands and stop (do not install anything):

```bash
brew install kernel/tap/kernel
npm i -g @onkernel/cli
```

Run `kernel auth context -o json | jq 'keys'`. If it fails, tell the user to set `KERNEL_API_KEY` in their environment and stop. Do not print the key.

## 2. Read the session record

Run now (works for live and deleted sessions; P19, P20):

```bash
kernel browsers get <ID> --include-deleted -o json > /tmp/kdbg-browser.json
jq '{session_id,name,headless,stealth,proxy,timeout_seconds,tags,usage_status,created_at,deleted_at,
     ran_s:(if .deleted_at then ((.deleted_at|sub("\\.[0-9]+";"")|fromdate)-(.created_at|sub("\\.[0-9]+";"")|fromdate)) else null end),
     telemetry_on:([.telemetry.browser//{}|to_entries[]|select(.value.enabled)|.key])}' /tmp/kdbg-browser.json
```

(This filter was run against a deleted failing session in the build: it printed `ran_s`, the proxy mode, tags and the enabled telemetry categories.)

Read the result:
- `deleted_at` present: the browser is gone. Skip step 4 (live checks). The record has `deleted_at`, not a `status` key (P19); do not look for one.
- Exit 1 with `Not_found` even with `--include-deleted`: the id is wrong, belongs to another project (retry with `--project <name>`), or the name does not resolve. Whether `--include-deleted` accepts a name is untested; prefer the id. Stop and ask.
- `ran_s` close to `timeout_seconds`: the browser was most likely reaped by its timeout, not crashed. The timeout countdown starts after the browser enters standby, which happens after about 5 s with no activity (any activity resets it), so also compare with the time of the last `cdp_disconnect` in step 3. Fix: raise `timeout_seconds` at create (../kernel/references/browsers.md).
- `headless: true`: no live view URL and no replays exist for this session (replay start returns 400 on headless, P18).
- `telemetry_on` lacks `console`, `network` or `page`: capture was off for those categories; there is no evidence to recover, and enabling later cannot backfill. Defaults (`connection`, `control`, `system`, `captcha`) always layer on, so you will still see CDP connects and API calls (P18, P19; P13 shows the layering on create). Not observed in the lab: system events such as OOM kills.
- `proxy` and `stealth`: note them for the diagnosis (unblock cases).

## 3. Read telemetry (the main evidence)

Events default to a 5 minute window. Always pass `--since <created_at>` and `--all`, or you will miss the failure (P19). `--until` in the future is rejected.

Run now, with `CREATED` set to `created_at` from step 2:

```bash
CREATED=$(jq -r .created_at /tmp/kdbg-browser.json)
kernel browsers telemetry events <SESSION_ID> --since "$CREATED" --all -o json > /tmp/kdbg-events.json
jq -r '.events|map(.event.type)|group_by(.)|map("\(.[0]) \(length)")[]' /tmp/kdbg-events.json
```

The JSON is `{ "events": [ { "seq": N, "event": { "ts", "type", "category", "source", "data" } } ] }`; `seq` is on the envelope and `ts` is microseconds (P18, P19). If the count is 0, report "no telemetry captured" and go to step 5.

Then pull only the failure signals, one line each, with URLs stripped of query strings (run against a deleted failing session: it surfaced the uncaught JS error, the 502 on the bad host's favicon and the aborted fetch):

```bash
jq -r '.events[]
  | select(.event.category=="console"
      or (.event.type=="network_loading_failed" and .event.data.target_type=="page")
      or (.event.type=="network_response" and .event.data.status>=400)
      or (.event.type|IN("page_crashed","system_oom_kill","service_crashed","proxy_error","monitor_disconnected","monitor_reconnected","cdp_disconnect")))
  | [.seq,(.event.ts/1000000|floor|todate),.event.type,
     (.event.data.status//.event.data.error_text//(.event.data.text//""|.[0:120])),
     ((.event.data.url//"")|sub("\\?.*";"?***"))] | @tsv' /tmp/kdbg-events.json | head -40
```

Only `console_error` and `network_*` text fields are used above. Do not print `.event.data` whole. The CLI also filters server-side: `--types console_error,network_loading_failed` and `--categories console` both work (P19); `--limit`/`--offset` page manually if `--all` is too much.

Traps in the data (lab-confirmed, P19):
- Uncaught JS errors arrive as `console_error`. There is no `page_error` event.
- `page.goto` to an unresolvable host does not throw. The signal is `page_navigation` events plus a 502 `network_response` on `/favicon.ico`, not a `network_loading_failed` for the document.
- A page `fetch` that returned HTTP 500 shows as `network_loading_failed` with `net::ERR_ABORTED` (canceled), not as a `network_response` 500. Do not read it as a network outage.
- Most `network_loading_failed` rows can be `target_type: service_worker` calls to a Kernel-internal endpoint. The filter above keeps only `page` targets.
- `monitor_disconnected` means the collector dropped; treat events until `monitor_reconnected` as incomplete.

Map signal to likely cause (state it as "likely", cite the event `seq`):

| Signal | Likely cause | Fix to propose |
|---|---|---|
| `system_oom_kill`, `service_crashed`, `page_crashed` | VM out of memory or renderer crash | More `memory` at create (default headless VM is 1 GiB; headless accepts 1, 2 or 4 GiB) and fewer parallel executors: ../kernel/references/browsers.md, ../kernel/references/control.md |
| `network_response` 403/429, or `network_loading_failed` on the document with a challenge page | Bot detection or rate limit | ../kernel/references/unblock.md (stealth, proxy, captcha) |
| `proxy_error` | Proxy path failed (a classification of branded 502/403 responses, only with network telemetry on; not a complete record of proxy refusals) | `proxy: { mode: 'direct' }` to isolate, or fix the proxy: ../kernel/references/unblock.md |
| `network_response` 403 with `X-Kernel-Proxy-Error: network_policy_denied` | Blocked by `network.allowed_hosts` (header seen on `page.goto` and `browsers curl` responses in P14; not checked on telemetry `network_response` events) | Add the host to the allow list (P14) |
| `ran_s` near `timeout_seconds`, last `cdp_disconnect` then silence | Idle timeout reaped the browser | Raise `timeout_seconds`, keep the client connected or delete explicitly: ../kernel/references/browsers.md |
| `console_error` after a navigation | Page-side JS failure (the site, not Kernel) | Fix selectors or wait for `page_navigation_settled` before acting |
| Only `connection`/`control`/`system` events | `console`/`network`/`page` were not enabled | Create with `telemetry` including them: ../kernel/references/observe.md |
| `monitor_disconnected` before the failure window | Evidence gap | Say the diagnosis is partial |

## 4. Live checks (only if `deleted_at` is null)

Run these once each, in this order, and stop as soon as the cause is clear. Replace `<ID>` with the session id.

1. Screenshot (P20): `kernel browsers computer screenshot <ID> --to /tmp/kdbg-shot.png`, then open the PNG with the Read tool. Tell the user what the page shows (blank, challenge, error page). Do not paste image bytes.
2. Page state (P20 ran this form): `kernel browsers playwright execute <ID> 'return await page.title()' -o json`. Returning an object such as `{ url: page.url(), title: await page.title() }` and a `success: false` result for a script error were not tested.
3. Chrome path vs VM path, for connection failures (CLI source; not run in the lab, so treat results as hints):

```bash
kernel browsers curl <ID> https://example.com -I
kernel browsers process exec <ID> -- curl -sI https://example.com
```

   Chrome-only failure points at fingerprinting, cookies or the proxy route (../kernel/references/unblock.md). Failure on both points at network or DNS.
4. Service logs (P20: flags exist, but the lab got no lines): `kernel browsers logs stream <ID> --source supervisor --supervisor-process chromium --follow=false | head -50`. If it prints `logs source not available` or `failed to open log path`, say logs were unavailable and move on. Do not retry in a loop.
5. Live view: only if the user wants to look. `kernel browsers view <ID>` prints a URL that is a bearer token; do not show it. Tell the user to run the command themselves. Absent on headless (P18).

## 5. Replays

Run `kernel browsers replays list <ID> -o json | jq 'map({replay_id,started_at,finished_at})'` (works after delete, P19). If empty, say no replay was recorded (a replay records only from the moment it is started, and a headless browser returns 400 on replays start, P18).

If there is one and the symptom is visual, offer to download it; do not download unasked:

```bash
kernel browsers replays download <ID> <REPLAY_ID> -f /tmp/kdbg-replay.mp4
```

(CLI source; not run in the lab. The SDK download returned a 200 mp4 immediately in P18; a 202 with `Retry-After` was never seen, so if you get a non-200, wait and retry once.) The replay is video only. Report the file path, not the replay URL.

## 6. Diagnose and propose a fix

1. State the most likely cause in one sentence, with the evidence (event `seq` and type, or a record field).
2. State what you ruled out and what you could not check (telemetry off, logs unavailable, session already deleted, headless so no replay).
3. Give one concrete fix for the user's code, in TypeScript with `@onkernel/sdk` when code is needed, and name the reference file to read (../kernel/references/browsers.md, ../kernel/references/unblock.md, ../kernel/references/observe.md, ../kernel/references/control.md). Add the docs URL when one applies: telemetry events https://kernel.sh/docs/browsers/telemetry/categories, replays https://kernel.sh/docs/browsers/replays.
4. If the failure will recur and capture was off, give the create-time fix: enable `console`, `network` and `page` telemetry (and start a replay on a headful browser) before the run. See ../kernel/references/observe.md.
5. Offer, do not run: re-running the failing step on a new browser with telemetry on.
6. Remove your temp files: `rm -f /tmp/kdbg-browser.json /tmp/kdbg-events.json /tmp/kdbg-shot.png /tmp/kdbg-replay.mp4`.

## Do not do

- Do not toggle `disable_default_proxy` or other routing on a live session to A/B test; that field is deprecated and had no direct effect in the lab (P14). Use `proxy: { mode: 'direct' }` on a new browser instead (../kernel/references/unblock.md).
- Do not call `kernel browsers delete ... -y`: `delete` has no `-y` flag (P20).
- Do not assume `kernel logs` or app logs cover browser failures; for Apps use `kernel logs <app> -i <invocation_id>` (P17).

## Output format

Report to the user in exactly this shape:

```
Session: <id> (<name>) - <live | deleted at <deleted_at>> - <headless | headful> - ran <ran_s>s of <timeout_seconds>s
Telemetry captured: <categories> | events read: <count> | window: <created_at> to now

Likely cause: <one sentence>
Evidence:
- seq <n> <event type> <short text, no URLs with tokens>
- <record field or live check result>
Ruled out / not checked: <list, each with the reason>

Fix:
- <concrete change, with code in TypeScript if needed>
- Read: ../kernel/references/<file>.md  (<docs URL>)

Next step: <one thing you can run for the user, if any>
```

Never include CDP, live view, replay or hosted URLs, keys, cookies or raw event payloads in that report.

> Verified in lab: 2026-10-20, @onkernel/sdk 0.127.0, kernel CLI 0.49.0 (the lab binary self-reported 0.47 in places, and the "no `-y` flag" finding was seen on that binary, P20). Probes: P18 (confirmed: events readable after delete, CLI `--types` filter, replay list/start/stop/download, headless replay 400; refuted: console-only isolation, SDK stream `type` filter, download 202), P19 (confirmed: `get --include-deleted`, `events --since --all --types --categories`, replays list after delete; refuted: `page_error`, bad-host goto throwing, fetch 500 as `network_response`, `status` on deleted record), P20 (confirmed: `get --include-deleted`, `playwright execute`, `computer screenshot`, exit codes and plain-text errors; unclear: `logs stream` returning lines). Not tested in the lab: `browsers curl` and `process exec` via the CLI, `replays download` via the CLI, `browsers view`, `page_crashed` / `proxy_error` / `system_oom_kill` events (names from the SDK types and docs only), `--include-deleted` with a name, `service_crashed` / `monitor_disconnected` / `monitor_reconnected` event names, the playwright object-return form and `success: false`, replays needing to start before the run, the `X-Kernel-Proxy-Error` shape on telemetry `network_response` events, the brew tap name.
