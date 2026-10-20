# SDK client: setup, env vars, retries, errors, pagination, projects

Read this when you write `new Kernel(...)`, see a 401/404/429/5xx from the SDK, wonder why a call ran twice, or need to scope work to a project. Default answer: `new Kernel()` with `KERNEL_API_KEY` in the environment, and change options only for a reason listed here.

## K1. Create the client

**If** you are writing shipped code -> **Do** `import Kernel from '@onkernel/sdk'; const kernel = new Kernel();`. It reads `KERNEL_API_KEY` and throws at construction if it is missing or empty. -> **Avoid** `apiKey: '...'` literals, keys in code, prompts, logs, CLI args or frontend bundles. -> **Source** https://www.kernel.sh/docs/start/quickstart, SDK `src/client.ts`.

Options worth knowing (installed SDK 0.128.0):

| Option | Default | Use it when |
|---|---|---|
| `timeout` (ms) | 60000 | A call legitimately runs longer (execute, deploy, invoke): raise per request, not globally |
| `maxRetries` | 2 | A call has side effects: set 0 (see K2) |
| `baseURL` / env `KERNEL_BASE_URL` | `https://api.onkernel.com/` | Pointing at another host |
| `environment` | `production` | Almost never; see Avoid below |
| `project` / `projectID` | none | Scoping to a project (K5) |
| `logLevel` / env `KERNEL_LOG` | `warn` | Debugging: `info` or `debug`; `debug` logs the request options (including the body) plus response status and headers, so never ship it |
| `defaultHeaders` / env `KERNEL_CUSTOM_HEADERS` | none | Tagging requests |
| `fetch`, `fetchOptions`, `logger` | global fetch, console | Proxies, custom fetch, pino/winston |

**Avoid** passing both `environment` and `baseURL` (or setting `KERNEL_BASE_URL` while passing `environment`): the constructor throws "Ambiguous URL". Pass `baseURL: null` with `environment` if you must.

Env vars the SDK reads (grep of installed 0.128.0): `KERNEL_API_KEY`, `KERNEL_BASE_URL`, `KERNEL_LOG`, `KERNEL_CUSTOM_HEADERS`, `KERNEL_SUPPRESS_BUN_WARNING`, `KERNEL_BROWSER_ROUTING_SUBRESOURCES`. It does NOT read `KERNEL_PROJECT` (only the CLI does).

**Runtime**: Node 20+ (non-EOL); Stagehand 4.x needs Node >= 22.18; Bun 1.0+ works but logs a warning about Playwright CDP issues, silenced with `KERNEL_SUPPRESS_BUN_WARNING=true`. The SDK needs a global `fetch`. **Source** SDK README "Requirements", `src/client.ts`.

## K2. Retries and timeouts

**If** a call is safe to repeat (list, retrieve, delete by id) -> **Do** keep the defaults. -> **Avoid** hand-rolled 429 loops on top of them.

**If** a call has side effects (browser create, app invoke, deploy, playwright `execute`, REPL/code run, payments, search, auth `connections.create` / `login`, vault `performOperation`, pool `acquire`, profile writes) -> **Do** pass per-request options: `{ maxRetries: 0, timeout: <operation timeout + margin> }`. -> **Avoid** default retries there: a timed-out or 5xx request can already have run on the server, and the retry runs it again.

```ts
// untested (shape from SDK README "Retries" and "Timeouts")
const browser = await kernel.browsers.create(
  { name: 'run-123', tags: { run: 'run-123' } },
  { maxRetries: 0, timeout: 30_000 },
);
```

What the SDK retries (source `shouldRetry`, `src/client.ts`): connection errors, timeouts, 408, 409, 429, any status >= 500, and any response with `x-should-retry: true`; never when `x-should-retry: false`. Backoff is 0.5 s doubling to a cap of 8 s, but `retry-after-ms` or `Retry-After` from the server wins. A request timeout is itself retried, so worst case is roughly `timeout * (maxRetries + 1)`.

**Idempotency**: the client sends no idempotency key (the header is unset in `src/client.ts`; `options.idempotencyKey` has no effect here). To make create-style calls safe after an ambiguous failure, tag the resource with a run id (`tags`, `name`) and reconcile with `list` before retrying. **Source** SDK `src/client.ts`, README. (unverified: no real 408/409/429/5xx was provoked; read from source only.)

## K3. Errors

**If** a call fails -> **Do** branch on the class or `status`, and log `x-request-id`:

```ts
// untested (classes from SDK src/core/error.ts)
try {
  await kernel.browsers.deleteByID(id);
} catch (e) {
  if (e instanceof Kernel.NotFoundError) return; // already gone
  if (e instanceof Kernel.APIError) {
    console.error(e.status, e.headers?.get('x-request-id'));
  }
  throw e;
}
```

