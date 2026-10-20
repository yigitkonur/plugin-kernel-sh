# API map: TypeScript SDK, REST, CLI, MCP

Read when you need the exact name of a Kernel method, flag, REST route or MCP tool, or to check whether something exists.
Names below were checked against `@onkernel/sdk` 0.127.0 and re-diffed against 0.128.0 (type definitions and source), `kernel` CLI 0.49.0 (`--help`) and the hosted MCP server source on 2026-10-20. The installed types in `node_modules/@onkernel/sdk` and `kernel <command> --help` always win over this file; if they disagree, trust them and say so.

Conventions that apply everywhere:
- REST base is `https://api.onkernel.com` with `Authorization: Bearer <key>`. The reference is https://www.kernel.sh/docs/api-reference and the spec is https://api.onkernel.com/spec.json.
- TS names differ from REST: fetch one record with `retrieve` (never `get`), delete a browser with `deleteByID` (there is no `browsers.delete`), and a browser id lives in `session_id` (the create response has no `id`).
- Most `{id_or_name}` routes take either; pool release needs the browser id.
- Offset-paged lists (`apps`, `deployments`, `invocations`, `projects`, `api-keys`, telemetry destinations, browsers, profiles) return a bare array over raw HTTP with `X-Has-More` and `X-Next-Offset` headers; the SDK wraps them in an async-iterable page (`for await`). Audit logs use `page_token` and `X-Next-Page-Token` instead.
- CLI: add `-o json` per command for raw API output. `kernel browsers delete` never prompts and has no `-y`; other destructive commands take `-y`.
- MCP tools are `mcp__plugin_kernel_kernel__<tool>` when installed through this plugin. Every call needs a `context` string (see `references/mcp.md`).

## Client (`new Kernel(options)`)

| Option | Default | Notes |
|---|---|---|
| `apiKey` | env `KERNEL_API_KEY`; throws if missing | |
| `projectID` | null | sent as `X-Kernel-Project-Id`; ID only |
| `project` | null | sent as `X-Kernel-Project`; ID or exact name |
| `environment` / `baseURL` | production / env `KERNEL_BASE_URL` | setting both throws |
| `timeout` | 60000 ms | per request |
| `maxRetries` | 2 | connection errors, 408, 409, 429, >=500, or `x-should-retry: true`; backoff 0.5 s doubling to 8 s; honors `Retry-After` |
| `fetch`, `fetchOptions`, `defaultHeaders`, `defaultQuery`, `logLevel`, `logger` | | `KERNEL_CUSTOM_HEADERS` (newline separated), `KERNEL_LOG` |

Other env vars the SDK reads: `KERNEL_SUPPRESS_BUN_WARNING`, `KERNEL_BROWSER_ROUTING_SUBRESOURCES`. It does not read `KERNEL_PROJECT` (the CLI does). It never sends an idempotency key (`idempotencyKey` is inert in 0.127.0), and retries POSTs, so a retried create can be duplicated: set `{ maxRetries: 0 }` per request for side-effecting calls and reconcile with `list`.

Errors (`Kernel.APIError` subclasses): 400 `BadRequestError`, 401 `AuthenticationError`, 403 `PermissionDeniedError`, 404 `NotFoundError`, 409 `ConflictError`, 422 `UnprocessableEntityError`, 429 `RateLimitError`, >=500 `InternalServerError` (this includes 529 capacity errors), plus `APIConnectionError`, `APIConnectionTimeoutError`, `APIUserAbortError`. 408 is a plain `APIError`. `error.headers` is a fetch `Headers`: read `error.headers?.get('x-request-id')`.

App framework (inside the same package): `kernel.app(name)` returns an app; `app.action(name, handler)` where the handler is `(ctx)` or `(ctx, payload)`; `KernelContext` is `{ invocation_id: string }`.

## Browsers

