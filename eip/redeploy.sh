#!/bin/bash
# Activate one source-attributed controller image that has already been loaded
# on the phone, release the installed v4 skill pack, then recreate the existing
# Forge UI and chat stack. Bootstrap already ran; existing state is preserved
# transactionally and restored if the candidate fails.
set -euo pipefail

if [[ -n "${ADB:-}" ]]; then
  ADB_BIN=$ADB
elif command -v adb >/dev/null 2>&1; then
  ADB_BIN=$(command -v adb)
else
  ADB_BIN=$HOME/Library/Android/sdk/platform-tools/adb
fi
PHONE_DOCKER='DOCKER_HOST=unix:///data/docker/run/docker.sock /data/docker/bin/docker'
PHONE_EIP=/data/eip-cve-ops/eip.sh
PHONE_HOSTCTL=/data/eip-cve-ops/eip-hostctl.sh
CONTROLLER_TAG=eip-cve-controller:phone
ACTIVE_TAG=eip-cve-controller:local
ROLLBACK_TAG=eip-cve-controller:rollback
OPERATOR_CANDIDATE_TAG=eip-operator-shell:candidate
OPERATOR_ACTIVE_TAG=eip-operator-shell:phone
OPERATOR_ROLLBACK_TAG=eip-operator-shell:rollback
POLL_ATTEMPTS=30
POLL_INTERVAL_SECONDS=5
ROLLBACK_ARMED=false
PARKED_BASELINE=false

usage() {
  printf '%s\n' 'usage: redeploy.sh --serial ADB_SERIAL --manifest CONTROLLER_BUILD.json [--parked]'
}

die() {
  printf 'redeploy: %s\n' "$1" >&2
  exit 2
}

step() {
  printf '\n===== %s =====\n' "$*"
}

