# Unblock: when a site blocks, challenges or throttles you

Read this when a page returns a challenge, a 403/502, a captcha, or a login that keeps failing from Kernel. Work the ladder in order and stop at the first rung that holds; each rung costs more than the last. `kernel org entitlements -o json` tells you which rungs your plan has (flags in `references/api-map.md`).

All code assumes `import Kernel from '@onkernel/sdk'` and `const kernel = new Kernel()` (key from `KERNEL_API_KEY`).

## Baseline before any block

**If** the task says "look as human as possible" or the site is known to defend itself -> **Do** set this up front, before any block appears:
- headful (the default), the default viewport, and a start at the home page, not a deep link;
- `stealth: true` (shared ISP proxy plus captcha solver, section 3);
- a managed proxy of your own only when the site needs a geo or a residential reputation (sections 5 and 6);
- verify against the site itself (does the real flow complete?), not a fingerprint page: stealth showed no measurable difference on bot.sannysoft.com.

## 1. New target site: ask the registry before guessing

**If** you are about to automate a site you have not run before -> **Do** (1) open it by hand in a dashboard browser and click through the flow you plan to automate; (2) `kernel.configRegistry.lookup({ url })`; (3) if `recommendation` is null, `resolve({ url, intent })` then `analyses.waitForResult(id, { maxWaitMs })`; (4) create the recommended managed proxy through `kernel.proxies` **once** (look it up by name first), store its id, pass it to `browsers.create`. -> **Avoid** guessing flags; re-running the setup (every run creates another proxy); reading a null `recommendation` as "site unreachable" (it means "no answer yet"); sending URLs with secrets, signed links or GET-triggered actions. -> **Source** https://www.kernel.sh/docs/config-registry.

```ts
const { recommendation } = await kernel.configRegistry.lookup({ url: 'https://www.google.com/recaptcha/api2/demo' });
if (recommendation?.type === 'recommendation') {
  // recommendation.browser spreads into browsers.create (keys seen live: gpu, headless, stealth, viewport)
  // recommendation.proxy.mode is 'managed' (then create or retrieve a proxy through kernel.proxies, e.g. proxies.list({ name })
  // then proxies.create, and pass its id as browsers.create({ proxy: { id } })) or direct
}
```

```ts
// Only when lookup returned null. Budget minutes: the analysis for bot.sannysoft.com took a few minutes.
const started = await kernel.configRegistry.resolve({ url: 'https://bot.sannysoft.com' });
const result = await kernel.configRegistry.analyses.waitForResult(started.analysis!.id, { maxWaitMs: 420_000 });
console.log(result.analysis?.status, result.recommendation?.type, Boolean(result.guidance));
```

- A wait timeout stops waiting; it does not cancel the analysis. Terminal statuses: `completed`, `failed`, `canceled`, `expired`.
- Judge a recommendation by its evidence (success rate, sample size, last observed), not by its existence. `guidance` can be useful even when nothing worked.
- Add `intent` (a sentence or two; the target url must be https) when the first page loading is not enough; add `allowed_proxy_countries` when the workload must exit from specific countries.
- Hobbyist plan and up. Verified live: lookup for bot.sannysoft.com returned null; for the reCAPTCHA demo it returned a recommendation with a managed proxy and 1 working configuration.

## 2. Blocked: the escalation ladder

**If** a site challenges or blocks you -> **Do** go down this list and re-test after each step:

| Step | Change | Why / when |
|---|---|---|
| 1 | Headful, default viewport, start at the home page and click through | Cheapest; common causes are a deep link, a headless flag or a custom viewport |
| 2 | `stealth: true` | Adds the shared ISP proxy and the captcha solver (section 3) |
| 3 | A profile plus the same dedicated ISP proxy every run, or a pool | Returning-user signal; stable IP (sections 5 and 6) |
| 4 | Residential proxy | Geo needs, or fingerprint-heavy vendors where the network layer is not the main signal |
| 5 | GPU browser (`gpu: true`, headful) | Sites that cross-check canvas/WebGL against the claimed GPU. Plan-gated (below) |
| 6 | Mobile proxy | Advanced stealth cases only |
| 7 | Web Bot Auth | Sites that honor signed bot identities (section 13) |

