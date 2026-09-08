#!/system/bin/sh
# KernelSU always removes the module directory after this hook, even when the
# hook returns nonzero. Publish and verify a standalone recovery kit before
# making any kernel or host cleanup decision.
set -u
set -f

PROGRAM=uninstall.sh
ATTENTION_STATUS=3
BUSYBOX=/data/adb/ksu/bin/busybox
DOCKER_ROOT=/data/docker
ACTIVE_LINK=$DOCKER_ROOT/bin
RELEASES=$DOCKER_ROOT/releases
DEACTIVATION_RECORD=$RELEASES/.deactivation
RECOVERY_ROOT=$DOCKER_ROOT/recovery
MODDIR=${0%/*}
MODULE_PROP=$MODDIR/module.prop
KERNELCTL=$MODDIR/bin/kernelctl
PREFLIGHT=$MODDIR/bin/install-preflight
RELEASE_TRANSACTION=$MODDIR/bin/release-transaction
SWAP_BOOT_KERNEL=$MODDIR/bin/swap-boot-kernel
INPUTS=$MODDIR/installer-inputs.tsv
RECOVERY_READY=0
RECOVERY_DIR=
RECOVERY_KERNELCTL=
RECOVERY_STAGING=
export LC_ALL=C

bb() {
  "$BUSYBOX" "$@"
}

path_exists() {
  [ -e "$1" ] || [ -L "$1" ]
}

cleanup_staging() {
  [ -n "$RECOVERY_STAGING" ] || return 0
  case "$RECOVERY_STAGING" in
    "$RECOVERY_ROOT"/.*.staging."$$") ;;
    *) RECOVERY_STAGING=; return 1 ;;
  esac
  if [ -x "$BUSYBOX" ] && [ -d "$RECOVERY_STAGING" ] && [ ! -L "$RECOVERY_STAGING" ]; then
    if [ -d "$RECOVERY_STAGING/bin" ] && [ ! -L "$RECOVERY_STAGING/bin" ]; then
      for CLEANUP_FILE in \
        "$RECOVERY_STAGING/bin/kernelctl" \
        "$RECOVERY_STAGING/bin/install-preflight" \
        "$RECOVERY_STAGING/bin/swap-boot-kernel"
      do
        path_exists "$CLEANUP_FILE" && bb rm -f "$CLEANUP_FILE" 2>/dev/null || true
      done
      bb rmdir "$RECOVERY_STAGING/bin" 2>/dev/null || true
    fi
    for CLEANUP_FILE in \
      "$RECOVERY_STAGING/installer-inputs.tsv" \
      "$RECOVERY_STAGING/recovery-manifest.tsv"
    do
      path_exists "$CLEANUP_FILE" && bb rm -f "$CLEANUP_FILE" 2>/dev/null || true
    done
    bb rmdir "$RECOVERY_STAGING" 2>/dev/null || true
  fi
  RECOVERY_STAGING=
}

fail() {
  FAIL_MESSAGE=$1
  FAIL_STATUS=${2:-1}
  cleanup_staging || true
  printf '%s: %s\n' "$PROGRAM" "$FAIL_MESSAGE" >&2
  if [ "$RECOVERY_READY" -eq 1 ]; then
    printf '%s: standalone recovery kit preserved at %s\n' "$PROGRAM" "$RECOVERY_DIR" >&2
  else
    printf '%s\n' "$PROGRAM: standalone recovery kit could not be proven; do not reboot until the module is reinstalled or fastboot recovery is ready" >&2
  fi
  printf '%s\n' \
    "$PROGRAM: KernelSU will still delete this module directory after the hook returns" \
    "$PROGRAM: host data, releases, disk, staged kernels, and boot backups were not deleted" >&2
  exit "$FAIL_STATUS"
}

valid_sha256() {
  [ "${#1}" -eq 64 ] || return 1
  case "$1" in *[!0-9a-f]*) return 1 ;; esac
}

canonical_unsigned() {
  case "$1" in 0|[1-9]*) ;; *) return 1 ;; esac
  case "$1" in *[!0-9]*) return 1 ;; esac
}

read_identity() {
  IDENTITY_PATH=$1
  IDENTITY_SIZE=$(bb stat -c '%s' "$IDENTITY_PATH" 2>/dev/null) || return 1
  canonical_unsigned "$IDENTITY_SIZE" || return 1
  IDENTITY_LINE=$(bb sha256sum "$IDENTITY_PATH" 2>/dev/null) || return 1
  IDENTITY_OLD_IFS=$IFS
  IFS=' '
  # shellcheck disable=SC2086
  set -- $IDENTITY_LINE
  IFS=$IDENTITY_OLD_IFS
  [ "$#" -eq 2 ] && [ "$2" = "$IDENTITY_PATH" ] && valid_sha256 "$1" || return 1
  IDENTITY_HASH=$1
}

identity_matches() {
  MATCH_PATH=$1
  MATCH_SIZE=$2
  MATCH_HASH=$3
  [ -f "$MATCH_PATH" ] && [ ! -L "$MATCH_PATH" ] || return 1
  read_identity "$MATCH_PATH" || return 1
  [ "$IDENTITY_SIZE" = "$MATCH_SIZE" ] && [ "$IDENTITY_HASH" = "$MATCH_HASH" ]
}

load_source_identities() {
  for SOURCE_EXECUTABLE in "$KERNELCTL" "$PREFLIGHT" "$RELEASE_TRANSACTION" "$SWAP_BOOT_KERNEL"
  do
    [ -f "$SOURCE_EXECUTABLE" ] && [ ! -L "$SOURCE_EXECUTABLE" ] && [ -x "$SOURCE_EXECUTABLE" ] \
      || fail "required recovery helper is unavailable or unsafe: $SOURCE_EXECUTABLE"
  done
  [ -f "$INPUTS" ] && [ ! -L "$INPUTS" ] || fail 'installer inputs are unavailable or unsafe'

  read_identity "$KERNELCTL" || fail 'cannot identify packaged kernelctl'
  KERNELCTL_SIZE=$IDENTITY_SIZE; KERNELCTL_HASH=$IDENTITY_HASH
  read_identity "$PREFLIGHT" || fail 'cannot identify packaged install-preflight'
  PREFLIGHT_SIZE=$IDENTITY_SIZE; PREFLIGHT_HASH=$IDENTITY_HASH
  read_identity "$RELEASE_TRANSACTION" || fail 'cannot identify packaged release transaction'
  RELEASE_TRANSACTION_SIZE=$IDENTITY_SIZE; RELEASE_TRANSACTION_HASH=$IDENTITY_HASH
  read_identity "$SWAP_BOOT_KERNEL" || fail 'cannot identify packaged swap-boot-kernel'
  SWAP_SIZE=$IDENTITY_SIZE; SWAP_HASH=$IDENTITY_HASH
  read_identity "$INPUTS" || fail 'cannot identify packaged installer inputs'
  INPUTS_SIZE=$IDENTITY_SIZE; INPUTS_HASH=$IDENTITY_HASH

  RECOVERY_MANIFEST=$(printf '%s\n%s\t%s\t%s\t%s\n%s\t%s\t%s\t%s\n%s\t%s\t%s\t%s\n%s\t%s\t%s\t%s\n%s\t%s\t%s\t%s' \
    'RECOVERY_KIT_VERSION=1' \
    'KSU' "$RECOVERY_KSU_VERSION" "$RECOVERY_KSU_VERSION_CODE" lkm \
    'bin/install-preflight' "$PREFLIGHT_SIZE" "$PREFLIGHT_HASH" 0755 \
    'bin/kernelctl' "$KERNELCTL_SIZE" "$KERNELCTL_HASH" 0755 \
    'bin/swap-boot-kernel' "$SWAP_SIZE" "$SWAP_HASH" 0755 \
    'installer-inputs.tsv' "$INPUTS_SIZE" "$INPUTS_HASH" 0600)
}

read_recovery_environment() {
  [ "${KSU:-}" = true ] || fail 'KernelSU script identity is unavailable for recovery'
  RECOVERY_KSU_VERSION=${KSU_VER:-}
  case "$RECOVERY_KSU_VERSION" in v*) RECOVERY_KSU_VERSION=${RECOVERY_KSU_VERSION#v} ;; esac
  case "$RECOVERY_KSU_VERSION" in ''|*[!0-9.]*) fail 'KernelSU version is unsafe for recovery' ;; esac
  RECOVERY_KSU_VERSION_CODE=${KSU_VER_CODE:-}
  case "$RECOVERY_KSU_VERSION_CODE" in ''|*[!0-9]*) fail 'KernelSU version code is unsafe for recovery' ;; esac
  [ "${KSU_RUNTIME_MODE:-}" = lkm ] || fail 'KernelSU runtime mode is unsafe for recovery'
  RECOVERY_COMMAND_ENV="KSU=true KSU_VER=$RECOVERY_KSU_VERSION KSU_VER_CODE=$RECOVERY_KSU_VERSION_CODE KSU_RUNTIME_MODE=lkm"
}

source_identities_unchanged() {
  identity_matches "$KERNELCTL" "$KERNELCTL_SIZE" "$KERNELCTL_HASH" &&
    identity_matches "$PREFLIGHT" "$PREFLIGHT_SIZE" "$PREFLIGHT_HASH" &&
    identity_matches "$RELEASE_TRANSACTION" "$RELEASE_TRANSACTION_SIZE" "$RELEASE_TRANSACTION_HASH" &&
    identity_matches "$SWAP_BOOT_KERNEL" "$SWAP_SIZE" "$SWAP_HASH" &&
    identity_matches "$INPUTS" "$INPUTS_SIZE" "$INPUTS_HASH"
}

read_module_version() {
  [ -f "$MODULE_PROP" ] && [ ! -L "$MODULE_PROP" ] || fail 'module metadata is unavailable or unsafe'
  # shellcheck disable=SC2016
  MODULE_VERSION=$(bb awk -F = '
    NR == 1 { if (NF != 2 || $1 != "id" || $2 != "eip-pixel8a-forge") exit 1; next }
    NR == 2 { if ($0 !~ /^name=[ -~]+$/) exit 1; next }
    NR == 3 {
      if (NF != 2 || $1 != "version" || $2 !~ /^[A-Za-z0-9][A-Za-z0-9._+-]*$/) exit 1
      version = $2; next
    }
    NR == 4 { if (NF != 2 || $1 != "versionCode" || $2 !~ /^[1-9][0-9]*$/) exit 1; next }
    NR == 5 { if ($0 !~ /^author=[ -~]+$/) exit 1; next }
    NR == 6 { if ($0 !~ /^description=[ -~]+$/) exit 1; next }
    { exit 1 }
    END { if (NR != 6 || version == "") exit 1; print version }
  ' "$MODULE_PROP" 2>/dev/null) || fail 'module metadata is malformed'
  case "$MODULE_VERSION" in ''|none|.*|*/*|*[!A-Za-z0-9._+-]*) fail 'module version is unsafe for recovery publication' ;; esac
  [ "${#MODULE_VERSION}" -le 64 ] || fail 'module version is too long for recovery publication'
}

