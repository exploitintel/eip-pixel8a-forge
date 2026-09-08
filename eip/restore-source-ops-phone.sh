#!/system/bin/sh
# Verify or restore the exact directory identities retained by the installer.
set -eu

die() {
  printf 'restore-source-ops: %s\n' "$1" >&2
  exit 1
}

[ "$#" -eq 4 ] || [ "$#" -eq 5 ] || die 'usage: restore-source-ops.sh check-pending|finalize|restore|check-restored SOURCE_REV BUILDER_REV sha256:DIGEST [sha256:IMAGE_ID]'
ACTION=$1
SOURCE_REVISION=$2
BUILDER_REVISION=$3
SOURCE_SNAPSHOT_DIGEST=$4
case "$ACTION" in
  check-pending|restore|check-restored) [ "$#" -eq 4 ] || die "$ACTION does not accept an image ID" ;;
  finalize) [ "$#" -eq 5 ] || die 'finalize requires the deployed image ID' ;;
  *) die 'usage: restore-source-ops.sh check-pending|finalize|restore|check-restored SOURCE_REV BUILDER_REV sha256:DIGEST [sha256:IMAGE_ID]' ;;
esac
case "$SOURCE_REVISION" in *[!0-9a-f]*|'') die 'source revision is malformed' ;; esac
case "$BUILDER_REVISION" in *[!0-9a-f]*|'') die 'builder revision is malformed' ;; esac
[ "${#SOURCE_REVISION}" -eq 40 ] || die 'source revision is malformed'
[ "${#BUILDER_REVISION}" -eq 40 ] || die 'builder revision is malformed'
case "$SOURCE_SNAPSHOT_DIGEST" in sha256:*) ;; *) die 'source snapshot digest is malformed' ;; esac
DIGEST_HEX=${SOURCE_SNAPSHOT_DIGEST#sha256:}
case "$DIGEST_HEX" in *[!0-9a-f]*|'') die 'source snapshot digest is malformed' ;; esac
[ "${#DIGEST_HEX}" -eq 64 ] || die 'source snapshot digest is malformed'
DEPLOYED_IMAGE_ID=${5:-}
if [ "$ACTION" = finalize ]; then
  case "$DEPLOYED_IMAGE_ID" in sha256:*) ;; *) die 'deployed image ID is malformed' ;; esac
  IMAGE_ID_HEX=${DEPLOYED_IMAGE_ID#sha256:}
  case "$IMAGE_ID_HEX" in *[!0-9a-f]*|'') die 'deployed image ID is malformed' ;; esac
  [ "${#IMAGE_ID_HEX}" -eq 64 ] || die 'deployed image ID is malformed'
fi

