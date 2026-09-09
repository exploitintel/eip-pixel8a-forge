#!/system/bin/sh
# Materialize and atomically select a matched Forge source and Pixel ops pair.
# This helper runs as root on Android and deliberately never invokes Docker.
set -eu

die() {
  printf 'install-source-ops-phone: %s\n' "$1" >&2
  exit 1
}

usage() {
  die 'usage: install-source-ops-phone.sh PAYLOAD_ROOT SOURCE_REV BUILDER_REV sha256:DIGEST sha256:PAYLOAD_MANIFEST_DIGEST'
}

[ "$#" -eq 5 ] || usage
PAYLOAD=$1
SOURCE_REVISION=$2
BUILDER_REVISION=$3
SOURCE_SNAPSHOT_DIGEST=$4
PAYLOAD_MANIFEST_DIGEST=$5

case "$SOURCE_REVISION" in *[!0-9a-f]*|'') die 'source revision is malformed' ;; esac
case "$BUILDER_REVISION" in *[!0-9a-f]*|'') die 'builder revision is malformed' ;; esac
[ "${#SOURCE_REVISION}" -eq 40 ] || die 'source revision is malformed'
[ "${#BUILDER_REVISION}" -eq 40 ] || die 'builder revision is malformed'
case "$SOURCE_SNAPSHOT_DIGEST" in sha256:*) ;; *) die 'source snapshot digest is malformed' ;; esac
case "$PAYLOAD_MANIFEST_DIGEST" in sha256:*) ;; *) die 'payload manifest digest is malformed' ;; esac
SOURCE_DIGEST_HEX=${SOURCE_SNAPSHOT_DIGEST#sha256:}
PAYLOAD_DIGEST_HEX=${PAYLOAD_MANIFEST_DIGEST#sha256:}
case "$SOURCE_DIGEST_HEX" in *[!0-9a-f]*|'') die 'source snapshot digest is malformed' ;; esac
case "$PAYLOAD_DIGEST_HEX" in *[!0-9a-f]*|'') die 'payload manifest digest is malformed' ;; esac
[ "${#SOURCE_DIGEST_HEX}" -eq 64 ] || die 'source snapshot digest is malformed'
[ "${#PAYLOAD_DIGEST_HEX}" -eq 64 ] || die 'payload manifest digest is malformed'

