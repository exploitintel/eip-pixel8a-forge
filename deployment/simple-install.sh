#!/bin/bash
set -euo pipefail

usage() {
  printf '%s\n' 'usage: install.sh --serial ADB_SERIAL [--wipe] [--disk-gib 64] [--provider-env FILE]'
}

die() {
  printf 'install: %s\n' "$*" >&2
  exit 1
}

CURRENT_STAGE='Checking arguments and package'
NEXT_ACTION='Check the arguments and package files, then run the installer again.'
STAGE_STARTED=$SECONDS
HEARTBEAT_PID=

stop_progress() {
  if [[ -n "$HEARTBEAT_PID" ]]; then
    kill "$HEARTBEAT_PID" 2>/dev/null || true
    wait "$HEARTBEAT_PID" 2>/dev/null || true
    HEARTBEAT_PID=
  fi
}

# shellcheck disable=SC2329 # Invoked by the EXIT trap.
finish() {
  local rc=$? elapsed=$((SECONDS - STAGE_STARTED))
  trap - EXIT
  stop_progress
  if ((rc != 0)); then
    printf 'install: failed during "%s" (exit %s, %dm%02ds elapsed).\nNext: %s\n' \
      "$CURRENT_STAGE" "$rc" "$((elapsed / 60))" "$((elapsed % 60))" "$NEXT_ACTION" >&2
  fi
  exit "$rc"
}
trap 'finish' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

stage() {
  stop_progress
  CURRENT_STAGE=$1
  NEXT_ACTION=$2
  STAGE_STARTED=$SECONDS
  printf '\n[%dm%02ds] %s\n' "$((SECONDS / 60))" "$((SECONDS % 60))" "$CURRENT_STAGE" >&2
  # Stderr keeps progress out of captured image IDs, UIDs and status output.
  (
    trap - EXIT
    tick=
    trap 'if [[ -n "$tick" ]]; then kill "$tick" 2>/dev/null || true; wait "$tick" 2>/dev/null || true; fi; exit 0' INT TERM
    while kill -0 "$$" 2>/dev/null; do
      sleep 15 & tick=$!
      wait "$tick"
      elapsed=$((SECONDS - STAGE_STARTED))
      printf 'Still working: %s - %dm%02ds elapsed in this stage.\n' \
        "$CURRENT_STAGE" "$((elapsed / 60))" "$((elapsed % 60))" >&2
    done
  ) &
  HEARTBEAT_PID=$!
}

require_value() {
  [[ -n "${2:-}" && "$2" != --* && "$2" != -h ]] || die "$1 requires a value (see --help)"
}

hash_file() {
  local output
  if command -v shasum >/dev/null 2>&1; then
    output=$(shasum -a 256 -- "$1") || die "cannot hash $1"
  elif command -v sha256sum >/dev/null 2>&1; then
    output=$(sha256sum -- "$1") || die "cannot hash $1"
  else
    die 'neither shasum nor sha256sum is installed'
  fi
  FILE_SHA256=${output%% *}
}

verify_file() {
  local file=$1 expected=$2 label=$3
  hash_file "$file"
  [[ "$FILE_SHA256" == "$expected" ]] || die "$label has the wrong SHA-256"
}

SERIAL=
DISK_GIB=64
DISK_GIB_SET=0
PROVIDER_ENV=
WIPE=0
EXPECTED_DEVICE=akita
EXPECTED_FINGERPRINT=google/akita/akita:17/CP2A.260805.005/15828068:user/release-keys
EXPECTED_ANDROID_VERSION=17
EXPECTED_SECURITY_PATCH=2026-08-05
while (($#)); do
  case "$1" in
    --serial) require_value "$@"; SERIAL=$2; shift 2 ;;
    --disk-gib) require_value "$@"; DISK_GIB=$2; DISK_GIB_SET=1; shift 2 ;;
    --provider-env) require_value "$@"; PROVIDER_ENV=$2; shift 2 ;;
    --wipe) WIPE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[[ -n "$SERIAL" ]] || die '--serial is required'
