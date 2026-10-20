# Account: keys, projects, spending, audit logs, firewalls, Terraform

Read this when you hand Kernel access to someone or something else (an agent, a CI job, a customer workload), split an org into projects, hit a 403, or sit behind a firewall. Everything here is org-level, not per browser.

## AC1. Preflight before cost-bearing work or on a 403

**If** you are about to start expensive work (many browsers, GPU, pools, search, vaults) or got a 403 -> **Do** read the live answer, then read the 403 body (`code`):

```bash
kernel org limits get -o json        # max_concurrent_sessions, concurrent_sessions_used / _available, auth_connections_used, vaults_used
kernel org entitlements -o json      # features.gpu.enabled, custom_proxies, search, proxy_bypass_hosts; plan.id
```

```ts
// untested (method names from api-map.md; the CLI form was run)
import Kernel from '@onkernel/sdk';
const kernel = new Kernel();
const lim = await kernel.organization.limits.retrieve();
const ent = await kernel.organization.entitlements.retrieve();
```

The same data is `GET /org/limits` and `GET /org/entitlements`. A 403 has several causes; branch on the body code, not on the plan name:

| 403 / code | Meaning | Seen |
|---|---|---|
| `insufficient_plan` | Plan gate. GPU: "requires an active paid Start-Up or Enterprise plan". Audit logs: "Insufficient_plan: Audit logs require a Start-Up or Enterprise plan." | verified live, Hobbyist |
| spending cap reached | New browsers and app invocations return 403 for the capped scope (see AC5) | docs only |
| `insufficient_scope` | Your key's policy lacks the action (see AC2) | docs only |
| project mismatch | A project-scoped key sent a header naming another project | docs only |

**Avoid** guessing access from the plan name. Avoid treating `concurrent_sessions_used` as yours alone or expecting it to return to your baseline after cleanup: the counter is org-wide and moved on its own (4 -> 6 after two creates, 3 after deleting both). Order of GPU errors: `gpu: true` with `headless: true` is a 400 `invalid_request` before any plan check; the plan gate (403) only shows on a headful create.

**Source** https://www.kernel.sh/docs/browsers/concurrency-and-limits, https://www.kernel.sh/docs/info/spending-caps.

## AC2. Handing a key to an agent or short-lived job

**If** code you trust less than your backend (an AI agent, a CI job, a customer workload) needs Kernel access -> **Do** create a project-scoped key with a `policy` and an `expires_at` of minutes to hours, and keep the secret out of logs:

```ts
// untested (docs example; key creation was not run)
const key = await kernel.apiKeys.create({
  name: 'checkout-agent-run-4812',
  project_id: 'proj_staging_9f3k',
  expires_at: new Date(Date.now() + 60 * 60 * 1000).toISOString(),
  policy: {
    statements: [
      { action: 'browsers:create', resource: 'projects/proj_staging_9f3k/*' },
      { action: 'browsers:use', resource: 'projects/proj_staging_9f3k/*' },
    ],
  },
});
// key.key is shown once; pass it through the environment, never print it
```

- Actions are `{kind}:{verb}` (`browsers:create|use|write|delete`, `profiles:create|read|use|write|delete`, `vaults:...`, `proxies:...`). Resources are `projects/{id}/*`, `projects/{id}/{kind}/{id}` (kind: browsers, profiles, vaults, proxies) or `organizations/{org_id}/*`. Anything not listed is denied.
- One operation can need several actions: creating a browser needs `browsers:create` and `browsers:use` (the response carries connection URLs), plus `profiles:use` on its profile, `profiles:write` if it saves changes, `vaults:use` per linked vault, `proxies:use` on a saved proxy. A missing grant on a list endpoint gives an empty list, not an error.
- A scoped key gets 403 `insufficient_scope` on: API key management, browser pools, project and org endpoints (including limits), saved extensions, telemetry export, app invocations.
- `expires_at` cannot be combined with `days_to_expire`, must be in the future, and cannot outlive the key that creates it. The CLI `api-keys create` has `--name`, `--days-to-expire`, `--project-id` and no policy or `expires_at` flag, so scoped keys come from the SDK or REST.
- Revocation: an expired key is rejected immediately, a deleted key within about 10 seconds. Neither revokes connection URLs (CDP, WebDriver, live view) the key already obtained: they keep working, including for new connections, until the browser is deleted. **Delete the key's browsers to cut off access.**
- Rotate with `kernel.apiKeys.rotate(id, { days_to_expire?, expire_in_days? })` (old key lives a 7-day grace period unless `expire_in_days: 0`); rotation keeps the policy.
- Deployed apps get their own deployment key injected as `KERNEL_API_KEY`; do not set that name yourself (reserved).
- Listing keys (`kernel api-keys list -o json`, `kernel.apiKeys.list()`): fields are `id, name, masked_key, project_id, project_name, created_at, created_by, expires_at, deleted_at`; `masked_key` looks like `sk_xxxx...xxxx` (older keys have a shorter prefix). The 5 unscoped keys listed had no `policy` field; scoped keys return `policy` in list and retrieve responses per the docs, so the list above is what unscoped keys showed, not an exhaustive schema.

