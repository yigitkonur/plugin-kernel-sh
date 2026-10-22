# Changelog

Versions are per plugin since 2026-10-22; tags are `<plugin>--v<version>`.

## kernel-browser 1.0.1 - 2026-10-22

- The `project` option now steers where browsers are created, not only where cleanup looks: the primer tells the agent to pass it on every Kernel call, and the create guard sends back a browser create, pool create or acquire, or profile setup aimed at another project. Before, browsers could land in the connection's default project while cleanup looked in the configured one and silently did nothing.
- README: Claude Code labels the once-per-session stop reminder "Stop hook error occurred"; the README says so. The 1.x upgrade note and install receipts (KB15) are in.

## kernel-browser 1.0.0 and kernel-dev 2.0.0 - 2026-10-22

- New plugin **`kernel-browser`**: Claude Code uses Kernel cloud browsers as its browser through the Kernel MCP server. Skills `browse`, `login` (hosted login, live view, 1Password Agentic Autofill, stored credential), `sessions` (list and clean up), plus `debug-session`, `diff-profiles` and `site-skill` adapted to the MCP tools. Hooks: a short primer with a leftover count, a create guard (session tag and capped idle timeout, by deny), browser tracking, a once-per-session stop reminder, deletion of the session's browsers at SessionEnd (needs an API key option), a key and 1Password-token guard on MCP input, and masking of browser control URLs in MCP results. `userConfig`: `api_key` (keychain), `default_timeout_seconds`, `max_timeout_seconds`, `project`, `cleanup_on_session_end`, `check_leftovers_on_start`.
- **Breaking:** the plugin `kernel` is renamed **`kernel-dev`** (2.0.0); skills move from `/kernel:` to `/kernel-dev:` and the MCP tool prefix to `mcp__plugin_kernel-dev_kernel__`. Content is unchanged apart from a pointer to `kernel-browser` in `mcp.md`. Uninstall `kernel@plugin-kernel-sh`, install `kernel-dev`.
- Repo: `VERSION` removed (each `plugin.json` is the source of truth; `scripts/sync-version.sh <plugin> <version>`); `scripts/validate.sh` checks every plugin in the marketplace, shared hook libraries (`shared/lib`, `scripts/sync-shared.sh`) and the key regex across plugins.
- Live checks for `kernel-browser` (KB1-KB12 in `verified-facts.md`), including the finding that Playwright executor and REPL connections do not keep a browser billing. Issues found in Kernel's MCP server are in `MCP-FINDINGS.md` and were reported to Kernel.

## kernel 1.0.2 - 2026-10-21

- Security: the scripted-login recipes (`logins.md`, `profiles.md`, `site-skill`) put a throwaway password into the `playwright.execute` code string, and Kernel's `control` telemetry stores that string as `api_call.data.code` (SDK type doc; `control` is on by default). The recipes now create the login browser with `telemetry: { browser: { control: { enabled: false } } }`, and the secrets rules in `kernel/SKILL.md` and `observe.md` say why. Whether the opt-out keeps the code out of storage was not read back live.
- Re-checked on `@onkernel/sdk` 0.129.0 (published 2026-10-21): all 71 snippets and the profile-site analyzer type-check; `locale_source` now reads `default` instead of `metro` (branch on `!== 'override'`), GPU browsers default to a 60 Hz refresh rate, and Kernel wallets carry a secret `capture_token`. The lab and analyzer pins move to 0.129.0.
- `scale.md`: pool sizing guidance rewritten from one long paragraph into three steps; latency numbers now match the ledger.
- The weekly freshness job no longer opens a second issue for a Kernel state it already reported, and its issue title includes the docs changelog entry.
- README: rewritten in a casual lowercase style; adds a one-command install (`claude plugin install kernel --marketplace yigitkonur/plugin-kernel-sh`), team (project-scope), update and uninstall commands, all run from a clean Claude Code config.

## kernel 1.0.1 - 2026-10-21

A quality pass on 1.0.0: wrong or unsafe advice fixed, claims aligned with the evidence, and the hooks tightened. Facts re-checked against `@onkernel/sdk` 0.128.0 and CLI 0.49.0 (both still the latest on npm).

- Workflow skills: every `kernel ... | jq` is now capture-then-parse, because the CLI writes errors to stderr and an empty pipe made failures look like success; `diff-profiles` storage comparison no longer breaks under zsh (unquoted command variable, shell globs that match nothing); `login` and `debug-session` clean up their temp files and browsers on every stop path; `profile-site` keeps its work directory across calls and uses one slot rule; `site-skill` uses a private scratch directory; `audit` no longer reports "no key in history" when the git check failed.
- References: corrected contradictions with the ledger and the SDK types (GPU plan gate, telemetry frame shape, `kernel vaults items invoke`, CLI `invoke` blocking, `kernel logs -i`, MCP header expansion, vault field edits, pool vaults, Stagehand template version); several snippets now clean up on every path.
- Hooks: the key guard also matches uppercase-hex keys and allows any gitignored file; the stale-identifier tripwire reports a line only when the edit added it (not when it only kept it as context); `lint` never echoes a key literal; false positives of K004, K016 and K018 removed; detection state is private to the user, written atomically, and an abandoned scan is not repeated for ten minutes; big non-git trees are not walked.
- Tests and CI: 372 tests, up from 341 (new cases for each fix; tests that could not fail now assert their effect); CI also type-checks the skill snippets, runs the suite under dash and GNU coreutils and without `jq`, uses read-only permissions and pinned actions; the weekly job also checks links and the docs changelog.
- README: counts are generated from the ledger (and checked by `scripts/validate.sh`), the privacy and key-guard limits are stated plainly, and the dogfood result is described as what it is.

## kernel 1.0.0 - 2026-10-20

First release.

- Knowledge skill `kernel` with 17 references (SDK client, browsers, control surfaces, unblocking, logins, profiles, vaults and payments, scale, apps, observability, account, CLI, MCP, integrations, API map, things that do not exist, verification record).
- Workflow skills: `debug-session`, `login` (model- and user-invocable); `audit`, `profile-site`, `diff-profiles`, `site-skill` (user-invocable).
- Hooks: project primer (SessionStart, SubagentStart), stale-identifier tripwire (PostToolUse), API-key guard (PreToolUse).
- Bundled hosted Kernel MCP server (OAuth).
- Every fact was checked against `@onkernel/sdk` 0.127.0/0.128.0, CLI 0.49.0 and live runs on 2026-10-20; see `verified-facts.md`.
