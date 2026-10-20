# Logins: getting an authenticated session

Read this when a task needs a site where someone is signed in. Pick one path first, then read only that section.

Rule zero still applies: if the site has an API or an MCP server, use it and skip the login (https://www.kernel.sh/docs/overview/why-kernel).

## Pick the path

| If | Do | Avoid | Source |
|---|---|---|---|
| The user is present and your agent or code owns navigation, submit and recovery (a login can appear mid-task) | Fill from Vault: attach a vault to the browser, call `fill`, submit yourself (sections "Fill from Vault" below) | Putting the password in a prompt, a Playwright `fill()` call, or a CLI argument | https://www.kernel.sh/docs/auth/overview |
| Unattended, recurring, SSO or MFA, or you want Kernel to keep the session alive | Managed Auth: connection, `login`, `follow`, then a **new** browser with the profile (next section) | Writing your own login script; reusing the login browser | https://www.kernel.sh/docs/auth/managed-auth |
| You only need to resume state a previous run already saved | A profile, no login at all (`references/profiles.md`) | Re-running a login you do not need | https://www.kernel.sh/docs/auth/overview |
| You do not know which one | Managed Auth if nobody watches the run, Fill from Vault if a human is in the loop | Mixing both on one site in one run | https://www.kernel.sh/docs/auth/overview |

Both paths keep stored secrets out of API responses and model context. Neither hides them from the page: after `fill`, page scripts, extensions and an unrestricted agent can read the values, so attach a vault only to browsers allowed to use every item in it (https://www.kernel.sh/docs/auth/overview).

## Managed Auth flow

**If** you want Kernel to run the login and save the session to a profile.
**Do** create a connection, start a login, follow it, then open a fresh browser on the profile.
**Avoid** reusing the browser the login ran in (it is Kernel's, you never receive it); polling `login` to check progress (each call starts a new flow).
**Source** https://www.kernel.sh/docs/auth/managed-auth, https://www.kernel.sh/docs/auth/hosted-ui, lab P10.

```ts
import Kernel from '@onkernel/sdk';
import { chromium } from 'playwright-core';

const kernel = new Kernel();

// 1. Optional: store the site credential first. The response never echoes the password.
await kernel.credentials.create({
  name: 'acme-cred',
  domain: 'example.com',
  values: { username: process.env.SITE_USER!, password: process.env.SITE_PASSWORD! },
});

// 2. One connection per domain + profile. The profile is created if missing.
const conn = await kernel.auth.connections.create({
  domain: 'example.com',
  profile_name: 'acme-profile',
  credential: { name: 'acme-cred' },
});
// conn.status is NEEDS_AUTH and conn.can_reauth is false until the first login succeeds.

// 3. Start the flow. hosted_url and handoff_code are credentials: never log them.
const login = await kernel.auth.connections.login(conn.id);
// With no stored credential, send the user to login.hosted_url (or use the React/programmatic paths below).

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
  const page = (pw.contexts()[0] ?? (await pw.newContext())).pages()[0] ?? (await pw.contexts()[0].newPage());
  await page.goto('https://example.com/account');
  await pw.close();
} finally {
  await kernel.browsers.deleteByID(browser.session_id);
}
```

The shape above is trimmed from lab P10 (`p10-01` to `p10-06`, all ran). Lab results worth acting on:

- With a stored credential, `login` then `follow` reached `AUTHENTICATED` with no human (flow `IN_PROGRESS/DISCOVERING`, then `SUCCESS/COMPLETED`). A browser on the profile opened the protected page logged in; the same page without the profile redirected to the login page (P10).
- A new connection starts `NEEDS_AUTH` with `can_reauth: false` (reason `no_prior_successful_login`). It only becomes eligible for automatic reauth after one successful login (P10).
- `follow` heartbeats arrive as event name `sse_heartbeat`, but the SDK type says `heartbeat`. Filter on `ev.event === 'managed_auth_state'` and ignore the rest; do not branch on the heartbeat name (P10).
- Stream ends when the flow succeeds, fails, expires or is canceled. A hosted session expires after 20 minutes and waits 10 minutes for user input (https://www.kernel.sh/docs/auth/hosted-ui, untested).
- `post_login_url` on the connection says where the login landed; start from it (https://www.kernel.sh/docs/auth/configuration).
- A profile can hold one connection per domain, so one profile per end user covers all that user's sites (https://www.kernel.sh/docs/auth/faq).

CLI equivalents exist for every step: `kernel auth connections create|get|update|list|delete|login|follow|submit|timeline` with `-o json` (flags from CLI source: `--domain`, `--profile-name`, `--credential-name`, `--no-health-checks`, `--health-check-interval`, `--record-session`; only `list --domain --profile-name` was run in the lab).

## Recovery: NEEDS_AUTH and EXPIRED

**If** `status` is `NEEDS_AUTH`, or a flow ended `EXPIRED` or `FAILED`.
**Do** call `login` again on the same connection and send the user to the new `hosted_url`; then `follow`.
**Avoid** deleting the connection as recovery; calling `login` while a flow is live.
**Source** https://www.kernel.sh/docs/auth/connection-lifecycle, lab P10.

Lab: a second `login` while the first flow was live did not error. It returned a different `hosted_url` and the first flow showed `CANCELED` in `timeline` (P10). So a `hosted_url` you already handed out is superseded the moment anyone calls `login` again. Whether the old URL is then dead was not tested.

If a flow pauses at `AWAITING_INPUT` or `AWAITING_EXTERNAL_ACTION`, continue it through the `hosted_url` of that same `login` call; calling `login` again cancels it (https://www.kernel.sh/docs/auth/connection-lifecycle).

## Check before consequential work

**If** the next step needs the account to be signed in right now (a purchase, a post, a send).
**Do** call `login` then `follow` as a pre-check and wait for `SUCCESS` before creating the browser.
**Avoid** trusting `connection.status` alone: it reflects the last completed health check, and the site session can expire after it.
**Source** https://www.kernel.sh/docs/auth/connection-lifecycle, https://www.kernel.sh/docs/auth/faq.

```ts
// untested: docs pattern (lab P10 did not exercise the saved-check-URL verify path)
async function ensureAuthenticated(id: string) {
  const login = await kernel.auth.connections.login(id);
  for await (const ev of await kernel.auth.connections.follow(id)) {
    if (ev.event !== 'managed_auth_state') continue;
    if (ev.flow_status === 'SUCCESS') return;
    if (ev.flow_step === 'AWAITING_INPUT' || ev.flow_step === 'AWAITING_EXTERNAL_ACTION') {
      throw new Error('user action required; send them to the hosted_url of this login call');
    }
  }
  throw new Error('authentication did not complete');
}
```

If the connection has a previous successful login and a saved check URL, `login` first verifies the profile and reaches `SUCCESS` without typing anything (docs; unverified in lab).

## React embed (Next.js App Router)

**If** the user must sign in inside your own app instead of on Kernel's hosted page.
**Do** keep the API key on the server: a backend route creates or reuses the connection, calls `login`, and returns only `id` and the one-time `handoff_code`. The page is a `'use client'` component with `<KernelManagedAuth sessionId handoffCode onSuccess onError />` and the package stylesheet.
**Avoid** the API key or `hosted_url` in the frontend; reusing a `handoff_code` (single-use, so every reconnect needs a fresh `login`); taking `success_url` or `error_url` from client input.
**Source** https://www.kernel.sh/docs/auth/react (untested: no lab probe; package `@onkernel/managed-auth-react`).

```tsx
// untested: from the docs page
'use client';
import { KernelManagedAuth } from '@onkernel/managed-auth-react';
import '@onkernel/managed-auth-react/styles.css';

<KernelManagedAuth sessionId={id} handoffCode={code}
  onSuccess={({ profileName, domain }) => { /* continue */ }}
  onError={({ code, message }) => { /* show a retry */ }} />
```

- Default `baseUrl` talks to Kernel directly. For same-origin traffic set `baseUrl=""` and rewrite exactly these four routes to the Kernel API: `/auth/connections/:id/exchange`, `/auth/connections/:id`, `/auth/connections/:id/submit`, `/auth/connections/:id/events`.
- Rendering the component does not give you ongoing recovery. When the connection returns to `NEEDS_AUTH`, your backend calls `login` again and passes the new `id` and fresh `handoff_code`.

## Programmatic flow (your own UI)

**If** you build the credential form or MFA picker yourself, or run headless with a human answering by another channel.
**Do** `follow` the connection; on `flow_step === 'AWAITING_INPUT'` render the event's `fields` or `choices`; reply with one `submit` carrying that event's `interaction_id` plus either `field_values` keyed by the field `id`, or `selected_choice_id` with the exact `choice.id`.
**Avoid** keying `field_values` by `ref`; sending both `field_values` and `selected_choice_id`; replaying an old `interaction_id` (stale ids are rejected, and a new screen gets a new one); deriving a choice id from its label.
**Source** https://www.kernel.sh/docs/auth/programmatic (untested: the demo site in lab P10 has no MFA, so no `AWAITING_INPUT` was observed).

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

A field with `reason: 'rejected'` means the site refused the previous value; ask again and submit against the new interaction. During `AWAITING_EXTERNAL_ACTION` (push approval, security key) show `external_action_message` and keep listening; the flow resumes by itself.

## Failure codes

**If** a flow ends `FAILED` with an `error_code`.
**Do** branch on the code; most are not retried by Kernel and you should not retry them either.
**Avoid** retry loops on any login failure: wrong credentials and lockouts get worse with each attempt.
**Source** https://www.kernel.sh/docs/auth/connection-lifecycle (codes untested in lab; the demo site never failed).

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

Proxy for blocked logins: set it on the connection's own browser config, not on your task browser, because the login runs in a browser Kernel starts.

```ts
// untested: shape from the SDK types (ManagedAuthBrowserConfig.proxy is BrowserProxyConfig: id | name | mode)
const proxy = await kernel.proxies.create({ type: 'isp' });
await kernel.auth.connections.update(conn.id, { browser: { proxy: { id: proxy.id } } });
await kernel.auth.connections.login(conn.id);
```

Avoid the top-level `proxy` field on connection create, update and login (the docs prose still shows it): the SDK types mark it deprecated in favor of `browser.proxy`. A proxy passed to `browsers.create` does not affect the login browser. Residential proxies rotate the exit IP per session, which can itself look suspicious on reauth, so prefer ISP or custom (see `references/unblock.md`).

## MFA

**If** the site uses an authenticator app.
**Do** store `totp_secret` on the credential (base32, 16 to 128 chars, or an `otpauth://totp/` URI) so Kernel generates codes for login and reauth. Add `totp_algorithm`, `totp_digits`, `totp_period` only when the authenticator is not SHA1, 6 digits, 30 s. A code is as long as `totp_digits`; do not assume six.
**Avoid** relying on email, SMS, push or passkey: those need an interactive login every time, and a code the user typed once gives Kernel no access to future ones.
**Source** https://www.kernel.sh/docs/auth/configuration, https://www.kernel.sh/docs/auth/faq (untested: the lab credential had no TOTP; `has_totp_secret` appears on the credential response).

```ts
// untested: from the docs page
await kernel.credentials.create({
  name: 'acme-cred', domain: 'example.com',
  values: { username: process.env.SITE_USER!, password: process.env.SITE_PASSWORD! },
  totp_secret: process.env.SITE_TOTP_SECRET!,
});
```

A credential may hold partial values (for example email plus `totp_secret`, with the password collected from the user each time). `save_credentials: false` on the connection opts out of saving what the user types (docs).

## Health checks cost

**If** the connection serves a single task or a one-shot run.
**Do** create it with `health_checks: false`; health checks and reauths each start a billed browser session (typically 5 to 30 s each).
**Avoid** leaving checks on for connections nobody will use again.
**Source** https://www.kernel.sh/docs/auth/faq, lab P10.

```ts
const conn = await kernel.auth.connections.create({
  domain: 'example.com',
  profile_name: 'acme-oneshot',
  credential: { name: 'acme-cred' },
  health_checks: false,
});
```

- `auto_reauth` only matters when `health_checks` is `true`. When `false`, an expired session becomes `NEEDS_AUTH` with no automatic attempt.
- The lowest `health_check_interval` is plan-dependent. In lab the API rejected 60 with HTTP 400 `health_check_interval must be between 3600 and 86400 seconds` and accepted 3600. The SDK docstring and docs list other minimums per plan; read the 400 body or `kernel org limits get -o json` (`min_health_check_interval_seconds`) instead of hard-coding (P10).
- Inconclusive health checks leave the connection untouched; only a definite logout with `can_reauth: true` triggers reauth.

## 409 on create

**If** `connections.create` returns 409 (that domain and profile already have a connection).
**Do** read `existing_id` from the error body and use that connection.
**Avoid** listing connections and guessing which one matches.
**Source** lab P10 `p10-04`.

```ts
try {
  conn = await kernel.auth.connections.create({ domain, profile_name });
} catch (e) {
  if (e instanceof Kernel.APIError && e.status === 409) {
    const existingId = (e.error as { existing_id: string }).existing_id;
    conn = await kernel.auth.connections.retrieve(existingId);
  } else throw e;
}
```

Lab: status 409, body keys `code`, `existing_id`, `message` (P10). That `existing_id` equals the live connection id was not compared (only the key's presence was checked).

## Fill from Vault

**If** your agent drives the login in its own browser (mid-task prompt, user-owned credentials, custom submit and recovery).
**Do** make a vault, store a credential item, create the browser **with the vault attached**, open the login page, call `performOperation` with `type: 'fill'`, then submit the form yourself and check the result.
**Avoid** attaching a vault to a browser that should not see all its items (the attachment is fixed at create); expecting `fill` to navigate, find fields, submit or verify; passing `maxRetries` above 0 on a write into a live form.
**Source** https://www.kernel.sh/docs/auth/fill-from-vault, https://www.kernel.sh/docs/vaults/fill, lab P11.

```ts
const vault = await kernel.vaults.upsert({ name: 'user-12345' });
await kernel.vaults.items.upsert('site-login', {
  id_or_name: vault.id,
  type: 'credential',
  spec: {
    provider: 'kernel',
    fields: [
      { name: 'username', type: 'text', required: true, sensitive: false, value: process.env.SITE_USER! },
      { name: 'password', type: 'password', required: true, sensitive: true, value: process.env.SITE_PASSWORD! },
    ],
  },
});
// Wait until the item is ready and advertises fill.
const item = await kernel.vaults.items.retrieve('site-login', { id_or_name: vault.id, wait: 60 });
if (!item.available_operations.some((o) => o.type === 'fill')) throw new Error('fill unavailable');

const browser = await kernel.browsers.create({ vaults: [{ id: vault.id }] });
try {
  // ...connectOverCDP and page.goto(LOGIN) as in the Managed Auth example...
  const result = await kernel.vaults.items.performOperation('site-login', {
    id_or_name: vault.id,
    type: 'fill',
    browser_id: browser.session_id,
    page_url: LOGIN,                      // exact match: path, query and fragment
    fields: [
      { field: 'username', selector: '#username' },
      { field: 'password', selector: '#password' },
    ],
  }, { maxRetries: 0 });
  // result.status === 'completed' means written, not logged in. Now click submit yourself.
} finally {
  await kernel.browsers.deleteByID(browser.session_id);
}
```

Trimmed from P11 `01` and `02` (ran). What the lab showed:

- `get` and `list` on the vault and item never returned the password. A field with `sensitive: false` (the username) does come back with its value, so mark anything private `sensitive: true`.
- `fill` returned `{ status: 'completed', fields: [{ index, status: 'filled' }, ...] }`, the page stayed on the login URL and the password length read back as 20, so nothing was submitted. Read back only the length, never the value.
- Failures before any write are **HTTP 400 with `{ code, message }`**, not a 200 with a failed status, and the message says no fields were written. Codes seen: `page_not_found` (`page_url` mismatch, even an extra `?x=1`), `element_not_found` (selector matched nothing), `timeout` (`timeout_ms: 1`). Catch `Kernel.APIError` and branch on `e.status` and `e.error.code` (P11).
- The docs also describe HTTP 200 with `failed`, `unknown` or `not_attempted` fields when a failure happens after writing starts. Always inspect the body, not just the status. That branch was not reproduced in lab.
- `fill` is safe to retry after you check the page, never in an automatic loop. `timeout_ms` is the total deadline (default 10000, max 30000).
- Your code must authorize the destination page: credential items have no destination allowlist, and `fill` does not compare the page with the item's site (https://www.kernel.sh/docs/vaults/fill).
- `fill` does not monitor the session. To reuse the login later, create the browser with a profile and `save_changes: true` (`references/profiles.md`).

Free-tier vault cap and entitlement gating vary by plan: check `kernel org entitlements -o json` first. The fill step through the CLI is `kernel vaults items invoke <vault> <key> fill --spec-file -` (docs and CLI source; not run in lab).

For end-user collection, create the item without `value`s and give the user `item.action.url` (Kernel-hosted form) only in their private interface; never log it. Details and cards/wallets: `references/vaults-payments.md`.

## Reuse a Managed Auth credential in your own browser

**If** users already log in through Managed Auth and your agent sometimes needs to type that login into a page it controls.
**Do** upsert a vault item with `spec: { provider: 'managed_auth', connection_id }` and `fill` from it, so there is one credential copy and it follows password changes.
**Avoid** this for connections backed by 1Password (their values stay in 1Password and cannot back an item).
**Source** https://www.kernel.sh/docs/auth/fill-from-managed-auth (untested). Create returns 404 for an unknown connection and 409 when the connection has no saved credential yet, belongs to another project, or uses an external provider.

## 1Password

**If** the secrets already live in 1Password.
**Do** pick by who approves:

| Setup | Use | Source |
|---|---|---|
| Your org owns the logins and you want unattended Managed Auth | A service-account provider (connected in the dashboard) with an **explicit** `path` of `VaultName/ItemName` per user or per site: `credential: { provider: 'my-1p', path: 'Engineering/github-login' }` | https://www.kernel.sh/docs/integrations/1password |
| The end user owns the login and approves each use | 1Password Agentic Autofill: vault item `provider: '1password'`, user approves in the 1Password app, then `1pw_fill` on a page of the approved login's origin | https://www.kernel.sh/docs/vaults/1password |

**Avoid** `credential: { provider, auto: true }` when one service account can see several users' items: `auto` matches by domain and "if multiple items match a domain, the first match is used", so one user's session can get another user's login. Also avoid `/` in vault or item names (unsupported), and `1pw_fill` on a different origin than the approved login. Values stay in 1Password and are not stored in Kernel on the Managed Auth path.
**Source** the two pages above (untested in lab: no 1Password account was used). Agentic Autofill needs the owner's non-shared vault and does not support passkeys.

## Existing secrets manager

**If** your secrets live in AWS Secrets Manager, Vault, Doppler or similar.
**Do** have your trusted backend read the secret and copy it into a Kernel `provider: 'kernel'` credential item (same upsert as above), then `fill`. Update the copy when the source rotates; delete it when access is revoked or retention ends.
**Avoid** handing raw secret values to the agent; expecting `fill` to read your manager directly (it takes only field names and selectors); expecting Kernel to poll or sync the source.
**Source** https://www.kernel.sh/docs/vaults/existing-credential-vault (untested; the item upsert shape is lab P11).

Keep the source id next to the Kernel vault and item ids in your backend for rotation and deletion. Keep tokens, values, collection URLs and hosted-login URLs out of logs, prompts, CLI arguments and frontend bundles.

## Cleanup

Delete what you made when the run is one-shot: `kernel.auth.connections.delete(id)`, `kernel.credentials.delete(name)`, `kernel.profiles.delete(name)`, and for vaults `kernel.vaults.items.delete(key, { id_or_name })` then `kernel.vaults.delete(name)`. The lab checked each is gone with `kernel auth connections list --domain <d> --profile-name <p> -o json`, `kernel credentials list --query <name> -o json` and `kernel profiles list --name <p> -o json`, all returning `[]` (P10, P11). `kernel vaults get <name>` on a deleted vault prints plain text `ERROR: Not_found`, not JSON. Do not delete a connection or profile that a real user still needs.

Verified in lab: 2026-10-20, @onkernel/sdk 0.127.0, kernel CLI 0.49.0. Probes: P10 confirmed (credential create without echo, connection create and health-check options, `login`, `follow` to AUTHENTICATED, 409 `existing_id` body, `login` supersedes a live flow, `timeline`, profile browser opens the protected page, cleanup); P11 confirmed (vault and item upsert without secret echo, `fill` completed and not submitted, 400 `page_not_found` / `element_not_found` / `timeout`, cleanup). NOT tested: React embed, programmatic `submit` and choices (`AWAITING_INPUT` never occurred), any `error_code` failure path, TOTP, health-check runs, auto-reauth and the `NEEDS_AUTH` recovery, the saved-check-URL pre-task verify, `timeline` types `reauth` and `health_check`, whether a superseded `hosted_url` is dead, 200-after-write `fill` outcomes, vault attach by `{ name }`, `fill` through the CLI, `managed_auth` and 1Password providers, `browser.proxy` on a connection, creating a connection through the CLI.
