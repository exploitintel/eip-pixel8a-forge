#!/usr/bin/env bash
# Build the module's four static AArch64 helpers from one hash-bound SDK.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
metadata="$root/tools/aarch64-musl-toolchain.json"
export LC_ALL=C
export SOURCE_DATE_EPOCH=0
export TZ=UTC
export ZERO_AR_DATE=1

# The caller's PATH remains available for the reviewed host utilities below,
# but ambient compiler search paths, loader injection, and tar defaults must
# not influence the pinned SDK or either reproducibility build.
unset \
  CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH OBJC_INCLUDE_PATH \
  GCC_EXEC_PREFIX COMPILER_PATH LIBRARY_PATH \
  GCC_COMPARE_DEBUG COLLECT_GCC_OPTIONS \
  LD_PRELOAD LD_LIBRARY_PATH LD_AUDIT TAR_OPTIONS

fail() {
  echo "build-module-tools.sh: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
usage: build-module-tools.sh --toolchain-archive PATH --out NEW_DIRECTORY
       build-module-tools.sh verify-elf --readelf PATH ELF [ELF ...]
EOF
  exit 2
}

verify_elf() {
  local readelf=$1
  local binary=$2
  local header program_headers dynamic

  [ -f "$binary" ] && [ ! -L "$binary" ] \
    || fail "not a regular ELF input: $binary"
  header=$("$readelf" -hW -- "$binary") \
    || fail "readelf could not inspect ELF header: $binary"
  printf '%s\n' "$header" | grep -Eq '^[[:space:]]*Class:[[:space:]]+ELF64[[:space:]]*$' \
    || fail "ELF class is not ELF64: $binary"
  printf '%s\n' "$header" | grep -Eq '^[[:space:]]*Machine:[[:space:]]+AArch64[[:space:]]*$' \
    || fail "ELF machine is not AArch64: $binary"

  program_headers=$("$readelf" -lW -- "$binary") \
    || fail "readelf could not inspect program headers: $binary"
  if printf '%s\n' "$program_headers" | grep -Eq '(^|[[:space:]])INTERP([[:space:]]|$)'; then
    fail "PT_INTERP is forbidden: $binary"
  fi

  dynamic=$("$readelf" -dW -- "$binary") \
    || fail "readelf could not inspect the dynamic section: $binary"
  if printf '%s\n' "$dynamic" | grep -Eq '\(NEEDED\)'; then
    fail "DT_NEEDED is forbidden: $binary"
  fi
}

if [ "${1:-}" = verify-elf ]; then
  shift
  [ "${1:-}" = --readelf ] && [ "$#" -ge 3 ] || usage
  readelf=$2
  shift 2
  [ -x "$readelf" ] && [ -f "$readelf" ] && [ ! -L "$readelf" ] \
    || fail "readelf is not an executable regular file: $readelf"
  for binary in "$@"; do
    verify_elf "$readelf" "$binary"
  done
  exit 0
fi

[ "$#" -eq 4 ] || usage
archive=
out=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --toolchain-archive)
      [ -z "$archive" ] && [ "$#" -ge 2 ] || usage
      archive=$2
      shift 2
      ;;
    --out)
      [ -z "$out" ] && [ "$#" -ge 2 ] || usage
      out=$2
      shift 2
      ;;
    *) usage ;;
  esac
done
[ -n "$archive" ] && [ -n "$out" ] || usage

[ "$(uname -s)" = Linux ] || fail "the pinned toolchain requires a Linux host"
[ "$(uname -m)" = x86_64 ] || fail "the pinned toolchain requires an x86_64 host"
[ -f "$archive" ] && [ ! -L "$archive" ] || fail "toolchain archive is not a regular file"
[ ! -e "$out" ] && [ ! -L "$out" ] || fail "output already exists: $out"
[ -d "$(dirname "$out")" ] && [ ! -L "$(dirname "$out")" ] \
  || fail "output parent must be an existing non-symlink directory"

mapfile -t pin < <(python3 - "$metadata" <<'PY'
import json
import re
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    item = json.load(handle)

required = {
    "schemaVersion": 1,
    "hostOs": "linux",
    "hostArchitecture": "x86_64",
    "targetArchitecture": "aarch64",
    "elfClass": "ELF64",
    "elfMachine": "AArch64",
    "toolPrefix": "aarch64-buildroot-linux-musl",
}
actual = {
    "schemaVersion": item.get("schemaVersion"),
    "hostOs": item["identity"]["host"]["os"],
    "hostArchitecture": item["identity"]["host"]["architecture"],
    "targetArchitecture": item["identity"]["target"]["architecture"],
    "elfClass": item["identity"]["target"]["elfClass"],
    "elfMachine": item["identity"]["target"]["elfMachine"],
    "toolPrefix": item["identity"]["target"]["toolPrefix"],
}
if actual != required:
    raise SystemExit("toolchain metadata identity is not the supported contract")

archive = item["archive"]
paths = item["paths"]
if not isinstance(archive["size"], int) or archive["size"] <= 0:
    raise SystemExit("toolchain archive size is invalid")
if not re.fullmatch(r"[0-9a-f]{64}", archive["sha256"]):
    raise SystemExit("toolchain archive sha256 is invalid")
if not archive["url"].startswith("https://toolchains.bootlin.com/"):
    raise SystemExit("toolchain URL is outside the accepted HTTPS origin")
for value in (archive["name"], archive["topLevelDirectory"], paths["cc"], paths["readelf"], paths["sysroot"]):
    if not isinstance(value, str) or not value or "\n" in value or value.startswith("/") or ".." in value.split("/"):
        raise SystemExit("unsafe toolchain metadata path")

print(archive["name"])
print(archive["size"])
print(archive["sha256"])
print(archive["topLevelDirectory"])
print(paths["cc"])
print(paths["readelf"])
print(paths["sysroot"])
print(item["components"]["gcc"]["version"])
print(item["components"]["binutils"]["version"])
print(item["identity"]["target"]["toolPrefix"])
PY
)
[ "${#pin[@]}" -eq 10 ] || fail "could not read the complete toolchain pin"

