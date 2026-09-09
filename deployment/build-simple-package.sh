#!/bin/bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: build-simple-package.sh \
  --forge-source DIR \
  --module ZIP \
  --kernel IMAGE \
  --ksu-grant-helper FILE \
  --image-lock FILE \
  --apk APK \
  [--engine TGZ] \
  [--ksu-apk APK] \
  [--stock-boot IMAGE --ksu-init-boot IMAGE] \
  --output DIR
EOF
}

die() {
  printf 'build-simple-package: %s\n' "$*" >&2
  exit 1
}

FORGE_SOURCE=
MODULE=
ENGINE=
KERNEL=
STOCK_BOOT=
KSU_INIT_BOOT=
KSU_APK=
KSU_GRANT_HELPER=
IMAGE_LOCK=
APK=
OUTPUT=

while (($#)); do
  case "$1" in
    --forge-source) FORGE_SOURCE=${2:-}; shift 2 ;;
    --module) MODULE=${2:-}; shift 2 ;;
    --engine) ENGINE=${2:-}; shift 2 ;;
    --kernel) KERNEL=${2:-}; shift 2 ;;
    --stock-boot) STOCK_BOOT=${2:-}; shift 2 ;;
    --ksu-init-boot) KSU_INIT_BOOT=${2:-}; shift 2 ;;
    --ksu-apk) KSU_APK=${2:-}; shift 2 ;;
    --ksu-grant-helper) KSU_GRANT_HELPER=${2:-}; shift 2 ;;
    --image-lock) IMAGE_LOCK=${2:-}; shift 2 ;;
    --apk) APK=${2:-}; shift 2 ;;
    --output) OUTPUT=${2:-}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

for value in FORGE_SOURCE MODULE KERNEL KSU_GRANT_HELPER IMAGE_LOCK APK OUTPUT; do
  [[ -n "${!value}" ]] || die "missing --${value,,}"
done
if [[ -n "$STOCK_BOOT" || -n "$KSU_INIT_BOOT" ]]; then
  [[ -n "$STOCK_BOOT" && -n "$KSU_INIT_BOOT" ]] || \
    die '--stock-boot and --ksu-init-boot must be supplied together'
fi
fresh_inputs=0
for value in ENGINE STOCK_BOOT KSU_INIT_BOOT KSU_APK; do
  [[ -z "${!value}" ]] || fresh_inputs=$((fresh_inputs + 1))
done
((fresh_inputs == 0 || fresh_inputs == 4)) || \
  die '--engine, --stock-boot, --ksu-init-boot, and --ksu-apk must be supplied together'
[[ -d "$FORGE_SOURCE" ]] || die "Forge source is not a directory: $FORGE_SOURCE"
for file in "$MODULE" "$KERNEL" "$KSU_GRANT_HELPER" "$IMAGE_LOCK" "$APK"; do
  [[ -f "$file" ]] || die "file is missing: $file"
done
if [[ -n "$ENGINE" ]]; then
  [[ -f "$ENGINE" ]] || die "file is missing: $ENGINE"
fi
if [[ -n "$KSU_APK" ]]; then
  [[ -f "$KSU_APK" ]] || die "file is missing: $KSU_APK"
fi
if [[ -n "$STOCK_BOOT" ]]; then
  [[ -f "$STOCK_BOOT" ]] || die "file is missing: $STOCK_BOOT"
  [[ -f "$KSU_INIT_BOOT" ]] || die "file is missing: $KSU_INIT_BOOT"
fi
[[ ! -e "$OUTPUT" ]] || die "output already exists: $OUTPUT"

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
PROJECT_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd -P)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/eip-simple-package.XXXXXX")
trap 'rm -rf -- "$WORK"' EXIT

for command in git tar python3; do
  command -v "$command" >/dev/null 2>&1 || die "$command is unavailable"
done

hash_file() {
  local output
  if command -v shasum >/dev/null 2>&1; then
    output=$(shasum -a 256 -- "$1") || die "cannot hash $1"
  elif command -v sha256sum >/dev/null 2>&1; then
    output=$(sha256sum -- "$1") || die "cannot hash $1"
  else
    die 'neither shasum nor sha256sum is available'
  fi
  HASH=${output%% *}
}