SOURCE_ROOT=${EIP_SOURCE_ROOT:-/data/eip-cve-src}
OPS_ROOT=${EIP_OPS_ROOT:-/data/eip-cve-ops}
BACKUPS_ROOT=${EIP_BACKUPS_ROOT:-/data/eip-cve-backups}
PROC_ROOT=${EIP_PROC_ROOT:-/proc}
LOCK_DIR=${EIP_HOSTCTL_LOCK_DIR:-/data/docker/run/eip-hostctl.lock}
DOCKER_RUN=${LOCK_DIR%/*}
TRANSACTION=$BACKUPS_ROOT/deploy-$SOURCE_REVISION-$BUILDER_REVISION
METADATA=$TRANSACTION/source-ops.txt
PREVIOUS_SOURCE=$TRANSACTION/previous-source
PREVIOUS_OPS=$TRANSACTION/previous-ops
FAILED_SOURCE=$TRANSACTION/failed-candidate-source
FAILED_OPS=$TRANSACTION/failed-candidate-ops
DEPLOYED_MARKER=$TRANSACTION/deployed-image-id
DEPLOYED_MARKER_STAGE=$TRANSACTION/deployed-image-id.stage

identity() {
  stat -c '%d:%i:%u:%g:%a' "$1"
}

require_directory() {
  [ -d "$1" ] && [ ! -L "$1" ] || die "$2 must be a non-symlink directory"
}

release_lock() {
  rm -f "$LOCK_DIR/pid" 2>/dev/null || true
  rmdir "$LOCK_DIR" 2>/dev/null || true
}

release_for_signal() {
  SIGNAL_STATUS=$1
  trap - EXIT HUP INT TERM
  release_lock
  exit "$SIGNAL_STATUS"
}

acquire_lock() {
  [ -d "$DOCKER_RUN" ] && [ ! -L "$DOCKER_RUN" ] || die 'Docker run directory is unavailable'
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    if [ -d "$LOCK_DIR" ] && [ ! -L "$LOCK_DIR" ] \
        && [ -f "$LOCK_DIR/pid" ] && [ ! -L "$LOCK_DIR/pid" ]; then
      LOCK_PID=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
      case "$LOCK_PID" in
        ''|*[!0-9]*) die 'lifecycle lock is malformed; refusing recovery' ;;
      esac
      [ ! -d "$PROC_ROOT/$LOCK_PID" ] || die 'another lifecycle operation is in progress'
      rm -f "$LOCK_DIR/pid" || die 'cannot remove proved-stale lifecycle lock owner'
      rmdir "$LOCK_DIR" || die 'cannot remove proved-stale lifecycle lock'
      mkdir "$LOCK_DIR" 2>/dev/null || die 'another lifecycle operation is in progress'
    else
      die 'lifecycle lock is ambiguous; refusing recovery'
    fi
  fi
  printf '%s\n' "$$" >"$LOCK_DIR/pid" || {
    rmdir "$LOCK_DIR"
    die 'cannot record lifecycle lock'
  }
  chmod 0700 "$LOCK_DIR" || {
    release_lock
    die 'cannot protect lifecycle lock'
  }
  chmod 0600 "$LOCK_DIR/pid" || {
    release_lock
    die 'cannot protect lifecycle lock owner'
  }
  trap release_lock EXIT
  trap 'release_for_signal 129' HUP
  trap 'release_for_signal 130' INT
  trap 'release_for_signal 143' TERM
}

read_metadata() {
  key=$1
  [ -f "$METADATA" ] && [ ! -L "$METADATA" ] || die 'transaction metadata is unavailable'
  count=$(grep -c "^${key}=" "$METADATA" 2>/dev/null || true)
  [ "$count" = 1 ] || die "transaction metadata must define $key exactly once"
  value=$(grep "^${key}=" "$METADATA")
  METADATA_VALUE=${value#*=}
}

read_metadata schema_version
[ "$METADATA_VALUE" = 1 ] || die 'transaction metadata schema is unsupported'
read_metadata source_revision
[ "$METADATA_VALUE" = "$SOURCE_REVISION" ] || die 'source revision does not match transaction'
read_metadata builder_revision
[ "$METADATA_VALUE" = "$BUILDER_REVISION" ] || die 'builder revision does not match transaction'
read_metadata source_snapshot_digest
[ "$METADATA_VALUE" = "$SOURCE_SNAPSHOT_DIGEST" ] || die 'source snapshot digest does not match transaction'
read_metadata source_previous_identity
SOURCE_PREVIOUS_IDENTITY=$METADATA_VALUE
read_metadata ops_previous_identity
OPS_PREVIOUS_IDENTITY=$METADATA_VALUE
read_metadata source_candidate_identity
SOURCE_CANDIDATE_IDENTITY=$METADATA_VALUE
read_metadata ops_candidate_identity
OPS_CANDIDATE_IDENTITY=$METADATA_VALUE

check_selected() {
  require_directory "$SOURCE_ROOT" 'candidate source root'
  require_directory "$OPS_ROOT" 'candidate ops root'
  require_directory "$PREVIOUS_SOURCE" 'preserved source root'
  require_directory "$PREVIOUS_OPS" 'preserved ops root'
  [ ! -e "$FAILED_SOURCE" ] && [ ! -L "$FAILED_SOURCE" ] || die 'failed candidate source already exists'
  [ ! -e "$FAILED_OPS" ] && [ ! -L "$FAILED_OPS" ] || die 'failed candidate ops already exists'
  [ "$(identity "$SOURCE_ROOT")" = "$SOURCE_CANDIDATE_IDENTITY" ] || die 'candidate source identity changed'
  [ "$(identity "$OPS_ROOT")" = "$OPS_CANDIDATE_IDENTITY" ] || die 'candidate ops identity changed'
  [ "$(identity "$PREVIOUS_SOURCE")" = "$SOURCE_PREVIOUS_IDENTITY" ] || die 'preserved source identity changed'
  [ "$(identity "$PREVIOUS_OPS")" = "$OPS_PREVIOUS_IDENTITY" ] || die 'preserved ops identity changed'
}

check_pending() {
  check_selected
  [ ! -e "$DEPLOYED_MARKER" ] && [ ! -L "$DEPLOYED_MARKER" ] || die 'source and ops transaction is already deployed'
  [ ! -e "$DEPLOYED_MARKER_STAGE" ] && [ ! -L "$DEPLOYED_MARKER_STAGE" ] || die 'source and ops deployment marker is incomplete'
}

check_finalized() {
  check_selected
  [ -f "$DEPLOYED_MARKER" ] && [ ! -L "$DEPLOYED_MARKER" ] || die 'deployed image marker is unavailable'
  [ "$(wc -l <"$DEPLOYED_MARKER" | tr -d ' ')" = 1 ] || die 'deployed image marker is malformed'
  [ "$(cat "$DEPLOYED_MARKER")" = "$DEPLOYED_IMAGE_ID" ] || die 'deployed image marker does not match'
  [ "$(stat -c '%a:%u:%g' "$DEPLOYED_MARKER")" = 600:0:0 ] || die 'deployed image marker mode or owner changed'
}

check_restored() {
  require_directory "$SOURCE_ROOT" 'restored source root'
  require_directory "$OPS_ROOT" 'restored ops root'
  require_directory "$FAILED_SOURCE" 'failed candidate source root'
  require_directory "$FAILED_OPS" 'failed candidate ops root'
  [ ! -e "$PREVIOUS_SOURCE" ] && [ ! -L "$PREVIOUS_SOURCE" ] || die 'preserved source path remains after restore'
  [ ! -e "$PREVIOUS_OPS" ] && [ ! -L "$PREVIOUS_OPS" ] || die 'preserved ops path remains after restore'
  [ "$(identity "$SOURCE_ROOT")" = "$SOURCE_PREVIOUS_IDENTITY" ] || die 'exact previous source is not active'
  [ "$(identity "$OPS_ROOT")" = "$OPS_PREVIOUS_IDENTITY" ] || die 'exact previous ops are not active'
  [ "$(identity "$FAILED_SOURCE")" = "$SOURCE_CANDIDATE_IDENTITY" ] || die 'failed candidate source identity changed'
  [ "$(identity "$FAILED_OPS")" = "$OPS_CANDIDATE_IDENTITY" ] || die 'failed candidate ops identity changed'
}

case "$ACTION" in
  check-pending)
    check_pending
    ;;
  finalize)
    if [ -e "$DEPLOYED_MARKER" ] || [ -L "$DEPLOYED_MARKER" ]; then
      check_finalized
      exit 0
    fi
    check_pending
    umask 077
    printf '%s\n' "$DEPLOYED_IMAGE_ID" >"$DEPLOYED_MARKER_STAGE"
    chmod 0600 "$DEPLOYED_MARKER_STAGE"
    chown 0:0 "$DEPLOYED_MARKER_STAGE"
    mv -- "$DEPLOYED_MARKER_STAGE" "$DEPLOYED_MARKER"
    check_finalized
    ;;
  check-restored)
    check_restored
    ;;
  restore)
    if [ -d "$SOURCE_ROOT" ] && [ -d "$OPS_ROOT" ] && [ -d "$FAILED_SOURCE" ] && [ -d "$FAILED_OPS" ] && [ ! -e "$PREVIOUS_SOURCE" ] && [ ! -e "$PREVIOUS_OPS" ]; then
      check_restored
      exit 0
    fi
    acquire_lock
    check_selected
    RESTORE_STARTED=true
    cleanup_restore() {
      status=$?
      trap - EXIT HUP INT TERM
      if [ "${RESTORE_STARTED:-false}" = true ]; then
        if [ -d "$SOURCE_ROOT" ] && [ "$(identity "$SOURCE_ROOT" 2>/dev/null || true)" = "$SOURCE_PREVIOUS_IDENTITY" ]; then
          mv -- "$SOURCE_ROOT" "$PREVIOUS_SOURCE" || true
        fi
        if [ -d "$FAILED_SOURCE" ] && [ ! -e "$SOURCE_ROOT" ]; then
          mv -- "$FAILED_SOURCE" "$SOURCE_ROOT" || true
        fi
        if [ -d "$OPS_ROOT" ] && [ "$(identity "$OPS_ROOT" 2>/dev/null || true)" = "$OPS_PREVIOUS_IDENTITY" ]; then
          mv -- "$OPS_ROOT" "$PREVIOUS_OPS" || true
        fi
        if [ -d "$FAILED_OPS" ] && [ ! -e "$OPS_ROOT" ]; then
          mv -- "$FAILED_OPS" "$OPS_ROOT" || true
        fi
      fi
      release_lock
      exit "$status"
    }
    trap cleanup_restore EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    mv -- "$SOURCE_ROOT" "$FAILED_SOURCE"
    mv -- "$OPS_ROOT" "$FAILED_OPS"
    mv -- "$PREVIOUS_SOURCE" "$SOURCE_ROOT"
    mv -- "$PREVIOUS_OPS" "$OPS_ROOT"
    check_restored
    RESTORE_STARTED=false
    release_lock
    trap - EXIT HUP INT TERM
    ;;
esac
