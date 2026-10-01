#!/bin/bash
# deploy.sh - thin shim kept for existing call sites; delegates to mt.
#
# Usage: deploy.sh <image> <src> <guest-path> [offset-bytes]
#   (mt form: mt <image> [--offset <bytes>] put <src> <guest-path>)
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
[ $# -ge 3 ] || { echo "usage: deploy.sh <image> <src> <guest-path> [offset-bytes]" >&2; exit 1; }
IMG=$1; SRC=$2; DEST=$3; OFFSET=${4:-}
if [ -n "$OFFSET" ]; then
    exec "$HERE/mt" "$IMG" --offset "$OFFSET" put "$SRC" "$DEST"
else
    exec "$HERE/mt" "$IMG" put "$SRC" "$DEST"
fi