QUALIFIED_KERNEL_SHA256=$(python3 - "$PROJECT_ROOT/DEVICE.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    print(json.load(handle)["kernel"]["qualified_image_lz4_sha256"])
PY
) || die 'cannot read the qualified kernel identity'
hash_file "$KERNEL"
[[ "$HASH" == "$QUALIFIED_KERNEL_SHA256" ]] || \
  die 'kernel image does not match the qualified Pixel 8a kernel'

PIXEL_REVISION=$(git -C "$PROJECT_ROOT" rev-parse --verify HEAD 2>/dev/null) || \
  die 'cannot resolve Pixel source revision'
[[ "$PIXEL_REVISION" =~ ^[0-9a-f]{40}$ ]] || die 'Pixel source revision is invalid'
[[ -z $(git -C "$PROJECT_ROOT" status --porcelain=v1 --untracked-files=all --ignore-submodules=none) ]] || \
  die 'Pixel source must be clean before package assembly'
FORGE_REVISION=$(git -C "$FORGE_SOURCE" rev-parse --verify HEAD 2>/dev/null) || \
  die 'cannot resolve Forge source revision'
[[ "$FORGE_REVISION" =~ ^[0-9a-f]{40}$ ]] || die 'Forge source revision is invalid'
[[ -z $(git -C "$FORGE_SOURCE" status --porcelain=v1 --untracked-files=all --ignore-submodules=none) ]] || \
  die 'Forge source must be clean before package assembly'
PINNED_FORGE_REVISION=$(tr -d '\r\n' < "$PROJECT_ROOT/FORGE_REVISION")
[[ "$FORGE_REVISION" == "$PINNED_FORGE_REVISION" ]] || \
  die "Forge source must be the pinned revision $PINNED_FORGE_REVISION"
git -C "$FORGE_SOURCE" archive --format=tar HEAD > "$WORK/forge-source.tar"
hash_file "$WORK/forge-source.tar"
FORGE_SOURCE_SHA256=$HASH

IMAGE_LOCK_FIELDS=$(python3 - "$IMAGE_LOCK" <<'PY'
import re
import sys

path = sys.argv[1]
rows = {}
with open(path, encoding="utf-8") as handle:
    for raw in handle:
        line = raw.rstrip("\n")
        if not line or "=" not in line:
            raise SystemExit(2)
        key, value = line.split("=", 1)
        if key in rows:
            raise SystemExit(2)
        rows[key] = value
expected = {
    "LOCK_VERSION", "PIXEL_REVISION", "FORGE_REVISION", "FORGE_SOURCE_SHA256",
    "CONTROLLER_IMAGE", "CONTROLLER_CONFIG_SHA256", "OPERATOR_IMAGE",
    "OPERATOR_CONFIG_SHA256",
}
if set(rows) != expected or rows["LOCK_VERSION"] != "2":
    raise SystemExit(2)
revision = re.compile(r"[0-9a-f]{40}")
digest = re.compile(r"[0-9a-f]{64}")
controller = re.compile(r"ghcr[.]io/exploitintel/eip-pixel8a-forge-controller@sha256:[0-9a-f]{64}")
operator = re.compile(r"ghcr[.]io/exploitintel/eip-pixel8a-forge-operator@sha256:[0-9a-f]{64}")
if not revision.fullmatch(rows["PIXEL_REVISION"]) or not revision.fullmatch(rows["FORGE_REVISION"]):
    raise SystemExit(2)
if not digest.fullmatch(rows["FORGE_SOURCE_SHA256"]) or not digest.fullmatch(rows["CONTROLLER_CONFIG_SHA256"]) or not digest.fullmatch(rows["OPERATOR_CONFIG_SHA256"]):
    raise SystemExit(2)
if not controller.fullmatch(rows["CONTROLLER_IMAGE"]) or not operator.fullmatch(rows["OPERATOR_IMAGE"]):
    raise SystemExit(2)
print("|".join(rows[key] for key in (
    "PIXEL_REVISION", "FORGE_REVISION", "FORGE_SOURCE_SHA256",
    "CONTROLLER_CONFIG_SHA256", "OPERATOR_CONFIG_SHA256",
)))
PY
) || die 'image lock is malformed'
IFS='|' read -r LOCK_PIXEL_REVISION LOCK_FORGE_REVISION LOCK_FORGE_SOURCE_SHA256 \
  CONTROLLER_CONFIG_SHA256 OPERATOR_CONFIG_SHA256 \
  <<< "$IMAGE_LOCK_FIELDS"
