#!/bin/bash
# Preserve and restore the exact managed-skills tree around a controller update.
# This runs as root inside the existing phone operator container.
set -euo pipefail

ROOT=${EIP_CVE_ROOT:-/data/eip-cve}
STATE_ROOT=$ROOT/state
MANAGED_ROOT=$STATE_ROOT/managed-skills
TRANSACTIONS_ROOT=$ROOT/redeploy-transactions

die() {
  printf 'managed-state transaction: %s\n' "$*" >&2
  exit 1
}

identity() {
  stat -c '%d:%i:%u:%g:%a' "$1"
}

require_directory() {
  [[ -d "$1" && ! -L "$1" ]] || die "$1 must be a non-symlink directory"
}

[[ $# -eq 2 ]] || die 'usage: redeploy-managed-state.sh prepare|check-candidate|restore|check-restored TRANSACTION_ID'
ACTION=$1
TRANSACTION_ID=$2
[[ "$TRANSACTION_ID" =~ ^[0-9a-f]{64}$ ]] || die 'transaction ID must be 64 lowercase hex characters'

TRANSACTION=$TRANSACTIONS_ROOT/$TRANSACTION_ID
PREVIOUS=$TRANSACTION/previous-managed-skills
FAILED=$TRANSACTION/failed-candidate-managed-skills
METADATA=$TRANSACTION/managed-state.txt

read_metadata() {
  local key=$1 matches
  [[ -f "$METADATA" && ! -L "$METADATA" ]] || die 'transaction metadata is unavailable'
  matches=$(grep -c "^${key}=" "$METADATA" || true)
  [[ "$matches" == 1 ]] || die "transaction metadata has no unique $key"
  grep "^${key}=" "$METADATA" | cut -d= -f2-
}

check_candidate() {
  local previous_identity candidate_identity
  previous_identity=$(read_metadata previous_identity)
  candidate_identity=$(read_metadata candidate_identity)
  require_directory "$PREVIOUS"
  require_directory "$MANAGED_ROOT"
  [[ "$(identity "$PREVIOUS")" == "$previous_identity" ]] \
    || die 'preserved managed-skills identity changed'
  [[ "$(identity "$MANAGED_ROOT")" == "$candidate_identity" ]] \
    || die 'candidate managed-skills identity changed'
  [[ ! -e "$FAILED" && ! -L "$FAILED" ]] \
    || die 'failed-candidate retention path already exists'
}

check_restored() {
  local previous_identity candidate_identity
  previous_identity=$(read_metadata previous_identity)
  candidate_identity=$(read_metadata candidate_identity)
  require_directory "$MANAGED_ROOT"
  require_directory "$FAILED"
  [[ "$(identity "$MANAGED_ROOT")" == "$previous_identity" ]] \
    || die 'exact previous managed-skills tree is not active'
  [[ "$(identity "$FAILED")" == "$candidate_identity" ]] \
    || die 'failed candidate managed-skills identity changed'
  [[ ! -e "$PREVIOUS" && ! -L "$PREVIOUS" ]] \
    || die 'previous managed-skills path still exists after restore'
}

case "$ACTION" in
  prepare)
    require_directory "$STATE_ROOT"
    require_directory "$MANAGED_ROOT"
    [[ ! -e "$TRANSACTION" && ! -L "$TRANSACTION" ]] \
      || die 'managed-state transaction already exists'
    install -d -m 0700 -o 0 -g 0 "$TRANSACTIONS_ROOT"
    [[ "$(stat -c '%a:%u:%g' "$TRANSACTIONS_ROOT")" == 700:0:0 ]] \
      || die 'transaction root must be mode 0700 and owned by root'
    mkdir "$TRANSACTION"
    chmod 0700 "$TRANSACTION"
    chown 0:0 "$TRANSACTION"

    previous_identity=$(identity "$MANAGED_ROOT")
    prepared=false
    cleanup_prepare() {
      local status=$?
      trap - EXIT
      trap '' HUP INT TERM
      if [[ "$prepared" != true ]]; then
        rm -rf -- "$TRANSACTION/candidate.stage"
        if [[ -d "$PREVIOUS" && ! -e "$MANAGED_ROOT" ]]; then
          mv -- "$PREVIOUS" "$MANAGED_ROOT"
        fi
        if [[ -d "$MANAGED_ROOT" && "$(identity "$MANAGED_ROOT")" != "$previous_identity" \
            && -d "$PREVIOUS" ]]; then
          mv -- "$MANAGED_ROOT" "$TRANSACTION/failed-prepare"
          mv -- "$PREVIOUS" "$MANAGED_ROOT"
        fi
      fi
      exit "$status"
    }
    trap cleanup_prepare EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    mv -- "$MANAGED_ROOT" "$PREVIOUS"
    cp -a -- "$PREVIOUS" "$TRANSACTION/candidate.stage"
    mv -- "$TRANSACTION/candidate.stage" "$MANAGED_ROOT"
    candidate_identity=$(identity "$MANAGED_ROOT")
    [[ "$candidate_identity" != "$previous_identity" ]] \
      || die 'candidate managed-skills copy did not receive a distinct identity'
    printf '%s\n' \
      "transaction_id=$TRANSACTION_ID" \
      "previous_identity=$previous_identity" \
      "candidate_identity=$candidate_identity" >"$METADATA"
    chmod 0600 "$METADATA"
    chown 0:0 "$METADATA"
    prepared=true
    trap - EXIT HUP INT TERM
    check_candidate
    ;;
  check-candidate)
    check_candidate
    ;;
  restore)
    if [[ -d "$MANAGED_ROOT" && -d "$FAILED" && ! -e "$PREVIOUS" ]]; then
      check_restored
      exit 0
    fi
    check_candidate
    previous_identity=$(read_metadata previous_identity)
    candidate_identity=$(read_metadata candidate_identity)
    restore_started=false
    cleanup_restore() {
      local status=$?
      trap - EXIT
      trap '' HUP INT TERM
      if [[ "$restore_started" == true ]]; then
        if [[ -d "$MANAGED_ROOT" && "$(identity "$MANAGED_ROOT")" == "$previous_identity" ]]; then
          mv -- "$MANAGED_ROOT" "$PREVIOUS" || true
        fi
        if [[ -d "$FAILED" && ! -e "$MANAGED_ROOT" ]]; then
          mv -- "$FAILED" "$MANAGED_ROOT" || true
        fi
      fi
      exit "$status"
    }
    trap cleanup_restore EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    restore_started=true
    mv -- "$MANAGED_ROOT" "$FAILED"
    mv -- "$PREVIOUS" "$MANAGED_ROOT"
    check_restored
    restore_started=false
    trap - EXIT HUP INT TERM
    ;;
  check-restored)
    check_restored
    ;;
  *)
    die 'usage: redeploy-managed-state.sh prepare|check-candidate|restore|check-restored TRANSACTION_ID'
    ;;
esac
