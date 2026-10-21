---
name: site-skill
description: >-
  Turn a browser workflow that already worked on a website with Kernel cloud browsers into a reusable site-specific skill: which profile to load, which tags and timeout, the Playwright snippets to run, how to verify signed-in, and cleanup.
argument-hint: "[domain]"
disable-model-invocation: true
---
<!-- Derived in part from the official Kernel skill `create-agent-site-skill` (https://github.com/kernel/skills, MIT, Copyright (c) 2025 Kernel). License text: THIRD_PARTY_NOTICES.md at the plugin root. -->

# Turn a working Kernel workflow into a site skill

You are writing a new skill file that lets a future agent repeat a workflow on one website with Kernel cloud browsers, driven through the Kernel MCP tools. Base it only on steps that you or the user ran and saw succeed. Do not invent selectors, URLs or waits. Driving surfaces and tool notes: `../browse/references/tools.md`; profiles: `../browse/references/profiles.md`; logins: `/kernel-browser:login`.

The argument is the site (domain or name) and optionally the tasks to capture. If it is missing, ask for the site and tasks (for example "export invoices") and stop.

Rules for the whole run:
- Never print API keys, `cdp_ws_url`, `webdriver_ws_url`, `browser_live_view_url`, replay URLs, hosted-login URLs, cookie values or credential values. The only permitted disclosure is ONE message to the user containing a live-view or hosted-login URL when a human must act (see step 4). Never repeat it, log it, write it to a file or include it in the report. See `../browse/references/safety.md`.
- Never ask the user for a raw password in chat and never put credentials in the skill, `AGENTS.md` or CLAUDE.md. Login goes through `/kernel-browser:login` (hosted login or a Managed Auth connection) or the user's own hands in live view.
- Never hard-code the user's id, profile, connection, browser id or account-specific URL parts in the generated skill; make them runtime inputs.
- Use only the tools and calls named in this file. Run anything marked "(unverified)" once and check the result before you document it.
- Stop and ask the user before any CAPTCHA, 2FA or other human check, any payment or purchase, and any destructive site action (delete, cancel, send, submit for real).
- Every MCP call takes a one-line `context` string (why you call).
- Every browser you create needs `tags: {cc_session: "<session id the hook tells you>"}` and an explicit `timeout_seconds` (the create hook denies it otherwise). Pick one run tag too, for example `site_skill: "<site>-<6 random letters or digits>"`, and use it for every browser of this run.
- On ANY stop after a browser is created, run step 7 (clean up) first, then stop.

## 1. Check the tools

Confirm the Kernel MCP tools answer: call `get_connection_context` once. If it fails, tell the user the Kernel MCP server is not connected or not authorized and stop. Do not print the key or any token. `search_docs` is available for questions about Kernel features.

## 2. Find what already worked

Look for a workflow that already succeeded: the conversation, earlier tool calls in this session, or the user's notes. Reuse its URLs, selectors and waits. Explore live only for missing steps, and only inside what the user authorized. If there is no working workflow and no authorization to test one, stop and ask.

Decide the controls. Default is `execute_playwright_code` for DOM steps (return a small value; a thrown snippet comes back as a failed result with the error text). Use `computer_action` for OS-level steps only when Playwright fails. `browser_repl` suits exploring with state kept between calls. Record the choice in the skill.

## 3. Get consent, then prepare a discovery browser

Name the profile `<site>-<user-id>`; resolve the user id from the message or project, ask if unknown. Skip this (and the profile) when the flow needs no login, for example a public practice site. Check what exists first: `manage_profiles` list (or `get` with the exact name). If the check fails, stop and tell the user: do not treat it as "absent".

Then list for the user every profile, connection and browser you will create or write to, marking which already exist. WAIT for a yes before creating anything. In a non-interactive run the user's explicit request to build and run is the consent for tagged browsers only; anything that creates a profile or connection still needs a yes. Never use `save_profile_changes: true` on a profile that existed before this run.

After the yes, create only what is absent: a new profile comes from `manage_profiles` setup (the login flow in `/kernel-browser:login`) or from a browser created with `profile_name` and `save_profile_changes: true`, which is saved when that browser is deleted.

Make one private scratch directory for screenshots if you need local files (`umask 077; mktemp -d`), print it, and use that literal path as `<S>`. Create the browser with `manage_browsers` action `create`. Headful is the default and live view needs it (headless has no live view). Prefer headful for `computer_action`. `stealth` can only be set at creation. Suggested arguments for discovery (unverified as a combination):

```
manage_browsers create: profile_name "<site>-<user-id>", stealth true, timeout_seconds 600,
  tags {cc_session: "<hook session id>", site_skill: "<run-tag>"}
```

Add `save_profile_changes: true` only if you created that profile in this run; for a profile that existed before, leave it out (or load it read-only) so deleting the browser cannot overwrite it. Use the returned `session_id` wherever this file says `<browser-id>`; if it is empty or the call failed, stop. Profile facts (`../browse/references/profiles.md`): changes are saved only when a session created with `save_profile_changes` is deleted (closing the CDP client saves nothing); without the flag they are discarded; with two writers the last wins, so keep one writer per profile and any number of read-only readers.

## 4. Establish login (only if the site needs it)

Check first whether the saved profile is already signed in (the `goto` plus `page.url()` variant is unverified; `return await page.title()` is the known-good form):

```
execute_playwright_code: session_id <browser-id>, code: await page.goto("<site-url>"); return page.url()
computer_action: screenshot on <browser-id>
```

Look at the screenshot to judge the state. If login is needed, follow `/kernel-browser:login` (hosted login or a Managed Auth connection via `manage_auth_connections` create, login, submit, timeline, wait). Give any hosted-login or live-view URL to the user in ONE message, never open it in the Kernel browser, and verify the signed-in state yourself afterwards. A password never goes in a snippet, a command line, a file or the generated skill, and a password pasted in chat is already in the transcript: keep it out of later calls. Note for the generated skill which connection or profile type is used and how it is checked, with names as runtime inputs; no values.

If bot detection blocks login, recreate the browser with `stealth` (and see `../browse/references/unblock.md`). If still blocked, ask the user to log in by hand through live view, then verify the state yourself.

## 5. Explore and verify each task

Each task must be runnable on its own (shared setup plus login prerequisites). For each task: go to the starting state and look at the page; do the task and confirm the real state change after each action; record inputs, start state, direct URLs, ordered snippets, the wait condition, the success check and every failure or workaround; test uncertain steps alone, then run the whole sequence with the exact snippets you will document.

DOM rules (use `return` for results; keep returned values small):
- Prefer role, label or text locators; CSS or XPath only if those fail.
- Wait for a URL, visible element or value that proves completion, with a short timeout (for example 5000 ms), not `networkidle` or fixed sleeps.
- Use `page.frameLocator(...)` for iframes (unverified). Check the call's success before trusting its result.
- Do not rely on variables between `execute_playwright_code` calls; use `browser_repl` when state must persist.

Computer fallback: if Playwright fails 2-3 times on a step (error, timeout, or no page change), use `computer_action` (screenshot, click, type, key press) for that step only, after checking the step did not already succeed. Read coordinates from a screenshot and record the viewport size next to them.

## 6. Write the skill

Draft at `<skills-dir>/<slug>/SKILL.md`; `<slug>` is the primary domain with hyphens (`example-com`, not `example.com`) and equals the `name:` field. Find the skills directory from the project's agent instructions (for example `.claude/skills/`) or ask. If the file exists, show a diff and ask before overwriting.

Fill this template only with verified details; user ids, connection and profile names stay runtime inputs.
````markdown
---
name: <slug>
description: <What it does on <site> and when to use it.>
---

# <Site Name>

## Setup
<Kernel MCP server connected; runtime inputs (user id); which profile to load (read-only unless this task must write), stealth, tags {cc_session}, timeout_seconds; the tested manage_browsers create arguments.>

## Login
<Saved-profile check (snippet and expected result); /kernel-browser:login fallback; live-view hand-off.>

## <Task Name>
<Inputs and starting state.>

```js
// Tested snippet for execute_playwright_code, with waits and the success check.
```
<Expected outcome and recovery. Repeat per task.>

## Cleanup
<Delete the browser with manage_browsers delete (this saves the profile only if it was created with save_profile_changes), remove scratch screenshots.>

## Notes
<Quirks, workarounds, coordinates and viewport size.>
````

Include the field-to-selector map, login steps, waits and success checks; no credential values.

Leak check before the file is final. Run this on the draft and fix every hit:

```bash
grep -c -E 'sk_[0-9a-fA-F]{8}-' <file>   # a count only: a key must never be echoed; any count above 0 is a hit to fix
grep -nEi 'jwt=|handoff_code=|wss?://|onkernel\.com/browser/(live|replay|cdp)|token=|session=|api[_-]?key|password|@[a-z0-9.-]+\.[a-z]{2,}' <file>
```

Strip query strings from documented URLs and remove any recorded ids. `password` hits are fine only as a field name or type, never a value. Re-run until only those remain.

## 7. Clean up

Delete the browser with `manage_browsers` action `delete` (this saves the profile if it was created with `save_profile_changes`), remove the scratch directory (`rm -rf <S>`), and confirm none of this run's browsers remain: `manage_browsers` list with `status: "active"` and `tags` for the run tag (expect none; the account may hold other people's browsers).

Delete a profile or connection only if you created it in this run for throwaway discovery and the user agrees; never one that existed before.

## 8. Cold run

Create a fresh browser (the step 3 arguments with the same run tag and without `save_profile_changes`), follow the new skill's steps once exactly as written and check each success condition. Fix the skill where it fails and re-run the leak check. Then run step 7 for this browser. No task counts as verified without this run.

## Report to the user

Reply in exactly this shape (no URLs, no ids):

```
Site skill: <absolute path>; Tasks captured: <list>
Controls: <execute_playwright_code | browser_repl | computer_action>; Login: <none | hosted login | managed auth | manual live view> (profile, connection names)
Verified: <steps run end to end, cold run result, what proved success>
Not verified: <copied or unverified steps>
Cleaned up: <what was deleted; what was left and why>
Open questions: <decisions for the user>
```

Verified live 2026-10-20; types re-checked on SDK 0.129.0 / CLI 0.49.0; evidence ledger: https://github.com/yigitkonur/plugin-kernel-sh/blob/main/verified-facts.md (MCP tool names checked against the Kernel MCP server source, 2026-10-22)