**Avoid** headless on defended sites; overriding user-agent or headers; extra extensions (each adds a detectable fingerprint); deep links straight to a login page; bursts of parallel sessions from one IP; self-hosted Playwright when `playwright.execute` works. **Source** https://www.kernel.sh/docs/browsers/bot-detection/overview, https://www.kernel.sh/docs/browsers/bot-detection/stealth.

- GPU on Hobbyist: `browsers.create({ gpu: true, headless: false })` returned 403 `insufficient_plan` ("GPU acceleration requires an active paid Start-Up or Enterprise plan"); `gpu: true` with `headless: true` is a 400 first. Nothing was created either way.
- Rate matters as much as config: many sites score request frequency, so pace actions instead of escalating a rung for a throttle problem.

## 3. What `stealth` and `proxy` each change

**If** you wonder what a flag does -> **Do** use this table (create response verified live):

| Create params | Egress | Captcha solver | `browser.proxy` in response |
|---|---|---|---|
| `{}` (non-stealth) | Direct (SDK types) | No | (unverified: not captured) |
| `{ stealth: true }` | Shared ISP pool IP, static for that session, may differ next session | Yes | `{ mode: 'default' }` |
| `{ proxy: { mode: 'direct' } }` | Direct | No | `{ mode: 'direct' }` |
| `{ stealth: true, proxy: { id } }` | Your proxy | Yes (SDK types) | `{ id }` |
| `{ proxy: { id } }` | Your proxy | No | `{ id }` |

- The anti-detection Chromium baseline is on for every browser. `stealth` adds the proxy and the solver; `proxy` changes egress only and never toggles the solver.
- Egress seen live: the stealth default gave a different IP in each of three sessions; `proxy: { mode: 'direct' }` gave yet another; `proxy: { id }` gave exactly the proxy's `ip_address`.
- **Avoid** assuming stealth removes bot detection by itself: a live test could not show a fingerprint difference on bot.sannysoft.com between stealth and non-stealth (the page exposes no failed rows, so that evidence is weak both ways). Test your real target.
- **Source** `BrowserProxyConfig` in the installed SDK types, https://www.kernel.sh/docs/browsers/bot-detection/stealth.

## 4. Fair test of stealth vs normal

**If** you compare stealth against non-stealth (or `/kernel:profile-site`) -> **Do** control the network: either run both on the same explicit proxy (`proxy: { id }` on both), or run both direct (`stealth: true` plus `proxy: { mode: 'direct' }` against `{}`), and say which design you used. **Avoid** comparing stealth-with-ISP-proxy against plain-direct and crediting stealth: a live test showed those two differ in egress IP as well as in stealth. **Source** verified live; `kernel-cli` profile-website-bot-detection skill.

```ts
// stealth with direct egress (solver kept, per SDK types) -- untested live (unverified: stealth + direct was not run)
const b = await kernel.browsers.create({ stealth: true, proxy: { mode: 'direct' } });
```

## 5. Logins and IP allowlists: a dedicated ISP proxy

**If** the account logs in, a site allowlists your IP, or a session must keep the same IP across runs -> **Do** create one ISP proxy, read its `ip_address`, and select it on every browser. ISP proxies keep one static exit IP across sessions. -> **Avoid** relying on the stealth pool IP across sessions (it can change); creating a new proxy per run (it clutters the project; look it up by name instead). -> **Source** https://www.kernel.sh/docs/proxies/isp.