**Avoid** org-wide keys for agents; `days_to_expire` when you need a short expiry; assuming deleting a key kills live browser access.

**Source** https://www.kernel.sh/docs/info/api-keys, https://www.kernel.sh/docs/info/api-key-permissions, `api-keys.ts` types (`APIKeyCreateParams`, `APIKeyRotateParams`), list shape verified live; scoped creation not run. Note: the policy syntax is from docs and SDK types; the minimum SDK version that has `policy` was not verified, 0.127.0 has it (0.128.0 was released since; not re-checked).

## AC3. Projects and multi-tenant setups

**If** you serve several customers, teams or environments -> **Do** one project per customer, one project-scoped key per customer workload, a concurrency cap per project (`kernel projects limits set <id-or-name> --max-concurrent-sessions N`, or an org default via `kernel org limits set --default-project-max-concurrent-sessions N`), a spending cap per project (AC5), and one profile per end user inside the customer's project.

```ts
// untested (the CLI `projects list` was run, not this call)
const projects = await kernel.projects.list();   // /org/projects
```

**Project routes.** **Do** use `/org/projects/*` (the SDK already does). **Avoid** `/projects/*`: deprecated, "will be removed on 2026-11-24" per the API reference pages.

**Scoping a request.** Both headers were verified live against `GET /browsers`:

| Input | Result |
|---|---|
| no header | default project, 200 |
| `X-Kernel-Project-Id: <id>` (SDK `projectID`) | 200 |
| `X-Kernel-Project-Id: <name>` | 404 `project_not_found` |
| `X-Kernel-Project: <exact name or id>` (SDK `project`) | 200 |
| `X-Kernel-Project: <unknown>` | 404 `project_not_found` |

- Unresolved: the projects docs page says CLI `--project` / `KERNEL_PROJECT` send `X-Kernel-Project-Id`, while the CLI README and its tests say `X-Kernel-Project`. CLI headers were not captured; the CLI accepting a project name via `--project` is consistent with the README.
- The docs page documents only the `-Id` header and says names are not accepted there. `X-Kernel-Project` taking a name works live; it is not described on the projects page.
- The SDK does not read `KERNEL_PROJECT` (it reads `KERNEL_API_KEY`, `KERNEL_BASE_URL`, `KERNEL_LOG`, `KERNEL_CUSTOM_HEADERS`, and a few internal ones such as `KERNEL_SUPPRESS_BUN_WARNING`). The CLI does. For a variable that may hold a name use `new Kernel({ project: name })`, not `projectID`.
- Without a header, requests act on the default project (the one named `Default`); naming it explicitly is equivalent. OAuth (CLI `kernel login`, MCP) is always org-wide: scope it with `--project` or the header.
- A scoped key sending a header for another project gets 403.
- Delete rules: 409 `last_active_project` for the last project, 409 `project_not_empty` until it is empty, 404 `projects_disabled` if the org lacks projects. Most project admin (create, archive, delete, limits) needs an org-wide credential.
- Plan limits: pricing says Hobbyist has 1 project; the Hobbyist account listed 4 active projects and `/org/entitlements` has no project count. Do not assume the limit is enforced or absent; read the response.

**Avoid** one org key for all tenants; `projectID: process.env.KERNEL_PROJECT`.

**Source** https://www.kernel.sh/docs/info/projects, https://www.kernel.sh/docs/introduction/manage, `client.ts` in `@onkernel/sdk`.

## AC4. Audit logs

