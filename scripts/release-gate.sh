#!/bin/sh
# release-gate.sh -- run by the release workflow on the bumped tree; a non-zero exit stops the release.
exec bash "$(dirname "$0")/validate.sh"
