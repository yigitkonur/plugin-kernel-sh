#!/bin/sh
# run.sh -- test suite for the kernel plugin hooks, detection, rules and CLI. POSIX sh. No network, no Kernel API key.
#   sh tests/run.sh               run everything with $KP_SH (default: sh) as the hook interpreter
#   sh tests/run.sh --all-shells  rerun under sh, /bin/dash and a GNU-coreutils PATH (macOS: brew coreutils)
# Prints PASS/FAIL/SKIP/INFO per case; exit 1 if any case failed.
# Optional: KP_K8S=<dir with a kubernetes clone> for the cold-scan benchmark (git clone --depth 1 https://github.com/kubernetes/kubernetes).

HERE="$(cd "$(dirname "$0")" && pwd)"
R="$(cd "$HERE/.." && pwd)"
P="$R/plugins/kernel"
F="$HERE/fixtures"

if [ "${1:-}" = "--all-shells" ]; then
  rc=0
  echo "=== sh ===";   KP_SH=sh sh "$HERE/run.sh" || rc=1
  if [ -x /bin/dash ]; then echo "=== /bin/dash ==="; KP_SH=/bin/dash /bin/dash "$HERE/run.sh" || rc=1; else echo "SKIP /bin/dash missing"; fi
  G=/opt/homebrew/opt/coreutils/libexec/gnubin
  if [ -d "$G" ]; then echo "=== GNU coreutils first in PATH ==="; PATH="$G:$PATH" KP_SH=sh sh "$HERE/run.sh" || rc=1; else echo "SKIP $G missing"; fi
  exit $rc
fi

KP_SH="${KP_SH:-sh}"
PASS=0; FAIL=0; SKIP=0
W="$(mktemp -d "${TMPDIR:-/tmp}/kp-test.XXXXXX")" || exit 2
trap 'rm -rf "$W"' EXIT
export CLAUDE_PLUGIN_DATA="$W/data"
unset KERNEL_PLUGIN_HOOKS KP_NO_JQ
KP_PLUGIN_ROOT="$P"; . "$P/lib/common.sh"; . "$P/lib/rules.sh"
KEY="sk_00000000-0000-0000-0000-000000000000.AAAAAAAAAAAAAAAAAAAAAAAA"
SID0="11111111-1111-4111-8111-111111111111"
N=0

