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
# <state_dir>/browsers is an append-only event log, so parallel hooks (parallel tool calls) never lose each other's
# writes: each change is one short line appended in one write. Events (tab-separated):
#   +  id name keep(0|1) agent_id project kind(browser|pool|setup) pool    a browser this session created/acquired
#   -  id-or-name                                                          deleted or released
#   k  id-or-name keep(0|1)                                                keep flag changed
# An empty field is written as "-": `read` with a whitespace IFS would merge consecutive tabs.
# kb_track_live folds the log into one line per live browser: id name keep agent project kind pool.
kb_track_file() { printf '%s/browsers' "$1"; }

kb_track_add() { # <sd> <id> <name> <keep> <agent> <project> <kind> <pool>
  [ -n "$2" ] || return 0
  printf '+\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$2" "${3:--}" "${4:-0}" "${5:--}" "${6:--}" "${7:--}" "${8:--}" >> "$(kb_track_file "$1")" 2>/dev/null
  return 0
}

kb_track_del() { # <sd> <id-or-name>
  [ -n "$2" ] && [ "$2" != - ] || return 0
  printf -- '-\t%s\n' "$2" >> "$(kb_track_file "$1")" 2>/dev/null
  return 0
}

kb_track_keep() { # <sd> <id-or-name> <0|1>
  [ -n "$2" ] && [ "$2" != - ] || return 0
  printf 'k\t%s\t%s\n' "$2" "$3" >> "$(kb_track_file "$1")" 2>/dev/null
  return 0
}

kb_track_live() { # <sd>: the live set, in creation order
  _kb_f="$(kb_track_file "$1")"; [ -s "$_kb_f" ] || return 0
  awk -F'\t' -v OFS='\t' '
    $1 == "+" { if (!($2 in row)) order[++n] = $2; row[$2] = $2 OFS $3 OFS $4 OFS $5 OFS $6 OFS $7 OFS $8; name[$2] = $3; next }
    $1 == "-" { for (i in row) if (i == $2 || name[i] == $2) delete row[i]; next }
    $1 == "k" { for (i in row) if (i == $2 || name[i] == $2) { split(row[i], f, OFS); f[3] = $3
                  row[i] = f[1] OFS f[2] OFS f[3] OFS f[4] OFS f[5] OFS f[6] OFS f[7] } }
    END { for (j = 1; j <= n; j++) if (order[j] in row) print row[order[j]] }' "$_kb_f" 2>/dev/null
}

# kb_project <recorded>: the project for a cleanup call: the one recorded at create, else the plugin option.
kb_project() { if [ -n "$1" ] && [ "$1" != - ]; then printf '%s' "$1"; else kb_opt PROJECT ''; fi; }

# kb_prune_gone <sd>: drop tracked browsers the API reports as gone (404); at most 6 checks, 1 s each, in parallel.
kb_prune_gone() {
  [ -n "$(kb_track_live "$1")" ] || return 0
  [ -n "$(kb_key)" ] || return 0
  _kb_tmp="$(mktemp "${TMPDIR:-/tmp}/kb-prune.XXXXXX")" || return 0
  kb_track_live "$1" | head -6 | {
    while IFS="$KP_TAB" read -r _id _n _k _a _p _kind _pool; do
      _p="$(kb_project "$_p")"
      ( c="$(kb_api GET "/browsers/$_id" 1 "$_p" | tail -1)"; [ "$c" = 404 ] && printf '%s\n' "$_id" >> "$_kb_tmp" ) &
    done
    wait
  }
  while IFS= read -r _id; do kb_track_del "$1" "$_id"; done < "$_kb_tmp"
  rm -f "$_kb_tmp"
  return 0
}