SOURCE_ROOT=${EIP_SOURCE_ROOT:-/data/eip-cve-src}
OPS_ROOT=${EIP_OPS_ROOT:-/data/eip-cve-ops}
BACKUPS_ROOT=${EIP_BACKUPS_ROOT:-/data/eip-cve-backups}
PROC_ROOT=${EIP_PROC_ROOT:-/proc}
LOCK_DIR=${EIP_HOSTCTL_LOCK_DIR:-/data/docker/run/eip-hostctl.lock}
DOCKER_RUN=${LOCK_DIR%/*}
BACKUP=$BACKUPS_ROOT/deploy-$SOURCE_REVISION-$BUILDER_REVISION
SOURCE_STAGE=$SOURCE_ROOT.stage-$SOURCE_REVISION-$BUILDER_REVISION
OPS_STAGE=$OPS_ROOT.stage-$SOURCE_REVISION-$BUILDER_REVISION
OPS_EXTRACT=$OPS_ROOT.extract-$SOURCE_REVISION-$BUILDER_REVISION
MANIFEST=$PAYLOAD/payload.txt
SOURCE_ARCHIVE=$PAYLOAD/source.tar
OPS_ARCHIVE=$PAYLOAD/ops.tar
RESTORE_SOURCE=$PAYLOAD/restore-source-ops-phone.sh
METADATA=$BACKUP/source-ops.txt
PREVIOUS_SOURCE=$BACKUP/previous-source
PREVIOUS_OPS=$BACKUP/previous-ops

require_directory() {
  [ -d "$1" ] && [ ! -L "$1" ] || die "$2 must be a non-symlink directory"
}

require_file() {
  [ -f "$1" ] && [ ! -L "$1" ] || die "$2 must be a non-symlink regular file"
}

hash_file() {
  HASH_VALUE=$(sha256sum "$1" 2>/dev/null) || die "cannot hash $2"
  HASH_VALUE=${HASH_VALUE%%[[:space:]]*}
  case "$HASH_VALUE" in *[!0-9a-f]*|'') die "invalid digest for $2" ;; esac
  [ "${#HASH_VALUE}" -eq 64 ] || die "invalid digest for $2"
}

read_value() {
  READ_KEY=$1
  READ_COUNT=$(grep -c "^${READ_KEY}=" "$MANIFEST" 2>/dev/null || true)
  [ "$READ_COUNT" = 1 ] || die "payload manifest must define $READ_KEY exactly once"
  READ_VALUE=$(grep "^${READ_KEY}=" "$MANIFEST")
  READ_VALUE=${READ_VALUE#*=}
}

check_hash() {
  CHECK_PATH=$1
  CHECK_KEY=$2
  CHECK_DESCRIPTION=$3
  require_file "$CHECK_PATH" "$CHECK_DESCRIPTION"
  read_value "$CHECK_KEY"
  case "$READ_VALUE" in *[!0-9a-f]*|'') die "$CHECK_KEY is malformed" ;; esac
  [ "${#READ_VALUE}" -eq 64 ] || die "$CHECK_KEY is malformed"
  hash_file "$CHECK_PATH" "$CHECK_DESCRIPTION"
  [ "$HASH_VALUE" = "$READ_VALUE" ] || die "$CHECK_DESCRIPTION digest does not match"
}

identity() {
  stat -c '%d:%i:%u:%g:%a' "$1"
}

LOCK_HELD=false
release_lock() {
  if [ "${LOCK_HELD:-false}" = true ]; then
    rm -f "$LOCK_DIR/pid" 2>/dev/null || true
    rmdir "$LOCK_DIR" 2>/dev/null || true
    LOCK_HELD=false
  fi
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
  LOCK_HELD=true
  chmod 0700 "$LOCK_DIR" || {
    release_lock
    die 'cannot protect lifecycle lock'
  }
  chmod 0600 "$LOCK_DIR/pid" || {
    release_lock
    die 'cannot protect lifecycle lock owner'
  }
}

require_directory "$PAYLOAD" 'payload root'
require_directory "$SOURCE_ROOT" 'current Forge source'
require_directory "$OPS_ROOT" 'current Pixel ops root'
require_file "$MANIFEST" 'payload manifest'
require_file "$SOURCE_ARCHIVE" 'source archive'
require_file "$OPS_ARCHIVE" 'ops archive'
require_file "$RESTORE_SOURCE" 'restore helper'
[ ! -e "$BACKUP" ] && [ ! -L "$BACKUP" ] || die 'source and ops transaction already exists'
[ ! -e "$SOURCE_STAGE" ] && [ ! -L "$SOURCE_STAGE" ] || die 'source staging path already exists'
[ ! -e "$OPS_STAGE" ] && [ ! -L "$OPS_STAGE" ] || die 'ops staging path already exists'
[ ! -e "$OPS_EXTRACT" ] && [ ! -L "$OPS_EXTRACT" ] || die 'ops extraction path already exists'

hash_file "$MANIFEST" 'payload manifest'
[ "$HASH_VALUE" = "$PAYLOAD_DIGEST_HEX" ] || die 'payload manifest digest does not match'
[ "$(wc -l <"$MANIFEST" | tr -d ' ')" = 23 ] || die 'payload manifest must contain exactly 23 fields'
read_value schema_version
[ "$READ_VALUE" = 1 ] || die 'payload manifest schema_version must be 1'
read_value source_revision
[ "$READ_VALUE" = "$SOURCE_REVISION" ] || die 'payload source revision does not match'
read_value builder_revision
[ "$READ_VALUE" = "$BUILDER_REVISION" ] || die 'payload builder revision does not match'
read_value source_snapshot_digest
[ "$READ_VALUE" = "$SOURCE_SNAPSHOT_DIGEST" ] || die 'payload source snapshot digest does not match'
check_hash "$SOURCE_ARCHIVE" source_archive_sha256 'source archive'
[ "sha256:$HASH_VALUE" = "$SOURCE_SNAPSHOT_DIGEST" ] || die 'source archive does not match source snapshot digest'
check_hash "$OPS_ARCHIVE" ops_archive_sha256 'ops archive'
check_hash "$RESTORE_SOURCE" restore_script_sha256 'restore helper'

SOURCE_ARCHIVE_SHA256=$(grep '^source_archive_sha256=' "$MANIFEST")
SOURCE_ARCHIVE_SHA256=${SOURCE_ARCHIVE_SHA256#*=}
OPS_ARCHIVE_SHA256=$(grep '^ops_archive_sha256=' "$MANIFEST")
OPS_ARCHIVE_SHA256=${OPS_ARCHIVE_SHA256#*=}
RESTORE_SCRIPT_SHA256=$(grep '^restore_script_sha256=' "$MANIFEST")
RESTORE_SCRIPT_SHA256=${RESTORE_SCRIPT_SHA256#*=}

mkdir -m 0700 "$SOURCE_STAGE" "$OPS_STAGE" "$OPS_EXTRACT" || die 'cannot create protected staging directories'
STAGING_PRESENT=true
BACKUP_CREATED=false
cleanup_staging() {
  status=$?
  trap - EXIT HUP INT TERM
  if [ "${STAGING_PRESENT:-false}" = true ]; then
    rm -rf -- "$SOURCE_STAGE" "$OPS_STAGE" "$OPS_EXTRACT"
  fi
  if [ "${BACKUP_CREATED:-false}" = true ]; then
    rm -rf -- "$BACKUP"
  fi
  release_lock
  exit "$status"
}
trap cleanup_staging EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

tar -xf "$SOURCE_ARCHIVE" -C "$SOURCE_STAGE" || die 'cannot extract source archive'
tar -xf "$OPS_ARCHIVE" -C "$OPS_EXTRACT" || die 'cannot extract ops archive'

install_ops_file() {
  OPS_LOCAL=$1
  OPS_REMOTE=$2
  OPS_MODE=$3
  OPS_KEY=$4
  OPS_DESCRIPTION=$5
  OPS_FROM=$OPS_EXTRACT/$OPS_LOCAL
  OPS_TO=$OPS_STAGE/$OPS_REMOTE

  check_hash "$OPS_FROM" "$OPS_KEY" "$OPS_DESCRIPTION"
  install -m "$OPS_MODE" -o 0 -g 0 "$OPS_FROM" "$OPS_TO" || die "cannot install $OPS_DESCRIPTION"
}

install_ops_file eip/compose.android.yaml compose.android.yaml 0644 ops_compose_sha256 'Android compose override'
install_ops_file eip/operator-entry.sh entry.sh 0755 ops_entry_sha256 'operator entry script'
install_ops_file eip/phone-eip.sh eip.sh 0755 ops_eip_sha256 'phone lifecycle script'
install_ops_file eip/eip-hostctl.sh eip-hostctl.sh 0755 ops_hostctl_sha256 'host lifecycle authority'
install_ops_file eip/hostctl-state.mjs hostctl-state.mjs 0644 ops_hostctl_state_sha256 'host lifecycle state inspector'
install_ops_file eip/rebase-managed-skills.py rebase-managed-skills.py 0755 ops_rebase_sha256 'managed-skills rebase script'
install_ops_file eip/redeploy-managed-state.sh redeploy-managed-state.sh 0755 ops_redeploy_state_sha256 'managed-state transaction script'
install_ops_file eip/preflight.sh preflight.sh 0755 ops_preflight_sha256 'preflight script'
install_ops_file eip/fix-routing.sh fix-routing.sh 0755 ops_fix_routing_sha256 'routing script'
install_ops_file eip/merge-env.sh merge-env.sh 0755 ops_merge_env_sha256 'environment merge script'
install_ops_file eip/set-ollama.sh set-ollama.sh 0755 ops_set_ollama_sha256 'Ollama configuration script'
install_ops_file eip/set-ollama-key.sh set-ollama-key.sh 0755 ops_set_ollama_key_sha256 'Ollama credential script'

check_hash "$SOURCE_STAGE/deploy/container/compose.yaml" source_compose_sha256 'Forge compose file'
check_hash "$SOURCE_STAGE/deploy/container/verify.sh" source_verify_sha256 'Forge verify script'
check_hash "$SOURCE_STAGE/deploy/container/bootstrap.sh" source_bootstrap_sha256 'Forge bootstrap script'
check_hash "$SOURCE_STAGE/package.json" source_package_sha256 'Forge package manifest'
rm -rf -- "$OPS_EXTRACT"

chmod 0755 "$SOURCE_STAGE" "$OPS_STAGE"
chown 0:0 "$SOURCE_STAGE" "$OPS_STAGE"
SOURCE_PREVIOUS_IDENTITY=$(identity "$SOURCE_ROOT") || die 'cannot identify current source root'
OPS_PREVIOUS_IDENTITY=$(identity "$OPS_ROOT") || die 'cannot identify current ops root'
SOURCE_CANDIDATE_IDENTITY=$(identity "$SOURCE_STAGE") || die 'cannot identify staged source root'
OPS_CANDIDATE_IDENTITY=$(identity "$OPS_STAGE") || die 'cannot identify staged ops root'

install -d -m 0700 -o 0 -g 0 "$BACKUPS_ROOT" || die 'cannot protect backup root'
[ "$(stat -c '%a:%u:%g' "$BACKUPS_ROOT")" = 700:0:0 ] || die 'backup root must be mode 0700 and owned by root'
mkdir -m 0700 "$BACKUP" || die 'cannot create transaction backup'
BACKUP_CREATED=true
chown 0:0 "$BACKUP"
install -m 0700 -o 0 -g 0 "$RESTORE_SOURCE" "$BACKUP/restore-source-ops.sh" || die 'cannot retain restore helper'
cat >"$METADATA" <<EOF
schema_version=1
source_revision=$SOURCE_REVISION
builder_revision=$BUILDER_REVISION
source_snapshot_digest=$SOURCE_SNAPSHOT_DIGEST
source_archive_sha256=$SOURCE_ARCHIVE_SHA256
ops_archive_sha256=$OPS_ARCHIVE_SHA256
restore_script_sha256=$RESTORE_SCRIPT_SHA256
source_previous_identity=$SOURCE_PREVIOUS_IDENTITY
ops_previous_identity=$OPS_PREVIOUS_IDENTITY
source_candidate_identity=$SOURCE_CANDIDATE_IDENTITY
ops_candidate_identity=$OPS_CANDIDATE_IDENTITY
EOF
chmod 0600 "$METADATA"
chown 0:0 "$METADATA"

acquire_lock
SWAP_STARTED=true
cleanup_swap() {
  status=$?
  trap - EXIT HUP INT TERM
  if [ "${SWAP_STARTED:-false}" = true ]; then
    if [ -d "$SOURCE_ROOT" ] && [ "$(identity "$SOURCE_ROOT" 2>/dev/null || true)" = "$SOURCE_CANDIDATE_IDENTITY" ]; then
      mv -- "$SOURCE_ROOT" "$SOURCE_STAGE" || true
    fi
    if [ -d "$PREVIOUS_SOURCE" ] && [ ! -e "$SOURCE_ROOT" ]; then
      mv -- "$PREVIOUS_SOURCE" "$SOURCE_ROOT" || true
    fi
    if [ -d "$OPS_ROOT" ] && [ "$(identity "$OPS_ROOT" 2>/dev/null || true)" = "$OPS_CANDIDATE_IDENTITY" ]; then
      mv -- "$OPS_ROOT" "$OPS_STAGE" || true
    fi
    if [ -d "$PREVIOUS_OPS" ] && [ ! -e "$OPS_ROOT" ]; then
      mv -- "$PREVIOUS_OPS" "$OPS_ROOT" || true
    fi
    rm -rf -- "$SOURCE_STAGE" "$OPS_STAGE" "$OPS_EXTRACT"
    if [ -d "$SOURCE_ROOT" ] && [ -d "$OPS_ROOT" ] \
        && [ "$(identity "$SOURCE_ROOT" 2>/dev/null || true)" = "$SOURCE_PREVIOUS_IDENTITY" ] \
        && [ "$(identity "$OPS_ROOT" 2>/dev/null || true)" = "$OPS_PREVIOUS_IDENTITY" ] \
        && [ ! -e "$PREVIOUS_SOURCE" ] && [ ! -e "$PREVIOUS_OPS" ]; then
      rm -rf -- "$BACKUP"
    fi
  fi
  release_lock
  exit "$status"
}
trap cleanup_swap EXIT

mv -- "$SOURCE_ROOT" "$PREVIOUS_SOURCE"
mv -- "$OPS_ROOT" "$PREVIOUS_OPS"
mv -- "$SOURCE_STAGE" "$SOURCE_ROOT"
mv -- "$OPS_STAGE" "$OPS_ROOT"

[ "$(identity "$PREVIOUS_SOURCE")" = "$SOURCE_PREVIOUS_IDENTITY" ] || die 'preserved source identity changed'
[ "$(identity "$PREVIOUS_OPS")" = "$OPS_PREVIOUS_IDENTITY" ] || die 'preserved ops identity changed'
[ "$(identity "$SOURCE_ROOT")" = "$SOURCE_CANDIDATE_IDENTITY" ] || die 'candidate source identity changed'
[ "$(identity "$OPS_ROOT")" = "$OPS_CANDIDATE_IDENTITY" ] || die 'candidate ops identity changed'

SWAP_STARTED=false
STAGING_PRESENT=false
BACKUP_CREATED=false
release_lock
trap - EXIT HUP INT TERM
printf 'source and ops transaction pending at %s\n' "$BACKUP"
