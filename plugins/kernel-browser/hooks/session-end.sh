#!/bin/sh
# session-end.sh -- SessionEnd. Deletes the browsers this Claude Code session created and did not delete, except those
# tagged keep=after-session, through the Kernel API (key: plugin option api_key or KERNEL_API_KEY). All deletes run in
# parallel inside Claude Code's 1.5 s SessionEnd budget. Never touches a browser this session did not create. Without a
# key it does nothing (Kernel's idle timeout still deletes them). Pool browsers are released, not deleted. Fail-open.
case "$0" in */*) KP_PLUGIN_ROOT="${0%/*}/.." ;; *) KP_PLUGIN_ROOT="./.." ;; esac
{ . "$KP_PLUGIN_ROOT/lib/common.sh" && . "$KP_PLUGIN_ROOT/lib/browser.sh"; } 2>/dev/null || exit 0
kb_off && exit 0
[ "$KP_HAVE_JQ" = 1 ] || exit 0   # every kernel-browser hook parses nested MCP JSON: without jq they stay silent

main() {
  [ "$(kb_opt CLEANUP_ON_SESSION_END true)" = false ] && return 0
  kp_read_stdin
  [ -n "$KP_JSON" ] || return 0
  [ -n "$(kb_key)" ] || return 0
  sd="$(kp_state_dir "$(json_get session_id)")"
  f="$(kb_track_file "$sd")"; [ -s "$f" ] || return 0
  while IFS="$KP_TAB" read -r id name keep agent project kind pool; do
    [ -n "$id" ] && [ "$keep" != 1 ] || continue
    [ "$project" = - ] && project=""
    if [ "$kind" = pool ] && [ "$pool" != - ]; then
      ( kb_api POST "/browser_pools/$pool/release" 1.2 "$project" "{\"session_id\":\"$id\",\"reuse\":false}" >/dev/null ) &
    else
      ( kb_api DELETE "/browsers/$id" 1.2 "$project" >/dev/null ) &
    fi
  done < "$f"
  wait
  printf '' > "$f" 2>/dev/null
}

main >/dev/null 2>&1
exit 0
