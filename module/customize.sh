#!/system/bin/sh
# KernelSU sources this file inside its installer. Keep all host mutation in
# install-host, which runs as a subprocess and owns its own cleanup traps.

BUSYBOX=/data/adb/ksu/bin/busybox

[ "${KSU:-}" = true ] || abort "KernelSU-Next is required"
[ "${BOOTMODE:-}" = true ] || abort "installation from the KernelSU-Next manager is required"
[ "${ARCH:-}" = arm64 ] || abort "unsupported architecture: ${ARCH:-unknown}"
[ "${KSU_RUNTIME_MODE:-}" = lkm ] || abort "KernelSU runtime mode must be lkm"
[ -n "${KSU_VER:-}" ] || abort "KernelSU-Next version is unavailable"
case "${KSU_VER_CODE:-}" in
  ''|*[!0-9]*) abort "KernelSU-Next version code is unavailable or invalid" ;;
esac
case "${MODPATH:-}" in
  /*) ;;
  *) abort "MODPATH must be an absolute installer staging path" ;;
esac
case "${TMPDIR:-}" in
  /*) ;;
  *) abort "TMPDIR must be an absolute installer temporary path" ;;
esac
[ -d "$MODPATH" ] && [ ! -L "$MODPATH" ] \
  || abort "module staging directory is unavailable or unsafe"
[ -d "$TMPDIR" ] && [ ! -L "$TMPDIR" ] \
  || abort "installer temporary directory is unavailable or unsafe"
command -v ui_print >/dev/null 2>&1 || abort "KernelSU ui_print helper is unavailable"
command -v set_perm >/dev/null 2>&1 || abort "KernelSU set_perm helper is unavailable"
[ -x "$BUSYBOX" ] && [ -f "$BUSYBOX" ] && [ ! -L "$BUSYBOX" ] \
  || abort "KernelSU BusyBox is unavailable or unsafe"

for package_file in \
  "$MODPATH/module.prop" \
  "$MODPATH/host.conf.default" \
  "$MODPATH/installer-inputs.tsv" \
  "$MODPATH/release-manifest.tsv" \
  "$MODPATH/bin/hostctl" \
  "$MODPATH/bin/install-host" \
  "$MODPATH/bin/install-preflight" \
  "$MODPATH/bin/kernelctl" \
  "$MODPATH/bin/prepare-engine" \
  "$MODPATH/bin/prepare-kernel" \
  "$MODPATH/bin/release-transaction" \
  "$MODPATH/bin/patch-engine" \
  "$MODPATH/bin/swap-boot-kernel" \
  "$MODPATH/bin/privns" \
  "$MODPATH/bin/route-policy" \
  "$MODPATH/bin/dockerd.sh" \
  "$MODPATH/bin/buildkit-runc.sh" \
  "$MODPATH/action.sh" \
  "$MODPATH/service.sh" \
  "$MODPATH/boot-completed.sh" \
  "$MODPATH/uninstall.sh"
do
  [ -f "$package_file" ] && [ ! -L "$package_file" ] \
    || abort "missing regular package file: $package_file"
done

for runtime_script in \
  "$MODPATH/bin/hostctl" \
  "$MODPATH/bin/install-host" \
  "$MODPATH/bin/install-preflight" \
  "$MODPATH/bin/kernelctl" \
  "$MODPATH/bin/prepare-engine" \
  "$MODPATH/bin/prepare-kernel" \
  "$MODPATH/bin/release-transaction" \
  "$MODPATH/bin/patch-engine" \
  "$MODPATH/bin/swap-boot-kernel" \
  "$MODPATH/bin/privns" \
  "$MODPATH/bin/route-policy" \
  "$MODPATH/bin/dockerd.sh" \
  "$MODPATH/bin/buildkit-runc.sh" \
  "$MODPATH/action.sh" \
  "$MODPATH/service.sh" \
  "$MODPATH/boot-completed.sh" \
  "$MODPATH/uninstall.sh"
do
  set_perm "$runtime_script" 0 0 0755 \
    || abort "cannot apply executable package permissions: $runtime_script"
  [ -f "$runtime_script" ] && [ ! -L "$runtime_script" ] \
    && [ "$("$BUSYBOX" stat -c '%u:%g:%a' "$runtime_script" 2>/dev/null)" = 0:0:755 ] \
    || abort "executable package permissions did not converge: $runtime_script"
done
for package_data in \
  "$MODPATH/module.prop" \
  "$MODPATH/host.conf.default" \
  "$MODPATH/installer-inputs.tsv" \
  "$MODPATH/release-manifest.tsv"
do
  set_perm "$package_data" 0 0 0644 \
    || abort "cannot apply data package permissions: $package_data"
  [ -f "$package_data" ] && [ ! -L "$package_data" ] \
    && [ "$("$BUSYBOX" stat -c '%u:%g:%a' "$package_data" 2>/dev/null)" = 0:0:644 ] \
    || abort "data package permissions did not converge: $package_data"
done

ui_print "- Validating this Pixel, boot image, Docker Engine, and kernel candidate"
# KernelSU sources this file, so its documented variables need not be exported.
# Bind the complete child contract explicitly instead of depending on ash's
# inherited export flags.
INSTALL_HOST_OUTPUT=$(KSU="$KSU" BOOTMODE="$BOOTMODE" ARCH="$ARCH" \
  KSU_VER="$KSU_VER" KSU_VER_CODE="$KSU_VER_CODE" \
  KSU_RUNTIME_MODE="$KSU_RUNTIME_MODE" TMPDIR="$TMPDIR" \
  "$MODPATH/bin/install-host" 2>&1)
INSTALL_HOST_STATUS=$?
if [ "$INSTALL_HOST_STATUS" -ne 0 ]; then
  [ -n "$INSTALL_HOST_OUTPUT" ] && ui_print "$INSTALL_HOST_OUTPUT"
  if [ "$INSTALL_HOST_STATUS" -eq 3 ]; then
    abort "installation needs operator attention; the previous host selection was preserved when possible"
  fi
  abort "host installation failed before a usable module was committed"
fi

[ -n "$INSTALL_HOST_OUTPUT" ] && ui_print "$INSTALL_HOST_OUTPUT"
ui_print "- Clean hosts default to autostart off with no Docker disk allocated; existing valid host state is preserved"
ui_print "- Open the module Action to configure storage, start Docker, or install the staged kernel"
