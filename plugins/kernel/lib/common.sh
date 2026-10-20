# common.sh -- shared helpers for the kernel plugin hooks and bin/kernel-plugin.
# POSIX sh (macOS /bin/sh, dash, busybox). Sourced, never executed. No bashisms.
# Contract: helpers never abort the caller; hooks wrap everything so any failure ends in exit 0 / empty stdout.
#
# Env: KERNEL_PLUGIN_HOOKS=off  silences every hook
#      CLAUDE_PLUGIN_DATA       state root parent (state lives in $CLAUDE_PLUGIN_DATA/state)
#      KP_NO_JQ=1               test switch: ignore jq and use the sed fallback

KP_TAB="$(printf '\t')"
KP_CR="$(printf '\r')"
if [ -z "${KP_NO_JQ:-}" ] && command -v jq >/dev/null 2>&1; then KP_HAVE_JQ=1; else KP_HAVE_JQ=0; fi

# kp_root_of <script-path> -> plugin root (no subshell, no cd)
kp_root_of() {
  case "$1" in */*) _kp_d="${1%/*}" ;; *) _kp_d="." ;; esac
  printf '%s' "$_kp_d/.."
}

kp_off() { [ "${KERNEL_PLUGIN_HOOKS:-}" = "off" ]; }

# kp_read_stdin -> KP_JSON
kp_read_stdin() { KP_JSON="$(cat 2>/dev/null)"; }

# kp_unescape: JSON string body on stdin -> text (best effort: \n \t \" \\ \/)
kp_unescape() {
  sed -e 's/\\n/\
/g' -e "s/\\\\t/$KP_TAB/g" -e 's/\\"/"/g' -e 's#\\/#/#g' -e 's/\\\\/\\/g'
}

# json_get <dotted.path>  (reads $KP_JSON; prints a string value or nothing)
json_get() {
  if [ "$KP_HAVE_JQ" = 1 ]; then
    printf '%s' "$KP_JSON" | jq -r --arg p "$1" 'getpath($p | split(".")) | if type == "string" then . else empty end' 2>/dev/null
  else
    _kp_key="${1##*.}"; _kp_scope=""
    case "$1" in *.*) _kp_scope="${1%.*}"; _kp_scope="${_kp_scope##*.}" ;; esac
    _kp_src="$KP_JSON"
    if [ -n "$_kp_scope" ]; then
      _kp_src="$(printf '%s' "$KP_JSON" | sed -n -E "s/^.*\"$_kp_scope\"[[:space:]]*:[[:space:]]*\{//p" | sed -e 's/,"tool_response".*$//')"
    fi
    printf '%s' "$_kp_src" | sed -n -E "s/^.*\"$_kp_key\"[[:space:]]*:[[:space:]]*\"(([^\"\\\\]|\\\\.)*)\".*\$/\\1/p" | sed -n 1p | kp_unescape
  fi
}

# json_escape: stdin -> JSON string body (no surrounding quotes)
json_escape() {
  sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e "s/$KP_TAB/\\\\t/g" -e "s/$KP_CR/\\\\r/g" \
      -e ':a' -e '$!N' -e '$!ba' -e 's/\n/\\n/g'
}

# kp_emit <HookEventName> <text>: prints {"hookSpecificOutput":{...additionalContext}}
kp_emit() {
  _kp_body="$(printf '%s' "$2" | json_escape)"
  printf '{"hookSpecificOutput":{"hookEventName":"%s","additionalContext":"%s"}}\n' "$1" "$_kp_body"
}

# ---- state -------------------------------------------------------------
kp_state_root() {
  if [ -n "${CLAUDE_PLUGIN_DATA:-}" ]; then printf '%s/state' "$CLAUDE_PLUGIN_DATA"
  else printf '%s/kernel-plugin-state' "${TMPDIR:-/tmp}"; fi
}

# kp_state_dir <session_id> -> prints (and creates) the per-session dir
kp_state_dir() {
  _kp_sid="$1"
  case "$_kp_sid" in *[!A-Za-z0-9_-]*) _kp_sid="$(printf '%s' "$_kp_sid" | tr -c 'A-Za-z0-9_-' '_')" ;; esac
  [ -n "$_kp_sid" ] || _kp_sid="nosession"
  _kp_sd="$(kp_state_root)/$_kp_sid"
  [ -d "$_kp_sd" ] || mkdir -p "$_kp_sd" 2>/dev/null
  printf '%s' "$_kp_sd"
}

# kp_once <state_dir> <key>: returns 0 the first time a key is seen, 1 afterwards
kp_once() {
  [ -f "$1/once" ] && grep -q -x -F -- "$2" "$1/once" 2>/dev/null && return 1
  printf '%s\n' "$2" >> "$1/once" 2>/dev/null
  return 0
}

# kp_prune: delete state entries older than 7 days (only inside our own state root)
kp_prune() {
  _kp_r="$(kp_state_root)"
  case "$_kp_r" in */state|*/kernel-plugin-state) ;; *) return 0 ;; esac
  [ -d "$_kp_r" ] || return 0
  find "$_kp_r" -maxdepth 1 ! -path "$_kp_r" -mtime +7 -exec rm -rf {} + >/dev/null 2>&1
  return 0
}

