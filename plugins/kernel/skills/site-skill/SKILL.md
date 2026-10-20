---
name: site-skill
description: >-
  Turn a browser workflow that already worked on a website with Kernel into a reusable site-specific skill in this project.
disable-model-invocation: true
---

# Turn a working Kernel workflow into a site skill

You are writing a new skill file in the user's project that lets a future agent repeat a workflow on one website with Kernel cloud browsers. Base it only on steps that you or the user ran and saw succeed. Do not invent selectors, URLs or waits.

The argument is the text after the skill name in the user's message (or the line starting `ARGUMENTS:`). It is the site (domain or name) and, optionally, the tasks to capture. If it is missing, ask for the site and which tasks (for example "export invoices") and stop.

Rules for the whole run:
- Never print API keys, `cdp_ws_url`, `webdriver_ws_url`, `browser_live_view_url`, replay URLs, vault collection URLs, or credential values. Mask URLs as `...?jwt=***`. Never write them into the generated skill.
- Never ask the user for a raw password in chat and never put credentials in the skill, `AGENTS.md` or CLAUDE.md. Login goes through a vault or the user's own hands in live view.
- Never hard-code the discovery user's id, profile, vault, or account-specific URL parts in the generated skill; make them runtime inputs.
- Use only the commands in this file. Anything marked "(unverified)" was not run in the lab: run it once yourself and check the result before you document it.
- Do not create browsers, profiles or vaults without telling the user what you create and deleting what you created for discovery (step 7). Never delete a profile or vault that existed before.

## 1. Check the CLI

Run `command -v kernel`. If it prints nothing, print these install commands and stop (do not install anything):

```bash
brew install kernel/tap/kernel
npm i -g @onkernel/cli
```

Run `kernel auth context -o json | jq 'keys'`. If it fails, tell the user to set `KERNEL_API_KEY` in their environment and stop.

## 2. Find what already worked

Before exploring, look for a workflow that already succeeded: the current conversation, scripts in the project that use `@onkernel/sdk`, or notes the user gives you. Reuse its URLs, selectors and waits. Explore live only for the steps that are missing, and only inside what the user authorized on that site. If the user has no working workflow and no authorization to test one, stop and ask.

Decide the controls. Default is the CLI: `kernel browsers playwright execute` for DOM steps and `kernel browsers computer` for OS-level steps. If the user's project drives Kernel from TypeScript instead, the generated skill can use `@onkernel/sdk` with `kernel.browsers.playwright.execute` (HTTP 200 with `success: false` and an `error` field on a thrown snippet; the SDK does not throw; lab P01). Record the choice in the generated skill.

## 3. Prepare a discovery browser

Profiles and vaults must be scoped to site and user: name them `<site>-<user-id>`. Resolve the user id from the user's message or the project; ask if unknown.

Check whether the profile exists before creating anything: `kernel profiles list -o json | jq -r '.[].name'` (unverified for the jq path; read the raw keys first with `jq '.[0]|keys'`). Create only what is absent (unverified; flags from CLI source, not run in the lab):

```bash
kernel profiles create --name "<site>-<user-id>"
kernel vaults create --name "<site>-<user-id>"   # only if the site needs a login
```

Create the browser. Headful is the default and live view needs it (headless create returns no `browser_live_view_url`; lab P01). Computer calls were only checked on a headless browser for API success (lab P07), so prefer headful for them. `--stealth` and `--vault` can only be set at creation. The CLI default `--timeout` is 60 seconds; use more for discovery:

```bash
SESSION=$(kernel browsers create --profile-name "<site>-<user-id>" --save-changes --stealth \
  --vault "<site>-<user-id>" --timeout 600 -o json | jq -r '.session_id')
```

Omit `--vault` and the vault for sites with no login. Flags are from CLI source (`--profile-name`, `--save-changes`, `--stealth`, `--vault`, `--timeout`); the combined command was not run in the lab (unverified). `--save-changes` needs a profile, otherwise the CLI errors.

Profile facts you must respect (lab P09):
- Changes are saved when a session created with `--save-changes` is deleted (`kernel browsers delete`). Closing only the CDP client saves nothing.
- Without `--save-changes` the changes are discarded.
- With two writers in turn, the last one wins. Run one writer per profile.

## 4. Establish login (only if the site needs it)

Check first whether the saved profile is already logged in (the `goto` plus `page.url()` variant is unverified; only `return await page.title()` was run):

```bash
kernel browsers playwright execute "$SESSION" -o json 'await page.goto("<site-url>"); return page.url()'
kernel browsers computer screenshot "$SESSION" --to /tmp/state.png
```

(`playwright execute <id> '<code>' -o json` is lab-confirmed on `return await page.title()` in P20; the screenshot `--to` flag is from P20 too. Read the PNG to judge the state.)

If login is needed, use the vault. Inspect the login form first and write down field names, types and which are sensitive. Create the credential item without values (unverified: the CLI path was not run, only the SDK upsert was; create takes `fields` as an ordered array with `name`; the older object form is wrong for create, CLI source `vaults_credentials.go`):

```bash
kernel vaults credentials create "<site>-<user-id>" <site>-login --spec-file - <<'JSON'
{"description":"<Site Name>","fields":[
 {"name":"username","label":"Username","type":"text","required":true,"sensitive":false},
 {"name":"password","label":"Password","type":"password","required":true,"sensitive":true}]}
JSON
```

