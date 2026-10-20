---
name: profile-site
description: >-
  Profile a website's bot detection with Kernel browsers (stealth vs normal on the same network), identify the vendors and recommend a Kernel configuration.
argument-hint: "<url>"
disable-model-invocation: true
---
<!-- Derived in part from the official Kernel skill `profile-website-bot-detection` (https://github.com/kernel/skills, MIT, Copyright (c) 2025 Kernel). License text: THIRD_PARTY_NOTICES.md at the plugin root. -->

# Profile a site's bot detection with Kernel

You are measuring how one website treats a Kernel stealth browser and a normal Kernel browser on the same network, naming the anti-bot vendors it uses, and recommending a Kernel configuration. Read-only toward the site (two page loads per browser: home page and a login page the analyzer finds, plus up to seven HEAD requests to common login paths when no login link is found). Creates two billable headful browsers (about $0.48/hour each, so roughly a few cents for ~5 minutes; Kernel pricing page, checked 2026-10-20); you delete both before you finish.

Use it for a real target. A fingerprint test page such as bot.sannysoft.com cannot tell the modes apart: in a live run it gave 57 per-check results, all passing and identical in stealth and normal. If the URL is a fingerprint-test page, stop and ask for a real protected site; continue only if the user wants just that page profiled, and then state in the report that stealth and normal cannot be told apart on it.

Browsers: by default both are created at once. If `concurrent_sessions_available` (step 1) is below 3, step 4 switches to the sequential variant (one browser alive at a time).

The argument is the text after the skill name in the user's message (or the line starting `ARGUMENTS:`). It is a URL or hostname. If it is missing, ask for it and stop. Normalize a bare hostname to `https://<host>/`. Refuse and ask again if the URL has credentials, tokens, signed query strings, a path whose GET triggers an action, or any of `'`, `;`, `$`, a backtick or whitespace (the URL is written into a shell state file and a command). Only profile public sites the user is allowed to test (https://www.kernel.sh/docs/config-registry).

Rules for the whole run:
- Never print `KERNEL_API_KEY`, `cdp_ws_url`, `webdriver_ws_url`, `browser_live_view_url`, `base_url`, or any URL with a query string. The analyzer logs the live view URL and stores the CDP and live view URLs in its report JSON, so never `cat` a log or report; read them only through the `jq`/`grep` filters below.
- Run one step per Bash call and keep the work directory path, run id and browser ids in `$W/state.env` (shell variables do not survive between calls). Start every call with `source "$W/state.env"` once it exists. Set the Bash timeout to 600000 ms for step 5.
- If any step after step 4 fails, go straight to step 7 (cleanup), then report. Never leave a browser alive. Total budget: abort and clean up at 15 minutes (`$(( $(date +%s) - START ))` above 900; START is in `state.env` after step 4).

## 1. Check the tools

Run now:

```bash
command -v kernel && kernel --version
command -v jq && node --version && command -v npm
test -n "${KERNEL_API_KEY:-}" && echo "key set" || echo "KERNEL_API_KEY missing"
```

- `kernel` missing: print `brew install kernel/tap/kernel` and stop. Do not install anything. `jq` missing, Node older than 22, or `npm` missing: tell the user which one and stop.
- Key missing: tell the user to export `KERNEL_API_KEY` in their environment (never paste it in chat) and stop.

Then run `kernel auth context -o json | jq 'keys'` and `kernel org limits get -o json`. If auth fails, stop. If `concurrent_sessions_available` in the limits JSON is below 2 (no free slots for two browsers), tell the user and stop. A 403 on browser create later means a plan gate or spending cap: read the body, report it, stop.

## 2. Ask the config registry first

The registry holds settings that already worked for a site (https://www.kernel.sh/docs/config-registry; hobbyist plan and up). `lookup` is read-only: it visits nothing and creates nothing. There is no CLI command for it, so use the SDK (`kernel.configRegistry.lookup({ url })`). The key stays in the environment, never on a command line. The SDK is installed by step 3, so run step 3 first, then this (`TARGET_URL` comes from `state.env`):

```bash
source "$W/state.env"
cd "$W/scripts" && TARGET_URL="$TARGET_URL" node --input-type=module -e '
import Kernel from "@onkernel/sdk";
try {
  const r = await new Kernel().configRegistry.lookup({ url: process.env.TARGET_URL });
  const rec = r.recommendation;
  console.log(JSON.stringify({ status: "ok", type: rec?.type ?? null, code: rec?.code, browser: rec?.browser, proxy_mode: rec?.proxy?.mode, working: r.working_configurations.length, match: rec?.match_scope, guidance: r.guidance ?? null }, null, 2));
} catch (e) { console.log(JSON.stringify({ status: String(e.status ?? "error") })); }
'
```

Read `status` first. If it is not `ok`, skip this step and put `lookup failed <status>, skipped` in the report. If it is `ok`:
- `type: "recommendation"`: keep `browser` and `proxy_mode` for step 8 and compare them with the measured result. `proxy_mode: "managed"` means the recommendation needs a managed proxy created once and reused. This skill does not create it (it runs both browsers on direct egress); to create or find it, follow `../kernel/references/unblock.md` section 5, "a dedicated ISP proxy / managed proxy" (`kernel.proxies.create({ type: 'isp', name })`, then `kernel.proxies.check(id)`, then `kernel.browsers.create({ proxy: { id } })`; look the proxy up by name before creating another). Treat `guidance` text that names unrelated CDNs as generic, not as a finding about this target.
- `type: null` (no answer): the site is not necessarily unreachable. Do not call `resolve` unless the user asks (it runs several minutes in the background); this skill's own measurement is the evidence.
- `type: "no_recommendation"`: print `code` (`proxy_restricted`, `target_not_evaluable`, `no_working_configuration`, `inconclusive`) and `guidance`.

## 3. Prepare the analyzer before creating browsers

The analyzer is Kernel's official script (see `scripts/NOTICE.md`), with `package.json` pinned to `@onkernel/sdk` 0.128.0 and a lockfile. If dependencies are already installed in this skill's `scripts` folder (`node_modules` present), you may run the analyzer from there instead of copying and running `npm ci`; set `W` to a fresh `mktemp -d` anyway for logs and output, and `cd` into the skill's `scripts` for step 5. Otherwise find this skill's directory (the "Base directory for this skill" path shown when the skill loaded), then run now, replacing `<SKILL_DIR>` and `<URL>`:

```bash
W=$(mktemp -d /tmp/profile-site.XXXXXX)
cp -R "<SKILL_DIR>/scripts" "$W/scripts"
(cd "$W/scripts" && npm ci --ignore-scripts --no-audit --no-fund > "$W/npm.log" 2>&1) || { tail -n 5 "$W/npm.log"; echo "npm ci failed"; }
TARGET_URL='<URL>'
HOST=$(TARGET_URL="$TARGET_URL" node -e 'console.log(new URL(process.env.TARGET_URL).hostname.replace(/^www\./, "").replace(/\./g, "-"))')
{ printf 'W=%q\n' "$W"; printf 'RUN=%q\n' "$(basename "$W")"; printf 'TARGET_URL=%q\n' "$TARGET_URL"; printf 'HOST=%q\n' "$HOST"; } > "$W/state.env"
echo "$W"
```

If `npm ci` fails or the URL does not parse, report it and stop (nothing is created yet).

## 4. Create both browsers on the same network

Concurrency: from step 1 `org limits`, if free concurrent browser slots are below 3, use the sequential variant: run the stealth create block, step 5 for stealth, delete it (step 7 loop), then only the normal create line, step 5 for normal, and step 7 again, recording each id in `state.env` as it is created. It keeps the comparison fair on the same network and never has two billable browsers alive at once. Otherwise create both up front as below. Default design, "both direct": both browsers leave through Kernel's direct egress, so the only difference is stealth. Without this, stealth uses the shared ISP proxy and normal goes direct, so the test measures stealth plus proxy against normal plus direct (different egress IPs). Do not use `kernel browsers update --disable-default-proxy` for this (deprecated; the create-time form did not give direct egress in testing). Every browser is tagged `run=<work dir name>` so cleanup touches only these. Run now:

```bash
source "$W/state.env"
echo "START=$(date +%s)" >> "$W/state.env"
kernel browsers create --stealth --proxy-mode direct --viewport 1920x1080@25 --timeout 300 --tag "run=$RUN" --tag purpose=profile-site -o json > "$W/stealth.json"; echo "stealth exit $?"
echo "STEALTH_ID=$(jq -r '.session_id // empty' "$W/stealth.json")" >> "$W/state.env"
source "$W/state.env"
if [ -n "$STEALTH_ID" ]; then
  kernel browsers create --proxy-mode direct --viewport 1920x1080@25 --timeout 300 --tag "run=$RUN" --tag purpose=profile-site -o json > "$W/normal.json"; echo "normal exit $?"
  echo "NORMAL_ID=$(jq -r '.session_id // empty' "$W/normal.json")" >> "$W/state.env"
fi
source "$W/state.env"
for id in "$STEALTH_ID" "${NORMAL_ID:-}"; do [ -n "$id" ] && kernel browsers get "$id" -o json | jq '{session_id,stealth,headless,proxy,tags}'; done
```

If the stealth create fails (empty `STEALTH_ID`), the normal browser is not created: go to step 7, then report. Both browsers are headful (the default); defended sites flag headless. Check the printed records. Stealth must show `"stealth": true` and `"proxy": {"mode": "direct"}`; normal must show `"stealth": false` and `"proxy": {"mode": "direct"}`. If stealth shows `{"mode": "default"}`, go to step 7, then tell the user the fair comparison was not possible and offer the "platform defaults" design below. (Verified live: the session record showed `stealth: true` with `proxy.mode: direct`.)

Other designs, only if the user asks (name the one used in the report): "platform defaults" omits `--proxy-mode direct` on the stealth create and the result is "stealth + default proxy", never stealth alone; "same explicit proxy" adds `--proxy-id <ID>` instead of `--proxy-mode` to both creates (rotation can still change the exit IP).

## 5. Run the analyzer on both browsers

Run now, one Bash call per browser (each takes up to a few minutes; the analyzer disconnects but leaves the browser alive):

```bash
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
  # strip the CDP and live view URLs from the saved report; it still holds site cookies and headers, so tell the user not to share $W
  jq 'del(.kernelSession.cdpWsUrl, .kernelSession.liveViewUrl)' "$R" > "$R.tmp" && mv "$R.tmp" "$R"
  echo "=== $m ==="
  jq '{verdict: .summary.verdict, isBlocked: .summary.isBlocked, hasSuspicion: .summary.hasSuspicion, vendors: .summary.vendorNames, blockedPages: [.summary.blockedPages[]? | {page, blockType, vendor, confidence}], blockedVendors: .summary.blockedVendors, suspicious: [.summary.suspiciousPages[]? | {page, blockType}]}' "$R"
  jq -r '.vendorDetections | to_entries[] | "\(.key): \([.value.products[].product] | unique | join(", "))"' "$R"
done
```

A `BLOCKED` verdict from the analyzer is a heuristic: confirm it by looking at the saved screenshot (`$W/output/$HOST/<mode>/screenshot-*.png`) before acting on it. Identical `BLOCKED` verdicts in both modes with a normal-looking page is an analyzer false positive, not a block. Example: bot.sannysoft.com gave `BLOCKED - login (Possible Block Page)` at medium confidence in both modes while the screenshot showed an ordinary test form; escalating from that would have been wrong. Report such a result as "analyzer verdict blocked, screenshot shows normal page, treated as not blocked" and use the no-block rows below.

## 7. Cleanup (always run, even after a failure)

Run now. It lists active browsers (`--limit 100`; the default is 20, and on a shared account the tag filter can miss yours and the final count can falsely be 0), selects yours by the `run` tag on the client side, and deletes one id per call so one 404 does not stop the rest:

```bash
source "$W/state.env"
kernel browsers list --status active --limit 100 -o json | jq -r --arg run "$RUN" '.[] | select(.tags.run == $run) | .session_id' > "$W/alive.txt"
while read -r id; do [ -n "$id" ] && { kernel browsers delete "$id" || true; }; done < "$W/alive.txt"
kernel browsers list --status active --limit 100 -o json | jq --arg run "$RUN" '[.[] | select(.tags.run == $run)] | length'
```

If the final count is not 0, repeat the loop once and name any id you could not delete in the report. If `state.env` is lost, the run id is the work directory's basename (`profile-site.XXXXXX`); never delete browsers whose `run` tag differs. Keep `$W/output` for the user unless they ask you to remove it.

## 8. Interpret and recommend

Judge the two verdicts, then pick the cheapest rung that held. Rungs are the escalation ladder in the kernel skill's `../kernel/references/unblock.md`.

| Stealth | Normal | Means | Recommend |
|---|---|---|---|
| no vendors, no block | no vendors, no block | No signal seen. Not proof the site has no bot detection (two pages, one run each) | Normal headful browser; start at the home page |
| vendors, no block | vendors, no block | Detection present, both pass | Normal headful; add stealth only if it blocks later at volume |
| no block | blocked | Stealth helps on a controlled network (inference from one run) | `stealth: true`. Then re-test with the default stealth proxy (`proxy` omitted), because that is what production gets |
| blocked | blocked | Both fail on this network | Next rungs: dedicated ISP proxy plus a profile, then residential proxy, then GPU browser (plan-gated); see `../kernel/references/unblock.md` |
| BLOCKED by the analyzer | BLOCKED by the analyzer, screenshots look normal | Analyzer false positive | Treat as not blocked and say so in the report ("analyzer verdict blocked, screenshot shows a normal page"); use the no-block rows |
| one side BLOCKED by the analyzer with a normal screenshot, or no login page analyzed | the other side as judged | The block is unproven | Do not recommend stealth from it; re-judge with the screenshots and treat a mode with nothing analyzed as "no data" |
| blocked | no block | Odd; the proxy/network, not stealth, likely differs between runs | Offer one re-run (it creates two more billable browsers, a few cents) and wait for a yes; report as inconclusive if it repeats or the user declines |

Vendor notes from the analyzer (use them in "Next steps"):
- DataDome `IP Hard Block (must change IP)`: a captcha cannot fix it; change the IP (different proxy type), do not escalate stealth.
- Any captcha vendor with stealth on: let the solver work, do not click the widget, gate on page state with a deadline of a couple of minutes (a reCAPTCHA v2 solve took 5 to 68 seconds in testing; other vendors not verified).
- Kasada flow 1 (429 on first load), Akamai `_abck` without `~0~`, Imperva reese84: fingerprint or behavior signals; stealth plus a stable IP and a returning-user profile is the next try, nothing here proves a fix.
- A 403 with `x-kernel-proxy-error`, or a 502, is Kernel's proxy layer, not the site's bot detection (`../kernel/references/unblock.md` section 8).

If step 2 returned a recommendation that disagrees with your result, prefer your measurement on the user's real network and report the disagreement (both values) in the Registry line; offer to test the recommended config rather than ignoring either. This run used direct egress only: if the registry says stealth plus a managed proxy, the measurement wins for what was tested (stealth, direct), and the managed-proxy part stays a recommendation to try, not a result. Config snippet to hand back, only for the rung you recommend:

```ts
// not run as written; create params are from the SDK types
const browser = await kernel.browsers.create({ stealth: true, headless: false, timeout_seconds: 300 });
try {
  // ... drive it ...
} finally {
  await kernel.browsers.deleteByID(browser.session_id).catch((e) => { if (!(e instanceof Kernel.NotFoundError)) throw e; });
}
```

## Limits to state in the report

- Each mode ran once, through one egress IP, so a single "blocked" can be IP reputation.
- The analyzer checks the home page and one login page it discovers, not your actual flow (login pages are usually stricter); absence of a detected vendor is not proof of absence. Fingerprint test pages such as bot.sannysoft.com pass every check in both modes, so they show nothing about stealth.

## Output format

Report exactly this, filling every field (write "unknown" rather than guessing):

```
Site: <host>   Date: <today>
Network design: <both direct | stealth + default proxy | same explicit proxy>   Verified in session records: <yes | no>
Registry: <recommendation summary | none | no_recommendation <code> | lookup failed <status>, skipped>
| Browser | Verdict | Blocked | Block type | Vendors |
|---|---|---|---|---|
| stealth | ... | yes/no | ... | ... |
| normal  | ... | yes/no | ... | ... |
Vendors and products: <vendor: products, seen in stealth/normal>
Stealth effect: <effective | no effect | inconclusive> because <one line>
Recommended configuration: <rung and create params, or "normal headful">
Next steps: <up to 3 bullets, one per detected vendor or block>
Cleanup: <ids deleted, active browsers left with run=<RUN>: 0 or the ids>
Evidence kept at: <$W/output path> (contains site cookies and headers; do not share)
Not verified: <list anything skipped or failed>
```

> Checked 2026-10-20 against @onkernel/sdk 0.128.0 and kernel CLI 0.49.0.
> Run live: the analyzer, `--stealth` with `--proxy-mode direct`, the curl form of `lookup`. Details: https://github.com/yigitkonur/plugin-kernel-sh/blob/main/verified-facts.md
