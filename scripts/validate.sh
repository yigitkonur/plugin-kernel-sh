#!/usr/bin/env bash
# validate.sh -- structural checks for the plugin repo. Exit 1 on any failure.
#  1 claude plugin validate --strict (marketplace, plugin, skills) when `claude` is installed
#  2 every .json parses
#  3 SKILL.md frontmatter is valid YAML (python3+pyyaml if present, else a plain-scalar heuristic)
#  4 every references/ or scripts/ path named in a SKILL.md, and every ${CLAUDE_PLUGIN_ROOT}/ path named in
#    hooks.json, SKILL.md or README, exists  (a line containing "novalidate" is skipped)
#  5 size limits: SKILL.md <= 300 lines, references <= 350 lines, description <= 600 chars
#  6 each plugin's plugin.json version == its marketplace entry version (plugin.json is the source of truth)
#  7 THIRD_PARTY_NOTICES.md ships inside every plugin and matches the root copy; 8 no $N / $ARGUMENTS in SKILL.md bodies
#  9 the ledger counts quoted in README.md match verified-facts.md; 10 shared hook libs are in sync
# 11 Codex: every hook script named in hooks/codex-hooks.json exists, and no skill text names ${CLAUDE_PLUGIN_ROOT}
#    (Codex does not resolve it; manifests, versions and the marketplace are checked by scripts/kit/check-manifests.py)
set -u; shopt -s nullglob
cd "$(git rev-parse --show-toplevel)" || exit 2
fail=0
bad() { echo "validate: $*" >&2; fail=1; }
PLUGINS="$(jq -r '.plugins[].source' .claude-plugin/marketplace.json | sed 's#^\./##')"
[ -n "$PLUGINS" ] || bad "marketplace.json lists no plugins"

# 1
if command -v claude >/dev/null 2>&1; then
  for t in . $(for P in $PLUGINS; do printf '%s %s ' "$P" "$P/skills"; done); do claude plugin validate "$t" --strict >/dev/null 2>&1 || { bad "claude plugin validate --strict failed on $t"; claude plugin validate "$t" --strict 2>&1 | sed 's/^/  /' >&2; }; done
else echo "validate: claude not installed, skipping claude plugin validate" >&2; fi

# 2
while IFS= read -r f; do jq -e . "$f" >/dev/null 2>&1 || bad "invalid JSON: $f"; done < <(git ls-files -co --exclude-standard '*.json')

for P in $PLUGINS; do
# 3
for f in "$P"/skills/*/SKILL.md; do
  fm="$(awk 'NR==1&&$0!="---"{exit} NR>1&&$0=="---"{exit} NR>1{print}' "$f")"
  [ -z "$fm" ] && { bad "no frontmatter: $f"; continue; }
  if python3 -c 'import yaml' 2>/dev/null; then
    printf '%s\n' "$fm" | python3 -I -c 'import sys,yaml; d=yaml.safe_load(sys.stdin); assert isinstance(d,dict) and isinstance(d.get("name"),str) and isinstance(d.get("description"),str)' 2>/dev/null || bad "frontmatter is not valid YAML with string name+description: $f"
  else
    printf '%s\n' "$fm" | grep -E '^(description|argument-hint):[[:space:]]+[^>"|[:space:]].*: ' >/dev/null && bad "plain scalar containing ': ' in $f (use >- or quotes)"
    printf '%s\n' "$fm" | grep -E '^argument-hint:[[:space:]]+\[' >/dev/null && bad "unquoted [..] argument-hint in $f"
  fi
  name="$(printf '%s\n' "$fm" | sed -n 's/^name:[[:space:]]*//p' | head -1)"; [ "$name" = "$(basename "$(dirname "$f")")" ] || bad "name '$name' != directory: $f"
  dlen="$(printf '%s\n' "$fm" | awk '/^description:/{d=1; sub(/^description:[[:space:]]*(>-|>|\|)?[[:space:]]*/,""); s=$0; next} d&&/^[[:space:]]/{s=s " " $0; next} d{d=0} END{print length(s)}')"
  [ "${dlen:-0}" -le 600 ] || bad "description is $dlen chars (>600): $f"
  [ "$(wc -l < "$f")" -le 300 ] || bad "SKILL.md over 300 lines: $f"
