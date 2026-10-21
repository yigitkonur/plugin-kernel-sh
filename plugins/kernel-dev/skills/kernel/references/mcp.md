# Kernel MCP server: management and quick checks

The hosted MCP server is for you, the coding agent, to look at and poke at a Kernel org while you work: list browsers, read docs, run a one-off Playwright snippet, clean up leftovers. It is NOT the product's browsing path. Code that ships calls `@onkernel/sdk` (`references/sdk-client.md`). Exact tool names: `references/api-map.md`.

## M1. MCP or SDK or CLI

**If** you are exploring, debugging, or cleaning up in this session -> **Do** use the MCP tools (or the `kernel` CLI if you prefer shell output you can pipe through `jq`). **If** you are writing code the user will run -> **Do** write TypeScript against `@onkernel/sdk`. -> **Avoid** putting MCP calls in shipped code, and avoid starting a browser for something an API can do. -> **Source** https://www.kernel.sh/docs/reference/mcp-server

## M2. Connect

**If** the plugin is installed -> **Do** nothing: it bundles this config; the user runs `/mcp` once to authorize. **If** the user wants it in another client -> **Do** `kernel mcp install --target <target>` (targets: `cursor`, `claude`, `claude-code`, `antigravity`, `windsurf`, `vscode`, `goose`, `zed`, `fx`). `--target claude-code` writes the server to `~/.claude.json`, and the plugin's bundled `.mcp.json` matches that config (write location from the plan, not the docs). -> **Avoid** installing it twice: if the user already ran `kernel mcp install --target claude-code`, you probably have two Kernel servers under different tool prefixes (inferred from the prefix naming, not tested). -> **Source** https://www.kernel.sh/docs/reference/cli/mcp

The bundled config is `plugins/kernel-dev/.mcp.json` (an `http` server at the endpoint below).

- Endpoint is `https://mcp.onkernel.com/mcp` (streamable HTTP). For clients without remote MCP: `npx -y mcp-remote https://mcp.onkernel.com/mcp` (stdio). -> https://www.kernel.sh/docs/reference/mcp-server/transports
- Tool names inside Claude Code through this plugin: `mcp__plugin_kernel-dev_kernel__<tool>`. With the sibling `kernel-browser` plugin also installed, Claude Code keeps one copy of the server (the plugin installed first; checked on 2.1.306), so the prefix may be `mcp__plugin_kernel-browser_kernel__` instead.
- For doing tasks in a cloud browser (browsing, logged-in sites, saved profiles), the `kernel-browser` plugin is the tool; this reference is about the coding agent's own checks.

## M3. Auth

| If | Do | Avoid |
|---|---|---|
| Interactive client | OAuth 2.1 (browser prompt) | Assuming it is project-scoped: check M4 |
| CI, scripts, or a client that fails OAuth with an issuer mismatch (strict RFC 9207 check) | `Authorization: Bearer <Kernel API key>`; non-JWT bearers are treated as API keys | Pasting the key into a committed config; read it from the environment |

- Verified live: Bearer key -> `initialize` 200 with an `mcp-session-id` header; no key -> 401 with `WWW-Authenticate: Bearer realm="OAuth", error="invalid_token"`. A 200 with `x-clerk-auth-message: Invalid JWT form` on a key is expected, not an error.
- `Authorization: Bearer ${KERNEL_API_KEY}` in a Claude Code `.mcp.json` header expands: the server connected with 31 tools (ledger MC1). With the variable unset the server showed status `failed`, a visible failure and not a silent unauthenticated session (ledger MC2).
- Source: https://www.kernel.sh/docs/reference/mcp-server/authentication, https://www.kernel.sh/docs/reference/mcp-server/troubleshooting

## M4. First call: who am I

**If** you are about to create or delete anything -> **Do** call `get_connection_context` first and read `connection_scope` (`kind`, `project_id`) so you know which org or project you are touching. -> **Avoid** assuming the scope: with an API key we saw `kind: organization`, `project_id: null`. -> **Source** verified live

- Pass a `context` string (one line saying why you call) on every call anyway. The schema marks it required on most tools, but the server accepted `manage_browsers list` and `get_connection_context` without it (create and delete without it: untested). Treat it as advisory, not as something to rely on skipping. Docs/schema vs live behavior: live behavior wins for list/read calls.

## M5. Do not hard-code the tool list

**If** you need to know which tools exist -> **Do** read the live `tools/list` (your client already shows it). -> **Avoid** quoting a count: the tool reference pages document 13, the server source names 34, the hosted server returned 31 live (`web_search`, `open_auth_login`, `begin_auth_login` were gated out). Some tools depend on org entitlements, cached up to 30 min in the server source. -> **Source** the server source `tool-names.ts`

```ts
// Trimmed. Run with KERNEL_API_KEY in the environment.
const url = "https://mcp.onkernel.com/mcp";
const base = {
  "Content-Type": "application/json",
  Accept: "application/json, text/event-stream",
  Authorization: `Bearer ${process.env.KERNEL_API_KEY}`,
};
async function post(body: object, sid?: string) {
  const res = await fetch(url, {
    method: "POST",
    headers: { ...base, ...(sid ? { "mcp-session-id": sid } : {}) },
    body: JSON.stringify(body),
  });
  return { status: res.status, sid: res.headers.get("mcp-session-id") ?? undefined, text: await res.text() };
}
const init = await post({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "mcp-check", version: "1.0.0" } } });
if (!init.sid) throw new Error(`no session id on initialize (status ${init.status})`);
await post({ jsonrpc: "2.0", method: "notifications/initialized" }, init.sid);
const list = await post({ jsonrpc: "2.0", id: 2, method: "tools/list", params: {} }, init.sid);
const payload = JSON.parse(list.text.split("\n").find((l) => l.startsWith("data: "))!.slice(6));
console.log(payload.result.tools.map((t: { name: string }) => t.name).join(" "));
```

