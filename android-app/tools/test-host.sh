#!/bin/sh
set -eu

APP_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
JDK_ROOT=${FORGE_JAVA_HOME:-/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home}
OUTPUT_DIR="$APP_ROOT/build/host-tests"

if [ ! -x "$JDK_ROOT/bin/javac" ]; then
  echo 'Set FORGE_JAVA_HOME to a JDK 21 installation.' >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
"$JDK_ROOT/bin/javac" \
  -d "$OUTPUT_DIR" \
  "$APP_ROOT/app/src/main/java/com/exploitintel/forgecontrol/ActivityLifecycleGate.java" \
  "$APP_ROOT/app/src/main/java/com/exploitintel/forgecontrol/HostctlCommand.java" \
  "$APP_ROOT/app/src/main/java/com/exploitintel/forgecontrol/CommandResult.java" \
  "$APP_ROOT/app/src/main/java/com/exploitintel/forgecontrol/OperationCoordinator.java" \
  "$APP_ROOT/app/src/main/java/com/exploitintel/forgecontrol/OperationLease.java" \
  "$APP_ROOT/app/src/main/java/com/exploitintel/forgecontrol/ServiceLifecycleGate.java" \
  "$APP_ROOT/app/src/main/java/com/exploitintel/forgecontrol/HostStatus.java" \
  "$APP_ROOT/app/src/main/java/com/exploitintel/forgecontrol/ControlActions.java" \
  "$APP_ROOT/host-tests/com/exploitintel/forgecontrol/HostStatusContractTest.java" \
  "$APP_ROOT/host-tests/com/exploitintel/forgecontrol/ControlActionsContractTest.java" \
  "$APP_ROOT/host-tests/com/exploitintel/forgecontrol/OperationCoordinatorContractTest.java"
"$JDK_ROOT/bin/java" \
  -cp "$OUTPUT_DIR" \
  com.exploitintel.forgecontrol.HostStatusContractTest
"$JDK_ROOT/bin/java" \
  -cp "$OUTPUT_DIR" \
  com.exploitintel.forgecontrol.OperationCoordinatorContractTest
"$JDK_ROOT/bin/java" \
  -cp "$OUTPUT_DIR" \
  com.exploitintel.forgecontrol.ControlActionsContractTest
