#!/system/bin/sh
# Install the two Android policy-routing rules needed by Docker bridge traffic.
set -eu

MODDIR=${0%/*}
D=/data/docker
export PATH="$D/bin:/system/bin:/system/xbin:$PATH"
IP=/system/bin/ip

# The early boot hook may run before loop mounts are usable on this device.
# Repeat the idempotent preparation at KernelSU's later service stage.
if ! grep -q " $D/lib ext4 " /proc/mounts; then
  sh "$MODDIR/post-fs-data.sh"
fi

echo 1 > /proc/sys/net/ipv4/ip_forward

"$IP" rule show | grep -q '9990:.*to 172.17.0.0/16 lookup main' || \
  "$IP" rule add to 172.17.0.0/16 lookup main pref 9990

exec >> "$D/host-service.log" 2>&1
# Android allocates the numeric wlan0 table dynamically. Wait until the named
# table has a default route, then bind container egress to it.
ATTEMPT=0
while ! "$IP" route show table wlan0 2>/dev/null | grep -q '^default '; do
  ATTEMPT=$((ATTEMPT + 1))
  if [ "$ATTEMPT" -ge 30 ]; then
    echo "wlan0 route was not ready; Docker remains parked"
    exit 0
  fi
  sleep 2
done
"$IP" rule show | grep -q '9991:.*from 172.17.0.0/16 lookup wlan0' || \
  "$IP" rule add from 172.17.0.0/16 lookup wlan0 pref 9991

if grep -q '^AUTOSTART=1$' "$D/config/host.conf" && \
   [ ! -S "$D/run/docker.sock" ]; then
  nohup sh "$D/bin/dockerd.sh" --runtime-only \
    >> "$D/dockerd.log" 2>&1 &
fi
