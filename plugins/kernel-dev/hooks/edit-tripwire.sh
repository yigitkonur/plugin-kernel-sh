#!/bin/sh
# edit-tripwire.sh -- H3 (PostToolUse on Edit|Write|MultiEdit|NotebookEdit, and apply_patch in Codex): flag deprecated Kernel identifiers the
# agent just wrote. A rule fires only if more lines of the NEW text match it than lines of the text it replaced, AND
# the file on disk matches; once per
# (session, file, rule); at most 3 findings; <= 600 chars; only in detected Kernel projects whose file carries a marker;
# files over 512 KB are skipped. Fail-open: any problem => exit 0, empty stdout.
case "$0" in */*) KP_PLUGIN_ROOT="${0%/*}/.." ;; *) KP_PLUGIN_ROOT="./.." ;; esac
{ . "$KP_PLUGIN_ROOT/lib/common.sh" && . "$KP_PLUGIN_ROOT/lib/detect.sh" && . "$KP_PLUGIN_ROOT/lib/rules.sh"; } 2>/dev/null || exit 0
kp_off && exit 0

# stdin = kp_tool_stream old: 4 metadata lines, then the new text, a separator line and the replaced text (consumed by the rules awk)
h3_body() {
  IFS= read -r sid; IFS= read -r cwd; IFS= read -r tool; IFS= read -r fp
  case "$tool" in Edit|Write|MultiEdit|NotebookEdit|apply_patch) ;; *) return 0 ;; esac
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
    kp_save_detected "$sd"
  fi
  [ "$det" = 1 ] || return 0

  found="$(kp_rules_check "$f" 0)"
  # a key literal in a gitignored file is the supported place (H4 allows it): drop K019 there; asked only when K019 fired,
  # because the git calls behind kp_env_ok cost more than the rest of the hook
  case "$found" in *K019*) if kp_env_ok "$f"; then found="$(printf '%s\n' "$found" | grep -v "^K019$KP_TAB")"; fi ;; esac
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

# Codex apply_patch: one patch can touch several files; each file goes through h3_body as if it were one Edit, and the
# first file with a finding is reported (the hook prints one JSON object).
h3_patch() {
  _sid="$(json_get session_id)"; _cwd="$(json_get cwd)"
  _pd="$(mktemp -d "${TMPDIR:-/tmp}/kp-h3.XXXXXX")" || return 0
  _n="$(json_get tool_input.command | kp_patch_explode "$_pd")"
  _i=1
  while [ "$_i" -le "${_n:-0}" ]; do
    IFS= read -r _p < "$_pd/$_i.path"
    _o="$({ printf '%s\n%s\napply_patch\n%s\n' "$_sid" "$_cwd" "$_p"; cat "$_pd/$_i.new"; printf '\001KP-OLD\001\n'; cat "$_pd/$_i.old"; } | h3_body)"
    if [ -n "$_o" ]; then printf '%s\n' "$_o"; break; fi
    _i=$((_i + 1))
  done
  rm -rf "$_pd"
}

main() {
  kp_read_stdin
  [ -n "$KP_JSON" ] || return 0
  if [ "$(json_get tool_name)" = apply_patch ]; then h3_patch; else kp_tool_stream old | h3_body; fi
}

out="$(main 2>/dev/null)" || out=""
[ -n "$out" ] && printf '%s\n' "$out"
exit 0
