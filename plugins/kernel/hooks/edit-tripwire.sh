#!/bin/sh
# edit-tripwire.sh -- H3 (PostToolUse on Edit|Write|MultiEdit|NotebookEdit): flag deprecated Kernel identifiers the
# agent just wrote. A rule fires only if it matches the NEW text of the tool input AND the file on disk; once per
# (session, file, rule); at most 3 findings; <= 600 chars; only in detected Kernel projects whose file carries a marker;
# files over 512 KB are skipped. Fail-open: any problem => exit 0, empty stdout.
case "$0" in */*) KP_PLUGIN_ROOT="${0%/*}/.." ;; *) KP_PLUGIN_ROOT="./.." ;; esac
{ . "$KP_PLUGIN_ROOT/lib/common.sh" && . "$KP_PLUGIN_ROOT/lib/detect.sh" && . "$KP_PLUGIN_ROOT/lib/rules.sh"; } 2>/dev/null || exit 0
kp_off && exit 0

# stdin = kp_tool_stream: 4 metadata lines, then the new text (consumed by the rules awk)
h3_body() {
  IFS= read -r sid; IFS= read -r cwd; IFS= read -r tool; IFS= read -r fp
  case "$tool" in Edit|Write|MultiEdit|NotebookEdit) ;; *) return 0 ;; esac
  [ -n "$fp" ] || return 0
  case "$fp" in /*) f="$fp" ;; *) f="$cwd/$fp" ;; esac
  [ -f "$f" ] || return 0
  sz="$(wc -c < "$f")"; [ "$((sz + 0))" -le 524288 ] || return 0

  sd="$(kp_state_dir "$sid")"
  if [ -f "$sd/detected" ]; then
    { IFS= read -r det; } < "$sd/detected"
  else
    [ -d "$cwd" ] || return 0
    kp_detect "$cwd" </dev/null; det="$KP_DET"
    printf '%s\n%s\n' "$KP_DET" "$KP_DET_SUMMARY" > "$sd/detected" 2>/dev/null
  fi
  [ "$det" = 1 ] || return 0

  skip=0; if kp_is_envfile "$f" && kp_env_ok "$f"; then skip=1; fi
  found="$(kp_rules_check "$f" "$skip")"
  [ -n "$found" ] || return 0

  rel="$(kp_relpath "$cwd" "$f")"
  text="$(printf '%s\n' "$found" | {
    n=0; acc=""
    while IFS="$KP_TAB" read -r id sev line msg rep url; do
      [ "$n" -lt 3 ] || break
      kp_once "$sd" "$f:$id" || continue
      m="kernel: $rel: $id $msg. Use $rep. $url"
      if [ -z "$acc" ]; then acc="$m"; elif [ "$((${#acc} + ${#m} + 1))" -le 600 ]; then acc="$acc
$m"; else break; fi
      n=$((n + 1))
    done
    printf '%s' "$acc"
  })"
  [ -n "$text" ] || return 0
  text="$(printf '%s' "$text" | awk '{ print substr($0, 1, 600) }' | sed -n '1,3p')"
  kp_emit PostToolUse "$text"
}

main() {
  kp_read_stdin
  [ -n "$KP_JSON" ] || return 0
  kp_tool_stream | h3_body
}

out="$(main 2>/dev/null)" || out=""
[ -n "$out" ] && printf '%s\n' "$out"
exit 0
