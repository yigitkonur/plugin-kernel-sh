#!/bin/sh
# redact.sh -- PostToolUse on Kernel MCP tools. Masks the values of cdp_ws_url, webdriver_ws_url and base_url (bearer
# URLs to drive the browser) and any Kernel API key literal in the tool result before the model sees it, through
# updatedMCPToolOutput. The live-view and hosted-login URLs stay: the user needs them. Prints nothing when there is
# nothing to mask. Fail-open.
case "$0" in */*) KP_PLUGIN_ROOT="${0%/*}/.." ;; *) KP_PLUGIN_ROOT="./.." ;; esac
{ . "$KP_PLUGIN_ROOT/lib/common.sh" && . "$KP_PLUGIN_ROOT/lib/browser.sh"; } 2>/dev/null || exit 0
kb_off && exit 0
[ "$KP_HAVE_JQ" = 1 ] || exit 0   # every kernel-browser hook parses nested MCP JSON: without jq they stay silent

main() {
  kp_read_stdin
  [ -n "$KP_JSON" ] || return 0
  [ -n "$(kb_tool)" ] || return 0
  case "$KP_JSON" in *cdp_ws_url*|*webdriver_ws_url*|*base_url*|*sk_[0-9a-fA-F]*) ;; *) return 0 ;; esac
  printf '%s' "$KP_JSON" | jq -c --arg kre "$KP_KEY_RE" '
    def mask: gsub("(?<k>\\\\?\"(cdp_ws_url|webdriver_ws_url|base_url)\\\\?\"\\s*:\\s*\\\\?\")[^\"\\\\]+"; "\(.k)***") | gsub($kre; "sk_***");
    (.tool_response // empty) as $r
    | ($r | if type == "array" then map(if type == "object" and (.text | type) == "string" then .text |= mask else . end)
            elif type == "string" then mask else . end) as $new
    | if $new == $r then empty
      else {hookSpecificOutput: {hookEventName: "PostToolUse", updatedMCPToolOutput: $new}} end' 2>/dev/null
}

out="$(main 2>/dev/null)" || out=""
[ -n "$out" ] && printf '%s\n' "$out"
exit 0
