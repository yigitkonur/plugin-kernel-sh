---
name: audit
description: >-
  Audit this project's Kernel usage: environment, deprecated fields, cleanup on every path, secrets, retries, pools, profiles, telemetry. Read-only; reports file:line findings with fixes and sources.
argument-hint: "[path]"
disable-model-invocation: true
context: fork
---

# Audit a project's Kernel usage

You are reviewing code that uses Kernel (kernel.sh cloud browsers) and the account it runs against. Output is a findings list, not a rewrite. Two kinds of evidence: the single-regex linter (cheap, finds deprecated names and leaked values) and your own reading against `references/checklist.md` (finds what a regex cannot: a missing `finally`, a retry on a payment, two writers on one profile).

The argument is the text after the skill name in the user's message (or the line starting `ARGUMENTS:`). It is a project path. If it is missing, use `.`. If the path does not exist, say so and stop.

Rules for the whole run:
- Read-only. Do not create, update or delete browsers, profiles, pools, apps or keys. Do not edit project files. Do not run `kernel org limits set`, `kernel deploy`, `kernel invoke` or anything that starts a browser.
- Never print an API key, a `cdp_ws_url`, `browser_live_view_url`, `replay_view_url`, `hosted_url`, or a URL carrying `?jwt=`. Mask them as `***`. If a finding is a literal key (K019), quote only the file and line, never the value, and treat the linter output as sensitive (it prints key literals as found).
- Never dump a command's raw JSON into the context. Project fields with `jq`.
- Check the exit code before parsing. `-o json` errors from the CLI are plain text such as `ERROR: Authentication required: ...` (not lab-verified wording) with a non-zero exit, so `jq` fails on them.
- A hit is a lead, not a verdict. Read the surrounding code before you report it.

## 1. Check the CLI

Run `command -v kernel`. If it prints nothing, print these install commands and stop (do not install anything):

```bash
brew install kernel/tap/kernel
npm i -g @onkernel/cli
```

Run `kernel --version` and keep the number for the report.

## 2. Check the environment

Run these now. Each is read-only. If one fails, note the one-line error in the report under "Could not check" and go on; do not retry in a loop.

```bash
kernel-plugin detect --json "$PROJECT" | jq '{detected, tier, summary}'
kernel auth context -o json | jq 'keys'
kernel status -o json | jq '{status}'
kernel org entitlements -o json | jq '{plan: .plan.id, features: (.features | keys)}'
kernel org limits get -o json | jq '{used: .concurrent_sessions_used, free: .concurrent_sessions_available, max: .max_concurrent_sessions}'
kernel browsers list --status active --limit 100 -o json | jq '[.[] | {session_id, name, created_at, timeout_seconds, headless, tags}]'
```

