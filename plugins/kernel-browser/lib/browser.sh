# browser.sh -- kernel-browser hook helpers. POSIX sh, sourced after lib/common.sh. Never aborts the caller.
#
# Env: KERNEL_BROWSER_HOOKS=off              silences every kernel-browser hook
#      CLAUDE_PLUGIN_OPTION_<KEY>            plugin userConfig values (api_key, default_timeout_seconds, ...)
#      KERNEL_API_KEY, KERNEL_BASE_URL       fallback credentials / API host for the cleanup calls

# Kernel MCP tools, whichever copy of the server Claude Code kept: this plugin's, kernel-dev's, or a user/project
# server named "kernel" (e.g. from `kernel mcp install`).
KB_TOOL_RE='^mcp__(plugin_kernel-(browser|dev)_)?kernel__'
# Same literal as kernel-dev's lib/rules.sh (scripts/validate.sh checks they match).
KP_KEY_RE='sk_[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\.[A-Za-z0-9_-]{20,}'

kb_off() { [ "${KERNEL_BROWSER_HOOKS:-}" = "off" ]; }

# kb_opt <KEY> <default>: a userConfig value (exported by Claude Code as CLAUDE_PLUGIN_OPTION_<KEY>) or the default.
kb_opt() {
  eval "_kb_v=\${CLAUDE_PLUGIN_OPTION_$1:-}"
  if [ -n "$_kb_v" ]; then printf '%s' "$_kb_v"; else printf '%s' "$2"; fi
}

# kb_tool: the Kernel MCP tool name (manage_browsers, ...) of $KP_JSON, or nothing for any other tool.
kb_tool() {
  _kb_t="$(json_get tool_name)"
  printf '%s' "$_kb_t" | grep -E -q "${KB_TOOL_RE}" || return 0
  printf '%s' "${_kb_t##*kernel__}"
}

# kb_key: the API key for the cleanup calls (plugin option first, then KERNEL_API_KEY), or nothing.
kb_key() { kb_opt API_KEY "${KERNEL_API_KEY:-}"; }

# kb_api <METHOD> <path> [max-seconds] [project] [json-body]: Kernel REST call; prints the body and, on the last line,
# the HTTP code.
# The key goes to curl through a config on stdin, never on the command line (ps would show it).
kb_api() {
  _kb_k="$(kb_key)"; [ -n "$_kb_k" ] || return 1
  command -v curl >/dev/null 2>&1 || return 1
  _kb_base="${KERNEL_BASE_URL:-https://api.onkernel.com}"; _kb_base="${_kb_base%/}"
  {
    printf 'header = "Authorization: Bearer %s"\n' "$_kb_k"
    [ -n "${4:-}" ] && printf 'header = "X-Kernel-Project: %s"\n' "$4"
    [ -n "${5:-}" ] && printf 'header = "Content-Type: application/json"\n'
  } | if [ -n "${5:-}" ]; then
    curl -s -K - -X "$1" -m "${3:-2}" --data-raw "$5" -w '\n%{http_code}' "$_kb_base$2" 2>/dev/null
  else
    curl -s -K - -X "$1" -m "${3:-2}" -w '\n%{http_code}' "$_kb_base$2" 2>/dev/null
  fi
}

# ---- tracked browsers of one Claude Code session ----------------------------------------------------
# <state_dir>/browsers: one line per live browser this session created, acquired or set up:
#   id <TAB> name <TAB> keep(0|1) <TAB> agent_id <TAB> project <TAB> kind(browser|pool|setup) <TAB> pool
# An empty field is written as "-": `read` with a whitespace IFS would merge consecutive tabs.
kb_track_file() { printf '%s/browsers' "$1"; }

kb_track_add() { # <sd> <id> <name> <keep> <agent> <project> <kind> <pool>
  [ -n "$2" ] || return 0
  kb_track_del "$1" "$2"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$2" "${3:--}" "${4:-0}" "${5:--}" "${6:--}" "${7:--}" "${8:--}" >> "$(kb_track_file "$1")" 2>/dev/null
  return 0
}

kb_track_del() { # <sd> <id-or-name>
  _kb_f="$(kb_track_file "$1")"; [ -f "$_kb_f" ] || return 0
  awk -F'\t' -v x="$2" '$1 != x && $2 != x' "$_kb_f" > "$_kb_f.$$" 2>/dev/null && mv "$_kb_f.$$" "$_kb_f" 2>/dev/null
  return 0
}

kb_track_keep() { # <sd> <id-or-name> <0|1>
  _kb_f="$(kb_track_file "$1")"; [ -f "$_kb_f" ] || return 0
  awk -F'\t' -v OFS='\t' -v x="$2" -v k="$3" '($1 == x || $2 == x) { $3 = k } { print }' "$_kb_f" > "$_kb_f.$$" 2>/dev/null \
    && mv "$_kb_f.$$" "$_kb_f" 2>/dev/null
  return 0
}

# kb_prune_gone <sd>: drop tracked browsers the API reports as gone (404); at most 6 checks, 1 s each, in parallel.
kb_prune_gone() {
  _kb_f="$(kb_track_file "$1")"; [ -s "$_kb_f" ] || return 0
  [ -n "$(kb_key)" ] || return 0
  _kb_tmp="$(mktemp "${TMPDIR:-/tmp}/kb-prune.XXXXXX")" || return 0
  head -6 "$_kb_f" | {
    while IFS="$KP_TAB" read -r _id _n _k _a _p _kind _pool; do
      [ "$_p" = - ] && _p=""
      ( c="$(kb_api GET "/browsers/$_id" 1 "$_p" | tail -1)"; [ "$c" = 404 ] && printf '%s\n' "$_id" >> "$_kb_tmp" ) &
    done
    wait
  }
  while IFS= read -r _id; do kb_track_del "$1" "$_id"; done < "$_kb_tmp"
  rm -f "$_kb_tmp"
  return 0
}
