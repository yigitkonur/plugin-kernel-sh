---
name: login
description: >-
  Get an agent a logged-in Kernel browser for a website, after confirming the user wants browser auth: first decide whether browser auth is needed at all (API or MCP first), then choose Managed Auth (hosted login saved to a profile) or a vault fill, and relaunch a logged-in browser. Use when code or a task needs an authenticated session on a site: log in, reuse a login, credentials, SSO or MFA.
argument-hint: "<domain>"
---
<!-- Derived in part from the official Kernel skill `kernel-auth` (https://github.com/kernel/skills, MIT, Copyright (c) 2025 Kernel). License text: THIRD_PARTY_NOTICES.md at the plugin root. -->

# /kernel:login

Goal: leave the user with a Kernel browser already signed in to one site, a profile name and connection id they can reuse, and no secret in the transcript.

The argument is the text after the skill name (or the line starting `ARGUMENTS:`): a domain such as `example.com`. If missing, ask and stop. Use the bare domain (no scheme, no path) for `<domain>`. Before ANY command, lower-case it yourself and check it is a hostname: at most 253 characters and `^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$`. If it does not match, say so and stop; never put the raw argument in a command.

Every value you place in a command (domain, profile name, credential name, project, connection id, session id, proxy id, choice id) must be validated first: names and ids against `^[A-Za-z0-9._-]{1,64}$` (a domain against the hostname grammar above). If one does not match, say so and stop. Double quotes alone do not stop injection when a value contains `$(...)`, a backtick or a quote. At the top of every Bash call (shell state does not persist) assign each validated value to a variable as a single-quoted literal, for example `domain='example.com'; profile='example-com-main'; id='abc123'`, and use only `"$domain"`, `"$profile"`, `"$cred"`, `"$project"`, `"$id"`, `"$sid"`, `"$proxy_id"`, `"$choice"` in the commands below.

Rules for the whole run:
- Never print, paste or log an API key, a `hosted_url`, a `handoff_code`, a `cdp_ws_url`, a live view URL or a replay URL. They are credentials. Keep them out of your context with `jq` projections and files written under `umask 077`.
- Never pass a password, TOTP secret or one-time code as a CLI argument (`--value`, `--field-value`), and never use `kernel credentials create --value password=...` (its own help shows that form). A human types secrets into the hosted page, or the shipped script stores them from environment variables (Step 3 item 4).
- Never dump `follow` or `timeline` streams; use `jq` filters and `--limit`/`--type`.
- Never delete the connection or profile to recover. Recovery is another `login` on the same connection.
- Shell state does not persist between Bash calls: re-assign the validated variables at the top of each call.

## Step 1. Preflight
1. `command -v kernel`. If empty, tell the user to run `brew install kernel/tap/kernel` (or `npm i -g @onkernel/cli`) and stop. Install nothing yourself.
2. `kernel auth context -o json | jq 'keys'`. If it fails, tell the user to run `kernel login` or set `KERNEL_API_KEY`, then stop.
3. If the user named a Kernel project, pass `--project "$project"` on every `kernel` command below, and run the credential script of Step 3 item 4 with `KERNEL_PROJECT="$project"` set for that one invocation (the script reads that variable, not `--project`; without it the credential lands in the default project).

## Step 2. Is browser auth needed, and which path
Docs: "If the task can be done through an API or an MCP server, use that instead." (https://www.kernel.sh/docs/overview/why-kernel)

1. A URL is not proof a browser is needed. If an API, CLI or MCP server covers the operation, or the pages are public, say so and stop.
2. If a previous run saved the state you need, a profile alone is enough: go to Step 5.
3. Otherwise pick one path, tell the user which and why:

| Situation | Path |
|---|---|
| Nobody watches the run, it recurs, or the site uses SSO or MFA, and a person can open the hosted page | Managed Auth (Steps 3 to 6) |
| Nobody will be at the hosted page and you hold the user's credentials | Managed Auth with a stored Kernel credential (Step 3 item 4); without one the flow waits for a person and fails `awaiting_input_timeout` after 10 minutes |
| The user is present and the agent drives navigation, submit and recovery (a login can appear mid-task) | Vault fill: see "Fill from Vault" in `../kernel/references/logins.md`; the steps below do not apply |

Never mix both on one site in one run.

## Step 3. Reuse or create the connection
A connection ties one domain to one profile; a profile holds at most one connection per domain.

1. Look for an existing one:
   ```bash
   kernel auth connections list --domain "$domain" -o json \
     | jq '[.[] | {id, domain, profile_name, status, can_reauth, can_reauth_reason}]'
   ```
2. If one matches the account the user means, reuse its `id` and `profile_name`. If several match and you cannot tell them apart, ask which profile; do not guess.
3. If none matches, choose a stable profile name (one per end user or account). A domain-only request does not name the profile: use `<domain-slug>-main` (dots to dashes, for example `example-com-main`) only when the login belongs to the single person asking. If the profile could serve several users or accounts, ask for an opaque user or account id (lowercase letters, digits, dashes) and use `<domain-slug>-<opaque-id>`; never share one domain-wide profile across people. For a NEW connection and profile name, state what you will create (path, profile name, domain) and proceed: creation costs nothing until used and health checks are off. Wait for a yes only when a connection or profile for that domain already exists (reuse or new), before deleting anything the user did not ask you to clean up, or before `--save-changes` on an existing profile.
4. Credentials for an unattended login. With a stored Kernel credential Managed Auth logs in with no person present (verified live: `AUTHENTICATED` about 45 s after `login`). Without one it waits for a person to type on the hosted page and ends `FAILED`, `error_code` `awaiting_input_timeout`, after 10 minutes. So when you hold the user's credentials and nobody will be at the page, store a credential first with the shipped script. `${CLAUDE_SKILL_DIR}` is the folder of this skill; if it is empty (the skill was read as a plain file), the script is at `<plugin>/skills/login/scripts/create-credential.mjs`:
   ```bash
   node "${CLAUDE_SKILL_DIR}/scripts/create-credential.mjs" "$cred" "$domain"   # with a project: KERNEL_PROJECT="$project" node ...
   ```
   It reads `SITE_USER`, `SITE_PASSWORD`, optional `SITE_TOTP_SECRET` and `KERNEL_API_KEY` from the environment and prints only `id`, `name`, `domain` and `has_totp_secret`. Exit 2 means a variable is missing (a Bash call may not see `KERNEL_API_KEY`: ask the user to export it before launching Claude Code, or put it in the env file); exit 1 is an HTTP error (409: the name exists, so reuse it only if it is for this domain, else pick another name). Never use an inline `SITE_PASSWORD=... node` prefix (it lands in shell history and the transcript). Pick how the secrets reach the script by the user's situation:
   1. The user exported the variables in the shell that launched Claude Code: run the command above as is.
   2. The user keeps them in a gitignored `.env`: `node --env-file=.env "${CLAUDE_SKILL_DIR}/scripts/create-credential.mjs" "$cred" "$domain"`.
   3. The user pasted the password into the chat: it is already in the transcript; the goal is to keep it out of files, shell history and later commands. Prefer asking them to export it or put it in `.env` (options 1 and 2). Otherwise run `umask 077; mktemp -d`, write `<dir>/env` with the Write tool (file content, not a shell command or heredoc), run the script with `--env-file=<dir>/env` (that file holds only the site variables: `KERNEL_API_KEY` must already be in the environment, or pass a second `--env-file=.env` that holds it), then `rm -rf <dir>`. Never repeat the password in any command, and tell the user to rotate it if it is real.

   Email, SMS and push codes still need a person even with a stored credential.
5. Create the connection. Pass `--no-health-checks` unless the user asked for unattended reuse: health checks and reauths each start a billed browser session (https://www.kernel.sh/docs/auth/faq). Run exactly one of these two commands. Without a stored credential:
   ```bash
   kernel auth connections create --domain "$domain" --profile-name "$profile" --no-health-checks -o json \
     | jq '{id, status, can_reauth, can_reauth_reason, health_checks}'
   ```
   With the credential you stored in item 4:
   ```bash
   kernel auth connections create --domain "$domain" --profile-name "$profile" --credential-name "$cred" --no-health-checks -o json \
     | jq '{id, status, can_reauth, can_reauth_reason, health_checks}'
   ```
   A new connection starts `NEEDS_AUTH`, `can_reauth: false`, reason `no_prior_successful_login`. That is normal. `connections create` also creates the profile.
6. On HTTP 409 (CLI output not run) the domain and profile already have a connection. Run `kernel auth connections list --domain "$domain" --profile-name "$profile" -o json` and reuse the exact match (the 409 body also carries `existing_id`).
7. Options, only when needed:
   - Unattended reuse: drop `--no-health-checks`; the lowest `--health-check-interval` depends on the plan, so read the 400 message instead of guessing.
   - TOTP authenticator: set `SITE_TOTP_SECRET` for the script (see `../kernel/references/logins.md`, "MFA"). Email, SMS and push codes need a human every time.
   - Custom login page or extra SSO hosts: `--login-url`, `--allowed-domain` (repeat per host).

## Step 4. Log in
1. If `status` is `AUTHENTICATED`, do not start a flow: go straight to Step 5 and verify in a fresh browser. Run `login` only if that browser lands on a login page.
2. Start the flow once. Save the response privately so the URL never enters your context:
   ```bash
   umask 077; D=$(mktemp -d "${TMPDIR:-/tmp}/kernel-login.XXXXXX") || exit 1
   trap 'rm -rf "$D"' INT TERM HUP
   kernel auth connections login "$id" -o json > "$D/login.json" \
     && jq '{flow_type, flow_expires_at, has_hosted_url: (.hosted_url != null)}' "$D/login.json" \
     || { rm -rf "$D"; exit 1; }
   echo "private dir: $D"
   ```
   `mktemp -d` makes a directory only you can enter, so no one can pre-create the file or a symlink. The trap removes it if this call is interrupted; on success it stays for the next calls, so use the printed path literally (it is not a secret) and remove it in item 8.
   Never call `login` again to check progress or nudge a stuck flow: it starts a new flow with a different `hosted_url` and cancels the first. That is also the way to end a pending flow without deleting the connection (the previous flow shows `CANCELED` in the timeline); otherwise wait for it to expire.
3. `follow` can block about 20 minutes but the Bash tool stops at 10. Run it in the background (`run_in_background`), writing to a private file. Do not use `timeout`: stock macOS does not have it; stop the background task yourself instead.
   ```bash
   umask 077; kernel auth connections follow "$id" -o json \
     | jq --unbuffered -c 'select(.event=="managed_auth_state") | {flow_status, flow_step, error_code}' \
     > "<private dir>/follow.log"
   ```
   Poll every ~15 s (`sleep 15`) with the Step 5 `get` command until `flow_status` is terminal (`SUCCESS`, `FAILED`, `EXPIRED`, `CANCELED`). The hosted flow waits 10 minutes for input, so poll up to about 11 minutes, not less. Stop the background task when it is terminal or after about 11 minutes, whichever comes first. Run nothing else that changes this connection meanwhile.
4. If `flow_step` is `AWAITING_INPUT` or `AWAITING_EXTERNAL_ACTION`, a person must act.
   - User present: do not run `open` or `xdg-open` (the URL would become a process argument). Prefer to tell the user to run `jq -r .hosted_url "<private dir>/login.json"` in their own terminal and open the result. Only if they cannot, read it once (`jq -r .hosted_url "<private dir>/login.json"`) and give it to that user in one chat message; never repeat it, log it or write it to a file. Say "Finish the login in the page you opened; I will wait here", and keep polling the same flow.
   - User not present: do not open anything. If you hold the user's credentials, store a credential (Step 3 item 4) and run `login` once on the same connection; otherwise report `AWAITING_INPUT` and stop.
   - If the flow ends `awaiting_input_timeout`, report it (it needs a person or a stored credential) and stop; do not retry with the same setup (a second `login` times out the same way).
5. If the flow ends `EXPIRED` or `CANCELED` (not `awaiting_input_timeout`), allow exactly ONE more `login` on the same connection (back to item 2). If it ends that way again, stop and report.
6. Non-secret choices only: `kernel auth connections submit "$id" --choice-id "$choice"` (untested). Secrets go through the hosted page.
7. React embed: out of scope; see `../kernel/references/logins.md`, section "React embed".
8. When the flow is finished, `rm -rf "<private dir>"`.

## Step 5. Confirm, branch on failure, then verify in a fresh browser
```bash
kernel auth connections get "$id" -o json \
  | jq '{status, flow_status, flow_step, error_code, error_message, website_error, can_reauth, can_reauth_reason}'
```
Proceed to the browser check only when `status` is `AUTHENTICATED` and, if a flow ran, `flow_status` is `SUCCESS`. Otherwise branch on `error_code` (https://www.kernel.sh/docs/auth/connection-lifecycle; only `awaiting_input_timeout` was seen live, the rest are untested):

| `error_code` | Do |
|---|---|
| `bot_detected`, `captcha_blocked` | Set an ISP or custom proxy on the connection (`kernel auth connections update "$id" --proxy-id "$proxy_id"`; see `../kernel/references/unblock.md`), then `login` once. Do not loop. |
| `account_locked` | Stop. The user unlocks the account on the site; another `login` may extend the lockout. |
| `credentials_invalid` | Ask the user to fix the linked credential (dashboard or env-reading SDK script), then `login` once. |
| `totp_code_rejected` | Retry once in a new TOTP window; if it fails again, ask the user to re-enter the secret. |
| `totp_required`, `sms_code_required`, `email_code_required`, `account_choice_required`, `customer_input_required`, `external_action_required` | Needs a person: Step 4 item 4. |
| `rate_limited` | Wait for the site's window, then one new `login`. |
| `website_error` | Usually the site; Kernel retried once. Try later. |
| `unsupported_auth_method` | Passkeys are unsupported; the account must use password plus TOTP. |
| `awaiting_input_timeout` | Nobody typed on the hosted page within 10 minutes. Store a credential (Step 3 item 4) or get a person to the page of a fresh `login`. Do not loop. |

Never loop on a failed login. If `status` is `NEEDS_AUTH` with no `error_code`, run `login` once on the same connection. To see what happened: `kernel auth connections timeline "$id" --per-page 5 -o json | jq '.events[] | {timestamp, type, status, step, error_code}'`.

The login ran in a browser Kernel started and you never receive. Do not reuse any task browser that hit a login wall. Create a new one on the profile:
```bash
kernel browsers create --profile-name "$profile" --start-url "https://$domain/" --tag run=login-check -t 240 -o json | jq '{session_id}'
```
Keep only `session_id`. Check for a signed-in page, not a flash message:
```bash
kernel browsers playwright execute "$sid" 'return { path: new URL(page.url()).pathname, logout_links: await page.getByRole("link",{name:/log ?out|sign ?out/i}).count() }'
```
Signed in means `logout_links` is above 0 and the URL path is not the login path.

- If it lands on a login page, run Step 4 on the same connection; do not create a second profile.
- Add `--save-changes` only on exactly one browser per profile: two writers overwrite each other (`../kernel/references/profiles.md`). Reading does not need it.
- For the user's code, give `profile: { name: '<profile>' }` for `kernel.browsers.create`, not the session id of this browser.
- Delete the verification browser unless the user asked to keep it: `kernel browsers delete "$sid"`.
- A browser is ephemeral (it ends at its `timeout_seconds`), so "a logged-in browser I can keep" means handing over the profile name, the launch one-liner `kernel browsers create --profile-name "<profile>"` (SDK: `profile: { name }`) and the connection id. Keep a verification browser alive only if the user asks, with an explicit `--timeout <seconds>`, and report its id and expiry under `Left running`.

## Step 6. Recovery later (tell the user, one short paragraph)
- Before consequential work (purchase, post, send), verify in a fresh profile browser; run `login` and wait for `SUCCESS` if it lands on a login page. `status` alone can be stale.
- If the connection falls to `NEEDS_AUTH`, `login` again on the same connection and send the person to the new hosted page. Do not delete and recreate it.
- Health checks cost browser time; off on one-shot connections (`kernel auth connections update "$id" --no-health-checks`).
- Cleanup cannot be undone. Delete what this run created when the user asked for cleanup or a throwaway test; otherwise ask first. Never delete a connection, profile or credential the user wants to keep, or one that existed before this run. Commands: `kernel auth connections delete "$id" --yes`, then `kernel profiles delete "$profile" --yes`, and `kernel credentials delete "$cred" -y` for a credential you created. Without the flag they fail when stdin is not a terminal.

## Report to the user
End with exactly this, filled in, with no secret or URL:

```
Login: <domain>
Decision: <API/MCP instead | profile reuse | Managed Auth | vault fill> because <one line>
Connection: <id> (profile <profile name>)   status=<AUTHENTICATED|NEEDS_AUTH>   can_reauth=<true|false>
Flow: <LOGIN|REAUTH> result=<SUCCESS|FAILED|EXPIRED|CANCELED|AWAITING_INPUT>   error_code=<none|code>
Verification: <signed-in element seen on <url path> | redirected to login | not checked>
Use it: kernel browsers create --profile-name "<profile>"   (SDK: kernel.browsers.create({ profile: { name: '<profile>' } }))
Health checks: <on|off>, interval <n>s
Left running: <browser ids still alive, or none>
Next step for you: <one line, for example "type the MFA code on the page that opened", or none>
Not verified: <anything unverified you relied on, or none>
```
If the run stopped early, put the stop reason in `Decision` and `n/a` elsewhere.

Verified live 2026-10-20 (Hobbyist plan); types re-checked on @onkernel/sdk 0.128.0. Evidence ledger: https://github.com/yigitkonur/plugin-kernel-sh/blob/main/verified-facts.md
