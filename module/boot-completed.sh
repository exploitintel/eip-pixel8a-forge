#!/system/bin/sh
# KernelSU runs this after Android boot. It only dispatches a background start
# after the installed host, exact boot identity, and required kernel features
# have all passed read-only checks.
set -u
set -f

MODDIR=${0%/*}
BUSYBOX=/data/adb/ksu/bin/busybox
DOCKER_ROOT=/data/docker
HOSTCTL=$DOCKER_ROOT/bin/hostctl
KERNELCTL=$MODDIR/bin/kernelctl
KERNEL_CONFIG=/proc/config.gz
LOG_FILE=$DOCKER_ROOT/hostctl.log
IP=/system/bin/ip
SLEEP=/system/bin/sleep

bb() {
  "$BUSYBOX" "$@"
}

log_refusal() {
  printf 'boot-completed: %s\n' "$1" >>"$LOG_FILE" 2>/dev/null || true
}

autostart_ready() {
  [ -x "$HOSTCTL" ] && [ ! -L "$HOSTCTL" ] || return 1
  HOST_STATUS=$($HOSTCTL status 2>/dev/null) || return 1
  printf '%s\n' "$HOST_STATUS" | bb awk -F= '
    NR == 1 { if ($1 != "schema_version" || $2 != "2") exit 1; next }
    NR == 2 { if ($1 != "daemon" || NF != 2) exit 1; next }
    NR == 3 { if ($1 != "containers" || NF != 2) exit 1; next }
    NR == 4 { if ($1 != "autostart" || $2 != "on") exit 1; next }
    NR == 5 { if ($1 != "host_config" || $2 != "ready") exit 1; next }
    NR == 6 { if ($1 != "disk" || NF != 2) exit 1; next }
    NR == 7 { if ($1 != "mount" || NF != 2) exit 1; next }
    NR == 8 { if ($1 != "wifi_interface" || NF != 2) exit 1; next }
    NR == 9 { if ($1 != "bridge_routes" || NF != 2) exit 1; next }
    NR == 10 { if ($1 != "wifi_policy" || NF != 2) exit 1; next }
    NR == 11 { if ($1 != "ipv4_forwarding" || NF != 2) exit 1; next }
    NR == 12 { if ($1 != "api_firewall" || NF != 2) exit 1; next }
    { exit 1 }
    END { if (NR != 12) exit 1 }
  ' >/dev/null 2>&1
}

kernel_capabilities_ready() {
  [ -f "$KERNEL_CONFIG" ] && [ ! -L "$KERNEL_CONFIG" ] || return 1
  bb zcat "$KERNEL_CONFIG" 2>/dev/null | bb awk '
    $0 == "CONFIG_PID_NS=y" { pid++ }
    $0 == "CONFIG_IPC_NS=y" { ipc++ }
    $0 == "CONFIG_USER_NS=y" { user++ }
    $0 == "CONFIG_SYSVIPC=y" { sysvipc++ }
    $0 == "CONFIG_POSIX_MQUEUE=y" { mqueue++ }
    END {
      if (pid == 1 && ipc == 1 && user == 1 && sysvipc == 1 && mqueue == 1) exit 0
      exit 1
    }
  ' >/dev/null 2>&1
}

wait_for_wifi() {
  WAIT_TRY=0
  while [ "$WAIT_TRY" -lt 60 ]; do
    if "$IP" -4 addr show dev wlan0 2>/dev/null | bb awk '
         $1 == "inet" || $2 == "inet" { found = 1 }
         END { exit found ? 0 : 1 }
       ' >/dev/null 2>&1 &&
       "$IP" -4 route show table wlan0 2>/dev/null | bb awk '
         $1 == "default" { found = 1 }
         END { exit found ? 0 : 1 }
       ' >/dev/null 2>&1; then
      return 0
    fi
    WAIT_TRY=$((WAIT_TRY + 1))
    "$SLEEP" 2
  done
  return 1
}

[ -x "$BUSYBOX" ] || exit 0
[ -f "$MODDIR/module.prop" ] && [ ! -L "$MODDIR/module.prop" ] || exit 0
autostart_ready || exit 0
kernel_capabilities_ready || { log_refusal 'required Docker kernel capabilities are unavailable; use the module Action'; exit 0; }
[ -x "$KERNELCTL" ] && [ ! -L "$KERNELCTL" ] \
  || { log_refusal 'kernel controller is unavailable or unsafe'; exit 0; }
if ! "$KERNELCTL" status </dev/null >>"$LOG_FILE" 2>&1; then
  log_refusal 'exact build and boot identity check failed; use the module Action'
  exit 0
fi

(wait_for_wifi || { log_refusal 'wlan0 did not become ready after boot'; exit 0; }
 "$HOSTCTL" start) </dev/null >>"$LOG_FILE" 2>&1 &
exit 0
