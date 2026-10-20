# Integrations: Playwright, Puppeteer, Stagehand, AI SDK, agent frameworks

Kernel gives you a browser; a framework gives you the loop. Pick the lightest option that works, and keep one rule: **you** create and delete the Kernel browser (`kernel.browsers.deleteByID(id)`), whatever the framework does on `close()`. Overview of all integrations: https://www.kernel.sh/docs/integrations/overview.

## Pick the integration

| If you have... | Use | Needs a model key? | Status |
|---|---|---|---|
| New code, you know the steps | `kernel.browsers.playwright.execute` (`references/control.md`) | no | verified live |
| Existing Playwright suite | `chromium.connectOverCDP(browser.cdp_ws_url)` (`references/control.md` section 11) | no | verified live |
| Existing Puppeteer code | `puppeteer-core` `connect({ browserWSEndpoint })` | no | verified live |
| A Vercel AI SDK agent that needs a browser tool | `@onkernel/ai-sdk` `playwrightExecuteTool` | yes, for the loop | tool verified live, loop untested |
| Natural-language `act` / `extract` steps | Stagehand | yes | untested (gated) |
| A screenshot-driven (computer use) loop you do not want to write | `@onkernel/cua-agent` | yes | untested (gated) |
| A coding-agent loop in TypeScript | `@onkernel/browser-loop` | yes | untested (gated) |
| A CLI-driven agent (shell commands, snapshots) | `agent-browser` with the `kernel` provider | no for the CLI | verified live |
| Agentic e2e tests | `@e2e-dev/kernel` | depends | untested |
| Traces of an agent run | Laminar | Laminar key | untested |

