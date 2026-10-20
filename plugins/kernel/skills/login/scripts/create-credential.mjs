#!/usr/bin/env node
// Create a Kernel credential from environment variables, so the password never appears on a command line
// (the `kernel credentials create` CLI only accepts --value name=value, which leaks into shell history and `ps`).
//
//   SITE_USER=... SITE_PASSWORD=... node create-credential.mjs <credential-name> <domain>
//
// Environment: KERNEL_API_KEY (required), SITE_USER and SITE_PASSWORD (required), SITE_TOTP_SECRET (optional,
// base32 or an otpauth:// URI), KERNEL_PROJECT (optional project id or exact name).
// Prints only the credential's id, name and domain. Needs Node 18+ (global fetch); no dependencies.
const [name, domain] = process.argv.slice(2);
const { KERNEL_API_KEY, SITE_USER, SITE_PASSWORD, SITE_TOTP_SECRET, KERNEL_PROJECT } = process.env;

const missing = [];
if (!name || !domain) missing.push('arguments <credential-name> <domain>');
if (!KERNEL_API_KEY) missing.push('KERNEL_API_KEY');
if (!SITE_USER) missing.push('SITE_USER');
if (!SITE_PASSWORD) missing.push('SITE_PASSWORD');
if (missing.length) {
  console.error(`create-credential: missing ${missing.join(', ')}`);
  process.exit(2);
}

const body = { name, domain, values: { username: SITE_USER, password: SITE_PASSWORD } };
if (SITE_TOTP_SECRET) body.totp_secret = SITE_TOTP_SECRET;

const headers = { Authorization: `Bearer ${KERNEL_API_KEY}`, 'Content-Type': 'application/json' };
if (KERNEL_PROJECT) headers['X-Kernel-Project'] = KERNEL_PROJECT;

let res;
try {
  res = await fetch('https://api.onkernel.com/credentials', { method: 'POST', headers, body: JSON.stringify(body), signal: AbortSignal.timeout(30_000) });
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
