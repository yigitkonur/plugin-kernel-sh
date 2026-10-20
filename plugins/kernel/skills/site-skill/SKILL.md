---
name: site-skill
description: >-
  Turn a browser workflow that already worked on a website with Kernel into a reusable site-specific skill in this project.
argument-hint: "[domain]"
disable-model-invocation: true
---
<!-- Derived in part from the official Kernel skill `create-agent-site-skill` (https://github.com/kernel/skills, MIT, Copyright (c) 2025 Kernel). License text: THIRD_PARTY_NOTICES.md at the plugin root. -->

# Turn a working Kernel workflow into a site skill

You are writing a new skill file in the user's project that lets a future agent repeat a workflow on one website with Kernel cloud browsers. Base it only on steps that you or the user ran and saw succeed. Do not invent selectors, URLs or waits. Generic CLI help: `../kernel/references/cli.md`, logins: `../kernel/references/logins.md`.

The argument is the site (domain or name) and optionally the tasks to capture. If it is missing, ask for the site and tasks (for example "export invoices") and stop.

Rules for the whole run:
- Never print API keys, `cdp_ws_url`, `webdriver_ws_url`, `browser_live_view_url`, replay URLs or credential values. The only permitted disclosure is ONE message to the user containing the collection or live-view URL. Never repeat it, log it, write it to a file or include it in the report.
- Never ask the user for a raw password in chat and never put credentials in the skill, `AGENTS.md` or CLAUDE.md. Login goes through a vault or the user's own hands in live view (a throwaway or demo account handed to you: see step 4).
- Never hard-code the user's id, profile, vault, browser id or account-specific URL parts in the generated skill; make them runtime inputs.
- Use only the commands in this file. Run anything marked "(unverified)" once and check the result before you document it.
- Stop and ask the user before any CAPTCHA, 2FA or other human check, any payment or purchase, and any destructive site action (delete, cancel, send, submit for real).
- Shell state does not persist between Bash calls: use literal ids and names in every command.
- On ANY stop after a browser is created, run step 7 (clean up) first, then stop.

## 1. Check the CLI

Run `command -v kernel` and `command -v jq`. If either prints nothing, say what is missing, print `brew install kernel/tap/kernel` (or `npm i -g @onkernel/cli`) and stop; install nothing. Run `kernel auth context -o json >/dev/null`; if it exits non-zero, tell the user to set `KERNEL_API_KEY` and stop. (The CLI writes errors to stderr and nothing to stdout, so never pipe a `kernel` command straight into `jq`: a failure would look like empty success. Capture first: `out=$(kernel ... -o json) && jq '...' <<<"$out" || echo "could not run: <what>"`.)

## 2. Find what already worked

Look for a workflow that already succeeded: the conversation, project scripts that use `@onkernel/sdk`, or the user's notes. Reuse its URLs, selectors and waits. Explore live only for missing steps, and only inside what the user authorized. If there is no working workflow and no authorization to test one, stop and ask.

Decide the controls. Default is the CLI: `kernel browsers playwright execute` for DOM steps and `kernel browsers computer` for OS-level steps. If the project uses TypeScript, the skill can use `@onkernel/sdk` with `kernel.browsers.playwright.execute` (a thrown snippet returns `success: false` with `error`; the SDK does not throw). Record the choice in the skill.

## 3. Get consent, then prepare a discovery browser

Name profiles and vaults `<site>-<user-id>`; resolve the user id from the message or project, ask if unknown. Skip this (and the profile and vault) when the flow needs neither, for example a public practice site with no login. Check what exists first with the exact-name filter (the list returns 20 per page, so an unfiltered list can miss a profile): `out=$(kernel profiles list --name "<site>-<user-id>" -o json) && jq -r '.[].name' <<<"$out" || echo "could not check: profiles list"` (the `.name` path is unverified; if it prints nothing but the output is not `[]`, read the keys with `jq '.[0]|keys'`). On `could not check`, stop and tell the user: do not treat it as "absent".

Then list for the user every profile, vault, credential item and browser you will create or write to, marking which already exist. WAIT for a yes before creating anything. In a non-interactive run the user's explicit request to build and run is the consent for tagged browsers only; anything that creates a profile, vault or credential still needs a yes. Never use `--save-changes` on a profile that existed before this run.

After the yes, create only what is absent (unverified; flags from CLI source):

```bash
kernel profiles create --name "<site>-<user-id>"
kernel vaults create --name "<site>-<user-id>"   # only if the site needs a login
```

Pick one unique run tag now, for example `site-skill-<site>-<6 random letters or digits>`, and write its literal value in every browser command of this run (steps 3, 7 and 8). Make one private scratch directory for screenshots (`umask 077; mktemp -d`), print it, and use that literal path as `<S>` wherever a screenshot is saved (a fixed path in the shared temp folder can collide or be a symlink). Create the browser. Headful is the default and live view needs it (headless returns no `browser_live_view_url`). Prefer headful for computer calls. `--stealth` and `--vault` can only be set at creation. The CLI default `--timeout` is 60 seconds; use more for discovery:

```bash
out=$(kernel browsers create --profile-name "<site>-<user-id>" --tag "run=<run-tag>" --stealth \
  --vault "<site>-<user-id>" --timeout 600 -o json) && jq -r '.session_id' <<<"$out" || echo "could not run: browsers create"
```

Add `--save-changes` only if you created that profile in this run (step 3 `profiles create`); for a profile that existed before, leave the flag out so deleting the browser cannot overwrite it. Print the id once; if it is empty or the command printed `could not run`, stop. Use that literal id wherever this file says `<browser-id>`. Omit `--vault` for sites with no login. The combined command is unverified; `--save-changes` needs a profile. Profile facts: changes are saved only when a session created with `--save-changes` is deleted (closing the CDP client saves nothing); without the flag they are discarded; with two writers the last wins, so run one writer per profile.

## 4. Establish login (only if the site needs it)

Check first whether the saved profile is already logged in (the `goto` plus `page.url()` variant is unverified; only `return await page.title()` was run):

```bash
kernel browsers playwright execute <browser-id> -o json 'await page.goto("<site-url>"); return page.url()'
kernel browsers computer screenshot <browser-id> --to <S>/state.png
```

Read the PNG to judge the state. If login is needed, use the vault. Exception: a throwaway or demo account whose credentials must reach a script and no vault is wanted. Follow the secrets policy in `../kernel/SKILL.md`: a password never goes in project code or on a command line, so use the SDK's `playwright.execute` (the CLI form puts the code on a command line), read the secret from the environment at run time and put it into the `code` string with `JSON.stringify` (it travels in the request body); never log that string, never commit it, never write values into the generated skill. A password pasted in chat is already in the transcript: keep it out of files, shell history and later commands. Inspect the login form and note field names, types and sensitivity. Create the credential item without values (unverified CLI path; `fields` is an ordered array with `name`):

```bash
kernel vaults credentials create "<site>-<user-id>" "<site>-login" --spec-file - <<'JSON'
{"description":"<Site Name>","fields":[
 {"name":"username","label":"Username","type":"text","required":true,"sensitive":false},
 {"name":"password","label":"Password","type":"password","required":true,"sensitive":true}]}
JSON
```

Give the returned collection URL to the user in ONE message to open in their own browser, never in the Kernel browser. Check readiness; repeat only while the status is pending:

```bash
out=$(kernel vaults items get "<site>-<user-id>" "<site>-login" --wait 60 -o json) && jq '.state.status' <<<"$out" || echo "could not run: vaults items get"
```

(`--wait` takes 0-60 seconds and only observes; the CLI JSON path is unverified, check the keys once with `jq 'keys' <<<"$out"`.) When the item is ready, fill by field name and selector, then submit yourself (`fill` never submits):

```bash
kernel vaults items invoke "<site>-<user-id>" "<site>-login" fill --spec-file - <<'JSON'
{"browser_id":"<browser-id>","page_url":"<login-url>","fields":[
 {"field":"username","selector":"input[name='username']"},
 {"field":"password","selector":"input[name='password']"}]}
JSON
```

Accept only `status` `completed`; on `failed` or `unknown`, stop and check the page, do not loop. Never print or screenshot filled values. If bot detection blocks login without `--stealth`, recreate the browser with it. If still blocked, ask the user to log in by hand: run `out=$(kernel browsers view "<browser-id>" -o json) && jq -r '.browser_live_view_url // empty' <<<"$out"` (capture first so a CLI failure is not hidden by the pipe, and never without the jq; the JSON key is unverified, so if it prints nothing or the command fails tell the user to run `kernel browsers view "<browser-id>"` themselves) and give that URL to the user in ONE message, then verify the logged-in state yourself.

## 5. Explore and verify each task

Each task must be runnable on its own (shared setup plus login prerequisites). For each task:
Go to the starting state and look at the page; do the task and confirm the real state change after each action; record inputs, start state, direct URLs, ordered commands, the wait condition, the success check and every failure or workaround; test uncertain steps alone, then run the whole sequence with the exact commands you will document.

DOM rules (use `return` for results; globals persist across calls on the same named executor but not across executors, so do not rely on variables between calls):
- Prefer role, label or text locators; CSS or XPath only if those fail.
- Wait for a URL, visible element or value that proves completion, with a short timeout (for example 5000 ms), not `networkidle` or fixed sleeps.
- Use `page.frameLocator(...)` for iframes (unverified). Check `.success` in the `-o json` output before trusting `.result`.

Computer fallback: if Playwright fails 2-3 times on a step (error, timeout, or no page change), use OS-level controls for that step only, after checking the step did not already succeed:

```bash
kernel browsers computer screenshot <browser-id> --to <S>/state.png
kernel browsers computer click-mouse <browser-id> --x 250 --y 60
kernel browsers computer type <browser-id> --text "some text"
kernel browsers computer press-key <browser-id> --key Return
```

(Only `screenshot --to` was run; other flags are from CLI source.) Read coordinates from a screenshot and record the viewport size next to them. `drag-mouse` takes several `--point x,y` waypoints.

## 6. Write the skill

Draft at `<skills-dir>/<slug>/SKILL.md`; `<slug>` is the primary domain with hyphens (`example-com`, not `example.com`) and equals the `name:` field. Find the skills directory from the project's agent instructions (for example `.claude/skills/`) or ask. If the file exists, show a diff and ask before overwriting.

Fill this template only with verified details; user ids, vault, item and profile names stay runtime inputs.
````markdown
---
name: <slug>
description: <What it does on <site> and when to use it.>
---

# <Site Name>

## Setup
<CLI, auth, runtime inputs (user id), tested browser create command.>

## Login
<Saved-profile check; vault-backed login sequence; live-view fallback.>

## <Task Name>
<Inputs and starting state.>

```bash
# Tested commands, with waits and the success check.
```
<Expected outcome and recovery. Repeat per task.>

## Cleanup
<Close any attached harness, delete the browser, remove the scratch screenshots.>

## Notes
<Quirks, workarounds, coordinates and viewport size.>
````

Include the credential field schema (names, types, sensitive flags), field-to-selector map, login sequence, waits and success checks; no values.

Leak check before the file is final. Run this on the draft and fix every hit:

```bash
grep -c -E 'sk_[0-9a-fA-F]{8}-' <file>   # a count only: a key must never be echoed; any count above 0 is a hit to fix
grep -nEi 'jwt=|handoff_code=|wss?://|onkernel\.com/browser/(live|replay|cdp)|token=|session=|api[_-]?key|password|@[a-z0-9.-]+\.[a-z]{2,}' <file>
```

Strip query strings from documented URLs and remove any recorded ids. `password` hits are fine only as a field name or type, never a value. Re-run until only those remain.

## 7. Clean up

Delete the browser (this saves the profile if created with `--save-changes`) and the scratch directory; `<run-tag>` is the exact value from step 3:

```bash
kernel browsers delete <browser-id>
rm -rf <S>
out=$(kernel browsers list --status active --tag "run=<run-tag>" --limit 100 -o json) && jq length <<<"$out" || echo "could not check: browsers list"   # expect 0; the account may hold other people's browsers
```

Delete a vault, item or profile only if you created it in this run for throwaway discovery and the user agrees; never one that existed before.

## 8. Cold run

Create a fresh browser (the step 3 command with the same `--tag "run=<run-tag>"` and without `--save-changes`), follow the new skill's steps once exactly as written and check each success condition. Fix the skill where it fails and re-run the leak check. Then run step 7 for this browser. No task counts as verified without this run.

## Report to the user

Reply in exactly this shape (no URLs, no ids):

```
Site skill: <absolute path>; Tasks captured: <list>
Controls: <playwright execute | computer | SDK>; Login: <none | vault | manual live view> (profile, vault names)
Verified: <steps run end to end, cold run result, what proved success>
Not verified: <copied or unverified steps>
Cleaned up: <what was deleted; what was left and why>
Open questions: <decisions for the user>
```

Verified 2026-10-20, SDK 0.128.0 / CLI 0.49.0; evidence ledger: https://github.com/yigitkonur/plugin-kernel-sh/blob/main/verified-facts.md
