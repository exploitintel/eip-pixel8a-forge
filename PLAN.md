# Pixel 8a Forge delivery plan

The Pixel 8a port follows the released Pixel 11 architecture while retaining
its independently qualified `akita` kernel and boot artifacts.

1. Host lifecycle: port the proven module lifecycle and toolchain, adapt exact
   Pixel 8a identity and storage behavior, then prove start, stop, reboot,
   Docker networking, and Wi-Fi.
2. Forge runtime and control app: port the device-neutral operator runtime and
   Android controller, then prove Web UI, Agent, start, park, and idle parking.
3. Online delivery: publish Pixel 8a controller and operator images by digest
   while keeping Forge pinned by `FORGE_REVISION`.
4. Installer: build the small firmware-preparation and install package for the
   exact qualified Pixel 8a build, preserving operator state on updates.
5. Qualification and release: prove update-to-READY, then after an explicit
   destructive checkpoint prove factory-wipe-to-READY using only the installer.

Each implementation slice receives focused local and live tests, one
independent review, sensible triage of review findings, and one merged PR.
Firmware, credentials, container data, and generated images remain outside
Git.
