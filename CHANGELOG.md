# Changelog

## 1.0.0 - 2026-10-20

First release.

- Knowledge skill `kernel` with 17 references (SDK client, browsers, control surfaces, unblocking, logins, profiles, vaults and payments, scale, apps, observability, account, CLI, MCP, integrations, API map, things that do not exist, verification record).
- Workflow skills: `debug-session`, `login` (model- and user-invocable); `audit`, `profile-site`, `diff-profiles`, `site-skill` (user-invocable).
- Hooks: project primer (SessionStart, SubagentStart), stale-identifier tripwire (PostToolUse), API-key guard (PreToolUse).
- Bundled hosted Kernel MCP server (OAuth).
- Every fact was checked against `@onkernel/sdk` 0.127.0/0.128.0, CLI 0.49.0 and live runs on 2026-10-20; see `verified-facts.md`.
