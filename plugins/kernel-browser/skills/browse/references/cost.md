# What a Kernel browser costs, and how to leave nothing billing

## How billing works
- Kernel bills a browser only while it is **active**. After five seconds with no activity it goes into **standby**, which costs nothing and keeps its state. Source: https://www.kernel.sh/docs/browsers/standby
- Active means: a CDP or WebDriver client is connected, a live-view viewer is connected, or a computer-control request (`computer_action`) is running. Leaving a live-view tab open keeps a browser active and billed.
- Playwright and REPL calls do **not** keep a browser active between calls. Verified live 2026-10-22 through the same executor and REPL API the MCP tools use: a browser touched once with a Playwright call, and one whose REPL held a `connectOverCDP` connection in a variable, were both deleted by their 30 s idle timeout within 60 s, like an untouched one.
- Rates (https://www.kernel.sh/docs/info/pricing): headful about $0.48 per active hour, headless about $0.06 (one eighth), headful with GPU about $2.88. GPU browsers never enter standby.

## The only automatic close: the idle timeout
- `timeout_seconds` on create is an **idle** timer. Its countdown starts when the browser goes into standby; any activity resets it. When it runs out, Kernel deletes the browser. Default 60 s, maximum 259200 (72 h). Source: https://www.kernel.sh/docs/browsers/termination
- Kernel has no maximum lifetime and no "delete when the agent stops". A browser kept busy (a live view left open, a loop) runs until something deletes it.
- 60 s is too short when you wait for the user: the browser is deleted and a later step fails. Use 600. A long timeout (hours) costs nothing while idle but holds a concurrency slot the whole time.

## Concurrency: standby still counts
- Every live browser, active or in standby, and every pool reservation counts toward the org's concurrent-browser limit: Developer 5, Hobbyist 10, Start-Up 150. Source: https://www.kernel.sh/docs/browsers/concurrency-and-limits
- Forgotten idle browsers do not cost money, but they fill the slots, and the next create fails. List this session's browsers before creating (`manage_browsers` `action: list`, `tags: { cc_session: "<id>" }`) and delete what you no longer need.

## What the kernel-browser plugin does for you
| When | What | Needs |
|---|---|---|
| `manage_browsers create` | sends the create back unless it has `tags.cc_session` and a `timeout_seconds` within the cap | nothing |
| after create, profile setup, pool acquire | remembers the session id for this Claude Code session | nothing |
| the agent ends a turn with browsers alive | reminds it once, listing them | nothing (an API key lets it skip ones already gone) |
| the Claude Code session ends | deletes the browsers this session created, except ones tagged `keep: "after-session"` | an API key: plugin option `api_key` or `KERNEL_API_KEY` |
| a new session starts | says how many browsers earlier Claude Code sessions left alive | an API key |

Without an API key the session-end cleanup cannot run; the idle timeout still deletes each browser after it.

## Limits the user can set (tell them; never change them yourself)
- A project just for agent browsers with its own concurrency cap: `kernel projects create agents`, then `kernel projects limits set agents --max-concurrent-sessions 5`. Point the plugin at it with the `project` option.
- A monthly spending cap for the org or the project in the dashboard (Billing, Spending Cap; preview). At 100% new usage pauses. Source: https://www.kernel.sh/docs/info/spending-caps
- Managed Auth health checks and re-auths start billed browsers: keep them off on connections that are not used unattended.

## Find and clean up leftovers
`/kernel-browser:sessions` lists live browsers by owner (this session, earlier Claude Code sessions, everything else) and deletes the Claude Code leftovers on request. Never delete a browser without the `cc_session` tag unless the user confirms that id.
