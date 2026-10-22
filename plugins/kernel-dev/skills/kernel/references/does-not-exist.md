# Things that do not exist (or no longer do)

Read when you are about to use a Kernel method, flag, feature or page from memory and are not sure it is real. Agents hallucinate these; the table says what to use instead. When in doubt check `references/api-map.md`, the installed types, or `kernel <cmd> --help`.

| If you were about to use... | It does not exist because... | Use instead | Source |
|---|---|---|---|
| `persistent: true`, `persistence: { id }`, `--persistent-id` (persistent browsers) | Removed 2026-05-21. Browsers are disposable. | `profile: { name, save_changes: true }` on exactly one browser, plus `timeout_seconds` | https://www.kernel.sh/docs/changelog |
| `kernel.agents.auth.*`, `kernel agents auth` | Removed in SDK 0.33.0 / CLI 0.14.8 | `kernel.auth.connections.*`, `kernel auth connections` | https://github.com/kernel/kernel-node-sdk/blob/main/CHANGELOG.md |
| `proxies.create({ type: 'datacenter' })`, `--type datacenter` | Removed from the CLI and generated SDKs; existing configs keep working | `type: 'isp'` (start there), `'residential'`, `'mobile'`, `'custom'` | https://www.kernel.sh/docs/changelog |
| `max_pooled_sessions` | Deprecated: still in the 0.128.0 and 0.129.0 types and `kernel projects limits set --help`, but the API rejects it with 400 | `max_concurrent_sessions` (pooled browsers count toward it) | https://www.kernel.sh/docs/changelog |
| `kernel.browsers.delete(id)`, `kernel.browsers.get(id)` | TS names differ from REST | `browsers.deleteByID(id)`, `browsers.retrieve(id)` | `references/api-map.md` |
| `kernel.apps.create(...)` | Apps are created by deploying | `kernel deploy`, `deployments.create` | https://www.kernel.sh/docs/apps/deploy |
| `proxy_id` or `disable_default_proxy` on browsers | Deprecated | `proxy: { id }` / `proxy: { mode: 'direct' }` (`proxy_id` is still correct on pools) | `references/unblock.md` |
| `captcha_type` in telemetry events | Deprecated | `captcha_provider` and `task_kind` | https://www.kernel.sh/docs/browsers/telemetry/categories |
| `computer.typeText({ smooth, typo_chance })` | Documented, but absent from the 0.127.0 to 0.129.0 types, REST page and CLI; the live API accepted them (ledger P07.9) | `typeText({ text, delay })` for typed code; a cast if you need the extras | `references/api-map.md` |
| `kernel auth status`, `kernel auth whoami`, `kernel auth token` | No such subcommands (`kernel auth` alone prints the login state) | `kernel auth context -o json` for the effective org, project and credential | https://www.kernel.sh/docs/reference/cli |
| `kernel` CLI command for the config registry | None exists; `kernel search` is web search | `kernel.configRegistry.lookup/resolve` (SDK) or the `manage_config_registry` MCP tool | `references/api-map.md` |
| MCP `manage_apps` deploy, or updating an invocation | Not offered by the MCP tool | `kernel deploy` and `kernel invoke update` (CLI) or the SDK | `references/mcp.md` |
| A spending-cap API | Caps are dashboard-only | Set the cap in the dashboard; read limits with `kernel org limits get` | https://www.kernel.sh/docs/info/spending-caps |
| `Idempotency-Key` / `idempotencyKey` protecting a retried create | The SDK never sends it in 0.127.0 to 0.129.0 | `{ maxRetries: 0 }` plus tags and `list` to reconcile | `references/sdk-client.md` |
| `browser.profile.origins` | A proposal in the docs, not an API | Load a whole profile | https://www.kernel.sh/docs/testing/profile-loading-performance |
| An hCaptcha guide page | The docs URL redirects to the stealth page | `references/unblock.md` | https://www.kernel.sh/docs/browsers/bot-detection/stealth |
| `kernel create` templates named `playwright`, `bare`, `cua`, `magnitude`, `computer-use` | Not in 0.49.0 | Run `kernel create --help`; TypeScript templates today: `sample-app`, `captcha-solver`, `anthropic-computer-use`, `openai-computer-use`, `gemini-computer-use`, `stagehand`, `claude-agent-sdk`, `yutori`, `tzafon` | https://github.com/kernel/cli (pkg/create/templates.go) |
| `@onkernel/hypeman` as a Kernel browser package | A different product | `@onkernel/sdk` | npm |
| A `vaults` parameter on pool create | Pool create has no vault parameter in the 0.127.0 types or the CLI | Attach vaults at `browsers.create` only; pool acquire takes no vault parameter (0.129.0 types, `kernel browser-pools acquire --help`) | `kernel browser-pools create --help` |

Do not "fix" these: the npm scope `@onkernel/*`, `api.onkernel.com`, `mcp.onkernel.com`, and the `kernel/tap` Homebrew tap are current names.
