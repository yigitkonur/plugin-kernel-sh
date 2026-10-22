#!/bin/sh
# create-guard.sh -- PreToolUse on Kernel MCP manage_browsers / manage_browser_pools / manage_profiles. Denies a browser
# create that the session could not clean up later: no tags.cc_session = <this session id>, no explicit timeout_seconds,
# or a timeout above max_timeout_seconds; denies a pool create/update above the cap. When the plugin's `project` option
# is set, also denies a browser create, pool create or acquire, or profile setup that does not target that project
# (cleanup runs there). Deny (never allow) keeps the user's permission rules untouched: the model resends the call with
# the values in the reason. Fields a tool cannot take (tags on setup or acquire) are never asked for. Fail-open.
case "$0" in */*) KP_PLUGIN_ROOT="${0%/*}/.." ;; *) KP_PLUGIN_ROOT="./.." ;; esac
{ . "$KP_PLUGIN_ROOT/lib/common.sh" && . "$KP_PLUGIN_ROOT/lib/browser.sh"; } 2>/dev/null || exit 0
kb_off && exit 0
[ "$KP_HAVE_JQ" = 1 ] || exit 0   # every kernel-browser hook parses nested MCP JSON: without jq they stay silent

main() {
  kp_read_stdin
  [ -n "$KP_JSON" ] || return 0
  tool="$(kb_tool)"
  case "$tool" in manage_browsers|manage_browser_pools|manage_profiles) ;; *) return 0 ;; esac
  action="$(printf '%s' "$KP_JSON" | jq -r '.tool_input.action // empty' 2>/dev/null)"
  sid="$(json_get session_id)"
  max="$(kb_opt MAX_TIMEOUT_SECONDS 1800)"; def="$(kb_opt DEFAULT_TIMEOUT_SECONDS 600)"
  t="$(printf '%s' "$KP_JSON" | jq -r '.tool_input.timeout_seconds // empty' 2>/dev/null)"
  why=""
  if [ "$tool" = manage_browsers ] && [ "$action" = create ]; then
    tag="$(printf '%s' "$KP_JSON" | jq -r '.tool_input.tags.cc_session // empty' 2>/dev/null)"
    [ -n "$sid" ] && [ "$tag" != "$sid" ] && why="add tags.cc_session = \"$sid\" (keep your other tags)"
    if [ -z "$t" ]; then why="${why:+$why; }set timeout_seconds explicitly (suggested $def; the 60 s default can delete the browser while you wait for the user)"
    elif [ "$t" -gt "$max" ] 2>/dev/null; then why="${why:+$why; }use timeout_seconds <= $max (suggested $def)"; fi
  elif [ "$tool" = manage_browser_pools ] && { [ "$action" = create ] || [ "$action" = update ]; }; then
    [ -n "$t" ] && [ "$t" -gt "$max" ] 2>/dev/null && why="use timeout_seconds <= $max for pool browsers"
  fi
  proj="$(kb_opt PROJECT '')"
  if [ -n "$proj" ]; then
    case "$tool:$action" in
      manage_browsers:create|manage_browser_pools:create|manage_browser_pools:acquire|manage_profiles:setup)
        got="$(printf '%s' "$KP_JSON" | jq -r '.tool_input.project // .tool_input.project_id // empty' 2>/dev/null)"
        [ "$got" = "$proj" ] || why="${why:+$why; }set project = \"$proj\" (the kernel-browser project option: cleanup runs there; pass it on every Kernel call)" ;;
    esac
  fi
  [ -n "$why" ] || return 0
  reason="kernel-browser: resend this $tool $action and $why. timeout_seconds counts idle time only (idle browsers cost nothing), and the session tag lets Claude Code delete what this session created when it ends."
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' \
    "$(printf '%s' "$reason" | json_escape)"
}

out="$(main 2>/dev/null)" || out=""
[ -n "$out" ] && printf '%s\n' "$out"
exit 0
