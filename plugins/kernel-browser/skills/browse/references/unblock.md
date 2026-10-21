# When a site blocks or challenges the browser

Set the baseline before the first block, then climb one rung at a time and re-test after each. Never loop on the same setup.

## Baseline for logged-in or defended sites
- `stealth: true` (adds an ISP proxy from a shared Kernel pool, with one exit IP per browser that may differ next time, and automatic captcha solving), headful (leave `headless` unset), a saved profile, and a human-like path: open the home page and click through, do not jump to deep links. Source: https://www.kernel.sh/docs/browsers/bot-detection/overview
- New site you have not run before: `manage_config_registry` `action: lookup` with the URL returns Kernel's recommended browser config when one exists.

## The ladder
1. **Captcha or "checking your browser" page with stealth on**: do not click the widget. Wait about 10-15 s and check the page again; the solver works on its own. If it is still there, take one screenshot to see what it is.
2. **Blocked or 403 without stealth**: recreate with `stealth: true`, headful, same profile.
3. **Blocked with stealth**: add a dedicated ISP proxy (one static exit IP) for that identity: `manage_proxies` `action: list` to find one the user already has. Creating a proxy is the user's call (it can cost money): ask first.
4. **Content depends on country**: a residential proxy with the least specific targeting that works (country before city).
5. **A 502 from the browser's navigation**: Kernel's proxy layer failed. Read the `x-kernel-proxy-error` response header in Playwright (`(await page.goto(url)).headers()['x-kernel-proxy-error']`) before changing anything. Do not resubmit a form after `origin_response_incomplete`: it may have gone through.
6. **Banks, payment processors, government sites, postal services**: Kernel's proxies are often refused there. Try `proxy: { mode: "direct" }`; if that also fails, tell the user.
7. **Still blocked**: stop and report what you tried. A person may need to log in through the live view (`/kernel-browser:login`), or the site does not allow automation.

## Logged-in identities and IPs
A site that sees the same account from a new IP each time asks for 2FA or locks the account. For any profile used for logged-in work, pick one ISP proxy and pass the same `proxy: { name }` on every browser for that profile. Mention it in the profile's name or tell the user which proxy goes with which profile.

## Do not
- Do not click captchas, rotate user agents or add random delays: stealth handles fingerprinting; manual tricks make it worse.
- Do not retry a blocked create-and-navigate loop: each attempt burns time and can flag the account.
- Do not use a throwaway profile for an account that matters: challenges keep coming back without a stable profile.

Sources: https://www.kernel.sh/docs/browsers/bot-detection/stealth, https://www.kernel.sh/docs/proxies/overview, the kernel-dev plugin's `unblock.md` (verified live 2026-10-20).