done
for f in "$P"/skills/*/references/*.md; do [ -f "$f" ] && [ "$(wc -l < "$f")" -gt 350 ] && bad "reference over 350 lines: $f"; done

# 4
check_paths() { # file base-dir-for-relative-refs
  local f="$1" base="$2" p
  while IFS= read -r p; do
    [ -e "$base/$p" ] || bad "$f names missing path: $p"
  done < <(grep -v 'novalidate' "$f" | grep -oE '(^|[^A-Za-z0-9_./-])(references|scripts)/[A-Za-z0-9._/-]*[A-Za-z0-9_]\.(md|sh|ts|tsv|json|mjs)' | sed -E 's/^[^rs]*//' | sort -u)
}
for f in "$P"/skills/*/SKILL.md; do check_paths "$f" "$(dirname "$f")"; done
# cross-skill pointers: ../kernel/references/x.md (from a SKILL.md) and ../../kernel/references/x.md (from audit/references)
for f in "$P"/skills/*/SKILL.md "$P"/skills/*/references/*.md; do
  d="$(dirname "$f")"
  while IFS= read -r p; do
    [ -e "$d/$p" ] || bad "$f names missing path: $p"
  done < <(grep -v 'novalidate' "$f" | grep -oE '(\.\./)+[a-z-]+/references/[A-Za-z0-9._-]+\.md' | sort -u)
done
for f in "$P"/skills/*/references/*.md; do check_paths "$f" "$(dirname "$(dirname "$f")")"; done
for f in "$P/hooks/hooks.json" "$P"/skills/*/SKILL.md "$P"/skills/*/references/*.md README.md "$P/README.md"; do
  [ -f "$f" ] || continue
  while IFS= read -r p; do
    [ -e "$P/$p" ] || bad "$f names missing plugin path: \${CLAUDE_PLUGIN_ROOT}/$p"
  done < <(grep -v 'novalidate' "$f" | grep -oE '\$\{CLAUDE_PLUGIN_ROOT\}/[A-Za-z0-9._/-]*[A-Za-z0-9_]' | sed 's#^\${CLAUDE_PLUGIN_ROOT}/##' | sort -u)
done

# 11 Codex
if [ -f "$P/hooks/codex-hooks.json" ]; then
  while IFS= read -r p; do
    [ -e "$P/$p" ] || bad "$P/hooks/codex-hooks.json names missing script: $p"
  done < <(grep -oE 'PLUGIN_ROOT\}/[A-Za-z0-9._/-]*[A-Za-z0-9_]' "$P/hooks/codex-hooks.json" | sed 's#^PLUGIN_ROOT}/##' | sort -u)
  jq -e '[.hooks[][].hooks[] | select(.type != "command")] | length == 0' "$P/hooks/codex-hooks.json" >/dev/null 2>&1 || bad "$P/hooks/codex-hooks.json has a hook that is not a command hook (Codex skips prompt and agent hooks)"
  if grep -rn 'CLAUDE_PLUGIN_ROOT' "$P"/skills >/dev/null 2>&1; then bad "a skill names CLAUDE_PLUGIN_ROOT, which Codex does not set for skills: $(grep -rn 'CLAUDE_PLUGIN_ROOT' "$P"/skills | head -2 | cut -c1-120)"; fi
fi

# 6
V="$(jq -r .version "$P/.claude-plugin/plugin.json")"
[ "$(jq -r --arg s "./$P" '.plugins[] | select(.source == $s) | .version' .claude-plugin/marketplace.json)" = "$V" ] || bad "marketplace entry version for $P != plugin.json ($V)"
[ "$(jq -r --arg s "./$P" '.plugins[] | select(.source == $s) | .name' .claude-plugin/marketplace.json)" = "$(jq -r .name "$P/.claude-plugin/plugin.json")" ] || bad "marketplace entry name for $P != plugin.json name"

# 7 the license notice ships inside the plugin and the repo-root copy matches it
[ -f "$P/THIRD_PARTY_NOTICES.md" ] || bad "missing $P/THIRD_PARTY_NOTICES.md (the installed plugin must carry the upstream MIT notice)"
cmp -s THIRD_PARTY_NOTICES.md "$P/THIRD_PARTY_NOTICES.md" || bad "THIRD_PARTY_NOTICES.md differs between the repo root and $P"

# 8 Claude Code substitutes $0, $1, ... and $ARGUMENTS in a skill body before the model sees it (a shell "$1" or a price like $0.48 gets rewritten)
if grep -n -E '\$([0-9]|ARGUMENTS)' "$P"/skills/*/SKILL.md >/dev/null 2>&1; then
  bad "a SKILL.md contains \$N or \$ARGUMENTS, which Claude Code rewrites: $(grep -n -E '\$([0-9]|ARGUMENTS)' "$P"/skills/*/SKILL.md | head -3 | cut -c1-120)"
fi
done

# 10 hook libraries shared between plugins stay identical to shared/lib (scripts/sync-shared.sh copies them)
for f in shared/lib/*; do for P in $PLUGINS; do [ -f "$P/lib/${f##*/}" ] || continue; cmp -s "$f" "$P/lib/${f##*/}" || bad "$P/lib/${f##*/} differs from $f (run scripts/sync-shared.sh)"; done; done

# 10b the Kernel key regex is the same literal in every plugin's hook libs
krs="$(grep -h -o "^KP_KEY_RE='[^']*'" plugins/*/lib/*.sh | sort -u)"
[ "$(printf '%s\n' "$krs" | grep -c .)" -le 1 ] || bad "KP_KEY_RE differs between plugins: $krs"

# 9 the ledger counts quoted in the README match verified-facts.md (probe rows P*, R*, MC*)
counts="$(awk -F'|' 'NF >= 5 && $2 ~ /^ *(P[0-9]|R[0-9]|MC[0-9])/ { v = $4; gsub(/ /, "", v); c[v]++ } END { printf "%d confirmed, %d refuted, %d gated and %d untested", c["confirmed"], c["refuted"], c["gated"], c["untested"] }' verified-facts.md)"
grep -q -F "<!--ledger-counts-->$counts<!--/ledger-counts-->" README.md || bad "README ledger counts differ from verified-facts.md (expected: $counts)"

[ $fail = 0 ] && echo "validate: OK"
exit $fail
