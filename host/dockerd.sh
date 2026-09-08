#!/system/bin/sh
# Start Docker after the host module has mounted its ext4 data image.
set -eu

D=/data/docker
export PATH="$D/bin:/system/bin:/system/xbin:$PATH"
export TMPDIR=$D/tmp
export SSL_CERT_DIR=/apex/com.android.conscrypt/cacerts

if [ "$#" -ne 1 ] || [ "$1" != --runtime-only ]; then
  echo "usage: $0 --runtime-only" >&2
  exit 2
fi

grep -q " $D/lib ext4 " /proc/mounts || {
  echo "Docker data image is not mounted at $D/lib" >&2
  exit 1
}

mkdir -p "$D/run" "$D/exec" "$D/tmp" /sys/fs/cgroup/docker
echo +memory > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null || true

rm -rf "$D/lib/.etc/work"
mkdir -p "$D/lib/.etc/upper" "$D/lib/.etc/work"
printf 'nameserver 8.8.8.8\nnameserver 1.1.1.1\n' \
  > "$D/lib/.etc/upper/resolv.conf"

export DOCKER_BUILDKIT_RUNC_COMMAND=$D/bin/buildkit-runc.sh
exec "$D/bin/privns" "$D/lib/.etc/upper" "$D/lib/.etc/work" \
  "$D/bin/dockerd" \
  --data-root "$D/lib" \
  --exec-root "$D/exec" \
  --pidfile "$D/run/docker.pid" \
  --host "unix://$D/run/docker.sock" \
  --storage-driver overlay2 \
  --bip 172.17.0.1/24 \
  --default-address-pool base=172.17.0.0/16,size=24 \
  --cgroup-parent docker \
  --default-ulimit nofile=65536:65536 \
  --dns 8.8.8.8 --dns 1.1.1.1 \
  --group 2000 \
  --log-level info
