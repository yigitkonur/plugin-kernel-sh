---
name: login
description: >-
  Get an agent a logged-in Kernel browser for a website: first decide whether browser auth is needed at all, then set up Managed Auth (hosted login, profile-backed) or a vault fill, and relaunch a logged-in browser. Use when code or a task needs an authenticated session on a site: log in, reuse a login, credentials, SSO or MFA.
argument-hint: "<domain>"
---

# /kernel:login

Goal: leave the user with a Kernel browser that is already signed in to one site, a profile name and connection id they can reuse, and no secret in the transcript.

The argument is the text after the skill name in the user's message (or the line starting `ARGUMENTS:`). It is a domain such as `example.com`. If it is missing, ask for it and stop until you have it. Use the bare domain (no scheme, no path) wherever a command below says `<domain>`.

Rules for the whole run:
- Never print, paste or log an API key, a `hosted_url`, a `handoff_code`, a `cdp_ws_url`, a live view URL or a replay URL. Those URLs are credentials. Filter output with `jq` so they never reach you (the commands below already do).
- Never pass a password, TOTP secret or one-time code as a CLI argument (`--value`, `--field-value`): arguments land in shell history and process lists. A human types secrets into the hosted page.
- Never dump `follow` or `timeline` streams. Always use `jq` filters and `--limit`/`--type`.
- Never delete the connection or the profile as a way to recover. Recovery is another `login` on the same connection.
- Shell state does not persist between Bash calls. Write the connection id and profile name literally into each command.

## Step 1. Preflight

1. Run `command -v kernel`. If it prints nothing, print these two options and stop. Do not install anything yourself.
   ```
   brew install kernel/tap/kernel
   npm i -g @onkernel/cli
   ```
2. Run `kernel auth context -o json | jq 'keys'`. If it fails, tell the user to run `kernel login` or set `KERNEL_API_KEY` in their environment, then stop.
3. If the user named a Kernel project, pass `--project <id-or-name>` on every command below (CLI source: global flag).

## Step 2. Is browser auth needed at all

