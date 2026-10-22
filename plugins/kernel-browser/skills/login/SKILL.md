---
name: login
description: >-
  Put a website login into a Kernel profile so later Kernel browsers start signed in, without any password passing through chat: a hosted Kernel login page or a live view the user types into, the user's 1Password (approved in the 1Password app), or a credential stored from environment variables for unattended re-login. Use when a Kernel browser lands on a login page, the user asks to log in to a site in Kernel, or a saved Kernel login has expired.
argument-hint: "<domain>"
---
<!-- Derived in part from the official Kernel skill `kernel-auth` (https://github.com/kernel/skills, MIT, Copyright (c) 2025 Kernel). License text: THIRD_PARTY_NOTICES.md at the plugin root. -->

# /kernel-browser:login

Goal: a Kernel profile that opens signed in to one site, a name the user can reuse, and no secret in the transcript.

The argument is the text after the skill name (or the line starting `ARGUMENTS:`): a domain such as `github.com`. If missing, ask and stop. Lower-case it and check it is a hostname (`^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$`, at most 253 characters); otherwise say so and stop. Profile and credential names you choose: `^[A-Za-z0-9._-]{1,64}$`.

Tools are the Kernel MCP tools; give each call a one-line `context`. Pass `project` when the kernel-browser note at session start names one (the plugin's `project` option) or the user named one.

## Rules
- Never ask for, accept or type a password, one-time code or TOTP seed in chat or in a tool input (`manage_credentials` `values`, `manage_auth_connections` `submit` `field_values`, `manage_vault_credentials` field values, Playwright code, `computer_action` typing). The user types secrets into a Kernel-hosted page, a live view or their 1Password app; the script in Path C reads them from environment variables.
- A `hosted_url`, live-view URL or 1Password approval link goes to the user once, in one message, only when they must act. Never put it in a file, a command or a browser the agent drives, and never open it yourself.
- Never delete a connection, profile or vault item to "retry". Recovery is another login on the same connection or profile.
- Every browser you create carries `tags: { cc_session: "<this session id>" }` and `timeout_seconds` (the plugin sends a create back otherwise). Delete it before you report.

## Step 1. Is a login needed, and is there one already
1. If the task works through an API, or the pages are public, say so and stop.
2. `manage_auth_connections` `action: list` with `domain_filter: "<domain>"`, and `manage_profiles` `action: list` with `query` set to the site name.
   - A connection with `status: AUTHENTICATED`: go to Step 3 and verify; log in again only if the check fails.
   - A connection with `status: NEEDS_AUTH`: reuse it (Path A item 2 on that connection id).
   - A profile without a connection: verify it (Step 3); if it is logged out, refresh it with Path B or D into the same profile.
   - Several candidates: ask which account; never guess.
3. New profile name: `<site>-<account>` from the user's words (`github-work`); `<site>-main` when the login is the asking user's only one. One profile per site account; never one profile for several people.

## Step 2. Pick the path (ask the user when more than one fits)
| Situation | Path |
|---|---|
| The user is here and can type into a web page | **A. Hosted login** (default; works with SSO and email or SMS codes too) |
| SSO, a passkey or an odd login flow the hosted page cannot handle, or the user wants to see the real site | **B. Live view** |
| The user's login is in their own 1Password (not a shared vault, not a passkey) | **D. 1Password** (preview) |
| Nobody will be present later, and the profile must log in again by itself | **C. Stored credential**, then A on the same connection |

Ask before choosing D: "Is your <domain> login saved in your own 1Password, or would you rather type it once in a secure Kernel page?" Never pick a path that stores credentials without telling the user.

## Path A. Hosted login (Managed Auth)
A Managed Auth connection ties one domain to one profile, logs in through a Kernel-hosted page, saves the login into the profile, and can re-login later.
1. Create the connection (it also creates the profile): `manage_auth_connections` `action: create` with `domain`, `profile_name`, and `health_checks: false` unless the user wants unattended upkeep (health checks start billed browsers). A conflict means it exists: list it (Step 1) and reuse it.
2. Start one flow: `action: login` with the connection `id`. The result holds a `hosted_url`. Give it to the user once: "Open this link and sign in to <domain>; I will wait here." Do not call `login` again to check progress: a new `login` cancels the first flow.
3. Wait: `action: wait` with the `id` (it waits up to 30 s per call). While it reports pending, call `wait` again; do not ask the user whether they finished. Stop after about 11 minutes: an unattended hosted page fails with `awaiting_input_timeout` after 10.
4. Success is `status: AUTHENTICATED` with the flow ended `SUCCESS`. On failure read `error_code`:

| `error_code` | Do |
|---|---|
| `awaiting_input_timeout` | nobody typed in time; one new `login` when the user is ready, or Path C |
| `bot_detected`, `captcha_blocked` | set an ISP proxy on the connection (`action: update`, `proxy`), then one new `login` (`../browse/references/unblock.md`) |
| `credentials_invalid` | the user fixes the password on the site or in the stored credential, then one new `login` |
| `account_locked` | stop; the user unlocks it on the site |
| `totp_code_rejected` | one retry in the next 30 s window |
| `unsupported_auth_method` | passkeys are not supported: Path B |
| `provider_unavailable` | Kernel's sign-in service was briefly down (seen live once); one new `login` |
| `EXPIRED` or `CANCELED` flow | one more `login`, then stop |

Never loop. `action: timeline` with the `id` shows what happened.

## Path B. Live view (the user logs in on the real site)
1. `manage_profiles` `action: setup` with `profile_name` (add `update_existing: true` to refresh an existing profile). It starts a stealth browser that saves into the profile, with a 300 s idle timeout. Keep the `session_id` (the plugin tracks it).
2. Give the user the live-view URL once: "Sign in to <domain> in this window. Tell me if a step needs something only you can do." An open live view keeps the browser active and billed.
3. Poll the page every 15-20 s with `execute_playwright_code` on that `session_id`, returning only `{ path: new URL(page.url()).pathname, signed_in: <count of a signed-in element> }` (for example `await page.getByRole('link', { name: /log ?out|sign ?out/i }).count()`, or the site's avatar or account menu). Never return page text that could hold a code.
4. When the page shows the user signed in: ask the user to close the live-view tab, then `manage_browsers` `action: delete` on that `session_id`. Deleting saves the profile. Do not delete earlier: an unfinished login would be saved logged out.
5. If the user leaves without finishing, the browser idles out after 300 s and saves whatever state it has: verify (Step 3) before relying on it.

## Path C. Stored credential (unattended re-login)
Kernel stores the username, password and optional TOTP seed (encrypted; values are never returned), and Managed Auth logs in with no person present. Email, SMS and push codes still need a person.
1. Needs `node` (18+) and `KERNEL_API_KEY` in the environment, plus `SITE_USER`, `SITE_PASSWORD` and optional `SITE_TOTP_SECRET` that the user sets themselves, in the shell that launched Claude Code or in a gitignored `.env`. Never write them into a command line.
2. Run the shipped script (`${CLAUDE_SKILL_DIR}` is this skill's folder; if empty, the script is at `<plugin>/skills/login/scripts/create-credential.mjs`):
   ```bash
   cred='github-com-main'; domain='github.com'
   node --env-file=.env "${CLAUDE_SKILL_DIR}/scripts/create-credential.mjs" "$cred" "$domain"
   ```
   (Without `.env`, drop `--env-file=.env`.) It prints only `id`, `name`, `domain`, `has_totp_secret`. Exit 2: a variable is missing. Exit 1: an HTTP error (409: the name exists).
3. Create or update the connection with `credential_name` (`manage_auth_connections` `action: create`, or `action: update` on an existing one), then Path A from item 2. With a credential, `login` usually ends `AUTHENTICATED` within a minute, with nobody at the page (verified live in the kernel-dev ledger).

## Path D. 1Password Agentic Autofill (preview)
The user links their 1Password account once and approves each login request in the 1Password app. 1Password's extension, loaded into the Kernel browser, fills and submits; Kernel and the agent never see the values. Only logins in the owner's own non-shared vault; no passkeys. Source: https://www.kernel.sh/docs/vaults/1password
1. Vault: `manage_vaults` `action: create` with an immutable `name` for this user (for example `me`). It returns the existing vault if present.
2. Account link: `manage_vault_items` `action: list` in that vault. Reuse a connected `credential_account`. Otherwise `manage_vault_credentials` `action: connect_account`, `provider: "1password"`, a new `key` (for example `onepassword`). Give the returned authorization URL to the user once, to open in their own browser (never the Kernel browser). Wait with `manage_vault_items` `action: get` on that key until it reports connected.
3. Login request: confirm with the user which site logins to request (1-5). `manage_vault_credentials` `action: create`, `provider: "1password"`, a new `key` (`github-com`), `spec: { account: "<account key>", logins: [{ website: "https://<domain>" }] }`.
4. Approval: `manage_vault_items` `action: invoke`, `operation: "1pw_create_access_request"` on that credential. Give the returned `onepassword://` link, unmodified, to the user: "Approve this request in your 1Password app." Poll with `operation: "1pw_access_request_status"` until approved. Never open or approve it yourself.
5. Fill: create a browser with this vault attached and saving into the profile: `manage_browsers` `action: create` with `vaults: [{ name: "<vault>" }]`, `profile_name`, `save_profile_changes: true`, `stealth: true`, tags and `timeout_seconds`. Open the site's login page, then `manage_vault_items` `action: invoke`, `operation: "1pw_fill"`, `inputs: { browser_id: "<session id>", page_url: "<exact current https URL>" }`. If several approved logins share the page origin, ask which and pass its `entry_id`. If the site asks for the one-time code on a later page, invoke `1pw_fill` again there.
6. Check the page (Step 3 test). A fill result never proves the login. Signed in: delete the browser (this saves the profile). From now on, browsers load the profile read-only and need no 1Password approval until the site's session expires; then repeat items 4-5.
7. If the vault tools are missing, the request fails, or the login is in a shared vault or uses a passkey: tell the user 1Password did not work and use Path A or B. A `404 not_found` from `connect_account` while other vault calls work means the 1Password preview is not enabled for this Kernel org (seen live 2026-10-22): the user can ask Kernel support to enable it.

A 1Password **service account** (Business or Teams plans) lets Kernel log in fully unattended: the user connects it in the Kernel dashboard (Integrations), then Path A uses `credential_provider` and `credential_path` (`Vault/Item`) on the connection. Never accept a service-account token in chat; the plugin blocks it in tool input.

## Step 3. Verify in a fresh browser
The login ran in a browser you do not reuse. `manage_browsers` `action: create` with `profile_name`, no `save_profile_changes`, `stealth: true`, tags, `timeout_seconds: 300`. `execute_playwright_code`: go to the site's home page and return `{ path, signed_in }` as in Path B item 3. Signed in means a signed-in element is present and the path is not a login page. Then delete this browser.

## Report to the user
```
Login: <domain>   Path: <A hosted | B live view | C stored credential | D 1Password>
Profile: <name>   Connection: <id or none>   status=<AUTHENTICATED|NEEDS_AUTH|n/a>
Verified: <signed-in element seen on <path> | redirected to login | not checked>
Use it: /kernel-browser:browse with profile <name> (browsers load it read-only)
Left running: <browser ids, or none>
Next step for you: <one line, or none>
```

MCP tool names and parameters checked against the Kernel MCP server source, 2026-10-22. Paths A and C were verified live in the kernel-dev ledger through the CLI; Path D is a preview feature. Evidence: https://github.com/yigitkonur/plugin-kernel-sh/blob/main/verified-facts.md
