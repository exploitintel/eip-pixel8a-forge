# Notices and attribution

The first-party scripts, tools, tests, documentation, and Android runtime
helpers are provided under the repository MIT license unless a file says
otherwise.

The kernel configuration and patches apply to Linux kernel source. Linux
kernel source and resulting distributions remain subject to upstream
licensing terms and applicable per-file SPDX identifiers.

This project downloads the pinned Docker Engine 29.8.0 AArch64 static archive
from Docker's official distribution site and applies reviewed, same-length
path substitutions on the user's machine. It does not distribute Docker
binaries.

Development module tools are cross-compiled with the exact Bootlin
AArch64-musl toolchain recorded in `tools/aarch64-musl-toolchain.json`. The
toolchain archive itself is not distributed. The musl 1.2.5 copyright and
permission notice is preserved at `tools/licenses/musl-COPYRIGHT` and inside
each module ZIP.

KernelSU-Next is a separate project used by the installation design. This
repository is not affiliated with KernelSU-Next.

Google Pixel, Android, and related marks belong to Google LLC. Google firmware
and boot images are not included. Users must obtain their own matching factory
image under Google's terms.