Rule zero from Kernel docs: "If the task can be done through an API or an MCP server, use that instead." (https://www.kernel.sh/docs/overview/why-kernel).

1. Ask yourself what the user needs from `<domain>`. A URL is not proof that a browser is needed. If the site has an API, CLI or MCP server that covers the operation, tell the user to use that and stop.
2. If the pages being read are public, no login is needed. Stop and say so.
3. If a previous run already saved the state you need, a profile alone is enough: skip to Step 6 with that profile name.
4. Otherwise pick one path and tell the user which and why:

| Situation | Path |
|---|---|
| Nobody watches the run, it recurs, or the site uses SSO or MFA | Managed Auth (Steps 3 to 7) |
| The user is present and your agent will drive navigation, submit and recovery in its own browser (a login can appear mid-task) | Vault fill (Step 8) |

Do not mix both on one site in one run (`../kernel/references/logins.md`, Avoid row "Mixing both on one site in one run"). The unattended and SSO/MFA criteria come from https://www.kernel.sh/docs/auth/overview.

## Step 3. Reuse or create the connection

A connection ties one domain to one profile. A profile holds at most one connection per domain.

1. Look for an existing one:
   ```bash
   kernel auth connections list --domain <domain> -o json \
     | jq '[.[] | {id, domain, profile_name, status, can_reauth, can_reauth_reason}]'
   ```
   `list --domain --profile-name` ran in the lab (P10); the jq projection is untested (the list is a JSON array, P10).
2. If one matches the account the user means, reuse its `id` and `profile_name`. If several match and you cannot tell the account apart, ask the user which profile name to use. Do not guess.
3. If none matches, pick a stable profile name (one per end user or account, for example `<domain>-main`) and create it:
   ```bash
   kernel auth connections create --domain <domain> --profile-name <profile> -o json \
     | jq '{id, status, can_reauth, can_reauth_reason, health_checks, health_check_interval}'
   ```
   Flags are from CLI source (`kernel auth connections create --help`); the same call through the SDK ran in P10. A new connection starts `NEEDS_AUTH` with `can_reauth: false` and reason `no_prior_successful_login`. That is normal.
4. If create fails with a conflict (HTTP 409), that domain and profile already have a connection. The SDK error body carries `existing_id` (P10). With the CLI, use that `existing_id` if the CLI prints it. (unverified: how the CLI prints a 409.) If it does not show the id, stop and ask the user; do not list and pick a result.
5. Add options only when they are needed:
   - One-shot task, nobody will reuse the connection: add `--no-health-checks`. Health checks and reauths each start a billed browser session (https://www.kernel.sh/docs/auth/faq). The lowest `--health-check-interval` depends on the plan (an account here rejected 60 and accepted 3600, P10); read the 400 message instead of guessing.
   - A saved credential should power unattended reauth: link it with `--credential-name <name>`. Create that credential in the Kernel dashboard, or tell the user to run a small SDK script that reads `SITE_USER` and `SITE_PASSWORD` from the environment (`kernel.credentials.create`, ran in P10; the response never echoes the password). Do not use `kernel credentials create --value password=...`.
   - TOTP authenticator: the credential needs `totp_secret`, plus `totp_algorithm`, `totp_digits` and `totp_period` when the site does not use the defaults (https://www.kernel.sh/docs/auth/configuration). Email, SMS and push codes need a human every time.
   - Custom login page or extra SSO hosts: `--login-url`, `--allowed-domain` (repeat per host).

## Step 4. Log in

1. If the connection is `AUTHENTICATED`, do the pre-check below instead of trusting `status`: `status` reflects the last health check and the site session may have expired since (https://www.kernel.sh/docs/auth/connection-lifecycle). The same two calls (`login`, then `follow`) are the pre-check. If the flow reaches `SUCCESS` without asking for anything, go to Step 6.
2. Start the flow once. Save the response to a private file so the URL never enters your context:
   ```bash
   umask 077; F="${TMPDIR:-/tmp}/kernel-login-<id>.json"
   kernel auth connections login <id> -o json > "$F" \
     && jq '{flow_type, flow_expires_at, has_hosted_url: (.hosted_url != null)}' "$F"
   ```
   Only the SDK `login` call ran in the lab (P10); the CLI commands in this skill are from CLI source unless a note says otherwise. Delete the file with `rm -f "$F"` once the hosted page has been opened and the flow has finished.
   Expect `flow_type` `LOGIN` (or `REAUTH`). `login` returns `hosted_url`, `handoff_code`, `flow_type`, `flow_expires_at` (P10).
3. Follow the flow with a filter. Run it in the background if a human may have to act, and do not run anything else against this connection meanwhile:
   ```bash
   kernel auth connections follow <id> -o json \
     | jq --unbuffered -c 'select(.event=="managed_auth_state") | {flow_status, flow_step, error_code}'
   ```
   The stream ends when the flow reaches a terminal state. Heartbeat events are named `sse_heartbeat`; the jq filter drops them (P10). In the lab, with a stored credential, the sequence was `IN_PROGRESS/DISCOVERING` then `SUCCESS/COMPLETED` with no human (P10). (Stream-ends-at-terminal and the `follow` CLI output were not run in the lab: unverified.)
4. Never call `login` again to check progress or to nudge a stuck flow. A second `login` while a flow is live starts a new flow with a different `hosted_url` and cancels the first one (P10). Any URL already given to the user is then superseded.
5. If the flow reaches `flow_step` `AWAITING_INPUT` or `AWAITING_EXTERNAL_ACTION`, a person must act. Open the hosted page for them without printing it:
   ```bash
   F="${TMPDIR:-/tmp}/kernel-login-<id>.json"
   (open "$(jq -r .hosted_url "$F")" 2>/dev/null || xdg-open "$(jq -r .hosted_url "$F")" 2>/dev/null) || echo "no opener available"
   ```
   If that prints `no opener available`, tell the user to run `jq -r .hosted_url <file path>` in their own terminal and open the result. Say plainly: "Finish the login in the page that opened. I will wait here." Do not stop the turn or ask them to reply; keep following the same flow. A hosted session expires after about 20 minutes and waits about 10 minutes for input (https://www.kernel.sh/docs/auth/hosted-ui, untested).
6. If the flow ends `EXPIRED` or `CANCELED`, run `login` once more on the same connection (back to item 2) and open the new page.
7. Programmatic answers: only for non-secret choices. `kernel auth connections submit <id> --choice-id <choice id from fields/choices>` answers the current interaction (CLI source, unverified in the lab: the demo site had no MFA). In the API, submit one `interaction_id` with either `field_values` (keyed by field `id`, never by `ref`) or `selected_choice_id`; never send both. Secrets go through the hosted page, never `--field-value`.
8. Embedding the hosted flow in a React app (Next.js): out of scope here. `login` returns `id` and a one-time `handoff_code` for `<KernelManagedAuth>`; never reuse a `handoff_code` or take `success_url` from client input. See `../kernel/references/logins.md` and https://www.kernel.sh/docs/auth/react.

## Step 5. Confirm the result and branch on failure

Run:
```bash
kernel auth connections get <id> -o json \
  | jq '{status, flow_status, flow_step, error_code, error_message, website_error, can_reauth, can_reauth_reason}'
```
Proceed only when `status` is `AUTHENTICATED` and `flow_status` is `SUCCESS` (P10). Otherwise branch on `error_code` (https://www.kernel.sh/docs/auth/connection-lifecycle; no failure code was reproduced in the lab):

| `error_code` | Do |
|---|---|
| `bot_detected`, `captcha_blocked` | Set an ISP or custom proxy on the connection (`kernel auth connections update <id> --proxy-id <proxy id>`, keep stealth on; create the proxy first, see the `kernel` skill, `../kernel/references/unblock.md`), then `login` once. Do not loop. Residential exit IPs can change between logins; prefer ISP. |
| `account_locked` | Stop. Tell the user to unlock the account on the site. Another `login` may extend the lockout. |
| `credentials_invalid` | Ask the user to correct the linked credential (in the dashboard or an SDK script reading env vars; never as a CLI argument), then `login` once. |
| `totp_code_rejected` | Retry once in a new TOTP window; if it fails again, ask the user to re-enter the secret. |
| `totp_required`, `sms_code_required`, `email_code_required`, `account_choice_required`, `customer_input_required`, `external_action_required` | Needs a person: repeat Step 4 item 5. |
| `rate_limited` | Wait for the site's window, then one new `login`. |
| `website_error` | Usually the site; Kernel retried once. Try later. |
| `unsupported_auth_method` | Passkeys are not supported. The account must switch to a supported sign-in method, for example password plus TOTP instead of a passkey. |

Never retry a failed login in a loop: lockouts get worse with each attempt. If `status` is `NEEDS_AUTH` with no `error_code`, run `login` once on the same connection (Step 4). To see what happened, list recent events only:
```bash
kernel auth connections timeline <id> --per-page 5 -o json \
  | jq '.events[] | {timestamp, type, status, step, error_code}'
```
(`timeline` ran in P10 through the SDK; the CLI JSON shape comes from CLI source and the `kernel-auth` sample skill, unverified.)

## Step 6. Open a NEW browser on the profile

The login ran in a browser Kernel started and you never receive. Do not look for it; do not reuse any task browser that hit the login wall. Create a new one:
```bash
kernel browsers create --profile-name <profile> --start-url https://<domain>/ -o json | jq '{session_id}'
```
Keep only `session_id`; the full response holds the CDP and live view URLs. Check that the session is signed in by looking for something that only a signed-in page shows (a logout link, an account menu), not a flash message (P10). Replace the selector with one that fits the site:
```bash
kernel browsers playwright execute <session_id> 'return { path: new URL(page.url()).pathname, logout_links: await page.locator("a[href=\"/logout\"]").count() }'
```
(`playwright execute <id> [code]` is in CLI source and this CLI form was not run in the lab; the SDK version of the check ran in P10: with the profile `/secure` loaded and had a logout link, without it the site redirected to `/login`.)

- If the page redirects to a login page, go back to Step 4 on the same connection. Do not create a second profile.
- Add `--save-changes` only on exactly one browser per profile; two writers overwrite each other (see the `kernel` skill, `../kernel/references/profiles.md`). Reading does not need it.
- If the task will run in the user's code, give them `profile: { name: '<profile>' }` for `kernel.browsers.create`. Do not hand over the session id of the browser you just made.

When you finish checking, delete the verification browser unless the user asked to keep it:
```bash
kernel browsers delete <session_id>
```

## Step 7. Recovery later (hand this to the user)

Tell the user in one short paragraph:
- Before consequential work (a purchase, a post, a send), call `login` then `follow` on the connection and wait for `SUCCESS`. Do not trust `status` alone.
- If the connection falls to `NEEDS_AUTH`, call `login` again on the same connection and send the person to the new hosted page. Do not delete and recreate it.
- Health checks cost browser time. Disable them on one-shot connections (`kernel auth connections update <id> --no-health-checks`).
- Cleanup for one-shot runs: `kernel auth connections delete <id>`, then `kernel profiles delete <profile>`, only when no real user needs that state. Confirm with the user first; this cannot be undone.

## Step 8. Vault fill path (user present, agent drives)

Do this only when Step 2 chose it. The working code lives in the `kernel` skill, `../kernel/references/logins.md`, section "Fill from Vault" (SDK calls ran in lab P11). Summarize the contract to the user, then help write it:

1. One vault per end user, a credential item with `sensitive: true` for the password. A field with `sensitive: false` (the username) is returned in clear by `get` and `list` (P11).
2. Attach the vault when the browser is created (`vaults: [{ id }]` in the SDK, or `kernel browsers create --vault <id-or-name>`). Attach it only to browsers allowed to use every item.
3. Open the login page first. Call `performOperation` with `type: 'fill'`, the browser id, the exact `page_url` (path, query and fragment must match), and a selector per field. Use `{ maxRetries: 0 }`.
4. `status: 'completed'` means the fields were written, not that anyone is signed in and not submitted (P11). Click submit yourself, then check for a signed-in element.
5. A fill rejected before any write is HTTP 400 with `{ code, message }`: `page_not_found` (page_url mismatch), `element_not_found` (bad selector), `timeout` (P11). Fix the input; do not loop.
6. To keep the signed-in state for later, create the browser with a per-user profile that saves changes, on exactly one browser. The SDK types declare a top-level `profile_save_changes`, while the docs show `profile: { name, save_changes: true }`; check which one your SDK version accepts (untested in the lab).

Credential sources: for 1Password, use a service-account provider with an explicit `path` per user, or Agentic Autofill; never `auto: true` across users. For an existing secrets manager, have the backend copy values into a `provider: "kernel"` item; never give raw values to the agent.

The CLI fill path (`kernel vaults items invoke <vault> <key> fill --spec-file -`) is in CLI source and the `kernel-auth` sample skill but did not run in the lab (unverified). Never type the password into a Playwright `fill()` call, a prompt or a CLI argument.

## Report to the user

End with exactly this, filled in, and nothing that is a secret or a URL:

```
Login: <domain>
Decision: <API/MCP instead | profile reuse | Managed Auth | vault fill> because <one line>
Connection: <id> (profile <profile name>)   status=<AUTHENTICATED|NEEDS_AUTH>   can_reauth=<true|false>
Flow: <LOGIN|REAUTH> result=<SUCCESS|FAILED|EXPIRED|CANCELED>   error_code=<none|code>
Verification: <signed-in element seen on <url path> | redirected to login | not checked>
Use it: kernel.browsers.create({ profile: { name: '<profile>' } })
Health checks: <on|off>, interval <n>s
Left running: <browser ids still alive, or none>
Next step for you: <one line, for example "type the MFA code on the page that opened", or none>
Not verified: <list anything marked unverified that you relied on, or none>
```
If the run stopped early (CLI missing, no auth context, no domain, API or MCP chosen), report the stop reason in the `Decision` line and leave the rest as `n/a`.

> Verified in lab: 2026-10-20. Probes: P10 (Managed Auth through the SDK: create, list, login, follow stream, get, timeline, 409 body, profile browser check), P11 (vault fill through the SDK: sensitive fields, `page_not_found`, `element_not_found`, `timeout`). SDK/CLI versions: see the lab cards. Not tested in the lab: CLI `follow`, `timeline` and `submit`, the CLI 409 output, failure `error_code` values, the CLI vault fill, the React embed, 1Password, and the `playwright execute` check via the CLI.