Never print the session id. Responses are SSE: parse the `data: ` line.

## M6. Tools worth using

| Situation | Do | Avoid | Source |
|---|---|---|---|
| How does X work in Kernel | `search_docs` `{ query }`. Returns text (not structured content): markdown headed `## N. <page>` (ranked doc sections, ledger P21.4) | Guessing a flag before checking | https://www.kernel.sh/docs/reference/mcp-server/tools/search-docs |
| Make, list, inspect, delete a browser | `manage_browsers` `action: create\|update\|list\|get\|get_telemetry\|delete`; `remote_forward` (`remoteport:host:localport`) exposes a local dev server to the browser | Calling `delete` without `session_id`; trusting the docs action list (it omits `update` and `get_telemetry`; the live tool schema listed all six in the lab run; not a ledger row) | https://www.kernel.sh/docs/reference/mcp-server/tools/manage-browsers |
| One-off page check | `execute_playwright_code` `{ session_id, code }`; `return` the value you need. Verified live: `page.goto('https://example.com'); return await page.title()` worked | Expecting it to create or delete the browser (`session_id` is required) | verified live |
| Screenshot | `computer_action` with `screenshot` | `page.screenshot()` inside the code (docs prefer `computer_action`) | https://www.kernel.sh/docs/reference/mcp-server/tools/execute-playwright-code |
| Record video | `manage_replays` `action: start\|stop\|list` | Using a headless browser (docs: needs headful; leave `headless` unset); assuming your plan allows it (paid plan: unverified; start/stop not called live) | https://www.kernel.sh/docs/reference/mcp-server/tools/manage-replays |
| Pull files out of a browser | `manage_browser_files`; schema: `max_bytes` default 10 MiB, maximum 25 MiB | Assuming read/download works (not exercised) | the tool schema |
| Apps | `manage_apps` | | `references/apps.md` |

- Limits that change what you do: `browser_repl` `timeout_sec` is 1-150 (default 60; it terminates the REPL on timeout); `webmcp` `invoke` `timeout_sec` is 1-120 (default 60). Both from the docs, not run live. -> https://www.kernel.sh/docs/reference/mcp-server/tools/browser-repl, https://www.kernel.sh/docs/reference/mcp-server/tools/webmcp
- Do not retry `webmcp` invoke or `browser_repl` automatically after a transport failure (docs). A `browser_repl` timeout or crash terminates the REPL and clears its state, so re-check state first.
- Sessions can be addressed by name or ID, but pool release needs the ID (`session_id`), not the name (see `references/scale.md`).

## M7. Create, use, delete: leave nothing behind

**If** you create a browser through MCP -> **Do** pass a small `timeout_seconds` and a unique per-run tag (for example `{ run: "check-<random id>" }`, never a shared tag), set `headless: true` only for an unwatched check of an undefended site and leave `headless` unset when you need a replay or live view, and delete it with `manage_browsers delete` when done. Verify with `kernel browsers list --status active -o json`. -> **Avoid** relying on a parse of the create response to get the ID in a script, and relying on the timeout to clean up. -> **Source** verified live

- Verified live: create (headless, `timeout_seconds: 60`, tags) -> 200; it appeared in `kernel browsers list --status active --tag <key>=<value> -o json` while alive; MCP `delete` replied "browser session deleted successfully"; the list was then `[]`.
- Trap seen live: a client-side redaction of the create response (it masked a URL and swallowed an escaped quote) broke `JSON.parse`, no ID was saved, and the browser survived several minutes past its 60 s timeout until deleted by ID from `kernel browsers list`. If you lose the ID, list by your unique run tag, paginate that list to the end, and only then, for each candidate, confirm its tags hold this run's id (and that it was created after this run started) before deleting it by ID; never delete what a shared or generic tag matches, since it may be another worker's live browser.
- The create response contains the CDP URL and live view URL: these are credentials. Never print, log or paste them.

## M8. Inputs: use the nested forms

**If** you set proxy, project or network options on `manage_browsers` -> **Do** use the nested `proxy` object (`mode: direct|default`, `id`, `name`) and the schema's replacements. -> **Avoid** the flat aliases the server marks deprecated: `proxy_id` (use `proxy.id`), `proxy_routes` (use `network.proxy_routes`), `clear_proxy` (use `proxy.mode: default`), `disable_default_proxy` (use `proxy.mode: direct`), `project_id` (use `project`). The docs example for `manage_browsers` still shows `proxy_id` with no deprecation note: the live schema wins. -> **Source** verified live (43 deprecated-tagged properties across 23 tools)

## M9. Known unknowns

- Context cost in Claude Code is measured: the tools load deferred, about +1,040 tokens for a trivial prompt (ledger MC4).
- Whether Kernel OAuth passes a strict RFC 9207 issuer check: (unverified); the docs recommend an API key if it does not.
- MCP `manage_replays`, file read/download, and create/delete without `context`: (untested).

Verified live 2026-10-20 (Hobbyist plan); types re-checked on @onkernel/sdk 0.129.0. Evidence ledger: https://github.com/yigitkonur/plugin-kernel-sh/blob/main/verified-facts.md
