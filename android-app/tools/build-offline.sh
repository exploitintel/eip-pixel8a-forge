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
OUTPUT_DIR="$APP_ROOT/build/offline"
WORK_DIR="$OUTPUT_DIR/work"
KEYSTORE="$APP_ROOT/.signing/forge-control-debug.jks"
SIGNING_DIR=$(dirname -- "$KEYSTORE")

export JAVA_HOME="$JDK_ROOT"

for required in \
  "$JDK_ROOT/bin/javac" \
  "$JDK_ROOT/bin/jar" \
  "$JDK_ROOT/bin/keytool" \
  "$BUILD_TOOLS/aapt2" \
  "$BUILD_TOOLS/d8" \
  "$BUILD_TOOLS/zipalign" \
  "$BUILD_TOOLS/apksigner" \
  "$ANDROID_JAR"
do
  if [ ! -e "$required" ]; then
    echo "Missing offline build dependency: $required" >&2
    exit 1
  fi
done

rm -rf "$WORK_DIR"
mkdir -p \
  "$WORK_DIR/compiled" \
  "$WORK_DIR/generated" \
  "$WORK_DIR/classes" \
  "$WORK_DIR/dex" \
  "$SIGNING_DIR"

"$BUILD_TOOLS/aapt2" compile \
  --dir "$APP_ROOT/app/src/main/res" \
  -o "$WORK_DIR/compiled/resources.zip"

"$BUILD_TOOLS/aapt2" link \
  -I "$ANDROID_JAR" \
  --manifest "$APP_ROOT/app/src/main/AndroidManifest.xml" \
  --java "$WORK_DIR/generated" \
  --min-sdk-version 31 \
  --target-sdk-version 36 \
  --version-code 1 \
  --version-name 0.1.0 \
  -o "$WORK_DIR/resources.apk" \
  "$WORK_DIR/compiled/resources.zip"

find "$APP_ROOT/app/src/main/java" -type f -name '*.java' -print \
  > "$WORK_DIR/sources.txt"
find "$WORK_DIR/generated" -type f -name '*.java' -print \
  >> "$WORK_DIR/sources.txt"

"$JDK_ROOT/bin/javac" \
  --release 17 \
  -classpath "$ANDROID_JAR" \
  -d "$WORK_DIR/classes" \
  @"$WORK_DIR/sources.txt"

"$JDK_ROOT/bin/jar" --create \
  --file "$WORK_DIR/classes.jar" \
  -C "$WORK_DIR/classes" .

"$BUILD_TOOLS/d8" \
  --lib "$ANDROID_JAR" \
  --min-api 31 \
  --output "$WORK_DIR/dex" \
  "$WORK_DIR/classes.jar"

cp "$WORK_DIR/resources.apk" "$WORK_DIR/unsigned.apk"
(
  cd "$WORK_DIR/dex"
  zip -q -u "$WORK_DIR/unsigned.apk" classes.dex
)
"$BUILD_TOOLS/zipalign" -f 4 \
  "$WORK_DIR/unsigned.apk" \
  "$WORK_DIR/aligned.apk"

if [ ! -f "$KEYSTORE" ]; then
  "$JDK_ROOT/bin/keytool" -genkeypair \
    -keystore "$KEYSTORE" \
    -storetype PKCS12 \
    -storepass android \
    -keypass android \
    -alias forge-control-debug \
    -keyalg RSA \
    -keysize 2048 \
    -validity 10000 \
    -dname 'CN=Forge Control Debug,O=Exploit Intel,C=US'
fi

"$BUILD_TOOLS/apksigner" sign \
  --ks "$KEYSTORE" \
  --ks-key-alias forge-control-debug \
  --ks-pass pass:android \
  --key-pass pass:android \
  --out "$OUTPUT_DIR/forge-control-debug.apk" \
  "$WORK_DIR/aligned.apk"

"$BUILD_TOOLS/apksigner" verify --verbose "$OUTPUT_DIR/forge-control-debug.apk"
echo "Built $OUTPUT_DIR/forge-control-debug.apk"
