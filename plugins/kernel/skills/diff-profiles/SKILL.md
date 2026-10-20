---
name: diff-profiles
description: >-
  Compare two Kernel profiles (cookies, storage, preferences, extensions, login state) without printing values, and explain why a flow works on one and not the other.
argument-hint: "<profile-a> <profile-b> [issue]"
disable-model-invocation: true
---

# Diff two Kernel profiles

Compare what two profiles actually contain, find the state that explains "works on A, fails on B", and report it without printing any value. The argument is the text after the skill name in the user's message (or the line starting ARGUMENTS:): `<profile-a> <profile-b> [issue]`. Profile A is the working baseline, B the broken one. If either profile is missing, ask for it. If the issue is missing, do not ask: default to Cookies, Session Storage, Local Storage and Preferences and proceed.

## Rules

- Never print cookie values, `Login Data` username/password columns, tokens, or storage values. Emit host, name, lengths, counts and presence only.
- Never print API keys or any CDP / live-view / replay / hosted-login URL.
- The extracted profile is sensitive. Put it in a new empty temp directory and remove it on every exit path (step 7).
- Only read: `profiles get`, `profiles download`, `browsers list`. Never create or delete resources.
- Do not dump file listings or diffs into the context. Summarize with counts, `head`, and `jq`.

## 1. Preflight

1. Run `command -v kernel`. If it is missing, print these and stop (never install silently):
   - `brew install kernel/tap/kernel`
   - `npm i -g @onkernel/cli`
2. Run `command -v jq sqlite3`. `jq` is required. `sqlite3` is only needed for the cookie and `Login Data` steps; without it, skip those and say so in the report.
3. If the user named a project, add `--project <id-or-name>` to every `kernel profiles` and `kernel browsers` command below. Names and IDs resolve inside the CLI's active project.

## 2. Resolve both profiles

Run now:

```bash
WORKDIR=$(mktemp -d -t profile-diff-XXXXXX); mkdir -p "$WORKDIR/a" "$WORKDIR/b" "$WORKDIR/diff"; cd "$WORKDIR"; echo "$WORKDIR"
kernel profiles get "$A" -o json > diff/profile-a.json
kernel profiles get "$B" -o json > diff/profile-b.json
jq -r '[.id,.name,.created_at,.updated_at,.last_used_at] | @tsv' diff/profile-a.json diff/profile-b.json
```

(Replace `$A` and `$B` with the two values from the user.)

Shell state does not persist between Bash calls. Note the printed workdir path, and start every later block with `cd <that literal path>` and use the literal profile names in place of `$A` and `$B`. Do the same for cleanup.

**On every stop after the download step (same id, 404, "no saved data", empty archive, any error), run the cleanup step (7) first, then report.**

- If both resolve to the same `id`, stop and tell the user.
- Compare `updated_at`. A profile is only written when a browser that had `save_changes: true` is deleted or times out (docs). Closing a Playwright/CDP connection does not save it, so a stale `updated_at` on B often is the answer. Say so in the report.
- If a get fails with 404, the name or project is wrong; stop and ask.
- Setting up inputs: a profile is created and saved by a browser created with `--profile-name X --save-changes` and then deleted (see ../kernel/references/profiles.md). A profile that was created but never saved has no archive.

## 3. Download both

Run now:

```bash
kernel profiles download "$A" --to a   # use the literal names here
kernel profiles download "$B" --to b
for s in a b; do echo "$s: $(find "$s" -type f | wc -l) files"; done   # counts only, no names
```

- `--to` is an extraction directory, not a filename. The CLI extracts for you; do not run `unzip`, `tar` or `zstd` (CLI source: the default is a zstd tarball, not zip, and it extracts a Chromium user-data layout).
- Keep the default `--format tar.zst`. Use `--format tar` only if decompression fails.
- If the CLI says the profile "has no saved data yet" (it prints this on HTTP 202 and still exits 0, so do not rely on exit status), stop: that profile was never saved. Tell the user to run a browser with `profile: { name, save_changes: true }` and delete the browser, then retry. The SDK can also return a 0-byte archive with no error, so treat an empty `a/` or `b/` as "never saved".
- Expect `Default/` (cookies, `Preferences`, `Local Storage`, `Session Storage`, `IndexedDB`, `Extensions`) and `Local State` at the top level. Use `find` for paths: newer Chrome keeps cookies in `Default/Network/Cookies`.

## 4. Pick surfaces from the issue

Do not compare everything. Start from this table; when in doubt use Cookies + Session Storage + Local Storage + Preferences.

