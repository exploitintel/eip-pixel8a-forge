# Isolated native UI checks

This dependency-free instrumentation APK renders the production `ControlScreen`,
`ControlDialogs`, presentation policy, and resources. Its only callbacks increment
in-memory counters. The explicit Java source allowlist excludes the host client,
services, receivers, coordinator, and production activity. The manifest has no
permissions, and uses a distinct test-only package.

Use a disposable or read-only emulator. The script requires an explicit
`emulator-NNNN` serial and verifies Android's emulator property before installing.
It does not select, install to, or send commands to a physical device. It does not
start an emulator or change its display settings automatically.

```sh
android-app/ui-tests/run.sh --build-only
android-app/ui-tests/run.sh emulator-5580 light
```

The runner verifies Open Forge availability, the temporary reading-logs hint,
pending-park controls, and the real park/park-when-idle dialogs. Opening,
cancelling, and pressing Back must dispatch nothing; the positive button must
dispatch exactly the requested command once. Disabled confirmation buttons must
use the muted text color. It checks text height, ellipsizing, and minimum touch
height on the screen and dialogs, and captures top and bottom screenshots of
READY, RUNNING, PARK_PENDING, PARKED, and ATTENTION, plus both confirmation dialogs.
Screenshots and result logs are under the ignored `android-app/build/ui-tests/`.
Programmatic smooth scrolling is disabled only in the test host so screenshot
positioning cannot race an earlier scroll animation; native touch scrolling is
unchanged. Bottom captures assert that the screen reached the end of its content.

For additional runs, configure dark theme or a narrow portrait display with larger
font on the disposable emulator, then pass a different screenshot variant name.
Restore any changed emulator settings afterwards. These checks prove presentation
behavior only; they do not invoke Forge or validate a phone lifecycle operation.
