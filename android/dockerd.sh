#!/system/bin/sh
# Native Docker on a prepared Android host. This launcher never creates or
# mounts storage and never changes routing or firewall policy.
# Start by hand:  su -c 'sh /data/docker/dockerd.sh --runtime-only'
# Client use:     su -c 'DOCKER_HOST=unix:///data/docker/run/docker.sock /data/docker/bin/docker ps'
set -eu

D=/data/docker
# Public lifecycle-controller capability marker. Controllers may invoke
# --runtime-only only after boot preparation has established the host state.
HOSTCTL_RUNTIME_ONLY_CONTRACT=1
export PATH="$D/bin:/system/bin:/system/xbin:$PATH"
export TMPDIR=$D/tmp
# Android's CA store lives in the conscrypt apex; Go's TLS needs to be told.
export SSL_CERT_DIR=/apex/com.android.conscrypt/cacerts
HOST_CONFIG=$D/config/host.conf

if [ "$#" -ne 1 ] || [ "$1" != --runtime-only ]; then
  echo "usage: $0 --runtime-only" >> "$D/dockerd.log"
  exit 2
fi

# Bind Docker's default bridge and all automatically allocated user-defined
# bridge networks to the one pool already validated by hostctl. Subdivide the
# configured private base into 256 networks where possible, and never use a
# subnet longer than /28.
NETWORK_CONFIG=$(awk -F= '
  NR == 1 && $0 == "HOST_CONFIG_VERSION=2" { version=1; next }
  NR == 2 && ($0 == "AUTOSTART=0" || $0 == "AUTOSTART=1") { autostart=1; next }
  NR == 3 && $1 == "DISK_SIZE_BYTES" && $2 ~ /^(0|[1-9][0-9]*)$/ { disk=1; next }
  NR == 4 && $1 == "BRIDGE_POOL_CIDR" && NF == 2 { cidr=$2; next }
  NR == 5 && ($0 == "EXT4_FEATURES=^casefold" || $0 == "EXT4_FEATURES=^has_journal,^casefold") { features=1; next }
  NR == 6 && $0 == "MOUNT_OPTIONS=noatime,nodev" { options=1; next }
  { bad=1 }
  function ip(value, a, b, c, d) {
    a=int(value / 16777216); value-=a * 16777216
    b=int(value / 65536); value-=b * 65536
    c=int(value / 256); d=value-c * 256
    return a "." b "." c "." d
  }
  END {
    if (bad || NR != 6 || !version || !autostart || !disk || !features || !options ||
        split(cidr, pair, "/") != 2 || pair[2] == "" || pair[2] ~ /[^0-9]/) exit 1
    prefix=pair[2] + 0
    if (pair[2] != prefix "" || prefix < 12 || prefix > 24 || split(pair[1], octet, ".") != 4) exit 1
    value=0
    for (i=1; i<=4; i++) {
      if (octet[i] == "" || octet[i] ~ /[^0-9]/ ||
          (length(octet[i]) > 1 && substr(octet[i], 1, 1) == "0") || octet[i] > 255) exit 1
      value=value * 256 + octet[i]
    }
    block=2 ^ (32-prefix)
    if (value % block != 0) exit 1
    end=value + block - 1
    private=((value >= 167772160 && end <= 184549375) ||
             (value >= 2886729728 && end <= 2887778303) ||
             (value >= 3232235520 && end <= 3232301055))
    if (!private) exit 1
    subnet=prefix + 8
    if (subnet > 28) subnet=28
    print cidr "|" ip(value + 1) "/" subnet "|" subnet
  }
' "$HOST_CONFIG" 2>/dev/null) || {
  echo "runtime-only start requires the exact v2 host network configuration" >> "$D/dockerd.log"
  exit 1
}
OLD_IFS=$IFS
IFS='|'
read -r BRIDGE_POOL_CIDR BRIDGE_BIP BRIDGE_SUBNET_PREFIX <<EOF
$NETWORK_CONFIG
EOF
IFS=$OLD_IFS
[ -n "$BRIDGE_POOL_CIDR" ] && [ -n "$BRIDGE_BIP" ] && [ -n "$BRIDGE_SUBNET_PREFIX" ] || {
  echo "runtime-only start could not derive the Docker bridge pool" >> "$D/dockerd.log"
  exit 1
}

# Lifecycle-controller starts reuse the current boot's prepared host state.
# The host controller owns explicit disk initialization, mounting, IP
# forwarding, and Wi-Fi routing.
awk -v target="$D/lib" '$2 == target && $3 == "ext4" { found=1 } END { exit found ? 0 : 1 }' /proc/mounts || {
  echo "runtime-only start requires the existing ext4 data mount: $D/lib" >> "$D/dockerd.log"
  exit 1
}
mkdir -p "$D/run" "$D/exec" "$D/tmp"

# Embedded BuildKit launches runc directly, outside containerd, so dockerd's
# --exec-root does not relocate its state. The wrapper gives only that runc
# path an Android-writable tmpfs root; normal container runtimes are unchanged.
BUILDKIT_RUNC=$D/bin/buildkit-runc.sh
if [ ! -x "$BUILDKIT_RUNC" ]; then
  echo "missing executable BuildKit runc wrapper: $BUILDKIT_RUNC" >> $D/dockerd.log
  exit 1
fi
export DOCKER_BUILDKIT_RUNC_COMMAND=$BUILDKIT_RUNC

# Docker puts its containers under this cgroup; hand it the memory controller.
mkdir -p /sys/fs/cgroup/docker 2>/dev/null
echo "+memory" > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null

# Android has no /etc/resolv.conf and /etc is read-only. privns (tiny static helper) puts the
# daemon in a private mount namespace with an overlay on /system/etc that adds one. Containers
# inherit it; the rest of the system never sees it.
rm -rf "$D/lib/.etc/work"
mkdir -p "$D/lib/.etc/upper" "$D/lib/.etc/work"
printf 'nameserver 8.8.8.8\nnameserver 1.1.1.1\n' > "$D/lib/.etc/upper/resolv.conf"

exec $D/bin/privns $D/lib/.etc/upper $D/lib/.etc/work $D/bin/dockerd \
  --data-root $D/lib \
  --exec-root $D/exec \
  --pidfile $D/run/docker.pid \
  --host unix://$D/run/docker.sock \
  --storage-driver overlay2 \
  --bip "$BRIDGE_BIP" \
  --default-address-pool "base=$BRIDGE_POOL_CIDR,size=$BRIDGE_SUBNET_PREFIX" \
  --cgroup-parent docker \
  --default-ulimit nofile=65536:65536 \
  --dns 8.8.8.8 --dns 1.1.1.1 \
  --group 2000 \
  --log-level info \
  >> $D/dockerd.log 2>&1
