# Vaults and payments: secrets reach the page, not the model

Read when a browser must log in or pay and the credential or card number must not pass through your code, your prompts or the model. Vaults are in preview (https://www.kernel.sh/docs/vaults/overview). Login-only tasks with Kernel running the whole login: `references/logins.md` (Managed Auth). Client options and retries: `references/sdk-client.md`. Showing the user the browser: `references/observe.md`.

Vault fill was verified live. **Payments were never run** (real money, real wallets): every payment rule below comes from the docs pages cited, not from a live test. Snippets marked `// untested` were not run.

## Pick the path

| If the task is... | Do | Source |
|---|---|---|
| A login your code drives (your navigation, your submit) | Credential item + `fill` (next section) | https://www.kernel.sh/docs/auth/fill-from-vault |
| A login Kernel should run, save and re-auth | Managed Auth, not vaults: `references/logins.md` | https://www.kernel.sh/docs/auth/managed-auth |
| The user keeps the login in their own 1Password | `provider: '1password'` item, `1pw_fill`; preview | https://www.kernel.sh/docs/vaults/1password |
| A merchant checkout paid with the user's wallet | Wallet + card items (Link or AgentCard), see "Payments" | https://www.kernel.sh/docs/browsers/payments |
| The agent should pay Kernel for a browser with no account | MPP, see last section; it is not a merchant checkout | https://www.kernel.sh/docs/info/mpp |
| Card data typed into a `credential` item | Never. Use `card` / `wallet` items | https://www.kernel.sh/docs/vaults/credentials |

## Vault fill (login) - verified live

**If** the page needs a stored username/password/TOTP and the model must never read it
**Do**
1. One vault per end user or access boundary: `kernel.vaults.upsert({ name })`. Attaching a vault gives the browser every item in it, including items added later.
2. Create the item with `kernel.vaults.items.upsert(key, { id_or_name, type: 'credential', spec: { provider: 'kernel', description, fields } })`. Keep secrets `sensitive: true` (the default). With no `value` the item is `pending_collection` with an `action.url` the user opens; poll `items.retrieve(key, { id_or_name, wait: 60 })` until `ready`.
3. Attach the vault when you create the browser: `browsers.create({ vaults: [{ id: vault.id }] })`. The binding is fixed for the browser's life. Up to 20 references; each takes `id` or `name` (attach by `name` was not run).
4. Navigate so the page is open at exactly the URL you will pass as `page_url`, retrieve the item, require a `fill` entry in `available_operations` (an array of `{ type, description }` objects, not strings: match on `.type`), then call `performOperation` with `type: 'fill'`, `browser_id: browser.session_id` (the session id, not a name), `page_url` and `fields: [{ field, selector }]`. Pass `{ maxRetries: 0, timeout: <ms> }`.
5. Submit only if the operation `status` is `completed` and every requested field is `filled` (not `failed`, `unknown` or `not_attempted`); otherwise stop. After a partial fill the page may hold written secrets: the trusted controller inspects only redacted page state (per field filled yes/no, never values) and returns just that to the agent. Then submit the form yourself and check the page for a logged-in signal.

```ts
// untested as written: adapted from a live run (names changed, trimmed). `username` and `password` are never literals in code:
// read them from the environment at run time (a throwaway account the user handed you; see references/logins.md and the
// /kernel:login skill), or omit `value` and let the user type them into the collection form (`action.url`, step 2).
const vault = await kernel.vaults.upsert({ name: 'user-12345' });
await kernel.vaults.items.upsert('portal-login', {
  id_or_name: vault.id,
  type: 'credential',
  spec: {
    provider: 'kernel',
    description: 'Account Portal', // site name only: it titles the collection form
    fields: [
      { name: 'username', type: 'text', required: true, sensitive: false, value: username },
      { name: 'password', type: 'password', required: true, sensitive: true, value: password },
    ],
  },
});
const browser = await kernel.browsers.create(
  { headless: true, timeout_seconds: 240, vaults: [{ id: vault.id }], tags: { run: process.env.RUN_ID ?? 'local' } },
  { maxRetries: 0, timeout: 30_000 });
try {
  // ... open the login page so its URL is exactly LOGIN ...
  const item = await kernel.vaults.items.retrieve('portal-login', { id_or_name: vault.id, wait: 60 });
  if (!('available_operations' in item) || !item.available_operations.some((o) => o.type === 'fill')) {
    throw new Error('fill is not advertised yet');   // each operation is { type, description }
  }
  const result = await kernel.vaults.items.performOperation('portal-login', {
    id_or_name: vault.id,
    type: 'fill',
    browser_id: browser.session_id,
    page_url: LOGIN,
    fields: [
      { field: 'username', selector: '#username' },
      { field: 'password', selector: '#password' },
    ],
  }, { maxRetries: 0, timeout: 40_000 });
  // result: { type: 'fill', status: 'completed', fields: [{ index: 0, status: 'filled' }, ...] }
  if (result.type !== 'fill' || result.status !== 'completed' || result.fields.length !== 2 || !result.fields.every((f) => f.status === 'filled')) {
    throw new Error('fill not fully completed: do not submit');   // failed / unknown / not_attempted: look at the page first
  }
  // ... only now submit the form, then check the page for a logged-in signal ...
} finally {
  await kernel.browsers.deleteByID(browser.session_id).catch((e) => {
    if (!(e instanceof Kernel.NotFoundError)) throw e;   // 404: the timeout already reaped it
  });
}
```

**Avoid**
- Treating `completed` as logged in. Verified live: after `completed` the URL stayed on `/login`, no flash message; `fill` writes fields and never submits. Check the page after you submit.
- Treating `fill` as isolation. Page scripts, extensions and an agent with CDP access can read the filled values. Your controller (not the model) must authorize `page_url` and selectors before every fill: a credential item has no destination allowlist.
- `sensitive: false` for anything secret. Verified live: a non-sensitive field's value comes back in `get` and `list`; sensitive fields show only `has_value: true`. Passwords and TOTP fields must be sensitive.
- Logging the `action.url` (collection link, 30 minute bearer link) or the filled values. Show the link only in the user's authenticated UI.
- Reading back the password field to "verify". If you must, report its length only (not in the ledger).
- Putting a vault on a pool: pool create has no vault parameter (`references/does-not-exist.md`).
- Vault count is capped per org (SDK doc comment: 3 on the free tier). Check `max_vaults` in `kernel org limits get -o json` before one vault per user at scale; delete item then vault when done (done live).

**Source** https://www.kernel.sh/docs/vaults/fill, https://www.kernel.sh/docs/vaults/credentials; verified live

### Fill errors: branch on the HTTP status and `code`

| Situation | Verified live | Do |
|---|---|---|
| `page_url` not an exact match of the open page (even `?x=1` added) | HTTP 400, `code: 'page_not_found'`, "no fields were written" | Open the page at the exact URL, retry once |
| Selector matches nothing | HTTP 400, `code: 'element_not_found'` | Fix the selector; password length on the page stayed 0 |
| `timeout_ms` too small (tested `1`) | HTTP 400, `code: 'timeout'`, nothing written | Raise `timeout_ms` (default 10000, max 30000, total not per field) |
| Failure after writing started | Docs: known execution failures can return HTTP 200 with `status: 'failed'` or `'unknown'`, with per-field `filled / failed / unknown / not_attempted`; whether this happens only after writing started is our inference from "earlier writes aren't rolled back" (unverified: not reproduced live) | Read the body, not just the status; earlier writes are not rolled back |

```ts
// error shape (verified live)
import Kernel, { APIError } from '@onkernel/sdk';
try { /* performOperation(...) */ } catch (e) {
  if (e instanceof APIError) console.log(e.status, JSON.stringify(e.error)); // 400 {code,message}
}
```

**Do** retry a fill only after looking at the page and never in a loop; `fill` never submits, so one retry is safe, and a `totp` field gets a fresh code. **Avoid** SDK default retries on this call (`performOperation` already sends `maxRetries: 0` in `@onkernel/sdk` 0.128.0 source (ref copy, `items.ts:178`); keep it explicit). **Source** https://www.kernel.sh/docs/vaults/fill, verified live.

### Rotating and importing values

- **If** your secrets live in another manager (AWS, Vault, etc.) **Do** read them in your trusted backend and pass them as `value` at `upsert`. This stores an encrypted copy in Kernel; it is not a live link, so update the item when the source changes and delete it when retention ends. Source https://www.kernel.sh/docs/vaults/existing-credential-vault (not run live).
- **If** a value changes **Do** `items.update(key, { id_or_name, type: 'credential', version, expected_item_id, spec: { fields: { password: { value } } } })`. A stale `version` returns 409: reload, do not resubmit blindly. Source https://www.kernel.sh/docs/vaults/credentials (not run live).
- A field's name, type and sensitivity cannot be edited in place. The SDK `update` takes `add_fields` and `remove_fields`: to change a field, remove it and add it again in the same update (the old value is deleted), or use a new item key for a different shape. A vault `totp` field always makes SHA1, 6-digit, 30 s codes; a different algorithm, digits or period needs a Managed Auth credential.

## 1Password (preview)

**If** the user keeps the login in their own non-shared 1Password vault **Do** create a `provider: '1password'` item, have the user approve each request in the 1Password app, then `1pw_fill` (the extension fills and submits). Offer it, and fall back to a `provider: 'kernel'` credential item if they decline or it fails. **Avoid** promising shared-vault items or passkeys (not supported), and auto-retrying `1pw_fill`: on `fill_unknown`, check the page. `1pw_create_access_request` needs no browser. **Source** https://www.kernel.sh/docs/vaults/1password, https://www.kernel.sh/docs/changelog (October 16). Not run live.

## Payments (docs only, not run)

Roles: your **controller** (trusted backend) verifies the purchase, authorizes selectors, shows hosted links to the user, and observes state. The **agent** drives the page. The **user** connects the wallet and approves. A **wallet** item is the provider connection; a **card** item is the payment material plus its authorization state. Source https://www.kernel.sh/docs/browsers/enable-payments-in-browser-agent

### P1 Any payment

**If** an agent will buy something
**Do**
1. Create the client with `maxRetries: 0` (`new Kernel({ projectID, maxRetries: 0 })`): `items.upsert` creates are retried by default.
2. Get merchant, amount (minor units), currency and cart contents from a trusted source (your order backend, or fixed-selector page extraction), compare them with what the agent proposed, show the verified values to the user, wait for explicit confirmation, then freeze that object. Derive the card spec and the authorize request only from it.
3. Create a headful browser with the vault attached; if the user may watch or step in, give the user the live view URL through your authenticated UI (`references/observe.md`).
4. Submit checkout once through the merchant's normal form.
5. Report success only when the merchant's order record shows a paid order matching the frozen merchant, amount, currency and items.

**Avoid**
- Retrying a failed, timed-out or indeterminate payment, or falling back from `fill` to aliases. Browser deletion, a timeout or a missing event does not cancel a payment.
- Trusting item `ready`, `payment_succeeded`, a completed `fill` or a success page as proof; they are supporting evidence only. No merchant record means report "indeterminate" and stop.
- Putting action URLs, OAuth codes, provider responses, API keys or `cdp_ws_url` in model context.
- Creating or authorizing a card from the agent's proposal alone.

Keep the vault id, card key, browser id and last event id until reconciled. **Source** https://www.kernel.sh/docs/browsers/enable-payments-in-browser-agent, https://www.kernel.sh/docs/browsers/payments

### Wallet setup (one wallet per provider per vault)

**If** the user connects a payment method
**Do** list the vault's items and group wallets by `spec.provider`: none -> offer to connect; `pending_authorization` -> resume the existing hosted action; `connected` -> reuse. Re-check immediately before creating. Wait for `connected` before preparing a purchase. Present the hosted action URL from your own authenticated endpoint (bound to user, vault, item; short TTL; our recommendation: `Cache-Control: no-store`, `Referrer-Policy: no-referrer`, as the docs require on the redirect response in https://www.kernel.sh/docs/browsers/enable-payments-in-browser-agent).
**Avoid** a second wallet under a different key (the API makes item keys unique, not providers); deleting a wallet (it invalidates its cards); letting the agent or its browser see the action URL.
**Source** https://www.kernel.sh/docs/integrations/wallets/overview

| Need | Provider | Notes |
|---|---|---|
| Pay with the user's Link wallet, a fresh approved credential per purchase | `link` | US phone number users only; live only; the SDK type says the amount is at most 50000 minor units (the docs page has been seen with a larger figure: check the SDK types before relying on a limit; payments are untested) |
| Pay with the user's real card, reusable, Face ID approval per checkout | `agentcard` | Needs a recognized processor request (Stripe, Shopify, Square, Recurly, Razorpay, Braintree, Worldpay, Bambora, Mercado Pago, and Adyen, which takes public dummy card fields and no vault aliases per the SDK doc); check mode (`test_mode`) against your `AGENTCARD_MODE` and stop on mismatch |

Choose by the lifecycle, not the merchant processor; only AgentCard's alias handoff depends on processor coverage.

### P2 Link

**If** paying with Link
**Do**
1. Put the browser on the **final** checkout page, then create the card item (`type: 'card'`, `spec: { provider: 'link', wallet, payment_method_id, amount, currency, merchant_name, merchant_url, context }`); `context` must be at least 100 characters; list methods via `wallet.expanded.payment_methods` (`expand: ['payment_methods']`) and let the user pick.
2. Retrieve the card, require an `authorize` entry in `available_operations` (match on `.type`), and after user approval call `performOperation` `{ type: 'authorize', browser_id, page_url }` with the checkout's exact current top-level https URL. Kernel picks a link pay token (Stripe checkouts that expose Link's agent tools; send no merchant fields) or a single-use virtual card elsewhere. CLI: `kernel vaults items invoke <vault> <key> authorize --browser-id <id> --page-url <url>`.
3. Wait for the card to be `ready` (`items.retrieve(key, { id_or_name, wait: 60 })`), require `fill` again just before use, and follow the operation's `description`. Pay token: send only `browser_id` and `page_url`. Virtual card: add `fields` mapping `number`, `expiration` (with `format: 'MM/YY'`), `cvc` to unique selectors. Continue only on `completed`, then submit once.