archive_size=$(wc -c < "$archive" | tr -d ' ')
[ "$archive_size" = "${pin[1]}" ] \
  || fail "toolchain archive size mismatch: got $archive_size, expected ${pin[1]}"
actual_sha=$(sha256sum "$archive" | awk '{print $1}')
[ "$actual_sha" = "${pin[2]}" ] \
  || fail "toolchain archive sha256 mismatch: got $actual_sha, expected ${pin[2]}"

work=$(mktemp -d "${TMPDIR:-/tmp}/eip-module-toolchain.XXXXXX")
staging=
cleanup() {
  [ -z "$work" ] || rm -rf -- "$work"
  [ -z "$staging" ] || rm -rf -- "$staging"
}
trap cleanup EXIT
python3 - "$archive" "${pin[3]}" <<'PY'
import pathlib
import sys
import tarfile

archive, expected_root = sys.argv[1:]
with tarfile.open(archive, mode="r:xz") as handle:
    members = handle.getmembers()
    if not members:
        raise SystemExit("toolchain archive is empty")
    for member in members:
        path = pathlib.PurePosixPath(member.name)
        if path.is_absolute() or ".." in path.parts or not path.parts or path.parts[0] != expected_root:
            raise SystemExit("toolchain archive contains a path outside its pinned root")
        if member.isdev() or member.isfifo():
            raise SystemExit("toolchain archive contains a device or FIFO")
        if member.issym() or member.islnk():
            target = pathlib.PurePosixPath(member.linkname)
            resolved = target if target.is_absolute() else path.parent / target
            parts = []
            for part in resolved.parts:
                if part in ("", "."):
                    continue
                if part == "..":
                    if not parts:
                        raise SystemExit("toolchain archive link escapes its pinned root")
                    parts.pop()
                else:
                    parts.append(part)
            if target.is_absolute() or not parts or parts[0] != expected_root:
                raise SystemExit("toolchain archive link escapes its pinned root")
PY
tar --extract --xz --file "$archive" --directory "$work" --no-same-owner --no-same-permissions
toolchain="$work/${pin[3]}"
[ -d "$toolchain" ] && [ ! -L "$toolchain" ] || fail "pinned toolchain root is absent"

cc="$toolchain/${pin[4]}"
readelf="$toolchain/${pin[5]}"
sysroot="$toolchain/${pin[6]}"
for executable in "$cc" "$readelf"; do
  resolved=$(realpath -e "$executable") || fail "pinned tool cannot be resolved: $executable"
  case "$resolved" in
    "$toolchain"/*) ;;
    *) fail "pinned tool resolves outside the verified SDK: $executable" ;;
  esac
  [ -x "$resolved" ] && [ -f "$resolved" ] \
    || fail "pinned tool is not an executable regular file: $executable"
done
resolved_sysroot=$(realpath -e "$sysroot") || fail "pinned sysroot cannot be resolved"
case "$resolved_sysroot" in
  "$toolchain"/*) ;;
  *) fail "pinned sysroot resolves outside the verified SDK" ;;
esac
[ -d "$resolved_sysroot" ] || fail "pinned sysroot is not a directory"
[ "$("$cc" -dumpmachine)" = "${pin[9]}" ] || fail "compiler target tuple mismatch"
[ "$("$cc" -dumpfullversion)" = "${pin[7]}" ] || fail "compiler version mismatch"
readelf_version=$("$readelf" --version) || fail "could not read the readelf version"
case "${readelf_version%%$'\n'*}" in
  *" ${pin[8]}"*) ;;
  *) fail "readelf version mismatch" ;;
esac
reported_sysroot=$("$cc" --print-sysroot)
[ "$(realpath -e "$reported_sysroot")" = "$resolved_sysroot" ] \
  || fail "compiler sysroot does not match the pinned SDK path"

staging=$(mktemp -d "$(dirname "$out")/.module-tools.XXXXXX") \
  || fail "could not create the output staging directory"
chmod 0755 "$staging"
sources=(patch-engine swap-boot-kernel privns route-policy)
common_flags=(
  "-std=c99"
  "-Os"
  "-Wall"
  "-Wextra"
  "-Werror"
  "-static"
  "-fno-ident"
  "-ffile-prefix-map=$root=."
  "-fdebug-prefix-map=$root=."
  "-Wl,--build-id=sha1"
)
for name in "${sources[@]}"; do
  source="$root/tools/$name.c"
  target="$staging/$name.part"
  [ -f "$source" ] && [ ! -L "$source" ] || fail "missing regular source: $source"
  "$cc" "${common_flags[@]}" -frandom-seed="$name" -o "$target" "$source"
  verify_elf "$readelf" "$target"
  chmod 0755 "$target"
  mv "$target" "$staging/$name"
done

mv --no-clobber --no-target-directory "$staging" "$out" \
  || fail "could not publish the complete output directory"
[ ! -e "$staging" ] \
  || fail "output appeared concurrently; complete staged tools were not published"
staging=

printf 'built and verified %s\n' \
  "$out/patch-engine" "$out/swap-boot-kernel" "$out/privns" "$out/route-policy"