```ts
const NAME = 'my-site-isp';
let proxy: { id?: string } | undefined;
// fail closed: do not catch here. A list error (including a key without list permission) must stop the run, never fall through to create.
for await (const p of kernel.proxies.list({ name: NAME })) { if (p.type === 'isp') { proxy = p; break; } } // names are not unique: reuse only an ISP match
proxy ??= await kernel.proxies.create({ type: 'isp', name: NAME }, { maxRetries: 0, timeout: 30_000 }); // only when absent; country defaults to US
const proxyId = proxy.id!;                                // typed optional in the response
const checked = await kernel.proxies.check(proxyId);      // returns the proxy: ip_address, status 'available'
const browser = await kernel.browsers.create(
  { proxy: { id: proxyId }, tags: { run: process.env.RUN_ID ?? 'local' } },
  { maxRetries: 0, timeout: 30_000 });
try {
  // ... drive it; the egress IP equals checked.ip_address
} finally {
  await kernel.browsers.deleteByID(browser.session_id).catch((e) => {
    if (!(e instanceof Kernel.NotFoundError)) throw e;
  });
}
```

- An empty list from a key lacking the list grant looks like "none exist" and would create a duplicate paid proxy: list once first (`await kernel.proxies.list()`) and confirm it returns without error before relying on an empty result.
- `proxies.create` with `{ type: 'isp', name }` worked on Hobbyist; `proxies.delete(id)` then retrieve returns 404. The docs say proxies unused for 14 days may be auto-deleted when the org has over 100; attached ones are kept.
- Add `stealth: true` to keep the captcha solver on your own proxy.
- Countries: docs list US, SG, GB, FR, DE; the SDK comment and CLI help also list KR. Only the default US was tested. Check `kernel proxies create --help` before relying on another country.
- Some orgs get a backup ISP endpoint; during a primary outage the site may briefly see a different IP (docs).
- Pair with a profile (`references/profiles.md`) so cookies and IP stay consistent.

## 6. Geo-targeted content: residential, least specific first

**If** the site serves different content by place -> **Do** create a residential proxy with the least-specific targeting that works (country, then state, then city); more specific means fewer IPs and a higher chance of a slow connection or a `no_peer` error. -> **Avoid** ZIP/ASN targeting unless required; assuming a residential exit IP is stable (it can change between connections, and reCAPTCHA-style systems can penalize rotating pools); expecting the ZIP to match exactly. -> **Source** https://www.kernel.sh/docs/proxies/residential. (unverified live: no residential proxy was created.)

```ts
// untested
const res = await kernel.proxies.create({ type: 'residential', name: 'us-residential', config: { country: 'US' } });
const b = await kernel.browsers.create({ proxy: { id: res.id } });
```

## 7. Captcha: let the solver work, gate on telemetry

**If** a captcha appears and you use stealth -> **Do** wait; do not touch the widget. Tell a computer-use loop: "If you see a CAPTCHA or similar test, just wait for it to get solved automatically." For a deterministic wait, enable captcha telemetry and gate on the events plus a page check. For Cloudflare, continue after the "Ready" message appears. -> **Avoid** clicking the checkbox (verified live: the script never touched it and the solver ticked the box and set the token); treating a solver `success` as "page cleared" (verify the page); assuming hCaptcha works (beta, per org, ask support); expecting the solver without `stealth: true` (verified live: a non-stealth browser stayed unchecked, 0 captcha events, page said "Please verify that you are not a robot"). -> **Source** https://www.kernel.sh/docs/browsers/bot-detection/stealth, https://www.kernel.sh/docs/browsers/telemetry/pausing-for-captcha-solves.

