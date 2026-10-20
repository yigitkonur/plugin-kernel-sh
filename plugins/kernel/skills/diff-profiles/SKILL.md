---
name: diff-profiles
description: >-
  Compare two Kernel profiles (cookies, storage, preferences, extensions, login state) without printing values, and explain why a flow works on one and not the other.
argument-hint: "<profile-a> <profile-b> [issue]"
disable-model-invocation: true
---

# Diff two Kernel profiles

Compare what two profiles actually contain, find the state that explains "works on A, fails on B", and report it without printing any value. The argument is the text after the skill name in the user's message (or the line starting ARGUMENTS:): `<profile-a> <profile-b> [issue]`. Profile A is the working baseline, B the broken one. If either profile is missing, ask for it. If the issue is missing, ask for it too: it decides which surfaces to weight.

## Rules

- Never print cookie values, `Login Data` username/password columns, tokens, or storage values. Emit host, name, lengths, counts and presence only.
- Never print API keys or any CDP / live-view / replay / hosted-login URL.
- The extracted profile is sensitive. Put it in a new empty temp directory and remove it at the end.
- Never run `kernel` commands that create or delete resources here. This skill only reads (`profiles get`, `profiles download`).
- Do not dump file listings or diffs into the context. Summarize with counts, `head`, and `jq`.

## 1. Preflight

1. Run `command -v kernel`. If it is missing, print these and stop (never install silently):
   - `brew install kernel/tap/kernel`
   - `npm i -g @onkernel/cli`
2. Run `command -v jq sqlite3`. `jq` is required. `sqlite3` is only needed for the cookie and `Login Data` steps; without it, skip those and say so in the report.
3. If the user named a project, add `--project <id-or-name>` to every `kernel profiles` command below. Names and IDs resolve inside the CLI's active project.

## 2. Resolve both profiles

Run now:

```bash
WORKDIR=$(mktemp -d -t profile-diff-XXXXXX); mkdir -p "$WORKDIR/a" "$WORKDIR/b" "$WORKDIR/diff"; cd "$WORKDIR"; echo "$WORKDIR"
kernel profiles get "$A" -o json > diff/profile-a.json
kernel profiles get "$B" -o json > diff/profile-b.json
jq -r '[.id,.name,.created_at,.updated_at,.last_used_at] | @tsv' diff/profile-a.json diff/profile-b.json
```

(Replace `$A` and `$B` with the two values from the user. `profiles get` flags are from the CLI source; the lab only ran the SDK form: unverified as a shell line.)

Shell state does not persist between Bash calls. Note the printed workdir path, and start every later block with `cd <that literal path>` and use the literal profile names in place of `$A` and `$B`. Do the same for cleanup.

- If both resolve to the same `id`, stop and tell the user.
- Compare `updated_at`. A profile is only written when a browser that had `save_changes: true` is deleted (lab P09, confirmed) or times out (docs; the lab tested deletion only). Closing a Playwright/CDP connection does not save it, so a stale `updated_at` on B often is the answer. Say so in the report.
- If a get fails with 404, the name or project is wrong; stop and ask.

## 3. Download both

Run now:

```bash
kernel profiles download "$A" --to a   # use the literal names here
kernel profiles download "$B" --to b
find a b -maxdepth 2 -type d | sort | head -40
```

- `--to` is an extraction directory, not a filename. The CLI extracts for you; do not run `unzip`, `tar` or `zstd` (CLI source; lab P09: the default is a zstd tarball, not zip, and `kernel profiles download <name> --to <dir>` extracted a Chromium user-data layout, 151 files, SUCCESS).
- Keep the default `--format tar.zst`. Use `--format tar` only if decompression fails.
- If the CLI says the profile "has no saved data yet" (it prints this on HTTP 202 and still exits 0, so do not rely on exit status), stop: that profile was never saved. Tell the user to run a browser with `profile: { name, save_changes: true }` and delete the browser, then retry. (Lab P09 gotcha: the SDK returned a 0-byte archive for a never-saved profile with no error printed, HTTP status not captured, so also treat an empty `a/` or `b/` as "never saved".)
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

Skip `Cache/`, `Code Cache/`, `GPUCache/` and `Service Worker/CacheStorage/`: noise.

## 5. Focused diffs

Every block below starts with an `# untested` comment: the lab verified only the download (it counted 5 cookie rows on a probe profile but did not run these exact lines). Run only the ones the table selected.

**Cookies** (select `length(encrypted_value)`, never `value`; modern Chrome encrypts the value and leaves `value` empty, per the Kernel profile-archive reference skill; not lab-verified):

```bash
# untested
for s in a b; do
  DB=$(find "$s" -name Cookies -not -name '*-journal' | head -1)
  [ -n "$DB" ] && sqlite3 "$DB" "SELECT host_key, name, length(encrypted_value), is_secure, is_httponly, samesite, expires_utc FROM cookies ORDER BY host_key, name;" > "diff/cookies-$s.txt"
done
diff diff/cookies-a.txt diff/cookies-b.txt | wc -l
diff diff/cookies-a.txt diff/cookies-b.txt | head -40
```

If the issue names a host, add `WHERE host_key LIKE '%<host>%'`. Flag these vendor cookie names when present on one side only: `_abck`, `bm_sz`, `bm_sv` (Akamai); `__cf_bm`, `cf_clearance` (Cloudflare); `datadome`; `_px*`, `pxvid` (HUMAN); `incap_ses_*`, `visid_incap_*`, `reese84` (Imperva). The SQL output contains names and lengths only.

