---
name: login
description: >-
  Get an agent a logged-in Kernel browser for a website, after confirming the user wants browser auth: first decide whether browser auth is needed at all (API or MCP first), then choose Managed Auth (hosted login saved to a profile) or a vault fill, and relaunch a logged-in browser. Use when code or a task needs an authenticated session on a site: log in, reuse a login, credentials, SSO or MFA.
argument-hint: "<domain>"
---

# /kernel:login

Goal: leave the user with a Kernel browser already signed in to one site, a profile name and connection id they can reuse, and no secret in the transcript.

The argument is the text after the skill name (or the line starting `ARGUMENTS:`): a domain such as `example.com`. If missing, ask and stop. Use the bare domain (no scheme, no path) for `<domain>`.

Rules for the whole run:
- Never print, paste or log an API key, a `hosted_url`, a `handoff_code`, a `cdp_ws_url`, a live view URL or a replay URL. They are credentials. Keep them out of your context with `jq` projections and files written under `umask 077`.
- Never pass a password, TOTP secret or one-time code as a CLI argument (`--value`, `--field-value`). A human types secrets into the hosted page.
- Never dump `follow` or `timeline` streams; use `jq` filters and `--limit`/`--type`.
- Never delete the connection or profile to recover. Recovery is another `login` on the same connection.
- Shell state does not persist between Bash calls: write ids and names literally.

## Step 1. Preflight
1. `command -v kernel`. If empty, tell the user to run `brew install kernel/tap/kernel` (or `npm i -g @onkernel/cli`) and stop. Install nothing yourself.
2. `kernel auth context -o json | jq 'keys'`. If it fails, tell the user to run `kernel login` or set `KERNEL_API_KEY`, then stop.
3. If the user named a Kernel project, pass `--project <id-or-name>` on every command below.