**If** you need "who called what" -> **Do** check the plan first: search and download need Start-Up or Enterprise, S3 export needs Enterprise. On Hobbyist `kernel audit-logs search --start 2026-10-19 --limit 3 -o json` exits 1 with `Insufficient_plan`. SDK: `kernel.auditLogs.list({ start, end, method })` is an async iterable. The CLI has `search`, `download`, `export` (no `list`). Retention is 1 year. **Avoid** building features on audit logs without the plan check.

**Source** https://www.kernel.sh/docs/info/audit-logs, gating verified live. Not tested: any successful audit-log call.

## AC5. Spending caps

**If** you want a bill guardrail -> **Do** set it in the dashboard (https://dashboard.onkernel.com/billing, org admin). The docs describe only the dashboard billing page for caps; no spending-cap API, SDK method or CLI command is documented (not checked against the spec). Organization caps cover out-of-pocket usage after monthly credits and pause all projects at 100%; project caps count gross project usage. Warning email at 80%. At 100% new browsers and app invocations return 403 for that scope; running work continues; reads and deletes still work. Project caps are limited preview and org caps are for eligible self-serve orgs (email support@kernel.sh for preview access).

**Avoid** treating a cap as a hard stop: "already-running work can continue adding usage" and billing events lag. Keep headroom. A cap is not a concurrency limit and does not reserve throughput.

**Source** https://www.kernel.sh/docs/info/spending-caps. Not tested live (dashboard-only, needs a human and money).

## AC6. Usage and billing data

**If** you want usage, billing or invoice numbers -> **Do** use the dashboard. The public API spec (128 paths) has no usage, billing or invoice endpoint, and the CLI has no billing command. The closest read-only calls are `GET /org/limits` and `GET /org/entitlements`. **Avoid** inventing a usage endpoint.

**Source** Verified live (no usage or billing endpoint in the spec).

## AC7. Firewalls and sandboxes

**If** outbound traffic is restricted (corporate firewall, sandbox, CI) -> **Do** allow:

| Need | Destination | Port |
|---|---|---|
| API, SDK, authenticated CLI | `api.onkernel.com` | 443 |
| `kernel login` | `auth.onkernel.com`, `dashboard.onkernel.com` | 443 |
| CDP, BiDi, live view, replays, app connections | `*.onkernel.com` and `*.kernel.sh` | 8443 (HTTPS + WSS) |
| Live view media | `stun.relay.metered.ca` (STUN/UDP 80), `global.relay.metered.ca` (TURN 443) | |
| Replay files | `kernel-api-prod.s3.us-east-1.amazonaws.com` | 443 |

Apply live view and replay rules to each viewer's network, not only the agent's machine. If you embed live view or replays, add the same hosts to your CSP (`frame-src`, `connect-src`). **Avoid** copying one hostname from a returned `cdp_ws_url`: it changes between sessions. Symptom map: API times out -> 443 to the API host; create works but CDP or live view will not connect -> 8443 on both wildcards; live view loads without video -> STUN/TURN; replay player loads but will not play -> the S3 host.

**Source** https://www.kernel.sh/docs/info/network-access. Not tested live.

## AC8. Restricting an untrusted agent

**If** an agent could be prompt-injected and must not exfiltrate -> **Do** put an egress allowlist on the browser from your own code, and keep the Kernel API key, the Kernel MCP server and any code execution inside the VM out of the agent's reach. Anyone with your key can replace or remove an allowlist or create a browser without one. **Avoid** assuming the allowlist covers everything the VM sends: it covers browser traffic through Kernel's egress proxy; code running in the VM can send traffic directly, and extensions with the `proxy` permission and `network.private_hosts` destinations are not filtered. Release pooled browsers with `reuse: false` if the next lease must not see cookies.

**Source** https://www.kernel.sh/docs/shared-responsibility-model, https://www.kernel.sh/docs/browsers/egress-allowlists (page not read here: see `references/browsers.md`). Allowlist API shape: unverified in this file.

## AC9. Infrastructure as code

**If** projects and browser pools should be declared, not scripted -> **Do** use the Terraform provider `kernel/kernel` (set `KERNEL_API_KEY`, and `KERNEL_PROJECT_ID` if needed). It manages durable config (projects, pools) and reads projects, profiles, proxies, extensions. **Avoid** Terraform for runtime work (create, acquire, release browsers): use the SDK.

**Source** https://www.kernel.sh/docs/integrations/terraform. Not tested.

---

Verified live 2026-10-20 (Hobbyist plan); types re-checked on @onkernel/sdk 0.128.0. Evidence ledger: verified-facts.md in the plugin repository.
