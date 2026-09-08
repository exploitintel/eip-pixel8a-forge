#!/system/bin/sh
# Moby's embedded BuildKit invokes runc directly and does not inherit
# dockerd's --exec-root. Keep only that executor state on Android's writable
# tmpfs instead of letting runc fall back to the unavailable /run/runc.
set -eu

RUNC=/data/docker/bin/runc
STATE_ROOT=/dev/docker/buildkit-runc

exec "$RUNC" --root "$STATE_ROOT" "$@"
