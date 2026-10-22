#!/bin/sh
# secret-guard.sh -- PreToolUse on Edit|Write|MultiEdit|NotebookEdit|Bash and every Kernel MCP tool. Denies a Kernel API
# key literal in the new text of a file write (a gitignored file is fine) or in a Bash command, and any Kernel API key
# or 1Password service-account token (ops_...) in a Kernel MCP tool input (MCP inputs land in the transcript). A speed
# bump, not a vault: a key split over lines is not seen. Fail-open: only a positive match can deny.
case "$0" in */*) KP_PLUGIN_ROOT="${0%/*}/.." ;; *) KP_PLUGIN_ROOT="./.." ;; esac
{ . "$KP_PLUGIN_ROOT/lib/common.sh" && . "$KP_PLUGIN_ROOT/lib/browser.sh"; } 2>/dev/null || exit 0
kb_off && exit 0
[ "$KP_HAVE_JQ" = 1 ] || exit 0   # every kernel-browser hook parses nested MCP JSON: without jq they stay silent

deny() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' \
    "$(printf '%s' "$1" | json_escape)"
}

main() {
  kp_read_stdin
  case "$KP_JSON" in *sk_[0-9a-fA-F]*|*ops_*) ;; *) return 0 ;; esac   # cheap exit
  tool="$(kb_tool)"
  if [ -n "$tool" ]; then
    inp="$(printf '%s' "$KP_JSON" | jq -c '.tool_input // {}' 2>/dev/null)"
    if printf '%s' "$inp" | grep -E -q "$KP_KEY_RE"; then
      deny "kernel-browser: this $tool call carries a Kernel API key literal. Keys never go into tool input (it is stored in the transcript); the Kernel MCP authenticates on its own."; return 0
    fi
    if printf '%s' "$inp" | grep -E -q 'ops_[A-Za-z0-9_-]{20,}'; then
      deny "kernel-browser: this $tool call carries a 1Password service-account token. Connect 1Password in the Kernel dashboard (Integrations), never through chat or tool input."; return 0
    fi
    return 0
  fi
  case "$KP_JSON" in *sk_[0-9a-fA-F]*) ;; *) return 0 ;; esac
  tmp="$(mktemp "${TMPDIR:-/tmp}/kb-h4.XXXXXX")" || return 0
  trap 'rm -f "$tmp"' EXIT
  kp_parse_tool "$tmp" || return 0
  case "$KP_TOOL" in Edit|Write|MultiEdit|NotebookEdit|Bash) ;; *) return 0 ;; esac
  sed '1,4d' "$tmp" | grep -E -q "$KP_KEY_RE" || return 0
  if [ "$KP_TOOL" = Bash ]; then
    target="this Bash command"
  else
    [ -n "$KP_FILE" ] || return 0
    case "$KP_FILE" in /*) f="$KP_FILE" ;; *) f="$KP_CWD/$KP_FILE" ;; esac
    kp_env_ok "$f" && return 0
    target="$(kp_relpath "$KP_CWD" "$f")"
  fi
  deny "Kernel API key literal in $target. Read it from KERNEL_API_KEY (env or a gitignored .env); never commit or echo keys."
}

out="$(main 2>/dev/null)" || out=""
[ -n "$out" ] && printf '%s\n' "$out"
exit 0
