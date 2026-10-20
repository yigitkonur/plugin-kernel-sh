# What this plugin was verified against

Read when you suspect a reference is out of date and need to know what it was checked against.

| Item | Version or date |
|---|---|
| `@onkernel/sdk` | 0.128.0 (2026-10-19); lab probes ran on 0.127.0 and the 0.127 to 0.128 type diff was reviewed |
| `kernel` CLI | 0.49.0 (2026-10-14) |
| Hosted MCP server | source commit 5c0e58b (2026-10-19) |
| Kernel docs | https://www.kernel.sh/docs (llms-full.txt), fetched 2026-10-20 |
| Docs changelog, newest entry | October 16 |
| Live runs | 2026-10-20, Hobbyist plan, 23 probes (each reference ends with a "Verified live" footer; every row is in the evidence ledger) |

Kernel ships every one to three days. Treat everything here as a snapshot: before relying on a name or limit, read the installed types (`node_modules/@onkernel/sdk`), `kernel <cmd> --help`, https://www.kernel.sh/docs/llms.txt, or ask the Kernel MCP `search_docs`. The plugin's weekly freshness job opens an issue when newer versions or new `@deprecated` tags appear.
