# plugin-kernel-sh

two claude code plugins for [kernel](https://kernel.sh) cloud browsers. pick the one that matches what you're doing, or install both:

| plugin | for when | what it gives you |
|---|---|---|
| **`kernel-browser`** | claude code should *use* a cloud browser: browse, read, fill forms, act on sites you're logged in to, without running chrome on your laptop | the kernel mcp server, skills for browsing, logging in (hosted page, live view, 1password) and cleaning up, and hooks that tag, track and delete every browser a session creates |
| **`kernel-dev`** | you're *writing code* that uses kernel (typescript, `@onkernel/sdk`, the `kernel` cli) | a live-tested knowledge skill, debugging, login, audit and site-profiling workflows, and hooks that catch deprecated fields and leaked api keys |

the facts in here were checked against `@onkernel/sdk`, the `kernel` cli, the kernel mcp server's source and live runs on a real account (receipts: [verified-facts.md](verified-facts.md)). anything that wasn't run live says "(unverified)" or "(untested)" right in the text.

<!-- kit:install:start -->
## install

Every plugin of ours is installed **once, globally, and off**, then **turned on per project**. Nothing runs and no tokens are spent in chats that don't switch it on. It works the same in Claude Code and Codex.

### 1. install them globally

**Claude Code**

```sh
claude plugin marketplace add yigitkonur/plugin-kernel-sh
claude plugin install kernel-dev@plugin-kernel-sh -s user          # stays off: defaultEnabled is false in the manifest
claude plugin install kernel-browser@plugin-kernel-sh -s user
```

**Codex** (0.163+)

```sh
codex plugin marketplace add yigitkonur/plugin-kernel-sh
codex plugin add kernel-dev@plugin-kernel-sh
codex plugin add kernel-browser@plugin-kernel-sh
codex-plugin-project.sh global-off kernel-dev@plugin-kernel-sh     # Codex has no enable/disable command; this keeps it off everywhere
codex-plugin-project.sh global-off kernel-browser@plugin-kernel-sh
```

All our plugins, both hosts, plus the `plugin` command and the 6-hourly update job, in one line:

```sh
curl -fsSL https://raw.githubusercontent.com/yigitkonur/plugin-kit/main/install.sh | sh -s -- --all
```

### 2. turn them on in a project

```sh
cd your-project
plugin on kernel-dev    # Claude Code and Codex, this folder only
plugin off kernel-dev   # undo
plugin                  # or pick from a list (TUI)
```

By hand, without the `plugin` command:

```sh
claude plugin enable kernel-dev@plugin-kernel-sh --scope project      # undo: claude plugin disable kernel-dev@plugin-kernel-sh --scope project
claude plugin enable kernel-browser@plugin-kernel-sh --scope project      # undo: claude plugin disable kernel-browser@plugin-kernel-sh --scope project
codex-plugin-project.sh on kernel-dev@plugin-kernel-sh . --trust      # undo: codex-plugin-project.sh off kernel-dev@plugin-kernel-sh
codex-plugin-project.sh on kernel-browser@plugin-kernel-sh . --trust      # undo: codex-plugin-project.sh off kernel-browser@plugin-kernel-sh
```

Restart `claude` / `codex` in that folder afterwards.
Codex reads a folder's `.codex/config.toml` only when the folder is trusted; `--trust` adds that, and it also enables the folder's hooks and rules, so use it for your own projects only. `plugin` and `codex-plugin-project.sh` come from [plugin-kit](https://github.com/yigitkonur/plugin-kit) (the one-line installer above).

### 3. updates

A plugin updates only when its `version` changes, and this repo's `release` workflow bumps it on every shipped change. Machines pick it up with `plugin update`, or by themselves with the 6-hourly job (`plugin autoupdate install`). By hand:

```sh
claude plugin marketplace update plugin-kernel-sh && claude plugin update kernel-dev@plugin-kernel-sh
codex plugin marketplace upgrade plugin-kernel-sh        # then start a new session
```

No GitHub SSH key on the machine? `export CLAUDE_CODE_PLUGIN_PREFER_HTTPS=1` (`plugin install` sets it in Claude's settings for you).

### 4. uninstall

```sh
claude plugin uninstall kernel-dev@plugin-kernel-sh -s user
claude plugin uninstall kernel-browser@plugin-kernel-sh -s user
claude plugin marketplace remove plugin-kernel-sh
codex plugin remove kernel-dev@plugin-kernel-sh
codex plugin remove kernel-browser@plugin-kernel-sh
codex plugin marketplace remove plugin-kernel-sh
```
<!-- kit:install:end -->

### coming from 1.x

the old plugin was called `kernel`. it's now `kernel-dev` (2.0.0), same content, skills under `/kernel-dev:`. after a marketplace update the old one shows "failed to load" in `claude plugin list`; run `claude plugin uninstall kernel@plugin-kernel-sh`, then install `kernel-dev` as described above.

### two plugins, one marketplace

the marketplace `plugin-kernel-sh` carries both `kernel-browser` and `kernel-dev`; install and switch on whichever you need, or both. `kernel-browser` will say "6 userConfig options not yet set" once installed: they're all optional, see its setup below. codex runs the same two plugins: see the "on codex" notes under each plugin below.

### what you need

- macos or linux, claude code 2.1.302 or newer. the hooks are posix `sh`; windows is untested.
- `jq`. the `kernel-browser` hooks stay silent without it; the `kernel-dev` hooks work without it.
- a kernel account. both plugins bundle kernel's hosted mcp server: run `/mcp`, pick `kernel`, sign in once. until then it shows "needs authentication" and adds no tools.
- install both? you still get one kernel server: claude code keeps the copy of whichever plugin was installed first and drops the duplicate (checked on 2.1.306). one sign-in covers both.

## kernel-browser: kernel as claude code's browser

your laptop runs claude code; the browser runs in kernel's cloud. good when a bunch of agents browsing locally is cooking your machine, when a site blocks headless chrome, or when you want saved logins that every agent can reuse.

### setup (two minutes)

1. `/mcp` → `kernel` → sign in. that's the only required step.
2. **recommended:** give the cleanup hooks an api key so they can delete a session's leftover browsers when it ends. in a session: `/plugin configure kernel-browser@plugin-kernel-sh` and paste the key into `api_key` (stored in your os keychain). or from a shell where `KERNEL_API_KEY` is set:
   ```sh
   printf '{"api_key":"%s"}' "$KERNEL_API_KEY" | claude plugin configure kernel-browser@plugin-kernel-sh --values-stdin
   ```
   without a key the hooks still guard and track, but can't delete at session end; kernel's idle timeout does it a bit later.
3. **recommended:** run agent browsers in their own kernel project with a concurrency cap, and set a spending cap in the dashboard (billing → spending cap):
   ```sh
   kernel projects create agents
   kernel projects limits set agents --max-concurrent-sessions 5
   ```
   then set the plugin's `project` option to `agents`. the agent then passes that project on every kernel call (the create guard sends back any create aimed elsewhere), so browsers and cleanup stay in the same project.
4. want claude to reach for kernel instead of a local browser by default? add one line to your `CLAUDE.md`: "for web tasks, use the kernel-browser:browse skill (kernel cloud browsers)".

options (`/plugin configure kernel-browser@plugin-kernel-sh`): `api_key`, `default_timeout_seconds` (600), `max_timeout_seconds` (1800), `project`, `cleanup_on_session_end` (on), `check_leftovers_on_start` (on).

### skills

| command | who triggers it | what it does |
|---|---|---|
| `/kernel-browser:browse <task>` | you or the agent | the main loop: reuse this session's browser or create one (tagged, sane timeout), pick the right saved login (asks when there's more than one), drive it with webmcp / playwright / repl / screenshots, confirm before anything irreversible, delete when done |
| `/kernel-browser:login <domain>` | you or the agent | gets a site's login into a kernel profile without a password ever touching chat: hosted kernel login page, live view, 1password, or a credential stored from env vars for unattended re-login |
| `/kernel-browser:sessions [clean]` | you | lists what's alive (this session, older claude code sessions, everything else), profiles and logins that need attention; deletes claude code leftovers when you say so |
| `/kernel-browser:debug-session <id>` | you or the agent | why did that browser session fail: state, telemetry (even after delete), replays |
| `/kernel-browser:diff-profiles <a> <b>` | you | "works on profile a, not b": compares cookie names, domains and storage keys, never values |
| `/kernel-browser:site-skill` | you | turns a browsing workflow that worked into a reusable skill for that site |

### hooks (all fail-open; `KERNEL_BROWSER_HOOKS=off` mutes them)

| when | what |
|---|---|
| session or subagent start | a ~150-token note: kernel browsers are here, load `browse`, five rules. with an api key it also says how many browsers older claude code sessions left alive (one api call, cached 10 min) |
| before `manage_browsers create` | sends the call back unless it carries `tags.cc_session` (this session's id) and a `timeout_seconds` within your cap. deny, not rewrite, so your permission settings stay untouched |
| after create / profile setup / pool acquire / delete | remembers which browsers this session made |
| the agent ends a turn with browsers alive | reminds it once, with the ids. claude code labels any blocking stop hook "Stop hook error occurred": that's this reminder, not a failure |
| the session ends | deletes the browsers this session made (not ones tagged `keep: "after-session"`, which the agent sets only when you ask). needs the api key |
| before any kernel mcp call, edit or bash command | blocks a kernel api key or a 1password service-account token in the input |
| after any kernel mcp call | masks `cdp_ws_url`, `webdriver_ws_url`, `base_url` and key literals in the result before the model reads them (the live-view url stays: you need it) |

### the questions everyone asks

**does kernel close browsers by itself?** only through `timeout_seconds`, an *idle* timer (default 60 s, max 72 h). no max lifetime. idle (standby) time is free, so a forgotten browser costs nothing but still holds a concurrency slot, and the next create fails at your plan's limit. what costs money is a browser kept *active*: an open live-view tab, a running computer-use action, a client connected over cdp. we tested the scary case: playwright calls and a repl holding a cdp connection do **not** keep a browser active between calls, and those browsers idled out on time. this plugin closes the gap: every browser is tagged with the session, and the session's end deletes them.

**can every agent start from one logged-in profile?** yes, that's kernel's native pattern. any number of browsers load a profile read-only at once, and each is a private throwaway copy. exactly one writer refreshes the saved login (a managed-auth connection, or one refresh browser you verify and then delete). we checked live: two browsers on one profile at the same time were both signed in. where it breaks: sites that rotate refresh tokens, sites that allow one session per account, and new-device checks when the ip changes (fix: one isp proxy per identity). details in the `browse` skill's `references/profiles.md`.

**can it use the logins from my own chrome?** no. kernel has no profile upload. you log in once *inside* kernel (`/kernel-browser:login`), and from then on agents reuse that profile.

**1password?** two ways:
- *personal / families accounts:* "agentic autofill" (kernel preview). you link 1password once, approve each login in the 1password app, and the 1password extension inside the kernel browser fills and submits. kernel and the agent never see the values. the result is saved to a profile, so later browsers start logged in with no approval until the site's session expires. own non-shared vault only, no passkeys. on our test org the link step returned `404 not_found` (the preview wasn't enabled there), so ask kernel support if you hit that.
- *business / teams accounts:* a 1password service account connected in the kernel dashboard lets managed auth log in fully unattended, with credentials pulled from 1password each time.

**two browsers at once?** fine, within your plan's concurrency (developer 5, hobbyist 10, start-up 150). several tasks as the same logged-in user run better in one browser with named playwright executors (one tab each, up to 8): one snapshot, no writer fights.

### privacy and safety

- passwords never go through chat or tool input; the `login` skill routes them through kernel's hosted page, a live view, 1password or env vars. the key guard blocks kernel keys and 1password service-account tokens in kernel mcp input.
- browser control urls are masked in mcp results; live-view and hosted-login urls go to you once, only when you have to act.
- page content is treated as data: the skills tell the agent never to follow instructions found on a page, and to ask before any submit, send, post, delete or purchase.
- unlike `kernel-dev`, these hooks make network calls, and only with an api key configured: one list call at session start (count of leftovers, `check_leftovers_on_start`), a status check on this session's browsers when a turn ends, and deletes at session end (`cleanup_on_session_end`). nothing else leaves your machine.

### kernel-browser on codex

same plugin, same skills and hooks, installed globally and off, switched on per project (`plugin on kernel-browser`, see install above). what's different:

- **sign in once:** `codex mcp login kernel_mcp`. the plugin's server is called `kernel_mcp` in codex (claude code: `kernel`) because `kernel` is the name of the kernel app in codex's connector list. if you also connected that app, codex may use its tools (`kernel.<tool>`) instead; the hooks cover both. tool names: claude code `mcp__plugin_kernel-browser_kernel__<tool>`, codex `kernel_mcp.<tool>`.
- **settings are environment variables** (codex has no plugin settings). export them in the shell that starts `codex`: `KERNEL_API_KEY` (cleanup hooks only), `KERNEL_BROWSER_DEFAULT_TIMEOUT_SECONDS` (600), `KERNEL_BROWSER_MAX_TIMEOUT_SECONDS` (1800), `KERNEL_BROWSER_PROJECT`, `KERNEL_BROWSER_CLEANUP_ON_SESSION_END` (true), `KERNEL_BROWSER_CHECK_LEFTOVERS_ON_START` (true), and `KERNEL_BROWSER_HOOKS=off` to mute the hooks. in claude code the `/plugin configure` values win when both are set.
- **trust the hooks once:** the first codex session in a project shows "hooks need review"; open `/hooks` and trust them.
- **what runs:** the session and subagent primer, the create guard (tag and timeout), tracking, the once-per-session stop reminder, the key guard (also on `apply_patch`, codex's file-write tool) and the delete-at-session-end cleanup (codex gives hooks 3 s there; needs `KERNEL_API_KEY`).
- **what doesn't:** result masking. codex ignores `updatedMCPToolOutput`, so `cdp_ws_url`, `webdriver_ws_url` and `base_url` stay visible to the model; the primer tells the agent to treat them as secrets. there are no `/kernel-browser:...` slash commands; ask for the skill by name ("use kernel-browser:browse to ...").
- **not verified on codex:** the oauth sign-in end to end (the login url is reached, the sign-in itself wasn't completed), `SubagentStart` / `SubagentStop` hooks, and any call to a real kernel account through the plugin's own `kernel_mcp` server.

## kernel-dev: writing code on kernel (was `kernel`)

makes coding agents use kernel the right way in typescript projects: *when and why* to reach for each feature, flags deprecated fields the moment they get written, keeps api keys out of your code, and ships workflows for the stuff that actually hurts.

**knowledge skill: `kernel`.** loads by itself when code or commands create, drive, debug or scale kernel browsers. a short decision tree plus the non-negotiables; the agent reads deeper references on demand: sdk client, browsers, control surfaces, unblocking (stealth, proxies, captcha), logins, profiles, vaults and payments, scale and pools, apps, observability, account, cli, mcp, integrations, an api map, and a list of things that straight up do not exist.

| command | who triggers it | what it does |
|---|---|---|
| `/kernel-dev:debug-session <session-id>` | you or the agent | reads session state and telemetry (still readable after the browser is deleted), replays and logs, then diagnoses and proposes a fix |
| `/kernel-dev:login <domain>` | you or the agent | first decides whether you even need browser auth, then sets up managed auth or a vault fill and relaunches a logged-in browser |
| `/kernel-dev:audit [path]` | you | read-only review of this project's kernel usage, with `file:line` findings and sources |
| `/kernel-dev:profile-site <url>` | you | finds the bot-detection vendors on a site and the kernel config that gets past them |
| `/kernel-dev:diff-profiles <a> <b>` | you | compares two profiles without ever printing values |
| `/kernel-dev:site-skill` | you | turns a workflow that worked into a reusable skill for that site |

**hooks** (four handlers, all fail-open; `KERNEL_PLUGIN_HOOKS=off` mutes them): a ~1.1k-character primer at session and subagent start, only in projects that use kernel; a tripwire after edits that flags a deprecated kernel identifier only when the edit just added it; a guard that blocks writing a literal kernel api key into code or a shell command (a gitignored file is fine).

**mcp server.** bundled for the coding agent's own checks (list and clean up browsers, search the docs, try a snippet). your product code should call `@onkernel/sdk`, not the mcp. for doing tasks *in* a browser, that's `kernel-browser`.

`kernel-dev` needs the `kernel` cli for the workflows (`brew install kernel/tap/kernel` or `npm i -g @onkernel/cli`) and `KERNEL_API_KEY` in your environment or a gitignored `.env`. its hooks make no network calls; detection scans manifests, ci files and `.env*` files for kernel marker *names* (never values). the key guard is a speed bump, not a vault: it won't catch a key split across lines or one in a subagent prompt.

### kernel-dev on codex

same plugin, installed globally and off, switched on per project (`plugin on kernel-dev`, see install above). what's different:

- **sign in once:** `codex mcp login kernel_mcp` (the server is `kernel_mcp` in codex, `kernel` in claude code; tools are `kernel_mcp.<tool>`). `KERNEL_API_KEY` in your environment or a gitignored `.env` is still what the workflows and the `kernel` cli use.
- **trust the hooks once:** the first codex session in a project shows "hooks need review"; open `/hooks` and trust them. `KERNEL_PLUGIN_HOOKS=off` mutes them.
- **what runs:** the primer (kernel projects only), the deprecated-identifier tripwire after an `apply_patch` (codex's file-write tool; reports the first patched file with a finding) and the key guard on `apply_patch` and shell commands.
- **what doesn't:** no `/kernel-dev:...` slash commands; ask for the skill by name ("use kernel-dev:audit on this project"). codex doesn't put a plugin's `bin/` on `PATH`, so the skills call the `kernel-plugin` helper by its path inside the plugin when it isn't found.

## receipts

- **kernel-dev live probes.** 23 topic probes against a real kernel account on 2026-10-20 (sdk 0.127.0, types re-checked on 0.129.0; cli 0.49.0). the ledger has <!--ledger-counts-->137 confirmed, 43 refuted, 5 gated and 14 untested<!--/ledger-counts--> rows, plus 24 naive-agent task runs that passed 23 of 23 with cleanup verified every time.
- **kernel-browser live runs** (2026-10-22, claude code 2.1.306, the plugin loaded with a bearer-key mcp config): the idle-timeout leak test, the create guard, the stop reminder plus session-end delete, a browse task with a screenshot, a stored-credential login and two simultaneous readers of one profile, choosing between two profiles and reusing a live browser, url masking and the key guard on mcp input. each row and what went wrong on the way is in [verified-facts.md](verified-facts.md).
- **installs.** the one-liners above were run from github after the 2.0.0 / 1.0.0 release in clean claude code configs (2.1.306): both plugins install, the installed files match `main`, update and uninstall work, and the 1.x → `kernel-dev` upgrade path was run end to end.
- **mcp findings.** what we hit in kernel's mcp server while building this, with evidence: [MCP-FINDINGS.md](MCP-FINDINGS.md).
- **not verified:** the interactive oauth sign-in to the bundled mcp server (the bearer-key variant is verified), 1password agentic autofill end to end (not enabled on the test org), payments, gpu browsers, windows.

## repo layout

```
.claude-plugin/marketplace.json   marketplace "plugin-kernel-sh": kernel-browser, kernel-dev
.agents/plugins/marketplace.json  the same marketplace for codex
plugins/kernel-browser/           skills/ hooks/ lib/ .mcp.json (only this directory gets installed)
plugins/kernel-dev/               skills/ hooks/ lib/ rules/ bin/ .mcp.json
plugins/*/.codex-plugin/          codex manifest; with .codex-mcp.json and hooks/codex-hooks.json next to the claude files
shared/lib/                       hook library copied into both plugins (scripts/sync-shared.sh)
tests/                            kernel-dev hook, detection and rule tests (sh tests/run.sh)
lab/                              maintainer smoke tests against the live api
scripts/                          validate, release gate, snippet type-check, link check, freshness, secret scan, kit/ (vendored from plugin-kit)
verified-facts.md                 evidence ledger from live runs
MCP-FINDINGS.md                   issues found in kernel's mcp server
DECISIONS.md                      why it's built this way
CHANGELOG.md                      what changed per release
```

maintainers: `sh tests/run.sh --all-shells`, `scripts/validate.sh`, `scripts/secret-scan.sh --tree`, and `cd lab && npm install && node ../scripts/typecheck-snippets.mjs`. versions live in each `plugin.json` and are bumped by the release workflow on `main`, never by hand (see [AGENTS.md](AGENTS.md)). ci runs the tests on ubuntu and macos, and a weekly job opens an issue when kernel ships something that needs re-verifying.

## license

mit. some workflow skills derive from the official kernel skills (mit, copyright (c) 2025 kernel); see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
