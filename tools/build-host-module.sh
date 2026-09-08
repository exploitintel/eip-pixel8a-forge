#!/bin/sh
set -eu

usage() {
  echo "usage: tools/build-host-module.sh --engine-dir DIR --out FILE" >&2
  exit 2
}

engine_dir=
output=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --engine-dir) [ "$#" -ge 2 ] || usage; engine_dir=$2; shift 2 ;;
    --out) [ "$#" -ge 2 ] || usage; output=$2; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$engine_dir" ] && [ -n "$output" ] || usage
case "$output" in
  /*) output_abs=$output ;;
  *) output_abs=$(pwd)/$output ;;
esac

required='docker dockerd containerd containerd-shim-runc-v2 runc docker-init docker-proxy privns'
for binary in $required; do
  [ -x "$engine_dir/$binary" ] || {
    echo "missing engine binary: $engine_dir/$binary" >&2
    exit 1
  }
done

stage=$(mktemp -d "${TMPDIR:-/tmp}/eip-pixel8a-module.XXXXXX")
trap 'rm -rf "$stage"' EXIT HUP INT TERM
mkdir -p "$stage/bin" "$(dirname "$output_abs")"
rm -f "$output_abs"
cp host-module/module.prop host-module/post-fs-data.sh host-module/service.sh "$stage/"
cp host/host.conf.default "$stage/host.conf.default"
cp host/dockerd.sh host/buildkit-runc.sh "$stage/bin/"
for binary in $required; do
  cp "$engine_dir/$binary" "$stage/bin/$binary"
done
chmod 0755 "$stage/post-fs-data.sh" "$stage/service.sh" "$stage/bin/"*

(cd "$stage" && zip -qr "$output_abs" .)
echo "$output"