Give the returned collection URL to the user to open in their own browser; never open it in the Kernel browser and never log it. Observe readiness with a bounded wait; run it once and repeat only while the status is pending:

```bash
kernel vaults items get "<site>-<user-id>" <site>-login --wait 60 -o json | jq '.state.status'
```

(`--wait` takes 0-60 seconds and only observes; `state.status` `ready` was observed on the SDK side in P11, but the CLI JSON path was not run (unverified), so check the raw JSON once.)

When the item is ready, fill by field name and selector, then submit yourself (`fill` never submits):

```bash
kernel vaults items invoke "<site>-<user-id>" <site>-login fill --spec-file - <<JSON
{"browser_id":"$SESSION","page_url":"<login-url>","fields":[
 {"field":"username","selector":"input[name='username']"},
 {"field":"password","selector":"input[name='password']"}]}
JSON
```

(The CLI invoke path was not run in the lab; the SDK fill was, P11.) Accept only a result with `status` `completed`. On `failed` or `unknown`, stop and check the page; do not loop. Never print or screenshot filled values.

If bot detection blocks login on a browser created without `--stealth`, delete it and recreate with `--stealth`. If it stays blocked, ask the user to log in by hand through live view: run `kernel browsers view "$SESSION" -o json` and give the `browser_live_view_url` to the user directly (never paste it into files or logs; mask it as `...?jwt=***` in anything you write). Then verify the logged-in state yourself.

## 5. Explore and verify each task

Each task must be runnable on its own (shared setup plus login prerequisites). For each task:

1. Go to the starting state and look at the page.
2. Do the task and confirm the real state change after each action.
3. Record: inputs, start state, direct URLs, ordered commands, the wait condition, the success check, and every failure or workaround you hit.
4. Test uncertain steps alone, then run the whole sequence with the exact commands you will document.

DOM rules (use `return` for results; globals persist across calls on the same named executor but not across executors (lab P03), so do not rely on variables between calls):
- Prefer role, label or text locators; CSS or XPath only if those fail.
- Wait for a URL, visible element or value that proves completion, with a short explicit timeout (for example 5000 ms). Do not use `networkidle` or fixed sleeps as the success condition.
- Use `page.frameLocator(...)` for iframes, cross-origin ones too (unverified; upstream reference only, not run in the lab).
- A thrown snippet returns `success: false` with `error`; check `.success` in the `-o json` output before trusting `.result`.

Computer fallback: if Playwright fails 2-3 times on a step (error, timeout, or "success" with no page change), use OS-level controls for that step only, after checking the step did not already succeed:

```bash
kernel browsers computer screenshot "$SESSION" --to /tmp/state.png
kernel browsers computer click-mouse "$SESSION" --x 250 --y 60
kernel browsers computer type "$SESSION" --text "some text"
kernel browsers computer press-key "$SESSION" --key Return
kernel browsers computer drag-mouse "$SESSION" --point 100,200 --point 250,200 --point 400,200 --button left
```

(Flags are from CLI source; only `screenshot --to` was run in the lab.) Read coordinates from a screenshot and record the viewport size next to them. Give drag several waypoints so pointer handlers see movement.

## 6. Write the skill

Put it at `<skills-dir>/<primary-domain>/SKILL.md`. Find the project's skills directory from its agent instructions (for example `.claude/skills/`); if you cannot tell, ask. If a file exists there, show the user a diff and ask before overwriting.

Fill this template only with verified details. Keep user ids, vault, item and profile names as runtime inputs.

````markdown
---
name: <descriptive-name>
description: <What it does on <site> and when to use it.>
---

# <Site Name>

## Setup
<CLI, auth, runtime inputs (user id), tested browser create command. Link to the project's Kernel skill for generic CLI help.>

## Login
<How to check the saved profile; vault-backed login sequence; manual live-view fallback.>

## <Task Name>
<Inputs and starting state.>

```bash
# Tested commands, with waits and the success check.
```
<Expected outcome and recovery for observed failures. Repeat per task.>

## Cleanup
<Close any attached harness, then: kernel browsers delete "$SESSION">

## Notes
<Quirks, workarounds, coordinates and viewport size if computer controls are used.>
````

Include the discovered credential field schema (names, types, sensitive flags), the field-to-selector map, the login sequence, waits and success checks. Do not include values.

## 7. Clean up

Delete the discovery browser; deletion is what saves the profile:

```bash
kernel browsers delete "$SESSION"
```

(`kernel browsers delete <id-or-name>` takes no `--yes` flag in CLI source; the SDK equivalent is `kernel.browsers.deleteByID(id)`, lab P01. There is no `kernel.browsers.delete`.) Then confirm: `kernel browsers list --status active -o json | jq length`. After delete, a plain `kernel browsers get` returns not found; use `--include-deleted` to read the record (lab P01, P19).

Delete the vault, credential item or profile only if you created them in this run for throwaway discovery and the user agrees. A profile or vault the user will reuse stays.

## Report to the user

Reply in exactly this shape:

```
Site skill: <absolute path of the SKILL.md>
Tasks captured: <list>
Controls: <playwright execute | computer | SDK>
Login: <none | vault | manual live view> (profile <name>, vault <name>)
Verified: <steps run end to end and what proved success>
Not verified: <steps copied from earlier work, or marked unverified>
Cleaned up: <browsers deleted; resources left in place and why>
Open questions: <anything the user must decide>
```