**Preferences**:

```bash
# untested
for s in a b; do P=$(find "$s" -name Preferences -not -path '*/Extension*' | head -1); [ -n "$P" ] && jq -r '[paths(scalars) | map(tostring) | join(".")] | .[]' "$P" | sort > "diff/pref-keys-$s.txt"; done
diff diff/pref-keys-a.txt diff/pref-keys-b.txt | wc -l
diff diff/pref-keys-a.txt diff/pref-keys-b.txt | head -60
```

Look at `intl.*`, `profile.default_content_setting_values`, `webrtc.*`, `extensions.settings`, `dns_over_https.*`. Preferences can hold identifiers; the diff above lists key paths only. To check a value, query one known non-sensitive path (for example `jq '.intl.accept_languages'`), never the whole file.

**Local Storage and Session Storage** (LevelDB, read with `strings`, report key names and origin only, never values):

```bash
# untested; first run on a probe profile with a known sessionStorage value and confirm the output is key names only (adjacent value bytes can match the key pattern)
for s in a b; do
  SS=$(find "$s" -type d -name 'Session Storage' -not -path '*/Extension*' | head -1)
  [ -n "$SS" ] && strings "$SS"/*.log "$SS"/*.ldb 2>/dev/null | grep -oE 'map-[0-9]+-[A-Za-z._0-9-]+' | sed -E 's/^map-[0-9]+-//' | sort -u > "diff/ss-keys-$s.txt"
  LS=$(find "$s" -type d -name 'Local Storage' -not -path '*/Extension*' | head -1)
  [ -n "$LS" ] && strings "$LS"/leveldb/*.log "$LS"/leveldb/*.ldb 2>/dev/null | grep -oE '^_https?://[^[:space:]^]+' | sort -u > "diff/ls-origins-$s.txt"
done
diff diff/ss-keys-a.txt diff/ss-keys-b.txt | head -40
diff diff/ls-origins-a.txt diff/ls-origins-b.txt | head -40
```

`map-N` numbers differ between profiles and mean nothing; the `sed` strips them so only key names are compared. Look for auth-shaped keys missing on B (`authCookie`, `sessionGUID`, `*_token`, tenant or account GUIDs).

**Extensions and Login Data**:

```bash
# untested
for s in a b; do E=$(find "$s" -type d -name Extensions -not -path '*/Local Extension*' | head -1); [ -n "$E" ] && ls "$E" > "diff/ext-$s.txt"; done
diff diff/ext-a.txt diff/ext-b.txt
for s in a b; do L=$(find "$s" -name 'Login Data' -not -name '*-journal' | head -1); [ -n "$L" ] && sqlite3 "$L" "SELECT origin_url, length(username_value) > 0, length(password_value) FROM logins ORDER BY origin_url;" > "diff/logins-$s.txt"; done
diff diff/logins-a.txt diff/logins-b.txt | head -20
```

Extension IDs are 32-char hashes; map an ID to a name through `Extensions/<id>/<version>/manifest.json` (`jq -r .name`). Print `origin_url` and lengths only.

**Inventory** (catches missing databases):

```bash
# untested
for s in a b; do (cd "$s" && find . -type f | sort) > "diff/files-$s.txt"; done
diff diff/files-a.txt diff/files-b.txt | grep -v -E 'Cache|GPUCache' | wc -l
diff diff/files-a.txt diff/files-b.txt | grep -v -E 'Cache|GPUCache' | head -30
```

## 6. Interpret

Tie every difference to the issue; do not paste raw diffs. Likely causes, strongest first:

- Auth cookie present on A, missing or short on B: session not established or evicted.
- Cookies match but Session Storage auth keys are missing on B: B was saved before the SPA finished its post-login bootstrap (save-time race).
- B's `updated_at` is old or equal to creation: the writer never deleted its browser, or ran without `save_changes: true`, so nothing was saved (lab P09, confirmed).
- Bot-vendor cookie only on A: A already cleared the challenge; B will be re-challenged.
- `intl.*`, `webrtc.*` or `dns_over_https.*` differ: locale and fingerprint branches differ.
- Extension on one side only: it can change page behavior.
- Login Data row on A only: autofill will not fire on B.
- Local Storage origin has keys on A only: site-managed session state (JWT, flags) will not apply.
- IndexedDB for an auth origin (Firebase, Clerk) empty on B: SDK token cache is absent.

Profiles are last-writer-wins (lab P09, confirmed for sequential writers): if two jobs share a profile with `save_changes: true`, the later deletion overwrites the earlier. Check this when B "lost" state A had. To find a live writer, run `kernel browsers list --status active -o json` and filter with `jq '.[] | select(.profile.id=="<id>") | {session_id, profile_save_changes}'` (untested field path; the lab confirmed `profile_save_changes` via the SDK `browsers.list({ status: 'active', query: <profile id> })`).

Renaming a profile keeps its id and the old name stops resolving at once (lab P09, confirmed). If a script still uses the old name, that explains a 404 on one side.

## 7. Cleanup

Run `rm -rf <literal workdir path>` (the path printed in step 2; `$WORKDIR` is not set in a new Bash call, and an empty expansion removes nothing) unless the user asks to keep the data. If kept, tell them the path and that it may contain credentials.

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

Not checked: <surfaces skipped, tools missing>
Workspace: removed | kept at <path>
```

Never include values, only names, counts and lengths.