[[ "$LOCK_PIXEL_REVISION" == "$PIXEL_REVISION" ]] || die 'image lock does not match the Pixel source revision'
[[ "$LOCK_FORGE_REVISION" == "$FORGE_REVISION" ]] || die 'image lock does not match the Forge source revision'
[[ "$LOCK_FORGE_SOURCE_SHA256" == "$FORGE_SOURCE_SHA256" ]] || \
  die 'image lock does not match the packaged Forge source'

mkdir -p "$OUTPUT/payload" "$WORK/ops"
cp "$SCRIPT_DIR/simple-install.sh" "$OUTPUT/install.sh"
cp "$SCRIPT_DIR/prepare-firmware.sh" "$OUTPUT/prepare-firmware.sh"
cp "$SCRIPT_DIR/SIMPLE-INSTALLER.md" "$OUTPUT/README.md"
cp "$MODULE" "$OUTPUT/payload/host-module.zip"
if [[ -n "$ENGINE" ]]; then
  cp "$ENGINE" "$OUTPUT/payload/docker-engine.tgz"
fi
cp "$KERNEL" "$OUTPUT/payload/kernel.lz4"
if [[ -n "$STOCK_BOOT" ]]; then
  cp "$STOCK_BOOT" "$OUTPUT/payload/stock-boot.img"
  cp "$KSU_INIT_BOOT" "$OUTPUT/payload/ksu-init-boot.img"
fi
if [[ -n "$KSU_APK" ]]; then
  cp "$KSU_APK" "$OUTPUT/payload/ksu-manager.apk"
fi
cp "$KSU_GRANT_HELPER" "$OUTPUT/payload/ksu-grant-profile"
cp "$APK" "$OUTPUT/payload/forge-control.apk"
cp "$WORK/forge-source.tar" "$OUTPUT/payload/forge-source.tar"
cp "$IMAGE_LOCK" "$OUTPUT/payload/forge.lock"
cp "$PROJECT_ROOT/eip/install-source-ops-phone.sh" "$OUTPUT/payload/install-source-ops-phone.sh"
cp "$PROJECT_ROOT/eip/restore-source-ops-phone.sh" "$OUTPUT/payload/restore-source-ops-phone.sh"
cp "$PROJECT_ROOT/eip/redeploy.sh" "$OUTPUT/payload/redeploy.sh"

