<p align="center">
  <a href="https://exploit-intel.com">
    <img src=".github/assets/eip-hero-banner.svg" alt="Exploit Intelligence Platform" width="100%">
  </a>
</p>

<h1 align="center">eip-pixel8a-forge</h1>

<p align="center"><strong>Turn a Pixel 8a into a self-contained CVE research device.</strong></p>

<p align="center">
  <a href="https://exploit-intel.com"><img src="https://img.shields.io/badge/Exploit_Intel-platform-34e0a4.svg" alt="Exploit Intelligence Platform"></a>
  <a href="https://github.com/exploitintel/eip-pixel8a-forge/releases"><img src="https://img.shields.io/github/v/release/exploitintel/eip-pixel8a-forge?include_prereleases&label=release" alt="Latest release"></a>
  <a href="https://github.com/exploitintel/eip-pixel8a-forge/actions/workflows/check.yml"><img src="https://github.com/exploitintel/eip-pixel8a-forge/actions/workflows/check.yml/badge.svg" alt="Project checks"></a>
  <a href="https://github.com/exploitintel/eip-pixel8a-forge/blob/main/LICENSE"><img src="https://img.shields.io/badge/license-MIT-16b8c4.svg" alt="MIT License"></a>
</p>

[Forge v4](https://github.com/exploitintel/eip-cve-public-v4) is an
operator-controlled CVE research workbench: agents perform source review,
build isolated labs, do bounded proof work, and prepare reviewed publication
packages, with a human operator in control at every gate. This repository
makes that entire system run on the phone itself.

The phone runs a real Docker Engine on a matched custom kernel - not an
emulator, not a chroot, and not a thin client for a server somewhere else.
Labs, agents, and the Forge WebUI all execute on the device; apart from
installs and updates, the traffic leaving it is the model-provider calls you
configure. You get a pocket-sized research host that works anywhere there is
Wi-Fi, and that you can wipe back to stock Google firmware whenever you want a
clean start.

This repository owns the Pixel host, installer, Forge Control Android app,
and release packaging. Forge itself remains in
[`eip-cve-public-v4`](https://github.com/exploitintel/eip-cve-public-v4) and
is pinned here by [`FORGE_REVISION`](FORGE_REVISION).

**Start here:** [Supported phone](#supported-phone) | [Install](#install) |
[Update](#update-an-existing-installation) | [What gets installed](#what-gets-installed) |
[Important limits](#important-limits)

## Supported phone

| Device | Google build | KernelSU-Next | Network |
| --- | --- | --- | --- |
| Pixel 8a (`akita`) | Android 17 `CP2A.260805.005` | 3.3.0, LKM | Wi-Fi |

Other phones and Android builds are not supported by this release.

## Install

You need an unlocked bootloader, a USB cable, and a computer with `adb`,
`fastboot`, `curl`, and `unzip`. The clean-install path erases the phone.

### 1. Download two files

Download and extract the latest installer bundle from this repository's
[Releases](https://github.com/exploitintel/eip-pixel8a-forge/releases) page.

Then open Google's official
[Pixel factory-image page](https://developers.google.com/android/images),
accept Google's terms, and download the factory ZIP for:

```text
Pixel 8a (akita)
CP2A.260805.005
```

Keep the Google ZIP intact. You do not need to find or rename partition
images yourself.

### 2. Prepare the Google firmware inputs

With the phone booted, USB debugging enabled, and this computer authorized:

```sh
./prepare-firmware.sh \
  --factory-zip ~/Downloads/akita-cp2a.260805.005-factory-*.zip \
  --serial ADB_SERIAL
```

The command extracts and verifies the exact Google boot images, downloads the
pinned Docker and KernelSU-Next inputs, and creates the local KernelSU bootstrap
image. Google firmware never enters this repository or its release assets.

### 3. Wipe the phone

Back up anything you need first. This command erases Android user data:

```sh
./install.sh --serial ADB_SERIAL --wipe
```

### 4. Finish Android setup and install Forge

Complete Android setup, connect to Wi-Fi, enable USB debugging, and authorize
the computer again. Then run:

```sh
./install.sh --serial ADB_SERIAL
```

To install provider keys at the same time:

```sh
./install.sh \
  --serial ADB_SERIAL \
  --provider-env /path/to/providers.env
```

The provider file is ordinary `NAME=value` lines and stays outside the
repository. For example:

```text
OLLAMA_API_KEY=replace-me
OPENAI_API_KEY=replace-me
ANTHROPIC_API_KEY=replace-me
DEEPSEEK_API_KEY=replace-me
GLM_API_KEY=replace-me
OPENROUTER_API_KEY=replace-me
```

The Docker data image defaults to a sparse 64 GiB allocation. Use
`--disk-gib 16`, `--disk-gib 32`, or `--disk-gib 64` during a clean install
when you deliberately want a different size.

Installation is complete only when the final line is:

```text
READY
```

The installer prints the generated Forge WebUI username and password
immediately before `READY`. Save the password for future logins. Open the
Forge Control app on the phone, then tap **Open Forge WebUI**.

## Update an existing installation

Download and extract the latest installer bundle, connect the already
installed phone over USB, and run the same command:

```sh
./install.sh --serial ADB_SERIAL
```

The installer recognizes the existing system, downloads the exact public
controller and operator image digests over the phone's Wi-Fi connection,
waits for current Forge work to become idle, and updates with rollback. It
preserves the Docker disk, Forge state, WebUI password, provider keys, and CVE
data. Do not run `prepare-firmware.sh`, `--wipe`, or `--disk-gib` for an update.

## What gets installed

- The matched Pixel kernel and native Docker host
- The controller image built from the pinned public Forge commit, pulled from
  GHCR by immutable digest
- The Pixel operator image and phone operations
- Forge Control for starting, parking, and inspecting the system
- The Forge WebUI and agent-chat service

New installations default Ollama to `https://ollama.com`; no local Ollama
binary is installed. Local Ollama and every other Forge provider remain
available through normal Forge configuration.

## Source layout

- `deployment/` contains the installer and package builder.
- `eip/` contains Pixel-specific Forge and container glue.
- `android-app/` contains Forge Control.
- `module/`, `android/`, and `tools/` contain the native Pixel Docker host.
- `kernel/` contains the qualified kernel recipe, configuration, and source
  identity.
- [`DEVICE.json`](DEVICE.json) records the exact firmware, source, boot,
  KernelSU-Next, and Docker identities qualified on the phone.

Run the source checks with:

```sh
tools/check.sh
```

Pull requests run the same checks, focused installer contracts, Android host
contracts, image validation, and an independent code review.

## Important limits

- The installer writes the active `boot` and `init_boot` partitions.
- Never use firmware from a different device or build.
- Keep the matching factory image available for fastboot recovery.
- Do not accept an Android OTA on an installed Forge phone. Return to the
  recorded build before reinstalling.
- Container networking is qualified over Wi-Fi only.
- Unlocking the bootloader and installing a custom kernel weaken the stock
  Android security model.

First-party source is MIT licensed. Kernel materials retain their upstream
licenses. See [`NOTICE.md`](NOTICE.md).