Anything not in this table: if it speaks CDP, hand it `cdp_ws_url` (https://www.kernel.sh/docs/integrations/overview).

## Playwright and Puppeteer over CDP

**If** you are porting existing code -> **Do** connect to `browser.cdp_ws_url`; see `references/control.md` section 11 for the Playwright version. Puppeteer:

```ts
import Kernel from '@onkernel/sdk';
import puppeteer from 'puppeteer-core';

const kernel = new Kernel();
const browser = await kernel.browsers.create(
  { headless: true, timeout_seconds: 120 },
  { maxRetries: 0, timeout: 30_000 }, // a retried create can duplicate
);
let pptr: Awaited<ReturnType<typeof puppeteer.connect>> | undefined;
try {
  pptr = await puppeteer.connect({ browserWSEndpoint: browser.cdp_ws_url });
  const page = (await pptr.pages())[0] ?? (await pptr.newPage());
  await page.goto('https://example.com');
  console.log(await page.title()); // Example Domain
} finally {
  await pptr?.disconnect();
  await kernel.browsers.deleteByID(browser.session_id).catch((e) => {
    if (!(e instanceof Kernel.NotFoundError)) throw e; // 404: the timeout already reaped it
  });
}
```

(ran live, trimmed.)

**Avoid** `disconnect()` or `close()` as cleanup (a browser in standby still counts toward your concurrency limit until deleted) and new code on CDP (use `playwright.execute`). **Source** verified live (connect and title confirmed); concurrency and standby limits in the Kernel docs.

## Vercel AI SDK: `@onkernel/ai-sdk`

**If** your agent loop already uses the Vercel AI SDK and needs a browser tool -> **Do** create the browser yourself, pass its id to the tool, delete it in `finally`.

```bash
# untested (not installed here); from the docs page
npm install @onkernel/ai-sdk zod ai @onkernel/sdk
```

```ts
import Kernel from '@onkernel/sdk';
import { playwrightExecuteTool } from '@onkernel/ai-sdk';

const kernel = new Kernel();
const browser = await kernel.browsers.create(
  { headless: true, timeout_seconds: 120 },
  { maxRetries: 0, timeout: 30_000 }, // a retried create can duplicate
);
try {
  const tool = playwrightExecuteTool({ client: kernel, sessionId: browser.session_id });
  // In a real loop pass it to the AI SDK: tools: { playwright_execute: tool }
  await tool.execute!({ code: 'await page.goto("https://example.com"); return await page.title();' }, undefined as any);
  const out = await tool.execute!({ code: 'return await page.title()' }, undefined as any);
  console.log(out); // { result: 'Example Domain', success: true, tab: { created: ..., target_id: ... } }
} finally {
  await kernel.browsers.deleteByID(browser.session_id).catch((e) => {
    if (!(e instanceof Kernel.NotFoundError)) throw e; // 404: the timeout already reaped it
  });
}
```

(ran live, trimmed. `undefined as any` is only for calling `execute` by hand outside the AI SDK loop.)

- The export is `playwrightExecuteTool`. Input the model sends: `{ code, timeout_sec? }` (docs default 60 s). It calls `client.browsers.playwright.execute(sessionId, { code, timeout_sec })`, so `result.success` handling from `references/control.md` applies: read `success`, `error`, `stdout`, `stderr` in the returned object.
- `client` is required at runtime (it throws `client is required` without it), even though the types mark it optional.
- One tab is bound: a second call in the same browser reuses it (`tab.created: false`).
- A model loop around the tool was not run (untested: needs a model key). Cookbook: https://github.com/kernel/cookbooks/tree/main/integrations/ai-sdk-agent.

**Avoid** sharing one browser between concurrent agent loops (a second call in the same browser reuses the bound tab), and letting the loop create browsers it never deletes. **Source** verified live; https://www.kernel.sh/docs/integrations/vercel/ai-sdk.

## Stagehand (v4 and v3)

**If** you want `act` / `extract` in natural language on a Kernel browser -> **Do** use v4 with the extension upload, or start from the template: `kernel create --name my-stagehand-app --language typescript --template stagehand`. The latest `@browserbasehq/stagehand` on npm was 4.2.1 on 2026-10-20 (a community pattern file says 4.2.0; the Kernel docs page states no version).

v4 runs as a Chrome extension, so a remote browser needs the extension on **its** filesystem before Stagehand connects:

```ts
// untested (needs a model key); adapted from the docs page (the docs wrap the upload in a `loadStagehandExtension(kernel, sessionId)` helper; `STAGEHAND_EXTENSION_DIR`, `STAGEHAND_EXTENSION_ZIP` and `kernel` are assumed defined)
import { Stagehand, localBrowser } from '@browserbasehq/stagehand';
const kb = await kernel.browsers.create(
  { stealth: true, timeout_seconds: 300 },
  { maxRetries: 0, timeout: 30_000 }, // a retried create can duplicate
);
await kernel.browsers.fs.uploadZip(kb.session_id, {
  dest_path: STAGEHAND_EXTENSION_DIR,          // <stagehand dist>/extension
  zip_file: createReadStream(STAGEHAND_EXTENSION_ZIP), // <stagehand dist>/assets/stagehand-extension.zip
});
const browser = await localBrowser.connect({ cdpUrl: kb.cdp_ws_url });
const stagehand = await Stagehand.create({
  browser,
  model: { modelName: '<provider>/<model>', apiKey: process.env.MODEL_API_KEY },
});
// v4: await browser.context.activePage(); extract() returns { data }
// cleanup, nested so a failed close never skips the delete:
// try { await stagehand.close() } finally { try { await browser.close() } finally { await kernel.browsers.deleteByID(kb.session_id).catch(ignoreNotFound) } }
```

- v3 differs (labelled v3 only): it takes `env: 'LOCAL'` and `localBrowserLaunchOptions: { cdpUrl }`, uses `stagehand.context.pages()[0]`, and `extract` returns the object directly.
- Model ids are provider-prefixed (`<provider>/<model>`), never bare.
- v4 does not close browsers it did not launch, so the delete is yours.

**Avoid** mixing v3 and v4 snippets (v4 removed `env`, `localBrowserLaunchOptions` and `modelClientOptions`), and `stealth: true` as a reflex (`references/unblock.md`). **Source** gated (docs only); https://www.kernel.sh/docs/integrations/stagehand.

## Computer-use and agent loops: `@onkernel/cua-agent`, `@onkernel/browser-loop`

**If** you want a ready-made screenshot loop -> **Do** `CuaAgent` from `@onkernel/cua-agent` (install with `npm install @onkernel/cua-agent @onkernel/cua-ai @onkernel/sdk`); you create the browser, pass `browser` and `client`, and set the model's provider key next to `KERNEL_API_KEY`. If you write the loop yourself, the cycle is screenshot, model, `kernel.browsers.computer.*` action (https://www.kernel.sh/docs/integrations/computer-use/overview, `references/control.md` section 4).

- Both need Node 22.19 or newer (npm metadata). `@onkernel/browser-loop` has peer dependencies on `@earendil-works/pi-agent-core` and `@earendil-works/pi-coding-agent`.
- `@onkernel/cua-agent` pins `@onkernel/sdk` to an exact old version (0.49.0 at 0.10.0), so expect a nested duplicate SDK. Do not pass objects between the two SDK copies' classes without checking (unverified: not installed).
- Runtime of both: not run (gated: needs a model key and no install was done).

**Avoid** hardcoding a model ref from a docs page (read the provider table, "Switch providers by changing the model ref", on https://www.kernel.sh/docs/integrations/computer-use/overview). **Source** verified live (npm metadata confirmed, runtime gated).

## Agent Browser (Vercel CLI)

**If** the agent drives the browser by shell commands (open, snapshot, click by ref) -> **Do** use the native provider and set every variable explicitly:

```ts
import { spawnSync } from 'node:child_process';

const env = {
  ...process.env, // carries KERNEL_API_KEY
  AGENT_BROWSER_PROVIDER: 'kernel',
  KERNEL_HEADLESS: 'true',
  KERNEL_STEALTH: 'false',
  KERNEL_TIMEOUT_SECONDS: '120',
};
spawnSync('npx', ['--yes', 'agent-browser', 'open', 'https://example.com'], { env, encoding: 'utf8' });
// ... later, ALWAYS:
spawnSync('npx', ['--yes', 'agent-browser', 'close'], { env, encoding: 'utf8' });
```

(ran live, trimmed: printed `Example Domain`, then `Browser closed`; zero active browsers afterwards.)

- The docs page gives defaults of headless false and stealth true; a community skill (agent-browser 0.33.0) says headless true and stealth false. The defaults were not tested, so do not rely on either; set `KERNEL_HEADLESS`, `KERNEL_STEALTH` and `KERNEL_TIMEOUT_SECONDS` yourself.
- It creates browsers with no tags: `kernel browsers list --tag ...` cannot find them. Track them by time or close via `agent-browser close`.
- Use headful (`KERNEL_HEADLESS=false`) when a human needs live view.
- `KERNEL_PROFILE_NAME` and the `-p kernel` flag form were not tested (an older community skill says the profile variable failed in 0.33.0; unverified for 0.39.1). To keep state, create the browser with the SDK (profiles: `references/profiles.md`) and attach: `agent-browser connect "$CDP_URL"` (docs, untested), then `agent-browser close` and `kernel browsers delete <id>`.

**Avoid** forgetting `close` (the Kernel browser lives until its timeout) and putting the CDP URL in a command line or log (it is a credential). **Source** verified live (env path); https://www.kernel.sh/docs/integrations/vercel/agent-browser.

## Claude Agent SDK, e2e, Laminar, Browser Use

| If | Do | Avoid | Source |
|---|---|---|---|
| You build an agent with the Claude Agent SDK | `kernel create --template claude-agent-sdk` (pick TypeScript); it creates a stealth browser and exposes an in-process `execute_playwright` tool; deploy with `kernel deploy index.ts --env-file .env`; needs a model key and `KERNEL_API_KEY` | Writing a second Playwright wrapper; committing the `.env` (untested: not run) | https://www.kernel.sh/docs/integrations/claude/claude-agent-sdk |
| You run agentic e2e tests | `npm install --save-dev @e2e-dev/kernel @onkernel/sdk`, then `kernel({ viewport })` as the web target's `browser`; `KERNEL_API_KEY` in CI; `scope: "attempt"` for a browser per attempt (untested) | Assuming the framework deletes browsers after a crashed run: check `kernel browsers list` | https://www.kernel.sh/docs/integrations/e2e |
| You want traces of agent runs | Laminar wraps Playwright, Browser Use or Stagehand and needs `LMNR_PROJECT_API_KEY`; call `Laminar.flush()` before exit (untested) | Treating Laminar recordings as Kernel replays: they are separate (https://www.kernel.sh/docs/integrations/laminar; Kernel replays: `references/observe.md`) | https://www.kernel.sh/docs/integrations/laminar |
| You see a Browser Use guide | It is Python (`cdp_url=kernel_browser.cdp_ws_url`); in TypeScript use any CDP client above | Copying its Python into a TypeScript project | https://www.kernel.sh/docs/integrations/browser-use |
| You only want a coding agent (Claude Code, Codex, etc.) to use Kernel | MCP or the plugin, not a framework: `references/mcp.md` | Building a loop you do not need | https://www.kernel.sh/docs/integrations/overview |

## Cross-cutting rules

- Whatever the framework, give the browser a `timeout_seconds`, tag it with a run id, and delete it in `finally`. Frameworks that "launch" browsers do not own a Kernel browser they did not create, and agent loops that crash skip cleanup.
- Keep the Kernel key out of framework configs; `new Kernel()` reads `KERNEL_API_KEY`. Model keys belong in the environment, not in code.
- Hand a framework `cdp_ws_url` only in-process; never print it or pass it as a CLI argument you log.

Verified live 2026-10-20 (Hobbyist plan); types re-checked on @onkernel/sdk 0.128.0. Evidence ledger: verified-facts.md in the plugin repository.
