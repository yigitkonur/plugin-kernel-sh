# Attribution

`test-kernel-bot-detection.ts` and `package.json` are copied from the official Kernel skills repository,
`plugins/kernel-cli/skills/profile-website-bot-detection/scripts/` (https://github.com/kernel/skills),
Copyright (c) 2025 Kernel, MIT License. Changes are listed below; in `package.json`, `@onkernel/sdk` is pinned to 0.128.0 and `playwright-core` to `^1.64.1` (the .ts file type-checks unchanged against them), and `package-lock.json` is added.

The complete MIT license text is in THIRD_PARTY_NOTICES.md at the plugin root (three directories up from this folder).

## Changes

Changes to `test-kernel-bot-detection.ts` (everything else is as upstream):
- The header comment names the file as modified.
- The CDP URL and live view URL are never logged or saved: the log prints `Live View: available`, and the report keeps only the session id, stealth, headless, creation time and a `liveViewAvailable` flag.
- Cookie values are not saved (the report keeps name, domain, vendor match and `valueLength`). Sensitive request and response header values (cookie, authorization, token-like, Kasada and DataDome headers) are replaced by `[redacted]`; `referer` and `location` values are cut to origin and path.
- Every URL that is logged or saved (requests, responses, vendor evidence, console messages, page errors, error output) is reduced to origin and path, with no query or fragment.
- Kasada IPS is reported only when the `/ips.js` response status matches the signature (429); other `/ips.js` responses are reported as a generic Kasada match.
- A Cloudflare challenge product (JS Challenge, Managed Challenge) is registered even when Cloudflare was already detected from another signal.
