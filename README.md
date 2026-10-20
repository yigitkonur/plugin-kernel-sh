# plugin-kernel-sh

A Claude Code plugin that makes coding agents use [Kernel](https://kernel.sh) cloud browsers correctly in TypeScript projects. It tells the agent *when and why* to use each Kernel capability, catches deprecated fields as they are written, keeps API keys out of code, and gives you workflows for the situations that actually hurt: a failed session, a login, a blocked site, a review.

The facts in it were checked against `@onkernel/sdk`, the `kernel` CLI and live runs on a real account (see [verified-facts.md](verified-facts.md)). What was not checked is marked "(unverified)" or "(untested)" in the text; the list is under "Verification status".

## Install

```sh
claude plugin marketplace add yigitkonur/plugin-kernel-sh
claude plugin install kernel@plugin-kernel-sh
```

or inside Claude Code: `/plugin marketplace add yigitkonur/plugin-kernel-sh`, then `/plugin install kernel@plugin-kernel-sh`.

Requirements: macOS or Linux (the hooks are POSIX `sh`; Windows is untested); Claude Code 2.1.302 or later (that is the version the hooks were run on; they use the `command` plus `args` form). The hooks work without `jq`; the workflow skills need it and say so when it is missing. The workflows use the `kernel` CLI (`brew install kernel/tap/kernel` or `npm i -g @onkernel/cli`); the plugin never installs it for you.

Authenticate the bundled Kernel MCP server once: run `/mcp`, pick `kernel`, and sign in with OAuth. Until then it shows as needing authentication and adds no tools. The Bearer-key variant (for CI, or a client that rejects the OAuth flow) was verified live; the interactive OAuth sign-in follows Kernel's documentation but was not completed end-to-end during this plugin's verification (see "Verification status").

## What you get

**Knowledge skill: `kernel`.** Loaded automatically when code or commands create, drive, debug or scale Kernel browsers. A short decision tree and non-negotiables, plus references the agent reads on demand: SDK client, browsers, control surfaces, unblocking (stealth, proxies, captcha), logins, profiles, vaults and payments, scale and pools, Apps, observability, account, CLI, MCP, integrations, an API map, and a list of things that do not exist.

**Workflow skills**

| Command | Who triggers it | What it does |
|---|---|---|
| `/kernel:debug-session <session-id>` | you or the agent | Reads session state and telemetry (still readable after the browser is deleted), replays and logs; diagnoses and proposes a fix |
| `/kernel:login <domain>` | you or the agent | Decides whether browser auth is needed at all, then sets up Managed Auth or a vault fill and relaunches a logged-in browser |
| `/kernel:audit [path]` | you | Read-only review of this project's Kernel usage with `file:line` findings and sources |
| `/kernel:profile-site <url>` | you | Finds the bot-detection vendors on a site and the Kernel configuration that beats them |
| `/kernel:diff-profiles <a> <b>` | you | Compares two profiles without printing values |
| `/kernel:site-skill` | you | Turns a workflow that worked into a reusable skill for that site |

**Hooks** (four handlers, all fail-open; set `KERNEL_PLUGIN_HOOKS=off` to silence every one)

| When | What | Why |
|---|---|---|
| Session start, subagent start | In a project that uses Kernel, injects a ~1.1k-character primer: delete browsers in `finally`, default control surface, no secrets in code, verify names instead of remembering | The agent cannot know the project uses Kernel until it opens a file; subagents do not inherit session context. Nothing is injected in other projects. |
| After an edit | Reports a deprecated Kernel identifier only if the edit just wrote it (for example `disable_default_proxy`) | Kernel's own docs and sample skills still show deprecated fields |
| Before an edit or a shell command | Denies writing a literal Kernel API key into code or a command (a gitignored `.env` is allowed) | A leaked key is expensive to fix |

**MCP server.** The hosted Kernel MCP server (`https://mcp.onkernel.com/mcp`) is bundled for management and quick checks by the coding agent (list and clean up browsers, search the docs, try a snippet). Your product code should call `@onkernel/sdk`, not the MCP.

## Verification status

- **Live probes.** 23 topic probes ran against a real Kernel account on 2026-10-20 (SDK 0.127.0, types re-checked on 0.128.0; CLI 0.49.0). The ledger has <!--ledger-counts-->137 confirmed, 43 refuted, 5 gated and 14 untested<!--/ledger-counts--> rows: refuted means a claim from an earlier skill, the docs or sample code did not hold up, gated means the plan or a missing model key blocked the test. Every row, with its evidence, is in [verified-facts.md](verified-facts.md).
- **Naive-agent runs.** 24 realistic tasks (screenshots, scraping, logins, vault fill, parallel visits, pools, Apps, debugging a failed session, downloads, uploads, stealth, an audit, a Next.js route, leftover cleanup, one task that needs no browser) were given to agents that knew Kernel only from these files. The final text passed 23 of 23 tasks, and a final re-run of the 13 tasks whose guidance changed passed 13 of 13, with cleanup verified each time. This shows the guidance is enough for an agent that knows nothing else about Kernel. It is not a measurement of how much the plugin changes behavior: there was no control run without the plugin, and a few task prompts state a rule themselves.
- **Code.** Every TypeScript snippet in the skills type-checks against the installed SDK (`scripts/typecheck-snippets.mjs`); the hook, detection and rule tests pass under `sh`, `dash` and with GNU coreutils first in `PATH`; CI runs both on Ubuntu and macOS.
- **Not verified**, so the skills mark it "(unverified)" or "(untested)": the interactive OAuth sign-in to the bundled MCP server (the Bearer-key variant is verified), payments (Link, MPP, AgentCard), TOTP and captcha behavior beyond the lab sites, GPU browsers (plan-gated), the Kernel React component's props, and Windows.

## Privacy and safety

- The plugin ships no secret and asks for none. The hooks make no network calls and send nothing anywhere. Project detection searches manifests, CI files and `.env*` files for Kernel marker names (not values) and keeps a small cache; the stale-identifier check reads the file you just edited; the key guard sees only the text of the tool call.
- The key guard is a speed bump, not a vault. It checks Edit, Write, NotebookEdit and Bash input for a literal Kernel key (hex digits in either case) and lets you write one into a gitignored file. It does not see a key split over several lines, a key in an MCP tool call or in a subagent prompt.
- Workflows print session ids and structure, never cookie values, tokens, CDP / live-view / replay URLs or hosted-login URLs.
- If you already installed Kernel's official `kernel-cli` and `kernel-sdks` plugins, this one supersedes them for TypeScript work. Keeping both can give conflicting advice; this plugin's primer says which to trust.
- If you also ran `kernel mcp install`, you have two Kernel MCP servers under different names; `/kernel:audit` reports that.

## Repository layout

```
.claude-plugin/marketplace.json   marketplace "plugin-kernel-sh"
plugins/kernel/                   the plugin (only this directory is installed)
  skills/  hooks/  lib/  rules/  bin/kernel-plugin  .mcp.json
tests/                            hook, detection and rule tests (sh tests/run.sh)
lab/                              maintainer smoke tests against the live API
scripts/                          validate, link check, freshness, secret scan
verified-facts.md                 evidence ledger from live runs
DECISIONS.md                      why it is built this way
```

Maintainers: `sh tests/run.sh --all-shells`, `scripts/validate.sh`, `scripts/secret-scan.sh --tree` (the scripts in `scripts/` are bash: run them directly, not through `sh`). After an SDK bump, `cd lab && npm run smoke` (needs a throwaway key). CI runs the tests on Ubuntu and macOS, and a weekly job opens an issue when Kernel ships something that needs re-verifying.

## License

MIT. Some workflow skills derive from the official Kernel skills (MIT, Copyright (c) 2025 Kernel); see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