| Operation | TS | REST | CLI | MCP |
|---|---|---|---|---|
| create | `browsers.create(params)` | `POST /browsers` | `kernel browsers create` | `manage_browsers` create |
| get | `browsers.retrieve(idOrName, { include_deleted? })` | `GET /browsers/{id_or_name}` | `kernel browsers get <id> --include-deleted` | `manage_browsers` get |
| list | `browsers.list({ status, query, ... })` | `GET /browsers` | `kernel browsers list --status active --tag k=v` | `manage_browsers` list |
| update | `browsers.update(idOrName, params)` | `PATCH /browsers/{id_or_name}` | `kernel browsers update` | `manage_browsers` update |
| delete | `browsers.deleteByID(idOrName)` | `DELETE /browsers/{id_or_name}` | `kernel browsers delete <id-or-name> [more...]` | `manage_browsers` delete |
| run Playwright code | `browsers.playwright.execute(id, { code, timeout_sec?, executor? })` | `POST .../playwright/execute` | `kernel browsers playwright execute <id> [code]` | `execute_playwright_code` |
| executors | `browsers.playwright.executors.list(id)`, `.delete(name, { id_or_name, close_tab? })` | `GET/DELETE .../playwright/executors[/{name}]` | `kernel browsers playwright executors list\|delete` | `manage_playwright_executors` |
| computer controls | `browsers.computer.{batch, captureScreenshot, clickMouse, dragMouse, getMousePosition, moveMouse, pressKey, readClipboard, scroll, setCursorVisibility, typeText, writeClipboard}` | `POST .../computer/{batch, screenshot, click_mouse, drag_mouse, get_mouse_position, move_mouse, press_key, clipboard/read, scroll, cursor, type, clipboard/write}` | `kernel browsers computer <verb>` (`press-key`, `type`, `screenshot`, ...) | `computer_action` |
| REPL | `browsers.repl(id, { code, reset? })` | `POST .../repl` | `kernel browsers repl <id> [code]` | `browser_repl` |
| WebMCP | `browsers.webmcp.listTools(id, { exclude_custom? })`, `.invokeTool(id, { tool_ref, input, timeout_sec? })`, `.customTools.list\|add\|remove` | `GET .../webmcp/tools`, `POST .../webmcp/invoke`, `.../webmcp/custom-tools` | `kernel browsers webmcp list\|invoke\|custom-tools` | `webmcp` |
| files | `browsers.fs.{createDirectory, deleteDirectory, deleteFile, downloadDirZip, fileInfo, listFiles, move, readFile, setFilePermissions, upload, uploadZip, writeFile}`, `browsers.fs.watch.{start, events, stop}` | `.../fs/*` | `kernel browsers fs <verb>` | `manage_browser_files` |
| processes | `browsers.process.{exec, spawn, status, stdin, stdoutStream, kill, resize}` | `.../process/*` | `kernel browsers process <verb>` | `exec_command` |
| HTTP through the browser | `browsers.curl(id, params)`, `browsers.fetch(...)` (posts to the browser's own `/curl/raw` route) | `POST .../curl` | `kernel browsers curl <id> <url>` | `browser_curl` |
| logs | `browsers.logs.stream(id, { source, ... })` (SSE) | `GET .../logs/stream` | `kernel browsers logs stream <id>` | none |
| replays | `browsers.replays.list(id)`, `.start(id, body?)`, `.stop(replayID, { id_or_name })`, `.download(replayID, { id_or_name })` returns a fetch `Response` | `GET/POST .../replays`, `POST .../replays/{replay_id}/stop`, `GET .../replays/{replay_id}` | `kernel browsers replays list\|start\|stop\|download` | `manage_replays` |
| telemetry | `browsers.telemetry.events(id, { category[], type[], since, until, order, limit, offset })`, `.stream(id, { replay?, type[], 'Last-Event-ID'? })` (SSE) | `GET .../telemetry/events`, `GET .../telemetry/stream` | `kernel browsers telemetry events\|stream` (`--categories`, `--types`, `--since`, `--until`, `--order`, `--limit`, `--offset`, `--all`; stream adds `--replay`, `--seq`) | `manage_browsers` get_telemetry |
| extensions at runtime | `browsers.loadExtensions(id, body)` (multipart) | `POST .../extensions` | `kernel browsers extensions` | none |

Shapes you will branch on:
- Create response (30 properties). Always present: `cdp_ws_url`, `created_at`, `headless`, `memory`, `region`, `session_id`, `stealth`, `timeout_seconds`, `webdriver_ws_url`. Optional: `base_url`, `browser_live_view_url`, `chrome_policy`, `deleted_at`, `gpu`, `kiosk_mode`, `name`, `network`, `pool`, `profile`, `profile_save_changes`, `proxy`, `start_url`, `tags`, `telemetry`, `usage`, `usage_status`, `vaults`, `video_memory`, `viewport` (and deprecated `proxy_id`). Verified live: a headless create returned no `browser_live_view_url` (`references/browsers.md`).
- `playwright.execute` response: `success`, optional `result`, `error`, `stderr`, `stdout`, `tab`. A thrown error inside your code gives HTTP 200 with `success: false`, so check `success`.
- `ExecutorLimitError` is a response interface `{ executors, message }` returned when a call would exceed the per-browser executor limit (documented as HTTP 409).
- `computer.pressKey` takes `{ keys: string[], duration?, hold_keys? }`, not a single string. `computer.typeText` takes `{ text, delay? }` only: the docs mention `smooth` and `typo_chance`, but neither the 0.127.0 types, the REST page nor the CLI have them.
- 0.128.0 added `location` on browsers: the create response always carries `{ locale, locale_source, timezone, timezone_source }` (`'metro'` = default for the browser's region); a request override `location: { locale?, timezone? }` is gated per organization (a 400 "browser location is not enabled for this organization" otherwise). It also added allowlist fencing: `network.allowed_hosts` updates can carry `expected_allowlist_revision` plus a unique `mutation_id` (read `network.allowlist_state.revision` first); a stale revision returns 409 `stale_network`; reuse both values when retrying an uncertain update.
- Deprecated on browsers: `proxy_id` (use `proxy`), `disable_default_proxy` (use `proxy.mode`). `proxy` is `{ id?, name?, mode?: 'direct' | 'default' }`. Telemetry events `captcha_type` is deprecated for `captcha_provider` (and `task_kind`).

## Profiles, pools, proxies, extensions

| Operation | TS | REST | CLI | MCP |
|---|---|---|---|---|
| profiles | `profiles.{create, retrieve, update, list, delete, download}` | `/profiles`, `/profiles/{id_or_name}`, `.../download` | `kernel profiles create\|get\|update\|list\|delete\|download --to` | `manage_profiles` |
| pools | `browserPools.{create, retrieve, update, list, delete, acquire, release, flush}` | `/browser_pools`, `.../{id_or_name}`, `POST .../acquire\|release\|flush` | `kernel browser-pools create\|get\|update\|list\|delete\|acquire\|release\|flush` | `manage_browser_pools` |
| proxies | `proxies.{create, retrieve(idOrName), update(idOrName), list, delete, check}` | `/proxies`, `POST /proxies/{id}/check` | `kernel proxies create\|get\|update\|list\|delete\|check` | `manage_proxies` |
| extensions | `extensions.{upload, list, get, download, downloadFromChromeStore, delete}` | `/extensions`, `/extensions/{id_or_name}`, `.../metadata`, `/extensions/from_chrome_store` | `kernel extensions list\|get\|upload\|download\|download-web-store\|delete` | `manage_extensions` |

- `profiles.update` only renames (`name` required).
- Pool create requires `size`; also `fill_rate_per_minute`, `timeout_seconds`, `profile`, `proxy_id`, `region`, `network`, `headless`, `stealth`, `memory`, `viewport`, `telemetry`, `extensions`. Update adds `discard_all_idle` and `expected_network`. `acquire` returns `null` on HTTP 204 (no browser ready: retry until your deadline). `release(id, { session_id, reuse? })`: `reuse` defaults to true; a browser loaded with an acquire-time profile is always destroyed. `delete(id, { force? })`. Pool config uses `proxy_id` (valid on pools; there is no `proxy` object on the pool config).
- `proxies.create` `type` is `'isp' | 'residential' | 'mobile' | 'custom'` (no `datacenter`), with `config` per type, `protocol: 'http' | 'https'` and `bypass_hosts`. Custom takes `host`, `port`, `username`, `password`, `ca_bundle`. `proxies.check(id, { url? })` only takes http(s) URLs that resolve to a public IP.

## Auth, credentials, vaults

| Operation | TS | REST | CLI | MCP |
|---|---|---|---|---|
| managed auth | `auth.connections.{create, retrieve, update, list, delete, login, follow, submit, timeline}` | `/auth/connections`, `.../{id}/login\|events\|submit\|timeline` | `kernel auth connections create\|get\|update\|list\|delete\|login\|follow\|submit\|timeline` | `manage_auth_connections`, `begin_auth_login`, `open_auth_login` |
| who am I | `auth.context.retrieve()` | `GET /auth/context` | `kernel auth context` | `get_connection_context` |
| credentials | `credentials.{create, retrieve, update, list, delete, totpCode}` | `/credentials`, `.../{id}/totp-code` | `kernel credentials create\|get\|update\|list\|delete\|totp-code` | `manage_credentials`, `manage_vault_credentials` |
| credential providers | `credentialProviders.{create, retrieve, update, list, delete, listItems, test}` | `/org/credential_providers` | `kernel credential-providers ...` | `manage_credential_providers` |
| vault provider configs | `vaultProviderConfigs.{create, retrieve, update, list, delete}` | `/vault-provider-configs` | `kernel vault-provider-configs ...` | `manage_vault_provider_configs` |
| vaults | `vaults.{upsert, retrieve, list, delete, retrieveEncryptionKey}` | `/vaults`, `.../encryption_key` | `kernel vaults create\|get\|list\|delete\|get-encryption-key` | `manage_vaults` |
| vault items | `vaults.items.{upsert, retrieve, list, update, delete, events, performOperation}` | `PUT /vaults/{v}/items/{key}`, `POST .../items/{key}/operations` | `kernel vaults items ...`, `kernel vaults invoke` | `manage_vault_items`, `manage_vault_cards`, `manage_vault_wallets` |
| config registry | `configRegistry.{list, lookup, resolve}`, `configRegistry.analyses.{retrieve, list, cancel, waitForResult}` | `/config-registry`, `/config-registry/{lookup,resolve}`, `.../analyses/{id}` | none (`kernel search` is web search, not this) | `manage_config_registry` |
| web search | `search.{create, retrieve}`, `search.contents.fetch`, `search.providers.list` | `/search` | `kernel search [query]` | `web_search` (entitlement-gated) |

- Managed auth create: `domain` and `profile_name` required (the profile is created if missing); optional `credential` (`name`, `provider`, `path`, `auto`), `health_checks`, `health_check_interval`, `auto_reauth`, and a nested `browser` config (`proxy`, `telemetry`). Top-level `proxy` and `browser_telemetry` are deprecated for `browser.proxy` / `browser.telemetry`. A duplicate create returns 409; the MCP code reads `existing_id` from that body.
- `auth.connections.login(id)` returns `{ id, flow_expires_at, flow_type: 'LOGIN' | 'REAUTH', hosted_url, handoff_code?, live_view_url? }`. `follow(id)` streams `managed_auth_state` events with `flow_status` (`IN_PROGRESS`, `SUCCESS`, `FAILED`, `EXPIRED`, `CANCELED`), `flow_step` (`DISCOVERING`, `AWAITING_INPUT`, `AWAITING_EXTERNAL_ACTION`, `SUBMITTING`, `COMPLETED`), and a free-string `error_code`, plus `error` and heartbeat events. The connection itself has `status: 'AUTHENTICATED' | 'NEEDS_AUTH'`.
- `credentials.create`: `domain`, `name`, `values` (string map) required; optional `sso_provider`, `totp_secret` (base32 or an `otpauth://` URI), `totp_algorithm` (`SHA1` | `SHA256` | `SHA512`), `totp_digits`, `totp_period`. Passkeys exist only as a vault credential field type.
- Vault item types: `credential`, `credential_account`, `card`, `wallet`. `performOperation` types: `fill`, `authorize`, `prepare_checkout`, `collect`, `confirm_transaction`, `restart_verification`, `webmcp_invoke`, and 1Password access-request operations. `fill` params: `browser_id` (required), `fields[]` (`{ field, selector, format? }`), `page_url`, `timeout_ms`.
- `configRegistry.lookup({ url, allowed_proxy_countries? })`, `.resolve({ url, intent?, allowed_proxy_countries? })` (intent needs an https target), `.analyses.waitForResult(id, { pollIntervalMs?, maxWaitMs? })`; a timeout does not cancel the remote analysis.
- Deprecated: `ResidentialProxyConfig.os`, `search.goggles_id` (use `goggles`), 1Password item `website` (use `requests`), `ManagedAuth.last_auth_at` (use `last_auth_check_at`).

## Apps, org, account

| Operation | TS | REST | CLI | MCP |
|---|---|---|---|---|
| deploy | `deployments.create(...)` (multipart: `entrypoint_rel_path`, `env_vars`, `file`, `force`, `region`, `source`, `version`), `.retrieve`, `.list`, `.delete`, `.follow(id)` (SSE) | `POST /deployments`, `.../{id}/events` | `kernel deploy <entrypoint>`, `kernel deploy get\|history\|logs\|delete` | `manage_apps` (no deploy action) |
| invoke | `invocations.create({ app_name, action_name, version, payload?, async?, async_timeout_seconds? })`, `.retrieve`, `.follow(id, { since? })`, `.update(id, { status, output? })`, `.list`, `.listBrowsers`, `.deleteBrowsers` | `POST /invocations`, `GET /invocations/{id}/events`, `PATCH /invocations/{id}` | `kernel invoke <app> <action>`, `kernel invoke get\|update\|history\|browsers\|delete-browsers`, `kernel logs <app>` | `manage_apps` (invoke, get invocation, list) |
| apps | `apps.list()` only (apps are created by deploying) | `GET /apps` | `kernel app list\|delete` | `manage_apps` |
| org | `organization.entitlements.retrieve()`, `organization.limits.retrieve()`, `.update(...)` | `GET /org/entitlements`, `GET/PATCH /org/limits` | `kernel org entitlements`, `kernel org limits get\|set` | none (entitlements gate tools) |
| projects | `projects.{create, retrieve, update, list, delete}`, `projects.limits.{retrieve, update}` | `/org/projects`, `.../{id_or_name}`, `.../limits` | `kernel projects create\|get\|update\|list\|delete`, `kernel projects limits get\|set` | `manage_projects` |
| API keys | `apiKeys.{create, retrieve, update, list, delete, rotate}` | `/org/api_keys`, `POST .../{id}/rotate` | `kernel api-keys create\|get\|update\|list\|delete\|rotate` | `manage_api_keys` |
| audit logs | `auditLogs.list({ start, end, page_token? })`, export destinations (S3) | `GET /audit-logs`, `/audit-logs/export/*` | `kernel audit-logs search\|download\|export ...` | none |
| telemetry export | `telemetry.destinations.{create, retrieve, update, list, delete}` | `/telemetry/destinations` | `kernel telemetry destinations create\|get\|update\|list\|delete` | none |

- `invocations.create`: `payload` is a JSON string; async returns status `queued` and `async_timeout_seconds` is 10 to 3600. `invocations.update` takes `status: 'succeeded' | 'failed'`; `failed` cancels the run and reaps its tagged browsers. The CLI `kernel invoke` is async by default (`-s`/`--sync` to wait).
- `deployments`: status is `queued | in_progress | running | failed | stopped`. Deployments with `force` replace a same-version deploy.
- `apiKeys.create`: `name`; optional `days_to_expire` or `expires_at` (not both), `project_id`, and `policy: { statements: [{ action, resource }] }` (resource `projects/{project_id}/{kind}/{id}`, wildcards allowed). The CLI `api-keys create` has `--name`, `--days-to-expire`, `--project-id` and no policy flag. A project-scoped key is a different thing from the SDK `project` option.
- `organization.limits.retrieve()` returns `max_concurrent_sessions`, `concurrent_sessions_used`, `concurrent_sessions_available`, `max_auth_connections`, `auth_connections_used`, `max_vaults`, `vaults_used`, `min_health_check_interval_seconds`. `max_pooled_sessions` is gone (a request that sets it returns 400).
- Audit logs need a Start-Up or Enterprise plan: a Hobbyist key gets `Insufficient_plan` (verified live).

## MCP tool names (34 in source, 0.127.0 era)

`begin_auth_login`, `browser_curl`, `browser_repl`, `computer_action`, `exec_command`, `execute_playwright_code`, `get_connection_context`, `get_more_tools`, `manage_api_keys`, `manage_apps`, `manage_auth_connections`, `manage_browser_files`, `manage_browser_pools`, `manage_browsers`, `manage_config_registry`, `manage_credential_providers`, `manage_credentials`, `manage_extensions`, `manage_playwright_executors`, `manage_profiles`, `manage_projects`, `manage_proxies`, `manage_replays`, `manage_vault_cards`, `manage_vault_credentials`, `manage_vault_items`, `manage_vault_provider_configs`, `manage_vault_wallets`, `manage_vaults`, `open_auth_login`, `search_docs`, `submit_feedback`, `web_search`, `webmcp`.

Only the vault and search tools are gated by entitlement; the server fetches `/org/entitlements` once (5 s timeout) and hides them if that fails. Never hard-code a tool count: the visible list depends on entitlements and the server's tool-loading mode.

## Names that do not exist

See `references/does-not-exist.md`. The usual hallucinations: `browsers.delete`, `browsers.get`, `apps.create`, `kernel auth status`, `kernel create` templates not in `kernel create --help`.

## Verified live

Checked against `@onkernel/sdk` 0.127.0 types and source (0.128.0 diff reviewed), `kernel` CLI 0.49.0 `--help`, MCP server source at commit 5c0e58b. Live checks so far: `browsers.create/retrieve/deleteByID`, `playwright.execute` shapes, `auth context`, audit-log gating. Not yet verified live and marked as such where used: REST routes for most resources, MCP tool behavior beyond `initialize`.

Verified live 2026-10-20 (Hobbyist plan); types re-checked on @onkernel/sdk 0.128.0. Evidence ledger: verified-facts.md in the plugin repository.
