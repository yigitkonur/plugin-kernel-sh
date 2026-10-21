#!/usr/bin/env bash
# sync-version.sh <plugin-dir-name> <X.Y.Z> -- set one plugin's version in its plugin.json and its marketplace entry.
#   scripts/sync-version.sh kernel-dev 2.0.0
set -eu
cd "$(git rev-parse --show-toplevel)"
[ $# -eq 2 ] || { echo "usage: $0 <plugin-dir-name> <X.Y.Z>" >&2; exit 2; }
P="plugins/$1"; V="$2"
[ -f "$P/.claude-plugin/plugin.json" ] || { echo "sync-version: no $P/.claude-plugin/plugin.json" >&2; exit 2; }
tmp="$(mktemp)"
jq --arg v "$V" '.version=$v' "$P/.claude-plugin/plugin.json" > "$tmp" && mv "$tmp" "$P/.claude-plugin/plugin.json"
jq --arg v "$V" --arg s "./$P" '(.plugins[] | select(.source == $s) | .version) = $v' .claude-plugin/marketplace.json > "$tmp" && mv "$tmp" .claude-plugin/marketplace.json
echo "$1 set to $V"
