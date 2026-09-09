# Building Forge Control

The canonical development artifact is:

`android-app/build/offline/forge-control-debug.apk`

Build it from the Pixel repository root with:

```sh
android-app/tools/build-offline.sh
```

The script uses the installed Android 36 SDK and JDK 21, compiles without
network access, zip-aligns the APK, signs it, and verifies the result. It reads
`ANDROID_SDK_ROOT` or `ANDROID_HOME`; override the local tool locations with
`FORGE_ANDROID_SDK` and `FORGE_JAVA_HOME`.

The one canonical debug key is:

`android-app/.signing/forge-control-debug.jks`

It is deliberately ignored by Git. Preserve it in operator-controlled storage
after the first build because Android requires the same key for in-place app
updates. Losing it requires uninstalling the existing debug app before a new
key can be used. Never commit or transfer the key as deployment payload.

The Gradle debug signing configuration points to this same key, so an IDE build
cannot silently create an incompatible debug signature. The offline script is
the supported repository build path for this slice; Gradle dependency caches
on the current host are incomplete.

## UI/UX checks

The native screen follows Android's light/dark setting using Forge's Paper and
Dark color tokens from `eip-cve-public-v4/public/operator-theme.css`. Typography
uses Android system sans and monospace; controls retain at least 48dp touch
targets and the layout respects system bars, display cutouts, and larger text.

Run the local presentation and companion checks:

```sh
android-app/tools/test-host.sh
node --test tests/android-companion-contract.test.mjs
android-app/tools/build-offline.sh
```

The separate `ui-tests` APK renders the actual native screen and dialogs using
fixture status and in-memory callbacks. It never includes the host client or
background service. Its emulator checks cover light/dark and narrow large-text
layouts, WebUI availability, confirmation, cancellation, and Back behavior.
See `android-app/ui-tests/README.md` for execution and screenshot locations.
The development APK path above is distinct from the preview APK. Building or
testing does not update the installed phone app or a release installer payload.

## Installer integration

The clean installer installs the APK and then authorizes its exact
package UID through `deployment/ksu-grant-profile.c`, built as an Android
AArch64 PIE against the KernelSU-Next 3.3.0 profile ABI. The helper is an
installer payload, not part of the app process. It replaces the old KernelSU
Manager screen-coordinate flow and is removed from the phone immediately after
the profile update. See `deployment/SIMPLE-INSTALLER.md` for the build command
and accepted clean-install sequence.

Release package builds should pass the canonical production APK above to
`build-simple-package.sh --apk`; the UI preview APK is never an installer
input.
