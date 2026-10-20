# Logins: getting an authenticated session

Read this when a task needs a site where someone is signed in. Pick one path first, then read only that section.

Docs: "If the task can be done through an API or an MCP server, use that instead." (https://www.kernel.sh/docs/overview/why-kernel)

## Pick the path

| If | Do | Avoid | Source |
|---|---|---|---|
| The user is present and your agent or code owns navigation, submit and recovery (a login can appear mid-task) | Fill from Vault: attach a vault to the browser, call `fill`, submit yourself (sections "Fill from Vault" below) | Putting the password in a prompt, a Playwright `fill()` call, or a CLI argument | https://www.kernel.sh/docs/auth/overview |
| Unattended, recurring, SSO or MFA, or you want Kernel to keep the session alive | Managed Auth: connection, `login`, `follow`, then a **new** browser with the profile (next section) | Reusing the login browser | https://www.kernel.sh/docs/auth/managed-auth |
| Unattended, you hold the user's credentials and no person will be at the hosted page | Store a Kernel credential with the shipped script `<plugin>/skills/login/scripts/create-credential.mjs` (the `/kernel:login` skill runs it for you; its text uses `${CLAUDE_SKILL_DIR}`), then Managed Auth with `credential: { name }`. Supply the secrets by (a) variables exported in the user's own shell before launching Claude Code, (b) `node --env-file=.env <script> <name> <domain>` with a gitignored `.env`, or (c) a mode-600 temp env file when the user pasted the password in chat. Verified: `AUTHENTICATED` with no human | Managed Auth with no credential (waits for a person, then fails `awaiting_input_timeout`); `kernel credentials create --value password=...` (password on the command line); an inline `SITE_PASSWORD=... node` prefix (shell history, tool transcript) | Verified live, https://www.kernel.sh/docs/auth/managed-auth |
| A dev script logs in once itself and later runs reuse the profile | "Scripted login once, reuse the profile" below | Putting the password in a source file or a command-line argument | Verified live |
| You only need to resume state a previous run already saved | A profile, no login at all (`references/profiles.md`) | Re-running a login you do not need | https://www.kernel.sh/docs/auth/overview |
| You do not know which one | Managed Auth if nobody watches the run, Fill from Vault if a human is in the loop | Mixing both on one site in one run | https://www.kernel.sh/docs/auth/overview |

Stored secrets stay out of API responses and model context, but not out of the page: after `fill`, page scripts, extensions and an unrestricted agent can read the values, so attach a vault only to browsers allowed to use every item in it (https://www.kernel.sh/docs/auth/overview).

## Managed Auth flow

**If** you want Kernel to run the login and save the session to a profile.
**Do** create a connection, start a login, follow it, then open a fresh browser on the profile.
**Avoid** reusing the browser the login ran in (it is Kernel's, you never receive it); polling `login` to check progress (each call starts a new flow).
**Source** https://www.kernel.sh/docs/auth/managed-auth, https://www.kernel.sh/docs/auth/hosted-ui; verified live.

```ts
import Kernel from '@onkernel/sdk';

const kernel = new Kernel();
const ONCE = { maxRetries: 0, timeout: 30_000 } as const;   // create and login are side-effecting: never auto-retry

// 1. Store the credential first for any unattended run (without it the flow needs a person). From a shell, use the login skill's script.
await kernel.credentials.create({
  name: 'acme-cred', domain: 'example.com',
  values: { username: process.env.SITE_USER!, password: process.env.SITE_PASSWORD! },
}, ONCE);
// 2. One connection per domain + profile; it starts NEEDS_AUTH. health_checks: false for a one-shot run (each check or reauth is a billed browser).
const conn = await kernel.auth.connections.create({
  domain: 'example.com', profile_name: 'acme-profile', credential: { name: 'acme-cred' }, health_checks: false,
}, ONCE);
// 3. Start the flow. hosted_url and handoff_code are credentials: never log them. With no stored credential
//    a person must open login.hosted_url (or use the React/programmatic paths below).
await kernel.auth.connections.login(conn.id, undefined, ONCE);
// 4. Follow until a terminal flow_status, for at most ~11 minutes (the hosted page waits 10 for input).
const deadline = Date.now() + 11 * 60_000;
let terminal = false;
for await (const ev of await kernel.auth.connections.follow(conn.id)) {
  if (Date.now() > deadline) break;
  if (ev.event !== 'managed_auth_state') continue;   // skip sse_heartbeat
  if (['SUCCESS', 'FAILED', 'EXPIRED', 'CANCELED'].includes(ev.flow_status)) { terminal = true; break; }
}
if (!terminal) throw new Error('no terminal flow_status within 11 minutes: stop and report, do not retry');
const done = await kernel.auth.connections.retrieve(conn.id);
if (done.status !== 'AUTHENTICATED') throw new Error(`login ended ${done.flow_status} ${done.error_code ?? ''}`);

// 5. Work in a NEW browser on the profile (never the login browser). Delete it in finally.
const browser = await kernel.browsers.create(
  { profile: { name: 'acme-profile' }, timeout_seconds: 120, tags: { run: process.env.RUN_ID ?? 'local' } }, ONCE);
try {
  const res = await kernel.browsers.playwright.execute(   // the profile is in the default context, so `page` is signed in
    browser.session_id,
    { code: "await page.goto('https://example.com/account'); return new URL(page.url()).pathname;", timeout_sec: 30 },
    { maxRetries: 0, timeout: 40_000 });
  if (!res.success) throw new Error(String(res.error));
} finally {
  await kernel.browsers.deleteByID(browser.session_id).catch((e) => {
    if (!(e instanceof Kernel.NotFoundError)) throw e;
  });
}
```

Verified live (trimmed). Worth acting on:
- With a stored credential, `login` then `follow` reached `AUTHENTICATED` with no human; a browser on the profile opened the protected page logged in, without the profile it redirected to login. A new connection starts `NEEDS_AUTH`, `can_reauth: false` (reason `no_prior_successful_login`) until one login succeeds.
- `follow` heartbeats arrive as event `sse_heartbeat`; filter on `ev.event === 'managed_auth_state'` and ignore the rest. The stream ends when the flow succeeds, fails, expires or is canceled; a hosted session expires after 20 minutes.
- With no stored credential the flow sits at `AWAITING_INPUT` and ends `FAILED`, `error_code: awaiting_input_timeout`, after 10 minutes if nobody types on the hosted page (seen twice). Poll up to about 11 minutes, then stop and report: the fix is a stored credential or a person.
- `connections.create` also creates the profile, so cleanup deletes both. `post_login_url` on the connection says where the login landed; start from it (https://www.kernel.sh/docs/auth/configuration).
- A profile holds one connection per domain, so one profile per end user covers all that user's sites (https://www.kernel.sh/docs/auth/faq).

CLI equivalents exist for every step: `kernel auth connections create|get|update|list|delete|login|follow|submit|timeline` with `-o json` (flags: `--domain`, `--profile-name`, `--credential-name`, `--no-health-checks`, `--health-check-interval`, `--record-session`). Run live: `credentials create` (via the script), `connections create --credential-name`, `login`, `follow` reached `AUTHENTICATED` in about 45 s with no human. `delete` needs `--yes` when stdin is not a terminal (`credentials delete` takes `-y`).

## Scripted login once, reuse the profile

**If** a dev script of yours logs in with a password itself (no Managed Auth), for a throwaway or demo account the user handed you, and later runs should reuse the session. Throwaway/demo accounts only: for a real account use Managed Auth with a stored credential, or vault fill.
**Do** read the password from the environment at run time and put it into the `playwright.execute` code string with `JSON.stringify` (`execute` takes only `code`, `executor` and `timeout_sec`, so it travels in the request body); never log that string and never commit it. Log in only when the protected page redirects to login; open the browser with `save_changes: true` as the one writer for the profile; `deleteByID` in `finally`.
**Avoid** a hard-coded password; a command-line argument or an inline `SECRET=... node` prefix (shell history); a second writer on the same profile. A password pasted in chat is already in the transcript: keep it out of files, shell history and later commands.
**Source** verified live (ran twice: login performed, then `wasLoggedIn: true`); `references/profiles.md`.

```ts
import Kernel, { ConflictError } from '@onkernel/sdk';

const PROFILE = 'acme-script-login';
const { SITE_USER, SITE_PASSWORD } = process.env;
if (!SITE_USER || !SITE_PASSWORD) throw new Error('SITE_USER and SITE_PASSWORD must be set');

// Runs inside the Kernel VM; the secret is JSON-quoted in at runtime and travels in the request body.
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

await kernel.profiles.create({ name: PROFILE }, { maxRetries: 0, timeout: 30_000 })
  .catch((e) => { if (!(e instanceof ConflictError)) throw e; });
const browser = await kernel.browsers.create(
  { headless: true, timeout_seconds: 300, profile: { name: PROFILE, save_changes: true }, tags: { run: process.env.RUN_ID ?? 'local' } },
  { maxRetries: 0, timeout: 30_000 });
try {
  const res = await kernel.browsers.playwright.execute(
    browser.session_id, { code, timeout_sec: 60 }, { maxRetries: 0, timeout: 90_000 });
  if (!res.success) throw new Error(`execute failed: ${String(res.error)}`);
  console.log(res.result);
} finally {
  // a 404 means the timeout already reaped the browser: fine
  await kernel.browsers.deleteByID(browser.session_id).catch((e) => {
    if (!(e instanceof Kernel.NotFoundError)) throw e;
  });
}
```

Run with `node --env-file=.env` (gitignored) or variables exported in your own shell. Sequential runs with `save_changes: true` are safe; concurrent runs on one profile are not.

## Recovery: NEEDS_AUTH and EXPIRED

**If** `status` is `NEEDS_AUTH`, or a flow ended `EXPIRED` or `FAILED`.
**Do** call `login` again on the same connection and send the user to the new `hosted_url`; then `follow`.
**Avoid** deleting the connection as recovery; calling `login` while a flow is live.
**Source** https://www.kernel.sh/docs/auth/connection-lifecycle; verified live.

Verified live: a second `login` while the first flow was live did not error. It returned a different `hosted_url` and the first flow showed `CANCELED` in `timeline`. So it also ends a pending flow without deleting the connection (otherwise wait for expiry), and any `hosted_url` you already handed out is superseded. Whether the old URL is then dead was not tested. A flow paused at `AWAITING_INPUT` or `AWAITING_EXTERNAL_ACTION` continues only through the `hosted_url` of its own `login` call.

## Check before consequential work

**If** the next step needs the account to be signed in right now (a purchase, a post, a send).
**Do** call `login` then `follow` and wait for `SUCCESS` before creating the browser.
**Avoid** trusting `connection.status` alone: it reflects the last completed health check, and the site session can expire after it.
**Source** https://www.kernel.sh/docs/auth/connection-lifecycle, https://www.kernel.sh/docs/auth/faq.

Pattern (untested; docs): `await kernel.auth.connections.login(id)`, then `for await (const ev of await kernel.auth.connections.follow(id))` over `managed_auth_state` events: return on `flow_status === 'SUCCESS'`, throw "user action required" on `flow_step` `AWAITING_INPUT` or `AWAITING_EXTERNAL_ACTION`, and throw if the stream ends without `SUCCESS`. With a previous successful login and a saved check URL, `login` first verifies the profile and reaches `SUCCESS` without typing (docs; unverified).

## React embed (Next.js App Router)

**If** the user must sign in inside your own app instead of on Kernel's hosted page.
**Do** keep the API key on the server: a backend route creates or reuses the connection, calls `login`, and returns only the connection `id` and the one-time `handoff_code`. The page is a `'use client'` component with `<KernelManagedAuth sessionId handoffCode onSuccess onError />` (`sessionId` is the connection id) and the package stylesheet.
**Avoid** the API key in the frontend; returning `hosted_url` or `live_view_url` (the `login` response carries both and both are credentials); reusing a `handoff_code` (single-use, so every reconnect needs a fresh `login`); taking `success_url` or `error_url` from client input; a `profile_name` shared across end users or derived from the domain (one profile per end user, never per domain); auto-retries on `connections.create` and `login`.
**Source** https://www.kernel.sh/docs/auth/react; the route type-checks against @onkernel/sdk 0.128.0 (strict `tsc`; not run against Kernel); the component and its props, callbacks and stylesheet path are (unverified): the package was not installed.

`profile_name` must be per end user (`user-<id>` from your session, never from the request body, never per domain), or every app user shares one logged-in session. `connections.create` and `login` are side-effecting: pass `{ maxRetries: 0 }` and handle 409 (see "409 on create"; `connectionFor` below is defined there). `handoff_code` is optional in the SDK type (`handoff_code?`): return 502 when it is missing. A `domain` from the client is untrusted: validate it, and prefer an allow-list of the sites your app supports.

```ts
// app/api/connect/route.ts
import Kernel from '@onkernel/sdk';

// Build the client inside the handler: `new Kernel()` throws when KERNEL_API_KEY is missing, and Next evaluates route modules at build time.
const OPERATION = { maxRetries: 0, timeout: 30_000 } as const;

// PLACEHOLDER: replace with your own session lookup. Returning null makes the route answer 401.
const getSessionUserId = async (request: Request): Promise<string | null> => null;

// Lower-case, strip scheme, path and port; the dotted name must end in a letter TLD, which rejects IPs and localhost.
const cleanDomain = (input: unknown): string | null => {
  const host = String(input ?? '').trim().toLowerCase().replace(/^[a-z]+:\/\//, '').split(/[/?#]/)[0].replace(/:\d+$/, '');
  return /^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{1,62}$/.test(host) ? host : null;
};

export async function POST(request: Request): Promise<Response> {
  const userId = await getSessionUserId(request);
  if (!userId) return Response.json({ error: 'unauthorized' }, { status: 401 });
  const body = (await request.json().catch(() => ({}))) as { domain?: unknown };
  const domain = cleanDomain(body.domain);
  if (!domain) return Response.json({ error: 'bad_domain' }, { status: 400 });
  const kernel = new Kernel();                     // KERNEL_API_KEY stays on the server
  const conn = await connectionFor(kernel, domain, `user-${userId}`);
  const login = await kernel.auth.connections.login(conn.id, undefined, OPERATION);
  if (!login.handoff_code) return Response.json({ error: 'no_handoff_code' }, { status: 502 });
  // Return only these. Never hosted_url or live_view_url.
  return Response.json({ connectionId: login.id, handoffCode: login.handoff_code, flowExpiresAt: login.flow_expires_at });
}
```

```tsx
// untested: from the docs page; props, callbacks and the stylesheet path are (unverified)
'use client';
import { useState } from 'react';
import { KernelManagedAuth } from '@onkernel/managed-auth-react';
import '@onkernel/managed-auth-react/styles.css';

export function ConnectSite({ domain }: { domain: string }) {
  const [auth, setAuth] = useState<{ connectionId: string; handoffCode: string } | null>(null);
  const start = async () => {
    const res = await fetch('/api/connect', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ domain }) });
    if (res.ok) setAuth(await res.json());          // { connectionId, handoffCode, flowExpiresAt }
  };
  if (!auth) return <button onClick={start}>Connect {domain}</button>;
  return <KernelManagedAuth sessionId={auth.connectionId} handoffCode={auth.handoffCode}
    onSuccess={({ profileName, domain }) => { /* continue */ }}
    onError={({ code, message }) => { /* show a retry */ }} />;
}
```

`sessionId` on the component carries the connection id, not a browser `session_id`.

- Default `baseUrl` talks to Kernel directly. For same-origin traffic set `baseUrl=""` and rewrite exactly these four routes to the Kernel API: `/auth/connections/:id/exchange`, `/auth/connections/:id`, `/auth/connections/:id/submit`, `/auth/connections/:id/events`.
- The component gives no ongoing recovery: when the connection returns to `NEEDS_AUTH`, your backend calls `login` again and passes a fresh `handoff_code`.

## Programmatic flow (your own UI)

**If** you build the credential form or MFA picker yourself, or run headless with a human answering by another channel.
**Do** `follow` the connection; on `flow_step === 'AWAITING_INPUT'` render the event's `fields` or `choices`; reply with one `submit` carrying that event's `interaction_id` plus either `field_values` keyed by the field `id`, or `selected_choice_id` with the exact `choice.id`.
**Avoid** keying `field_values` by `ref`; sending both `field_values` and `selected_choice_id`; replaying an old `interaction_id` (stale ids are rejected, and a new screen gets a new one); deriving a choice id from its label.
**Source** https://www.kernel.sh/docs/auth/programmatic (untested: the test site had no MFA, so no `AWAITING_INPUT` was seen).

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
| `awaiting_input_timeout` | No one typed on the hosted page within 10 minutes (no stored credential, or the site asked for input). Store a credential with the script, or send a person to a fresh `login`; do not loop. Seen live. |

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
**Source** https://www.kernel.sh/docs/auth/configuration, https://www.kernel.sh/docs/auth/faq (untested: the test credential had no TOTP; `has_totp_secret` appears on the credential response).

The shipped script takes `SITE_TOTP_SECRET` and sets `totp_secret`; with the SDK pass `totp_secret` next to `values` in `kernel.credentials.create` (docs; untested). A credential may hold partial values (email plus `totp_secret`, password typed each time); `save_credentials: false` on the connection opts out of saving what the user types (docs).

## Health checks cost

**If** the connection serves a single task or a one-shot run.
**Do** create it with `health_checks: false` (CLI `--no-health-checks`); health checks and reauths each start a billed browser session (typically 5 to 30 s each).
**Avoid** leaving checks on for connections nobody will reuse.
**Source** https://www.kernel.sh/docs/auth/faq; verified live.

- `auto_reauth` only matters when `health_checks` is `true`; otherwise an expired session becomes `NEEDS_AUTH` with no attempt.
- The lowest `health_check_interval` is plan-dependent: verified live: 60 got HTTP 400 `must be between 3600 and 86400 seconds` and 3600 was accepted. Read the 400 body or `kernel org limits get -o json` (`min_health_check_interval_seconds`); do not hard-code.

## 409 on create

**If** `connections.create` returns 409 (that domain and profile already have a connection).
**Do** read `existing_id` defensively from the error body and use that connection; if it is absent, list with the exact `domain` and `profile_name` and pick the match.
**Avoid** guessing which connection matches from a loose list; trusting `existing_id` to be typed.
**Source** `existing_id` verified live (409 body keys `code`, `existing_id`, `message`; its presence was checked, not that it equals the live connection id). It is NOT in the SDK types: `ConflictError.error` is an untyped object, so cast and check it.

```ts
async function connectionFor(kernel: Kernel, domain: string, profile_name: string) {
  try {
    return await kernel.auth.connections.create({ domain, profile_name }, { maxRetries: 0, timeout: 30_000 });
  } catch (e) {
    if (!(e instanceof Kernel.ConflictError)) throw e;   // typed 409
    const id = (e.error as { existing_id?: unknown } | undefined)?.existing_id;
    if (typeof id === 'string') return kernel.auth.connections.retrieve(id);
    for await (const c of kernel.auth.connections.list({ domain, profile_name })) {
      if (c.domain === domain && c.profile_name === profile_name) return c;
    }
    throw e;
  }
}
```

The same `ConflictError` catch on `profiles.create` also ran live.

## Fill from Vault

**If** your agent drives the login in its own browser (mid-task prompt, user-owned credentials, custom submit and recovery).
**Do** follow the one full recipe in `references/vaults-payments.md`, "Vault fill (login)": vault, credential item, browser created with the vault, `performOperation` `fill`, then submit yourself and check the page.
**Avoid** a second copy of the steps here; attaching a vault to a browser that should not see all its items; treating `completed` as logged in.
**Source** https://www.kernel.sh/docs/auth/fill-from-vault; verified live. To reuse the login later, create the browser with a profile and `save_changes: true` (`references/profiles.md`).

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

## Cleanup

**If** the run was one-shot and you created the connection, credential, profile or vault.
**Do** delete them: `kernel.auth.connections.delete(id)`, `kernel.credentials.delete(name)`, `kernel.profiles.delete(name)`; vaults: `kernel.vaults.items.delete(key, { id_or_name })` then `kernel.vaults.delete(name)`. CLI needs `--yes` (`kernel auth connections delete <id> --yes`, `kernel profiles delete <name> --yes`, `kernel credentials delete <name> -y`) when stdin is not a terminal.
**Avoid** deleting a connection or profile that a real user still needs.
**Source** verified live. Check with `kernel auth connections list --domain <d> --profile-name <p> -o json`, `kernel credentials list --query <name> -o json`, `kernel profiles list --name <p> -o json` (all `[]`). `kernel vaults get <name>` on a deleted vault prints plain `ERROR: Not_found`.

Verified live 2026-10-20 (Hobbyist plan); types re-checked on @onkernel/sdk 0.128.0. Evidence ledger: https://github.com/yigitkonur/plugin-kernel-sh/blob/main/verified-facts.md
