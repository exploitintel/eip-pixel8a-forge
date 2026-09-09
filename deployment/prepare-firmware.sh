#!/bin/bash
set -euo pipefail

usage() {
  printf '%s\n' 'usage: prepare-firmware.sh --factory-zip FILE --serial ADB_SERIAL'
}

die() {
  printf 'prepare-firmware: %s\n' "$*" >&2
  exit 1
}

require_value() {
  [[ -n "${2:-}" && "$2" != --* && "$2" != -h ]] || die "$1 requires a value (see --help)"
}

FACTORY_ZIP=
SERIAL=
while (($#)); do
  case "$1" in
    --factory-zip) require_value "$@"; FACTORY_ZIP=$2; shift 2 ;;
    --serial) require_value "$@"; SERIAL=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "$FACTORY_ZIP" ]] || die '--factory-zip is required'
[[ -f "$FACTORY_ZIP" ]] || die "factory ZIP is missing: $FACTORY_ZIP"
[[ -n "$SERIAL" ]] || die '--serial is required'

for command in unzip curl; do
  command -v "$command" >/dev/null 2>&1 || die "$command is not installed"
done

if [[ -n "${ADB:-}" ]]; then
  ADB_BIN=$ADB
elif command -v adb >/dev/null 2>&1; then
  ADB_BIN=$(command -v adb)
elif [[ -x "$HOME/Library/Android/sdk/platform-tools/adb" ]]; then
  ADB_BIN=$HOME/Library/Android/sdk/platform-tools/adb
else
  die 'adb is not installed'
fi

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
PAYLOAD=$SCRIPT_DIR/payload
mkdir -p "$PAYLOAD"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/eip-forge-firmware.XXXXXX")
REMOTE_KSUD=/data/local/tmp/eip-prepare-ksud
REMOTE_INIT=/data/local/tmp/eip-prepare-init-boot.img
REMOTE_OUTPUT=/data/local/tmp/eip-prepare-ksu-init-boot.img
cleanup() {
  rm -rf -- "$WORK"
  "$ADB_BIN" -s "$SERIAL" shell "rm -f $REMOTE_KSUD $REMOTE_INIT $REMOTE_OUTPUT" >/dev/null 2>&1 || true
}
trap cleanup EXIT

hash_file() {
  local output
  if command -v shasum >/dev/null 2>&1; then
    output=$(shasum -a 256 -- "$1") || die "cannot hash $1"
  elif command -v sha256sum >/dev/null 2>&1; then
    output=$(sha256sum -- "$1") || die "cannot hash $1"
  else
    die 'neither shasum nor sha256sum is installed'
  fi
  HASH=${output%% *}
}

download_input() {
  local url=$1 expected=$2 destination=$3 label=$4 temporary
  if [[ -f "$destination" ]]; then
    hash_file "$destination"
    [[ "$HASH" == "$expected" ]] || die "$label exists but has the wrong SHA-256: $destination"
    return
  fi
  temporary=$destination.download
  rm -f -- "$temporary"
  printf 'Downloading pinned %s...\n' "$label"
  curl --fail --location --retry 3 --output "$temporary" "$url"
  hash_file "$temporary"
  [[ "$HASH" == "$expected" ]] || die "downloaded $label has the wrong SHA-256"
  mv -- "$temporary" "$destination"
}

download_input \
  'https://download.docker.com/linux/static/stable/aarch64/docker-29.8.0.tgz' \
  '1462a696be6029bd478d7d60d7f3c31cdd15affd1178a4a278aaf4a1d1b7f8b5' \
  "$PAYLOAD/docker-engine.tgz" 'Docker Engine 29.8.0 for AArch64'
download_input \
  'https://github.com/KernelSU-Next/KernelSU-Next/releases/download/v3.3.0/KernelSU_Next_v3.3.0_33214-release.apk' \
  'fd0b12385c98fe9d5f4f1257b5f184e55c74c1376637507df0718305f5d7a924' \
  "$PAYLOAD/ksu-manager.apk" 'KernelSU-Next 3.3.0 Manager'

NESTED_IMAGE=
while IFS= read -r entry; do
  case "$entry" in
    image-akita-*.zip|*/image-akita-*.zip)
      [[ -z "$NESTED_IMAGE" ]] || die 'factory ZIP contains more than one akita image archive'
      NESTED_IMAGE=$entry
      ;;
  esac
done < <(unzip -Z1 "$FACTORY_ZIP")
[[ -n "$NESTED_IMAGE" ]] || die 'this is not the Pixel 8a akita factory ZIP'

printf 'Extracting Google build CP2A.260805.005...\n'
unzip -p "$FACTORY_ZIP" "$NESTED_IMAGE" >"$WORK/image-akita.zip"
unzip -p "$WORK/image-akita.zip" boot.img >"$WORK/boot.img"
unzip -p "$WORK/image-akita.zip" init_boot.img >"$WORK/init_boot.img"

hash_file "$WORK/boot.img"
[[ "$HASH" == 1a425630486ddc7150ac0669d1453cb20169c3df6d7db444929eedf8645db9eb ]] || \
  die 'boot.img does not match Google build CP2A.260805.005'
hash_file "$WORK/init_boot.img"
[[ "$HASH" == 135b2402dfe4199a127a02883984ad6958dae302ab1c4db2b469e49d1ec4a60c ]] || \
  die 'init_boot.img does not match Google build CP2A.260805.005'

printf 'Preparing the matching KernelSU image on the connected phone...\n'
unzip -p "$PAYLOAD/ksu-manager.apk" lib/arm64-v8a/libksud.so >"$WORK/ksud"
chmod 700 "$WORK/ksud"
"$ADB_BIN" -s "$SERIAL" get-state >/dev/null
"$ADB_BIN" -s "$SERIAL" push "$WORK/ksud" "$REMOTE_KSUD" >/dev/null
"$ADB_BIN" -s "$SERIAL" push "$WORK/init_boot.img" "$REMOTE_INIT" >/dev/null
"$ADB_BIN" -s "$SERIAL" shell "chmod 700 $REMOTE_KSUD && $REMOTE_KSUD boot-patch --boot $REMOTE_INIT --kmi android14-6.1 --allow-shell --out /data/local/tmp --out-name eip-prepare-ksu-init-boot.img" >/dev/null
"$ADB_BIN" -s "$SERIAL" pull "$REMOTE_OUTPUT" "$WORK/ksu-init-boot.img" >/dev/null

hash_file "$WORK/ksu-init-boot.img"
[[ "$HASH" == 9302c9957c191b6761ee06aacbd336641d2adae266d476b9272554bfb0a0a49e ]] || \
  die 'KernelSU output does not match the qualified KernelSU-Next 3.3.0 image'

install -m 0644 "$WORK/boot.img" "$PAYLOAD/stock-boot.img"
install -m 0644 "$WORK/ksu-init-boot.img" "$PAYLOAD/ksu-init-boot.img"

printf '%s\n' 'Firmware preparation complete.'
printf '%s\n' 'Next: run ./install.sh --serial ADB_SERIAL --wipe'