(`kernel-plugin` is the plugin's helper in `bin/`; if it is not on PATH, call it as `"${CLAUDE_PLUGIN_ROOT}/bin/kernel-plugin"`. `auth context` keys, `status`, `org limits get` keys and `org entitlements` keys `features` and `plan` are lab-confirmed; the `jq` projections above are built from those keys and were not each run for this skill. `$PROJECT` stands for the path argument: substitute it in every command, quoted.)

Read the results:
- `detect` says `detected: false`: tell the user no Kernel usage was found at that path and stop, unless they named the path on purpose.
- `auth context` fails: `KERNEL_API_KEY` is not set in this shell. Skip the account checks, say so, and continue with the code audit. Never ask the user to paste the key.
- Active browsers older than their `timeout_seconds`, or with no `tags`, or many of them at once: these are leaks or untraceable runs. List up to ten by `session_id` (not by URL) in the report. Do not delete them; tell the user the command (`kernel browsers delete <id>`) and let them decide.
- `used` near `max`: say that new work will fail with a concurrency error until browsers are freed (https://www.kernel.sh/docs/browsers/concurrency-and-limits).
- `entitlements` shows a feature the code uses as off (for example GPU, custom proxies): report it as a finding on the file that uses it.

Then check the two non-Kernel facts that cause leaks:

```bash
git -C "$PROJECT" ls-files | grep -E '(^|/)\.env($|\.)' | grep -v -E '\.(example|sample|template)$'
claude mcp list 2>/dev/null | grep -i kernel
```

- If `git ls-files` fails with "not a git repository", skip the `.env` check and list it under "Could not check".
- A tracked `.env*` file (anything printed by the first command): High finding, "env file tracked by git". Do not print its contents. Check whether it holds `KERNEL_API_KEY` with `git -C "$PROJECT" grep -c KERNEL_API_KEY -- <file>` (count only).
- More than one line from `claude mcp list` that points at a Kernel server (`mcp.onkernel.com`), for example one from this plugin and one from `kernel mcp install`: report "duplicate Kernel MCP servers"; the model sees two tool sets that do the same thing. (`claude mcp list` was not lab-tested; if it fails or `claude` is missing, skip this check.)

## 3. Run the linter

Run now:

```bash
kernel-plugin lint "$PROJECT" --json | jq '{files_scanned, rules, counts}'
kernel-plugin lint "$PROJECT" --json | jq -r '.findings[] | select(.id != "K019") | "\(.file):\(.line) \(.id) \(.severity) \(.message). Use \(.replacement). \(.url)"'
kernel-plugin lint "$PROJECT" --json | jq -r '.findings[] | select(.id == "K019") | "\(.file):\(.line) K019 key literal committed"'
```

The second command hides `text` on purpose; the third prints K019 without the line text so the key never reaches the context. Keep every row as a finding. The linter reports one row per matching line; fold repeats in one file into one finding with several lines.

Rule ids that matter most: K003, K004, K005 (removed options that now return errors), K015 (API key in a public bundle variable), K016 (a CDP, live-view, replay or hosted-login URL logged), K019 (key literal committed). The table at the end of `references/checklist.md` says what to judge for each; the full list is `rules/stale-api.tsv` in the plugin.

## 4. Judge the code against the checklist

Read `references/checklist.md` now. It has one row per judgment a regex cannot make.

1. Find the Kernel files: every file the linter flagged, plus every file that imports `@onkernel/sdk`, calls `connectOverCDP`, or uses `kernel.browsers`, `kernel.browserPools`, `kernel.invocations`, `kernel.profiles` (use `grep -rl -E "@onkernel/|connectOverCDP|KERNEL_API_KEY" "$PROJECT" --include='*.ts' --include='*.tsx' --include='*.js' --include='*.mjs' --exclude-dir=node_modules --exclude-dir=dist`). Also read `package.json` for the `@onkernel/sdk` version and the frontend packages (a Kernel key reaching a bundle).
2. Read each of those files in full. For each checklist row, decide: present, absent, or cannot tell. A row is a finding only if you can point at a file and line.
3. Walk every code path that creates a browser, a pool lease, an app invocation or a profile writer: success, thrown error, early return, timeout, process exit. The row "no deletion on every path" is about all of them, not the happy path.
4. For every external side effect (invoke, deploy, payment, fill-and-submit, search) ask whether a retry could run it twice.

## 5. Verify before you report

For each finding you are not certain of, check it against one of these, in this order, and drop the finding if the check disproves it:
- the installed types: `grep -n "<name>" node_modules/@onkernel/sdk/resources/**/*.d.ts` (the package ships no `api.md`);
- `kernel <command> --help` for a CLI flag;
- the doc URL in the checklist row.

A claim you could not check goes in the "Uncertain" list, with the reason. Do not turn an uncertain item into a finding to look thorough.

## 6. Report

Report to the user in exactly this shape. Keep each finding to one line plus an optional fix line. Order by severity (high, med, low), then by file.

```
Kernel audit: <path>
CLI: <version> | SDK: <version from package.json or "not installed"> | Account checks: <done | skipped: reason>

Findings (<n>)
- <file>:<line> | <id> | <severity> | <what is wrong in one sentence>
  Fix: <the change>. Source: <doc URL or lab probe id>
...

Environment
- Active browsers: <n> (<n> older than their timeout, <n> without tags)
- Concurrency: <used>/<max>
- Env file tracked by git: <yes: file | no>
- Duplicate Kernel MCP servers: <yes | no | not checked>

Uncertain (could not confirm)
- <file>:<line> | <what> | <why it could not be confirmed>

Could not check
- <command>: <one-line error>
```

Rules for the report:
- `<id>` is a linter id (K003) or a checklist id (C01 to C17 in `references/checklist.md`).
- Every finding has a `file:line`. Account-level findings use the command name instead.
- No finding without a fix and a source. No source means it goes under "Uncertain".
- If there are no findings, say "No findings" and still print the Environment and Could not check blocks.
- Do not paste code longer than three lines, and never a key, a signed URL or a hosted-login URL.
- Finish with one sentence naming the single finding to fix first and why.
