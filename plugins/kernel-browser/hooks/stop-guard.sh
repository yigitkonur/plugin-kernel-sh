#!/bin/sh
# stop-guard.sh <stop|subagent> -- Stop / SubagentStop. If browsers this session (or this subagent) created are still
# alive, block the stop ONCE per session (once per subagent) with their ids, so the agent deletes the ones the task no
# longer needs. Kept browsers are fine: they idle for free and session-end deletes them. Respects stop_hook_active.
# Tracked browsers the API reports as gone are dropped first (when a key is available). Fail-open.
case "$0" in */*) KP_PLUGIN_ROOT="${0%/*}/.." ;; *) KP_PLUGIN_ROOT="./.." ;; esac
{ . "$KP_PLUGIN_ROOT/lib/common.sh" && . "$KP_PLUGIN_ROOT/lib/browser.sh"; } 2>/dev/null || exit 0
kb_off && exit 0
[ "$KP_HAVE_JQ" = 1 ] || exit 0   # every kernel-browser hook parses nested MCP JSON: without jq they stay silent

main() {
  kind="${1:-stop}"
  kp_read_stdin
  [ -n "$KP_JSON" ] || return 0
  [ "$(printf '%s' "$KP_JSON" | jq -r '.stop_hook_active // false' 2>/dev/null)" = true ] && return 0
  sd="$(kp_state_dir "$(json_get session_id)")"
  [ -n "$(kb_track_live "$sd")" ] || return 0
  agent="$(printf '%s' "$KP_JSON" | jq -r '.agent_id // empty' 2>/dev/null)"
  if [ "$kind" = subagent ]; then
    [ -n "$agent" ] || return 0
    kp_once "$sd" "stop-reminded:$agent" || return 0
  else
    kp_once "$sd" "stop-reminded" || return 0
  fi
  kb_prune_gone "$sd"
  ids="$(kb_track_live "$sd" | awk -F'\t' -v a="$agent" -v k="$kind" '(k != "subagent" || $4 == a) && $3 != 1 { printf "%s%s", (n++ ? ", " : ""), ($2 != "-" ? $2 " (" $1 ")" : $1) }')"
  [ -n "$ids" ] || return 0
  reason="kernel-browser: Kernel browsers created in this session are still alive: $ids. Delete each one the task no longer needs (manage_browsers action delete; pool browsers: manage_browser_pools release). If the user may continue with it, keep it and say so: idle browsers cost nothing and are deleted when this Claude Code session ends. Tag keep=after-session only if the user asked to keep it after the session."
  printf '{"decision":"block","reason":"%s"}\n' "$(printf '%s' "$reason" | json_escape)"
}

out="$(main "$@" 2>/dev/null)" || out=""
[ -n "$out" ] && printf '%s\n' "$out"
exit 0
