#!/bin/sh
# secret-guard.sh -- H4 (PreToolUse on Edit|Write|MultiEdit|NotebookEdit|Bash, and apply_patch in Codex): deny a Kernel API key literal in the new
# text of a tool input. Exception: a write whose target file is gitignored (or an .env-named file outside any git repo).
# A Bash command containing the literal is always denied. Allowed cases print nothing (the normal permission flow
# applies). Fail-open: only a positive key match can deny. Not covered by design: a key split across lines, and tools
# outside the matcher (MCP tools, subagent prompts, WebFetch): this is a speed bump, not a vault.
case "$0" in */*) KP_PLUGIN_ROOT="${0%/*}/.." ;; *) KP_PLUGIN_ROOT="./.." ;; esac
{ . "$KP_PLUGIN_ROOT/lib/common.sh" && . "$KP_PLUGIN_ROOT/lib/rules.sh"; } 2>/dev/null || exit 0
kp_off && exit 0

main() {
  kp_read_stdin
  case "$KP_JSON" in *sk_[0-9a-fA-F]*) ;; *) return 0 ;; esac   # cheap exit: no forks unless "sk_" is followed by a hex digit
  tmp="$(mktemp "${TMPDIR:-/tmp}/kp-h4.XXXXXX")" || return 0
  trap 'rm -f "$tmp"' EXIT
  kp_parse_tool "$tmp" || return 0
  case "$KP_TOOL" in Edit|Write|MultiEdit|NotebookEdit|Bash|apply_patch) ;; *) return 0 ;; esac
  if [ "$KP_TOOL" = apply_patch ]; then   # Codex: the patch text is tool_input.command; the first file that gets a key decides
    target="$(kp_patch_key_target "$(json_get tool_input.command)" "$KP_CWD")" || return 0
  else
    sed '1,4d' "$tmp" | grep -E -q "$KP_KEY_RE" || return 0
    if [ "$KP_TOOL" = Bash ]; then
      target="this Bash command"
    else
      [ -n "$KP_FILE" ] || return 0
      case "$KP_FILE" in /*) f="$KP_FILE" ;; *) f="$KP_CWD/$KP_FILE" ;; esac
      kp_env_ok "$f" && return 0
      target="$(kp_relpath "$KP_CWD" "$f")"
    fi
  fi
  reason="Kernel API key literal in $target. Read it from KERNEL_API_KEY (env or a gitignored .env); never commit or echo keys."
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' \
    "$(printf '%s' "$reason" | json_escape)"
}

out="$(main 2>/dev/null)" || out=""
[ -n "$out" ] && printf '%s\n' "$out"
exit 0