# ---- paths / env files --------------------------------------------------
# kp_is_envfile <path>: basename matches ^\.env(\..+)?$
kp_is_envfile() {
  case "${1##*/}" in .env|.env.?*) return 0 ;; esac
  return 1
}

# kp_env_ok <path>: a .env-style file where a key literal is acceptable
# (gitignored, or outside any git repo). Existing ancestor dir is used for new files.
kp_env_ok() {
  kp_is_envfile "$1" || return 1
  _kp_dir="${1%/*}"; [ "$_kp_dir" = "$1" ] && _kp_dir="."
  while [ -n "$_kp_dir" ] && [ ! -d "$_kp_dir" ]; do
    case "$_kp_dir" in */*) _kp_dir="${_kp_dir%/*}" ;; *) _kp_dir="." ;; esac
    [ "$_kp_dir" = "" ] && _kp_dir="/"
  done
  git -C "$_kp_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  git -C "$_kp_dir" check-ignore -q -- "$1" 2>/dev/null
}

# kp_tool_stream: prints 4 metadata lines (session_id, cwd, tool_name, file path) followed by the NEW text of the
# tool input (Write.content, Edit.new_string, NotebookEdit.new_source, MultiEdit edits[].new_string, Bash.command).
# old_string / tool_response are deliberately excluded (so removing a legacy line is not "writing" it).
kp_tool_stream() {
  if [ "$KP_HAVE_JQ" = 1 ]; then
    printf '%s' "$KP_JSON" | jq -r '
      ([(.session_id // ""), (.cwd // ""), (.tool_name // ""),
        ((.tool_input | objects | (.file_path // .notebook_path // "")) // "")] | .[] | tostring | gsub("\n"; " ")),
      ((.tool_input | objects | (.content, .new_string, .new_source, .command, (.edits // [] | arrays | .[] | objects | .new_string)) | strings))' 2>/dev/null
  else
    _kp_f="$(json_get tool_input.file_path)"; [ -n "$_kp_f" ] || _kp_f="$(json_get tool_input.notebook_path)"
    printf '%s\n%s\n%s\n%s\n' "$(json_get session_id)" "$(json_get cwd)" "$(json_get tool_name)" "$_kp_f"
    printf '%s' "$KP_JSON" | sed -n -E 's/^.*"tool_input"[[:space:]]*:[[:space:]]*\{//p' | sed -e 's/,"tool_response".*$//' \
      | sed -E 's/"old_string"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)"//g' | kp_unescape
  fi
}

# kp_parse_tool <outfile>: kp_tool_stream into <outfile>; sets KP_SID KP_CWD KP_TOOL KP_FILE
kp_parse_tool() {
  KP_SID=""; KP_CWD=""; KP_TOOL=""; KP_FILE=""
  kp_tool_stream > "$1" 2>/dev/null || return 1
  { IFS= read -r KP_SID; IFS= read -r KP_CWD; IFS= read -r KP_TOOL; IFS= read -r KP_FILE; } < "$1"
  return 0
}

# kp_relpath <cwd> <path>
kp_relpath() { case "$2" in "$1"/*) printf '%s' "${2#"$1"/}" ;; *) printf '%s' "$2" ;; esac; }
