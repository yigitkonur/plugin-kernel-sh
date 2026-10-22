# rules.sh -- stale-identifier rules (rules/stale-api.tsv). POSIX sh, sourced; needs lib/common.sh and KP_PLUGIN_ROOT.
KP_RULES="${KP_RULES:-$KP_PLUGIN_ROOT/rules/stale-api.tsv}"
KP_KEY_RE='sk_[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\.[A-Za-z0-9_-]{20,}'

# kp_rules_check <target> [skipk019]: stdin = new text, a separator line, the text it replaced; findings for H3
# (see lib/rules-check.awk)
kp_rules_check() {
  KP_TG="$1" awk -f "$KP_PLUGIN_ROOT/lib/rules-check.awk" -v rl="$KP_RULES" -v mk="$KP_MARKERS" -v skipk019="${2:-0}"   # the path goes through ENVIRON: awk -v would process backslash escapes in it
}

# kp_rules_union: alternation of every rule regex (prefilter for lint)
kp_rules_union() {
  awk -F'\t' '/^#/ || NF < 7 { next } { printf "%s(%s)", sep, $3; sep = "|" }' "$KP_RULES"
}
