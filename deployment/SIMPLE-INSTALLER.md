# Pixel Forge installer

The release installer brings a supported Pixel 8a from stock Android
to a working Forge system. The accepted clean-install contract is one wipe
invocation followed by one uninterrupted install invocation.

## Supported target

- Pixel 8a (`akita`)
- Google build `CP2A.260805.005`
- unlocked bootloader
- Wi-Fi networking

The computer needs `adb`, `fastboot`, `curl`, and `unzip`.

## Prepare the two Google files automatically

Google does not allow its factory images to be redistributed. Download the
factory ZIP for the exact device and build from
<https://developers.google.com/android/images>, then run:

```sh
./prepare-firmware.sh \
  --factory-zip /path/to/akita-cp2a.260805.005-factory-b143bf41.zip \
  --serial ADB_SERIAL
```

The phone must be booted with USB debugging authorized for this preparation
step. The script does all of the mechanical work:

1. finds the nested `image-akita-*.zip`;
2. extracts `boot.img` and `init_boot.img`;
3. verifies both exact Google build hashes;
4. downloads and verifies Docker Engine 29.8.0 and KernelSU-Next 3.3.0 from
   their official release locations;
5. uses KernelSU's own tool on the connected phone to create the qualified
   local bootstrap image; and
6. places the two required outputs into `payload/`.

The Google files remain on the user's computer and never enter GitHub.

## Clean installation

The first invocation is destructive:

```sh
./install.sh --serial ADB_SERIAL --wipe
```

Before entering the bootloader, the installer requires the exact supported
device, build fingerprint, Android version, and security patch level. The same
check runs before a normal installation can bootstrap KernelSU.

After Android restarts, complete setup, connect Wi-Fi, enable USB debugging,
and authorize the computer again. Then run:

```sh
./install.sh \
  --serial ADB_SERIAL \
  --provider-env /path/to/providers.env
```

`--provider-env` is optional. It contains ordinary `KEY=value` rows and is
never part of the installer bundle. The installer reports key names and value
lengths, not secret values.

The Docker data image defaults to a sparse 64 GiB allocation. Select 16, 32,
or 64 GiB with `--disk-gib SIZE`. Smaller images do not leave enough room for
the old and new Forge controller layers during an update.

## Update an installed phone

Extract the latest bundle and run:

```sh
./install.sh --serial ADB_SERIAL
```

No firmware preparation is needed. The installer detects the qualified
existing installation before applying fresh-install payload requirements. It
preserves the existing Docker disk size, Forge state, provider configuration,
WebUI credentials, and CVE data. It pulls both release images by immutable
public GHCR digest, prevents new work, waits for current work to become idle,
and uses the existing source, operations, image, and managed-skills rollback
transaction. The update is complete only when the final line is `READY`.

Do not pass `--disk-gib` for an update. Use `--provider-env` only when you
intentionally want to merge additional provider settings.

## Success contract

In one process, the normal invocation installs KernelSU-Next, the Pixel host
module and kernel, Docker Engine, the pinned Forge images and source, the phone
operations, and Forge Control. It configures providers, waits for the candidate
WebUI, rebases any existing managed-skill state through Forge's release API,
then starts the full stack and waits for the host authority to report a healthy
WebUI and agent-chat service.

The final line must be:

```text
READY
```

Immediately before `READY`, the installer prints the generated Forge WebUI
username and password. Save the password. To retrieve it later on macOS, run:

```sh
"$HOME/Library/Android/sdk/platform-tools/adb" \
  -s ADB_SERIAL shell \
  "su -c '/data/eip-cve-ops/eip.sh password'"
```

No local Ollama binary is installed. New state defaults to the Ollama.com API,
while local Ollama and all other Forge providers remain configurable.

## Failure and recovery

Do not repair a failed clean-install proof with side ADB commands. Correct the
reported input or USB problem and restart the clean-install sequence.

Before installation, keep the matching Google factory ZIP available off the
phone. If the phone cannot boot, use fastboot with the exact active slot and
the matching factory `boot.img` and `init_boot.img`. Never guess a slot or use
another build.

## Package assembly

`build-simple-package.sh` creates the release directory from explicit built
artifacts. Public packages omit Google firmware, Docker Engine, and the
KernelSU Manager APK; `prepare-firmware.sh` obtains or creates those locally.
Supplying `--engine`, `--ksu-apk`, `--stock-boot`, and `--ksu-init-boot`
together remains available for operator-local packages.

The builder accepts only the Forge commit in `FORGE_REVISION` and a lock from
the matching Pixel image-publishing run. Release packages contain immutable
public GHCR references instead of `controller.tar` and `operator.tar`. The
installer verifies each downloaded image's config ID before assigning its
local release tag. It still rechecks the exact prepared boot inputs used by a
fresh installation.

Build the small Forge Control authorization helper with the Android NDK. Set
the prebuilt directory to `darwin-x86_64` on macOS or `linux-x86_64` on Linux:

```sh
"$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$ANDROID_NDK_HOST/bin/aarch64-linux-android34-clang" \
  -O2 -Wall -Wextra -Werror deployment/ksu-grant-profile.c \
  -o /tmp/ksu-grant-profile
```

Focused checks:

```sh
bash -n deployment/prepare-firmware.sh
bash -n deployment/simple-install.sh
bash -n deployment/build-simple-package.sh
node --test tests/simple-installer.test.mjs
```