**Avoid**
- `expires_at` in the card spec: removed (changelog October 16); the card's `expires_at` is set by Link.
- `fill` on a different origin than the one you authorized at (403 `destination_denied`); a path change on the same origin is fine, but `page_url` must be the exact current page.
- Repeating `authorize` or creating a replacement card to retry an unknown purchase. After approval is requested, `authorize` only re-checks. After an authorize with a checkout, spec updates return 409: delete and recreate (only if no purchase may have happened).
- Inspecting or invoking the checkout's WebMCP tools yourself (Kernel does it during authorize and fill).
- Stripe adaptive pricing (https://www.kernel.sh/docs/browsers/enable-payments-in-browser-agent): build the spec from the active presentment amount and currency the user saw, not the base price.

Authorize errors that leave the card `requested` and safe to authorize again: `page_not_found` (open the checkout at exactly `page_url`), `ambiguous_page` (close extra tabs), `browser_not_found / browser_unavailable / destination_denied / timeout / browser_error` (browser exists in this project, has the vault, is not busy, checkout open in one tab).
**Source** https://www.kernel.sh/docs/integrations/wallets/stripe-link

### P3 AgentCard

**If** paying with AgentCard
**Do**
1. Create the agentcard card item from the verified purchase (`card_id` pins an enrolled card), wait for `ready`, read `state.aliases` (`number`, `cvc`, `exp_month`, `exp_year`) just before use.
2. **Start the observer before the agent submits**: loop `items.retrieve(key, { id_or_name, wait: 5 })` and `items.events(key, { id_or_name, after, wait: 5 })`; when `action.url` appears, show it to the user through your controller. Events return an ordered array; an empty array means nothing new, not failure; keep the last event `id` as `after`.
3. Keep the aliases (`number`, `cvc`, expiry) in the trusted controller; never hand them to the agent or model as task input or tool output. Inject them into the checkout fields from page-driving controller code (for example your own Playwright or CDP code selecting the card inputs) that does not return the values to the agent (untested: no payment was run). The agent only drives navigation and the submit. Let the merchant page's own submit create the request; Kernel holds the recognized request while the user approves, agentcard executes it, Kernel replays the response.
4. Where the processor row requires it (Square on the current deployment, Braintree, Worldpay, Bambora, Mercado Pago, Adyen), invoke `prepare_checkout` before submitting; an unprepared request is rejected.
5. Keep the observer running until the merchant reaches a terminal order state or your deadline; if the deadline passes, classify the attempt indeterminate and do not submit again.

**Avoid** invoking `authorize` (AgentCard does not advertise it), raw processor API calls instead of the page's own submission, caching aliases across expiry or state changes, and reading `ready` after the attempt as success: a declined or expired attempt can return the reusable card to `ready`. **Source** https://www.kernel.sh/docs/integrations/wallets/agentcard

### P4 `recovery_required`

**If** a card reports `recovery_required` (unresolved provider outcome)
**Do** stop. Surface it to a human with the vault id, card key, browser id and last event id. Reconcile against the provider and merchant.
**Avoid** deleting the card, wallet or vault (deletion is blocked and is not recovery), looping on `wait`, or authorizing again. There is no reset operation.
**Source** https://www.kernel.sh/docs/integrations/wallets/overview#payment-actions-and-recovery

### P5-P8 Provider configs, Visa cards, MPP

| If | Do | Avoid | Source |
|---|---|---|---|
| You need your own OAuth client for Link or AgentCard | Create a provider config (`kernel vault-provider-configs`, SDK `vaultProviderConfigs`) with an **org-scoped** key; pick exactly one config `id` or `name` per wallet | Project-scoped key (403); changing a bound config (immutable; new config means new wallets); deleting one still referenced (409). Default to Kernel-managed credentials | https://www.kernel.sh/docs/integrations/wallets/overview |
| Kernel-managed Visa cards (`provider: 'kernel'`) | Wallet enroll, purchase request, then report with `confirm_transaction`, recover with `restart_verification` (CLI and MCP; the SDK types also have the `kernel` card and wallet item specs and these two params; no flow was run) | Assuming the docs' Link/AgentCard checkout flow applies (nothing is documented beyond the changelog) | https://www.kernel.sh/docs/changelog (October 16) |
| The agent should buy a Kernel browser with no account | MPP: `curl -i -X POST https://api.onkernel.com/mpp/browsers` shows the `402` offer (docs only, not run); pay with Stripe's `link-cli mpp pay`; on a lost response retry with the **same** payment credential | Treating MPP as a merchant checkout (it buys browser access only, no vault); a second payment to recover an uncertain purchase; logging the returned `cdp_ws_url` | https://www.kernel.sh/docs/info/mpp |

## Operating notes

- Kernel docs say the order record decides success; give the agent no "success" signal of its own. Your controller reads the merchant.
- Observing from the terminal: `kernel vaults items get <vault> <key> --wait 60 -o json` and `kernel vaults items events <vault> <key> --wait 60 -o json`. Each `--wait` is one bounded observation, not a submit. `--open` opens hosted links: use it only in a human-operated terminal and keep its output away from the agent.
- CLI fill: `kernel vaults items invoke <vault> <key> fill --params '<json>'` or `--spec-file`; exits nonzero on `failed` or `unknown` but keeps the value-free result on stdout with `-o json`. (Not run live; flags read from CLI 0.49.0 source.)
- Do not use `kernel vaults items ...` output as proof of payment. Do not print `state` of wallets into model context.
- Not tested: the HTTP 200 per-field `failed / not_attempted` branch, attaching a vault by `name`, CLI `items invoke ... fill`, a non-editable fill target, TOTP fill, credential update, 1Password, hosted `collect` flow, provider configs, MPP, and every payment path (Link authorize/fill, AgentCard aliases and observer, `prepare_checkout`, `recovery_required`, Visa cards), which are docs-only because payments spend real money.

## Contradictions to know

- Known execution failures can return HTTP 200 with `failed` or `unknown`; validation errors before any write are 400/403/404/409 and nothing is written (the SDK `performOperation` doc comment says both). Verified live: `page_not_found`, `element_not_found` and `timeout` came back as HTTP 400 with `{ code, message }`. The 403, 404 and 409 cases are docs-only. Branch on both.

Verified live 2026-10-20 (Hobbyist plan); types re-checked on @onkernel/sdk 0.128.0. Evidence ledger: https://github.com/yigitkonur/plugin-kernel-sh/blob/main/verified-facts.md