| Issue mentions | Compare first |
|---|---|
| login, signed out, session | Cookies, Session Storage, Local Storage, Login Data |
| SPA with `#/` routes | Session Storage first, then Local Storage, then Cookies |
| captcha, challenge, blocked, bot vendor | Cookies (vendor names), Local Storage, `Preferences` |
| extension, content script | `Extensions/`, `Local Extension Settings/`, `Secure Preferences` |
| autofill, saved password | Login Data (lengths only) |
| language, timezone, viewport | `Preferences`, `Secure Preferences` |
| quota, offline data | Local Storage, IndexedDB, Service Worker |

For any surface without a block in step 5 (Secure Preferences, Local Extension Settings, IndexedDB, Service Worker), compare only file counts and `du -sk` sizes; never `cat` or `strings` it. Skip `Cache/`, `Code Cache/`, `GPUCache/` and `Service Worker/CacheStorage/`: noise.

## 5. Focused diffs

The cookie, storage and extension blocks have been run on two real profiles. Run only the ones the table selected.

**Cookies** (select `length(encrypted_value)`, never `value`; modern Chrome encrypts the value and leaves `value` empty, per the Kernel profile-archive reference skill):

```bash
for s in a b; do
  DB=$(find "$s" -name Cookies -not -name '*-journal' | head -1)
  [ -n "$DB" ] && sqlite3 "$DB" "SELECT host_key, name, length(encrypted_value), is_secure, is_httponly, samesite, expires_utc FROM cookies ORDER BY host_key, name;" > "diff/cookies-$s.txt"
done
diff diff/cookies-a.txt diff/cookies-b.txt | head -40
```

If the issue names a host, add `WHERE host_key LIKE '%<host>%'`, but only if `<host>` matches `^[A-Za-z0-9.-]+$`; otherwise skip the filter. Flag these vendor cookie names when present on one side only: `_abck`, `bm_sz`, `bm_sv` (Akamai); `__cf_bm`, `cf_clearance` (Cloudflare); `datadome`; `_px*`, `pxvid` (HUMAN); `incap_ses_*`, `visid_incap_*`, `reese84` (Imperva). The SQL output contains names and lengths only. Noise: analytics cookies (for example `optimizely*`) change on every run (`expires_utc` and lengths), so compare `host_key`+`name` presence, and treat a length difference as meaningful only for the session cookie the user cares about.

**Preferences**:
```bash
for s in a b; do P=$(find "$s" -name Preferences -not -path '*/Extension*' | head -1); [ -n "$P" ] && jq -r '[paths(scalars) | map(tostring) | join(".")] | .[]' "$P" | sort > "diff/pref-keys-$s.txt"; done
diff diff/pref-keys-a.txt diff/pref-keys-b.txt | head -60
```

Look at `intl.*`, `profile.default_content_setting_values`, `webrtc.*`, `extensions.settings`, `dns_over_https.*`. Preferences can hold identifiers; the diff above lists key paths only. To check a value, query one known non-sensitive path (for example `jq '.intl.accept_languages'`), never the whole file.

**Local Storage and Session Storage** (LevelDB, read with `strings`, key names and origins only, never values). LevelDB stores a value right after its key, so a token can match the key pattern. Patterns are capped and a guard discards the whole file if any line is over 40 chars or token-shaped:

```bash
guard() { ! awk 'length>40 || /eyJ/ || /[A-Za-z0-9+\/_=-]{24,}/ {f=1} END{exit !f}' "$1"; }
for s in a b; do
  SS=$(find "$s" -type d -name 'Session Storage' -not -path '*/Extension*' | head -1)
  [ -n "$SS" ] && strings "$SS"/*.log "$SS"/*.ldb 2>/dev/null | grep -oE 'map-[0-9]+-[A-Za-z._0-9-]{1,41}' | sed -E 's/^map-[0-9]+-//' | sort -u > "diff/ss-keys-$s.txt"
  LS=$(find "$s" -type d -name 'Local Storage' -not -path '*/Extension*' | head -1)
  [ -n "$LS" ] && strings "$LS"/leveldb/*.log "$LS"/leveldb/*.ldb 2>/dev/null | grep -oE '^_https?://[A-Za-z0-9.-]{1,41}(:[0-9]{1,5})?' | sort -u > "diff/ls-origins-$s.txt"
done
for f in ss-keys-a ss-keys-b ls-origins-a ls-origins-b; do [ -f "diff/$f.txt" ] && ! guard "diff/$f.txt" && rm -f "diff/$f.txt" && echo "DISCARDED $f"; done
[ -f diff/ss-keys-a.txt ] && [ -f diff/ss-keys-b.txt ] && diff diff/ss-keys-a.txt diff/ss-keys-b.txt | head -40
[ -f diff/ls-origins-a.txt ] && [ -f diff/ls-origins-b.txt ] && diff diff/ls-origins-a.txt diff/ls-origins-b.txt | head -40
```