```ts
// untested as written
const browser = await kernel.browsers.create({
  stealth: true,
  headless: false,
  timeout_seconds: 300,
  telemetry: { browser: { captcha: { enabled: true } } },
  tags: { run: process.env.RUN_ID ?? 'local' },
}, { maxRetries: 0, timeout: 30_000 });
try {
  const stream = await kernel.browsers.telemetry.stream(browser.session_id, { replay: 'all' });
  const timer = setTimeout(() => stream.controller.abort(), 120_000); // deadline: abort ends the loop
  let solved = false;
  try {
    for await (const frame of stream as AsyncIterable<any>) {
      const ev = frame.event;                     // frames are wrapped: { seq, event: { type, category, data } }
      if (ev?.category === 'captcha') {           // top-level frame.type / frame.category are undefined
        console.log(ev.type, ev.data?.status, ev.data?.task_id);
        if (ev.type === 'captcha_challenge_result' && ev.data?.status === 'solved') { solved = true; break; }
      }
    }
  } catch { /* a stream termination error (including our abort) is a normal end */ }
  clearTimeout(timer);
  if (!solved) throw new Error('captcha not solved before the deadline; check the page');
} finally {
  await kernel.browsers.deleteByID(browser.session_id).catch((e) => {
    if (!(e instanceof Kernel.NotFoundError)) throw e;
  });
}
```
(hand-written from a live frame dump; the unwrap was confirmed from live frames, but this loop is untested as written. The live test matched on raw text.)

What was seen live on the reCAPTCHA v2 demo (stealth, headful): `captcha_solve_started` (task_kind `image_challenge`), `captcha_solve_result` (status `success`, `duration_ms` about 1.3 s), `captcha_challenge_result` (status `solved`). The page then said "Verification Success". Time from navigation to token varied 5 s, 30 s and 68 s across three runs, so give the wait a deadline of a couple of minutes, not seconds.

- **Wrapped frames refute the SDK types**: the types declare `category`/`type`/`data` at the top of each stream frame, live frames nest them under `event`. Filtering on the top level silently matches nothing.
- Join a start to its result on `task_id` only. Delivery is best-effort and unordered, so every wait needs a deadline and a fallback to reading the page.
- Use `captcha_provider` (`recaptcha_v2`) and `task_kind`. **Avoid** `captcha_type`: deprecated, and on solve events it read `other`.
- The stream ends with `TypeError: terminated` when the browser is deleted. Catch it.
- Server-side filtering: `browsers.telemetry.events(id, { type: [...] })` filters; the stream's `type` option is not applied server-side. In the CLI use `kernel browsers telemetry events <id> --categories captcha --limit 20 -o json` (server-side; `events --types` filters client-side and walks every page) (flags per `references/api-map.md`).
- With an egress allowlist, also allow the captcha provider hosts, or the challenge cannot load (reCAPTCHA: `www.google.com`, `www.gstatic.com`; hCaptcha: `hcaptcha.com`, `*.hcaptcha.com`; Turnstile: `challenges.cloudflare.com`; hosts can change).
- Not tested: hCaptcha, Turnstile, press-and-hold.

## 8. A 502 with `X-Kernel-Proxy-Error`, or a 403 you did not expect

**If** navigation returns 502 (or an unexpected 403) -> **Do** read the `x-kernel-proxy-error` response header and branch on it, not on the status. Proxy-layer failures are 502 (including timeouts); the allowlist refusal is 403. -> **Avoid** retrying `origin_response_incomplete` on form submits (the site may have acted); blind retry loops on non-retryable codes. -> **Source** https://www.kernel.sh/docs/proxies/errors.

| Code | Retry? | Do |
|---|---|---|
| `upstream_timeout`, `provider_unreachable`, `upstream_connect_failed`, `upstream_dns_failure`, `origin_tls_timeout`, `proxy_unavailable` | Yes, with backoff | Re-navigate |
| `restricted_route_unavailable` | Yes, except `.gov` | On `.gov`: residential proxy with no targeting, country-only or US-state targeting, `proxies.check` it, then use it; or go direct |
| `destination_route_unavailable` | No | A per-host route points at a deleted/unavailable proxy: fix or remove the route |
| `origin_response_incomplete` | Only if repeating is safe | Never auto-retry submits |
| `provider_rejected`, `provider_blacklisted` | No | Different proxy or proxy type, or disable the proxy for that host; check custom-proxy credentials |
| `destination_blocked` | No | Private/internal address: use a public one |
| `network_policy_denied` | No | Host is not in `network.allowed_hosts`; add it from your own code at create |

