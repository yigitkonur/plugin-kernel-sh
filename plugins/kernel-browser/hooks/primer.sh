#!/bin/sh
# primer.sh <session|subagent> -- SessionStart / SubagentStart: a short note that Kernel cloud browsers are available
# and the rules that prevent the costly mistakes. On SessionStart, when check_leftovers_on_start is on and a key is
# available, one Kernel API call (2 s cap, cached 10 min) counts browsers left alive by earlier Claude Code sessions.
# Fail-open: any problem => the plain primer or nothing.
case "$0" in */*) KP_PLUGIN_ROOT="${0%/*}/.." ;; *) KP_PLUGIN_ROOT="./.." ;; esac
{ . "$KP_PLUGIN_ROOT/lib/common.sh" && . "$KP_PLUGIN_ROOT/lib/browser.sh"; } 2>/dev/null || exit 0
kb_off && exit 0
[ "$KP_HAVE_JQ" = 1 ] || exit 0   # every kernel-browser hook parses nested MCP JSON: without jq they stay silent

leftovers() { # prints "N" browsers tagged by other Claude Code sessions, or nothing
  [ "$(kb_opt CHECK_LEFTOVERS_ON_START true)" = false ] && return 0
  [ -n "$(kb_key)" ] || return 0
  c="$(kp_state_root)/leftovers.cache"
  if [ -f "$c" ] && [ -z "$(find "$c" -mmin +10 2>/dev/null)" ]; then cat "$c"; return 0; fi
  out="$(kb_api GET "/browsers?status=active&limit=100" 2 "$(kb_opt PROJECT '')")" || return 0
  code="$(printf '%s\n' "$out" | tail -1)"; [ "$code" = 200 ] || return 0
  n="$(printf '%s\n' "$out" | sed '$d' | jq --arg s "$1" '[.[]? | select((.tags.cc_session // "") != "" and .tags.cc_session != $s)] | length' 2>/dev/null)"
  [ -n "$n" ] || return 0
  printf '%s' "$n" > "$c.$$" 2>/dev/null && mv "$c.$$" "$c" 2>/dev/null
  printf '%s' "$n"
}

main() {
  kind="${1:-session}"
  kp_read_stdin
  [ -n "$KP_JSON" ] || return 0
  sid="$(json_get session_id)"
  text="[kernel-browser] Kernel cloud browsers are available through the Kernel MCP tools (manage_browsers, execute_playwright_code, browser_repl, computer_action). For web tasks that should run off this machine, on logged-in sites saved in Kernel profiles, or on sites that block bots, load the skill kernel-browser:browse first. Rules: reuse a saved profile read-only (never two writers); create browsers with tags.cc_session=\"$sid\" and an explicit timeout_seconds; delete a browser when its task is done; never type passwords or 2FA codes from chat (use kernel-browser:login); confirm a submit, send or purchase with the user and never repeat one whose outcome is unknown."
  if [ "$kind" = session ]; then
    n="$(leftovers "$sid")"
    [ -n "$n" ] && [ "$n" -gt 0 ] 2>/dev/null && text="$text Note: $n Kernel browser(s) from earlier Claude Code sessions are still alive (they hold concurrency slots); /kernel-browser:sessions lists and cleans them."
    ev=SessionStart
  else ev=SubagentStart; fi
  kp_emit "$ev" "$text"
}

out="$(main "$@" 2>/dev/null)" || out=""
[ -n "$out" ] && printf '%s\n' "$out"
exit 0
