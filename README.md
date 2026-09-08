# EIP Pixel 8a Forge

Fresh Pixel 8a port of the working Pixel 11 Forge architecture.

The initial target is deliberately narrow:

- device: Pixel 8a (`akita`)
- Android: 17
- build: `CP2A.260805.005`
- kernel: Google common 6.1 commit `bd23337e42e794964a89f47596daf1209a25ee1a`
- Forge source: pinned from the standalone `eip-cve-public-v4` repository

The first slice builds the Docker-capable kernel and the minimal KernelSU host
module. It starts from the exact stock phone config, applies a small reviewed
fragment, and packages a prepared Android-patched Docker engine without
committing generated binaries or Google firmware.

## Kernel build

The exact Google source archive is recorded in `DEVICE.json` and is intentionally
not committed. Download it, then run:

```sh
kernel/build.sh \
  --tarball /path/to/kernel-common-bd23337e42e794964a89f47596daf1209a25ee1a.tar.gz \
  --out kernel/out/CP2A.260805.005
```

The build runs in a Linux Docker volume because the Android kernel source has
case-distinct filenames that cannot safely share a default macOS filesystem.

## Docker host module

Build the Android-native namespace helper into a prepared engine directory,
then package the KernelSU module:

```sh
ANDROID_NDK_HOME=/path/to/android-ndk \
  tools/build-privns.sh /path/to/engine/privns

tools/build-host-module.sh \
  --engine-dir /path/to/engine \
  --out artifacts/eip-pixel8a-docker-host.zip
```

The module creates and mounts an 8 GiB sparse ext4 data image, enables the
two Wi-Fi policy routes required for bridge traffic, and leaves Docker parked
by default. Setting `AUTOSTART=1` in `/data/docker/config/host.conf` starts the
daemon during the next boot.

## Qualified live result

On build `CP2A.260805.005`, the recorded kernel and KernelSU images survive a
reboot with root and Wi-Fi working. Docker 29.8.0 uses `overlay2`, pulls ARM64
images, resolves DNS, and reaches HTTPS from an Alpine container over Wi-Fi.
Exact source and qualified artifact hashes are in `DEVICE.json`.

## Pull-request checks

`tools/check.sh` runs the fast repository checks locally and in GitHub Actions.
Claude review is configured for every pull-request update after the repository
secret `CLAUDE_CODE_OAUTH_TOKEN` is added and the repository variable
`CLAUDE_REVIEW_ENABLED` is set to `true`.
