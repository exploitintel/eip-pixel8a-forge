#!/bin/sh
set -eu

: "${ANDROID_NDK_HOME:?set ANDROID_NDK_HOME to an installed Android NDK}"

case "$(uname -s)-$(uname -m)" in
  Darwin-arm64|Darwin-x86_64) toolchain=darwin-x86_64 ;;
  Linux-x86_64) toolchain=linux-x86_64 ;;
  *) echo "unsupported build host: $(uname -s)-$(uname -m)" >&2; exit 1 ;;
esac

cc="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$toolchain/bin/aarch64-linux-android31-clang"
output=${1:-artifacts/privns}
mkdir -p "$(dirname "$output")"

"$cc" -O2 -static -Wall -Wextra -Werror \
  host/privns.c -o "$output"
chmod 0755 "$output"
