# kernel CLI: operating Kernel from the terminal

Use the CLI to look, probe and clean up: list browsers, run one Playwright snippet, grab a screenshot, check limits. Code that ships calls `@onkernel/sdk` (`references/sdk-client.md`). Everything here is for CLI v0.49.0; `kernel <command> --help` is authoritative for the installed binary (flag names can differ from older notes; e.g. the browser timeout flag is `-t/--timeout`).

## Install and authenticate

**If** `kernel` is not on PATH (`which kernel` is empty) -> **Do** tell the user the two install commands and stop: `brew install kernel/tap/kernel` or `npm i -g @onkernel/cli`. Check with `kernel --version`. **Avoid** installing it yourself without being asked. **Source** https://www.kernel.sh/docs/reference/cli

**If** you run non-interactively (agent, CI) -> **Do** export `KERNEL_API_KEY`; it wins over stored OAuth. `kernel login` opens a browser and stores OAuth tokens in the OS keyring (service `kernel-cli`), so it is for humans. Confirm who you are with `kernel auth context -o json` (top-level keys: `authentication`, `authorization`, `organization`, `principal`). **Avoid** `kernel auth` alone as an identity check: it shows auth status and hosts the `connections` subcommands. **Source** https://github.com/onkernel/cli `pkg/auth/client.go`, `pkg/auth/storage.go`; verified live.

**If** the key reaches several projects -> **Do** pass `--project <id-or-name>` or set `KERNEL_PROJECT` (both accept an ID or exact name; global flag on every command). **Source** https://github.com/onkernel/cli `cmd/root.go`; https://www.kernel.sh/docs/info/projects

## Command map

| You want to | Command group |
|---|---|
| Browser lifecycle | `kernel browsers list\|create\|get\|view\|update\|delete` |
| Drive a page | `kernel browsers playwright execute <id> '<code>'`, `browsers playwright executors list\|delete`, `browsers repl <id> [code]`, `browsers curl <id> <url>` |
| Mouse, keys, screenshot | `kernel browsers computer screenshot\|click-mouse\|move-mouse\|type\|press-key\|scroll\|drag-mouse\|batch\|read-clipboard\|write-clipboard` |
| Files and processes in the VM | `kernel browsers fs ...`, `kernel browsers process exec\|spawn\|kill\|status\|stdin\|stdout-stream\|resize` |
| Observe | `kernel browsers telemetry events\|stream`, `browsers logs stream`, `browsers replays list\|start\|stop\|download` |
| Pools | `kernel browser-pools list\|create\|get\|update\|delete\|acquire\|release\|flush` |
| State and network | `kernel profiles ...`, `kernel proxies ...` (incl. `proxies check <id>`), `kernel extensions ...` |
| Logins and secrets | `kernel auth connections ...`, `kernel credentials ...`, `kernel credential-providers ...`, `kernel vaults ...` |
| Apps | `kernel create`, `kernel deploy`, `kernel invoke`, `kernel invoke history`, `kernel app list\|delete\|history`, `kernel logs <app>` |
| Account | `kernel org limits get\|set`, `kernel org entitlements`, `kernel projects ...`, `kernel api-keys ...`, `kernel audit-logs search` |
| Utility | `kernel status`, `kernel search`, `kernel upgrade`, `kernel completion <shell>`, `kernel mcp install --target <t>` |

The full flag list for each lives in `--help`; the groups above exist in the CLI source (`cmd/root.go`, `cmd/browsers.go`). Invocation history is `kernel invoke history`, not a top-level command (source `cmd/invoke.go`; untested live).

## Reading output: -o json

**If** a script or agent will parse output -> **Do** add `-o json` and pipe to `jq`; **check the exit code first**. **Avoid** parsing stdout of a failed call: errors are plain text even with `-o json` (`ERROR: Not_found: browser session 'x' not found`, exit 1). **Source** verified live.

- `-o json` is per command, not global. Most read commands support it; confirm with `--help`.
- **If** a script parses list output -> **Do** expect a top-level array (`browsers`, `browser-pools`, `profiles`, `proxies`, `app`, `credentials`, `auth connections`); `vaults list` returns an object `{ "vaults": [...] }`. **Avoid** reusing one jq filter for both. **Source** verified live.
- **If** you run `deploy` or `invoke` with `-o json` -> **Do** treat output as JSONL (one object per line) and filter with `jq -c 'select(...)'` or use `invoke get` / `invoke history` afterwards. **Avoid** dumping the stream into context. **Source** `cmd/invoke.go` (untested live).
- **If** you need status or limits as data -> **Do** use `kernel status -o json`, which returns `{ status, groups }`; `kernel org limits get -o json` returns `concurrent_sessions_used`, `concurrent_sessions_available`, `max_concurrent_sessions` and others. **Avoid** reading `null` in `max_auth_connections` / `max_vaults` as unlimited (unverified). **Source** verified live (keys).

## Verification commands