MANIFEST=
MANIFEST_SEEN=false
SERIAL=
SERIAL_SEEN=false
PARKED_SEEN=false
while (($# > 0)); do
  case "$1" in
    --manifest)
      "$MANIFEST_SEEN" && die '--manifest may be specified only once'
      (($# >= 2)) || die '--manifest requires a value'
      MANIFEST=$2
      MANIFEST_SEEN=true
      shift 2
      ;;
    --serial)
      "$SERIAL_SEEN" && die '--serial may be specified only once'
      (($# >= 2)) || die '--serial requires a value'
      SERIAL=$2
      SERIAL_SEEN=true
      shift 2
      ;;
    --parked)
      "$PARKED_SEEN" && die '--parked may be specified only once'
      PARKED_BASELINE=true
      PARKED_SEEN=true
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --*)
      die "unknown option: $1"
      ;;
    *)
      die 'positional arguments are not accepted'
      ;;
  esac
done

"$MANIFEST_SEEN" || die '--manifest is required'
"$SERIAL_SEEN" || die '--serial is required'
[[ "$SERIAL" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$ ]] || \
  die 'ADB serial must contain only letters, digits, dot, underscore, colon, or hyphen'
[[ -f "$MANIFEST" && ! -L "$MANIFEST" && -r "$MANIFEST" ]] || \
  die 'build manifest must be a readable regular file'
[[ -z "${DOCKER_HOST:-}" ]] || \
  die 'DOCKER_HOST must be unset; redeploy uses the phone candidate and phone Unix socket directly'

command -v python3 >/dev/null 2>&1 || die 'python3 is unavailable'
[[ -x "$ADB_BIN" ]] || die "adb is missing or not executable: $ADB_BIN"

read_manifest() {
  python3 - "$1" <<'PY'
import json
import re
import sys

def reject(message):
    print(f"redeploy: invalid build manifest: {message}", file=sys.stderr)
    raise SystemExit(1)

try:
    with open(sys.argv[1], "r", encoding="utf-8") as handle:
        manifest = json.load(handle)
except (OSError, UnicodeError, json.JSONDecodeError) as error:
    reject(str(error))

if not isinstance(manifest, dict):
    reject("root must be an object")
if type(manifest.get("schemaVersion")) is not int or manifest.get("schemaVersion") != 1:
    reject("schemaVersion must be 1")
if manifest.get("kind") != "eip-controller-build-manifest":
    reject("kind is not eip-controller-build-manifest")
if manifest.get("provenanceLevel") != "source-attributed":
    reject("provenanceLevel is not source-attributed")
if manifest.get("scope") not in ("controller-only", "release-images"):
    reject("scope is unsupported")
if manifest.get("platform") != "linux/arm64":
    reject("platform is not linux/arm64")

builder = manifest.get("builder")
controller = manifest.get("controller")
if not isinstance(builder, dict) or not isinstance(controller, dict):
    reject("builder and controller must be objects")
if builder.get("dirty") is not False or controller.get("sourceDirty") is not False:
    reject("redeploy requires clean Forge and companion source")
if controller.get("tag") != "eip-cve-controller:phone":
    reject("controller tag is not eip-cve-controller:phone")

revision_pattern = re.compile(r"[0-9a-f]{40}")
digest_pattern = re.compile(r"sha256:[0-9a-f]{64}")
if not isinstance(builder.get("revision"), str) or not revision_pattern.fullmatch(builder["revision"]):
    reject("builder revision is malformed")
if not isinstance(controller.get("sourceRevision"), str) or not revision_pattern.fullmatch(controller["sourceRevision"]):
    reject("controller sourceRevision is malformed")
if not isinstance(controller.get("sourceSnapshotDigest"), str) or not digest_pattern.fullmatch(controller["sourceSnapshotDigest"]):
    reject("controller sourceSnapshotDigest is malformed")

image_id = controller.get("imageId")
if not isinstance(image_id, str) or not digest_pattern.fullmatch(image_id):
    reject("controller imageId is malformed")
operator = manifest.get("operator")
operator_id = ""
if operator is not None:
    if manifest.get("scope") != "release-images" or not isinstance(operator, dict):
        reject("operator requires release-images scope")
    if operator.get("tag") != "eip-operator-shell:candidate":
        reject("operator tag is not eip-operator-shell:candidate")
    operator_id = operator.get("imageId")
    if not isinstance(operator_id, str) or not digest_pattern.fullmatch(operator_id):
        reject("operator imageId is malformed")
print("\t".join([
    image_id,
    controller["sourceRevision"],
    builder["revision"],
    controller["sourceSnapshotDigest"],
    operator_id,
]))
PY
}

normalize_id() {
  NORMALIZED_ID=${1//$'\r'/}
  [[ "$NORMALIZED_ID" =~ ^sha256:[0-9a-f]{64}$ ]]
}

phone() {
  local command=$1
  local quoted_command

  quoted_command=${command//\'/\'\\\'\'}
  "$ADB_BIN" -s "$SERIAL" shell -T "su -c '$quoted_command'"
}

phone_image_id() {
  phone "$PHONE_DOCKER image inspect --format='{{.Id}}' $1"
}

service_observation() {
  local service=$1
  local expected_image_id=$2
  local container_id observation

  container_id=$(phone "$PHONE_EIP ps -q $service" 2>/dev/null) || return 1
  container_id=${container_id//$'\r'/}
  [[ "$container_id" =~ ^[0-9a-f]{12,64}$ ]] || return 1
  observation=$(phone "$PHONE_DOCKER inspect --format='{{.Image}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}missing{{end}}' $container_id" 2>/dev/null) || \
    return 1
  observation=${observation//$'\r'/}
  [[ "$observation" == "$expected_image_id|healthy" ]]
}

wait_for_services() {
  local expected_image_id=$1
  local attempt=1
  local ui_ready chat_ready

  while ((attempt <= POLL_ATTEMPTS)); do
    ui_ready=false
    chat_ready=false
    service_observation ui "$expected_image_id" && ui_ready=true
    service_observation chat "$expected_image_id" && chat_ready=true
    if "$ui_ready" && "$chat_ready"; then
      return 0
    fi
    if ((attempt < POLL_ATTEMPTS)); then
      sleep "$POLL_INTERVAL_SECONDS"
    fi
    ((attempt += 1))
  done
  return 1
}

wait_for_service() {
  local service=$1
  local expected_image_id=$2
  local attempt=1

  while ((attempt <= POLL_ATTEMPTS)); do
    if service_observation "$service" "$expected_image_id"; then
      return 0
    fi
    if ((attempt < POLL_ATTEMPTS)); then
      sleep "$POLL_INTERVAL_SECONDS"
    fi
    ((attempt += 1))
  done
  return 1
}

bounded_diagnostics() {
  local description=$1

  step "bounded compose status: $description"
  phone "$PHONE_EIP ps" 2>&1 || true
  step "bounded ui and chat logs: $description"
  phone "$PHONE_EIP logs --no-color --tail 40 ui chat" 2>&1 || true
}

rollback_previous() {
  step 'stopping the candidate stack before state rollback'
  if ! phone "$PHONE_EIP down"; then
    printf 'redeploy: rollback failed: could not stop the candidate stack\n' >&2
    return 1
  fi

  if "$MANAGED_PREPARED"; then
    step 'restoring the exact pre-release managed-skills tree'
    local managed_restore_failed=false
    phone "$PHONE_EIP managed-state restore $MANAGED_TRANSACTION_ID" || \
      managed_restore_failed=true
    if ! phone "$PHONE_EIP managed-state check-restored $MANAGED_TRANSACTION_ID"; then
      printf 'redeploy: rollback failed: exact managed-skills restoration could not be proved\n' >&2
      return 1
    fi
    if "$managed_restore_failed"; then
      printf 'redeploy: managed-skills restore returned nonzero, but its exact postcondition is present\n' >&2
    fi
    printf 'redeploy: failed-candidate managed skills retained at %s\n' \
      "$MANAGED_FAILED_PATH" >&2
  fi

  step 'restoring the exact pre-release Forge source and Pixel operations bundle'
  local source_restore_failed=false
  phone "$SOURCE_OPS_RESTORE restore $SOURCE_REVISION $BUILDER_REVISION $SOURCE_SNAPSHOT_DIGEST" || \
    source_restore_failed=true
  if ! phone "$SOURCE_OPS_RESTORE check-restored $SOURCE_REVISION $BUILDER_REVISION $SOURCE_SNAPSHOT_DIGEST"; then
    printf 'redeploy: rollback failed: exact source and operations restoration could not be proved\n' >&2
    return 1
  fi
  if "$source_restore_failed"; then
    printf 'redeploy: source and operations restore returned nonzero, but its exact postcondition is present\n' >&2
  fi

  if "$OPERATOR_CHANGE"; then
    step "restoring $PREVIOUS_OPERATOR_ID as $OPERATOR_ACTIVE_TAG"
    local operator_restore_failed=false restored_operator_id
    phone "$PHONE_DOCKER tag $PREVIOUS_OPERATOR_ID $OPERATOR_ACTIVE_TAG" || \
      operator_restore_failed=true
    restored_operator_id=$(phone_image_id "$OPERATOR_ACTIVE_TAG") || {
      printf 'redeploy: rollback failed: could not inspect the restored operator tag\n' >&2
      return 1
    }
    if ! normalize_id "$restored_operator_id" || [[ "$NORMALIZED_ID" != "$PREVIOUS_OPERATOR_ID" ]]; then
      printf 'redeploy: rollback failed: operator tag does not resolve to the previous image\n' >&2
      return 1
    fi
    if "$operator_restore_failed"; then
      printf 'redeploy: operator restore returned nonzero, but its exact postcondition is present\n' >&2
    fi
  fi

  step "restoring $PREVIOUS_IMAGE_ID as $ACTIVE_TAG"
  local restore_command_failed=false
  phone "$PHONE_DOCKER tag $PREVIOUS_IMAGE_ID $ACTIVE_TAG" || \
    restore_command_failed=true

  local restored_image_id
  if ! restored_image_id=$(phone_image_id "$ACTIVE_TAG"); then
    printf 'redeploy: rollback failed: could not inspect the restored image tag\n' >&2
    return 1
  fi
  if ! normalize_id "$restored_image_id" || [[ "$NORMALIZED_ID" != "$PREVIOUS_IMAGE_ID" ]]; then
    printf 'redeploy: rollback failed: active tag does not resolve to the previous image\n' >&2
    return 1
  fi
  if "$restore_command_failed"; then
    printf 'redeploy: rollback restore command returned nonzero, but its exact postcondition is present\n' >&2
  fi

  if "$PARKED_BASELINE"; then
    if ! phone "$PHONE_HOSTCTL start"; then
      printf 'redeploy: rollback failed: normal lifecycle could not restart the previous stack\n' >&2
      return 1
    fi
  else
    if ! phone "$PHONE_EIP up --force-recreate"; then
      printf 'redeploy: rollback failed: previous stack recreation failed\n' >&2
      return 1
    fi
  fi
  if ! wait_for_services "$PREVIOUS_IMAGE_ID"; then
    printf 'redeploy: rollback failed: ui and chat are not healthy on the previous image\n' >&2
    bounded_diagnostics 'after failed rollback'
    return 1
  fi

  printf 'redeploy: rollback succeeded; ui and chat are healthy on %s\n' \
    "$PREVIOUS_IMAGE_ID" >&2
  return 0
}

candidate_failed() {
  local reason=$1

  trap - EXIT
  trap '' HUP INT TERM
  ROLLBACK_ARMED=false
  printf 'redeploy: candidate failed: %s\n' "$reason" >&2
  bounded_diagnostics 'candidate failure before rollback'
  if ! rollback_previous; then
    printf 'redeploy: candidate failed and automatic rollback did not recover the stack\n' >&2
  fi
  exit 1
}

unexpected_exit() {
  local status=$?
  trap - EXIT HUP INT TERM
  if "$ROLLBACK_ARMED"; then
    candidate_failed "unexpected redeploy exit with status $status"
  fi
  exit "$status"
}

interrupted() {
  local signal=$1
  local status=$2
  trap - EXIT HUP INT TERM
  if "$ROLLBACK_ARMED"; then
    candidate_failed "redeploy received $signal"
  fi
  exit "$status"
}

trap unexpected_exit EXIT
trap 'interrupted HUP 129' HUP
trap 'interrupted INT 130' INT
trap 'interrupted TERM 143' TERM

if ! IFS=$'\t' read -r CANDIDATE_ID SOURCE_REVISION BUILDER_REVISION SOURCE_SNAPSHOT_DIGEST OPERATOR_CANDIDATE_ID \
  < <(read_manifest "$MANIFEST"); then
  die 'build manifest validation failed'
fi
[[ -n "$CANDIDATE_ID" && -n "$SOURCE_REVISION" && -n "$BUILDER_REVISION" \
  && -n "$SOURCE_SNAPSHOT_DIGEST" ]] || die 'build manifest validation failed'
HAS_OPERATOR=false
OPERATOR_CHANGE=false
if [[ -n "$OPERATOR_CANDIDATE_ID" ]]; then
  HAS_OPERATOR=true
fi
SOURCE_OPS_TRANSACTION=/data/eip-cve-backups/deploy-$SOURCE_REVISION-$BUILDER_REVISION
SOURCE_OPS_RESTORE=$SOURCE_OPS_TRANSACTION/restore-source-ops.sh
MANAGED_TRANSACTION_ID=${CANDIDATE_ID#sha256:}
MANAGED_FAILED_PATH=/data/eip-cve/redeploy-transactions/$MANAGED_TRANSACTION_ID/failed-candidate-managed-skills
MANAGED_PREPARED=false

printf '%s\n' \
  'redeploy: Forge v4 skills rebase includes its governed missing-QA backfill; this run requires provider-use authorization.' \
  'redeploy: keep the authenticated skills UI idle until final health proof; rollback retains candidate-window writes for manual recovery.'

step 'verifying the manifest-bound source and Pixel operations transaction'
phone "$SOURCE_OPS_RESTORE check-pending $SOURCE_REVISION $BUILDER_REVISION $SOURCE_SNAPSHOT_DIGEST" || \
  die 'the matching source and operations transaction is not pending on the phone'

step 'verifying the manifest-bound candidate already loaded on the phone'
PHONE_CANDIDATE_ID=$(phone_image_id "$CONTROLLER_TAG") || \
  die 'cannot inspect the candidate controller image on the phone'
normalize_id "$PHONE_CANDIDATE_ID" || die 'phone candidate controller image ID is malformed'
[[ "$NORMALIZED_ID" == "$CANDIDATE_ID" ]] || \
  die 'phone candidate controller image does not match the build manifest'

PREVIOUS_IMAGE_ID=$(phone_image_id "$ACTIVE_TAG") || \
  die "cannot resolve the current $ACTIVE_TAG image on the phone"
normalize_id "$PREVIOUS_IMAGE_ID" || die 'current phone controller image ID is malformed'
PREVIOUS_IMAGE_ID=$NORMALIZED_ID
[[ "$PREVIOUS_IMAGE_ID" != "$CANDIDATE_ID" ]] || \
  die 'candidate image is already active; refusing to replay its deployment transaction'

if "$HAS_OPERATOR"; then
  PHONE_OPERATOR_CANDIDATE_ID=$(phone_image_id "$OPERATOR_CANDIDATE_TAG") || \
    die 'cannot inspect the candidate operator image on the phone'
  normalize_id "$PHONE_OPERATOR_CANDIDATE_ID" || die 'phone candidate operator image ID is malformed'
  [[ "$NORMALIZED_ID" == "$OPERATOR_CANDIDATE_ID" ]] || \
    die 'phone candidate operator image does not match the build manifest'
  PREVIOUS_OPERATOR_ID=$(phone_image_id "$OPERATOR_ACTIVE_TAG") || \
    die "cannot resolve the current $OPERATOR_ACTIVE_TAG image on the phone"
  normalize_id "$PREVIOUS_OPERATOR_ID" || die 'current phone operator image ID is malformed'
  PREVIOUS_OPERATOR_ID=$NORMALIZED_ID
  if [[ "$PREVIOUS_OPERATOR_ID" != "$OPERATOR_CANDIDATE_ID" ]]; then
    OPERATOR_CHANGE=true
  fi
fi

if "$PARKED_BASELINE"; then
  step 'proving the maintenance-parked baseline before tag changes'
  # shellcheck disable=SC2016 # The substitution is evaluated by Android's shell.
  phone 'test "$(cat /data/docker/eip-cve-control/maintenance-v1 2>/dev/null)" = EIP_CVE_MAINTENANCE_V1' || \
    die 'parked redeploy requires active maintenance admission'
  PARKED_UI=$(phone "$PHONE_EIP ps -q ui" 2>/dev/null) || die 'cannot inspect parked UI state'
  PARKED_CHAT=$(phone "$PHONE_EIP ps -q chat" 2>/dev/null) || die 'cannot inspect parked chat state'
  [[ -z "${PARKED_UI//$'\r'/}" && -z "${PARKED_CHAT//$'\r'/}" ]] || \
    die 'parked redeploy requires ui and chat to be stopped'
else
  step 'proving the current ui and chat baseline before tag changes'
  CURRENT_UI_READY=false
  CURRENT_CHAT_READY=false
  service_observation ui "$PREVIOUS_IMAGE_ID" && CURRENT_UI_READY=true
  service_observation chat "$PREVIOUS_IMAGE_ID" && CURRENT_CHAT_READY=true
  if ! "$CURRENT_UI_READY" || ! "$CURRENT_CHAT_READY"; then
    die 'current ui and chat must both be healthy on the previous controller image before redeploy'
  fi
fi

step "retaining $PREVIOUS_IMAGE_ID as $ROLLBACK_TAG"
ROLLBACK_TAG_COMMAND_FAILED=false
phone "$PHONE_DOCKER tag $PREVIOUS_IMAGE_ID $ROLLBACK_TAG" || \
  ROLLBACK_TAG_COMMAND_FAILED=true
ROLLBACK_IMAGE_ID=$(phone_image_id "$ROLLBACK_TAG") || \
  die 'cannot verify the rollback tag postcondition; active image was not changed'
normalize_id "$ROLLBACK_IMAGE_ID" || die 'rollback controller image ID is malformed'
[[ "$NORMALIZED_ID" == "$PREVIOUS_IMAGE_ID" ]] || \
  die 'rollback tag does not retain the previous controller image; active image was not changed'
if "$ROLLBACK_TAG_COMMAND_FAILED"; then
  printf 'redeploy: rollback-tag command returned nonzero, but its exact postcondition is present\n' >&2
fi
if "$OPERATOR_CHANGE"; then
  step "retaining $PREVIOUS_OPERATOR_ID as $OPERATOR_ROLLBACK_TAG"
  phone "$PHONE_DOCKER tag $PREVIOUS_OPERATOR_ID $OPERATOR_ROLLBACK_TAG" || \
    die 'cannot retain the previous operator image; active tags were not changed'
  OPERATOR_ROLLBACK_ID=$(phone_image_id "$OPERATOR_ROLLBACK_TAG") || \
    die 'cannot verify the operator rollback tag; active tags were not changed'
  normalize_id "$OPERATOR_ROLLBACK_ID" || die 'operator rollback image ID is malformed'
  [[ "$NORMALIZED_ID" == "$PREVIOUS_OPERATOR_ID" ]] || \
    die 'operator rollback tag does not retain the previous image; active tags were not changed'
fi
ROLLBACK_ARMED=true

if ! "$PARKED_BASELINE"; then
  step 'stopping the previous stack before the managed-skills snapshot'
  if ! phone "$PHONE_EIP down"; then
    candidate_failed 'previous stack stop failed'
  fi
fi

step 'preserving the exact pre-release managed-skills tree'
MANAGED_PREPARE_COMMAND_FAILED=false
if phone "$PHONE_EIP managed-state prepare $MANAGED_TRANSACTION_ID"; then
  MANAGED_PREPARED=true
else
  MANAGED_PREPARE_COMMAND_FAILED=true
  if phone "$PHONE_EIP managed-state check-candidate $MANAGED_TRANSACTION_ID"; then
    MANAGED_PREPARED=true
  else
    candidate_failed 'managed-skills snapshot failed or its exact postcondition is absent'
  fi
fi
if "$MANAGED_PREPARE_COMMAND_FAILED"; then
  printf 'redeploy: managed-skills snapshot returned nonzero, but its exact postcondition is present\n' >&2
fi

if "$OPERATOR_CHANGE"; then
  step "promoting $OPERATOR_CANDIDATE_ID as $OPERATOR_ACTIVE_TAG"
  if ! phone "$PHONE_DOCKER tag $OPERATOR_CANDIDATE_ID $OPERATOR_ACTIVE_TAG"; then
    candidate_failed 'candidate operator promotion command returned nonzero'
  fi
  PROMOTED_OPERATOR_ID=$(phone_image_id "$OPERATOR_ACTIVE_TAG") || \
    candidate_failed 'cannot inspect the promoted operator image'
  if ! normalize_id "$PROMOTED_OPERATOR_ID" || [[ "$NORMALIZED_ID" != "$OPERATOR_CANDIDATE_ID" ]]; then
    candidate_failed 'active operator tag does not resolve to the manifest image'
  fi
fi

step "promoting $CANDIDATE_ID as $ACTIVE_TAG"
if ! phone "$PHONE_DOCKER tag $CANDIDATE_ID $ACTIVE_TAG"; then
  candidate_failed 'candidate promotion command returned nonzero'
fi
if ! PROMOTED_IMAGE_ID=$(phone_image_id "$ACTIVE_TAG"); then
  candidate_failed 'cannot inspect the promoted controller image'
fi
if ! normalize_id "$PROMOTED_IMAGE_ID" || [[ "$NORMALIZED_ID" != "$CANDIDATE_ID" ]]; then
  candidate_failed 'active controller tag does not resolve to the manifest image'
fi

step 'starting the candidate UI through the existing phone lifecycle'
if ! phone "$PHONE_EIP up --force-recreate --no-deps ui"; then
  candidate_failed 'candidate UI recreation failed'
fi

step 'waiting for UI health on the exact candidate image'
if ! wait_for_service ui "$CANDIDATE_ID"; then
  candidate_failed "UI did not become healthy on the candidate after $POLL_ATTEMPTS checks at $POLL_INTERVAL_SECONDS-second intervals"
fi

step "rebasing managed skills through Forge v4's existing release API (including its governed missing-QA backfill)"
if ! phone "$PHONE_EIP skills-release"; then
  candidate_failed 'Forge v4 managed-skills rebase failed'
fi
if ! phone "$PHONE_EIP managed-state check-candidate $MANAGED_TRANSACTION_ID"; then
  candidate_failed 'managed-skills release postcondition failed'
fi

step 'starting candidate chat after the v4 skill release completes'
if ! phone "$PHONE_EIP up --force-recreate --no-deps chat"; then
  candidate_failed 'candidate chat recreation failed'
fi

step 'waiting for UI and chat health on the exact candidate image'
if ! wait_for_services "$CANDIDATE_ID"; then
  candidate_failed "UI and chat did not become healthy on the candidate after $POLL_ATTEMPTS checks at $POLL_INTERVAL_SECONDS-second intervals"
fi
if ! phone "$SOURCE_OPS_RESTORE check-pending $SOURCE_REVISION $BUILDER_REVISION $SOURCE_SNAPSHOT_DIGEST"; then
  candidate_failed 'source and operations transaction changed during deployment'
fi

if "$PARKED_BASELINE"; then
  step 'reopening admission through the normal host lifecycle'
  if ! phone "$PHONE_HOSTCTL start"; then
    candidate_failed 'normal post-maintenance Forge start failed'
  fi
  FINAL_STATUS=$(phone "$PHONE_HOSTCTL status" 2>/dev/null) || \
    candidate_failed 'cannot read normal post-maintenance Forge status'
  FINAL_STATUS=${FINAL_STATUS//$'\r'/}
  if ! grep -qx 'system=ready' <<< "$FINAL_STATUS"; then
    candidate_failed 'normal post-maintenance Forge readiness was not proved'
  fi
fi

step 'finalizing the one-shot source and operations transaction'
SOURCE_FINALIZE_COMMAND_FAILED=false
phone "$SOURCE_OPS_RESTORE finalize $SOURCE_REVISION $BUILDER_REVISION $SOURCE_SNAPSHOT_DIGEST $CANDIDATE_ID" || \
  SOURCE_FINALIZE_COMMAND_FAILED=true
if "$SOURCE_FINALIZE_COMMAND_FAILED"; then
  if ! phone "$SOURCE_OPS_RESTORE finalize $SOURCE_REVISION $BUILDER_REVISION $SOURCE_SNAPSHOT_DIGEST $CANDIDATE_ID"; then
    candidate_failed 'source and operations transaction could not be finalized'
  fi
  printf 'redeploy: source and operations finalization returned nonzero, but its exact postcondition is present\n' >&2
fi

ROLLBACK_ARMED=false
trap - EXIT HUP INT TERM
printf 'healthy: ui and chat use %s\n' "$CANDIDATE_ID"
