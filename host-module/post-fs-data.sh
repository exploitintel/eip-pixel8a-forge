#!/system/bin/sh
# Prepare Docker's ext4 data image in KernelSU's global mount namespace.
set -eu

MODDIR=${0%/*}
D=/data/docker
export PATH=/data/adb/ksu/bin:/system/bin:/system/xbin:$PATH
mkdir -p "$D/bin" "$D/config" "$D/lib" "$D/run" "$D/tmp"
exec >> "$D/host-init.log" 2>&1
echo "$(date '+%Y-%m-%dT%H:%M:%S%z') preparing Docker host"

cp -f "$MODDIR/bin/"* "$D/bin/"
chmod 0755 "$D/bin/"*
if [ ! -f "$D/config/host.conf" ]; then
  cp "$MODDIR/host.conf.default" "$D/config/host.conf"
fi

DISK_SIZE_BYTES=$(sed -n 's/^DISK_SIZE_BYTES=//p' "$D/config/host.conf")
case "$DISK_SIZE_BYTES" in
  ''|*[!0-9]*) echo "invalid Docker disk size" >&2; exit 1 ;;
esac

if [ ! -f "$D/disk.img" ]; then
  rm -f "$D/disk.img.new"
  truncate -s "$DISK_SIZE_BYTES" "$D/disk.img.new"
  mke2fs -q -t ext4 -O ^has_journal,^casefold "$D/disk.img.new"
  mv "$D/disk.img.new" "$D/disk.img"
fi

# Android already grants the kernel loop-device access to this data type.
chcon u:object_r:vold_data_file:s0 "$D/disk.img"
if ! grep -q " $D/lib ext4 " /proc/mounts; then
  LOOP=$(losetup -a | sed -n "\\#($D/disk.img)#s/:.*//p" | head -n 1)
  if [ -z "$LOOP" ]; then
    LOOP=$(losetup -f)
    losetup "$LOOP" "$D/disk.img"
  fi
  mount -t ext4 -o noatime,nodev "$LOOP" "$D/lib"
fi
echo "$(date '+%Y-%m-%dT%H:%M:%S%z') Docker host prepared"