cp "$PROJECT_ROOT/eip/compose.android.yaml" "$WORK/ops/compose.android.yaml"
cp "$PROJECT_ROOT/eip/operator-entry.sh" "$WORK/ops/entry.sh"
cp "$PROJECT_ROOT/eip/phone-eip.sh" "$WORK/ops/eip.sh"
cp "$PROJECT_ROOT/eip/eip-hostctl.sh" "$WORK/ops/eip-hostctl.sh"
cp "$PROJECT_ROOT/eip/hostctl-state.mjs" "$WORK/ops/hostctl-state.mjs"
cp "$PROJECT_ROOT/eip/rebase-managed-skills.py" "$WORK/ops/rebase-managed-skills.py"
cp "$PROJECT_ROOT/eip/redeploy-managed-state.sh" "$WORK/ops/redeploy-managed-state.sh"
cp "$PROJECT_ROOT/eip/preflight.sh" "$WORK/ops/preflight.sh"
cp "$PROJECT_ROOT/eip/fix-routing.sh" "$WORK/ops/fix-routing.sh"
cp "$PROJECT_ROOT/eip/merge-env.sh" "$WORK/ops/merge-env.sh"
cp "$PROJECT_ROOT/eip/set-ollama.sh" "$WORK/ops/set-ollama.sh"
cp "$PROJECT_ROOT/eip/set-ollama-key.sh" "$WORK/ops/set-ollama-key.sh"
chmod 0755 "$WORK/ops"/*.sh "$WORK/ops"/*.py
tar -C "$WORK/ops" -cf "$OUTPUT/payload/ops.tar" .
OPS_PATHS=(
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
git -C "$PROJECT_ROOT" archive --format=tar --output="$OUTPUT/payload/source-ops.tar" \
  "$PIXEL_REVISION" -- "${OPS_PATHS[@]}"

hash_path() {
  hash_file "$1"
  printf '%s' "$HASH"
}

hash_file "$OUTPUT/payload/source-ops.tar"
OPS_ARCHIVE_SHA256=$HASH
hash_file "$OUTPUT/payload/restore-source-ops-phone.sh"
RESTORE_HELPER_SHA256=$HASH
{
  printf 'schema_version=1\n'
  printf 'source_revision=%s\n' "$FORGE_REVISION"
  printf 'builder_revision=%s\n' "$PIXEL_REVISION"
  printf 'source_archive_sha256=%s\n' "$FORGE_SOURCE_SHA256"
  printf 'source_snapshot_digest=sha256:%s\n' "$FORGE_SOURCE_SHA256"
  printf 'ops_archive_sha256=%s\n' "$OPS_ARCHIVE_SHA256"
  printf 'restore_script_sha256=%s\n' "$RESTORE_HELPER_SHA256"
  printf 'source_compose_sha256=%s\n' "$(hash_path "$FORGE_SOURCE/deploy/container/compose.yaml")"
  printf 'source_verify_sha256=%s\n' "$(hash_path "$FORGE_SOURCE/deploy/container/verify.sh")"
  printf 'source_bootstrap_sha256=%s\n' "$(hash_path "$FORGE_SOURCE/deploy/container/bootstrap.sh")"
  printf 'source_package_sha256=%s\n' "$(hash_path "$FORGE_SOURCE/package.json")"
  printf 'ops_compose_sha256=%s\n' "$(hash_path "$PROJECT_ROOT/eip/compose.android.yaml")"
  printf 'ops_entry_sha256=%s\n' "$(hash_path "$PROJECT_ROOT/eip/operator-entry.sh")"
  printf 'ops_eip_sha256=%s\n' "$(hash_path "$PROJECT_ROOT/eip/phone-eip.sh")"
  printf 'ops_hostctl_sha256=%s\n' "$(hash_path "$PROJECT_ROOT/eip/eip-hostctl.sh")"
  printf 'ops_hostctl_state_sha256=%s\n' "$(hash_path "$PROJECT_ROOT/eip/hostctl-state.mjs")"
  printf 'ops_rebase_sha256=%s\n' "$(hash_path "$PROJECT_ROOT/eip/rebase-managed-skills.py")"
  printf 'ops_redeploy_state_sha256=%s\n' "$(hash_path "$PROJECT_ROOT/eip/redeploy-managed-state.sh")"
  printf 'ops_preflight_sha256=%s\n' "$(hash_path "$PROJECT_ROOT/eip/preflight.sh")"
  printf 'ops_fix_routing_sha256=%s\n' "$(hash_path "$PROJECT_ROOT/eip/fix-routing.sh")"
  printf 'ops_merge_env_sha256=%s\n' "$(hash_path "$PROJECT_ROOT/eip/merge-env.sh")"
  printf 'ops_set_ollama_sha256=%s\n' "$(hash_path "$PROJECT_ROOT/eip/set-ollama.sh")"
  printf 'ops_set_ollama_key_sha256=%s\n' "$(hash_path "$PROJECT_ROOT/eip/set-ollama-key.sh")"
} > "$OUTPUT/payload/source-ops.txt"

cat > "$OUTPUT/payload/deployment-manifest.json" <<EOF
{
  "schemaVersion": 1,
  "kind": "eip-controller-build-manifest",
  "provenanceLevel": "source-attributed",
  "scope": "release-images",
  "platform": "linux/arm64",
  "builder": { "revision": "$PIXEL_REVISION", "dirty": false },
  "controller": {
    "tag": "eip-cve-controller:phone",
    "imageId": "sha256:$CONTROLLER_CONFIG_SHA256",
    "sourceRevision": "$FORGE_REVISION",
    "sourceDirty": false,
    "sourceSnapshotDigest": "sha256:$FORGE_SOURCE_SHA256"
  },
  "operator": {
    "tag": "eip-operator-shell:candidate",
    "imageId": "sha256:$OPERATOR_CONFIG_SHA256"
  }
}
EOF
chmod 0755 "$OUTPUT/payload/install-source-ops-phone.sh" \
  "$OUTPUT/payload/restore-source-ops-phone.sh" "$OUTPUT/payload/redeploy.sh"
chmod 0755 "$OUTPUT/install.sh" "$OUTPUT/prepare-firmware.sh"

printf 'Package ready: %s\n' "$OUTPUT"
if [[ -n "$STOCK_BOOT" ]]; then
  printf 'Install with: %s/install.sh --serial ADB_SERIAL\n' "$OUTPUT"
else
  printf 'Prepare firmware with: %s/prepare-firmware.sh --factory-zip FILE --serial ADB_SERIAL\n' "$OUTPUT"
fi