require_owned_mode() {
  [ "$(bb stat -c '%u:%g:%a' "$1" 2>/dev/null || true)" = "$2" ]
}

pending_deactivation_matches() {
  PENDING_EXPECTED=$1
  [ -f "$DEACTIVATION_RECORD" ] && [ ! -L "$DEACTIVATION_RECORD" ] || return 1
  require_owned_mode "$DEACTIVATION_RECORD" 0:0:600 || return 1
  {
    IFS= read -r PENDING_LINE_1 || return 1
    IFS= read -r PENDING_LINE_2 || return 1
    if IFS= read -r PENDING_LINE_3; then
      return 1
    fi
  } < "$DEACTIVATION_RECORD"
  [ "$PENDING_LINE_1" = 'DEACTIVATION_RECORD_VERSION=1' ] &&
    [ "$PENDING_LINE_2" = "EXPECTED=$PENDING_EXPECTED" ]
}

validate_recovery_kit() {
  VALIDATE_KIT=$1
  [ -d "$VALIDATE_KIT" ] && [ ! -L "$VALIDATE_KIT" ] || return 1
  require_owned_mode "$VALIDATE_KIT" 0:0:700 || return 1
  [ -d "$VALIDATE_KIT/bin" ] && [ ! -L "$VALIDATE_KIT/bin" ] || return 1
  require_owned_mode "$VALIDATE_KIT/bin" 0:0:700 || return 1
  KIT_ROOT_CONTENTS=$(bb ls -A "$VALIDATE_KIT" 2>/dev/null) || return 1
  [ "$KIT_ROOT_CONTENTS" = "$(printf '%s\n%s\n%s' bin installer-inputs.tsv recovery-manifest.tsv)" ] || return 1
  KIT_BIN_CONTENTS=$(bb ls -A "$VALIDATE_KIT/bin" 2>/dev/null) || return 1
  [ "$KIT_BIN_CONTENTS" = "$(printf '%s\n%s\n%s' install-preflight kernelctl swap-boot-kernel)" ] || return 1

  identity_matches "$VALIDATE_KIT/bin/kernelctl" "$KERNELCTL_SIZE" "$KERNELCTL_HASH" || return 1
  require_owned_mode "$VALIDATE_KIT/bin/kernelctl" 0:0:755 || return 1
  identity_matches "$VALIDATE_KIT/bin/install-preflight" "$PREFLIGHT_SIZE" "$PREFLIGHT_HASH" || return 1
  require_owned_mode "$VALIDATE_KIT/bin/install-preflight" 0:0:755 || return 1
  identity_matches "$VALIDATE_KIT/bin/swap-boot-kernel" "$SWAP_SIZE" "$SWAP_HASH" || return 1
  require_owned_mode "$VALIDATE_KIT/bin/swap-boot-kernel" 0:0:755 || return 1
  identity_matches "$VALIDATE_KIT/installer-inputs.tsv" "$INPUTS_SIZE" "$INPUTS_HASH" || return 1
  require_owned_mode "$VALIDATE_KIT/installer-inputs.tsv" 0:0:600 || return 1
  [ -f "$VALIDATE_KIT/recovery-manifest.tsv" ] && [ ! -L "$VALIDATE_KIT/recovery-manifest.tsv" ] || return 1
  require_owned_mode "$VALIDATE_KIT/recovery-manifest.tsv" 0:0:600 || return 1
  KIT_MANIFEST=$(bb cat "$VALIDATE_KIT/recovery-manifest.tsv" 2>/dev/null) || return 1
  [ "$KIT_MANIFEST" = "$RECOVERY_MANIFEST" ]
}