[[ -z "$PROVIDER_ENV" || -f "$PROVIDER_ENV" ]] || die "provider environment is missing: $PROVIDER_ENV"
case "$DISK_GIB" in 8|16|32|64) ;; *) die '--disk-gib must be 8, 16, 32, or 64' ;; esac
DISK_BYTES=$((DISK_GIB * 1024 * 1024 * 1024))

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
PAYLOAD=$SCRIPT_DIR/payload
for file in forge-control.apk forge-source.tar forge.lock host-module.zip kernel.lz4 \
  ksu-grant-profile ops.tar source-ops.tar source-ops.txt install-source-ops-phone.sh \
  restore-source-ops-phone.sh redeploy.sh deployment-manifest.json; do
  [[ -f "$PAYLOAD/$file" ]] || die "package file is missing: payload/$file"
done
LOCK_VERSION=$(sed -n 's/^LOCK_VERSION=//p' "$PAYLOAD/forge.lock")
[[ "$LOCK_VERSION" == 2 ]] || die 'payload/forge.lock has an unsupported version'
PIXEL_REVISION=$(sed -n 's/^PIXEL_REVISION=//p' "$PAYLOAD/forge.lock")
FORGE_REVISION=$(sed -n 's/^FORGE_REVISION=//p' "$PAYLOAD/forge.lock")
FORGE_SOURCE_SHA256=$(sed -n 's/^FORGE_SOURCE_SHA256=//p' "$PAYLOAD/forge.lock")
CONTROLLER_IMAGE=$(sed -n 's/^CONTROLLER_IMAGE=//p' "$PAYLOAD/forge.lock")
CONTROLLER_CONFIG_SHA256=$(sed -n 's/^CONTROLLER_CONFIG_SHA256=//p' "$PAYLOAD/forge.lock")
OPERATOR_IMAGE=$(sed -n 's/^OPERATOR_IMAGE=//p' "$PAYLOAD/forge.lock")
OPERATOR_CONFIG_SHA256=$(sed -n 's/^OPERATOR_CONFIG_SHA256=//p' "$PAYLOAD/forge.lock")
[[ "$PIXEL_REVISION" =~ ^[0-9a-f]{40}$ && "$FORGE_REVISION" =~ ^[0-9a-f]{40}$ ]] || \
  die 'payload/forge.lock has an invalid source revision'
for digest in "$FORGE_SOURCE_SHA256" "$CONTROLLER_CONFIG_SHA256" "$OPERATOR_CONFIG_SHA256"; do
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || die 'payload/forge.lock has an invalid digest'
done
[[ "$CONTROLLER_IMAGE" =~ ^ghcr\.io/exploitintel/eip-pixel8a-forge-controller@sha256:[0-9a-f]{64}$ ]] || \
  die 'payload/forge.lock has an invalid controller image reference'
[[ "$OPERATOR_IMAGE" =~ ^ghcr\.io/exploitintel/eip-pixel8a-forge-operator@sha256:[0-9a-f]{64}$ ]] || \
  die 'payload/forge.lock has an invalid operator image reference'
