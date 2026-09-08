#!/system/bin/sh
# KernelSU manager Action UI for the bounded host and active-slot kernel
# lifecycle. It performs one explicitly selected operation per invocation.
set -u
set -f

PROGRAM=action.sh
BUSYBOX=/data/adb/ksu/bin/busybox
GETEVENT=/system/bin/getevent
KEY_WAIT_SLICE_SECONDS=1
MENU_WAIT_ATTEMPTS=15
CONFIRM_WAIT_ATTEMPTS=10
ATTENTION_STATUS=3
MODDIR=${0%/*}
HOSTCTL=$MODDIR/bin/hostctl
KERNELCTL=$MODDIR/bin/kernelctl
MENU_COUNT=10

fail() {
  printf '%s: %s\n' "$PROGRAM" "$1" >&2
  exit "${2:-1}"
}

bb() {
  "$BUSYBOX" "$@"
}

require_helper() {
  [ -f "$1" ] && [ ! -L "$1" ] && [ -x "$1" ] \
    || fail "required helper is unavailable or unsafe: $1"
}

# One getevent invocation can consume a release or sync event instead of the
# next key press. Keep each read short and cap the number of reads so both the
# menu and confirmation waits have hard upper bounds.
wait_volume_key() {
  WAIT_LIMIT=$1
  WAIT_COUNT=0
  while [ "$WAIT_COUNT" -lt "$WAIT_LIMIT" ]; do
    WAIT_COUNT=$((WAIT_COUNT + 1))
    EVENT_OUTPUT=$(bb timeout "$KEY_WAIT_SLICE_SECONDS" "$GETEVENT" -qlc 1 2>/dev/null || true)
    # The single-quoted program is passed to awk; shell expansion is not intended.
    # shellcheck disable=SC2016
    KEY_VALUE=$(printf '%s\n' "$EVENT_OUTPUT" | bb awk '
      function pressed(value) { return value == "DOWN" || value == "00000001" || value == "1" }
      {
        if (!pressed($NF)) next
        up = 0
        down = 0
        for (field = 1; field <= NF; field++) {
          if ($field == "KEY_VOLUMEUP" || $field == "0073" || $field == "115") up = 1
          if ($field == "KEY_VOLUMEDOWN" || $field == "0072" || $field == "114") down = 1
        }
        if (up && !down) { print "up"; exit }
        if (down && !up) { print "down"; exit }
      }
    ' 2>/dev/null || true)
    case "$KEY_VALUE" in
      up|down)
        VOLUME_KEY=$KEY_VALUE
        return 0
        ;;
    esac
  done
  VOLUME_KEY=timeout
  return 1
}

report_status_code() {
  STATUS_LABEL=$1
  STATUS_CODE=$2
  case "$STATUS_CODE" in
    0) return 0 ;;
    "$ATTENTION_STATUS")
      printf '%s\n' "ATTENTION: $STATUS_LABEL reported recovery-required status 3; state was preserved." >&2
      return "$ATTENTION_STATUS"
      ;;
    *)
      printf '%s\n' "$STATUS_LABEL reported status $STATUS_CODE; review the status above before selecting an action." >&2
      return "$STATUS_CODE"
      ;;
  esac
}

show_initial_status() {
  INITIAL_ATTENTION=0
  printf '%s\n' '=== Forge host status ==='
  "$HOSTCTL" status
  HOST_STATUS=$?
  report_status_code hostctl "$HOST_STATUS" || {
    [ "$?" -eq "$ATTENTION_STATUS" ] && INITIAL_ATTENTION=1
  }

  printf '%s\n' '=== Kernel status ==='
  "$KERNELCTL" status
  KERNEL_STATUS=$?
  report_status_code kernelctl "$KERNEL_STATUS" || {
    [ "$?" -eq "$ATTENTION_STATUS" ] && INITIAL_ATTENTION=1
  }

  [ "$INITIAL_ATTENTION" -eq 0 ] || exit "$ATTENTION_STATUS"
}

menu_label() {
  case "$1" in
    0) printf '%s' 'Start Forge host' ;;
    1) printf '%s' 'Stop Forge host' ;;
    2) printf '%s' 'Initialize 8 GiB Docker disk' ;;
    3) printf '%s' 'Initialize 16 GiB Docker disk' ;;
    4) printf '%s' 'Initialize 32 GiB Docker disk' ;;
    5) printf '%s' 'Enable autostart' ;;
    6) printf '%s' 'Disable autostart' ;;
    7) printf '%s' 'Install authenticated kernel' ;;
    8) printf '%s' 'Restore authenticated kernel backup' ;;
    9) printf '%s' 'Exit' ;;
    *) return 1 ;;
  esac
}

select_action() {
  printf '%s\n' \
    '=== Action menu ===' \
    'Volume Down cycles. Volume Up selects. The menu times out after 15 seconds.' \
    '  Start Forge host' \
    '  Stop Forge host' \
    '  Initialize Docker disk: 8 GiB / 16 GiB / 32 GiB' \
    '  Enable / disable autostart' \
    '  Install / restore authenticated kernel' \
    '  Exit'
  MENU_INDEX=0
  printf 'Selected: '
  menu_label "$MENU_INDEX"
  printf '\n'
  while :; do
    if ! wait_volume_key "$MENU_WAIT_ATTEMPTS"; then
      printf '%s\n' 'Action menu timed out; nothing changed.'
      SELECTED_ACTION=9
      return 1
    fi
    case "$VOLUME_KEY" in
      down)
        MENU_INDEX=$(((MENU_INDEX + 1) % MENU_COUNT))
        printf 'Selected: '
        menu_label "$MENU_INDEX"
        printf '\n'
        ;;
      up)
        SELECTED_ACTION=$MENU_INDEX
        return 0
        ;;
    esac
  done
}

confirm_action() {
  CONFIRM_LABEL=$1
  printf '%s\n' \
    "Confirm: $CONFIRM_LABEL" \
    'Press Volume Up to confirm. Volume Down cancels. Confirmation times out after 10 seconds.'
  if ! wait_volume_key "$CONFIRM_WAIT_ATTEMPTS"; then
    printf '%s\n' 'Confirmation timed out; nothing changed.'
    return 1
  fi
  if [ "$VOLUME_KEY" != up ]; then
    printf '%s\n' 'Action canceled; nothing changed.'
    return 1
  fi
  return 0
}

run_checked() {
  "$@"
  COMMAND_STATUS=$?
  if [ "$COMMAND_STATUS" -eq "$ATTENTION_STATUS" ]; then
    printf '%s\n' 'RECOVERY ATTENTION: status 3 reported. Do not reboot until the printed recovery guidance is resolved.' >&2
  elif [ "$COMMAND_STATUS" -ne 0 ]; then
    printf 'Action failed with status %s; state was preserved by the lifecycle helper.\n' "$COMMAND_STATUS" >&2
  fi
  return "$COMMAND_STATUS"
}

read_kernel_context() {
  KERNEL_OUTPUT=$("$KERNELCTL" status 2>&1)
  KERNEL_STATUS=$?
  printf '%s\n' "$KERNEL_OUTPUT"
  if [ "$KERNEL_STATUS" -eq "$ATTENTION_STATUS" ]; then
    printf '%s\n' 'RECOVERY ATTENTION: kernel status is 3. No kernel command was issued.' >&2
    return "$ATTENTION_STATUS"
  fi
  [ "$KERNEL_STATUS" -eq 0 ] || {
    printf '%s\n' 'Kernel status failed; no kernel command was issued.' >&2
    return "$KERNEL_STATUS"
  }
  TAB=$(printf '\t')
  # The single-quoted program is passed to awk; shell expansion is not intended.
  # shellcheck disable=SC2016
  KERNEL_FIELDS=$(printf '%s\n' "$KERNEL_OUTPUT" | bb awk -F = -v tab="$TAB" '
    NR == 1 { if (NF != 2 || $1 != "KERNELCTL_VERSION" || $2 != "1") exit 1; next }
    NR == 2 {
      if (NF != 2 || $1 != "build_id" || $2 !~ /^[A-Z0-9]+([.][A-Z0-9]+)+$/) exit 1
      build = $2; next
    }
    NR == 3 {
      if (NF != 2 || $1 != "slot_suffix" || ($2 != "_a" && $2 != "_b")) exit 1
      suffix = $2; next
    }
    NR == 4 {
      if (NF != 2 || $1 != "boot_state" || $2 !~ /^[a-z][a-z0-9-]*$/) exit 1
      next
    }
    NR == 5 {
      if (NF != 2 || $1 != "staged_image" || ($2 != "missing" && $2 != "invalid" && $2 != "ready")) exit 1
      next
    }
    { exit 1 }
    END {
      if (NR != 5 || build == "" || suffix == "") exit 1
      print build tab suffix
    }
  ') || {
    printf '%s\n' 'Kernel status output is malformed; no kernel command was issued.' >&2
    return 1
  }
  OLD_IFS=$IFS
  IFS=$TAB
  # Word splitting is intentional for the two-field validated handoff.
  # shellcheck disable=SC2086
  set -- $KERNEL_FIELDS
  IFS=$OLD_IFS
  [ "$#" -eq 2 ] || {
    printf '%s\n' 'Kernel status selection is malformed; no kernel command was issued.' >&2
    return 1
  }
  KERNEL_BUILD_ID=$1
  KERNEL_SLOT_SUFFIX=$2
  return 0
}

[ -x "$BUSYBOX" ] || fail 'KernelSU BusyBox is unavailable'
[ "$(bb id -u 2>/dev/null || true)" = 0 ] || fail 'root is required' 2
[ -x "$GETEVENT" ] || fail 'Android getevent is unavailable'
require_helper "$HOSTCTL"
require_helper "$KERNELCTL"

show_initial_status
select_action || exit 0

case "$SELECTED_ACTION" in
  0)
    read_kernel_context
    CONTEXT_STATUS=$?
    [ "$CONTEXT_STATUS" -eq 0 ] || exit "$CONTEXT_STATUS"
    run_checked "$HOSTCTL" start
    exit $?
    ;;
  1)
    confirm_action 'stop the Forge host' || exit 0
    run_checked "$HOSTCTL" stop
    exit $?
    ;;
  2|3|4)
    case "$SELECTED_ACTION" in
      2) DISK_GIB=8; DISK_BYTES=8589934592 ;;
      3) DISK_GIB=16; DISK_BYTES=17179869184 ;;
      4) DISK_GIB=32; DISK_BYTES=34359738368 ;;
    esac
    confirm_action "initialize the Docker disk at $DISK_GIB GiB" || exit 0
    run_checked "$HOSTCTL" disk-init --size-bytes "$DISK_BYTES"
    exit $?
    ;;
  5|6)
    if [ "$SELECTED_ACTION" -eq 5 ]; then
      AUTOSTART_VALUE=on
    else
      AUTOSTART_VALUE=off
    fi
    confirm_action "set autostart $AUTOSTART_VALUE" || exit 0
    run_checked "$HOSTCTL" autostart "$AUTOSTART_VALUE"
    exit $?
    ;;
  7|8)
    read_kernel_context
    CONTEXT_STATUS=$?
    [ "$CONTEXT_STATUS" -eq 0 ] || exit "$CONTEXT_STATUS"
    printf 'Recovery fallback: fastboot flash boot%s <exact-known-good-boot.img>\n' "$KERNEL_SLOT_SUFFIX"
    if [ "$SELECTED_ACTION" -eq 7 ]; then
      KERNEL_VERB=install
      KERNEL_TOKEN="INSTALL:$KERNEL_BUILD_ID:$KERNEL_SLOT_SUFFIX"
      KERNEL_LABEL="write the authenticated $KERNEL_BUILD_ID kernel to active slot $KERNEL_SLOT_SUFFIX"
    else
      KERNEL_VERB=restore
      KERNEL_TOKEN="RESTORE:$KERNEL_BUILD_ID:$KERNEL_SLOT_SUFFIX"
      KERNEL_LABEL="restore the authenticated $KERNEL_BUILD_ID backup to active slot $KERNEL_SLOT_SUFFIX"
    fi
    confirm_action "$KERNEL_LABEL" || exit 0
    run_checked "$KERNELCTL" "$KERNEL_VERB" "$KERNEL_TOKEN"
    exit $?
    ;;
  9) printf '%s\n' 'No action selected.'; exit 0 ;;
  *) fail 'internal menu selection is invalid' ;;
esac
