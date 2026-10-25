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
- Read-only toward the project and the account. Do not create, update or delete browsers, profiles, pools, apps or keys. Do not edit project files. (The plugin's own `kernel-plugin detect` keeps a few bytes of cache in its data or temp folder, and `claude mcp list` may health-check configured MCP servers; neither touches the project or the account.) Do not run `kernel org limits set`, `kernel deploy`, `kernel invoke` or anything that starts a browser.
- Never print an API key, a `cdp_ws_url`, `browser_live_view_url`, `replay_view_url`, `hosted_url`, or a URL carrying `?jwt=`. Mask them as `***`. If a finding is a literal key (K019), quote only the file and line, never the value, and treat the linter output as sensitive (it prints key literals as found).
- Never dump a command's raw JSON into the context. Project fields with `jq`.
- Check the exit code before parsing, and never pipe a CLI into `jq` (the pipe hides the CLI's exit code, and its plain-text error such as `ERROR: Authentication required: ...` (wording unverified) would reach `jq`). Capture first: `out=$(kernel ... -o json) && jq '...' <<<"$out" || echo "could not check: <cmd>"`. Every `could not check` line goes under "Could not check" in the report.
- A hit is a lead, not a verdict. Read the surrounding code before you report it.

## 1. Check the CLI

Replace `$PROJECT` with the path argument (quoted) in every command below.

Run `command -v kernel`. If it prints nothing, print these install commands (do not install anything), mark the account checks (section 2, except `detect` and the git checks) as skipped, and continue at section 3. The linter and the checklist do not need the CLI:

```bash
brew install kernel/tap/kernel
npm i -g @onkernel/cli
```

Run `kernel --version` and keep the number for the report. Run `command -v jq` too: sections 2 and 3 project JSON fields with `jq`. If it is missing, print `brew install jq`, mark sections 2 and 3 skipped, and continue at section 4.

## 2. Check the environment

Run these now. Each is read-only. If one fails, note the one-line error in the report under "Could not check" and go on; do not retry in a loop.

```bash
out=$(kernel-plugin detect --json "$PROJECT") && jq '{detected, tier, summary}' <<<"$out" || echo "could not check: detect"
out=$(kernel auth context -o json) && jq 'keys' <<<"$out" || echo "could not check: auth context"
out=$(kernel status -o json) && jq '{status}' <<<"$out" || echo "could not check: status"
out=$(kernel org entitlements -o json) && jq '{plan: .plan.id, features: (.features | keys)}' <<<"$out" || echo "could not check: org entitlements"
out=$(kernel org limits get -o json) && jq '{used: .concurrent_sessions_used, free: .concurrent_sessions_available, max: .max_concurrent_sessions}' <<<"$out" || echo "could not check: org limits get"
# name and tags are free text from the account: mask key literals and URLs, cut to 60 characters
out=$(kernel browsers list --status active --limit 100 -o json) && jq 'def red: if type=="string" then gsub("sk_[A-Za-z0-9_.-]+";"sk_***") | gsub("https?://[^ ]+";"<url>") | .[0:60] else . end; [.[] | {session_id, name: (.name|red), created_at, timeout_seconds, headless, tags: ((.tags // {}) | with_entries(.key |= red | .value |= red))}]' <<<"$out" || echo "could not check: browsers list"
```

(`kernel-plugin` is the plugin's helper in `bin/`; if it is not on PATH (Codex does not add a plugin's `bin/` to PATH), call it as `../../bin/kernel-plugin` relative to this skill's folder. The keys of `auth context`, `status`, `org limits get` and `org entitlements` (`features`, `plan`) were verified live; the `jq` projections above are built from those keys and were not each run for this skill.)

Read the results:
- `detect` says `detected: false`: tell the user no Kernel usage was found at that path and stop, unless they named the path on purpose.
- `auth context` fails: `KERNEL_API_KEY` is not set in this shell. Skip the account checks, say so, and continue with the code audit. Never ask the user to paste the key.
- `browsers list` is org-wide, not per project, and the timeout counts from idle (an active browser past `timeout_seconds` since creation is not necessarily a leak; see C16). Report active browsers with no `tags` or a very old `created_at` as "org-wide, possibly not this project". Attribute one to this project only if its `tags` or `name` match what the code sets. List up to ten by `session_id` (not by URL). Do not delete them; tell the user the command (`kernel browsers delete <id>`) and let them decide.
- `used` near `max`: say that new work will fail with a concurrency error until browsers are freed (https://www.kernel.sh/docs/browsers/concurrency-and-limits).
- `entitlements` shows a feature the code uses as off (for example GPU, custom proxies): report it as a finding on the file that uses it.

Then check the two non-Kernel facts that cause leaks:

```bash
if files=$(git -C "$PROJECT" ls-files 2>/dev/null); then printf '%s\n' "$files" | grep -E '(^|/)\.env($|\.)' | grep -v -E '\.(example|sample|template)$'; else echo "could not check: not a git repository"; fi
claude mcp list 2>/dev/null | grep -i kernel
```

- If the first command printed `could not check`, skip the `.env` check and list it under "Could not check". No output at all means no tracked `.env*` file.
- A tracked `.env*` file (anything printed by the first command): High finding, "env file tracked by git". Do not print its contents. Check whether it holds `KERNEL_API_KEY` with `git -C "$PROJECT" grep -c KERNEL_API_KEY -- <file>` (count only).
- Key in history (C04). If the path is a git repo, run this and print only the count, never the content:

```bash
if git -C "$PROJECT" rev-parse --git-dir >/dev/null 2>&1; then
  if hist=$(git -C "$PROJECT" log --all -G'sk_[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-' --oneline 2>/dev/null); then printf '%s\n' "$hist" | grep -c .; else echo "could not check: git log failed "; fi
else echo "could not check: not a git repository"; fi
```

  A count above 0 is a High finding, "key literal in git history" (fix: rotate the key). A `could not check` line goes under "Could not check".
- More than one line from `claude mcp list` that points at a Kernel server (`mcp.onkernel.com`), for example one from this plugin and one from `kernel mcp install`: report "duplicate Kernel MCP servers"; the model sees two tool sets that do the same thing. (`claude mcp list` output is unverified; if it fails or `claude` is missing, skip this check.)

## 3. Run the linter

Run now (capture once; the raw output may hold key literals, so never print `$lint`):

```bash
lint=$(kernel-plugin lint "$PROJECT" --json) || echo "could not check: lint"
jq '{files_scanned, rules, counts}' <<<"$lint"
jq -r '.findings[] | select(.id != "K019") | "\(.file):\(.line) \(.id) \(.severity) \(.message). Use \(.replacement). \(.url)"' <<<"$lint"
jq -r '.findings[] | select(.id == "K019") | "\(.file):\(.line) K019 key literal committed"' <<<"$lint"
```

The second command hides `text` on purpose; the third prints K019 without the line text so the key never reaches the context. Keep every row as a finding. The linter reports one row per matching line; fold repeats in one file into one finding with several lines.

Rule ids that matter most: K003, K004, K005 (removed options that now return errors), K015 (API key in a public bundle variable), K016 (a CDP, live-view, replay or hosted-login URL logged), K019 (key literal committed). The table at the end of `references/checklist.md` says what to judge for each; the full list is `rules/stale-api.tsv` in the plugin.

## 4. Judge the code against the checklist

Read `references/checklist.md` now. It has one row per judgment a regex cannot make.

1. Find the Kernel files: every file the linter flagged, plus every file that imports `@onkernel/sdk`, calls `connectOverCDP`, or uses `kernel.browsers`, `kernel.browserPools`, `kernel.invocations`, `kernel.profiles` (use `grep -rl -E "@onkernel/|connectOverCDP|KERNEL_API_KEY" "$PROJECT" --include='*.ts' --include='*.tsx' --include='*.js' --include='*.mjs' --exclude-dir=node_modules --exclude-dir=dist`). Coverage is TypeScript and JavaScript only; other languages are not scanned, so say so in the report. Also grep `package.json`, `Dockerfile*` and CI yaml (`.github/workflows/*.yml`, `.gitlab-ci.yml`) for `@onkernel` and `KERNEL_API_KEY`, and read `package.json` for the `@onkernel/sdk` version and the frontend packages (a Kernel key reaching a bundle).
2. Read at most 30 files in full, flagged files first, then the other matches. If there are more, say how many were left unread. Record the count and file types for the `Scanned:` line. For each checklist row, decide: present, absent, or cannot tell. A row is a finding only if you can point at a file and line.
3. Walk every code path that creates a browser, a pool lease, an app invocation or a profile writer: success, thrown error, early return, timeout, process exit. The row "no deletion on every path" is about all of them, not the happy path.
4. For every external side effect (invoke, deploy, payment, fill-and-submit, search) ask whether a retry could run it twice.

## 5. Verify before you report

For each finding you are not certain of, check it against one of these, in this order, and drop the finding if the check disproves it:
- the installed types: `grep -rn --include='*.d.ts' '<name>' "$PROJECT/node_modules/@onkernel/sdk"` (the package ships no `api.md`). If the project has no `node_modules`, use `../kernel/references/api-map.md` and the nearest ancestor `node_modules/@onkernel/sdk` (look upward from `$PROJECT`), and say which copy and version you checked;
- `kernel <command> --help` for a CLI flag;
- the doc URL in the checklist row.

A claim you could not check goes in the "Uncertain" list, with the reason. Do not turn an uncertain item into a finding to look thorough.

## 6. Report

Report to the user in exactly this shape. Keep each finding to one line plus an optional fix line. Order by severity (high, med, low), then by file.

```
Kernel audit: <path>
CLI: <version> | SDK: <version from package.json or "not installed"> | Account checks: <done | skipped: reason>
Scanned: <n> files (<types, e.g. ts, js, package.json, Dockerfile>); TypeScript and JavaScript only, other languages are not scanned

Findings (<n>)
- <file>:<line> | <id> | <severity> | <what is wrong in one sentence>
  Fix: <the change>. Source: <doc URL, or "verified live">
...

Environment
- Active browsers (org-wide): <n> (<n> without tags or very old, possibly not this project; <n> matched to this project)
- Concurrency: <used>/<max>
- Env file tracked by git: <yes: file | no>
- Key literal in git history: <yes: <n> commits | no | not checked>
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