| Status | Class | Typical meaning for your code |
|---|---|---|
| 400 | `BadRequestError` | Bad params; fix the request |
| 401 | `AuthenticationError` | Missing or wrong key |
| 403 | `PermissionDeniedError` | Plan gate (audit logs on Hobbyist return `Insufficient_plan`; the CLI exits 1 live, the 403 body is from field notes) or scoped-key mismatch |
| 404 | `NotFoundError` | Gone, wrong id, or unknown project (`project_not_found`) |
| 409 | `ConflictError` | Retried by default; e.g. deleting the last project is `last_active_project` |
| 422 | `UnprocessableEntityError` | Validation |
| 429 | `RateLimitError` | Retried twice by default; then queue on your side (see `references/scale.md`) |
| >= 500 | `InternalServerError` | Retried twice by default |
| none | `APIConnectionError`, `APIConnectionTimeoutError`, `APIUserAbortError` | Network or timeout; `status` is undefined |

- Deleted browser: `retrieve(id)` throws `NotFoundError` (404). The message likely embeds the session id, so avoid logging it raw (gotcha; message text not captured). `retrieve(id, { include_deleted: true })` returns the record with `deleted_at` and no `status` field (verified live).
- **Avoid** assuming a failed `playwright.execute` throws. When the submitted code throws, the HTTP call is 200 and the body has `success: false`, `error`, `stderr`, `tab`; the SDK does not throw (verified live). Check `res.success`.
- 529 CapacityExhausted: handle it explicitly, e.g. `if (e instanceof Kernel.APIError && e.status === 529) { /* back off or queue */ }` before the generic branch in the catch block. The SDK has no class for it (it would arrive as `InternalServerError` with `status` 529, retried by default). (unverified: never observed.)

Snippet (trimmed, ran live; `browser` comes from `kernel.browsers.create`):

```ts
const { data: res, response } = await kernel.browsers.playwright
  .execute(browser.session_id, {
    code: "await page.goto('https://example.com'); throw new Error('p01 deliberate failure');",
    timeout_sec: 30,
  })
  .withResponse();
console.log('SDK resolved; http', response.status);
console.log('success', res.success, 'error', JSON.stringify(String(res.error ?? '')).slice(0, 160)); // 200 false "..."
```

## K4. Pagination and raw responses

**If** you list anything -> **Do** `for await (const item of kernel.<resource>.list(params)) {...}`; the SDK fetches further pages. Over raw HTTP (curl) paging is in headers `X-Has-More` and `X-Next-Offset` (the CLI audit-log download reads `X-Has-More` and `X-Next-Cursor`). -> **Avoid** assuming one call returns everything, or counting items from the first page only. -> **Source** SDK `src/core/pagination.ts`, `references/api-map.md`.

Verified live: `for await (const key of client.apiKeys.list()) { count++; }` visited all 5 keys.

**If** you need headers or the status -> **Do** `.withResponse()` (returns `{ data, response }`, body parsed) or `.asResponse()` (headers only, body unread). Source: SDK README.

## K5. Project scoping

**If** your org uses projects and the code must act in one -> **Do** pick by what you hold:

| You hold | Set | Header sent | Accepts |
|---|---|---|---|
| A project id | `new Kernel({ projectID })` | `X-Kernel-Project-Id` | id only |
| A name or an id | `new Kernel({ project })` | `X-Kernel-Project` | exact name or id |

```ts
import Kernel from '@onkernel/sdk';

let visible = 0;
const client = new Kernel({ project: 'Default' }); // ran live
for await (const _browser of client.browsers.list()) visible++;
```

- **Avoid** `projectID: process.env.KERNEL_PROJECT`: the SDK never reads that variable, and a name in `projectID` returns 404 `project_not_found` (verified live with curl: `X-Kernel-Project-Id: Default` = 404; `X-Kernel-Project: Default` = 200; either header with an id = 200; a bogus name = 404).
- No header and no scoped key: requests act on the org default project. Naming the default project equals omitting the header (docs).
- Org-wide keys see all projects; a project-scoped key is limited to its project, and a conflicting header returns 403. Scoped keys cannot create, archive or delete projects. OAuth tokens are org-wide and cannot switch projects. (unverified: scoped-key creation and the 403 were not run; docs only.)
- Plan limits: pricing says Hobbyist has 1 project, but the test account listed 4 active projects; the server did not enforce 1. Do not code around the pricing number.
- A project-scoped API key is a different thing from the SDK `project` option. Key fields and masked shape: `references/api-map.md`.
- **Source** https://www.kernel.sh/docs/info/projects.

## K6. Things that do not exist

- No billing, usage or invoice endpoint: the public spec has none. Closest read-only calls are `GET /org/limits` and `GET /org/entitlements`.
- **Avoid** `kernel.browsers.delete` (undefined); use `deleteByID`. Full "does not exist" list: `references/does-not-exist.md`.
- Audit logs: CLI has `search`, `download`, `export`, no `list`; Hobbyist is gated.

Verified live 2026-10-20 (Hobbyist plan); types re-checked on @onkernel/sdk 0.128.0. Evidence ledger: https://github.com/yigitkonur/plugin-kernel-sh/blob/main/verified-facts.md
