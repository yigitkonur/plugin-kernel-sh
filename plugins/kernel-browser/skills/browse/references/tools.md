# Driving a Kernel browser with the MCP tools

All tools take a one-line `context` and, when the user named one, `project`. Address a browser by `session_id` (its id or its unique `name`).

## Pick the surface
| Need | Tool | Notes |
|---|---|---|
| The site offers WebMCP tools (structured actions such as "search", "add to cart") | `webmcp` `action: list`, then `invoke` with the `tool_ref` from that list | fastest and least brittle when present. `invoke` `timeout_sec` 1-120. Never retry an invoke after a transport error; check the page |
| Read, click, type, wait, extract | `execute_playwright_code` `{ session_id, code }` | `page` is ready; `return` a small value. Verified live: `await page.goto('https://example.com'); return await page.title();` returned `"Example Domain"`. One call has about a 60 s budget |
| Explore a page step by step | `browser_repl` `{ session_id, code }` | variables persist across cells; `reset: true` starts a fresh REPL; `timeout_sec` 1-150 (a timeout ends the REPL and clears its state) |
| See the screen, or act on canvas, image-only or drag-heavy UI | `computer_action` | screenshots, clicks by coordinates, typing, scrolling. Use a screenshot when the DOM does not tell you what is visible |
| Fetch a URL with the browser's cookies and IP, without rendering | `browser_curl` | for JSON endpoints behind the logged-in session |
| Files in the browser (downloads, uploads) | `manage_browser_files` | default read limit 10 MiB, max 25 MiB. Fetch downloads before deleting the browser |
| Record what happened | `manage_replays` `start`/`stop`/`list` | headful browsers only; replay URLs are sensitive |
| Run a command in the browser VM | `exec_command` | rarely needed |
| How does X work in Kernel | `search_docs` | returns ranked doc sections as text |

## Keep returns small
- Return a few fields: `return { title: await page.title(), rows: (await page.locator('tr').allInnerTexts()).slice(0, 20) }`.
- Trim long text (`.slice(0, 2000)`). Never return `page.content()`, a full `accessibility.snapshot()` or base64 screenshots through Playwright.
- For a list page, return the first N items and the count, then ask for more if needed.

## Parallel pages
- Same user, several pages: one browser, named executors. `execute_playwright_code` with `executor: "a"` opens its own background tab on the first call; calls on different executors run at the same time, calls on one executor run in order. At most 8 named executors per browser. Delete them with `manage_playwright_executors` `action: delete` `{ session_id, name }` when done.
- Different accounts, or different egress IPs: one browser each. Stay under the org's concurrency limit (`cost.md`).
- Many short independent visits (hundreds): a browser pool (`manage_browser_pools`) is the tool, but pools hold concurrency slots while idle; ask the user before creating one. Release every acquired browser (`action: release`, by `session_id`, not name).

## Live view: when a person has to see or act
- A headful browser has a live-view URL (`browser_live_view_url` in the create or `get` result). Give it to the user privately when they must log in, solve something only a person can, or want to watch.
- An open live-view tab keeps the browser active and billed. Tell the user to close it when done.
- Headless browsers have no live view.

## Getting state back
- `manage_browsers` `action: get` shows one browser (tags, profile, timeout).
- `manage_browsers` `action: get_telemetry` with `compact: true` and a `limit` reads recent console, network and page events, also after the browser is deleted. `/kernel-browser:debug-session <id>` walks through a failure.

## MCP quirks seen in the server source and live (2026-10-22)
- The MCP passes `timeout_seconds` through unchanged; it adds no default of its own (Kernel's is 60 s).
- `manage_profiles` `action: setup` starts a stealth browser that saves to the profile, with a fixed 300 s idle timeout and no tags. It never checks that the login finished: the agent must (see `/kernel-browser:login`).
- The create result includes `cdp_ws_url`, `webdriver_ws_url` and `base_url`; the plugin masks them.
- `browser_repl` accepts `timeout_sec` up to 150, while the docs say 300.
- The MCP-Apps login panel (`open_auth_login`, `begin_auth_login`) exists only in clients that render MCP Apps, such as ChatGPT. Claude Code gets the plain tools; `/kernel-browser:login` covers the same flow.
