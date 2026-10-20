# Apps: deploy code that runs next to the browser

Read this when work is long, stateful, event-triggered or a computer-use loop, and you are deciding whether to deploy a Kernel App, or you are writing, deploying, invoking, stopping or debugging one. Default answer for short flows: no App, call `@onkernel/sdk` from your own service.

Vocabulary you need: an App is deployed code, an action is one registered entry point, an invocation is one run of an action (https://www.kernel.sh/docs/apps/develop). Apps are created only by deploying; there is no `apps.create` (`references/does-not-exist.md`).

## S8. Should this be an App?

**If** the job runs minutes to an hour, keeps state between steps, is triggered by an event or schedule, or is a computer-use loop where a CDP round trip hurts -> **Do** deploy it as an App: your code runs co-located with the browsers it creates (https://www.kernel.sh/docs/apps/develop). **If** it is a short flow inside one request, or your service already holds the browser -> **Do** call the SDK directly. -> **Avoid** Apps for short flows: you add a deploy step, a version to manage and a second billing line. -> **Source** https://www.kernel.sh/docs/introduction/control, https://www.kernel.sh/docs/info/pricing (invocation compute is billed per second of execution, separately from browsers; failed and cancelled runs still bill; queued time and idle deployed apps do not).

## S9. Write the action

**If** you are writing an action -> **Do**:
- `const app = kernel.app('<unique-name>')`, then `app.action('<name>', async (ctx: KernelContext, payload) => ...)`. Handlers must accept `ctx` (a zero-argument handler throws at load); `KernelContext` is `{ invocation_id: string }` (SDK `core/app-framework.d.ts`).
- Pass `invocation_id: ctx.invocation_id` to every `kernel.browsers.create` inside the action, plus `tags` and a `timeout_seconds` you chose. That ties the browser to the run so it can be listed and reaped.
- Delete the browser in `finally` with `kernel.browsers.deleteByID(session_id)` (not `browser.close()`, which only disconnects: `references/browsers.md`).
- Return plain JSON. It becomes the invocation `output` string; the caller parses it.
- Keep payloads small and put big data in object storage or browser files (see S11 for what was observed).

**Avoid**:
- Browsers created without `invocation_id`: stopping the run cannot find them (S12).
- Logging `browser_live_view_url`, cookies or keys with `console.log`: action logs persist with the app's logs (the scaffolded sample does log the live-view URL; strip it).
- Shipping the scaffold unedited: it hardcodes `kernel.app("ts-basic")` in code and docs, leaves `"name": "ts-basic"` in `package.json`, prints a "Next steps" block that says `kernel invoke ts-basic get-page-title`, pins an old `@onkernel/sdk` (`^0.23.0` when tested), and its `create-browser-for-testing` action uses `timeout_seconds: 3600`. After scaffolding run `npm i @onkernel/sdk@latest` (or your package manager's equivalent), rename the app in `index.ts`, `package.json` and your invoke command, and remove that action before the first deploy.

```ts
// browser driven with playwright.execute, not connectOverCDP
import Kernel, { type KernelContext } from "@onkernel/sdk";

const kernel = new Kernel();
const app = kernel.app("my-app"); // rename: the scaffold says ts-basic

app.action<{ url: string }, { title: string }>(
  "get-page-title",
  async (ctx: KernelContext, payload?: { url: string }) => {
    if (!payload?.url) throw new Error("URL is required");
    new URL(payload.url); // throws on an invalid URL
    const browser = await kernel.browsers.create(
      {
        invocation_id: ctx.invocation_id,
        headless: true,
        timeout_seconds: 120,
        tags: { app: "my-app", run: ctx.invocation_id },
      },
      { maxRetries: 0, timeout: 60_000 },
    );
    try {
      const res = await kernel.browsers.playwright.execute(
        browser.session_id,
        {
          // execute has no params field: put the runtime value in the code string with JSON.stringify
          code: `await page.goto(${JSON.stringify(payload.url)}); return await page.title();`,
          timeout_sec: 60,
        },
        { maxRetries: 0, timeout: 90_000 },
      );
      if (!res.success) throw new Error(`execute failed: ${String(res.error)}`);
      return { title: String(res.result) };
    } finally {
      // a 404 means the timeout already reaped the browser: that is fine
      await kernel.browsers.deleteByID(browser.session_id).catch((e) => {
        if (!(e instanceof Kernel.NotFoundError)) throw e;
      });
    }
  },
);
```

Inside an action, `new Kernel()` just works: Kernel injects a per-deployment `KERNEL_API_KEY` (S10).

**Source** https://www.kernel.sh/docs/apps/develop.

## S10. Deploy

**If** you are shipping an App -> **Do**: run it from the project root with the entrypoint next to `package.json`.

```bash
kernel deploy index.ts --version v1 -o json   # exit 0
```

- `-o json` prints one JSON event per line. Do not read the stream into context; pull the last `app_version_summary` event, which carries `app_name`, `version` and `actions`.
- Layout: `package.json` with `"type": "module"`, `tsconfig.json`, one lockfile (`bun.lock`, `package-lock.json` or `pnpm-lock.yaml`; recommended, a deploy without one succeeded in testing), `.gitignore` excluding `node_modules`.
- Flags (CLI source, `kernel deploy --help`): `--version <v>` (default `latest`), `--force` (overwrite the same version label), `-e/--env KEY=VALUE` (repeatable), `--env-file <file>` (repeatable). Secrets go in `--env` / `--env-file`, never in the repo. Per-invocation secrets may go in the payload only if your app encrypts them (see Avoid in S11).
- Region: `kernel deploy --region` currently accepts only `aws.us-east-1a` per `--help`, while invocation events may show another region name; treat the region as informational.
- Scaffold: `kernel create -n <name> -l ts -t sample-app -y` (non-interactive; verified live).
- GitHub source: `kernel deploy github --url ... --ref ... --entrypoint ... [--path <subdir>]` (docs only, (unverified): not run).

**Avoid**:
- **Subdirectory entrypoints.** Verified live: the docs line "entrypoint can be located in a subdirectory" is wrong: `kernel deploy src/app.ts` and `./src/app.ts` both failed with `ERROR: Invalid_entrypoint: entrypoint not found: entrypoint "app.ts" not found in archive`, repeated identically. The CLI reference ("must live in the project root") is right. Keep the entrypoint at the root and import from `src/`.
- **Setting `KERNEL_API_KEY` or `ENTRYPOINT_RELPATH` with `--env`.** They are reserved. Verified live: `--env KERNEL_API_KEY=x` exits 0 with no error, and the action still sees the injected key (`keyIsX: false`). It is silently ignored, so a script that "passes" a key this way is not using it. To call Kernel with your own longer-lived key, put it under another name and pass it: `new Kernel({ apiKey: process.env.MY_KERNEL_API_KEY })` (SDK option `apiKey`; docs section "Using a different key" on https://www.kernel.sh/docs/apps/deploy; `// untested`).
- Reading build noise as failure: `#5 ERROR: failed to configure registry cache importer ... not found` and pnpm "Update available" lines appeared in a deploy that succeeded. Judge by exit code and the `app_version_summary` event.
- Printing the deploy event stream or action logs into context without a filter.

```ts
// prove an env var arrived without printing it
app.action("probe-env", async (_ctx: KernelContext) => ({
  keyPresent: Boolean(process.env.KERNEL_API_KEY),
  keyIsX: process.env.KERNEL_API_KEY === "x",
}));
```

**Source** https://www.kernel.sh/docs/apps/deploy, https://www.kernel.sh/docs/reference/cli/apps, https://www.kernel.sh/docs/info/api-keys.

## S11. Invoke

**If** the run is short (the docs say sync times out at 100 s) -> **Do** invoke sync. **If** it may run longer -> **Do** invoke async and follow it:

```ts
import Kernel from "@onkernel/sdk";
const kernel = new Kernel();

const invocation = await kernel.invocations.create(
  {
    app_name: "my-app",
    action_name: "get-page-title",
    version: "v1",
    payload: JSON.stringify({ url: "https://example.com" }), // payload is a JSON string
    async: true,
    async_timeout_seconds: 120,
  },
  { maxRetries: 0 }, // invoke is not idempotent: a retry starts a second, billed run
);

for await (const evt of await kernel.invocations.follow(invocation.id)) {
  if (evt.event === "invocation_state" && evt.invocation.status !== "queued" && evt.invocation.status !== "running") break;
}
const done = await kernel.invocations.retrieve(invocation.id);
console.log(done.status, done.output); // output is a JSON string: JSON.parse it
```

- Async returns status `queued` at once; default async timeout is 15 minutes, `async_timeout_seconds` 10 to 3600 (https://www.kernel.sh/docs/apps/invoke, SDK types).
- `follow` emits `invocation_state`, `deployment_state` and `log` events. Stop on the first terminal `invocation_state` (`succeeded` or `failed`), and read the result from `retrieve`. Polling `retrieve` also works.
- Sync SDK invoke (`invocations.create` without `async`) was not run: `// untested`. Set `maxRetries: 0` and a request timeout above 100 s if you use it.

CLI:

```bash
kernel invoke my-app get-page-title -v v1 -p '{"url":"https://example.com"}' -o json      # blocks, streams JSONL
kernel invoke my-app get-page-title -v v1 --sync -p '{"url":"https://example.com"}' -o json  # one object, CLI times out at 60 s
kernel invoke my-app payload-size -v v1 -f payload.json -o json                          # payload from a file
```

**Avoid**:
- **Forgetting `-v`.** `-v` defaults to `latest`. After `kernel deploy --version v1`, a bare `kernel invoke` fails with HTTP 400 `deployment_not_found ... version 'latest'` (verified live). Deploy without `--version`, or always pass `-v`. In SDK code `version` is required by the type.
- **Believing the CLI returns immediately.** The CLI reference says so; verified live: `kernel invoke` blocks and streams until the run ends. Use `--sync` for one JSON object (it times out at 60 s) or SDK async for anything long. Do not run a long `kernel invoke` in a foreground tool call without a timeout.
- **Trusting the 64 KB payload limit in either direction.** Docs disagree (64 KB in `apps/develop` and the CLI table, 4.5 MB in `apps/invoke`). Verified live: `-f` with 100 KB and with 1 MB both succeeded. Not tested: 4.5 MB, inline `-p` at size. Keep payloads small anyway and pass pointers to big data.
- Putting end-user secrets in plain payload: encrypt them in your app (https://www.kernel.sh/docs/apps/deploy#per-invocation-secrets).
- Default retries on `invocations.create` (use `{ maxRetries: 0 }`; see `references/sdk-client.md`).

**Source** https://www.kernel.sh/docs/apps/invoke, https://www.kernel.sh/docs/apps/status.

## S12. Stop a run

**If** an invocation is stuck, looping or no longer wanted -> **Do** set it to failed, then reap its browsers yourself and verify:

```ts
await kernel.invocations.update(id, { status: "failed", output: JSON.stringify({ error: "cancelled" }) });
await kernel.invocations.deleteBrowsers(id); // do not rely on update alone
```

```bash
kernel invoke update <invocation_id> --status failed        # untested
kernel invoke browsers <invocation_id> -o json              # untested
kernel invoke delete-browsers <invocation_id>               # untested
kernel browsers list --status active --tag app=my-app -o json   # prove nothing is left (list with --tag verified live)
```

**Avoid**: trusting `update(failed)` to destroy the browsers. The docs say terminating an invocation destroys its browsers. Verified live: that did not hold in the observed window: after `update` returned `failed`, the tagged browser was still active 10 s later (CLI active count 1); only `deleteBrowsers(id)` took it to 0. Longer waits were not tested, so the browser may be reaped later. Also: Ctrl+C in a blocking `kernel invoke` is the CLI's way to cancel (docs: browsers are cleaned up; not verified in the lab).

A browser that the action created with `invocation_id` and tags is findable by `deleteBrowsers(id)` and by `--tag`. The SDK `invocations.listBrowsers` items had no `status` field when tried, so check liveness with `kernel browsers list --status active --tag ...`.

**Source** https://www.kernel.sh/docs/apps/invoke.

## S13. Logs and billing

**If** you need output of a run after it finished -> **Do** ask for that invocation by id:

```bash
kernel invoke history --app my-app --status failed --limit 5 -o json   # untested: find the id
kernel logs my-app --version v1 -i <invocation_id>                     # includes the invocation header
```

SDK: `kernel.invocations.follow(id)` yields `log` events (`evt.message`, `evt.timestamp`); pass `{ since: '5m' }` to replay recent events (SDK type; only live following was tried).

**Avoid**:
- **`kernel logs <app> --since 10m` without `-i`.** Verified live: exit 0 but only 3 header lines (streaming, showing recent logs, Deployment ID) and no action output, also for `--since 1h`. Without `-i` it reads as "no logs". Always pass `-i <invocation_id>`.
- Concluding "no logs after the fact": past logs are available through `-i`. `kernel logs --follow` was not run in the lab: `(unverified)`.
- Lines over 64 KiB are truncated; log a reference to big data.
- Build problems: `kernel deploy logs <deployment_id> --follow` (docs and CLI source, not run).

Billing: only the time your code executes, per second; failed and cancelled runs still bill. Browsers the run creates bill on their own (https://www.kernel.sh/docs/info/pricing).

**Source** https://www.kernel.sh/docs/apps/logs, https://www.kernel.sh/docs/info/pricing.

## S14. CI and cleanup

**If** CI deploys the App -> **Do** `kernel deploy index.ts --version "$(git rev-parse --short HEAD)" -o json`, and invoke that exact version. **Avoid** re-deploying a label that already exists without `--force` (docs: duplicate labels need `--force`; (unverified): the error text was not captured). The `$(git rev-parse ...)` form was not run (`# untested`; only `--version v1` and `v2` were deployed). Use `-y` on destructive commands.

**If** you made a throwaway App in a test -> **Do** remove it and prove it is gone:

```bash
kernel app delete my-app -y            # prints "Deleted 2 deployment(s)"
kernel app list --name my-app -o json  # []
kernel app history my-app -o json      # []
```

**Avoid** `kernel app list --query ...`: it is not a flag of `app list` in 0.49.0 (only `--name`, `--version`, `-o`); it prints "No applications found" and proves nothing. `app delete` removes every deployment of that app unless you pass `--version`.

**Source** https://www.kernel.sh/docs/reference/cli/apps.

---

Verified live 2026-10-20 (Hobbyist plan); types re-checked on @onkernel/sdk 0.128.0. Evidence ledger: https://github.com/yigitkonur/plugin-kernel-sh/blob/main/verified-facts.md