verify_file "$PAYLOAD/forge-source.tar" "$FORGE_SOURCE_SHA256" 'Forge source archive'
command -v unzip >/dev/null 2>&1 || die 'unzip is not installed'
PACKAGE_MODULE_ID=$(unzip -p "$PAYLOAD/host-module.zip" module.prop | sed -n 's/^id=//p')
PACKAGE_MODULE_VERSION=$(unzip -p "$PAYLOAD/host-module.zip" module.prop | sed -n 's/^version=//p')
[[ "$PACKAGE_MODULE_ID" == eip-pixel8a-forge ]] || die 'payload/host-module.zip has the wrong module ID'
[[ "$PACKAGE_MODULE_VERSION" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] || \
  die 'payload/host-module.zip has an invalid module version'

if [[ -n "${ADB:-}" ]]; then
  ADB_BIN=$ADB
elif command -v adb >/dev/null 2>&1; then
  ADB_BIN=$(command -v adb)
elif [[ -x "$HOME/Library/Android/sdk/platform-tools/adb" ]]; then
  ADB_BIN=$HOME/Library/Android/sdk/platform-tools/adb
else
  die 'adb is not installed'
fi

FASTBOOT_BIN=

resolve_fastboot() {
  if [[ -n "${FASTBOOT:-}" ]]; then
    FASTBOOT_BIN=$FASTBOOT
  elif command -v fastboot >/dev/null 2>&1; then
    FASTBOOT_BIN=$(command -v fastboot)
  elif [[ -x "$(dirname "$ADB_BIN")/fastboot" ]]; then
    FASTBOOT_BIN=$(dirname "$ADB_BIN")/fastboot
  else
    die 'fastboot is not installed'
  fi
}

phone() {
  local command=$1 quoted
  quoted=${command//\'/\'\\\'\'}
  "$ADB_BIN" -s "$SERIAL" shell -T "su -c '$quoted'"
}

push() {
  "$ADB_BIN" -s "$SERIAL" push "$1" "$2" >/dev/null
}

wait_android() {
  stage 'Waiting for Android to boot' 'Keep USB connected; check that Android boots and USB debugging is authorized.'
  "$ADB_BIN" -s "$SERIAL" wait-for-device
  local attempt
  for attempt in {1..90}; do
    if [[ $("$ADB_BIN" -s "$SERIAL" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r') == 1 ]]; then
      return 0
    fi
    sleep 2
  done
  die 'Android did not finish booting'
}

wait_fastboot() {
  stage 'Waiting for fastboot' 'Check the USB connection and whether the phone is on the bootloader screen.'
  local attempt
  for attempt in {1..60}; do
    "$FASTBOOT_BIN" devices | grep -q "^${SERIAL}[[:space:]]" && return 0
    sleep 1
  done
  die 'phone did not enter fastboot'
}

validate_android_target() {
  local device fingerprint android_version security_patch
  stage "Verifying supported phone $SERIAL" 'Boot the supported Pixel build, authorize USB debugging, and try again.'
  device=$("$ADB_BIN" -s "$SERIAL" shell getprop ro.product.device | tr -d '\r')
  fingerprint=$("$ADB_BIN" -s "$SERIAL" shell getprop ro.build.fingerprint | tr -d '\r')
  android_version=$("$ADB_BIN" -s "$SERIAL" shell getprop ro.build.version.release | tr -d '\r')
  security_patch=$("$ADB_BIN" -s "$SERIAL" shell getprop ro.build.version.security_patch | tr -d '\r')
  [[ "$device" == "$EXPECTED_DEVICE" ]] || die "unsupported device: ${device:-unavailable}"
  [[ "$fingerprint" == "$EXPECTED_FINGERPRINT" ]] || die "unsupported Android build: ${fingerprint:-unavailable}"
  [[ "$android_version" == "$EXPECTED_ANDROID_VERSION" ]] || die "unsupported Android version: ${android_version:-unavailable}"
  [[ "$security_patch" == "$EXPECTED_SECURITY_PATCH" ]] || die "unsupported security patch: ${security_patch:-unavailable}"
}

validate_fastboot_target() {
  local product
  product=$("$FASTBOOT_BIN" -s "$SERIAL" getvar product 2>&1 | sed -n 's/^product: //p')
  [[ "$product" == "$EXPECTED_DEVICE" ]] || die "unsupported fastboot product: ${product:-unavailable}"
}

make_shell_root_image() {
  local output_dir=$1
  command -v unzip >/dev/null 2>&1 || die 'unzip is not installed'
  unzip -p "$PAYLOAD/ksu-manager.apk" lib/arm64-v8a/libksud.so >"$output_dir/ksud"
  unzip -p "$PAYLOAD/ksu-manager.apk" lib/arm64-v8a/libadbroot.so >"$output_dir/libadbroot.so"
  chmod 700 "$output_dir/ksud"
  cp "$PAYLOAD/ksu-init-boot.img" "$output_dir/ksu-init-boot.img"
  [[ -s "$output_dir/ksu-init-boot.img" ]] || die 'KernelSU bootstrap image is empty'
  [[ $(wc -c < "$output_dir/ksu-init-boot.img" | tr -d ' ') == 8388608 ]] || \
    die 'KernelSU bootstrap image has the wrong size'
}

if ((WIPE)); then
  resolve_fastboot
  validate_android_target
  stage "Factory-wiping $SERIAL" 'Check the fastboot error above; do not interrupt an active wipe.'
  "$ADB_BIN" -s "$SERIAL" reboot bootloader >/dev/null 2>&1 || true
  wait_fastboot
  validate_fastboot_target
  stage 'Wiping Android user data' 'Check the fastboot error above before deciding whether to repeat the wipe.'
  "$FASTBOOT_BIN" -s "$SERIAL" -w
  "$FASTBOOT_BIN" -s "$SERIAL" reboot
  stop_progress
  printf 'WIPE COMPLETE\n'
  exit 0
fi

stage 'Waiting for Android setup and authorized USB debugging' 'Complete Android setup, enable USB debugging, authorize this computer, and keep USB connected.'
until "$ADB_BIN" -s "$SERIAL" shell true >/dev/null 2>&1; do
  sleep 2
done
validate_android_target

root_available() {
  [[ $($ADB_BIN -s "$SERIAL" shell "su -c 'id -u'" 2>/dev/null | tr -d '\r') == 0 ]]
}

bootstrap_root() {
  local slot bootstrap_dir
  resolve_fastboot
  stage 'Preparing KernelSU bootstrap' 'Check the package inputs and the USB error above.'
  bootstrap_dir=$(mktemp -d "${TMPDIR:-/tmp}/eip-forge-bootstrap.XXXXXX")
  make_shell_root_image "$bootstrap_dir"
  slot=$($ADB_BIN -s "$SERIAL" shell getprop ro.boot.slot_suffix | tr -d '\r' | sed 's/^_//')
  "$ADB_BIN" -s "$SERIAL" reboot bootloader >/dev/null 2>&1 || true
  wait_fastboot
  validate_fastboot_target
  case "$slot" in a|b) ;; *) die "cannot determine active slot: $slot" ;; esac

  stage "Bootstrapping KernelSU on slot $slot" 'Check the fastboot error and matching firmware inputs before recovery; do not guess a slot.'
  "$FASTBOOT_BIN" -s "$SERIAL" flash "boot_$slot" "$PAYLOAD/stock-boot.img"
  "$FASTBOOT_BIN" -s "$SERIAL" flash "init_boot_$slot" "$bootstrap_dir/ksu-init-boot.img"
  "$FASTBOOT_BIN" -s "$SERIAL" reboot
  wait_android

  stage 'Installing KernelSU userspace without UI' 'Check the bootstrap output above and whether Android completed booting.'
  push "$bootstrap_dir/ksud" /data/local/tmp/eip-ksud
  push "$bootstrap_dir/libadbroot.so" /data/local/tmp/eip-libadbroot.so
  "$ADB_BIN" -s "$SERIAL" shell chmod 700 /data/local/tmp/eip-ksud
  printf '%s\n' 'exec /data/local/tmp/eip-ksud install --libadbroot /data/local/tmp/eip-libadbroot.so' | \
    "$ADB_BIN" -s "$SERIAL" shell -T /data/local/tmp/eip-ksud debug su
  for attempt in {1..15}; do
    root_available && break
    sleep 2
  done
  root_available || die 'KernelSU userspace bootstrap did not provide shell root'

  stage 'Installing KernelSU Manager' 'Check the APK installation error and available phone storage.'
  "$ADB_BIN" -s "$SERIAL" install -r "$PAYLOAD/ksu-manager.apk" >/dev/null
  "$ADB_BIN" -s "$SERIAL" shell 'rm -f /data/local/tmp/eip-ksud /data/local/tmp/eip-libadbroot.so; pm grant com.rifsxd.ksunext android.permission.POST_NOTIFICATIONS >/dev/null 2>&1 || true'
  "$ADB_BIN" -s "$SERIAL" reboot >/dev/null 2>&1 || true
  wait_android
  rm -rf "$bootstrap_dir"
  root_available || die 'KernelSU shell root did not survive reboot'
}

require_fresh_payload() {
  local file
  for file in docker-engine.tgz stock-boot.img ksu-init-boot.img ksu-manager.apk; do
    [[ -f "$PAYLOAD/$file" ]] || die "fresh installation requires payload/$file"
  done
  verify_file "$PAYLOAD/stock-boot.img" 1a425630486ddc7150ac0669d1453cb20169c3df6d7db444929eedf8645db9eb 'stock boot image'
  verify_file "$PAYLOAD/ksu-init-boot.img" 9302c9957c191b6761ee06aacbd336641d2adae266d476b9272554bfb0a0a49e 'KernelSU init_boot image'
  verify_file "$PAYLOAD/ksu-manager.apk" fd0b12385c98fe9d5f4f1257b5f184e55c74c1376637507df0718305f5d7a924 'KernelSU Manager APK'
}

start_docker() {
  phone '/data/docker/bin/hostctl start'
}

enable_control_app() {
  local control_uid
  if [[ "$EXISTING_INSTALL" != true ]]; then
    control_uid=$("$ADB_BIN" -s "$SERIAL" shell 'pm list packages -U com.exploitintel.forgecontrol' \
      | tr -d '\r' | sed -n 's/.* uid://p')
    [[ "$control_uid" =~ ^[0-9]+$ ]] || die 'cannot determine Forge Control UID'
    push "$PAYLOAD/ksu-grant-profile" /data/local/tmp/eip-ksu-grant-profile
    phone "chmod 700 /data/local/tmp/eip-ksu-grant-profile; /data/local/tmp/eip-ksu-grant-profile $control_uid com.exploitintel.forgecontrol; rc=\$?; rm -f /data/local/tmp/eip-ksu-grant-profile; exit \$rc"
  fi
  phone 'pm grant com.exploitintel.forgecontrol android.permission.POST_NOTIFICATIONS >/dev/null 2>&1 || true'
  "$ADB_BIN" -s "$SERIAL" shell 'am start -n com.exploitintel.forgecontrol/.MainActivity >/dev/null'
}

pull_image() {
  local reference=$1 tag=$2 expected_id=$3 current_id
  stage "Downloading $tag" 'Check the phone Wi-Fi connection and public registry error above.'
  phone "DOCKER_HOST=unix:///data/docker/run/docker.sock /data/docker/bin/docker pull $reference"
  current_id=$(phone "DOCKER_HOST=unix:///data/docker/run/docker.sock /data/docker/bin/docker image inspect --format '{{.Id}}' $reference" | tr -d '\r')
  [[ "$current_id" == "sha256:$expected_id" ]] || die "$tag downloaded the wrong image ID"
  phone "DOCKER_HOST=unix:///data/docker/run/docker.sock /data/docker/bin/docker tag $reference $tag"
}

stage_source_ops_transaction() {
  local remote manifest_sha
  remote=/data/local/tmp/eip-source-ops-$FORGE_REVISION-$PIXEL_REVISION
  hash_file "$PAYLOAD/source-ops.txt"
  manifest_sha=$FILE_SHA256
  phone "rm -rf $remote"
  "$ADB_BIN" -s "$SERIAL" shell "mkdir -p $remote"
  push "$PAYLOAD/forge-source.tar" "$remote/source.tar"
  push "$PAYLOAD/source-ops.tar" "$remote/ops.tar"
  push "$PAYLOAD/source-ops.txt" "$remote/payload.txt"
  push "$PAYLOAD/install-source-ops-phone.sh" "$remote/install-source-ops-phone.sh"
  push "$PAYLOAD/restore-source-ops-phone.sh" "$remote/restore-source-ops-phone.sh"
  phone "chmod 0700 $remote $remote/install-source-ops-phone.sh; chmod 0600 $remote/source.tar $remote/ops.tar $remote/payload.txt $remote/restore-source-ops-phone.sh"
  phone "$remote/install-source-ops-phone.sh $remote $FORGE_REVISION $PIXEL_REVISION sha256:$FORGE_SOURCE_SHA256 sha256:$manifest_sha"
  phone "/data/eip-cve-backups/deploy-$FORGE_REVISION-$PIXEL_REVISION/restore-source-ops.sh check-pending $FORGE_REVISION $PIXEL_REVISION sha256:$FORGE_SOURCE_SHA256"
  phone "rm -rf $remote"
}

wait_until_parked() {
  local attempt state
  phone '/data/eip-cve-ops/eip-hostctl.sh park-when-idle'
  for attempt in {1..120}; do
    phone '/data/eip-cve-ops/eip-hostctl.sh reconcile' >/dev/null 2>&1 || true
    state=$(phone '/data/eip-cve-ops/eip-hostctl.sh status' 2>/dev/null | tr -d '\r' | sed -n 's/^system=//p') || true
    [[ "$state" == parked ]] && return 0
    sleep 5
  done
  phone '/data/eip-cve-ops/eip-hostctl.sh cancel-park-when-idle' >/dev/null 2>&1 || true
  die 'Forge did not become idle within 10 minutes; the pending park was cancelled'
}

configure_providers() {
  stage 'Configuring providers' 'Check the configuration error above and the supplied provider file format (KEY=VALUE); do not paste credentials into reports.'
  if [[ -n "$PROVIDER_ENV" ]]; then
    printf 'Installing provider configuration\n' >&2
    push "$PROVIDER_ENV" /data/local/tmp/eip-provider.env
    # shellcheck disable=SC2016 # Preserve the remote merge result through cleanup.
    phone '/data/eip-cve-ops/merge-env.sh < /data/local/tmp/eip-provider.env; rc=$?; rm -f /data/local/tmp/eip-provider.env; exit $rc'
  fi
}

install_control_app() {
  stage 'Installing Forge Control' 'Check the APK installation error and available phone storage.'
  "$ADB_BIN" -s "$SERIAL" install -r "$PAYLOAD/forge-control.apk" >/dev/null
}

stage "Checking root on $SERIAL" 'Check that Android is booted and KernelSU shell root is available.'
if ! root_available; then
  require_fresh_payload
  bootstrap_root
fi
root_available || die 'KernelSU root is not available'

EXISTING_INSTALL=false
if phone 'test -x /data/docker/bin/docker && test -f /data/docker/disk.img && test -f /data/docker/config/host.conf && test -f /data/eip-cve/container.env && test -x /data/eip-cve-ops/eip-hostctl.sh && pm path com.exploitintel.forgecontrol >/dev/null' >/dev/null 2>&1; then
  EXISTING_INSTALL=true
fi
HOST_MODULE_CURRENT=false
if phone "test \"\$(sed -n 's/^id=//p' /data/adb/modules/eip-pixel8a-forge/module.prop 2>/dev/null)\" = eip-pixel8a-forge && test \"\$(sed -n 's/^version=//p' /data/adb/modules/eip-pixel8a-forge/module.prop 2>/dev/null)\" = $PACKAGE_MODULE_VERSION" >/dev/null 2>&1; then
  HOST_MODULE_CURRENT=true
fi

if [[ "$EXISTING_INSTALL" == true ]]; then
  ((DISK_GIB_SET == 0)) || die '--disk-gib applies only to a fresh installation; the existing Docker disk was not changed'
  printf 'Qualified existing installation found; preserving Docker disk, Forge state, and provider configuration.\n' >&2
else
  require_fresh_payload
fi

if [[ "$HOST_MODULE_CURRENT" == false ]]; then
  if [[ "$EXISTING_INSTALL" == true ]]; then
    stage 'Parking Forge for the host update' 'Wait for active Forge work to finish, then retry if the idle window expires.'
    wait_until_parked
  fi
  stage 'Installing the Pixel Docker host' 'Check the module output above, package inputs, USB connection, and available phone storage.'
  if [[ -f "$PAYLOAD/docker-engine.tgz" ]]; then
    push "$PAYLOAD/docker-engine.tgz" /data/local/tmp/docker-29.8.0.tgz
  fi
  push "$PAYLOAD/kernel.lz4" /data/local/tmp/Image-CP2A.260805.005.lz4
  push "$PAYLOAD/host-module.zip" /data/local/tmp/eip-pixel8a-forge.zip
  phone '/data/adb/ksud module install /data/local/tmp/eip-pixel8a-forge.zip'
  if [[ "$EXISTING_INSTALL" == true ]]; then
    phone '/data/docker/bin/hostctl disk-init'
  else
    phone "/data/docker/bin/hostctl disk-init --size-bytes $DISK_BYTES"
  fi
  slot=$("$ADB_BIN" -s "$SERIAL" shell getprop ro.boot.slot_suffix | tr -d '\r')
  case "$slot" in _a|_b) ;; *) die "cannot determine active slot: $slot" ;; esac
  module_root=$(phone 'if test -x /data/adb/modules_update/eip-pixel8a-forge/bin/kernelctl; then printf /data/adb/modules_update/eip-pixel8a-forge; else printf /data/adb/modules/eip-pixel8a-forge; fi' | tr -d '\r')
  phone "KSU=true KSU_VER=3.3.0 KSU_VER_CODE=33214 KSU_RUNTIME_MODE=lkm $module_root/bin/kernelctl install INSTALL:CP2A.260805.005:$slot"
  phone 'rm -f /data/local/tmp/docker-29.8.0.tgz /data/local/tmp/Image-CP2A.260805.005.lz4 /data/local/tmp/eip-pixel8a-forge.zip'
  "$ADB_BIN" -s "$SERIAL" reboot >/dev/null 2>&1 || true
  wait_android
elif [[ "$EXISTING_INSTALL" == false ]]; then
  stage 'Preparing Docker storage' 'Check the host storage error above and select the existing disk size if this is a partial installation.'
  phone "/data/docker/bin/hostctl disk-init --size-bytes $DISK_BYTES"
fi

stage 'Starting Docker on the phone' 'Check the Docker startup output above and available phone storage.'
start_docker

if [[ "$EXISTING_INSTALL" == true ]]; then
  pull_image "$CONTROLLER_IMAGE" eip-cve-controller:phone "$CONTROLLER_CONFIG_SHA256"
  pull_image "$OPERATOR_IMAGE" eip-operator-shell:candidate "$OPERATOR_CONFIG_SHA256"
else
  pull_image "$CONTROLLER_IMAGE" eip-cve-controller:local "$CONTROLLER_CONFIG_SHA256"
  pull_image "$OPERATOR_IMAGE" eip-operator-shell:phone "$OPERATOR_CONFIG_SHA256"
fi
stage 'Downloading the pinned architecture handler' 'Check the phone Wi-Fi connection and registry error above.'
phone 'DOCKER_HOST=unix:///data/docker/run/docker.sock /data/docker/bin/docker pull tonistiigi/binfmt@sha256:400a4873b838d1b89194d982c45e5fb3cda4593fbfd7e08a02e76b03b21166f0'

if [[ "$EXISTING_INSTALL" == true ]]; then
  configure_providers
  install_control_app
  stage 'Waiting for current Forge work to finish' 'Forge remains available until its active work is idle; close new work and wait.'
  wait_until_parked
  stage 'Restarting Docker for the update' 'Forge remains parked; check the Docker startup error above.'
  start_docker
  stage 'Installing the matched Forge update' 'Check the source transaction error above; existing state is retained for rollback.'
  stage_source_ops_transaction
else
  stage 'Installing Forge source and phone commands' 'Check the archive or USB error above and available phone storage.'
  push "$PAYLOAD/forge-source.tar" /data/local/tmp/eip-forge-source.tar
  push "$PAYLOAD/ops.tar" /data/local/tmp/eip-forge-ops.tar
  phone 'rm -rf /data/eip-cve-src /data/eip-cve-ops; mkdir -p /data/eip-cve-src /data/eip-cve-ops; tar -xf /data/local/tmp/eip-forge-source.tar -C /data/eip-cve-src; tar -xf /data/local/tmp/eip-forge-ops.tar -C /data/eip-cve-ops; chmod 0755 /data/eip-cve-ops/*.sh /data/eip-cve-ops/*.py; rm -f /data/local/tmp/eip-forge-source.tar /data/local/tmp/eip-forge-ops.tar'
  stage 'Creating Forge state' 'Check the bootstrap output above and available phone storage.'
  phone '/data/eip-cve-ops/eip.sh bootstrap'
  phone '/data/eip-cve-ops/set-ollama.sh https://ollama.com'
  configure_providers
  install_control_app
fi

if [[ "$EXISTING_INSTALL" == true ]]; then
  stage 'Activating the Forge update' 'The previous images and source are retained automatically if the candidate does not become healthy.'
  env -u DOCKER_HOST ADB="$ADB_BIN" "$PAYLOAD/redeploy.sh" \
    --serial "$SERIAL" --manifest "$PAYLOAD/deployment-manifest.json" --parked
else
  stage 'Starting Forge WebUI' 'Check the UI startup output above and available phone storage.'
  phone '/data/eip-cve-ops/eip.sh up --force-recreate --no-deps ui'
  ui_ready=false
  for attempt in {1..30}; do
    if ui_status=$(phone '/data/eip-cve-ops/eip-hostctl.sh status' 2>/dev/null | tr -d '\r') && \
      printf '%s\n' "$ui_status" | grep -qx 'ui_health=healthy'; then
      ui_ready=true
      break
    fi
    sleep 5
  done
  if [[ "$ui_ready" != true ]]; then
    phone '/data/eip-cve-ops/eip.sh logs --no-color --tail 40 ui' || true
    phone '/data/eip-cve-ops/eip.sh down' || true
    die 'Forge WebUI did not become healthy for the managed-skills update'
  fi
  stage 'Updating managed skills' 'Check the managed-skills migration error above; no existing customization was reset.'
  if ! phone '/data/eip-cve-ops/eip.sh skills-release'; then
    phone '/data/eip-cve-ops/eip.sh logs --no-color --tail 40 ui' || true
    phone '/data/eip-cve-ops/eip.sh down' || true
    die 'managed-skills update failed'
  fi
  stage 'Starting Forge' 'Check the startup output above; use Forge Control Host details and logs to inspect the reported state.'
  phone '/data/eip-cve-ops/eip-hostctl.sh start'
fi
stage 'Waiting for Forge readiness' 'Check the status and logs above; use Forge Control Host details to identify the unhealthy service.'
# shellcheck disable=SC2034 # Fixed retry count; only the number of attempts matters.
for attempt in {1..60}; do
  if ready_status=$(phone '/data/eip-cve-ops/eip-hostctl.sh status' 2>/dev/null | tr -d '\r') && \
    printf '%s\n' "$ready_status" | grep -qx 'system=ready'; then
    stage 'Authorizing and opening Forge Control' 'Check the root-profile or app-launch error above.'
    enable_control_app
    credentials=$(phone '/data/eip-cve-ops/eip.sh password')
    ui_user=$(printf '%s\n' "$credentials" | sed -n 's/^EIP_CVE_UI_USER=//p')
    ui_password=$(printf '%s\n' "$credentials" | sed -n 's/^EIP_CVE_UI_PASSWORD=//p')
    [[ -n "$ui_user" && -n "$ui_password" ]] || die 'Forge WebUI credentials are unavailable'
    stop_progress
    printf '\nInstallation complete in %dm%02ds.\n' "$((SECONDS / 60))" "$((SECONDS % 60))"
    printf '%s\n' "$ready_status" | sed -n \
      -e 's/^docker=/Docker: /p' -e 's/^ui_health=/WebUI: /p' -e 's/^chat_health=/Agent chat: /p'
    if [[ -n "$PROVIDER_ENV" ]]; then
      printf 'Provider file: imported (credentials not tested upstream).\n'
    else
      printf 'Provider file: not supplied; no keys imported.\n'
    fi
    printf '\nForge WebUI login\n  Username: %s\n  Password: %s\n' "$ui_user" "$ui_password"
    printf 'Save this password. To show it again, run:\n  '
    printf '%q ' "$ADB_BIN" -s "$SERIAL" shell "su -c '/data/eip-cve-ops/eip.sh password'"
    printf '\n\n'
    printf 'Open Forge Control on the phone, then tap Open Forge WebUI.\n'
    printf 'READY\n'
    exit 0
  fi
  sleep 2
done

printf 'Last Forge status:\n%s\n' "${ready_status:-unavailable}" >&2
phone '/data/eip-cve-ops/eip-hostctl.sh logs' || true
die 'Forge did not become READY'
