#!/usr/bin/env node
// Create a Kernel credential from environment variables, so the password never appears on a command line
// (the `kernel credentials create` CLI only accepts --value name=value, which leaks into shell history and `ps`).
//
//   node --env-file=.env create-credential.mjs <credential-name> <domain>
//
// Put the variables below in a gitignored .env (or export them in your own shell before launching your agent).
// Do not use an inline `SITE_PASSWORD=... node ...` prefix: it lands in shell history and the tool transcript.
// Environment: KERNEL_API_KEY (required; export it or use node --env-file=<file>), SITE_USER and SITE_PASSWORD
// (required), SITE_TOTP_SECRET (optional, base32 or an otpauth:// URI), KERNEL_PROJECT (optional project id or
// exact name), KERNEL_BASE_URL (optional, like the SDK; default https://api.onkernel.com). Prints only id, name, domain and has_totp_secret. Needs Node 20.6+ for --env-file (18+ with exported
// variables; global fetch); no dependencies.
const [name, domain] = process.argv.slice(2);
const { KERNEL_API_KEY, SITE_USER, SITE_PASSWORD, SITE_TOTP_SECRET, KERNEL_PROJECT, KERNEL_BASE_URL } = process.env;
const base = (KERNEL_BASE_URL || 'https://api.onkernel.com').replace(/\/+$/, '');
let baseUrl;
try { baseUrl = new URL(base); } catch { baseUrl = null; }
// the key and the password travel in this request: never over cleartext (http is accepted for localhost only, for tests)
if (!baseUrl || !(baseUrl.protocol === 'https:' || (baseUrl.protocol === 'http:' && ['localhost', '127.0.0.1', '[::1]'].includes(baseUrl.hostname)))) {
  console.error('create-credential: KERNEL_BASE_URL must be an https URL');
  process.exit(2);
}

const missing = [];
if (!name || !domain) missing.push('arguments <credential-name> <domain>');
if (!KERNEL_API_KEY) missing.push('KERNEL_API_KEY');
if (!SITE_USER) missing.push('SITE_USER');
if (!SITE_PASSWORD) missing.push('SITE_PASSWORD');
if (missing.length) {
  console.error(`create-credential: missing ${missing.join(', ')}`
    + (KERNEL_API_KEY ? '' : ' (KERNEL_API_KEY: export KERNEL_API_KEY or use node --env-file=<file>)'));
  process.exit(2);
}

const body = { name, domain, values: { username: SITE_USER, password: SITE_PASSWORD } };
if (SITE_TOTP_SECRET) body.totp_secret = SITE_TOTP_SECRET;

const headers = { Authorization: `Bearer ${KERNEL_API_KEY}`, 'Content-Type': 'application/json' };
if (KERNEL_PROJECT) headers['X-Kernel-Project'] = KERNEL_PROJECT;

let res;
try {
  res = await fetch(`${base}/credentials`, { method: 'POST', headers, body: JSON.stringify(body), signal: AbortSignal.timeout(30_000) });
} catch (e) {
  console.error(`create-credential: request failed: ${e.name}`);
  process.exit(1);
}
const text = await res.text();
let json;
try { json = JSON.parse(text); } catch { json = {}; }
if (!res.ok) {
  // Print the status and Kernel's error code/message only; never echo the request.
  console.error(`create-credential: HTTP ${res.status} ${json.code ?? ''} ${json.message ?? ''}`.trim());
  process.exit(1);
}
console.log(JSON.stringify({ id: json.id, name: json.name, domain: json.domain, has_totp_secret: json.has_totp_secret }));
