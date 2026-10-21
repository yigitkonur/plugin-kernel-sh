---
name: sessions
description: >-
  List the Kernel browsers that are alive right now (this Claude Code session's, ones left by earlier Claude Code sessions, and everything else), plus saved profiles and login connections, and delete Claude Code leftovers on request. Use when the user asks what Kernel browsers are running, why the concurrency limit is full, or to clean up leftover Kernel browsers.
disable-model-invocation: true
argument-hint: "[clean]"
---

# /kernel-browser:sessions

Goal: the user sees what is alive in Kernel and who left it there, and leftovers from Claude Code are gone when they ask, without touching anything else.

The argument is the text after the skill name (or the line starting `ARGUMENTS:`). `clean` means: after listing, delete the Claude Code leftovers (Step 3) without asking again. Anything else, or nothing: list only, then ask.

Use the Kernel MCP tools with a one-line `context` on each call; pass `project` if the user named one. Never print a browser URL of any kind.

## Step 1. Collect
1. `manage_browsers` `action: list`, `status: "active"`, `limit: 100`. If 100 come back, call again with `offset: 100`, and so on, until a page is shorter than the limit.
2. `manage_profiles` `action: list` and `manage_auth_connections` `action: list` (names, domains and statuses only).
3. Optional: if the user named a project, `manage_projects` `action: get_limits` for its concurrency cap.

## Step 2. Group and show
Sort each browser into one group by its `tags`:
- **This session**: `tags.cc_session` equals this session's id (from the kernel-browser note at session start).
- **Earlier Claude Code sessions**: `tags.cc_session` is set to another value. Mark the ones tagged `keep: "after-session"` as kept on purpose.
- **Other**: no `cc_session` tag. These belong to the user's own code, pools, apps or other tools. Never delete them from this skill unless the user names the exact id.

Show one table per group: `session_id`, `name`, `created_at` (and age), `headless`, the profile name if any, `timeout_seconds`, `keep` tag. Then one line: total live browsers, and that idle browsers cost nothing but each one holds a concurrency slot (Developer plan 5, Hobbyist 10, Start-Up 150).

After the tables, list profiles (name, last update if shown) and connections (domain, profile, status). Flag connections with `status: NEEDS_AUTH`: `/kernel-browser:login <domain>` refreshes them.

## Step 3. Clean up
- Candidates: browsers in "Earlier Claude Code sessions" without `keep: "after-session"`, plus browsers of this session the user says are done.
- Without `clean`: show the candidate ids and ask "Delete these N browsers?" Wait for yes. With `clean`: go ahead.
- Delete each with `manage_browsers` `action: delete` and `session_id`. Pool browsers (the list shows a pool) are released instead: `manage_browser_pools` `action: release` with the pool and `session_id`, `reuse: false`.
- A browser kept on purpose (`keep: "after-session"`) or in "Other": only with the user naming that id.
- Never delete profiles, connections or credentials from this skill.
- List again and report what is left.

## Report
```
Live browsers: <total>   this session <n>, earlier Claude Code sessions <n> (kept on purpose <n>), other <n>
Deleted: <ids, or none>
Left running: <ids and why: this session's / kept on purpose / not created by Claude Code>
Logins needing attention: <domains with NEEDS_AUTH, or none>
```

To stop leftovers at the source: the plugin deletes a session's browsers when the Claude Code session ends, if it has an API key (plugin option `api_key` or `KERNEL_API_KEY`). See `../browse/references/cost.md`.
