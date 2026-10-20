# Design decisions

Why the plugin looks the way it does. Each row is something a contributor might reasonably want to change; the reason is what to re-check first.

## What it is

| Decision | Reason |
|---|---|
| TypeScript only (`@onkernel/sdk`, `playwright-core`), plus the `kernel` CLI, REST and MCP | The goal is correct Kernel use in TS projects. CLI, REST and MCP are included because that is how agents operate Kernel from any terminal. Python and Go are out of scope. |
| One knowledge skill (`kernel`) with topic references, six workflow skills | One entry point that hooks can name; depth is read on demand. Workflow skills are separate because they are procedures with arguments. |
| `debug-session` and `login` can be invoked by the model; `audit`, `profile-site`, `diff-profiles`, `site-skill` are user-only | The first two are things an agent should do on its own mid-task. The rest are deliberate, sometimes costly reviews. |
| The plugin ships no secret and has no `userConfig` | The hooks read names and patterns, never `.env` contents. The bundled MCP server uses OAuth. |
| The bundled MCP server is framed for management and quick checks | Product code should call `@onkernel/sdk`; the MCP is for the coding agent's own exploring and debugging. Measured cost after authentication: about 1k tokens (31 deferred tools). |
| Named `plugin-kernel-sh`; the marketplace cannot be named `kernel` | Kernel's own marketplace uses that name. |

## Hooks (four handlers)

| Hook | Decision | Reason |
|---|---|---|
| SessionStart + SubagentStart primer | Only when Kernel is detected; about 1.1k characters; also after compaction and fork | An agent cannot know this project uses Kernel until it opens a file; subagents do not inherit SessionStart context. |
| PostToolUse stale-identifier tripwire | Reports a rule only if it matches the file on disk and the text just written; at most 3 findings | Deprecated fields get copied from Kernel's own docs and sample skills at write time. Untouched legacy lines are not re-reported. |
| PreToolUse API-key guard | Deny Kernel key literals in tool input; allow a gitignored `.env`; always deny in Bash | The key format is precise enough to deny without false positives; a leaked key is expensive. |
| All hooks | POSIX sh, fail-open, no network, no `timeout` binary | Works on macOS and Linux with stock tools. A broken hook must never block work. `KERNEL_PLUGIN_HOOKS=off` disables all. |

## Hooks: limits chosen on purpose (1.0.1)

| Decision | Reason |
|---|---|
| The key guard is a speed bump, not a vault: Edit, Write, MultiEdit, NotebookEdit and Bash input only; a key split over lines, in an MCP call or in a subagent prompt is not seen | A regex over tool input cannot be complete, and a false deny blocks real work. The README says so. |
| Any gitignored file may hold a key; outside a git repo only `.env`-named files may | Nothing can commit a gitignored file; outside git there is no ignore rule to rely on. |
| The all-zero placeholder key is treated as a key by the guard | The tests need a harmless literal to exercise the deny path. |
| The tripwire compares the lines an edit wrote with the lines it replaced | Kernel's docs show deprecated fields, so the moment of writing is what matters; a legacy line the edit only keeps as context is not news. Without `jq` only Edit and Write supply the replaced text. |
| A README or docs file that mentions `@onkernel/` or `KERNEL_API_KEY` still marks a project as Kernel | A project that documents installing the Kernel CLI usually uses it (a fixture asserts this); the cost of a wrong guess is one primer. |
| Big non-git trees (over 5000 files, `KP_SCAN_MAX_FILES`) are searched in manifests and config files only; an abandoned scan is not repeated for ten minutes | A hook has a 10 s limit and no `timeout` binary; failing to detect costs one primer, a stuck hook costs every edit. |

## Rejected or deferred

| Idea | Decision |
|---|---|
| A subagent reviewer | Rejected: the forked `audit` skill gives the same isolation. |
| `UserPromptSubmit` keyword hook | Rejected: runs on every prompt in every project; the skill description matches the same words. |
| Model-based (`prompt`/`agent`) hooks on edits | Rejected: a model call per edit. |
| `paths:` globs on the skill | Rejected: Kernel code can live in any file. |
| Leak guard (tracking created browsers, blocking at Stop) | Not built (decided from evidence). Across 23 lab probes and the dogfood task runs, every script that followed the `try/finally` + `deleteByID` pattern left nothing behind. The only orphans came from processes killed or hung before `finally` ran (an agent's `timeout` kill in the executor probe; a failed id parse in the MCP probe); the `timeout_seconds` backstop reaped them. Idle browsers cost nothing but hold a concurrency slot, so the real fixes are the primer's `finally` rule, a deliberate `timeout_seconds`, and run tags that make leftovers findable (`kernel browsers list --tag run=<id>`). Revisit if GPU browsers (which never idle) or very long timeouts become common. |
| Mirroring Kernel docs into the plugin | Rejected: it would go stale in days. The plugin ships rules, lab-tested facts and a verify-live protocol instead. |
| Depending on Kernel's official `kernel-cli` / `kernel-sdks` skills | Rejected: their content is absorbed, corrected and extended here (see `THIRD_PARTY_NOTICES.md`). Keeping both installed can give conflicting advice. |
| Auto-installing the `kernel` CLI | Rejected: silent installs are not the plugin's business; skills print the install commands. |
| Evals and A/B runs | Not done: the plugin is proven by live ledger rows and by dogfood runs where naive agents read only the plugin files (see `verified-facts.md`). |

## Keeping it current

Kernel ships every one to three days. `scripts/check-freshness.sh` (weekly in CI) compares the latest SDK and CLI with `verified-against.md`, lists new `@deprecated` tags as candidate stale-API rules, and opens an issue. `lab/` re-checks the key facts live.