A storage surface can be present yet yield nothing. In a real run, Session/Local Storage had 6 files per profile and the patterns extracted zero keys on both sides; that cannot tell "the site stores nothing there" from "the pattern missed LevelDB content" (`strings` only sees uncompressed bytes, and `.ldb` blocks may be compressed). So if a surface has files but its key file is empty or missing, never write "no difference". Report `Session Storage: no keys extracted (files present: N)` (same for Local Storage) and fall back to file counts and `du -sk` sizes of the directory on each side, e.g. `for s in a b; do find "$s" -type d -name 'Session Storage' -not -path '*/Extension*' | head -1 | while read -r d; do echo "$s $(ls "$d" | wc -l) files $(du -sk "$d" | cut -f1) KB"; done; done`. Treat a count or size difference as a hint only, and say key names were not compared.

If a file was discarded, show neither diff of that pair; report `Session Storage: not checked (value bytes adjacent)` (or `Local Storage: ...`) under "Not checked". `map-N` numbers differ between profiles and mean nothing; the `sed` strips them. Look for auth-shaped keys missing on B (`authCookie`, `sessionGUID`, `*_token`, tenant or account GUIDs).

**Extensions and Login Data**:
```bash
for s in a b; do E=$(find "$s" -type d -name Extensions -not -path '*/Local Extension*' | head -1); [ -n "$E" ] && ls "$E" > "diff/ext-$s.txt"; done
diff diff/ext-a.txt diff/ext-b.txt
for s in a b; do L=$(find "$s" -name 'Login Data' -not -name '*-journal' | head -1); [ -n "$L" ] && sqlite3 "$L" "SELECT origin_url, length(username_value) > 0, length(password_value) FROM logins ORDER BY origin_url;" > "diff/logins-$s.txt"; done
diff diff/logins-a.txt diff/logins-b.txt | head -20
```

Extension IDs are 32-char hashes; map an ID to a name through `Extensions/<id>/<version>/manifest.json` (`jq -r .name`). Print `origin_url` and lengths only.

**Inventory** (catches missing databases): `for s in a b; do (cd "$s" && find . -type f | sort) > "diff/files-$s.txt"; done; diff diff/files-a.txt diff/files-b.txt | grep -v -E 'Cache' | head -30`

## 6. Interpret

Tie every difference to the issue; do not paste raw diffs. Likely causes, strongest first:

- Auth cookie present on A, missing or short on B: session not established or evicted.
- Session Storage auth keys missing on B while cookies match: B was saved before the SPA finished its post-login bootstrap.
- B's `updated_at` is old or equal to creation: the writer never deleted its browser, or ran without `save_changes: true`, so nothing was saved.
- Bot-vendor cookie only on A: A already cleared the challenge; B will be re-challenged.
- `intl.*`, `webrtc.*` or `dns_over_https.*` differ: locale and fingerprint branches differ.
- Extension or Login Data row on A only: page behavior or autofill differs on B.
- Local Storage origin or IndexedDB auth origin (Firebase, Clerk) populated on A only: site session state is absent on B.

Profiles are last-writer-wins: if two jobs share a profile with `save_changes: true`, the later deletion overwrites the earlier. Check this when B "lost" state A had. To find a live writer, run `kernel browsers list --status active -o json` (add `--project` if one was named) and filter with `jq '.[] | select(.profile.id=="<id>") | {session_id, profile_save_changes}'`. Renaming a profile keeps its id and the old name stops resolving at once. If a script still uses the old name, that explains a 404 on one side.

## 7. Cleanup

Run this with the literal workdir path printed in step 2 (`$WORKDIR` is not set in a new Bash call), unless the user asks to keep the data:

```bash
case "<literal workdir path>" in */profile-diff-*) rm -rf -- "<literal workdir path>";; esac
```

This runs on every stop after the download step, not only at the end. If kept, tell them the path and that it may contain credentials.

## Report format

Reply with exactly this structure:

```
## Profile diff: <A> vs <B>
Issue: <one line>
Profiles: A <id>, updated <ts>; B <id>, updated <ts>

Likely root causes (ranked)
1. <finding> - evidence: <surface, host/key names, lengths> - why it matches the issue
2. ...

Other differences (probably unrelated)
- <finding>

Matched surfaces
- <surface>: identical

Next steps
- <concrete action, e.g. re-save B by deleting its browser after the page finishes loading>

Storage keys extracted: <n> (files present: <n>)
Not checked: <surfaces skipped, tools missing>
Workspace: removed | kept at <path>
```

Never include values, only names, counts and lengths.

---
Verified 2026-10-20 against SDK 0.128.0 / CLI 0.49.0; see the plugin repository's verified-facts.md and ../kernel/references/profiles.md.
