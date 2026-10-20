#!/usr/bin/env bash
# check-freshness.sh [--issue] -- compare what this plugin was verified against with what is current.
#  1 latest @onkernel/sdk and @onkernel/cli vs references/verified-against.md
#  2 @deprecated tags in the latest SDK types that were not in the verified SDK (candidate K0xx rules)
#  3 changelog entries newer than the verified date
# With --issue, opens a GitHub issue (needs gh auth) when anything changed and no open "freshness" issue exists.
set -u
cd "$(git rev-parse --show-toplevel)"
VA=plugins/kernel/skills/kernel/references/verified-against.md
vsdk="$(sed -n 's/^| `@onkernel\/sdk` | \([0-9.]*\).*/\1/p' "$VA" | head -1)"
vcli="$(sed -n 's/^| `kernel` CLI | \([0-9.]*\).*/\1/p' "$VA" | head -1)"
lsdk="$(npm view @onkernel/sdk version 2>/dev/null)"; lcli="$(npm view @onkernel/cli version 2>/dev/null)"
report="$(mktemp)"; changed=0
{
echo "# Kernel plugin freshness report"
echo "- verified against SDK ${vsdk:-?}, CLI ${vcli:-?}; latest on npm: SDK ${lsdk:-?}, CLI ${lcli:-?}"
} > "$report"
[ -n "${lsdk:-}" ] && [ "$lsdk" != "$vsdk" ] && changed=1
[ -n "${lcli:-}" ] && [ "$lcli" != "$vcli" ] && changed=1
if [ -n "${vsdk:-}" ] && [ -n "${lsdk:-}" ] && [ "$lsdk" != "$vsdk" ]; then
  w="$(mktemp -d)"
  ( cd "$w" && mkdir a b && (cd a && npm pack "@onkernel/sdk@$vsdk" --silent >/dev/null 2>&1 && tar xzf *.tgz) && (cd b && npm pack "@onkernel/sdk@$lsdk" --silent >/dev/null 2>&1 && tar xzf *.tgz) ) || true
  grab() { grep -rh -A2 '@deprecated' "$1/package" --include='*.d.ts' 2>/dev/null | tr -s ' ' | sort -u; }
  { echo; echo "## New @deprecated tags between $vsdk and $lsdk (candidate stale-API rules)"; diff <(grab "$w/a") <(grab "$w/b") | grep '^>' | head -40; } >> "$report"
  rm -rf "$w"
fi
{ echo; echo "## Docs changelog (top of page)"; curl -s -m 30 https://www.kernel.sh/docs/changelog.md 2>/dev/null | head -15; } >> "$report"
cat "$report"
if [ "${1:-}" = "--issue" ] && [ $changed = 1 ]; then
  if gh issue list --label freshness --state open --json number --jq 'length' 2>/dev/null | grep -qx 0; then
    gh issue create --title "Kernel moved: re-verify the plugin (SDK $lsdk, CLI $lcli)" --label freshness --body-file "$report" || true
  fi
fi
rm -f "$report"; exit 0
