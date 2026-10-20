#!/bin/sh
# context.sh <session|subagent> -- H1 (SessionStart) and H2 (SubagentStart): inject the Kernel primer, only when the
# project is detected as a Kernel project. Fail-open: any problem => exit 0, empty stdout.
case "$0" in */*) KP_PLUGIN_ROOT="${0%/*}/.." ;; *) KP_PLUGIN_ROOT="./.." ;; esac
{ . "$KP_PLUGIN_ROOT/lib/common.sh" && . "$KP_PLUGIN_ROOT/lib/detect.sh"; } 2>/dev/null || exit 0
kp_off && exit 0

main() {
  kind="${1:-session}"
  kp_read_stdin
  [ -n "$KP_JSON" ] || return 0
  sid="$(json_get session_id)"; cwd="$(json_get cwd)"
  [ -n "$cwd" ] && [ -d "$cwd" ] || return 0
  sd="$(kp_state_dir "$sid")"
  if [ "$kind" = session ]; then
    kp_prune
    kp_detect "$cwd"
    printf '%s\n%s\n' "$KP_DET" "$KP_DET_SUMMARY" > "$sd/detected" 2>/dev/null
  else
    if [ -f "$sd/detected" ]; then
      { IFS= read -r KP_DET; IFS= read -r KP_DET_SUMMARY; } < "$sd/detected"
    else
      kp_detect "$cwd"
      printf '%s\n%s\n' "$KP_DET" "$KP_DET_SUMMARY" > "$sd/detected" 2>/dev/null
    fi
  fi
  [ "$KP_DET" = 1 ] || return 0
  summary="$(printf '%s' "$KP_DET_SUMMARY" | awk '{ print substr($0, 1, 70) }')"
  primer="$(KP_D="$summary" awk 'BEGIN { d = ENVIRON["KP_D"] } { i = index($0, "{detected}"); if (i) $0 = substr($0, 1, i - 1) d substr($0, i + 10); print }' "$KP_PLUGIN_ROOT/rules/primer.txt")"
  [ -n "$primer" ] || return 0
  if [ "$kind" = session ]; then ev=SessionStart; else ev=SubagentStart; fi
  kp_emit "$ev" "$primer"
}

out="$(main "$@" 2>/dev/null)" || out=""
[ -n "$out" ] && printf '%s\n' "$out"
exit 0
