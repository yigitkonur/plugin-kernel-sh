#!/bin/sh
# track.sh -- PostToolUse on Kernel MCP manage_browsers / manage_profiles / manage_browser_pools. Records the browsers
# this Claude Code session created (create, profile setup, pool acquire) and forgets them on delete/release, so the
# stop and session-end hooks know what to clean up. Marks a browser kept past the session when the agent tags it
# keep=after-session (only on the user's request, per the browse skill). Prints nothing. Fail-open.
case "$0" in */*) KP_PLUGIN_ROOT="${0%/*}/.." ;; *) KP_PLUGIN_ROOT="./.." ;; esac
{ . "$KP_PLUGIN_ROOT/lib/common.sh" && . "$KP_PLUGIN_ROOT/lib/browser.sh"; } 2>/dev/null || exit 0
kb_off && exit 0
[ "$KP_HAVE_JQ" = 1 ] || exit 0   # every kernel-browser hook parses nested MCP JSON: without jq they stay silent

main() {
  kp_read_stdin
  [ -n "$KP_JSON" ] || return 0
  tool="$(kb_tool)"
  case "$tool" in manage_browsers|manage_profiles|manage_browser_pools) ;; *) return 0 ;; esac
  sd="$(kp_state_dir "$(json_get session_id)")"
  # one jq pass: action, ids and the response text (the MCP returns [{type:"text", text:"<json or prose>"}])
  printf '%s' "$KP_JSON" | jq -r '
    def txt: [(.tool_response // []) | if type == "array" then .[] else . end | objects | .text // empty] | join("\n");
    def body: (txt | try fromjson catch {});
    [ (.tool_input.action // ""),
      (.tool_input.session_id // ""),
      (.tool_input.name // ""),
      (.tool_input.project // ""),
      (.agent_id // ""),
      ((.tool_input.tags // {}) | .keep // ""),
      ((.tool_input.tags // null) | if . == null then "" else "set" end),
      (body | .browser.session_id // ""),
      (body | .browser.pool.id // ""),
      (txt | capture("session id: (?<s>[a-z0-9]+)").s? // ""),
      (txt | test("deleted|released") | tostring),
      (.tool_input.id_or_name // "")
    ] | map(if . == "" then "-" else . end) | @tsv' 2>/dev/null | {
    IFS="$KP_TAB" read -r action in_sid name project agent keep tagsset out_sid pool setup_sid ok pool_in || return 0
    [ "$out_sid" = - ] && out_sid=""; [ "$setup_sid" = - ] && setup_sid=""; [ "$pool" = - ] && pool="$pool_in"
    case "$tool:$action" in
      manage_browsers:create)
        k=0; [ "$keep" = after-session ] && k=1
        kb_track_add "$sd" "$out_sid" "$name" "$k" "$agent" "$project" browser "" ;;
      manage_browsers:delete) [ "$ok" = true ] && kb_track_del "$sd" "$in_sid" ;;
      manage_browsers:update)
        if [ "$tagsset" = set ]; then k=0; [ "$keep" = after-session ] && k=1; kb_track_keep "$sd" "$in_sid" "$k"; fi ;;
      manage_profiles:setup) kb_track_add "$sd" "$setup_sid" "" 0 "$agent" "$project" setup "" ;;
      manage_browser_pools:acquire) kb_track_add "$sd" "$out_sid" "" 0 "$agent" "$project" pool "$pool" ;;
      manage_browser_pools:release) [ "$ok" = true ] && kb_track_del "$sd" "$in_sid" ;;
    esac
  }
}

main >/dev/null 2>&1
exit 0
