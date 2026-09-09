# EIP Pixel 8a Forge

Pixel 8a port of the working Pixel 11 Forge architecture. Forge itself remains
in the standalone `eip-cve-public-v4` repository.

The supported target is deliberately exact:

- Pixel 8a (`akita`)
- Android 17 build `CP2A.260805.005`
- security patch `2026-08-05`
- Google common 6.1 kernel commit
  `bd23337e42e794964a89f47596daf1209a25ee1a`
- KernelSU-Next 3.3.0 in LKM mode
- Docker Engine 29.8.0 over Wi-Fi

`DEVICE.json` records the source, firmware, kernel, boot, KernelSU, and Docker
identities qualified on the phone. Google firmware, generated boot images,
Docker data, credentials, and compiled artifacts are intentionally not in Git.

## Current state

The Docker-capable kernel and managed KernelSU host module are phone-qualified.
The module keeps Docker parked by default and provides one lifecycle command:

```sh
/data/docker/bin/hostctl status
/data/docker/bin/hostctl disk-init --size-bytes 8589934592
/data/docker/bin/hostctl start
/data/docker/bin/hostctl stop
/data/docker/bin/hostctl autostart on
/data/docker/bin/hostctl autostart off
```

On the target phone it mounts a labeled sparse ext4 image at
`/data/docker/lib`, runs Docker with `overlay2`, discovers Android's current
numeric `wlan0` table, and installs the two bridge policy routes. A fresh
Alpine container has passed DNS and HTTPS egress over Wi-Fi.

The device-neutral Forge phone runtime and Forge Control Android app live in
`eip/` and `android-app/`. `FORGE_REVISION` pins the exact standalone Forge v4
source used to build and deploy the controller. Local Ollama, Ollama Cloud, and
the other Forge providers remain runtime choices; the phone default is Ollama
Cloud and no local Ollama binary is installed.

The pinned runtime has been live-qualified on the target phone: both Forge
services reached healthy state, the generated WebUI login authenticated, the
Agent broker passed Forge's acceptance checks, and the installed control app
reported `READY`. Provider API keys remain private runtime configuration.

## Kernel build

Download the exact Google source archive recorded in `DEVICE.json`, then run:

```sh
kernel/build.sh \
  --tarball /path/to/kernel-common-bd23337e42e794964a89f47596daf1209a25ee1a.tar.gz \
  --out kernel/out/CP2A.260805.005
```

The build uses a Linux Docker volume because the Android kernel source has
case-distinct filenames that cannot safely share a default macOS filesystem.

## Module build

The module build uses the pinned Bootlin AArch64-musl toolchain in
`tools/aarch64-musl-toolchain.json`:

```sh
tools/build-module-tools.sh \
  --toolchain-archive /path/to/aarch64--musl--stable-2025.08-1.tar.xz \
  --out /tmp/eip-pixel8a-module-tools

python3 tools/assemble-module.py --installable \
  --patch-engine /tmp/eip-pixel8a-module-tools/patch-engine \
  --swap-boot-kernel /tmp/eip-pixel8a-module-tools/swap-boot-kernel \
  --privns /tmp/eip-pixel8a-module-tools/privns \
  --route-policy /tmp/eip-pixel8a-module-tools/route-policy \
  --toolchain-provenance tools/aarch64-musl-toolchain.json \
  --musl-license tools/licenses/musl-COPYRIGHT \
  --output /tmp/eip-pixel8a-forge-module.zip
```

The installer downloads the exact Docker archive recorded in
`tools/engine.json`; it does not bundle Docker binaries.

## Development checks

Run `tools/check.sh`. Pull requests also run the same check and a focused
Claude review. The remaining delivery slices are recorded in `PLAN.md`.
