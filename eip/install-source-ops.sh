#!/bin/bash
# Install one clean, manifest-bound Forge source snapshot and the matching
# tracked Pixel ops files. The phone helper owns the directory transaction.
set -euo pipefail

ADB=$HOME/Library/Android/sdk/platform-tools/adb
SOURCE_PATH=
MANIFEST_PATH=
SERIAL=
SOURCE_SEEN=false
MANIFEST_SEEN=false
SERIAL_SEEN=false

usage() {
  printf '%s\n' \
    'usage: install-source-ops.sh --serial ADB_SERIAL --manifest CONTROLLER_BUILD.json --source FORGE_V4_GIT_ROOT'
}

die() {
  printf 'install-source-ops: %s\n' "$1" >&2
  exit 2
}

while (($# > 0)); do
  case "$1" in
    --serial)
      "$SERIAL_SEEN" && die '--serial may be specified only once'
      (($# >= 2)) || die '--serial requires a value'
      SERIAL=$2
      SERIAL_SEEN=true
      shift 2
      ;;
    --manifest)
      "$MANIFEST_SEEN" && die '--manifest may be specified only once'
      (($# >= 2)) || die '--manifest requires a value'
      MANIFEST_PATH=$2
      MANIFEST_SEEN=true
      shift 2
      ;;
    --source)
      "$SOURCE_SEEN" && die '--source may be specified only once'
      (($# >= 2)) || die '--source requires a value'
      SOURCE_PATH=$2
      SOURCE_SEEN=true
      shift 2
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

"$SERIAL_SEEN" || die '--serial is required'
"$MANIFEST_SEEN" || die '--manifest is required'
"$SOURCE_SEEN" || die '--source is required'
[[ "$SERIAL" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$ ]] || \
  die 'ADB serial must contain only letters, digits, dot, underscore, colon, or hyphen'
[[ -f "$MANIFEST_PATH" && ! -L "$MANIFEST_PATH" && -r "$MANIFEST_PATH" ]] || \
  die 'build manifest must be a readable regular file'
[[ -z "${DOCKER_HOST:-}" ]] || \
  die 'DOCKER_HOST must be unset; installation uses ADB and never Mac Docker'
for command_name in python3 git tar mktemp chmod cp; do
  command -v "$command_name" >/dev/null 2>&1 || die "$command_name is unavailable"
done
[[ -x "$ADB" ]] || die "adb is missing or not executable: $ADB"

SCRIPT_DIRECTORY=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || \
  die 'cannot resolve installer script directory'
EXPECTED_BUILDER_ROOT=$(cd -- "$SCRIPT_DIRECTORY/.." && pwd -P) || \
  die 'cannot resolve Pixel companion repository root'
BUILDER_ROOT=$(git -C "$EXPECTED_BUILDER_ROOT" rev-parse --show-toplevel 2>/dev/null) || \
  die 'Pixel companion repository is not a Git repository'
BUILDER_ROOT=$(cd -- "$BUILDER_ROOT" && pwd -P) || \
  die 'cannot resolve Pixel companion Git root'
[[ "$BUILDER_ROOT" == "$EXPECTED_BUILDER_ROOT" ]] || \
  die 'installer is not inside the Pixel companion Git root'

PHONE_INSTALLER=$BUILDER_ROOT/eip/install-source-ops-phone.sh
RESTORE_HELPER=$BUILDER_ROOT/eip/restore-source-ops-phone.sh
OPS_LOCAL_PATHS=(
  eip/compose.android.yaml
  eip/operator-entry.sh
  eip/phone-eip.sh
  eip/eip-hostctl.sh
  eip/hostctl-state.mjs
  eip/rebase-managed-skills.py
  eip/redeploy-managed-state.sh
  eip/preflight.sh
  eip/fix-routing.sh
  eip/merge-env.sh
  eip/set-ollama.sh
  eip/set-ollama-key.sh
)

for required_file in \
  "$PHONE_INSTALLER" "$RESTORE_HELPER" \
  "$BUILDER_ROOT/eip/install-source-ops.sh"; do
  relative_path=${required_file#"$BUILDER_ROOT"/}
  [[ -f "$required_file" && ! -L "$required_file" && -r "$required_file" ]] || \
    die "required tracked companion file is unavailable: $relative_path"
  git -C "$BUILDER_ROOT" ls-files --error-unmatch -- "$relative_path" >/dev/null 2>&1 || \
    die "required companion file is not tracked: $relative_path"
done
for relative_path in "${OPS_LOCAL_PATHS[@]}"; do
  [[ -f "$BUILDER_ROOT/$relative_path" && ! -L "$BUILDER_ROOT/$relative_path" && \
     -r "$BUILDER_ROOT/$relative_path" ]] || \
    die "tracked ops file is unavailable: $relative_path"
  git -C "$BUILDER_ROOT" ls-files --error-unmatch -- "$relative_path" >/dev/null 2>&1 || \
    die "ops file is not tracked: $relative_path"
done

MANIFEST_FIELDS=$(python3 - "$MANIFEST_PATH" <<'PY'
import json
import re
import sys

def reject(message):
    print(f"install-source-ops: invalid build input: {message}", file=sys.stderr)
    raise SystemExit(1)

def load(path, description):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        reject(f"{description}: {error}")

manifest = load(sys.argv[1], "build manifest")
if not isinstance(manifest, dict):
    reject("manifest root must be an object")
if type(manifest.get("schemaVersion")) is not int or manifest["schemaVersion"] != 1:
    reject("schemaVersion must be 1")
for key, expected in {
    "kind": "eip-controller-build-manifest",
    "provenanceLevel": "source-attributed",
    "scope": "controller-only",
    "platform": "linux/arm64",
}.items():
    if manifest.get(key) != expected:
        reject(f"{key} must be {expected}")
builder = manifest.get("builder")
controller = manifest.get("controller")
if not isinstance(builder, dict) or not isinstance(controller, dict):
    reject("builder and controller must be objects")
if builder.get("dirty") is not False or controller.get("sourceDirty") is not False:
    reject("installation requires clean Forge and companion source")
revision = re.compile(r"[0-9a-f]{40}")
digest = re.compile(r"sha256:[0-9a-f]{64}")
if controller.get("tag") != "eip-cve-controller:phone":
    reject("controller tag must be eip-cve-controller:phone")
if not isinstance(controller.get("imageId"), str) or not digest.fullmatch(controller["imageId"]):
    reject("controller imageId is malformed")
source_revision = controller.get("sourceRevision")
builder_revision = builder.get("revision")
source_digest = controller.get("sourceSnapshotDigest")
if not isinstance(source_revision, str) or not revision.fullmatch(source_revision):
    reject("controller sourceRevision is malformed")
if not isinstance(builder_revision, str) or not revision.fullmatch(builder_revision):
    reject("builder revision is malformed")
if not isinstance(source_digest, str) or not digest.fullmatch(source_digest):
    reject("controller sourceSnapshotDigest is malformed")

print("|".join((source_revision, builder_revision, source_digest)))
PY
) || die 'build manifest validation failed'
IFS='|' read -r SOURCE_REVISION BUILDER_REVISION SOURCE_SNAPSHOT_DIGEST EXTRA_FIELD \
  <<< "$MANIFEST_FIELDS"
[[ -z "$EXTRA_FIELD" && "$MANIFEST_FIELDS" == \
   "$SOURCE_REVISION|$BUILDER_REVISION|$SOURCE_SNAPSHOT_DIGEST" ]] || \
  die 'validated build fields are malformed'

resolve_git_root() {
  local candidate=$1
  local description=$2
  local physical top top_physical

  [[ -d "$candidate" ]] || die "$description is not a directory"
  physical=$(cd -- "$candidate" && pwd -P) || die "cannot resolve $description"
  top=$(git -C "$physical" rev-parse --show-toplevel 2>/dev/null) || \
    die "$description is not a Git repository"
  top_physical=$(cd -- "$top" && pwd -P) || die "cannot resolve $description Git root"
  [[ "$physical" == "$top_physical" ]] || die "$description must be the Git top-level directory"
  RESOLVED_GIT_ROOT=$physical
}

assert_clean_revision() {
  local repository=$1
  local expected_revision=$2
  local description=$3
  local revision status_output

  revision=$(git -C "$repository" rev-parse --verify HEAD 2>/dev/null) || \
    die "cannot resolve $description HEAD"
  [[ "$revision" =~ ^[0-9a-f]{40}$ ]] || die "$description HEAD is not a full commit ID"
  [[ "$revision" == "$expected_revision" ]] || \
    die "$description HEAD does not match the build manifest"
  status_output=$(git -C "$repository" status --porcelain=v1 \
    --untracked-files=all --ignore-submodules=none 2>/dev/null) || \
    die "cannot inspect $description worktree state"
  [[ -z "$status_output" ]] || die "$description must be clean"
}

resolve_git_root "$SOURCE_PATH" 'Forge v4 source'
SOURCE_ROOT=$RESOLVED_GIT_ROOT
assert_clean_revision "$SOURCE_ROOT" "$SOURCE_REVISION" 'Forge v4 source'
assert_clean_revision "$BUILDER_ROOT" "$BUILDER_REVISION" 'Pixel companion repository'

SOURCE_REQUIRED=(
  .dockerignore
  deploy/container/Dockerfile
  deploy/container/compose.yaml
  deploy/container/verify.sh
  deploy/container/bootstrap.sh
  package.json
  package-lock.json
)
for relative_path in "${SOURCE_REQUIRED[@]}"; do
  [[ -f "$SOURCE_ROOT/$relative_path" && ! -L "$SOURCE_ROOT/$relative_path" && \
     -r "$SOURCE_ROOT/$relative_path" ]] || \
    die "required Forge source file is unavailable: $relative_path"
  git -C "$SOURCE_ROOT" ls-files --error-unmatch -- "$relative_path" >/dev/null 2>&1 || \
    die "required Forge source file is not tracked: $relative_path"
done

TEMP_PARENT_ARGUMENT=${TMPDIR:-/tmp}
[[ -d "$TEMP_PARENT_ARGUMENT" && -w "$TEMP_PARENT_ARGUMENT" ]] || \
  die 'temporary directory is unavailable'
TEMP_PARENT=$(cd -- "$TEMP_PARENT_ARGUMENT" && pwd -P) || \
  die 'cannot resolve temporary directory'
umask 077
WORK_ROOT=$(mktemp -d "$TEMP_PARENT/eip-source-ops.XXXXXX") || \
  die 'cannot create installation workspace'
chmod 700 "$WORK_ROOT" || die 'cannot protect installation workspace'
SOURCE_ARCHIVE=$WORK_ROOT/source.tar
OPS_ARCHIVE=$WORK_ROOT/ops.tar
PAYLOAD_MANIFEST=$WORK_ROOT/payload.txt
PHONE_INSTALLER_COPY=$WORK_ROOT/install-source-ops-phone.sh
RESTORE_HELPER_COPY=$WORK_ROOT/restore-source-ops-phone.sh
REMOTE_PAYLOAD=/data/local/tmp/eip-source-ops-$SOURCE_REVISION-$BUILDER_REVISION
BACKUP=/data/eip-cve-backups/deploy-$SOURCE_REVISION-$BUILDER_REVISION
REMOTE_MAY_EXIST=false

phone() {
  local command=$1
  local quoted_command=${command//\'/\'\\\'\'}
  "$ADB" -s "$SERIAL" shell -T "su -c '$quoted_command'"
}

cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM
  if "$REMOTE_MAY_EXIST"; then
    phone "rm -rf $REMOTE_PAYLOAD" >/dev/null 2>&1 || true
  fi
  rm -rf -- "$WORK_ROOT"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

hash_file() {
  local output
  if command -v shasum >/dev/null 2>&1; then
    output=$(shasum -a 256 -- "$1" 2>/dev/null) || return 1
  elif command -v sha256sum >/dev/null 2>&1; then
    output=$(sha256sum -- "$1" 2>/dev/null) || return 1
  else
    return 1
  fi
  HASH_VALUE=${output%%[[:space:]]*}
  [[ "$HASH_VALUE" =~ ^[0-9a-f]{64}$ ]]
}

git -C "$SOURCE_ROOT" archive --format=tar --output="$SOURCE_ARCHIVE" \
  "$SOURCE_REVISION" || die 'cannot create the manifest-bound Forge source archive'
hash_file "$SOURCE_ARCHIVE" || die 'cannot hash the Forge source archive'
SOURCE_ARCHIVE_SHA256=$HASH_VALUE
[[ "sha256:$SOURCE_ARCHIVE_SHA256" == "$SOURCE_SNAPSHOT_DIGEST" ]] || \
  die 'Forge source archive does not match the controller source snapshot digest'

git -C "$BUILDER_ROOT" archive --format=tar --output="$OPS_ARCHIVE" \
  "$BUILDER_REVISION" -- "${OPS_LOCAL_PATHS[@]}" || \
  die 'cannot create the revision-bound Pixel ops archive'
hash_file "$OPS_ARCHIVE" || die 'cannot hash the Pixel ops archive'
OPS_ARCHIVE_SHA256=$HASH_VALUE
cp -- "$PHONE_INSTALLER" "$PHONE_INSTALLER_COPY" || die 'cannot stage the phone installer'
cp -- "$RESTORE_HELPER" "$RESTORE_HELPER_COPY" || die 'cannot stage the rollback helper'
chmod 600 "$PHONE_INSTALLER_COPY" "$RESTORE_HELPER_COPY" || \
  die 'cannot protect staged phone helpers'
hash_file "$RESTORE_HELPER_COPY" || die 'cannot hash the rollback helper'
RESTORE_HELPER_SHA256=$HASH_VALUE

hash_path() {
  hash_file "$1" || die "cannot hash tracked payload file: $1"
  printf '%s' "$HASH_VALUE"
}

{
  printf 'schema_version=1\n'
  printf 'source_revision=%s\n' "$SOURCE_REVISION"
  printf 'builder_revision=%s\n' "$BUILDER_REVISION"
  printf 'source_archive_sha256=%s\n' "$SOURCE_ARCHIVE_SHA256"
  printf 'source_snapshot_digest=%s\n' "$SOURCE_SNAPSHOT_DIGEST"
  printf 'ops_archive_sha256=%s\n' "$OPS_ARCHIVE_SHA256"
  printf 'restore_script_sha256=%s\n' "$RESTORE_HELPER_SHA256"
  printf 'source_compose_sha256=%s\n' "$(hash_path "$SOURCE_ROOT/deploy/container/compose.yaml")"
  printf 'source_verify_sha256=%s\n' "$(hash_path "$SOURCE_ROOT/deploy/container/verify.sh")"
  printf 'source_bootstrap_sha256=%s\n' "$(hash_path "$SOURCE_ROOT/deploy/container/bootstrap.sh")"
  printf 'source_package_sha256=%s\n' "$(hash_path "$SOURCE_ROOT/package.json")"
  printf 'ops_compose_sha256=%s\n' "$(hash_path "$BUILDER_ROOT/eip/compose.android.yaml")"
  printf 'ops_entry_sha256=%s\n' "$(hash_path "$BUILDER_ROOT/eip/operator-entry.sh")"
  printf 'ops_eip_sha256=%s\n' "$(hash_path "$BUILDER_ROOT/eip/phone-eip.sh")"
  printf 'ops_hostctl_sha256=%s\n' "$(hash_path "$BUILDER_ROOT/eip/eip-hostctl.sh")"
  printf 'ops_hostctl_state_sha256=%s\n' "$(hash_path "$BUILDER_ROOT/eip/hostctl-state.mjs")"
  printf 'ops_rebase_sha256=%s\n' "$(hash_path "$BUILDER_ROOT/eip/rebase-managed-skills.py")"
  printf 'ops_redeploy_state_sha256=%s\n' "$(hash_path "$BUILDER_ROOT/eip/redeploy-managed-state.sh")"
  printf 'ops_preflight_sha256=%s\n' "$(hash_path "$BUILDER_ROOT/eip/preflight.sh")"
  printf 'ops_fix_routing_sha256=%s\n' "$(hash_path "$BUILDER_ROOT/eip/fix-routing.sh")"
  printf 'ops_merge_env_sha256=%s\n' "$(hash_path "$BUILDER_ROOT/eip/merge-env.sh")"
  printf 'ops_set_ollama_sha256=%s\n' "$(hash_path "$BUILDER_ROOT/eip/set-ollama.sh")"
  printf 'ops_set_ollama_key_sha256=%s\n' "$(hash_path "$BUILDER_ROOT/eip/set-ollama-key.sh")"
} > "$PAYLOAD_MANIFEST" || die 'cannot write the phone payload manifest'
chmod 600 "$PAYLOAD_MANIFEST" || die 'cannot protect the phone payload manifest'
hash_file "$PAYLOAD_MANIFEST" || die 'cannot hash the phone payload manifest'
PAYLOAD_MANIFEST_SHA256=$HASH_VALUE

# Recheck both trees after all revision-bound bytes have been frozen.
assert_clean_revision "$SOURCE_ROOT" "$SOURCE_REVISION" 'Forge v4 source'
assert_clean_revision "$BUILDER_ROOT" "$BUILDER_REVISION" 'Pixel companion repository'

phone "test ! -e $REMOTE_PAYLOAD && install -d -m 0700 -o 2000 -g 2000 $REMOTE_PAYLOAD" || \
  die 'cannot create a fresh protected phone payload directory'
REMOTE_MAY_EXIST=true

push_payload() {
  local local_path=$1
  local remote_name=$2

  "$ADB" -s "$SERIAL" push "$local_path" "$REMOTE_PAYLOAD/$remote_name" \
    >/dev/null || die "cannot transfer phone payload file: $remote_name"
}

push_payload "$SOURCE_ARCHIVE" source.tar
push_payload "$OPS_ARCHIVE" ops.tar
push_payload "$PAYLOAD_MANIFEST" payload.txt
push_payload "$PHONE_INSTALLER_COPY" install-source-ops-phone.sh
push_payload "$RESTORE_HELPER_COPY" restore-source-ops-phone.sh
phone "chown 0:0 $REMOTE_PAYLOAD $REMOTE_PAYLOAD/source.tar $REMOTE_PAYLOAD/ops.tar $REMOTE_PAYLOAD/payload.txt $REMOTE_PAYLOAD/install-source-ops-phone.sh $REMOTE_PAYLOAD/restore-source-ops-phone.sh && chmod 0700 $REMOTE_PAYLOAD && chmod 0700 $REMOTE_PAYLOAD/install-source-ops-phone.sh && chmod 0600 $REMOTE_PAYLOAD/source.tar $REMOTE_PAYLOAD/ops.tar $REMOTE_PAYLOAD/payload.txt $REMOTE_PAYLOAD/restore-source-ops-phone.sh" || \
  die 'cannot protect the transferred phone payload'

INSTALL_COMMAND_FAILED=false
phone "$REMOTE_PAYLOAD/install-source-ops-phone.sh $REMOTE_PAYLOAD $SOURCE_REVISION $BUILDER_REVISION $SOURCE_SNAPSHOT_DIGEST sha256:$PAYLOAD_MANIFEST_SHA256" || \
  INSTALL_COMMAND_FAILED=true
if ! phone "$BACKUP/restore-source-ops.sh check-pending $SOURCE_REVISION $BUILDER_REVISION $SOURCE_SNAPSHOT_DIGEST"; then
  die 'phone source and operations transaction failed or its exact postcondition is absent'
fi
if "$INSTALL_COMMAND_FAILED"; then
  printf 'install-source-ops: phone installer returned nonzero, but its exact postcondition is present\n' >&2
fi

phone "rm -rf $REMOTE_PAYLOAD" || die 'cannot remove the phone payload directory'
REMOTE_MAY_EXIST=false
printf 'installed source %s and Pixel operations %s; rollback retained at %s\n' \
  "$SOURCE_REVISION" "$BUILDER_REVISION" "$BACKUP"
