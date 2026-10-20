---
name: kernel
description: >-
  Steering for Kernel (kernel.sh) cloud browsers in TypeScript projects: the @onkernel/sdk, the `kernel` CLI, the Kernel MCP server and KERNEL_API_KEY. Use when code or commands create, drive, debug or scale Kernel browsers or Kernel Apps: bot detection and proxies, logins and profiles, vaults, pools, live view, replays, telemetry, API keys and projects. Not for Linux or Jupyter kernels, Semantic Kernel, or other browser vendors.
---

# Kernel for TypeScript projects

Kernel is browser infrastructure, not an agent framework: your code decides what to do, Kernel runs the browser that does it (https://www.kernel.sh/docs/overview/concepts). This skill tells you when to reach for each Kernel capability and the traps that cost people money, slots and secrets. Code here is TypeScript (`@onkernel/sdk`, `playwright-core`); the `kernel` CLI and the Kernel MCP are covered because they are how you operate Kernel from a terminal.

Rule zero: if the task can be done through an API or an MCP server, use that and do not start a browser (https://www.kernel.sh/docs/overview/why-kernel).

## Pick the path

1. **Does the target service offer its own API or MCP server?** Then call that and start no browser.
2. **Exploring, debugging or one-off checks right now:** the `kernel` CLI or the Kernel MCP (`references/cli.md`, `references/mcp.md`). **Code that ships:** `@onkernel/sdk` (`references/sdk-client.md`).
3. **Create a browser per task, on demand.** Creating one takes well under a second (a few hundred ms from a laptop), so do not cache browsers "for speed" (pools are for fixed config at steady traffic: `references/scale.md`). Set `timeout_seconds` on purpose. Headful is the default and the right choice when anyone watches, you record a replay (headless rejects replays), or the site defends itself; headless only for unwatched, undefended, high-volume work, and give it `memory: '4GiB'` if one browser runs many parallel tabs or named executors (the 1 GiB default starves around the fifth).
4. **Drive the page**, in this order: `kernel.browsers.playwright.execute` (default), computer controls for the one step selectors cannot do, and `chromium.connectOverCDP` from `playwright-core` only for existing Playwright or Puppeteer code (https://www.kernel.sh/docs/introduction/control). Details: `references/control.md`.
5. **Delete the browser yourself**, in `finally`: `kernel.browsers.deleteByID(id)`. Closing a Playwright connection only disconnects.
6. **Need something specific?** Use the router below.

The shape every Kernel task should have (ran live; type-checks against the SDK):

```ts
import Kernel from '@onkernel/sdk';

const kernel = new Kernel();
const browser = await kernel.browsers.create(
  {
    headless: true, // fine for an unwatched, undefended one-off; omit it (headful is the default) for defended sites or replays
    timeout_seconds: 120, // runtime plus a margin
    tags: { run: process.env.RUN_ID ?? 'local' }, // lets you find and sweep this run's browsers if the process is killed
  },
  { maxRetries: 0, timeout: 30_000 }, // a retried create can duplicate: see sdk-client.md
);
try {
  const res = await kernel.browsers.playwright.execute(
    browser.session_id,
    { code: "await page.goto('https://example.com'); return await page.title();", timeout_sec: 30 },
    { maxRetries: 0, timeout: 40_000 }, // request timeout > timeout_sec
  );
  if (!res.success) throw new Error(String(res.error));
  console.log(res.result);
} finally {
  // a 404 means the timeout already reaped the browser: that is fine
  await kernel.browsers.deleteByID(browser.session_id).catch((e) => {
    if (!(e instanceof Kernel.NotFoundError)) throw e;
  });
}
```

`finally` does not run if the process is killed or a call hangs: wrap long calls in a timeout, and keep the run tag so `kernel browsers list --tag run=<id>` finds leftovers.

Read the matching reference before writing a call: this file is the summary, not the spec.

## Non-negotiables

| If you are... | Do | Avoid | Source |
|---|---|---|---|
| Creating any browser | Delete it in `finally` with `deleteByID` (CLI: `kernel browsers delete`). Report any browser you left alive. | `browser.close()` as cleanup: it disconnects only, the browser keeps its concurrency slot until deleted or its timeout ends, and a profile marked `save_changes` is saved when you delete the browser, never on disconnect | https://www.kernel.sh/docs/browsers/termination |
| Choosing `timeout_seconds` | Set it to the expected runtime plus a margin (default 60, range 10 to 259200). It counts from the moment the browser goes idle (about 5 s after the last client disconnects) and is the backstop for crashes, not the cleanup | Using it to free slots (delete instead), or fearing idle cost: idle browsers are free but still count toward concurrency; GPU browsers never go idle | https://www.kernel.sh/docs/browsers/standby |
| Driving a page in new code | `playwright.execute(id, { code, timeout_sec })` and check `result.success` | New code on `connectOverCDP`; assuming a page error rejects the promise (it returns HTTP 200 with `success: false`) | https://www.kernel.sh/docs/browsers/playwright-execution |
| Handling secrets | Read the key from `KERNEL_API_KEY` (`new Kernel()` does); use vaults or Managed Auth for site credentials. CDP, live-view, replay and hosted-login URLs are credentials: fetch them at runtime on the server and give them only to the user they are for, over a channel you control | Keys, passwords or those URLs hard-coded, logged, committed, put in a prompt, passed as CLI arguments or shipped in a frontend bundle | https://www.kernel.sh/docs/vaults/overview |
| Calling something with side effects (browser create, invoke, deploy, `playwright.execute`, REPL, WebMCP invoke, payments, search) | Pass `{ maxRetries: 0, timeout: <operation timeout + margin> }` per request; tag browsers with a run id and reconcile with `list`; handle 429 with one bounded backoff | Default retries (the SDK retries connection errors, 408, 409, 429 and >=500, and never sends an idempotency key, so a retried create can duplicate); unbounded retry loops | `references/sdk-client.md` |
| Starting cost-bearing work, or seeing a 403 | `kernel org limits get -o json` and `kernel org entitlements -o json` first; read the 403 body (plan gate, spending cap, scope or project mismatch) | Guessing access from plan names | https://www.kernel.sh/docs/browsers/concurrency-and-limits |
| Scoping to a project | `projectID` takes an ID only; `project` takes an ID or exact name (and is what the CLI's `--project` and `KERNEL_PROJECT` mean) | `projectID: process.env.KERNEL_PROJECT` (that variable may hold a name) | https://www.kernel.sh/docs/info/projects |
| Copying a field from docs prose or another skill, or unsure a feature exists | Trust the API reference and the installed types; check `references/does-not-exist.md` first | Deprecated fields still shown in prose and in Kernel's own sample skills (`proxy_id` or `disable_default_proxy` on browsers, `datacenter` proxies, `persistent`); invented method names | https://www.kernel.sh/docs/llms.txt |
| Catching errors | `catch (e) { if (e instanceof Kernel.APIError) ... }`: `e.status`, `e.error` (the parsed JSON body, e.g. `{ code, message }`) and `e.headers?.get('x-request-id')`; a 404 from `deleteByID` after a timeout reaped the browser is fine; treat 429 and 529 as "slow down" | Swallowing errors; assuming a page error rejects the promise (`playwright.execute` returns `success: false`) | `references/sdk-client.md` |

## Verify instead of remembering

Kernel releases every one to three days, so names and limits in memory go stale. When a name, flag, default or limit decides what you write:
- read the installed types in `node_modules/@onkernel/sdk` (the package ships no `api.md`; if it is not installed yet, `npm i @onkernel/sdk`, Node 20+), `references/api-map.md`, and `kernel <command> --help`;
- or read https://www.kernel.sh/docs/llms.txt, the API reference at https://www.kernel.sh/docs/api-reference, or ask the Kernel MCP `search_docs`;
- if a doc page and the installed types disagree, the types decide the call shape and a live call decides the truth;
- anything these files mark "(unverified)" is not settled: test it on one throwaway browser before relying on it.

## Router: which reference to read

| Reference | Read when |
|---|---|
| `references/sdk-client.md` | Writing the client: options, env vars, retries, errors, pagination, project scoping |
| `references/browsers.md` | Creating browsers: lifecycle, timeouts, standby, memory, viewport, regions, GPU |
| `references/control.md` | Scraping, extracting data or taking screenshots; driving the browser: Playwright execute, computer controls, CDP, REPL, WebMCP, files, processes, HTTP through the browser |
| `references/unblock.md` | A site blocks, challenges or throttles you: stealth, proxies, captcha, config registry |
| `references/logins.md` | The task needs a logged-in session: Managed Auth (hosted, React embed, programmatic), stored credentials, vault fill, 1Password, MFA |
| `references/profiles.md` | State must survive between browsers: saving, loading, who may write |
| `references/vaults-payments.md` | Credentials or cards must reach a page without the model seeing them |
| `references/scale.md` | Many browsers or bursts: concurrency, pools, queueing |
| `references/apps.md` | Long, stateful or event-triggered work: Kernel Apps, deploy, invoke, logs |
| `references/observe.md` | You will need to debug later, or a human must watch: telemetry, replays, live view |
| `references/account.md` | Keys, projects, spending, audit logs, firewalls, Terraform |
| `references/cli.md` | Operating Kernel from the terminal: command map, JSON output, verification commands |
| `references/mcp.md` | Using the Kernel MCP server for management and quick checks |
| `references/integrations.md` | Playwright, Puppeteer, Stagehand, Vercel AI SDK, agent frameworks |
| `references/api-map.md` | Exact method, route, flag or tool names |
| `references/does-not-exist.md` | Before using a name from memory |
| `references/verified-against.md` | How current this plugin's facts are |

## Workflows

- `/kernel:debug-session <session-id>`: why did a run fail? (works after the browser was deleted)
- `/kernel:login <domain>`: get a logged-in browser for a site
- `/kernel:audit [path]`: review this project's Kernel usage
- `/kernel:profile-site <url>`: find out what bot detection a site uses and what Kernel config beats it
- `/kernel:diff-profiles <a> <b>`: why does a login work in one profile and not another
- `/kernel:site-skill`: turn a workflow that worked into a reusable skill for that site

## What this plugin cannot tell you

Payments, MPP, Link, Visa cards, GPU, regions, spending caps and SSO flows depend on your plan and account. Read `kernel org entitlements -o json` rather than assuming, and never retry a payment.