copy_recovery_member() {
  COPY_SOURCE=$1; COPY_TARGET=$2; COPY_MODE=$3
  bb cp "$COPY_SOURCE" "$COPY_TARGET" || fail "cannot copy recovery member: ${COPY_TARGET##*/}"
  bb chmod "$COPY_MODE" "$COPY_TARGET" || fail "cannot protect recovery member: ${COPY_TARGET##*/}"
  bb chown 0:0 "$COPY_TARGET" || fail "cannot own recovery member: ${COPY_TARGET##*/}"
  bb fsync "$COPY_TARGET" || fail "cannot persist recovery member: ${COPY_TARGET##*/}"
}

ensure_recovery_kit() {
  [ -d "$DOCKER_ROOT" ] && [ ! -L "$DOCKER_ROOT" ] || fail 'Docker root is unavailable or unsafe for recovery publication'
  if ! path_exists "$RECOVERY_ROOT"; then
    (umask 077; bb mkdir "$RECOVERY_ROOT") || fail 'cannot create recovery root'
    bb chmod 0700 "$RECOVERY_ROOT" || fail 'cannot protect recovery root'
    bb chown 0:0 "$RECOVERY_ROOT" || fail 'cannot own recovery root'
    bb fsync "$DOCKER_ROOT" || fail 'cannot persist recovery root'
  fi
  if ! [ -d "$RECOVERY_ROOT" ] || [ -L "$RECOVERY_ROOT" ] ||
     ! require_owned_mode "$RECOVERY_ROOT" 0:0:700; then
    fail 'recovery root is unsafe'
  fi

  RECOVERY_DIR=$RECOVERY_ROOT/$MODULE_VERSION
  RECOVERY_KERNELCTL=$RECOVERY_DIR/bin/kernelctl
  if path_exists "$RECOVERY_DIR"; then
    validate_recovery_kit "$RECOVERY_DIR" || fail 'existing recovery kit does not exactly match this module'
    RECOVERY_READY=1
    return 0
  fi

  RECOVERY_STAGING=$RECOVERY_ROOT/.$MODULE_VERSION.staging.$$
  path_exists "$RECOVERY_STAGING" && fail 'recovery staging path already exists'
  (umask 077; bb mkdir "$RECOVERY_STAGING") || fail 'cannot create recovery staging directory'
  bb chmod 0700 "$RECOVERY_STAGING" || fail 'cannot protect recovery staging directory'
  bb chown 0:0 "$RECOVERY_STAGING" || fail 'cannot own recovery staging directory'
  (umask 077; bb mkdir "$RECOVERY_STAGING/bin") || fail 'cannot create recovery bin directory'
  bb chmod 0700 "$RECOVERY_STAGING/bin" || fail 'cannot protect recovery bin directory'
  bb chown 0:0 "$RECOVERY_STAGING/bin" || fail 'cannot own recovery bin directory'

  copy_recovery_member "$KERNELCTL" "$RECOVERY_STAGING/bin/kernelctl" 0755
  copy_recovery_member "$PREFLIGHT" "$RECOVERY_STAGING/bin/install-preflight" 0755
  copy_recovery_member "$SWAP_BOOT_KERNEL" "$RECOVERY_STAGING/bin/swap-boot-kernel" 0755
  copy_recovery_member "$INPUTS" "$RECOVERY_STAGING/installer-inputs.tsv" 0600
  (umask 077; printf '%s\n' "$RECOVERY_MANIFEST" > "$RECOVERY_STAGING/recovery-manifest.tsv") || fail 'cannot write recovery manifest'
  bb chmod 0600 "$RECOVERY_STAGING/recovery-manifest.tsv" || fail 'cannot protect recovery manifest'
  bb chown 0:0 "$RECOVERY_STAGING/recovery-manifest.tsv" || fail 'cannot own recovery manifest'
  bb fsync "$RECOVERY_STAGING/recovery-manifest.tsv" || fail 'cannot persist recovery manifest'
  bb fsync "$RECOVERY_STAGING/bin" || fail 'cannot persist recovery bin directory'
  bb fsync "$RECOVERY_STAGING" || fail 'cannot persist recovery staging directory'
  source_identities_unchanged || fail 'packaged recovery inputs changed during publication'
  validate_recovery_kit "$RECOVERY_STAGING" || fail 'staged recovery kit failed validation'
  bb mv -T "$RECOVERY_STAGING" "$RECOVERY_DIR" || fail 'cannot publish recovery kit'
  RECOVERY_STAGING=
  bb fsync "$RECOVERY_ROOT" || fail 'cannot persist published recovery kit'
  validate_recovery_kit "$RECOVERY_DIR" || fail 'published recovery kit failed validation'
  RECOVERY_READY=1
}