Run these to check the state of a run instead of trusting code you wrote. All read-only except `browsers playwright execute` (runs caller code in the page) and `browsers computer screenshot --to` (writes a PNG file).

```bash
kernel auth context -o json
kernel status -o json
kernel org limits get -o json
kernel org entitlements -o json
kernel browsers list --status active -o json
kernel browsers list --status active --tag run=example -o json
kernel browsers get <id> --include-deleted -o json
kernel browsers playwright execute <id> 'return await page.title()' -o json
kernel browsers computer screenshot <id> --to ./shot.png
```

- **Leftover browsers:** **If** you finish a task that created browsers -> **Do** run `kernel browsers list --status active -o json | jq length` (filter by `--tag` if you tagged them) and report anything alive. `--status` takes `active` (default), `deleted` or `all`: `browsers list` shows only active browsers by default, so a just-deleted browser is absent (an empty list after delete is normal); use `--status all` or `deleted`, or `browsers get <id> --include-deleted`. **Avoid** `browsers list --include-deleted` (deprecated; use `--status`).
- **Deleted session:** **If** `browsers get <id>` exits 1 with Not_found after a delete -> **Do** retry with `--include-deleted`: exit 0, `deleted_at` set, and no `status` key. **Avoid** reading a missing `status` as "unknown". **Source** verified live.
- **Playwright snippet:** **If** you need a value from a page -> **Do** note the code runs with `page` in scope; use `return` to get a value. Result shape: `{ result, success, tab: { created, target_id } }`. A new browser starts on `about:blank`, so pass `--start-url` at create or `page.goto` first. `--executor` runs it in a named executor with its own tab; `--timeout` is in seconds. **Avoid** `page.title()` on a fresh browser without `--start-url` (it is `about:blank`). **Source** verified live; https://github.com/onkernel/cli `cmd/browsers_playwright.go`.
- **Screenshot:** **If** you need a visual check -> **Do** use `--to <path>`, which writes a PNG and prints `SUCCESS: Saved screenshot to ...` **Avoid** printing image bytes to the terminal. **Source** verified live (valid PNG).
- **Telemetry:** **If** you need event history -> **Do** run `kernel browsers telemetry events <id> --since 24h --all` pages through history. Flags: `--limit` (1-100, default 20), `--offset`, `--order asc|desc` (not with `--since`), `--until`, `--categories`, `--types`, `--all`. Prefer `--types`/`--categories` plus `--limit` and `jq` over `--all` on busy sessions. Untested; flags from source. **Source** `cmd/browsers.go`; details: `references/observe.md`.
- **Proxy check:** **If** you need to test a proxy -> **Do** `kernel proxies check <id>  # untested`. **Avoid** assuming it passes; not run. **Source** `cmd/proxies/proxies.go`.

## Browser lifecycle from the CLI

**If** you need a throwaway browser to try something -> **Do**:

```bash
out=$(kernel browsers create -o json --headless -t 120 --name my-browser --tag run=example --start-url https://example.com -y)
id=$(printf '%s' "$out" | jq -r '.session_id // empty')   # keep only session_id; the other URLs are credentials
[ -n "$id" ] || exit 1                          # no id parsed: stop; never run delete with an empty id (find it by --tag instead)
printf '%s' "$out" | jq '{session_id}'          # never print cdp_ws_url, base_url or webdriver_ws_url
# ... work with "$id" ...
kernel browsers delete "$id"
```

`-y` skips prompts (the pool-conflict confirm). Create flags worth knowing: `--stealth`, `--headless`, `--gpu`, `--kiosk`, `-t/--timeout` (seconds, default 60; the SDK field is `timeout_seconds`), `--start-url`, `--name`, `--tag K=V` (repeatable), `--profile-id|--profile-name` with `--save-changes`, `--proxy-id|--proxy-name|--proxy-mode`, `--region`, `--viewport`, `--pool-id|--pool-name`, `--telemetry`, `--extension`, `--vault`, `--allowed-host`. Output keys include `session_id`, `cdp_ws_url`, `base_url`, `webdriver_ws_url`, `name`, `tags`, `region`, `headless`, `stealth`, `timeout_seconds`. **Source** create verified live; https://github.com/onkernel/cli `cmd/browsers.go`.

**If** you delete a browser -> **Do** run `kernel browsers delete <id-or-name> [more...]` with no `-y`. **Avoid** `-y` here: the tested binary (self-reports 0.47 in places) rejects it (exit 1, `Unknown shorthand flag: 'y'`) even though https://www.kernel.sh/docs/reference/cli/browsers lists it. Delete never prompts and is idempotent: a missing or already-deleted id prints success. **Source** verified live; `cmd/browsers.go` `browsersDeleteCmd` has no flags.

**If** you need the live view -> **Do** `kernel browsers view <id> -o json  # untested` (the SDK field is `browser_live_view_url`; the CLI JSON key was not run, so check it). **Avoid** pasting that URL anywhere: it is a credential. Mask the token path segment in anything you report, e.g. `https://api.onkernel.com/browser/live/***`.

