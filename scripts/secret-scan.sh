#!/usr/bin/env bash
# secret-scan.sh --staged | --tree | --history
# Fails (exit 1) on: Kernel API key literals (except the all-zero placeholder), tracked .env files
# (except .env.example), local-machine paths, personal e-mail, unmasked credential URLs, and -- when
# present locally -- the actual lab key and production resource ids (never committed).
set -o pipefail
MODE="${1:---staged}"
REPO="$(git rev-parse --show-toplevel)" || exit 2
cd "$REPO" || exit 2
KEY_RE='sk_[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\.[A-Za-z0-9_-]{20,}'
PLACEHOLDER='sk_(00000000|ABCDEF00)-0000-0000-0000-000000000000\.'   # synthetic test keys only (the second appears in v1.0.0 history)
HOME_RE='/Users/[A-Za-z0-9._-]+|@gmail\.com'
URL_RE='[?&](jwt|handoff_code|access_token)=[A-Za-z0-9._~%-]{8,}'
fail=0
report() { echo "secret-scan: $1" >&2; fail=1; }

scan_stream() { # reads text on stdin, label in $1
  local label="$1" text; text="$(cat)"
  [ -z "$text" ] && return 0
  printf '%s\n' "$text" | grep -E -o "$KEY_RE" | grep -v -E "^$PLACEHOLDER" | grep -q . && report "$label: Kernel API key literal"
  printf '%s\n' "$text" | grep -E -q "$HOME_RE" && report "$label: local path or personal e-mail"
  printf '%s\n' "$text" | grep -E -q "$URL_RE" && report "$label: unmasked credential URL (jwt/handoff_code/access_token)"
  # maintainers: set KP_LAB_DIR to a private directory (outside the repo) holding lab.env and ref/preexisting.ids to also
  # scan for the real throwaway key and for production resource ids. Unset: this part is skipped.
  local envf="${KP_LAB_DIR:-/nonexistent}/lab.env" idf="${KP_LAB_DIR:-/nonexistent}/ref/preexisting.ids" real
  if [ -f "$envf" ]; then
    real="$(sed -n 's/^KERNEL_API_KEY=//p' "$envf")"
    [ -n "$real" ] && printf '%s\n' "$text" | grep -F -q -- "$real" && report "$label: the REAL lab key"
  fi
  [ -f "$idf" ] && printf '%s\n' "$text" | grep -F -q -f "$idf" && report "$label: production resource id"
  return 0
}
bad_env_path() { grep -E '(^|/)\.env(\..+)?$' | grep -v -E '(^|/)\.env\.example$'; }

case "$MODE" in
  --staged)
    git diff --cached --name-only --diff-filter=ACMR | bad_env_path | grep -q . && report "staged .env file"
    scan_stream "staged diff" < <(git diff --cached -U0 --diff-filter=ACMR | grep -E '^\+[^+]') ;;
  --tree)
    git ls-files -co --exclude-standard | bad_env_path | grep -q . && report "tracked/untracked-unignored .env file"
    scan_stream "tree" < <(git ls-files -co --exclude-standard -z | xargs -0 grep -I -h -s -E '.' 2>/dev/null) ;;
  --history)
    git rev-parse --verify -q HEAD >/dev/null || { echo "secret-scan: no commits yet"; exit 0; }
    git log --all --name-only --pretty=format: | sort -u | bad_env_path | grep -q . && report "a .env file exists in history"
    scan_stream "history" < <(git log --all -p --pretty=format:) ;;
  *) echo "usage: $0 --staged|--tree|--history" >&2; exit 2 ;;
esac
[ $fail = 0 ] && echo "secret-scan: clean ($MODE)"
exit $fail
