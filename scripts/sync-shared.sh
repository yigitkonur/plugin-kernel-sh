#!/usr/bin/env bash
# sync-shared.sh -- copy shared/lib/* into every plugin that carries a file of the same name (plugins install only
# their own directory, so hook libraries are duplicated; scripts/validate.sh fails when the copies drift).
set -eu
cd "$(git rev-parse --show-toplevel)"
for f in shared/lib/*; do for p in plugins/*/lib; do [ -f "$p/${f##*/}" ] && cp "$f" "$p/${f##*/}" && echo "synced $p/${f##*/}"; done; done