**If** a profile, proxy, viewport, name, tags or telemetry must change on a running browser -> **Do** `kernel browsers update <id-or-name> ...  # untested` (flags in `--help`). **Avoid** guessing flags; read `--help`. **Source** https://www.kernel.sh/docs/reference/cli/browsers (untested live).

## Logs

**If** you want browser logs -> **Do** `kernel browsers logs stream <id> --source supervisor --supervisor-process chromium` (or `--source path --path <file>`; `--follow` defaults to true, so bound it with `timeout`). **Avoid** trusting exit 0: it exits 0 and prints `logs source not available` or `failed to open log path` to stdout when the source is unusable. In live tests no source returned log lines (chromium, kernel-images-api, a path), so treat this command as unproven and prefer telemetry for diagnosis. **Source** the command exists (verified live); whether it returns lines is unclear.

**If** you want app logs -> **Do** `kernel logs <app> --since 10m  # untested` (add `--follow` only with a timeout; `--since` takes `s/m/h`, not `d`; `-i <invocation>` narrows to one run). **Source** https://github.com/onkernel/cli `cmd/logs.go` (untested live).

## Scaffold, deploy, invoke

**If** you scaffold an app from an agent -> **Do** pass every flag: `kernel create --name my-app --language ts --template sample-app`. With flags it writes 6 files (`index.ts`, `package.json`, `tsconfig.json`, `README.md`, `.gitignore`, `pnpm-lock.yaml`) and does not deploy. **Avoid** omitting flags: without a TTY it exits 1 with `Cannot prompt for input: stdin is not an interactive terminal` and lists the missing flags. Also note it runs `pnpm install` (or `uv venv` for Python) if that tool is on PATH, which hits the network; if the tool is absent it prints a WARNING and still exits 0. `-y` overwrites an existing directory without asking. **Source** verified live.

**If** you deploy or invoke -> **Do** `kernel deploy index.ts -o json  # untested` then `kernel invoke <app> <action> --payload '{...}' -o json  # untested`; read results later with `kernel invoke history --app <app> --status failed --limit 5` and `kernel logs <app> -i <invocation>`. `invoke` is async by default; `--sync` holds an HTTP request open, `--async-timeout` is 10-3600 s. **Avoid** retrying a failed invoke or deploy blindly (not idempotent) and `deploy --force` unless overwriting the same version is intended. `kernel deploy delete` and `kernel app delete` take `-y` (`--yes`) and fail without it when stdin is not a terminal; `browsers delete` has no `-y`. Not run live (untested); full flow in `references/apps.md`.

## Org and cost checks

**If** you are about to start cost-bearing work or got a 403 -> **Do** `kernel org limits get -o json | jq '{used: .concurrent_sessions_used, free: .concurrent_sessions_available, max: .max_concurrent_sessions}'  # untested pipeline` (keys confirmed; pipe not run) and `kernel org entitlements -o json | jq 'keys'` (`features`, `limits`, `plan`). `kernel org limits set --default-project-max-concurrent-sessions <n>` changes spend-relevant limits: do not run it without the user asking; `0` removes the default. Counters drift when other workers share the account. **Source** https://www.kernel.sh/docs/reference/cli/org

## MCP install

**If** the user wants the Kernel MCP server in their tool -> **Do** tell them to run `kernel mcp install --target <target>  # untested`; targets: `cursor`, `claude`, `claude-code`, `antigravity`, `windsurf`, `vscode`, `goose`, `zed`, `fx`. It edits that tool's config file and keeps other servers. HTTP transport (`https://mcp.onkernel.com/mcp`) for cursor, claude-code, vscode, fx; stdio via `mcp-remote` for claude, windsurf, goose, zed, antigravity (CLI source sets stdio for antigravity, the docs page says HTTP: docs and source disagree, unverified). **Avoid** running it for the user unprompted: it writes outside the project. If the Kernel plugin already bundles the MCP server, installing it again may create a duplicate (unverified). Usage after install: `references/mcp.md`. **Source** https://www.kernel.sh/docs/reference/cli/mcp (not run: it would modify user config).

## Traps

| Trap | Reality |
|---|---|
| `browsers delete -y` | Exits 1; the flag does not exist. Plain `delete` never prompts. |
| Parsing JSON after a failure | Errors are plain text; check exit code first. |
| `logs stream` exit 0 | Says nothing about whether a source worked. Read the text. |
| One jq filter for all lists | `vaults list` is `{vaults: []}`, the rest are arrays. |
| `kernel create` in CI | Needs `--name --language --template`; runs the package installer if on PATH. |
| Printing create/view output | Contains CDP, live view and base URLs: credentials. Extract only `session_id`. |
| `browsers get` on a deleted id | 404-style exit 1 unless `--include-deleted`. |

---

Verified live 2026-10-20 (Hobbyist plan); types re-checked on @onkernel/sdk 0.128.0. Evidence ledger: https://github.com/yigitkonur/plugin-kernel-sh/blob/main/verified-facts.md
