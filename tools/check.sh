#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
cd "$repo_dir"

python3 -m json.tool DEVICE.json >/dev/null
python3 -m py_compile tools/swap-boot-kernel.py
bash -n kernel/build.sh

for script_file in \
  host/dockerd.sh \
  host/buildkit-runc.sh \
  host-module/post-fs-data.sh \
  host-module/service.sh \
  tools/build-host-module.sh \
  tools/build-privns.sh
do
  sh -n "$script_file"
done

git diff --check
echo "checks passed"
