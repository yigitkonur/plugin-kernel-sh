# Profiles: state that must outlive a browser

A profile persists cookies, site data, open tabs and preferences across browser sessions (https://www.kernel.sh/docs/browsers/profiles). Read this before you write any code that logs in once and expects to stay logged in, or that runs more than one browser against the same identity.

## The model in five lines

- A browser loads a snapshot of the profile when it starts. Nothing syncs between running browsers.
- `save_changes: true` replaces the whole stored profile with that browser's final state, when the browser is deleted or times out. No merge.
- Without `save_changes` (false or omitted) everything the browser does to the profile is thrown away. Verified live: login with `save_changes` false and omitted, then a new browser was logged out.
- The profile must exist before `browsers.create` references it (`profiles.create`, or Managed Auth creates it for `profile_name`; see `references/logins.md`).
- Names: 1-255 characters of letters, numbers, `.`, `_`, `-`; unique per project. `user-${email}` breaks on `@` and `+` (SDK type `BrowserProfile`).

## Persist state (the default recipe)

**If** the next browser must start logged in, or must resume where this one stopped
**Do** attach the profile with `save_changes: true` to exactly one browser, do the work, then `deleteByID`. Open later browsers with `profile: { name }` and no `save_changes`.
**Avoid** treating `browser.close()` or a dropped socket as a save. Verified live: after closing only the CDP client and waiting 10 s, the profile's `updated_at` was unchanged and the stored archive held no login; `updated_at` moved only when the browser was deleted. Also avoid a second writer and renaming the profile while it is in use.
**Source** https://www.kernel.sh/docs/browsers/profiles, https://www.kernel.sh/docs/browsers/profiles/save-and-reuse

```ts
// one writer, delete in finally
import Kernel from '@onkernel/sdk';
const kernel = new Kernel();
const browser = await kernel.browsers.create(
  { timeout_seconds: 300, profile: { name: 'my-profile', save_changes: true }, tags: { run: process.env.RUN_ID ?? 'local' } },
  { maxRetries: 0, timeout: 30_000 },
);
try {
  const res = await kernel.browsers.playwright.execute(
    browser.session_id, { code, timeout_sec: 60 }, { maxRetries: 0, timeout: 90_000 });
  console.log(`success=${res.success} error=${res.error ?? ''}`);
} finally {
  // this is the save; a 404 means the timeout already reaped the browser
  await kernel.browsers.deleteByID(browser.session_id).catch((e) => {
    if (!(e instanceof Kernel.NotFoundError)) throw e;
  });
}
```

Notes that change what you do:
- Reader browsers: `profile: { name: 'my-profile' }` (verified live: new browser opened `/secure` still logged in).
- The save also happens on timeout (docs). No writer was ever left to time out (unverified: timing of the save after an idle timeout), so delete explicitly.
- `start_url` on create (or on update when loading a profile) discards the restored tabs and opens one page. Without it, the saved tabs come back. Source https://www.kernel.sh/docs/browsers/profiles/save-and-reuse (untested).

## Create the profile first

**If** `browsers.create` must reference a profile that may not exist yet
**Do** create it once and ignore the conflict.
**Avoid** assuming `browsers.create` makes it for you.
**Source** https://www.kernel.sh/docs/browsers/profiles/save-and-reuse

```ts
// a repeat run takes the catch path (409 profile already exists)
import Kernel, { ConflictError } from '@onkernel/sdk';
const kernel = new Kernel();
try {
  await kernel.profiles.create({ name: 'my-profile' });
} catch (err) {
  if (!(err instanceof ConflictError)) throw err;
}
```

CLI: `kernel profiles create --name my-profile`, `kernel browsers create --profile-name my-profile --save-changes`. `kernel profiles delete my-profile --yes` needs `--yes`: without it the command fails when stdin is not a terminal and deletes nothing. (flags from the CLI source, https://github.com/kernel/cli, `cmd/profiles.go` and `cmd/browsers.go`; `--profile-id` is the alternative and the two are mutually exclusive).

## One script that logs in only when the profile is empty

**If** a single unattended script must log in once and reuse the session on later runs
**Do** create the profile (ignore the conflict), open a browser with `save_changes: true`, detect the login state inside the page, log in only if needed, and `deleteByID` in `finally`. One writer per run, runs sequential. Verified live: run 1 logged in, run 2 reused the profile and skipped the login. For throwaway or demo accounts only; the password handling (env at run time, `JSON.stringify` into `code`, never logged or committed) and the real-account paths are in `references/logins.md`, "Scripted login once, reuse the profile".
**Avoid** two overlapping runs (second writer overwrites the first), and a password in a file, a log or a command line.
**Source** https://www.kernel.sh/docs/browsers/profiles/save-and-reuse

```ts
// PROFILE, BASE, USER, PASSWORD come from your config/env
import Kernel, { ConflictError } from '@onkernel/sdk';
const kernel = new Kernel();
const code = `
await page.goto(${JSON.stringify(BASE)} + '/secure', { waitUntil: 'domcontentloaded' });
const wasLoggedIn = page.url() === ${JSON.stringify(BASE)} + '/secure'; // redirected to /login if not
if (!wasLoggedIn) {
  await page.goto(${JSON.stringify(BASE)} + '/login', { waitUntil: 'domcontentloaded' });
  await page.fill('#username', ${JSON.stringify(USER)});
  await page.fill('#password', ${JSON.stringify(PASSWORD)});
  await Promise.all([page.waitForURL('**/secure', { timeout: 15000 }), page.click('button[type="submit"]')]);
}
return { wasLoggedIn };`;
try {
  await kernel.profiles.create({ name: PROFILE }, { maxRetries: 0, timeout: 30_000 });
} catch (e) {
  if (!(e instanceof ConflictError)) throw e;
}
const browser = await kernel.browsers.create(
  { headless: true, timeout_seconds: 300, profile: { name: PROFILE, save_changes: true }, tags: { run: 'login' } },
  { maxRetries: 0, timeout: 30_000 },
);
try {
  const res = await kernel.browsers.playwright.execute(browser.session_id, { code, timeout_sec: 60 }, { maxRetries: 0, timeout: 90_000 });
  if (!res.success) throw new Error(`execute failed: ${String(res.error)}`);
} finally {
  // this is the save; a 404 means the timeout already reaped the browser
  await kernel.browsers.deleteByID(browser.session_id).catch((e) => {
    if (!(e instanceof Kernel.NotFoundError)) throw e;
  });
}
```

## Many workers, same login

**If** many browsers need the same logged-in starting point (scraping, read-only checks, fixtures)
**Do** load one profile without `save_changes` in every worker. Refresh the baseline with one separate setup job that is the only writer. Newly started browsers see the refreshed baseline; running ones keep the snapshot they loaded.
**Avoid** workers writing back: the browser that ends last overwrites the others, silently.
**Source** https://www.kernel.sh/docs/browsers/profiles/agent-patterns, https://www.kernel.sh/docs/browsers/profiles/concurrency

## One identity per end user or account

**If** your product acts for many users, or one user has accounts that need separate cookies, proxies or lifetimes
**Do** one profile per end user, or per connected account when the accounts must not share cookies. Name it from your own opaque id (not an email). One writer per profile.
**Avoid** one shared writable profile for unrelated users or concurrent agents. Also avoid one mega-profile that has logged into dozens of SaaS products: there is no way to load only some origins (`references/does-not-exist.md`, `browser.profile.origins`), so the whole profile loads every time.
**Source** https://www.kernel.sh/docs/browsers/profiles/agent-patterns

```ts
// untested (docs snippet)
const browser = await kernel.browsers.create({
  profile: { name: `user-${userId}`, save_changes: true },
  stealth: true,
});
```

## Concurrent tasks for one user

**If** several tasks act as the same user at the same time
**Do** run one profiled browser and give each task its own tab through a named Playwright executor (https://www.kernel.sh/docs/introduction/control). Tabs share a live cookie jar and persistent origin storage; `sessionStorage` stays per tab. For tab-heavy work on a headful non-GPU browser the docs suggest `memory: '16GiB'` over the `8GiB` default.
**Avoid** one browser per task from the same profile: each loads a stale snapshot, and only one of them may write.
**Source** https://www.kernel.sh/docs/browsers/profiles/concurrency (untested: executors with profiles)

## Detect a writer before you start one

**If** more than one worker or run can start a writer for the same profile
**Do** list active browsers by profile id and look for `profile_save_changes`, under your own lock or lease that also covers the create.
**Avoid** check-then-create without a lock: the check and the create are two requests, so two workers can both pass.
**Source** https://www.kernel.sh/docs/browsers/profiles/concurrency

```ts
// untested (writer check; only profile_save_changes of a single browser was observed)
const profile = await kernel.profiles.retrieve(name); // by name or id
const writers: string[] = [];
for await (const b of kernel.browsers.list({ status: 'active', query: profile.id })) {
  if (b.profile?.id === profile.id && b.profile_save_changes) writers.push(b.session_id);
}
if (writers.length > 0) throw new Error(`profile already has a writer: ${writers[0]}`);
```

Verified live: `query` set to the profile id returned that browser (total 1 with one writer running). No other active browser was present to be excluded, so the filter's precision was not tested. Two concurrent writers were not raced: last writer wins was shown with sequential writers only (login writer, then logout writer, then a third browser showed logged-out).

## Load a profile into a running browser

**If** a browser already exists and you need a profile in it
**Do** `browsers.update(id, { profile: { name }, start_url })` only on a browser created without a profile, then reconnect: Chromium restarts and CDP clients are disconnected.
**Avoid** loading into a browser that already has a profile (rejected by the API per the docs), and keeping a stale Playwright connection across the update.
**Source** https://www.kernel.sh/docs/browsers/profiles/save-and-reuse#load-a-profile-after-browser-creation (untested). CLI: `kernel browsers update --profile-name ... --save-changes` (https://github.com/kernel/cli).

## Rename

**If** you rename a profile
**Do** do it when no browser uses it, and reference live profiles by `id` in code that might race a rename. `kernel.profiles.update(name, { name: newName })` only renames; the id is unchanged.
**Avoid** renaming while a browser holds the profile by name. Verified live: the rename succeeded while a browser was running, the old name returned 404 immediately, the id stayed the same. The SDK doc says a rename "may prevent that session's changes from saving"; it was not checked whether the running browser's save still landed (unverified), so treat it as unsafe.
**Source** SDK `profiles.update` doc, https://www.kernel.sh/docs/browsers/profiles/save-and-reuse#rename-and-manage-profiles

## Pools and profiles

**If** you use browser pools (`references/scale.md`)
**Do** for per-user state: create the pool without a profile, `acquire` with `profile: { name, save_changes: true }`, then `release` with `reuse: false` so the next acquirer does not inherit that user. Verified live: an acquire-time profile with `save_changes: true` was writable and the cookie persisted to the next acquire.
**Avoid** relying on a profile set on the pool itself for writes: the docs say a pool-level profile is read-only and `save_changes` is ignored. Pool-level profiles were not tested.
**Source** https://www.kernel.sh/docs/browsers/profiles/concurrency#use-profiles-with-browser-pools

## Inspect or export a profile (without leaking it)

**If** you need to see what a profile holds, or compare two profiles
**Do** download it and read counts and names, not values. Default format is a zstd-compressed tar (`application/zstd`, about 46 KB for a one-login profile); `format: 'tar'` gives a plain tar (about 5.5 MB, 212 entries). The CLI extracts a Chromium user-data layout (`Default/`, `Local State`, ...) into a directory (151 files observed).
**Avoid** printing cookie values, committing the archive, or assuming zip. A profile that never had a save downloads as 0 bytes with no error (HTTP status not captured), so check the size before parsing.
**Source** SDK `profiles.download` doc

```ts
import { writeFileSync } from 'node:fs';
const res = await kernel.profiles.download(name, { format: 'tar' }); // omit for zstd
const buf = Buffer.from(await res.arrayBuffer());
writeFileSync(outFile, buf);
console.log(`bytes=${buf.length} content-type=${res.headers.get('content-type')}`);
```

CLI: `kernel profiles download <name> --to <dir>` extracts into `<dir>` (`--format tar.zst` is the default, or `tar`). `kernel profiles delete <name> --yes` needs `--yes` (see the create recipe above).

## "Works on profile A, not on B"

**If** the same login works in one profile and fails in another
**Do** run `/kernel:diff-profiles <a> <b>`. By hand: download both with `kernel profiles download --to`, compare cookie names and domains, storage keys and preference keys, never values.
**Avoid** printing cookie values into the chat or logs.
**Source** `/kernel:diff-profiles` workflow

## Profiles and logins

**If** the profile holds a login made by Managed Auth
**Do** pass the same name as `profile_name`; a new browser on that profile opened logged in (verified live). Details in `references/logins.md`.
**Avoid** relying on the login before the connection has finished.
**Source** https://www.kernel.sh/docs/browsers/profiles

**If** a vault fills the sign-in inside the browser
**Do** attach a profile with `save_changes: true` to keep the result.
**Avoid** treating `completed` as proof the login worked (`references/vaults-payments.md`).
**Source** `references/vaults-payments.md`

**If** bot challenges keep appearing
**Do** pair a stable profile with a consistent proxy; see `references/unblock.md`.
**Avoid** a throwaway profile or a changing proxy for the same account.
**Source** https://www.kernel.sh/docs/browsers/profiles (section "Reduce bot challenges")

## Avoid list (old names)

- `persistent: true`, `persistence: { id }`, `--persistent-id`: removed. Use `profile: { name, save_changes: true }` on one browser plus `timeout_seconds`.
- `browser.close()` or a closed CDP client as "save": it only disconnects.
- `browser.profile.origins` and similar origin filters: not an API.

Source: `references/does-not-exist.md` (persistent names removed 2026-05-21; `browser.profile.origins` is a docs proposal, not an API).

Verified live 2026-10-20 (Hobbyist plan); types re-checked on @onkernel/sdk 0.128.0. Evidence ledger: https://github.com/yigitkonur/plugin-kernel-sh/blob/main/verified-facts.md