read_kernel_state() {
  KERNEL_OUTPUT=$("$RECOVERY_KERNELCTL" status 2>&1)
  KERNEL_STATUS=$?
  printf '%s\n' "$KERNEL_OUTPUT"
  [ "$KERNEL_STATUS" -eq 0 ] || return "$KERNEL_STATUS"
  TAB=$(printf '\t')
  # shellcheck disable=SC2016
  KERNEL_FIELDS=$(printf '%s\n' "$KERNEL_OUTPUT" | bb awk -F = -v tab="$TAB" '
    NR == 1 { if (NF != 2 || $1 != "KERNELCTL_VERSION" || $2 != "1") exit 1; next }
    NR == 2 { if (NF != 2 || $1 != "build_id" || $2 !~ /^[A-Z0-9]+([.][A-Z0-9]+)+$/) exit 1; build=$2; next }
    NR == 3 { if (NF != 2 || $1 != "slot_suffix" || ($2 != "_a" && $2 != "_b")) exit 1; suffix=$2; next }
    NR == 4 { if (NF != 2 || $1 != "boot_state" || $2 !~ /^[a-z][a-z0-9-]*$/) exit 1; state=$2; next }
    NR == 5 { if (NF != 2 || $1 != "staged_image" || ($2 != "missing" && $2 != "invalid" && $2 != "ready")) exit 1; next }
    { exit 1 }
    END { if (NR != 5 || build == "" || suffix == "" || state == "") exit 1; print build tab suffix tab state }
  ') || return 1
  OLD_IFS=$IFS; IFS=$TAB
  # shellcheck disable=SC2086
  set -- $KERNEL_FIELDS
  IFS=$OLD_IFS
  [ "$#" -eq 3 ] || return 1
  KERNEL_BUILD_ID=$1; KERNEL_SLOT_SUFFIX=$2; KERNEL_BOOT_STATE=$3
}

print_unknown_recovery() {
  printf '%s\n' \
    "$PROGRAM: recovery status command: $RECOVERY_COMMAND_ENV $RECOVERY_KERNELCTL status" \
    "$PROGRAM: after status proves BUILD_ID and _a/_b, restore with: $RECOVERY_COMMAND_ENV $RECOVERY_KERNELCTL restore RESTORE:BUILD_ID:_a|_b" \
    "$PROGRAM: fastboot fallback: fastboot flash boot_<confirmed-active-slot> <exact-known-good-boot.img>" >&2
}

print_exact_recovery() {
  printf '%s\n' \
    "$PROGRAM: recovery status command: $RECOVERY_COMMAND_ENV $RECOVERY_KERNELCTL status" \
    "$PROGRAM: recovery restore command: $RECOVERY_COMMAND_ENV $RECOVERY_KERNELCTL restore RESTORE:$KERNEL_BUILD_ID:$KERNEL_SLOT_SUFFIX" \
    "$PROGRAM: fastboot fallback: fastboot flash boot$KERNEL_SLOT_SUFFIX <exact-known-good-boot.img>" >&2
}

resolve_active_hostctl() {
  [ -L "$ACTIVE_LINK" ] || return 1
  ACTIVE_TARGET=$(bb readlink "$ACTIVE_LINK" 2>/dev/null) || return 1
  case "$ACTIVE_TARGET" in releases/[A-Za-z0-9]*) ;; *) return 1 ;; esac
  RELEASE_NAME=${ACTIVE_TARGET#releases/}
  case "$RELEASE_NAME" in ''|.*|*/*|*[!A-Za-z0-9._+-]*) return 1 ;; esac
  ACTIVE_RELEASE=$DOCKER_ROOT/releases/$RELEASE_NAME
  [ -d "$ACTIVE_RELEASE" ] && [ ! -L "$ACTIVE_RELEASE" ] || return 1
  [ "$(bb readlink -f "$ACTIVE_LINK" 2>/dev/null || true)" = "$ACTIVE_RELEASE" ] || return 1
  require_owned_mode "$ACTIVE_RELEASE" 0:0:700 || return 1
  DIRECT_HOSTCTL=$ACTIVE_RELEASE/hostctl
  [ -f "$DIRECT_HOSTCTL" ] && [ ! -L "$DIRECT_HOSTCTL" ] && [ -x "$DIRECT_HOSTCTL" ] || return 1
  [ "$(bb readlink -f "$ACTIVE_LINK/hostctl" 2>/dev/null || true)" = "$DIRECT_HOSTCTL" ] || return 1
  require_owned_mode "$DIRECT_HOSTCTL" 0:0:755
}

[ -x "$BUSYBOX" ] || fail 'KernelSU BusyBox is unavailable'
[ "$(bb id -u 2>/dev/null || true)" = 0 ] || fail 'root is required' 2
trap cleanup_staging EXIT
trap 'fail "interrupted while preparing uninstall recovery" 129' HUP
trap 'fail "interrupted while preparing uninstall recovery" 130' INT
trap 'fail "interrupted while preparing uninstall recovery" 143' TERM

read_module_version
read_recovery_environment
load_source_identities
ensure_recovery_kit
printf '%s: standalone recovery kit ready at %s\n' "$PROGRAM" "$RECOVERY_DIR"

read_kernel_state
KERNEL_RESULT=$?
if [ "$KERNEL_RESULT" -ne 0 ]; then
  [ "$KERNEL_RESULT" -eq "$ATTENTION_STATUS" ] && printf '%s\n' 'RECOVERY ATTENTION: kernelctl reported status 3. Do not reboot until its recovery guidance is resolved.' >&2
  print_unknown_recovery
  fail 'cannot prove the active kernel state; active host link and releases were preserved' "$KERNEL_RESULT"
fi

if [ "$KERNEL_BOOT_STATE" = current-public ]; then
  print_exact_recovery
  fail 'public kernel is active; restore an authenticated backup before ordinary host cleanup'
fi

resolve_active_hostctl || fail 'active host release or hostctl is unavailable or unsafe; active link was preserved'
ORIGINAL_TARGET=$ACTIVE_TARGET; ORIGINAL_RELEASE=$ACTIVE_RELEASE; ORIGINAL_HOSTCTL=$DIRECT_HOSTCTL
STOP_OUTPUT=$("$DIRECT_HOSTCTL" stop 2>&1)
STOP_STATUS=$?
printf '%s\n' "$STOP_OUTPUT"
if [ "$STOP_STATUS" -ne 0 ]; then
  [ "$STOP_STATUS" -eq "$ATTENTION_STATUS" ] && printf '%s\n' 'RECOVERY ATTENTION: hostctl reported status 3; the active release link was preserved.' >&2
  printf '%s: retry stop directly with: %s stop\n' "$PROGRAM" "$ORIGINAL_HOSTCTL" >&2
  fail 'hostctl refused to stop; park running containers and retry' "$STOP_STATUS"
fi
[ "$STOP_OUTPUT" = 'result=stopped' ] || {
  printf '%s: retry stop directly with: %s stop\n' "$PROGRAM" "$ORIGINAL_HOSTCTL" >&2
  fail 'hostctl stop result was not the exact stopped acknowledgement'
}

resolve_active_hostctl || fail 'active release changed after host stop; refusing unlink'
[ "$ACTIVE_TARGET" = "$ORIGINAL_TARGET" ] && [ "$ACTIVE_RELEASE" = "$ORIGINAL_RELEASE" ] || fail 'active release changed after host stop; refusing unlink'
source_identities_unchanged || fail 'packaged release transaction changed before deactivation'
DEACTIVATE_OUTPUT=$("$RELEASE_TRANSACTION" deactivate "$RELEASE_NAME" 2>&1)
DEACTIVATE_STATUS=$?
if [ "$DEACTIVATE_STATUS" -ne 0 ]; then
  DEACTIVATE_RETRY=0
  if ! path_exists "$ACTIVE_LINK"; then
    DEACTIVATE_RETRY=1
  elif pending_deactivation_matches "$RELEASE_NAME"; then
    DEACTIVATE_RETRY=1
  fi
  if [ "$DEACTIVATE_RETRY" -eq 1 ]; then
    printf '%s\n' "$DEACTIVATE_OUTPUT"
    source_identities_unchanged || fail 'packaged release transaction changed before deactivation retry'
    DEACTIVATE_OUTPUT=$("$RELEASE_TRANSACTION" deactivate "$RELEASE_NAME" 2>&1)
    DEACTIVATE_STATUS=$?
  fi
fi
printf '%s\n' "$DEACTIVATE_OUTPUT"
if [ "$DEACTIVATE_STATUS" -ne 0 ]; then
  [ "$DEACTIVATE_STATUS" -eq "$ATTENTION_STATUS" ] &&
    printf '%s\n' 'RECOVERY ATTENTION: release transaction reported status 3; inspect its guidance before retrying.' >&2
  fail 'transactional active-release deactivation did not complete' "$DEACTIVATE_STATUS"
fi
EXPECTED_DEACTIVATE_OUTPUT=$(printf 'result=deactivated\nactive=none\nprevious=%s\n' "$RELEASE_NAME")
[ "$DEACTIVATE_OUTPUT" = "$EXPECTED_DEACTIVATE_OUTPUT" ] \
  || fail 'release transaction returned an unexpected deactivation acknowledgement'
path_exists "$ACTIVE_LINK" && fail 'active release link still exists after transactional deactivation'

trap - EXIT HUP INT TERM
printf '%s\n' \
  "$PROGRAM: host stopped and active release link removed" \
  "$PROGRAM: KernelSU will delete the module directory; the standalone recovery kit remains at $RECOVERY_DIR" \
  "$PROGRAM: versioned releases, disk data, staged kernels, and boot backups were preserved"
exit 0
