#!/bin/sh
set -eu

APP_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
JDK_ROOT=${FORGE_JAVA_HOME:-/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home}
SDK_ROOT=${FORGE_ANDROID_SDK:-${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}}
[ -n "$SDK_ROOT" ] || {
  echo 'Set FORGE_ANDROID_SDK, ANDROID_SDK_ROOT, or ANDROID_HOME.' >&2
  exit 1
}
BUILD_TOOLS="$SDK_ROOT/build-tools/36.0.0"
ANDROID_JAR="$SDK_ROOT/platforms/android-36/android.jar"
OUTPUT_DIR="$APP_ROOT/build/ui-tests"
TEST_PACKAGE=com.exploitintel.forgecontrol.uipreview
ADB="$SDK_ROOT/platform-tools/adb"
TARGET=${1:-}
VARIANT=${2:-default}

case "$TARGET" in
  --build-only) ;;
  emulator-*)
    if ! printf '%s\n' "$TARGET" | grep -Eq '^emulator-[0-9]+$'; then
      echo 'An explicit emulator-NNNN serial is required.' >&2
      exit 2
    fi
    if [ "$("$ADB" -s "$TARGET" shell getprop ro.kernel.qemu | tr -d '\r')" != 1 ]; then
      echo 'Refusing to install: the selected target is not an emulator.' >&2
      exit 2
    fi
    ;;
  *)
    echo 'Usage: ui-tests/run.sh --build-only | emulator-NNNN [screenshot-variant]' >&2
    exit 2
    ;;
esac

if ! printf '%s\n' "$VARIANT" | grep -Eq '^[a-z0-9-]+$'; then
  echo 'Screenshot variant must contain only lowercase letters, digits, or hyphens.' >&2
  exit 2
fi

export JAVA_HOME="$JDK_ROOT"
mkdir -p "$OUTPUT_DIR"
WORK_DIR=$(mktemp -d "$OUTPUT_DIR/work.XXXXXX")
mkdir -p "$WORK_DIR/compiled" "$WORK_DIR/generated" "$WORK_DIR/classes" "$WORK_DIR/dex"

"$BUILD_TOOLS/aapt2" compile \
  --dir "$APP_ROOT/app/src/main/res" \
  -o "$WORK_DIR/compiled/resources.zip"
"$BUILD_TOOLS/aapt2" link \
  -I "$ANDROID_JAR" \
  --manifest "$APP_ROOT/ui-tests/AndroidManifest.xml" \
  --custom-package com.exploitintel.forgecontrol \
  --java "$WORK_DIR/generated" \
  --min-sdk-version 31 --target-sdk-version 36 \
  --version-code 1 --version-name ui-test \
  -o "$WORK_DIR/resources.apk" \
  "$WORK_DIR/compiled/resources.zip"

# This allowlist is the isolation boundary. No host client, services, receivers,
# operation coordinator, or production activity can enter the preview APK.
for source in ControlScreen ControlDialogs ControlStyles ControlActions HostStatus HostctlCommand CommandResult; do
  printf '%s\n' "$APP_ROOT/app/src/main/java/com/exploitintel/forgecontrol/$source.java"
done > "$WORK_DIR/sources.txt"
find "$APP_ROOT/ui-tests/com" "$WORK_DIR/generated" -name '*.java' -print >> "$WORK_DIR/sources.txt"
"$JDK_ROOT/bin/javac" --release 17 -classpath "$ANDROID_JAR" \
  -d "$WORK_DIR/classes" @"$WORK_DIR/sources.txt"
"$JDK_ROOT/bin/jar" --create --file "$WORK_DIR/classes.jar" -C "$WORK_DIR/classes" .
"$BUILD_TOOLS/d8" --lib "$ANDROID_JAR" --min-api 31 \
  --output "$WORK_DIR/dex" "$WORK_DIR/classes.jar"
cp "$WORK_DIR/resources.apk" "$WORK_DIR/unsigned.apk"
(
  cd "$WORK_DIR/dex"
  zip -q -u "$WORK_DIR/unsigned.apk" classes.dex
)
"$BUILD_TOOLS/zipalign" -f 4 "$WORK_DIR/unsigned.apk" "$WORK_DIR/aligned.apk"
KEYSTORE="$OUTPUT_DIR/ui-preview.jks"
if [ ! -f "$KEYSTORE" ]; then
  "$JDK_ROOT/bin/keytool" -genkeypair -keystore "$KEYSTORE" -storetype PKCS12 \
    -storepass android -keypass android -alias ui-preview -keyalg RSA -keysize 2048 \
    -validity 10000 -dname 'CN=Forge UI Test,O=Exploit Intel,C=US'
fi
"$BUILD_TOOLS/apksigner" sign --ks "$KEYSTORE" --ks-key-alias ui-preview \
  --ks-pass pass:android --key-pass pass:android \
  --out "$OUTPUT_DIR/forge-ui-preview.apk" "$WORK_DIR/aligned.apk"
"$BUILD_TOOLS/apksigner" verify "$OUTPUT_DIR/forge-ui-preview.apk"

if [ "$TARGET" = --build-only ]; then
  echo "Built isolated preview: $OUTPUT_DIR/forge-ui-preview.apk"
  exit 0
fi

"$ADB" -s "$TARGET" install -r -t "$OUTPUT_DIR/forge-ui-preview.apk"
"$ADB" -s "$TARGET" shell am instrument -w -r -e variant "$VARIANT" \
  "$TEST_PACKAGE/com.exploitintel.forgecontrol.UiContractInstrumentation" \
  > "$OUTPUT_DIR/$VARIANT-result.txt"
cat "$OUTPUT_DIR/$VARIANT-result.txt"
mkdir -p "$OUTPUT_DIR/screenshots"
"$ADB" -s "$TARGET" pull \
  "/sdcard/Android/data/$TEST_PACKAGE/files/screenshots/$VARIANT" \
  "$OUTPUT_DIR/screenshots/" || true
if ! grep -q 'UI_CONTRACT_OK' "$OUTPUT_DIR/$VARIANT-result.txt"; then
  echo 'Native UI contract checks failed.' >&2
  exit 1
fi
echo "Native screenshots: $OUTPUT_DIR/screenshots/$VARIANT"
