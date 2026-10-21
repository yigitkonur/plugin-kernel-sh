# plugin-kernel-sh

a claude code plugin that makes coding agents use [kernel](https://kernel.sh) cloud browsers the right way in typescript projects. it tells the agent *when and why* to reach for each kernel feature, flags deprecated fields the moment they get written, keeps api keys out of your code, and ships workflows for the stuff that actually hurts: a failed session, a login, a site that blocks you, a pre-merge review.

the facts in here were checked against `@onkernel/sdk`, the `kernel` cli and live runs on a real account (receipts: [verified-facts.md](verified-facts.md)). anything that wasn't run live says "(unverified)" or "(untested)" right in the text. no vibes-based docs.

## install

one command from your terminal, and you're set:

```sh
claude plugin install kernel --marketplace yigitkonur/plugin-kernel-sh
```

that adds the `plugin-kernel-sh` marketplace (user scope) and installs `kernel@plugin-kernel-sh` in one go. restart claude code afterwards so the hooks and skills load.

prefer the classic two-step? same result:

```sh
claude plugin marketplace add yigitkonur/plugin-kernel-sh
claude plugin install kernel@plugin-kernel-sh
```

already inside a session? use the slash commands:

```text
/plugin marketplace add yigitkonur/plugin-kernel-sh
/plugin install kernel@plugin-kernel-sh
```

rolling it out to the whole team: run this in the repo, then commit `.claude/settings.json` (it now declares the marketplace and enables the plugin for that project):

```sh
claude plugin marketplace add yigitkonur/plugin-kernel-sh --scope project
claude plugin install kernel@plugin-kernel-sh --scope project
```

check it landed:

```sh
claude plugin details kernel
```

you should see `kernel <version>` (the number in [`VERSION`](VERSION)), 7 skills, 4 hooks, 1 mcp server and about 481 tokens always-on.

staying fresh, or bailing:

```sh
claude plugin marketplace update plugin-kernel-sh && claude plugin update kernel@plugin-kernel-sh
claude plugin uninstall kernel@plugin-kernel-sh
```

every command in this section was run against this repo from a clean claude code config (claude code 2.1.304), and the flags match `claude plugin --help`.

### what you need

- macos or linux. the hooks are posix `sh`; windows is untested.
- claude code 2.1.302 or newer: that's the version the hooks were run on, and they use the `command` + `args` hook form.
- `jq` and the `kernel` cli for the workflow skills (`brew install kernel/tap/kernel` or `npm i -g @onkernel/cli`). the plugin never installs anything behind your back. the hooks run fine without `jq`.
- `KERNEL_API_KEY` in your environment (or a gitignored `.env`) for your own code and the workflows. never paste it into chat.

### the kernel mcp server

run `/mcp`, pick `kernel`, and sign in with oauth once. until you do, it shows "needs authentication" and adds zero tools. the bearer-key variant (for ci, or a client that chokes on oauth) was verified live. the interactive oauth sign-in follows kernel's docs but wasn't completed end to end here (see "receipts").

## what you get

**knowledge skill: `kernel`.** loads by itself when code or commands create, drive, debug or scale kernel browsers. it's a short decision tree plus the non-negotiables, and the agent reads deeper references on demand: sdk client, browsers, control surfaces, unblocking (stealth, proxies, captcha), logins, profiles, vaults and payments, scale and pools, apps, observability, account, cli, mcp, integrations, an api map, and a list of things that straight up do not exist.

**workflow skills**

| command | who triggers it | what it does |
|---|---|---|
| `/kernel:debug-session <session-id>` | you or the agent | reads session state and telemetry (still readable after the browser is deleted), replays and logs, then diagnoses and proposes a fix |
| `/kernel:login <domain>` | you or the agent | first decides whether you even need browser auth, then sets up managed auth or a vault fill and relaunches a logged-in browser |
| `/kernel:audit [path]` | you | read-only review of this project's kernel usage, with `file:line` findings and sources |
| `/kernel:profile-site <url>` | you | finds the bot-detection vendors on a site and the kernel config that gets past them |
| `/kernel:diff-profiles <a> <b>` | you | compares two profiles without ever printing values |
| `/kernel:site-skill` | you | turns a workflow that worked into a reusable skill for that site |

**hooks** (four handlers, all fail-open; set `KERNEL_PLUGIN_HOOKS=off` to mute every one)

| when | what | why |
|---|---|---|
| session start, subagent start | in a project that uses kernel, drops a ~1.1k-character primer: delete browsers in `finally`, default control surface, no secrets in code, verify names instead of guessing | the agent can't know the project uses kernel until it opens a file, and subagents don't inherit session context. other projects get nothing. |
| after an edit | flags a deprecated kernel identifier only when the edit just added it (for example `disable_default_proxy`) | kernel's own docs and sample skills still show deprecated fields |
| before an edit or a shell command | blocks writing a literal kernel api key into code or a command (a gitignored file is fine) | a leaked key is a pain to clean up |

**mcp server.** the hosted kernel mcp server (`https://mcp.onkernel.com/mcp`) comes bundled so the coding agent can manage things and do quick checks (list and clean up browsers, search the docs, try a snippet). your product code should call `@onkernel/sdk`, not the mcp.

## receipts

- **live probes.** 23 topic probes ran against a real kernel account on 2026-10-20 (sdk 0.127.0, types re-checked on 0.129.0; cli 0.49.0). the ledger has <!--ledger-counts-->137 confirmed, 43 refuted, 5 gated and 14 untested<!--/ledger-counts--> rows. refuted means a claim from an earlier skill, the docs or sample code didn't hold up; gated means the plan or a missing model key blocked the test. every row and its evidence lives in [verified-facts.md](verified-facts.md).
- **naive-agent runs.** 24 realistic tasks (screenshots, scraping, logins, vault fill, parallel visits, pools, apps, debugging a failed session, downloads, uploads, stealth, an audit, a next.js route, leftover cleanup, plus one task that needs no browser at all) went to agents that knew kernel only from these files. the final text passed 23 of 23 tasks, and a re-run of the 13 tasks whose guidance changed passed 13 of 13, with cleanup verified every time. that proves the guidance is enough for an agent that knows nothing else about kernel. it doesn't measure how much the plugin changes behavior: there was no control run without the plugin, and a few task prompts state a rule themselves.
- **code.** every typescript snippet in the skills type-checks against the installed sdk (`scripts/typecheck-snippets.mjs`). the hook, detection and rule tests pass under `sh`, `dash`, with gnu coreutils first in `PATH`, and without `jq`. ci runs all of it on ubuntu and macos.
- **not verified**, so the skills say "(unverified)" or "(untested)": the interactive oauth sign-in to the bundled mcp server (the bearer-key variant is verified), payments (link, mpp, agentcard), totp and captcha behavior beyond the lab sites, gpu browsers (plan-gated), the kernel react component's props, and windows.

## privacy and safety

- the plugin ships no secret and asks for none. the hooks make no network calls and send nothing anywhere. project detection scans manifests, ci files and `.env*` files for kernel marker *names* (never values) and keeps a small private cache; the stale-identifier check reads the file you just edited; the key guard only sees the text of the tool call.
- the key guard is a speed bump, not a vault. it checks edit, write, notebookedit and bash input for a literal kernel key (hex digits in either case) and lets you write one into a gitignored file. it won't catch a key split across lines, a key inside an mcp tool call, or one in a subagent prompt.
- workflows print session ids and structure, never cookie values, tokens, cdp / live-view / replay urls or hosted-login urls.
- already have kernel's official `kernel-cli` and `kernel-sdks` plugins? this one supersedes them for typescript work. running both can give mixed advice; this plugin's primer says which to trust.
- also ran `kernel mcp install`? then you have two kernel mcp servers under different names, and `/kernel:audit` will tell you.

## repo layout

```
.claude-plugin/marketplace.json   marketplace "plugin-kernel-sh"
plugins/kernel/                   the plugin (only this directory gets installed)
  skills/  hooks/  lib/  rules/  bin/kernel-plugin  .mcp.json
tests/                            hook, detection and rule tests (sh tests/run.sh)
lab/                              maintainer smoke tests against the live api
scripts/                          validate, snippet type-check, link check, freshness, secret scan
verified-facts.md                 evidence ledger from live runs
DECISIONS.md                      why it's built this way
CHANGELOG.md                      what changed per release
```

maintainers: `sh tests/run.sh --all-shells`, `scripts/validate.sh`, `scripts/secret-scan.sh --tree`, and `cd lab && npm install && node ../scripts/typecheck-snippets.mjs`. the scripts in `scripts/` are bash, so run them directly, not through `sh`. after an sdk bump, `cd lab && npm run smoke` (needs a throwaway key). ci runs the tests on ubuntu and macos, and a weekly job opens an issue when kernel ships something that needs re-verifying.

## license

mit. some workflow skills derive from the official kernel skills (mit, copyright (c) 2025 kernel); see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
