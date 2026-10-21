# Saved logins: profiles, one writer, many readers

## The model
- A **profile** is a saved browser state (cookies, local storage, and so on) with a name. A browser created with `profile_name` starts from a snapshot of it. Nothing syncs between running browsers.
- A browser created with `save_profile_changes: true` **replaces** the whole stored profile with its final state when it is deleted or times out. No merge. Closing only a Playwright or CDP connection does not save. Source: https://www.kernel.sh/docs/browsers/profiles
- Without `save_profile_changes`, everything the browser does to the profile is thrown away. Verified live (kernel-dev ledger): a login with save off, then a new browser on the profile was logged out.
- There is no import of a login from your own Chrome. A profile gets its login only inside a Kernel browser: `/kernel-browser:login`.

## "Fork" one login to many agents: yes, that is the native pattern
- Any number of browsers can load the same profile **read-only** (no `save_profile_changes`) at the same time. Each is a private copy: what one agent does there is thrown away when it ends. Source: https://www.kernel.sh/docs/browsers/profiles/agent-patterns
- Exactly **one** writer refreshes the stored login: a Managed Auth connection (Kernel re-logs in and saves by itself), or one refresh browser created with `save_profile_changes: true` that you verify as signed in and then delete. Newly created readers see the refreshed login; running readers keep their snapshot.
- Two writers on one profile: the one that ends last silently overwrites the other. A writer that ends logged out (an expired session, a failed run) saves the logged-out state over the good one. So readers never save, and a refresh writes only after you saw the signed-in page.

Before you start a writer, look for another one: `manage_browsers` `action: list` with `query: "<profile id>"` and check each result's `profile_save_changes`. The check and the create are two calls, so this is best effort, not a lock.

## Where forking breaks (tell the user when it applies)
| Site behavior | What you see | Do |
|---|---|---|
| Rotating refresh tokens (each use invalidates the previous token) | the first reader works, later readers are logged out | refresh through Managed Auth or one writer before each batch; run readers one after another, or one browser with named executors |
| One session per account (a new login logs the others out) | parallel readers log each other out | one browser with named executors (tabs share one live cookie jar) instead of several browsers |
| New-device or new-location checks | a 2FA or "is this you" prompt on a profile that worked | the same exit IP for that identity every time: one ISP proxy per identity (`unblock.md`), created once and passed as `proxy` on every browser |
| Short session lifetime | readers fail after hours or days | a Managed Auth connection with health checks on, or a refresh before use |

## Many tasks as the same user at once
Prefer one browser on the profile with one named executor per task (`tools.md`): tabs share a live cookie jar, there is one snapshot and no writer conflict. Use several reader browsers only when tasks need separate egress or must not see each other's tabs.

## Choosing and naming
- One profile per site account: `github-work`, `github-personal`, `gmail-main`. Names are 1-255 characters of letters, digits, `.`, `_`, `-`, unique per project.
- Avoid one profile logged in to dozens of sites: it loads everything every time, and one bad writer loses every login.
- When several profiles match a site, ask the user; never take the first match.

## Find, inspect, fix
- `manage_profiles` `action: list` (`query`) and `get`; `manage_auth_connections` `action: list` (`domain_filter`) for profiles that a connection keeps logged in.
- "Works on profile A, not on B": `/kernel-browser:diff-profiles <a> <b>` compares cookie names, domains and storage keys, never values.
- Rename with `manage_profiles` `action: rename`. Delete only a profile the user asks you to delete: it cannot be undone and it logs every future browser out.