## Step 2. Is browser auth needed, and which path
Docs: "If the task can be done through an API or an MCP server, use that instead." (https://www.kernel.sh/docs/overview/why-kernel)

1. A URL is not proof a browser is needed. If an API, CLI or MCP server covers the operation, or the pages are public, say so and stop.
2. If a previous run saved the state you need, a profile alone is enough: go to Step 5.
3. Otherwise pick one path, tell the user which and why:

| Situation | Path |
|---|---|
| Nobody watches the run, it recurs, or the site uses SSO or MFA | Managed Auth (Steps 3 to 6) |
| The user is present and the agent drives navigation, submit and recovery (a login can appear mid-task) | Vault fill: see "Fill from Vault" in `../kernel/references/logins.md`; the steps below do not apply |

Never mix both on one site in one run.

## Step 3. Reuse or create the connection
A connection ties one domain to one profile; a profile holds at most one connection per domain.

1. Look for an existing one:
   ```bash
   kernel auth connections list --domain <domain> -o json \
     | jq '[.[] | {id, domain, profile_name, status, can_reauth, can_reauth_reason}]'
   ```
2. If one matches the account the user means, reuse its `id` and `profile_name`. If several match and you cannot tell them apart, ask which profile; do not guess.
3. If none matches, choose a stable profile name (one per end user or account, for example `<domain>-main`). Before creating anything, state the path (Managed Auth), the profile name and the connection (domain + profile) and wait for a yes. Skip the wait only if the user already named them.
4. Create it. Pass `--no-health-checks` unless the user asked for unattended reuse: health checks and reauths each start a billed browser session (https://www.kernel.sh/docs/auth/faq).
   ```bash
   kernel auth connections create --domain <domain> --profile-name <profile> --no-health-checks -o json \
     | jq '{id, status, can_reauth, can_reauth_reason, health_checks}'
   ```
   A new connection starts `NEEDS_AUTH`, `can_reauth: false`, reason `no_prior_successful_login`. That is normal.
5. On HTTP 409 the domain and profile already have a connection. Run `kernel auth connections list --domain <domain> --profile-name <profile> -o json` and reuse the exact match (the 409 body also carries `existing_id`).
6. Options, only when needed:
   - Unattended reuse: drop `--no-health-checks`; the lowest `--health-check-interval` depends on the plan, so read the 400 message instead of guessing.
   - Saved credential for unattended reauth: `--credential-name <name>`. Create it in the Kernel dashboard, or have the user run a small SDK script reading `SITE_USER` and `SITE_PASSWORD` from the environment. Never `kernel credentials create --value password=...`.
   - TOTP authenticator: the credential needs `totp_secret` (see `../kernel/references/logins.md`, "MFA"). Email, SMS and push codes need a human every time.
   - Custom login page or extra SSO hosts: `--login-url`, `--allowed-domain` (repeat per host).

## Step 4. Log in
1. If `status` is `AUTHENTICATED`, do not start a flow: go straight to Step 5 and verify in a fresh browser. Run `login` only if that browser lands on a login page.
2. Start the flow once. Save the response privately so the URL never enters your context:
   ```bash
   umask 077; F="${TMPDIR:-/tmp}/kernel-login-<id>.json"
   kernel auth connections login <id> -o json > "$F" \
     && jq '{flow_type, flow_expires_at, has_hosted_url: (.hosted_url != null)}' "$F"
   ```
   Never call `login` again to check progress or nudge a stuck flow: it starts a new flow with a different `hosted_url` and cancels the first.
3. `follow` can block about 20 minutes but the Bash tool stops at 10. Run it in the background (`run_in_background`), writing to a private file. Do not use `timeout`: stock macOS does not have it; stop the background task yourself instead.
   ```bash
   umask 077; kernel auth connections follow <id> -o json \
     | jq --unbuffered -c 'select(.event=="managed_auth_state") | {flow_status, flow_step, error_code}' \
     > "${TMPDIR:-/tmp}/kernel-follow-<id>.log"
   ```
   Poll every ~15 s (`sleep 15`) with the Step 5 `get` command until `flow_status` is terminal (`SUCCESS`, `FAILED`, `EXPIRED`, `CANCELED`). Stop the background task when it is terminal or after about 9 minutes, whichever comes first. Run nothing else that changes this connection meanwhile.
4. If `flow_step` is `AWAITING_INPUT` or `AWAITING_EXTERNAL_ACTION`, a person must act.
   - User present: open the hosted page without printing it, and give the URL to the user once in a message only if no opener works:
     ```bash
     F="${TMPDIR:-/tmp}/kernel-login-<id>.json"
     (open "$(jq -r .hosted_url "$F")" 2>/dev/null || xdg-open "$(jq -r .hosted_url "$F")" 2>/dev/null) || echo "no opener available"
     ```
     If it prints `no opener available`, tell the user to run `jq -r .hosted_url <file path>` in their own terminal. Say "Finish the login in the page that opened; I will wait here", and keep polling the same flow.
   - User not present: do not open anything. Report `AWAITING_INPUT` in the report and stop.
5. If the flow ends `EXPIRED` or `CANCELED`, allow exactly ONE more `login` on the same connection (back to item 2). If it ends that way again, stop and report.
6. Non-secret choices only: `kernel auth connections submit <id> --choice-id <choice id>`. Secrets go through the hosted page.
7. React embed: out of scope; see `../kernel/references/logins.md`, section "React embed".
8. When the flow is finished, `rm -f` the two temp files.

## Step 5. Confirm, branch on failure, then verify in a fresh browser
```bash
kernel auth connections get <id> -o json \
  | jq '{status, flow_status, flow_step, error_code, error_message, website_error, can_reauth, can_reauth_reason}'
```
Proceed to the browser check only when `status` is `AUTHENTICATED` and, if a flow ran, `flow_status` is `SUCCESS`. Otherwise branch on `error_code` (https://www.kernel.sh/docs/auth/connection-lifecycle):

| `error_code` | Do |
|---|---|
| `bot_detected`, `captcha_blocked` | Set an ISP or custom proxy on the connection (`kernel auth connections update <id> --proxy-id <proxy id>`; see `../kernel/references/unblock.md`), then `login` once. Do not loop. |
| `account_locked` | Stop. The user unlocks the account on the site; another `login` may extend the lockout. |
| `credentials_invalid` | Ask the user to fix the linked credential (dashboard or env-reading SDK script), then `login` once. |
| `totp_code_rejected` | Retry once in a new TOTP window; if it fails again, ask the user to re-enter the secret. |
| `totp_required`, `sms_code_required`, `email_code_required`, `account_choice_required`, `customer_input_required`, `external_action_required` | Needs a person: Step 4 item 4. |
| `rate_limited` | Wait for the site's window, then one new `login`. |
| `website_error` | Usually the site; Kernel retried once. Try later. |
| `unsupported_auth_method` | Passkeys are unsupported; the account must use password plus TOTP. |

Never loop on a failed login. If `status` is `NEEDS_AUTH` with no `error_code`, run `login` once on the same connection. To see what happened: `kernel auth connections timeline <id> --per-page 5 -o json | jq '.events[] | {timestamp, type, status, step, error_code}'`.

The login ran in a browser Kernel started and you never receive. Do not reuse any task browser that hit a login wall. Create a new one on the profile:
```bash
kernel browsers create --profile-name <profile> --start-url https://<domain>/ -o json | jq '{session_id}'
```
Keep only `session_id`. Check for a signed-in page, not a flash message:
```bash
kernel browsers playwright execute <session_id> 'return { path: new URL(page.url()).pathname, logout_links: await page.getByRole("link",{name:/log ?out|sign ?out/i}).count() }'
```
Signed in means `logout_links` is above 0 and the URL path is not the login path.

- If it lands on a login page, run Step 4 on the same connection; do not create a second profile.
- Add `--save-changes` only on exactly one browser per profile: two writers overwrite each other (`../kernel/references/profiles.md`). Reading does not need it.
- For the user's code, give `profile: { name: '<profile>' }` for `kernel.browsers.create`, not the session id of this browser.
- Delete the verification browser unless the user asked to keep it: `kernel browsers delete <session_id>`.

## Step 6. Recovery later (tell the user, one short paragraph)
- Before consequential work (purchase, post, send), verify in a fresh profile browser; run `login` and wait for `SUCCESS` if it lands on a login page. `status` alone can be stale.
- If the connection falls to `NEEDS_AUTH`, `login` again on the same connection and send the person to the new hosted page. Do not delete and recreate it.
- Health checks cost browser time; off on one-shot connections (`kernel auth connections update <id> --no-health-checks`).
- Cleanup for one-shot runs: `kernel auth connections delete <id>`, then `kernel profiles delete <profile>`. Confirm first; it cannot be undone.

## Report to the user
End with exactly this, filled in, with no secret or URL:

```
Login: <domain>
Decision: <API/MCP instead | profile reuse | Managed Auth | vault fill> because <one line>
Connection: <id> (profile <profile name>)   status=<AUTHENTICATED|NEEDS_AUTH>   can_reauth=<true|false>
Flow: <LOGIN|REAUTH> result=<SUCCESS|FAILED|EXPIRED|CANCELED|AWAITING_INPUT>   error_code=<none|code>
Verification: <signed-in element seen on <url path> | redirected to login | not checked>
Use it: kernel.browsers.create({ profile: { name: '<profile>' } })
Health checks: <on|off>, interval <n>s
Left running: <browser ids still alive, or none>
Next step for you: <one line, for example "type the MFA code on the page that opened", or none>
Not verified: <anything unverified you relied on, or none>
```
If the run stopped early, put the stop reason in `Decision` and `n/a` elsewhere.

> Verified in lab 2026-10-20, SDK 0.128.0 / CLI 0.49.0. CLI `follow`, `timeline`, `submit`, the CLI 409 output and failure codes were not run; see verified-facts.md.