ok()   { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf 'FAIL %s :: %s\n' "$1" "$2"; }
skip() { SKIP=$((SKIP + 1)); printf 'SKIP %s :: %s\n' "$1" "$2"; }
info() { printf 'INFO %s\n' "$1"; }
has()  { case "$1" in *"$2"*) return 0 ;; esac; return 1; }
t_empty()    { if [ -z "$2" ]; then ok "$1"; else bad "$1" "expected empty output, got: $(printf '%s' "$2" | cut -c1-200)"; fi; }
t_contains() { if has "$2" "$3"; then ok "$1"; else bad "$1" "missing '$3' in: $(printf '%s' "$2" | cut -c1-200)"; fi; }
t_eq()       { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$3', got '$2'"; fi; }
t_json()     { if [ "$KP_HAVE_JQ" = 1 ]; then if printf '%s' "$2" | jq -e . >/dev/null 2>&1; then ok "$1"; else bad "$1" "invalid JSON"; fi; fi; }

# copy a fixture dir into $W and make it usable; $3 = git to `git init` it (untracked files: exercises git grep --untracked)
stage() { # stage <fixture-dir> <dest> [git]
  rm -rf "$2"; mkdir -p "$2"; cp -R "$1/." "$2/"
  [ -f "$2/dot-env" ] && mv "$2/dot-env" "$2/.env"
  [ "${3:-}" = git ] && git -C "$2" init -q 2>/dev/null
  return 0
}
payload() { # payload <file> <proj> <sid>
  sed -e "s#__PROJ__#$2#g" -e "s#$SID0#$3#g" "$1"
}
run_hook() { # run_hook <hook-file> [args] < stdin
  _h="$1"; shift
  "$KP_SH" "$P/hooks/$_h" "$@" 2>/dev/null
}
newsid() { N="$(cat "$W/.n" 2>/dev/null)"; N=$((${N:-0} + 1)); printf '%s' "$N" > "$W/.n"; printf 'sess-%s' "$N"; }

# ---------------------------------------------------------------- hooks.json
echo "--- hooks.json"
HJ="$P/hooks/hooks.json"
[ -f "$HJ" ] && ok "hooks.json exists" || bad "hooks.json exists" "missing"
if [ "$KP_HAVE_JQ" = 1 ]; then
  jq -e . "$HJ" >/dev/null 2>&1 && ok "hooks.json parses" || bad "hooks.json parses" "invalid"
  t_eq "hooks.json events" "$(jq -r '.hooks | keys | join(",")' "$HJ")" "PostToolUse,PreToolUse,SessionStart,SubagentStart"
  t_eq "hooks.json exec form (command=sh + args)" "$(jq -r '[.hooks[][].hooks[] | select(.command == "sh" and (.args | length) >= 1)] | length' "$HJ")" "4"
  for s in $(jq -r '.hooks[][].hooks[].args[0]' "$HJ" | sed 's#^\${CLAUDE_PLUGIN_ROOT}/##'); do
    [ -f "$P/$s" ] && ok "hooks.json names existing script $s" || bad "hooks.json script $s" "missing"
  done
fi

# ---------------------------------------------------------------- detection
echo "--- detect"
for mode in nogit git; do
  for d in "$F"/detect/pos/*; do
    n="$(basename "$d")"; dest="$W/det/$mode/pos-$n"
    if [ "$mode" = git ]; then stage "$d" "$dest" git; else stage "$d" "$dest"; fi
    out="$("$KP_SH" "$P/bin/kernel-plugin" detect --json "$dest" 2>&1)"
    if has "$out" '"detected":true'; then ok "detect[$mode] positive $n"; else bad "detect[$mode] positive $n" "$out"; fi
  done
  for d in "$F"/detect/neg/*; do
    n="$(basename "$d")"; dest="$W/det/$mode/neg-$n"
    if [ "$mode" = git ]; then stage "$d" "$dest" git; else stage "$d" "$dest"; fi
    out="$("$KP_SH" "$P/bin/kernel-plugin" detect --json "$dest" 2>&1)"
    if has "$out" '"detected":false'; then ok "detect[$mode] negative $n"; else bad "detect[$mode] negative $n" "$out"; fi
  done
done
npos="$(ls "$F/detect/pos" | wc -l | tr -d ' ')"
[ "$npos" -ge 10 ] && ok "at least 10 detect positives ($npos)" || bad "detect positives" "only $npos"
# cache: second call is cached, a touched manifest invalidates it, tier-2 needs two groups
D="$W/det/nogit/pos-package-json"
"$KP_SH" "$P/bin/kernel-plugin" detect --json "$D" >/dev/null 2>&1
t_contains "detect cache hit" "$("$KP_SH" "$P/bin/kernel-plugin" detect --json "$D")" '"cached":true'
sleep 1; touch "$D/package.json"
t_contains "detect cache invalidated by manifest mtime" "$("$KP_SH" "$P/bin/kernel-plugin" detect --json "$D")" '"cached":false'
t_contains "detect negative result is cached too" "$("$KP_SH" "$P/bin/kernel-plugin" detect --json "$W/det/nogit/neg-plain-ts")" '"cached":true'
t_contains "detect tier-2 pair is tier 2" "$("$KP_SH" "$P/bin/kernel-plugin" detect --json "$W/det/nogit/pos-tier2-pair")" '"tier":2'
t_contains "detect text mode" "$("$KP_SH" "$P/bin/kernel-plugin" detect "$D")" 'kernel detected'
t_contains "detect text mode (negative)" "$("$KP_SH" "$P/bin/kernel-plugin" detect "$W/det/nogit/neg-plain-ts")" 'no kernel markers'
# a relative path ('.') in two different non-git directories must not share a cache entry
t_contains "detect '.' in a non-git positive dir" "$(cd "$W/det/nogit/pos-package-json" && "$KP_SH" "$P/bin/kernel-plugin" detect --json .)" '"detected":true'
t_contains "detect '.' in a non-git negative dir is not served the positive's cache" "$(cd "$W/det/nogit/neg-plain-ts" && "$KP_SH" "$P/bin/kernel-plugin" detect --json .)" '"detected":false'

# ---------------------------------------------------------------- rules table + lint
echo "--- rules"
IDS="K001 K002 K003 K004 K005 K006 K008 K009 K010 K012 K015 K016 K018 K019"
got="$(awk -F'\t' '/^#/ || NF < 7 { next } { printf "%s ", $1 }' "$P/rules/stale-api.tsv" | sed 's/ $//')"
t_eq "rule ids are exactly the agreed set" "$got" "$IDS"
for id in $IDS; do
  url="$(awk -F'\t' -v id="$id" '$1 == id { print $7 }' "$P/rules/stale-api.tsv")"
  case "$url" in https://*) ok "$id has a URL" ;; *) bad "$id has a URL" "url='$url'" ;; esac
  msg="$(awk -F'\t' -v id="$id" '$1 == id { print $4 "|" $5 }' "$P/rules/stale-api.tsv")"
  if printf '%s' "$msg" | LC_ALL=C grep -q '[^ -~]'; then bad "$id message is ASCII" "$msg"; else ok "$id message is ASCII"; fi
  if [ -f "$F/rules/$id.pos.ts" ] && [ -f "$F/rules/$id.neg.ts" ]; then
    p="$("$KP_SH" "$P/bin/kernel-plugin" lint "$F/rules/$id.pos.ts" --json)"
    n="$("$KP_SH" "$P/bin/kernel-plugin" lint "$F/rules/$id.neg.ts" --json)"
    has "$p" "\"id\":\"$id\"" && ok "$id positive fixture fires" || bad "$id positive fixture fires" "$p"
    has "$n" "\"id\":\"$id\"" && bad "$id negative fixture is quiet" "$n" || ok "$id negative fixture is quiet"
  else
    bad "$id has positive and negative fixtures" "missing tests/fixtures/rules/$id.{pos,neg}.ts"
  fi
done
t_contains "K002 message says proxy_id is valid on browser pools" "$(awk -F'\t' '$1 == "K002" { print $4 }' "$P/rules/stale-api.tsv")" "valid on browser pools"
# the K019 rule (awk/ERE without intervals) and the H4 regex must agree
for s in "$KEY" "sk_00000000-0000-0000-0000-000000000000.AAAAAAAAAAAAAAAAAAA" "sk_0000000-0000-0000-0000-000000000000.AAAAAAAAAAAAAAAAAAAAAAAA" "sk_ABCDEF00-0000-0000-0000-000000000000.AAAAAAAAAAAAAAAAAAAAAAAA" "x sk_00000000-0000-0000-0000-000000000000.abcdefghij_klmnopqr-stu y"; do
  a=0; b=0
  printf '%s\n' "$s" | grep -E -q "$(awk -F'\t' '$1 == "K019" { print $3 }' "$P/rules/stale-api.tsv")" && a=1
  printf '%s\n' "$s" | grep -E -q "$KP_KEY_RE" && b=1
  [ "$a" = "$b" ] && ok "K019 regex == H4 regex on a sample ($a)" || bad "K019 regex == H4 regex" "tsv=$a h4=$b for sample"
done
# lint over a tree: JSON shape, skips node_modules, 10k files < 5 s
mkdir -p "$W/lint/node_modules/x" "$W/lint/src"
printf "import Kernel from '@onkernel/sdk';\nk({ disable_default_proxy: true })\n" > "$W/lint/src/a.ts"
printf 'disable_default_proxy\n' > "$W/lint/node_modules/x/i.js"
out="$("$KP_SH" "$P/bin/kernel-plugin" lint "$W/lint" --json)"
t_contains "lint --json counts" "$out" '"counts":{"K001":1}'
t_contains "lint skips node_modules" "$out" '"files_scanned":1'
t_json "lint --json is valid JSON" "$out"
t_contains "lint text mode" "$("$KP_SH" "$P/bin/kernel-plugin" lint "$W/lint" 2>/dev/null)" 'src/a.ts:2: K001'
mkdir -p "$W/big"
i=0; while [ $i -lt 100 ]; do mkdir -p "$W/big/d$i"; i=$((i + 1)); done
awk -v w="$W/big" 'BEGIN { for (i = 0; i < 10000; i++) { f = sprintf("%s/d%d/f%d.ts", w, i % 100, i); print "export const v" i " = " i ";" > f; if (i % 500 == 0) print "const o = { max_pooled_sessions: 1 };" > f; close(f) } }'
if command -v perl >/dev/null 2>&1; then
  ms="$(perl -MTime::HiRes=time -e '$t = time; system(@ARGV); printf STDERR "%d", (time - $t) * 1000' "$KP_SH" "$P/bin/kernel-plugin" lint "$W/big" --json 2>&1 >"$W/big.json")"
  info "lint over 10000 files: ${ms} ms"
  [ "$ms" -lt 5000 ] && ok "lint 10k-file tree < 5 s" || bad "lint 10k-file tree < 5 s" "${ms} ms"
  t_contains "lint 10k tree finds the 20 planted hits" "$(cat "$W/big.json")" '"K005":20'
else skip "lint 10k-file timing" "perl missing"; fi

# ---------------------------------------------------------------- H1 / H2
echo "--- H1 / H2"
KPROJ="$W/proj/kernel"; stage "$F/detect/pos/package-json" "$KPROJ" git
for src in startup resume fork clear compact; do
  out="$(payload "$F/payloads/SessionStart.$src.json" "$KPROJ" "$(newsid)" | run_hook context.sh session)"
  t_contains "H1 primer on SessionStart/$src (kernel project)" "$out" '"hookEventName":"SessionStart"'
  t_contains "H1 primer text on $src" "$out" 'detected: @onkernel/sdk'
  t_json "H1 output is JSON ($src)" "$out"
  if [ "$KP_HAVE_JQ" = 1 ]; then
    len="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext | length')"
    [ "$len" -le 1200 ] && ok "H1 primer <= 1200 chars on $src ($len)" || bad "H1 primer length on $src" "$len"
  fi
  for neg in "$F"/detect/neg/*; do
    n="$(basename "$neg")"; stage "$neg" "$W/proj/neg-$n" git
    out="$(payload "$F/payloads/SessionStart.$src.json" "$W/proj/neg-$n" "$(newsid)" | run_hook context.sh session)"
    t_empty "H1 silent on $src in negative $n" "$out"
  done
done
sid="$(newsid)"
payload "$F/payloads/SessionStart.startup.json" "$KPROJ" "$sid" | run_hook context.sh session >/dev/null
out="$(payload "$F/payloads/SubagentStart.json" "$KPROJ" "$sid" | run_hook context.sh subagent)"
t_contains "H2 primer on SubagentStart (after H1)" "$out" '"hookEventName":"SubagentStart"'
out="$(payload "$F/payloads/SubagentStart.json" "$KPROJ" "$(newsid)" | run_hook context.sh subagent)"
t_contains "H2 primer on SubagentStart (no H1 state: detects itself)" "$out" 'kernel plugin'
stage "$F/detect/neg/plain-ts" "$W/proj/plain" git
sid="$(newsid)"
payload "$F/payloads/SessionStart.startup.json" "$W/proj/plain" "$sid" | run_hook context.sh session >/dev/null
t_empty "H2 silent in a non-kernel project" "$(payload "$F/payloads/SubagentStart.json" "$W/proj/plain" "$sid" | run_hook context.sh subagent)"
# prune: an old state entry disappears at SessionStart
mkdir -p "$CLAUDE_PLUGIN_DATA/state/old-entry"; touch -t 202001010000 "$CLAUDE_PLUGIN_DATA/state/old-entry"
payload "$F/payloads/SessionStart.startup.json" "$KPROJ" "$(newsid)" | run_hook context.sh session >/dev/null
[ -d "$CLAUDE_PLUGIN_DATA/state/old-entry" ] && bad "H1 prunes state older than 7 days" "still there" || ok "H1 prunes state older than 7 days"

# ---------------------------------------------------------------- H3
echo "--- H3"
H3P="$W/h3/kernel"; stage "$F/detect/pos/package-json" "$H3P" git
mkdir -p "$H3P/my dir"
FILE="$H3P/my dir/naïve café.ts"
printf "import Kernel from '@onkernel/sdk';\nconst o = { disable_default_proxy: true };\n" > "$FILE"
sid="$(newsid)"
mk_add() { payload "$F/payloads/PostToolUse.Edit.json" "$H3P" "$1" | sed 's#export const a = 2#const o = { disable_default_proxy: true };#g'; }
out="$(mk_add "$sid" | run_hook edit-tripwire.sh)"
t_contains "H3 adding disable_default_proxy -> finding K001" "$out" ' K001 '
t_eq "H3 exactly 1 finding" "$(printf '%s' "$out" | grep -o ' K0[0-9][0-9] ' | wc -l | tr -d ' ')" "1"
t_contains "H3 uses hookEventName PostToolUse + file in message" "$out" '"hookEventName":"PostToolUse","additionalContext":"kernel: my dir/naïve café.ts: K001'
t_json "H3 output is JSON" "$out"
[ "${#out}" -le 900 ] && ok "H3 output is short (${#out} chars)" || bad "H3 output length" "${#out}"
t_empty "H3 same file again -> silent" "$(mk_add "$sid" | run_hook edit-tripwire.sh)"
# legacy file that already contains proxy_id, editing another line (tool_response.originalFile carries proxy_id too)
LEG="$W/h3/legacy"; stage "$F/detect/pos/package-json" "$LEG" git; mkdir -p "$LEG/my dir"
printf "import Kernel from '@onkernel/sdk';\nconst p = { proxy_id: 'x' };\nexport const a = 2\n" > "$LEG/my dir/naïve café.ts"
out="$(payload "$F/payloads/PostToolUse.Edit.json" "$LEG" "$(newsid)" | sed 's#"originalFile":"export const a = 1#"originalFile":"const p = { proxy_id: 1 };\\nexport const a = 1#' | run_hook edit-tripwire.sh)"
t_empty "H3 editing another line of a legacy proxy_id file -> silent" "$out"
# non-Kernel project
PL="$W/h3/plain"; stage "$F/detect/neg/plain-ts" "$PL" git; mkdir -p "$PL/my dir"
printf "const o = { disable_default_proxy: true };\n" > "$PL/my dir/naïve café.ts"
t_empty "H3 non-Kernel project -> silent" "$(mk_add x | sed "s#$H3P#$PL#g" | run_hook edit-tripwire.sh)"
# kernel project but the file has no Kernel marker
mkdir -p "$H3P/other"; printf "const o = { disable_default_proxy: true };\n" > "$H3P/other/nomarker.ts"
t_empty "H3 file without a kernel marker -> silent" "$(mk_add "$(newsid)" | sed "s#$H3P/my dir/naïve café.ts#$H3P/other/nomarker.ts#g" | run_hook edit-tripwire.sh)"
# > 512 KB
awk 'BEGIN { print "import Kernel from \"@onkernel/sdk\";"; print "const o = { disable_default_proxy: true };"; for (i = 0; i < 20000; i++) print "const pad" i " = \"padding padding padding\";" }' > "$H3P/my dir/big.ts"
sz="$(wc -c < "$H3P/my dir/big.ts" | tr -d ' ')"; info "big fixture is $sz bytes"
t_empty "H3 file > 512 KB -> skipped" "$(mk_add "$(newsid)" | sed "s#naïve café.ts#big.ts#g" | run_hook edit-tripwire.sh)"
# Write replay of the captured payload: nothing stale in it
printf "import Kernel from '@onkernel/sdk';\nexport const a = 1\n" > "$FILE"
t_empty "H3 replay of captured Write payload -> silent" "$(payload "$F/payloads/PostToolUse.Write.json" "$H3P" "$(newsid)" | run_hook edit-tripwire.sh)"
# NotebookEdit shape (notebook_path / new_source)
printf '{"cells":[{"id":"c1","cell_type":"code","source":["import onkernel  # @onkernel/sdk\\n","disable_default_proxy = True"]}]}\n' > "$H3P/nb.ipynb"
out="$(payload "$F/payloads/PostToolUse.NotebookEdit.json" "$H3P" "$(newsid)" | sed 's#"new_source":"print(2)"#"new_source":"disable_default_proxy = True"#' | run_hook edit-tripwire.sh)"
t_contains "H3 NotebookEdit payload -> finding" "$out" ' K001 '
# every rule through a Write payload (positive fires, negative silent)
RP="$W/h3/rules"; stage "$F/detect/pos/package-json" "$RP" git
for id in $IDS; do
  for kind in pos neg; do
    cp "$F/rules/$id.$kind.ts" "$RP/r-$id-$kind.ts"
    content="$(cat "$F/rules/$id.$kind.ts")"
    body="$(printf '%s' "$content" | json_escape)"
    pl="{\"session_id\":\"$(newsid)\",\"cwd\":\"$RP\",\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$RP/r-$id-$kind.ts\",\"content\":\"$body\"},\"tool_response\":{\"type\":\"create\"}}"
    out="$(printf '%s' "$pl" | run_hook edit-tripwire.sh)"
    if [ "$kind" = pos ]; then t_contains "H3 rule $id fires via Write" "$out" " $id "; else t_empty "H3 rule $id quiet on negative" "$out"; fi
  done
done
# K019 in a gitignored .env is the supported place: no finding
EP="$W/h3/envp"; stage "$F/detect/pos/package-json" "$EP" git; printf '.env*\n' > "$EP/.gitignore"; printf 'KERNEL_API_KEY=%s\n' "$KEY" > "$EP/.env"
pl="{\"session_id\":\"$(newsid)\",\"cwd\":\"$EP\",\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$EP/.env\",\"content\":\"KERNEL_API_KEY=$KEY\\n\"},\"tool_response\":{}}"
t_empty "H3 gitignored .env with a key -> silent" "$(printf '%s' "$pl" | run_hook edit-tripwire.sh)"
# 3-finding cap and 600-char cap
CP="$W/h3/cap"; stage "$F/detect/pos/package-json" "$CP" git
printf "import Kernel from '@onkernel/sdk';\nconst a = { disable_default_proxy: 1, proxy_id: 2, max_pooled_sessions: 3, captcha_type: 4, browser_telemetry: 5 };\n" > "$CP/c.ts"
pl="{\"session_id\":\"$(newsid)\",\"cwd\":\"$CP\",\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$CP/c.ts\",\"content\":\"$(cat "$CP/c.ts" | json_escape)\"},\"tool_response\":{}}"
out="$(printf '%s' "$pl" | run_hook edit-tripwire.sh)"
t_eq "H3 at most 3 findings" "$(printf '%s' "$out" | grep -o ' K0[0-9][0-9] ' | wc -l | tr -d ' ')" "3"
if [ "$KP_HAVE_JQ" = 1 ]; then
  l="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext | length')"; [ "$l" -le 600 ] && ok "H3 additionalContext <= 600 chars ($l)" || bad "H3 600-char cap" "$l"
fi

# ---------------------------------------------------------------- H4
echo "--- H4"
G1="$W/h4/ignored"; stage "$F/detect/neg/plain-ts" "$G1" git; printf '.env*\n' > "$G1/.gitignore"; mkdir -p "$G1/src"
G2="$W/h4/tracked"; stage "$F/detect/neg/plain-ts" "$G2" git; mkdir -p "$G2/src"
G3="$W/h4/nogit"; stage "$F/detect/neg/plain-ts" "$G3"; mkdir -p "$G3/src"
wr() { # wr <proj> <relpath> -> Write PreToolUse payload with the placeholder key
  payload "$F/payloads/PreToolUse.Write.json" "$1" "$(newsid)" | sed -e "s#$1/my dir/naïve café.ts#$1/$2#" -e "s#export const a = 1\\\\n#const k = \\\\\"$KEY\\\\\"\\\\n#"
}
out="$(wr "$G1" src/config.ts | run_hook secret-guard.sh)"
t_contains "H4 Write src/config.ts with a key -> deny" "$out" '"permissionDecision":"deny"'
t_contains "H4 deny reason text" "$out" 'Kernel API key literal in src/config.ts. Read it from KERNEL_API_KEY (env or a gitignored .env); never commit or echo keys.'
t_contains "H4 deny names PreToolUse" "$out" '"hookEventName":"PreToolUse"'
t_json "H4 deny is JSON" "$out"
has "$out" "$KEY" && bad "H4 deny never echoes the key" "key present in output" || ok "H4 deny never echoes the key"
t_empty "H4 Write gitignored .env -> allow (silent)" "$(wr "$G1" .env | run_hook secret-guard.sh)"
t_empty "H4 Write gitignored .env.local -> allow (silent)" "$(wr "$G1" .env.local | run_hook secret-guard.sh)"
t_contains "H4 Write .env that is NOT gitignored -> deny" "$(wr "$G2" .env | run_hook secret-guard.sh)" '"permissionDecision":"deny"'
t_contains "H4 Write .env.example (not ignored) -> deny" "$(wr "$G2" .env.example | run_hook secret-guard.sh)" '"permissionDecision":"deny"'
t_empty "H4 Write .env outside any git repo -> allow (silent)" "$(wr "$G3" .env | run_hook secret-guard.sh)"
t_contains "H4 Write envfile.ts (not a .env name) outside git -> deny" "$(wr "$G3" src/env.ts | run_hook secret-guard.sh)" '"permissionDecision":"deny"'
t_empty "H4 Write new .env in a not-yet-existing gitignored dir -> allow" "$(wr "$G1" newdir/.env | run_hook secret-guard.sh)"
bash_pl() { payload "$F/payloads/PreToolUse.Bash.json" "$G1" "$(newsid)" | sed "s#\"command\":\"echo hi\"#\"command\":\"$1\"#"; }
t_contains "H4 Bash echo <key> -> deny" "$(bash_pl "echo $KEY" | run_hook secret-guard.sh)" '"permissionDecision":"deny"'
t_contains "H4 Bash writing the key into .env is still denied" "$(bash_pl "echo KERNEL_API_KEY=$KEY > .env" | run_hook secret-guard.sh)" '"permissionDecision":"deny"'
t_empty "H4 Bash without a key -> silent" "$(payload "$F/payloads/PreToolUse.Bash.json" "$G1" "$(newsid)" | run_hook secret-guard.sh)"
t_empty "H4 Bash mentioning KERNEL_API_KEY without a literal -> silent" "$(bash_pl 'echo $KERNEL_API_KEY | wc -c' | run_hook secret-guard.sh)"
t_empty "H4 Edit that REMOVES a key (key only in old_string) -> silent" "$(payload "$F/payloads/PreToolUse.Edit.json" "$G1" "$(newsid)" | sed "s#\"old_string\":\"export const a = 1\"#\"old_string\":\"const k = \\\\\"$KEY\\\\\"\"#" | run_hook secret-guard.sh)"
t_empty "H4 captured Write payload (no key) -> silent" "$(payload "$F/payloads/PreToolUse.Write.json" "$G1" "$(newsid)" | run_hook secret-guard.sh)"
t_empty "H4 captured NotebookEdit payload (no key) -> silent" "$(payload "$F/payloads/PreToolUse.NotebookEdit.json" "$G1" "$(newsid)" | run_hook secret-guard.sh)"
nb="$(payload "$F/payloads/PreToolUse.NotebookEdit.json" "$G1" "$(newsid)" | sed "s#\"new_source\":\"print(2)\"#\"new_source\":\"k = '$KEY'\"#" | run_hook secret-guard.sh)"
t_contains "H4 NotebookEdit with a key -> deny" "$nb" '"permissionDecision":"deny"'
rm -f "$FILE"; printf "import Kernel from '@onkernel/sdk';\nconst o = { disable_default_proxy: true };\n" > "$FILE"
t_contains "H4 deny with jq absent (sed fallback)" "$(wr "$G1" src/config.ts | KP_NO_JQ=1 "$KP_SH" "$P/hooks/secret-guard.sh" 2>/dev/null)" '"permissionDecision":"deny"'
t_empty "H4 .env allowed with jq absent (sed fallback)" "$(wr "$G1" .env | KP_NO_JQ=1 "$KP_SH" "$P/hooks/secret-guard.sh" 2>/dev/null)"
t_contains "H3 finding with jq absent (sed fallback)" "$(mk_add "$(newsid)" | KP_NO_JQ=1 "$KP_SH" "$P/hooks/edit-tripwire.sh" 2>/dev/null)" ' K001 '

# ---------------------------------------------------------------- opt-out and garbage
echo "--- opt-out / garbage"
for h in "context.sh session" "context.sh subagent" edit-tripwire.sh secret-guard.sh; do
  set -- $h
  out="$(payload "$F/payloads/SessionStart.startup.json" "$KPROJ" "$(newsid)" | KERNEL_PLUGIN_HOOKS=off "$KP_SH" "$P/hooks/$1" $2 2>/dev/null)"
  t_empty "KERNEL_PLUGIN_HOOKS=off silences $h" "$out"
done
out="$(wr "$G1" src/config.ts | KERNEL_PLUGIN_HOOKS=off "$KP_SH" "$P/hooks/secret-guard.sh" 2>/dev/null)"; t_empty "KERNEL_PLUGIN_HOOKS=off silences a would-be H4 deny" "$out"
out="$(mk_add "$(newsid)" | KERNEL_PLUGIN_HOOKS=off "$KP_SH" "$P/hooks/edit-tripwire.sh" 2>/dev/null)"; t_empty "KERNEL_PLUGIN_HOOKS=off silences a would-be H3 finding" "$out"
for nojq in "" 1; do
  for h in "context.sh session" "context.sh subagent" edit-tripwire.sh secret-guard.sh; do
    set -- $h
    for g in "{{{ not json" "" "$(printf 'sk_%s {{' "$KEY")" '[1,2,3]' '"just a string"' '{"tool_name":"Write","tool_input":"str"}'; do
      out="$(printf '%s' "$g" | KP_NO_JQ=$nojq "$KP_SH" "$P/hooks/$1" $2 2>/dev/null)"; rc=$?
      if [ $rc -eq 0 ] && [ -z "$out" ]; then ok "garbage stdin -> exit 0, empty ($h${nojq:+, no jq}): $(printf '%s' "$g" | cut -c1-12)"; else bad "garbage stdin ($h)" "rc=$rc out=$out"; fi
    done
    out="$(head -c 300 /dev/urandom 2>/dev/null | KP_NO_JQ=$nojq "$KP_SH" "$P/hooks/$1" $2 2>/dev/null)"; rc=$?
    if [ $rc -eq 0 ] && [ -z "$out" ]; then ok "random bytes -> exit 0, empty ($h${nojq:+, no jq})"; else bad "random bytes ($h)" "rc=$rc"; fi
  done
done
# unwritable state dir must not break a hook
out="$(payload "$F/payloads/SessionStart.startup.json" "$KPROJ" "$(newsid)" | CLAUDE_PLUGIN_DATA=/proc/nonexistent/x "$KP_SH" "$P/hooks/context.sh" session 2>/dev/null)"; rc=$?
[ $rc -eq 0 ] && ok "unwritable CLAUDE_PLUGIN_DATA -> exit 0" || bad "unwritable state" "rc=$rc"

# ---------------------------------------------------------------- timing
echo "--- timing"
# Timings are noisy when the machine is busy: a gate passes if ANY of up to 3 attempts meets it, and every attempt is printed.
PERL_P95='($sh, $hook, $pl, $st) = @ARGV; for (1..200) { unlink $st if $st; open(STDIN, "<", $pl); open(STDOUT, ">", "/dev/null"); $t = time; system($sh, $hook); push @d, (time - $t) * 1000 } @d = sort { $a <=> $b } @d; printf STDERR "%.1f %.1f %.1f", $d[100], $d[189], $d[199]'
bench_hook() { # bench_hook <label> <script> <payload> [statefile-to-unlink] [gate]  -> PASS if p95 < 50 ms in any of 3 attempts
  _bt=1; _bok=0
  while [ "$_bt" -le 3 ]; do
    set -- "$1" "$2" "$3" "${4:-}" "${5:-gate}" $(perl -MTime::HiRes=time -e "$PERL_P95" "$KP_SH" "$2" "$3" "${4:-}" 2>&1 >/dev/null)
    info "$1, attempt $_bt, 200 runs: median $6 ms, p95 $7 ms, max $8 ms"
    awk -v p="$7" 'BEGIN { exit !(p < 50) }' && { _bok=1; break; }
    _bt=$((_bt + 1))
  done
  if [ "$5" = gate ]; then [ "$_bok" = 1 ] && ok "$1: p95 < 50 ms ($7 ms)" || bad "$1: p95 < 50 ms" "$7 ms after 3 attempts"; fi
}
if command -v perl >/dev/null 2>&1; then
  sid="$(newsid)"
  mk_add "$sid" > "$W/h3.json"
  payload "$F/payloads/SessionStart.startup.json" "$H3P" "$sid" | run_hook context.sh session >/dev/null
  bench_hook "H3 steady state" "$P/hooks/edit-tripwire.sh" "$W/h3.json"
  bench_hook "H3 without session state (cache path; once per session)" "$P/hooks/edit-tripwire.sh" "$W/h3.json" "$CLAUDE_PLUGIN_DATA/state/$sid/detected" info
  payload "$F/payloads/PreToolUse.Bash.json" "$G1" "$SID0" > "$W/h4b.json"
  bench_hook "H4 on a clean Bash call" "$P/hooks/secret-guard.sh" "$W/h4b.json"
  K8="${KP_K8S:-/tmp/kp-k8s}"
  if [ -f "$K8/go.mod" ]; then
    rm -rf "$CLAUDE_PLUGIN_DATA/state"/detect-*
    ms="$(perl -MTime::HiRes=time -e '$t = time; system(@ARGV); printf STDERR "%d", (time - $t) * 1000' "$KP_SH" "$P/bin/kernel-plugin" detect --json "$K8" 2>&1 >"$W/k8s.json")"
    info "detect on kubernetes, cold: ${ms} ms ($(find "$K8" -type f -not -path '*/.git/*' 2>/dev/null | wc -l | tr -d ' ') files)"
    [ "$ms" -lt 10000 ] && ok "detect on kubernetes cold < 10 s (${ms} ms)" || bad "detect on kubernetes cold < 10 s" "${ms} ms"
    t_contains "detect on kubernetes is negative" "$(cat "$W/k8s.json")" '"detected":false'
    _wt=1; _wok=0
    while [ "$_wt" -le 3 ]; do
      ms="$(perl -MTime::HiRes=time -e '$t = time; system(@ARGV); printf STDERR "%d", (time - $t) * 1000' "$KP_SH" "$P/bin/kernel-plugin" detect --json "$K8" 2>&1 >"$W/k8s.json")"
      info "detect on kubernetes, warm, attempt $_wt: ${ms} ms"
      [ "$ms" -lt 50 ] && { _wok=1; break; }
      _wt=$((_wt + 1))
    done
    [ "$_wok" = 1 ] && ok "detect on kubernetes warm cache < 50 ms (${ms} ms)" || bad "detect on kubernetes warm < 50 ms" "${ms} ms after 3 attempts"
    t_contains "kubernetes warm answer is cached" "$(cat "$W/k8s.json")" '"cached":true'
  else
    skip "kubernetes benchmark" "no clone at $K8 (git clone --depth 1 https://github.com/kubernetes/kubernetes $K8)"
  fi
else
  skip "timing" "perl missing"
fi

echo "=== $PASS passed, $FAIL failed, $SKIP skipped (hook interpreter: $KP_SH)"
[ "$FAIL" -eq 0 ]
