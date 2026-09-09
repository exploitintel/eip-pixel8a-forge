#!/usr/bin/env bash
# Build the Pixel 8a Android 17 Docker kernel from the exact Google common source.
set -euo pipefail

kernel_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
commit=bd23337e42e794964a89f47596daf1209a25ee1a
source_sha=b0cd75af3d749e3b866fd600815049c4c6542740175808c045acb926a4dfa000
expected_release=6.1.157-android14-11-gbd23337e42e7-ab14791245
stock_config="$kernel_dir/configs/CP2A.260805.005.stock.config"
fragment="$kernel_dir/fragments/docker.config"
patches_dir="$kernel_dir/patches"
expected_config="$kernel_dir/kernel.config"
image_tag=eip-pixel8a-kernel-buildenv:pinned
tarball=
out_dir=
jobs=$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)

usage() {
  echo "usage: kernel/build.sh --tarball FILE --out DIR [--jobs N]" >&2
  exit 2
}

fail() {
  echo "build.sh: $*" >&2
  exit 1
}

digest() {
  shasum -a 256 "$1" | awk '{print $1}'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --tarball) [ "$#" -ge 2 ] || usage; tarball=$2; shift 2 ;;
    --out) [ "$#" -ge 2 ] || usage; out_dir=$2; shift 2 ;;
    --jobs) [ "$#" -ge 2 ] || usage; jobs=$2; shift 2 ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done

[ -n "$tarball" ] && [ -n "$out_dir" ] || usage
[ -f "$tarball" ] || fail "source archive not found: $tarball"
[ "$(digest "$tarball")" = "$source_sha" ] || fail "source archive SHA-256 mismatch"
[ -f "$stock_config" ] || fail "stock config not found: $stock_config"
[ -f "$fragment" ] || fail "Docker fragment not found: $fragment"
[ -d "$patches_dir" ] || fail "patch directory not found: $patches_dir"
[ ! -e "$out_dir" ] || fail "output already exists: $out_dir"
command -v docker >/dev/null || fail "Docker is required"
command -v python3 >/dev/null || fail "python3 is required"
docker info >/dev/null 2>&1 || fail "Docker daemon is not running"

qualified_image_lz4_sha=$(python3 - "$kernel_dir/../DEVICE.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    print(json.load(handle)["kernel"]["qualified_image_lz4_sha256"])
PY
) || fail "cannot read the qualified kernel identity"

stage=$(mktemp -d "${TMPDIR:-/tmp}/eip-pixel8a-kernel.XXXXXX")
volume="eip-pixel8a-ksrc-${commit:0:12}"
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/patches" "$out_dir"
cp "$stock_config" "$stage/stock.config"
cp "$fragment" "$stage/fragment.config"
cp "$patches_dir"/*.patch "$stage/patches/"

if ! docker image inspect "$image_tag" >/dev/null 2>&1; then
  echo "build.sh: building Linux toolchain image"
  docker build -q -f "$kernel_dir/Dockerfile.buildenv" -t "$image_tag" "$kernel_dir" >/dev/null
fi

marker="$source_sha $(cat "$patches_dir"/*.patch | shasum -a 256 | awk '{print $1}') symbollist=v1"
current=$(docker run --rm -v "$volume:/ksrc" "$image_tag" sh -c 'cat /ksrc/.source 2>/dev/null' || true)
if [ "$current" != "$marker" ]; then
  echo "build.sh: preparing exact Google source"
  docker volume rm "$volume" >/dev/null 2>&1 || true
  docker volume create "$volume" >/dev/null
  docker run --rm \
    -v "$volume:/ksrc" \
    -v "$(cd "$(dirname "$tarball")" && pwd -P):/cache:ro" \
    -v "$stage/patches:/patches:ro" \
    -e TARBALL="/cache/$(basename "$tarball")" \
    -e MARKER="$marker" \
    "$image_tag" bash -euo pipefail -c '
      mkdir -p /ksrc/common
      tar -xzf "$TARBALL" -C /ksrc/common
      cd /ksrc/common
      for item in /patches/*.patch; do
        patch -p1 --no-backup-if-mismatch -i "$item"
      done
      {
        for item in android/abi_gki_aarch64 android/abi_gki_aarch64_*; do
          case "$item" in
            *.stg|*.stg.*) continue ;;
          esac
          awk "!/^\\[/ && !/^#/ && NF {print \$1}" "$item"
        done
      } | LC_ALL=C sort -u > abi_symbollist.raw
      test -s abi_symbollist.raw
      printf "%s\n" "$MARKER" > /ksrc/.source
    ' || fail "source preparation failed"
fi

docker run --rm \
  -v "$volume:/ksrc" \
  -v "$stage:/work:ro" \
  -v "$(cd "$out_dir" && pwd -P):/out" \
  -e JOBS="$jobs" \
  -e EXPECTED_RELEASE="$expected_release" \
  "$image_tag" bash -euo pipefail -c '
    export ARCH=arm64 LLVM=1 LLVM_IAS=1
    rm -rf /ksrc/out
    mkdir -p /ksrc/out
    cp /work/stock.config /ksrc/out/.config
    /ksrc/common/scripts/kconfig/merge_config.sh -m -O /ksrc/out \
      /ksrc/out/.config /work/fragment.config >/dev/null
    make -s -C /ksrc/common O=/ksrc/out olddefconfig
    release=$(make -s -C /ksrc/common O=/ksrc/out kernelrelease)
    [ "$release" = "$EXPECTED_RELEASE" ] || {
      echo "kernel release mismatch: $release != $EXPECTED_RELEASE" >&2
      exit 1
    }
    cp /ksrc/out/.config /out/config
    make -s -j"$JOBS" -C /ksrc/common O=/ksrc/out Image Image.lz4
    cp /ksrc/out/arch/arm64/boot/Image /out/Image
    cp /ksrc/out/arch/arm64/boot/Image.lz4 /out/Image.lz4
    printf "%s\n" "$release" > /out/release.txt
    clang --version | head -1 > /out/toolchain.txt
  '

if [ -f "$expected_config" ]; then
  diff -u "$expected_config" "$out_dir/config" > "$out_dir/config.diff" || \
    fail "merged config differs from kernel/kernel.config"
else
  echo "build.sh: first build - review $out_dir/config before recording kernel/kernel.config"
fi

for file in Image Image.lz4 config; do
  printf '%s  %s\n' "$(digest "$out_dir/$file")" "$file"
done | tee "$out_dir/SHA256SUMS"
[ "$(digest "$out_dir/Image.lz4")" = "$qualified_image_lz4_sha" ] || \
  fail "Image.lz4 does not match the qualified Pixel 8a kernel"
echo "build.sh: completed $expected_release"
