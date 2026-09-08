#!/system/bin/sh
# Give BuildKit's direct runc invocation an Android-writable state directory.
set -eu

exec /data/docker/bin/runc --root /dev/docker/buildkit-runc "$@"
