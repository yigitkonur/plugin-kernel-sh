# Changelog

## 1.0.1 - 2026-10-21

A quality pass on 1.0.0: wrong or unsafe advice fixed, claims aligned with the evidence, and the hooks tightened. Facts re-checked against `@onkernel/sdk` 0.128.0 and CLI 0.49.0 (both still the latest on npm).

- Workflow skills: every `kernel ... | jq` is now capture-then-parse, because the CLI writes errors to stderr and an empty pipe made failures look like success; `diff-profiles` storage comparison no longer breaks under zsh (unquoted command variable, shell globs that match nothing); `login` and `debug-session` clean up their temp files and browsers on every stop path; `profile-site` keeps its work directory across calls and uses one slot rule; `site-skill` uses a private scratch directory; `audit` no longer reports "no key in history" when the git check failed.
- References: corrected contradictions with the ledger and the SDK types (GPU plan gate, telemetry frame shape, `kernel vaults items invoke`, CLI `invoke` blocking, `kernel logs -i`, MCP header expansion, vault field edits, pool vaults, Stagehand template version); several snippets now clean up on every path.
- Hooks: the key guard also matches uppercase-hex keys and allows any gitignored file; the stale-identifier tripwire reports a line only when the edit added it (not when it only kept it as context); `lint` never echoes a key literal; false positives of K004, K016 and K018 removed; detection state is private to the user, written atomically, and an abandoned scan is not repeated for ten minutes; big non-git trees are not walked.
- Tests and CI: 372 tests, up from 341 (new cases for each fix; tests that could not fail now assert their effect); CI also type-checks the skill snippets, runs the suite under dash and GNU coreutils and without `jq`, uses read-only permissions and pinned actions; the weekly job also checks links and the docs changelog.
- README: counts are generated from the ledger (and checked by `scripts/validate.sh`), the privacy and key-guard limits are stated plainly, and the dogfood result is described as what it is.

## 1.0.0 - 2026-10-20

First release.

- Knowledge skill `kernel` with 17 references (SDK client, browsers, control surfaces, unblocking, logins, profiles, vaults and payments, scale, apps, observability, account, CLI, MCP, integrations, API map, things that do not exist, verification record).
- Workflow skills: `debug-session`, `login` (model- and user-invocable); `audit`, `profile-site`, `diff-profiles`, `site-skill` (user-invocable).
- Hooks: project primer (SessionStart, SubagentStart), stale-identifier tripwire (PostToolUse), API-key guard (PreToolUse).
- Bundled hosted Kernel MCP server (OAuth).
- Every fact was checked against `@onkernel/sdk` 0.127.0/0.128.0, CLI 0.49.0 and live runs on 2026-10-20; see `verified-facts.md`.