```ts
const response = await page.goto(url);   // a blocked navigation RESOLVES, it does not throw
const code = response?.headers()['x-kernel-proxy-error'];
```

- Verified live: with `network: { allowed_hosts: ['example.com'] }`, `page.goto('https://httpbin.org/ip')` resolved with status 403 and header `network_policy_denied`; `browsers.curl` returned the same header. A harness that only catches thrown errors misses the denial.
- Cross-origin `fetch`/XHR can hide the 403 behind CORS (`net::ERR_FAILED`) and images behind ORB; do not rely on the header there. With network telemetry on, branded errors surface as `proxy_error` events, not always.
- An allowlist can be replaced or removed on a running browser but never added to one created without it. `kernel browsers create --allowed-host example.com` is the CLI form (max 100). Allowlists constrain only Kernel-managed egress; do not hand the constrained agent your API key or VM code execution (https://www.kernel.sh/docs/browsers/egress-allowlists).

## 9. Banks, `.gov`, payment processors, postal services

**If** the target is a bank, brokerage, payment processor, national postal service, government site or a bare IP and the Kernel proxy fails -> **Do** treat it as a provider restriction, not an outage: try direct egress (`proxy: { mode: 'direct' }` or non-stealth) or a custom proxy of your own; for `.gov` try residential as in section 8. -> **Avoid** retrying the same managed proxy or filing it as a Kernel incident. A documented business need can be sent to security@kernel.sh as an exception request (not guaranteed). -> **Source** https://www.kernel.sh/docs/acceptable-use (restricted destinations; the table is indicative, not exhaustive).

- Verified live, contradicting the blanket claim: a stealth browser on the default proxy loaded https://www.usa.gov (status 200, no proxy-error header). The ISP proxy docs (https://www.kernel.sh/docs/proxies/isp) say the default provider carries some `.gov` hosts and returns 502 on the rest, so test your host and branch on the header.
- Restricted destinations are not prohibited by the policy; Kernel's browser-level anti-detection works with or without a Kernel proxy.
- A proxy outside Kernel's network means your provider's rules apply instead (section 11).

## 10. Per-host routing

**If** one site needs a different egress than the rest of the session (e.g. direct for an internal host, residential for one target) -> **Do** set `network.proxy_routes` at create: list the apex and the wildcard (`*.example.com` does not match `example.com`); exact host beats wildcard, longer suffix beats shorter. A route whose proxy disappears fails closed. -> **Avoid** adding routes after create (create-only). -> **Source** `BrowserNetworkConfig.proxy_routes` in the SDK types; CLI `kernel browsers create --proxy-route 'HOST[,HOST]=PROXY_ID'` (max 10 routes, 50 hosts each; `id:ID` or `name:NAME` prefixes). (unverified live: not run.)

```ts
// untested
await kernel.browsers.create({
  proxy: { mode: 'direct' },
  network: { proxy_routes: [{ hosts: ['example.com', '*.example.com'], proxy: { id: proxy.id } }] },
});
```

## 11. Custom proxies, corporate MITM and names

**If** you must use your own proxy or a TLS-intercepting corporate proxy -> **Do** `proxies.create({ type: 'custom', ... config: { ca_bundle } })` and bind it at browser create (`proxy: { id }`); `ca_bundle` is write-only (responses show `has_ca_bundle`), PEM, 64 KiB max. -> **Avoid** hot-swapping a proxy that has a CA bundle onto a running browser. -> **Source** https://www.kernel.sh/docs/proxies/custom. Custom proxies are plan-gated off on Hobbyist (verified live); `bypass_hosts` is Start-Up and Enterprise (https://www.kernel.sh/docs/proxies/overview).

**If** you write new code -> **Do** use the nested `proxy: { id | name | mode }` on browsers (`mode`: `'direct'` or `'default'`; give exactly one of the three; `name` must match exactly one active proxy). On browser **pools** the field is still `proxy_id` (pool config has no `proxy` object). -> **Avoid** on browsers, with their replacement:

| Do not use | Use instead | Verified live |
|---|---|---|
| `proxy_id` on `browsers.create`/`update` | `proxy: { id }` | On create: still accepted (no error), response echoed `proxy: { id }`; deprecated in the SDK; update not run |
| `disable_default_proxy` on create | `proxy: { mode: 'direct' }` | Accepted but did NOT produce direct egress (response `proxy.mode` stayed `default`, egress stayed a pool IP) |
| `proxy: { type: 'datacenter' }` / datacenter proxies | `type: 'isp'` | 400 "provide exactly one of proxy.mode, proxy.id, or proxy.name" (message does not mention `type`) |

**Source** `@deprecated` tags in the SDK types, https://www.kernel.sh/docs/changelog. Note: Kernel's own docs prose and sample skills still show `proxy_id`/`disable_default_proxy`; the types and live behavior win.

## 12. Swapping a proxy mid-session

**If** a running browser must change egress between steps -> **Do** `kernel.browsers.update(id, { proxy: { id } })`, `{ proxy: { mode: 'direct' } }`, or `{ proxy: { mode: 'default' } }` (restores the browser default: pool proxy for stealth, direct otherwise); CLI `kernel browsers update <id> --proxy-id|--proxy-name|--proxy-mode`. The call is synchronous (docs: about 2 to 3 s) and the network drops briefly. -> **Avoid** swapping with requests in flight; swapping a leased pool browser without expecting the release to be slower (it resets to the pool proxy); combining `proxy` with `proxy_id` or `disable_default_proxy`. -> **Source** https://www.kernel.sh/docs/proxies/overview, SDK `BrowserUpdateParams`. (unverified live: not run.)

## 13. Web Bot Auth (last rung)

**If** a site honors signed bot identities and lower rungs fail -> **Do** request Kernel's WBA token from support (Start-Up and Enterprise only, enabled selectively, not by stealth), or sign with your own key: build the extension (`kernel extensions build-web-bot-auth --to ./ext --key ./key.jwk --signature-agent https://yourdomain.com --upload my-web-bot-auth`, needs Node and npm) and create the browser with `extensions: [{ name: 'my-web-bot-auth' }]`. -> **Avoid** treating it as a login or a guarantee; the site still decides. The test key does not establish Kernel's identity. -> **Source** https://www.kernel.sh/docs/browsers/bot-detection/web-bot-auth. (unverified live: no WBA extension built.)

## 14. Proxy ranking contradicts itself

**If** API or CLI help says "mobile > residential > isp" -> **Do** follow the guides: start with ISP (static IP on a residential ASN), move to residential only for geo or fingerprint-heavy vendors, mobile last. -> **Avoid** picking the "strongest" type first; it is slower and rotates. -> **Source** https://www.kernel.sh/docs/browsers/bot-detection/overview ("Start with ISP"), https://www.kernel.sh/docs/proxies/overview. (The two statements cannot both be right; the docs' ordering is a recommendation, not measured here.)

Gated or untested: residential, mobile and custom proxies, MITM `ca_bundle`, `proxy_routes`, `browsers.update` proxy swap, stealth plus `mode: 'direct'`, ISP countries other than US, WBA, hCaptcha and Turnstile, `proxies.check` with `url`, GPU (plan-gated), `bypass_hosts`.

Verified live 2026-10-20 (Hobbyist plan); types re-checked on @onkernel/sdk 0.128.0. Evidence ledger: https://github.com/yigitkonur/plugin-kernel-sh/blob/main/verified-facts.md
