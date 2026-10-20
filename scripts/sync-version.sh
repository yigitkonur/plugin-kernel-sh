#!/usr/bin/env bash
# sync-version.sh [X.Y.Z] -- write VERSION (if given) into plugin.json and marketplace.json (metadata + plugin entry).
set -eu
cd "$(git rev-parse --show-toplevel)"
[ $# -ge 1 ] && printf '%s\n' "$1" > VERSION
V="$(tr -d '[:space:]' < VERSION)"
tmp="$(mktemp)"
jq --arg v "$V" '.version=$v' plugins/kernel/.claude-plugin/plugin.json > "$tmp" || { echo "sync-version: jq failed on plugin.json" >&2; rm -f "$tmp"; exit 1; }
mv "$tmp" plugins/kernel/.claude-plugin/plugin.json
jq --arg v "$V" '.metadata.version=$v | .plugins[0].version=$v' .claude-plugin/marketplace.json > "$tmp" || { echo "sync-version: jq failed on marketplace.json" >&2; rm -f "$tmp"; exit 1; }
mv "$tmp" .claude-plugin/marketplace.json
echo "version set to $V"
