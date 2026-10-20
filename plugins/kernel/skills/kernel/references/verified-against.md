# What this plugin was verified against

Read when you suspect a reference is out of date and need to know what it was checked against.

| Item | Version or date |
|---|---|
| `@onkernel/sdk` | 0.127.0 (2026-10-16) |
| `kernel` CLI | 0.49.0 (2026-10-14) |
| Hosted MCP server | source commit 5c0e58b (2026-10-19) |
| Kernel docs | https://www.kernel.sh/docs (llms-full.txt), fetched 2026-10-20 |
| Live runs | 2026-10-20, Hobbyist plan, 23 probes (see each reference's "Verified in lab" box) |

Kernel ships every one to three days. Treat everything here as a snapshot: before relying on a name or limit, read the installed types (`node_modules/@onkernel/sdk`), `kernel <cmd> --help`, https://www.kernel.sh/docs/llms.txt, or ask the Kernel MCP `search_docs`. The plugin's weekly freshness job opens an issue when newer versions or new `@deprecated` tags appear.
