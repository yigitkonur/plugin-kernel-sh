# Logins: getting an authenticated session

Read this when a task needs a site where someone is signed in. Pick one path first, then read only that section.

Docs: "If the task can be done through an API or an MCP server, use that instead." (https://www.kernel.sh/docs/overview/why-kernel)

## Pick the path

| If | Do | Avoid | Source |
|---|---|---|---|
| The user is present and your agent or code owns navigation, submit and recovery (a login can appear mid-task) | Fill from Vault: attach a vault to the browser, call `fill`, submit yourself (sections "Fill from Vault" below) | Putting the password in a prompt, a Playwright `fill()` call, or a CLI argument | https://www.kernel.sh/docs/auth/overview |
| Unattended, recurring, SSO or MFA, or you want Kernel to keep the session alive | Managed Auth: connection, `login`, `follow`, then a **new** browser with the profile (next section) | Reusing the login browser | https://www.kernel.sh/docs/auth/managed-auth |
| Unattended, you hold the user's credentials and no person will be at the hosted page | Store a Kernel credential with the shipped script (`skills/login/scripts/create-credential.mjs`, password from the environment), then Managed Auth with `credential: { name }`. Verified: `AUTHENTICATED` with no human | Managed Auth with no credential (waits for a person, then fails `awaiting_input_timeout`); `kernel credentials create --value password=...` (password on the command line) | lab, https://www.kernel.sh/docs/auth/managed-auth |
| A dev script logs in once itself and later runs reuse the profile | "Scripted login once, reuse the profile" below | Putting the password in a source file or a command-line argument | dogfood D04 |
| You only need to resume state a previous run already saved | A profile, no login at all (`references/profiles.md`) | Re-running a login you do not need | https://www.kernel.sh/docs/auth/overview |
| You do not know which one | Managed Auth if nobody watches the run, Fill from Vault if a human is in the loop | Mixing both on one site in one run | https://www.kernel.sh/docs/auth/overview |

Stored secrets stay out of API responses and model context, but not out of the page: after `fill`, page scripts, extensions and an unrestricted agent can read the values, so attach a vault only to browsers allowed to use every item in it (https://www.kernel.sh/docs/auth/overview).

## Managed Auth flow

**If** you want Kernel to run the login and save the session to a profile.
**Do** create a connection, start a login, follow it, then open a fresh browser on the profile.
**Avoid** reusing the browser the login ran in (it is Kernel's, you never receive it); polling `login` to check progress (each call starts a new flow).
**Source** https://www.kernel.sh/docs/auth/managed-auth, https://www.kernel.sh/docs/auth/hosted-ui, lab P10.

```ts
import Kernel from '@onkernel/sdk';
import { chromium } from 'playwright-core';

const kernel = new Kernel();

// 1. Store the credential first for any unattended run (without it the flow needs a person). The response
//    never echoes the password. From a shell, use the shipped script so the password stays off the command line.
await kernel.credentials.create({
  name: 'acme-cred', domain: 'example.com',
  values: { username: process.env.SITE_USER!, password: process.env.SITE_PASSWORD! },
});
// 2. One connection per domain + profile. It starts NEEDS_AUTH with can_reauth false until a login succeeds.
const conn = await kernel.auth.connections.create({
  domain: 'example.com', profile_name: 'acme-profile', credential: { name: 'acme-cred' },
});
// 3. Start the flow. hosted_url and handoff_code are credentials: never log them.
//    With no stored credential a person must open login.hosted_url (or use the React/programmatic paths below).
const login = await kernel.auth.connections.login(conn.id);
// 4. Follow until a terminal flow_status. Skip events that are not managed_auth_state.
for await (const ev of await kernel.auth.connections.follow(conn.id)) {
  if (ev.event !== 'managed_auth_state') continue;
  if (['SUCCESS', 'FAILED', 'EXPIRED', 'CANCELED'].includes(ev.flow_status)) break;
}
const done = await kernel.auth.connections.retrieve(conn.id);
if (done.status !== 'AUTHENTICATED') throw new Error(`login ended ${done.flow_status} ${done.error_code ?? ''}`);

// 5. Work in a NEW browser on the profile. Delete it in finally.
const browser = await kernel.browsers.create({ profile: { name: 'acme-profile' } });
try {
  const pw = await chromium.connectOverCDP(browser.cdp_ws_url);
  const context = pw.contexts()[0];                 // the profile lives in the default context
  const page = context.pages()[0] ?? (await context.newPage());
  await page.goto('https://example.com/account');
  await pw.close();
} finally {
  await kernel.browsers.deleteByID(browser.session_id);
}
```

Trimmed from lab P10 (ran). Worth acting on:

- With a stored credential, `login` then `follow` reached `AUTHENTICATED` with no human; a browser on the profile opened the protected page logged in, without the profile it redirected to login (P10). A new connection starts `NEEDS_AUTH`, `can_reauth: false` (reason `no_prior_successful_login`) until one login succeeds.
- `follow` heartbeats arrive as event `sse_heartbeat`; filter on `ev.event === 'managed_auth_state'` and ignore the rest. The stream ends when the flow succeeds, fails, expires or is canceled; a hosted session expires after 20 minutes.
- With no stored credential the flow sits at `AWAITING_INPUT` and ends `FAILED`, `error_code: awaiting_input_timeout`, after 10 minutes if nobody types on the hosted page (D05, twice). Poll up to about 11 minutes, then stop and report: the fix is a stored credential or a person.
- `connections.create` also creates the profile, so cleanup deletes both connection and profile (D24).
- `post_login_url` on the connection says where the login landed; start from it (https://www.kernel.sh/docs/auth/configuration).
- A profile holds one connection per domain, so one profile per end user covers all that user's sites (https://www.kernel.sh/docs/auth/faq).

CLI equivalents exist for every step: `kernel auth connections create|get|update|list|delete|login|follow|submit|timeline` with `-o json` (flags: `--domain`, `--profile-name`, `--credential-name`, `--no-health-checks`, `--health-check-interval`, `--record-session`). Run live: `credentials create` (via the script), `connections create --credential-name`, `login`, `follow` reached `AUTHENTICATED` in about 45 s with no human. `delete` needs `--yes` when stdin is not a terminal (`credentials delete` takes `-y`).

## Scripted login once, reuse the profile

**If** a dev script of yours logs in with a password itself (no Managed Auth) and later runs should reuse the session.
**Do** read the password from an env var, build it into the `playwright.execute` code string at runtime, log in only when the protected page redirects to login, and open the browser with `save_changes: true` as the one writer for the profile; `deleteByID` in `finally`.
**Avoid** a hard-coded password; a command-line argument or `SECRET=... node` prefix (shell history); a second writer on the same profile.
**Source** dogfood D04 (ran twice: login performed, then `wasLoggedIn: true`); `references/profiles.md`.

```ts
import Kernel, { ConflictError } from '@onkernel/sdk';

const PROFILE = 'acme-script-login';
const { SITE_USER, SITE_PASSWORD } = process.env;
if (!SITE_USER || !SITE_PASSWORD) throw new Error('SITE_USER and SITE_PASSWORD must be set');

// Runs inside the Kernel VM; the secret is JSON-quoted in at runtime. It travels to Kernel in the request body,
// so for a long-lived job prefer a stored credential (Managed Auth).
const code = `
await page.goto('https://example.com/account', { waitUntil: 'domcontentloaded' });
const wasLoggedIn = new URL(page.url()).pathname === '/account';
if (!wasLoggedIn) {
  await page.goto('https://example.com/login', { waitUntil: 'domcontentloaded' });
  await page.fill('#username', ${JSON.stringify(SITE_USER)});
  await page.fill('#password', ${JSON.stringify(SITE_PASSWORD)});
  await Promise.all([page.waitForURL('**/account', { timeout: 15000 }), page.click('button[type="submit"]')]);
}
return { wasLoggedIn, path: new URL(page.url()).pathname };
`;

await kernel.profiles.create({ name: PROFILE }).catch((e) => { if (!(e instanceof ConflictError)) throw e; });
const browser = await kernel.browsers.create(
  { headless: true, timeout_seconds: 300, profile: { name: PROFILE, save_changes: true } }, { maxRetries: 0 });
try {
  const res = await kernel.browsers.playwright.execute(
    browser.session_id, { code, timeout_sec: 60 }, { maxRetries: 0, timeout: 90_000 });
  if (!res.success) throw new Error(`execute failed: ${String(res.error)}`);
  console.log(res.result);
} finally {
  await kernel.browsers.deleteByID(browser.session_id);
}
```

Run with `node --env-file=.env` (gitignored) or exported variables. Sequential runs with `save_changes: true` are safe; concurrent runs on one profile are not.

## Recovery: NEEDS_AUTH and EXPIRED

**If** `status` is `NEEDS_AUTH`, or a flow ended `EXPIRED` or `FAILED`.
**Do** call `login` again on the same connection and send the user to the new `hosted_url`; then `follow`.
**Avoid** deleting the connection as recovery; calling `login` while a flow is live.
**Source** https://www.kernel.sh/docs/auth/connection-lifecycle, lab P10.

Lab: a second `login` while the first flow was live did not error. It returned a different `hosted_url` and the first flow showed `CANCELED` in `timeline` (P10). So it also ends a pending flow without deleting the connection (otherwise wait for expiry), and any `hosted_url` you already handed out is superseded. Whether the old URL is then dead was not tested. A flow paused at `AWAITING_INPUT` or `AWAITING_EXTERNAL_ACTION` continues only through the `hosted_url` of its own `login` call.

## Check before consequential work

**If** the next step needs the account to be signed in right now (a purchase, a post, a send).
**Do** call `login` then `follow` and wait for `SUCCESS` before creating the browser.
**Avoid** trusting `connection.status` alone: it reflects the last completed health check, and the site session can expire after it.
**Source** https://www.kernel.sh/docs/auth/connection-lifecycle, https://www.kernel.sh/docs/auth/faq.

Pattern (untested; docs): `await kernel.auth.connections.login(id)`, then `for await (const ev of await kernel.auth.connections.follow(id))` over `managed_auth_state` events: return on `flow_status === 'SUCCESS'`, throw "user action required" on `flow_step` `AWAITING_INPUT` or `AWAITING_EXTERNAL_ACTION`, and throw if the stream ends without `SUCCESS`. With a previous successful login and a saved check URL, `login` first verifies the profile and reaches `SUCCESS` without typing (docs; unverified).

## React embed (Next.js App Router)

**If** the user must sign in inside your own app instead of on Kernel's hosted page.
**Do** keep the API key on the server: a backend route creates or reuses the connection, calls `login`, and returns only the connection `id` and the one-time `handoff_code`. The page is a `'use client'` component with `<KernelManagedAuth sessionId handoffCode onSuccess onError />` (`sessionId` is the connection id) and the package stylesheet.
**Avoid** the API key in the frontend; returning `hosted_url` or `live_view_url` (the `login` response carries both and both are credentials); reusing a `handoff_code` (single-use, so every reconnect needs a fresh `login`); taking `success_url` or `error_url` from client input; one `profile_name` per domain in a request-driven route.
**Source** https://www.kernel.sh/docs/auth/react; the route type-checks against @onkernel/sdk 0.128.0 (dogfood D23, strict `tsc`; not run against Kernel); the component snippet is untested (the package was not installed).

`profile_name` must be per end user (`user-<id>` from your session, never from the request body), or every app user shares one logged-in session. `handoff_code` is optional in the SDK type (`handoff_code?`): return 502 when it is missing.

```ts
// app/api/connect/route.ts, trimmed from D23. userId comes from your auth/session layer.
const OPERATION = { maxRetries: 0, timeout: 30_000 } as const;
declare const userId: string;
export async function POST(request: Request): Promise<Response> {
  // On Kernel.ConflictError retrieve existing_id instead (section "409 on create").
  const connection = await kernel.auth.connections.create(
    { domain: 'example.com', profile_name: `user-${userId}` }, OPERATION);
  const login = await kernel.auth.connections.login(connection.id, undefined, OPERATION);
  if (!login.handoff_code) return Response.json({ error: 'no_handoff_code' }, { status: 502 });
  // Return only these. Never hosted_url or live_view_url.
  return Response.json({ connectionId: login.id, handoffCode: login.handoff_code, flowExpiresAt: login.flow_expires_at });
}
```

```tsx
// untested: from the docs page
'use client';
import { KernelManagedAuth } from '@onkernel/managed-auth-react';
import '@onkernel/managed-auth-react/styles.css';

<KernelManagedAuth sessionId={connectionId} handoffCode={code}
  onSuccess={({ profileName, domain }) => { /* continue */ }}
  onError={({ code, message }) => { /* show a retry */ }} />
```

- Default `baseUrl` talks to Kernel directly. For same-origin traffic set `baseUrl=""` and rewrite exactly these four routes to the Kernel API: `/auth/connections/:id/exchange`, `/auth/connections/:id`, `/auth/connections/:id/submit`, `/auth/connections/:id/events`.
- The component gives no ongoing recovery: when the connection returns to `NEEDS_AUTH`, your backend calls `login` again and passes a fresh `handoff_code`.

## Programmatic flow (your own UI)

**If** you build the credential form or MFA picker yourself, or run headless with a human answering by another channel.
**Do** `follow` the connection; on `flow_step === 'AWAITING_INPUT'` render the event's `fields` or `choices`; reply with one `submit` carrying that event's `interaction_id` plus either `field_values` keyed by the field `id`, or `selected_choice_id` with the exact `choice.id`.
**Avoid** keying `field_values` by `ref`; sending both `field_values` and `selected_choice_id`; replaying an old `interaction_id` (stale ids are rejected, and a new screen gets a new one); deriving a choice id from its label.
**Source** https://www.kernel.sh/docs/auth/programmatic (untested: the lab site had no MFA, so no `AWAITING_INPUT` was seen).

```ts
// untested: from the docs page
for await (const ev of await kernel.auth.connections.follow(conn.id)) {
  if (ev.event !== 'managed_auth_state' || ev.flow_step !== 'AWAITING_INPUT' || !ev.interaction_id) continue;
  if (ev.fields?.length) {
    const field_values: Record<string, string> = {};
    for (const f of ev.fields) field_values[f.id] = await askUser(f);
    await kernel.auth.connections.submit(conn.id, { interaction_id: ev.interaction_id, field_values });
  } else if (ev.choices?.length) {
    const c = await askUserToChoose(ev.choices);
    await kernel.auth.connections.submit(conn.id, { interaction_id: ev.interaction_id, selected_choice_id: c.id });
  }
}
```

A field with `reason: 'rejected'` means the site refused the value; ask again against the new interaction. During `AWAITING_EXTERNAL_ACTION` show `external_action_message` and keep listening; the flow resumes by itself.

## Failure codes

**If** a flow ends `FAILED` with an `error_code`.
**Do** branch on the code; most are not retried by Kernel and you should not retry them either.
**Avoid** retry loops on any login failure: wrong credentials and lockouts get worse with each attempt.
**Source** https://www.kernel.sh/docs/auth/connection-lifecycle (only `awaiting_input_timeout` was seen live; the other codes are untested).

| `error_code` | Do |
|---|---|
| `bot_detected`, `captcha_blocked` | Pin the connection to an ISP or custom proxy and keep stealth on, then `login` again (below). Do not loop. |
| `account_locked` | Stop and tell the user to unlock it on the site. Calling `login` again may extend the lockout. |
| `credentials_invalid` | Update the linked credential, then `login` again. |
| `totp_code_rejected` | Retry once in a new TOTP window; if it keeps failing, reconnect the account and update the secret. |
| `totp_required`, `sms_code_required`, `email_code_required`, `account_choice_required`, `customer_input_required`, `external_action_required` | Needs a person: start an interactive login (hosted, React or programmatic). |
| `rate_limited` | Wait for the site's window, then one new login. |
| `website_error` | Usually the site; Kernel already retried once. Try later; check `login_url`. |
| `unsupported_auth_method` | Passkey-only is unsupported; switch the account to password plus TOTP. |
| `awaiting_input_timeout` | No one typed on the hosted page within 10 minutes (no stored credential, or the site asked for input). Store a credential with the script, or send a person to a fresh `login`; do not loop. Ran live (D05). |

**If** a login keeps ending `bot_detected` or `captcha_blocked`.
**Do** set the proxy on the connection's own browser config (`browser.proxy`); the login runs in a browser Kernel starts.
**Avoid** the top-level `proxy` field on create, update and login (deprecated in the SDK types); relying on a proxy set on your task browser (assumed not to reach the login browser; untested); residential exit IPs, which can change between logins and may look suspicious on reauth (inference): prefer ISP or custom (`references/unblock.md`).
**Source** https://www.kernel.sh/docs/auth/configuration#custom-proxy.

```ts
// shape from the SDK types (ManagedAuthBrowserConfig.proxy is BrowserProxyConfig: id | name | mode)
const proxy = await kernel.proxies.create({ type: 'isp' });
await kernel.auth.connections.update(conn.id, { browser: { proxy: { id: proxy.id } } });
```

## MFA

**If** the site uses an authenticator app.
**Do** store `totp_secret` on the credential (base32, 16 to 128 chars, or an `otpauth://totp/` URI) so Kernel generates codes for login and reauth. Add `totp_algorithm`, `totp_digits`, `totp_period` only when the authenticator is not SHA1, 6 digits, 30 s. A code is as long as `totp_digits`; do not assume six.
**Avoid** relying on email, SMS, push or passkey: those need an interactive login every time, and a code the user typed once gives Kernel no access to future ones.
**Source** https://www.kernel.sh/docs/auth/configuration, https://www.kernel.sh/docs/auth/faq (untested: the lab credential had no TOTP; `has_totp_secret` appears on the credential response).

The shipped script takes `SITE_TOTP_SECRET` and sets `totp_secret`; with the SDK pass `totp_secret` next to `values` in `kernel.credentials.create` (docs; untested). A credential may hold partial values (email plus `totp_secret`, password typed each time); `save_credentials: false` on the connection opts out of saving what the user types (docs).

## Health checks cost

**If** the connection serves a single task or a one-shot run.
**Do** create it with `health_checks: false` (CLI `--no-health-checks`); health checks and reauths each start a billed browser session (typically 5 to 30 s each).
**Avoid** leaving checks on for connections nobody will reuse.
**Source** https://www.kernel.sh/docs/auth/faq, lab P10.

- `auto_reauth` only matters when `health_checks` is `true`; otherwise an expired session becomes `NEEDS_AUTH` with no attempt.
- The lowest `health_check_interval` is plan-dependent: in lab 60 got HTTP 400 `must be between 3600 and 86400 seconds` and 3600 was accepted. Read the 400 body or `kernel org limits get -o json` (`min_health_check_interval_seconds`); do not hard-code (P10).

## 409 on create

**If** `connections.create` returns 409 (that domain and profile already have a connection).
**Do** read `existing_id` from the error body and use that connection.
**Avoid** listing connections and guessing which one matches.
**Source** lab P10 `p10-04`.

```ts
let conn;
try {
  conn = await kernel.auth.connections.create({ domain, profile_name });
} catch (e) {
  if (e instanceof Kernel.ConflictError) {   // typed 409; type-checks on 0.128.0 (D23)
    const existingId = (e.error as { existing_id: string }).existing_id;
    conn = await kernel.auth.connections.retrieve(existingId);
  } else throw e;
}
```

Lab: status 409, body keys `code`, `existing_id`, `message` (P10); the key's presence was checked, not that it equals the live connection id. D04 ran the same `ConflictError` catch on `profiles.create`.

## Fill from Vault

**If** your agent drives the login in its own browser (mid-task prompt, user-owned credentials, custom submit and recovery).
**Do** make a vault, store a credential item, create the browser **with the vault attached**, open the login page, call `performOperation` with `type: 'fill'`, then submit the form yourself and check the result.
**Avoid** attaching a vault to a browser that should not see all its items (the attachment is fixed at create); expecting `fill` to navigate, find fields, submit or verify; passing `maxRetries` above 0 on a write into a live form.
**Source** https://www.kernel.sh/docs/auth/fill-from-vault, https://www.kernel.sh/docs/vaults/fill, lab P11.

```ts
const vault = await kernel.vaults.upsert({ name: 'user-12345' });
await kernel.vaults.items.upsert('site-login', {
  id_or_name: vault.id, type: 'credential',
  spec: { provider: 'kernel', fields: [
    { name: 'username', type: 'text', required: true, sensitive: false, value: process.env.SITE_USER! },
    { name: 'password', type: 'password', required: true, sensitive: true, value: process.env.SITE_PASSWORD! },
  ] },
});
// Wait until the item is ready and advertises fill.
const item = await kernel.vaults.items.retrieve('site-login', { id_or_name: vault.id, wait: 60 });
if (!item.available_operations.some((o) => o.type === 'fill')) throw new Error('fill unavailable');

const browser = await kernel.browsers.create({ vaults: [{ id: vault.id }] });
try {
  // ...connectOverCDP and page.goto(LOGIN) as in the Managed Auth example...
  const result = await kernel.vaults.items.performOperation('site-login', {
    id_or_name: vault.id, type: 'fill', browser_id: browser.session_id,
    page_url: LOGIN,                      // exact match: path, query and fragment
    fields: [{ field: 'username', selector: '#username' }, { field: 'password', selector: '#password' }],
  }, { maxRetries: 0 });
  // result.status === 'completed' means written, not logged in. Now click submit yourself.
} finally {
  await kernel.browsers.deleteByID(browser.session_id);
}
```

Trimmed from P11 (ran). What the lab showed:

- `get` and `list` never returned the password; a `sensitive: false` field (the username) comes back with its value, so mark anything private `sensitive: true`.
- `fill` returned `{ status: 'completed', fields: [{ index, status: 'filled' }, ...] }`, the page stayed on the login URL and nothing was submitted. Read back only the length of the password field, never the value.
- Failures before any write are **HTTP 400 with `{ code, message }`**, not a 200 with a failed status: `page_not_found` (`page_url` mismatch, even an extra `?x=1`), `element_not_found`, `timeout`. Catch `Kernel.APIError` and branch on `e.status` and `e.error.code`. The docs also describe HTTP 200 with `failed`, `unknown` or `not_attempted` fields when a failure happens after writing starts (not reproduced): inspect the body, not just the status.
- Retry `fill` only after checking the page, never in a loop. `timeout_ms` is the total deadline (default 10000, max 30000). Your code must authorize the destination page: `fill` does not compare it with the item's site.
- `fill` does not monitor the session. To reuse the login later, create the browser with a profile and `save_changes: true` (`references/profiles.md`).

Vault caps vary by plan (`kernel org entitlements -o json`). CLI fill: `kernel vaults items invoke <vault> <key> fill --spec-file -` (docs; not run). For end-user collection, create the item without `value`s and give the user `item.action.url` (Kernel-hosted form) only in their private interface; never log it. Details and cards/wallets: `references/vaults-payments.md`.

## Reuse a Managed Auth credential in your own browser

**If** users log in through Managed Auth and your agent sometimes needs to type that login into a page it controls.
**Do** upsert a vault item with `spec: { provider: 'managed_auth', connection_id }` and `fill` from it (one credential copy; it follows password changes).
**Avoid** this for 1Password-backed connections (values cannot back an item).
**Source** https://www.kernel.sh/docs/auth/fill-from-managed-auth (untested). Create returns 404 for an unknown connection, 409 when the connection has no saved credential, belongs to another project, or uses an external provider.

## 1Password

**If** the secrets already live in 1Password.
**Do** pick by who approves:

| Setup | Use | Source |
|---|---|---|
| Your org owns the logins and you want unattended Managed Auth | A service-account provider (dashboard) with an **explicit** `path` of `VaultName/ItemName` per user or site: `credential: { provider: 'my-1p', path: 'Engineering/github-login' }` | https://www.kernel.sh/docs/integrations/1password |
| The end user owns the login and approves each use | Agentic Autofill: vault item `provider: '1password'`, user approves in the 1Password app, then `1pw_fill` on a page of the approved login's origin | https://www.kernel.sh/docs/vaults/1password |

**Avoid** `credential: { provider, auto: true }` when one service account sees several users' items: `auto` takes the first domain match, so one user can get another's login. Also avoid `/` in vault or item names and `1pw_fill` on a different origin. Values stay in 1Password on the Managed Auth path.
**Source** the two pages above (untested: no 1Password account). Agentic Autofill needs the owner's non-shared vault and does not support passkeys.

## Existing secrets manager

**If** your secrets live in AWS Secrets Manager, Vault, Doppler or similar.
**Do** have your trusted backend copy the secret into a Kernel `provider: 'kernel'` credential item (same upsert as above), then `fill`; update it on rotation, delete it when access is revoked.
**Avoid** handing raw secrets to the agent; expecting `fill` to read your manager or Kernel to sync it.
**Source** https://www.kernel.sh/docs/vaults/existing-credential-vault (untested; the item upsert shape is lab P11).

## Cleanup

**If** the run was one-shot and you created the connection, credential, profile or vault.
**Do** delete them: `kernel.auth.connections.delete(id)`, `kernel.credentials.delete(name)`, `kernel.profiles.delete(name)`; vaults: `kernel.vaults.items.delete(key, { id_or_name })` then `kernel.vaults.delete(name)`. CLI needs `--yes` (`kernel auth connections delete <id> --yes`, `kernel profiles delete <name> --yes`, `kernel credentials delete <name> -y`) when stdin is not a terminal.
**Avoid** deleting a connection or profile that a real user still needs.
**Source** lab P10, P11, dogfood D05. Check with `kernel auth connections list --domain <d> --profile-name <p> -o json`, `kernel credentials list --query <name> -o json`, `kernel profiles list --name <p> -o json` (all `[]`). `kernel vaults get <name>` on a deleted vault prints plain `ERROR: Not_found`.

Verified in lab 2026-10-20; types re-checked on @onkernel/sdk 0.128.0; dogfood-run snippets noted inline
