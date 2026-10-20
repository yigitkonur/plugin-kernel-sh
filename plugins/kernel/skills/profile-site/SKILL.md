---
name: profile-site
description: >-
  Profile a website's bot detection with Kernel browsers (stealth vs normal on the same network), identify the vendors and recommend a Kernel configuration.
argument-hint: "<url>"
disable-model-invocation: true
---

# Profile a site's bot detection with Kernel

You are measuring how one website treats a Kernel stealth browser and a normal Kernel browser on the same network, naming the anti-bot vendors it uses, and recommending a Kernel configuration. Read-only toward the site (two page loads per browser: home page and a login page the analyzer finds, plus up to seven HEAD requests to common login paths when no login link is found). Creates two billable headful browsers for a few minutes; you delete both before you finish.

The argument is the text after the skill name in the user's message (or the line starting `ARGUMENTS:`). It is a URL or hostname. If it is missing, ask for it and stop. Normalize a bare hostname to `https://<host>/`. Refuse and ask again if the URL has credentials, tokens, signed query strings, or a path whose GET triggers an action; only profile public sites the user is allowed to test (https://www.kernel.sh/docs/config-registry).

Rules for the whole run:
- Never print `KERNEL_API_KEY`, `cdp_ws_url`, `webdriver_ws_url`, `browser_live_view_url`, `base_url`, or any URL with a query string. The analyzer logs the live view URL and stores the CDP and live view URLs in its report JSON, so never `cat` a log or report; read them only through the `jq`/`grep` filters below.
- Run one step per Bash call and keep the work directory path and the two browser ids in `$W/state.env` (shell variables do not survive between calls). Start every call with `source "$W/state.env"` once it exists. Set the Bash timeout to 600000 ms for step 5.
- If any step after step 4 fails, go straight to step 7 (cleanup), then report. Never leave a browser alive.
- Do not use `kernel browsers update --disable-default-proxy` to make the stealth browser direct (Kernel's sample skill does). The Kernel changelog marks `disable_default_proxy` deprecated and the CLI source labels the flag "legacy"; the proxies overview still suggests the update-time form for a running stealth browser and the CLI reference does not mark it deprecated. The create-time field of the same name did not produce direct egress in lab P14, and the update-time flag is untested in the lab. Use `--proxy-mode direct` at create and verify it (step 4).

## 1. Check the tools

Run now:

```bash
command -v kernel && kernel --version
command -v jq && node --version && command -v npm
test -n "${KERNEL_API_KEY:-}" && echo "key set" || echo "KERNEL_API_KEY missing"
```

- `kernel` missing: print these two commands and stop. Do not install anything.
  ```bash
  brew install kernel/tap/kernel
  npm i -g @onkernel/cli
  ```
- `jq` missing, Node older than 22, or `npm` missing: tell the user which one and stop.
- Key missing: tell the user to export `KERNEL_API_KEY` in their environment (never paste it in chat) and stop.

Then run `kernel auth context -o json | jq 'keys'` and `kernel org limits get -o json`. If auth fails, stop. If limits show no free concurrent browser slots for two browsers, tell the user and stop. A 403 on browser create later means a plan gate or spending cap: read the body, report it, stop.

## 2. Ask the config registry first

The registry holds settings that already worked for a site (https://www.kernel.sh/docs/config-registry; hobbyist plan and up). `lookup` is read-only: it visits nothing and creates nothing. There is no CLI command for it (`kernel search` is web search, not this). Run now, with the normalized URL as `<URL>`:

```bash
# untested (lab P12 ran the SDK call, not curl)
curl -s -X POST https://api.onkernel.com/config-registry/lookup \
  -H "Authorization: Bearer $KERNEL_API_KEY" -H 'Content-Type: application/json' \
  -d '{"url":"<URL>"}' \
  | jq '{type: .recommendation.type, code: .recommendation.code, browser: .recommendation.browser, proxy_mode: .recommendation.proxy.mode, working: (.working_configurations|length), match: .recommendation.match_scope, guidance: (.guidance // null)}'
```

(unverified as written: lab P12 ran the same call through `kernel.configRegistry.lookup({ url })` from `@onkernel/sdk`; the path `/config-registry/lookup` and the Bearer header come from the installed SDK source. If the curl fails with 401/403/404, say so, skip this step, and note it in the report. In a project that already has a current `@onkernel/sdk`, the form that ran in the lab is `const kernel = new Kernel(); const r = await kernel.configRegistry.lookup({ url });`; the inline one-expression form was not run.)

Read the result:
- `type: "recommendation"`: keep `browser` and `proxy_mode` for step 8 and compare them with the measured result. `proxy_mode: "managed"` means the recommendation needs a managed proxy created once and reused.
- `type: null` (registry has no answer; P12 saw this for bot.sannysoft.com): this does not mean the site is unreachable. Do not call `resolve` unless the user asks: it starts a background analysis that takes several minutes (P12), and this skill's own measurement is the evidence.
- `type: "no_recommendation"`: print `code` (`proxy_restricted`, `target_not_evaluable`, `no_working_configuration`, `inconclusive`) and `guidance` in the report.

## 3. Prepare the analyzer before creating browsers

The analyzer is Kernel's official script, copied unchanged (see `scripts/NOTICE.md`). Find this skill's directory (the "Base directory for this skill" path shown when the skill loaded), then run now, replacing `<SKILL_DIR>`:

```bash
W=$(mktemp -d /tmp/profile-site.XXXXXX)
cp -R "<SKILL_DIR>/scripts" "$W/scripts"
(cd "$W/scripts" && npm install --no-audit --no-fund 2>&1 | tail -n 3)
HOST=$(TARGET_URL='<URL>' node -e 'console.log(new URL(process.env.TARGET_URL).hostname.replace(/^www\./, "").replace(/\./g, "-"))')
printf 'W=%s\nTARGET_URL=%s\nHOST=%s\n' "$W" '<URL>' "$HOST" > "$W/state.env"
echo "$W"
```

The script pins `@onkernel/sdk` `^0.25.0`; it only calls `browsers.retrieve`. If `npm install` fails, report the error and stop (nothing is created yet).

## 4. Create both browsers on the same network

Default design, "both direct": both browsers leave through Kernel's direct egress, so the only difference is stealth. Without this, stealth uses the shared ISP proxy and normal goes direct, and the test measures stealth plus proxy against normal plus direct (lab P12: different egress IPs). Run now:

```bash
source "$W/state.env"
# untested combination (see the note below)
kernel browsers create --stealth --proxy-mode direct --viewport 1920x1080@25 --timeout 300 --tag purpose=profile-site -o json > "$W/stealth.json"; echo "stealth exit $?"
kernel browsers create --proxy-mode direct --viewport 1920x1080@25 --timeout 300 --tag purpose=profile-site -o json > "$W/normal.json"; echo "normal exit $?"
echo "STEALTH_ID=$(jq -r '.session_id // empty' "$W/stealth.json")" >> "$W/state.env"
echo "NORMAL_ID=$(jq -r '.session_id // empty' "$W/normal.json")" >> "$W/state.env"
source "$W/state.env"
for id in "$STEALTH_ID" "$NORMAL_ID"; do [ -n "$id" ] && kernel browsers get "$id" -o json | jq '{session_id,stealth,headless,proxy}'; done
```

Both browsers are headful (the default); defended sites flag headless, and the analyzer takes screenshots.

Check the printed records. Stealth must show `"stealth": true` and `"proxy": {"mode": "direct"}`; normal must show `"stealth": false` and `"proxy": {"mode": "direct"}`. If stealth shows `{"mode": "default"}` or the create failed, go to step 7, then tell the user the fair comparison was not possible and offer the "platform defaults" design below. (`--stealth` together with `--proxy-mode direct` exists in the CLI source and the SDK types; lab P12/P14 created `proxy: { mode: 'direct' }` on a non-stealth browser only, so this exact combination is unverified live.)

Other designs, only if the user asks, and say which one you used in the report:
- Platform defaults: omit `--proxy-mode direct` on the stealth create. Report the stealth result as "stealth + default proxy" and never credit stealth alone.
- Same explicit proxy: add `--proxy-id <ID>` (instead of `--proxy-mode`) to both creates. Optionally run `kernel proxies check <ID> -o json` first. Provider rotation can still change the exit IP.

## 5. Run the analyzer on both browsers

Run now, one Bash call per browser (each takes up to a few minutes; the analyzer disconnects but leaves the browser alive):

```bash
# untested in the lab (the analyzer script was not run)
source "$W/state.env"
cd "$W/scripts"
KERNEL_BROWSER_ID="$STEALTH_ID" TARGET_URL="$TARGET_URL" BROWSER_MODE=stealth OUTPUT_DIR="$W/output" npm run analyze > "$W/stealth.log" 2>&1; echo "exit $?"
grep -E 'BLOCKED|DATADOME|Vendor analysis completed|Test failed' "$W/stealth.log" | sed -E 's/\?[^ "]*/?***/g' | head -n 15
```

Then the same with `NORMAL_ID`, `BROWSER_MODE=normal`, `normal.log`. A non-zero exit or a `Test failed` line: show the masked grep output, go to step 7, and report that browser's result as "no data".

## 6. Compare, without printing secrets

Run now:

```bash
source "$W/state.env"
for m in stealth normal; do
  R=$(ls -t "$W/output/$HOST/$m"/report-*.json 2>/dev/null | head -n 1)
  [ -n "$R" ] || { echo "no $m report"; continue; }
  jq 'del(.kernelSession.cdpWsUrl, .kernelSession.liveViewUrl)' "$R" > "$R.tmp" && mv "$R.tmp" "$R"
  echo "=== $m ==="
  jq '{verdict: .summary.verdict, isBlocked: .summary.isBlocked, hasSuspicion: .summary.hasSuspicion, vendors: .summary.vendorNames, blockedPages: [.summary.blockedPages[] | {page, blockType, vendor, confidence}], blockedVendors: .summary.blockedVendors, suspicious: [.summary.suspiciousPages[] | {page, blockType}]}' "$R"
  jq -r '.vendorDetections | to_entries[] | "\(.key): \([.value.products[].product] | unique | join(", "))"' "$R"
done
```

The first `jq` removes the CDP and live view URLs from the saved report. The reports still hold cookies and request headers from the site, so keep them in `$W` and tell the user not to share the directory.

## 7. Cleanup (always run, even after a failure)

Run now:

```bash
source "$W/state.env"
ids=(); [ -n "${STEALTH_ID:-}" ] && ids+=("$STEALTH_ID"); [ -n "${NORMAL_ID:-}" ] && ids+=("$NORMAL_ID")
[ ${#ids[@]} -gt 0 ] && kernel browsers delete "${ids[@]}"
kernel browsers list --status active --tag purpose=profile-site -o json | jq 'length'
```

`browsers delete` takes several ids and has no `-y` (lab P20; the public CLI reference documents `-y`, so the lab result overrides it). If the final count is not 0, delete each remaining `session_id` from `kernel browsers list --status active --tag purpose=profile-site -o json | jq -r '.[].session_id'`, and name any you could not delete in the report. If `state.env` is lost, use that same `list` command to find them. Keep `$W/output` for the user (screenshots and reports) unless they ask you to remove it.

## 8. Interpret and recommend

Judge the two verdicts, then pick the cheapest rung that held. Rungs are the escalation ladder in the kernel skill's `../kernel/references/unblock.md`.

| Stealth | Normal | Means | Recommend |
|---|---|---|---|
| no vendors, no block | no vendors, no block | No signal seen. Not proof the site has no bot detection (two pages, one run each) | Normal headful browser; start at the home page |
| vendors, no block | vendors, no block | Detection present, both pass | Normal headful; add stealth only if it blocks later at volume |
| no block | blocked | Stealth helps on a controlled network (design inference, not a lab result) | `stealth: true`. Then re-test with the default stealth proxy (`proxy` omitted), because that is what production gets |
| blocked | blocked | Both fail on this network | Next rungs: dedicated ISP proxy plus a profile, then residential proxy, then GPU browser (plan-gated); see `../kernel/references/unblock.md` |
| blocked | no block | Odd; the proxy/network, not stealth, likely differs between runs | Re-run once; report as inconclusive if it repeats |

Vendor notes from the analyzer (use them in "Next steps"):
- DataDome `IP Hard Block (must change IP)`: a captcha cannot fix it; change the IP (different proxy type), do not escalate stealth.
- Any captcha vendor with stealth on (the Kernel docs page on pausing for captcha solves lists Cloudflare Turnstile; the lab ran reCAPTCHA v2 only): let the solver work, do not click the widget, gate on page state with a deadline of a couple of minutes (lab P13: reCAPTCHA token took 5 s to 68 s; the non-stealth browser did not solve within the 20 s wait in one run).
- Kasada flow 1 (429 on first load), Akamai `_abck` without `~0~`, Imperva reese84: report as fingerprint or behavior signals; stealth plus a stable IP and a returning-user profile is the next try, nothing in this run proves a fix.
- A 403 with `x-kernel-proxy-error`, or a 502: that is Kernel's proxy layer, not the site's bot detection; read `../kernel/references/unblock.md` section 8.

If step 2 returned a recommendation, compare it with what you measured. A registry recommendation that disagrees with your result is a reason to test its config, not to ignore either.

Config snippet to hand back, only for the rung you recommend:

```ts
// untested as written (the create params are from the SDK types and the registry's recommended browser keys seen in lab P12)
const browser = await kernel.browsers.create({ stealth: true, headless: false, timeout_seconds: 300 });
// ... drive it ...
await kernel.browsers.deleteByID(browser.session_id);
```

## Limits to state in the report

- Each mode ran once, through one egress IP; the stealth default IP varied across sessions (lab P14, 2 samples), and stealth, direct and proxy IPs differed within one session (lab P12, P14), so a single "blocked" can be IP reputation.
- The analyzer checks the home page and one login page it discovers, not your actual flow. Login pages are usually stricter.
- It detects vendors from scripts, cookies, headers and block-page text; absence of a vendor is not proof of absence.
- Fingerprint test pages such as bot.sannysoft.com gave no usable result in lab P12: the failed-row extractor found none in either mode, but the lab could not confirm the page exposes failures (unclear), so do not use them as the verdict.

## Output format

Report exactly this, filling every field (write "unknown" rather than guessing):

```
Site: <host>   Date: <today>
Network design: <both direct | stealth + default proxy | same explicit proxy>   Verified in session records: <yes | no>
Registry: <recommendation summary | none | no_recommendation <code> | lookup failed <status>>

| Browser | Verdict | Blocked | Block type | Vendors |
|---|---|---|---|---|
| stealth | ... | yes/no | ... | ... |
| normal  | ... | yes/no | ... | ... |

Vendors and products: <vendor: products, seen in stealth/normal>
Stealth effect: <effective | no effect | inconclusive> because <one line>
Recommended configuration: <rung and create params, or "normal headful">
Next steps: <up to 3 bullets, one per detected vendor or block>
Cleanup: <ids deleted, active profile-site browsers left: 0 or the ids>
Evidence kept at: <$W/output path> (contains site cookies and headers; do not share)
Not verified: <list anything skipped or failed>
```

> Verified in lab: 2026-10-20, card L5, @onkernel/sdk 0.127.0, kernel CLI 0.49.0. Probes: P12 (registry lookup/resolve confirmed; stealth vs normal fingerprint unclear; stealth plus direct untested), P13 (captcha solver on stealth confirmed; the plain browser did not solve within 20 s, one run), P14 (`proxy: { mode: 'direct' }` confirmed; the deprecated create-time direct-egress field refuted). Not run in the lab: the analyzer script itself (this skill is not fully verified until it is run live once), `kernel browsers create --stealth --proxy-mode direct`, the curl form of `lookup`, `kernel browsers delete` with several ids, `--tag` filtering in `list` for this tag.
