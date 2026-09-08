#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
cd "$repo_dir"

for json_file in DEVICE.json kernel/builds.json tools/engine.json tools/aarch64-musl-toolchain.json
do
  python3 -m json.tool "$json_file" >/dev/null
done

for python_file in tools/assemble-module.py tools/patch-engine.py tools/swap-boot-kernel.py
do
  python3 -m py_compile "$python_file"
done

bash -n kernel/build.sh
for shell_file in module/*.sh module/bin/* android/*.sh
do
  sh -n "$shell_file"
done
for shell_file in tools/*.sh
do
  case "$(head -n 1 "$shell_file")" in
    '#!/usr/bin/env bash') bash -n "$shell_file" ;;
    *) sh -n "$shell_file" ;;
  esac
done

python3 - <<'PY'
import json
from pathlib import Path

device = json.loads(Path("DEVICE.json").read_text())
catalog = json.loads(Path("kernel/builds.json").read_text())
assert catalog["schemaVersion"] == 1
assert catalog["repository"] == "eip-pixel8a-forge"
assert len(catalog["builds"]) == 1
build = catalog["builds"][0]
assert build["buildId"] == device["build_id"]
assert build["device"]["codename"] == device["device"] == "akita"
assert build["device"]["buildFingerprint"] == device["build_fingerprint"]
assert str(build["device"]["androidVersion"]) == device["android_version"]
assert build["device"]["securityPatch"] == device["security_patch"]
assert build["kernel"]["release"] == device["kernel"]["release"]
assert build["candidateImage"]["sha256"] == device["kernel"]["qualified_image_lz4_sha256"]
assert build["boot"]["candidateOutputPartitionSha256"] == device["kernel"]["qualified_boot_sha256"]
assert build["kernelSuNext"]["testedVersions"] == [device["kernelsu_next"]["version"]]

properties = dict(
    line.split("=", 1)
    for line in Path("module/module.prop").read_text().splitlines()
)
assert properties["id"] == "eip-pixel8a-forge"
assert properties["name"] == "EIP Pixel 8a Forge"

hostctl = Path("module/bin/hostctl").read_text()
assert "u:object_r:vold_data_file:s0" in hostctl
assert "RT_TABLES=/data/misc/net/rt_tables" in hostctl
assert "PIDOF=$SYSTEM_BIN/pidof" in hostctl
for stale in ("eip-pixel11xl-forge", "kodiak", "CD1A.260714.001.A9", "1016"):
    assert stale not in hostctl
PY

git diff --check
echo "checks passed"
