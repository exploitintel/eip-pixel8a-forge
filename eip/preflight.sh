#!/system/bin/sh
# Read-only Pixel host audit. This script inspects existing state only: it does
# not create containers or networks, write files, probe the Internet, contact a
# model provider, start services, or attempt repairs.

PATH=/system/bin:/system/xbin
export PATH

D=/data/docker/bin/docker
HOST_BIN_DIR=/data/docker/bin
DOCKER_SOCKET=/data/docker/run/docker.sock
DOCKER_DATA_ROOT=/data/docker/lib
DOCKERD_SCRIPT=/data/docker/dockerd.sh
BOOT_SCRIPT=/data/adb/service.d/docker.sh
KERNEL_CONFIG=/proc/config.gz
ZCAT=/system/bin/zcat
STAT=/system/bin/stat
MOUNTS=/proc/mounts
NS_DIR=/proc/self/ns
BINFMT_ENTRY=/dev/binfmt_misc/qemu-x86_64
STATE_ROOT=/data/eip-cve
SOURCE_ROOT=/data/eip-cve-src
EXPECTED_UID=2000
EXPECTED_GID=2000

DOCKER_HOST="unix://$DOCKER_SOCKET"
export DOCKER_HOST

PASS=0
FAIL=0
WARN=0

ok() {
  PASS=$((PASS + 1))
  printf 'PASS  %s\n' "$1"
}

bad() {
  FAIL=$((FAIL + 1))
  printf 'FAIL  %s\n' "$1"
}

warn() {
  WARN=$((WARN + 1))
  printf 'WARN  %s\n' "$1"
}

hdr() {
  printf '\n== %s ==\n' "$1"
}

directory_content_state() {
  first_entry=$(find "$1" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)
  find_status=$?
  [ "$find_status" -eq 0 ] || return 2
  [ -n "$first_entry" ] && return 0
  return 1
}

check_executable() {
  if [ -f "$1" ] && [ ! -L "$1" ] && [ -x "$1" ]; then
    ok "$2 is a regular executable"
  else
    bad "$2 is missing, linked, non-regular, or not executable"
  fi
}

check_managed_file() {
  path=$1
  expected_mode=$2
  label=$3
  if [ ! -f "$path" ] || [ -L "$path" ]; then
    bad "$label is missing, linked, or non-regular"
    return
  fi
  metadata=$("$STAT" -c '%a|%u|%g' "$path" 2>/dev/null || true)
  expected="${expected_mode}|${EXPECTED_UID}|${EXPECTED_GID}"
  if [ "$metadata" = "$expected" ]; then
    ok "$label has mode $expected_mode and the expected owner"
  else
    bad "$label mode or owner does not match the deployment contract"
  fi
}

check_managed_directory() {
  path=$1
  expected_mode=$2
  label=$3
  if [ ! -d "$path" ] || [ -L "$path" ]; then
    bad "$label is missing, linked, or non-directory"
    return
  fi
  metadata=$("$STAT" -c '%a|%u|%g' "$path" 2>/dev/null || true)
  expected="${expected_mode}|${EXPECTED_UID}|${EXPECTED_GID}"
  if [ "$metadata" = "$expected" ]; then
    ok "$label has mode $expected_mode and the expected owner"
  else
    bad "$label mode or owner does not match the deployment contract"
  fi
}

hdr "1. host kernel"
if [ -r "$KERNEL_CONFIG" ]; then
  for option in SYSVIPC POSIX_MQUEUE PID_NS IPC_NS USER_NS OVERLAY_FS VETH; do
    if "$ZCAT" "$KERNEL_CONFIG" 2>/dev/null | grep -q "^CONFIG_${option}=y$"; then
      ok "CONFIG_${option} enabled"
    else
      bad "CONFIG_${option} missing"
    fi
  done
else
  bad "kernel config is not readable"
fi

for namespace in pid ipc user; do
  if [ -e "$NS_DIR/$namespace" ]; then
    ok "$namespace namespace present"
  else
    bad "$namespace namespace missing"
  fi
done

hdr "2. Docker host"
for binary in docker dockerd containerd containerd-shim-runc-v2 runc privns; do
  check_executable "$HOST_BIN_DIR/$binary" "$binary"
done
check_executable "$DOCKERD_SCRIPT" "dockerd startup script"
check_executable "$BOOT_SCRIPT" "KernelSU Docker service script"

if [ -S "$DOCKER_SOCKET" ]; then
  ok "Docker socket exists and is a socket"
else
  bad "Docker socket is missing or is not a socket"
fi

docker_ready=0
daemon_details=$("$D" info --format '{{.ServerVersion}}|{{.Driver}}|{{.CgroupDriver}}|{{.CgroupVersion}}|{{.DockerRootDir}}|{{.Architecture}}' 2>/dev/null || true)
if [ -n "$daemon_details" ]; then
  field_count=$(printf '%s\n' "$daemon_details" | awk -F '|' '{ print NF }')
  if [ "$field_count" -eq 6 ]; then
    docker_ready=1
    server=$(printf '%s\n' "$daemon_details" | awk -F '|' '{ print $1 }')
    driver=$(printf '%s\n' "$daemon_details" | awk -F '|' '{ print $2 }')
    cgroup_driver=$(printf '%s\n' "$daemon_details" | awk -F '|' '{ print $3 }')
    cgroup_version=$(printf '%s\n' "$daemon_details" | awk -F '|' '{ print $4 }')
    daemon_root=$(printf '%s\n' "$daemon_details" | awk -F '|' '{ print $5 }')
    architecture=$(printf '%s\n' "$daemon_details" | awk -F '|' '{ print $6 }')
    if [ -n "$server" ] && [ "$server" != "<no value>" ]; then
      ok "Docker daemon reachable: server=$server"
    else
      bad "Docker server version is unavailable"
    fi
    if [ "$driver" = "overlay2" ]; then
      ok "Docker storage driver is overlay2"
    else
      bad "Docker storage driver is not overlay2"
    fi
    if [ "$cgroup_driver" = "cgroupfs" ] && [ "$cgroup_version" = "2" ]; then
      ok "Docker cgroup mode is cgroupfs/2"
    else
      bad "Docker cgroup mode is not cgroupfs/2"
    fi
    if [ "$daemon_root" = "$DOCKER_DATA_ROOT" ]; then
      ok "Docker reports the expected data root"
    else
      bad "Docker reports an unexpected data root"
    fi
    case "$architecture" in
      aarch64|arm64) ok "Docker architecture is $architecture" ;;
      *) bad "Docker architecture is not arm64" ;;
    esac
  else
    bad "Docker daemon metadata is incomplete"
  fi
else
  bad "Docker daemon is unreachable"
fi

mount_type=$(awk -v target="$DOCKER_DATA_ROOT" '$2 == target { print $3; exit }' "$MOUNTS" 2>/dev/null || true)
if [ "$mount_type" = "ext4" ]; then
  ok "Docker data root is an ext4 mount"
else
  bad "Docker data root is not an ext4 mount"
fi

if [ -d "$DOCKER_DATA_ROOT" ]; then
  free_kb=$(df -k "$DOCKER_DATA_ROOT" 2>/dev/null | awk 'END { print $4 }')
  case "$free_kb" in
    ''|*[!0-9]*) warn "Docker data-root free space could not be read" ;;
    *)
      free_gib=$((free_kb / 1048576))
      if [ "$free_gib" -ge 20 ]; then
        ok "Docker data root has ${free_gib} GiB free"
      else
        warn "Docker data root has only ${free_gib} GiB free"
      fi
      ;;
  esac
else
  bad "Docker data root is missing"
fi

if [ -e "$BINFMT_ENTRY" ]; then
  ok "amd64 binfmt handler is registered"
else
  bad "amd64 binfmt handler is missing"
fi

hdr "3. deployment presence"
if [ -L "$STATE_ROOT" ]; then
  bad "Forge state root is a symlink"
elif [ ! -d "$STATE_ROOT" ]; then
  warn "Forge is not bootstrapped; state-root checks skipped"
else
  directory_content_state "$STATE_ROOT"
  state_content=$?
  if [ "$state_content" -eq 2 ]; then
    bad "Forge state root cannot be inspected"
  elif [ "$state_content" -eq 1 ]; then
    warn "Forge state root is empty; bootstrap has not completed"
  else
    ok "Forge state root is populated"
    check_managed_directory "$STATE_ROOT" 750 "Forge state root"
    for relative in state workspace publish-target run gh ollama kimi-pipeline agent-kimi agent-hermes config; do
      check_managed_directory "$STATE_ROOT/$relative" 750 "$relative directory"
    done
    check_managed_directory "$STATE_ROOT/state/managed-skills" 700 "managed-skills directory"
    check_managed_file "$STATE_ROOT/container.env" 644 "container.env"
    check_managed_file "$STATE_ROOT/config/eip-cve-ui.env" 600 "UI secret environment"
    check_managed_file "$STATE_ROOT/config/eip-cve-agent-chat.env" 600 "chat secret environment"
    check_managed_file "$STATE_ROOT/config/local.json" 644 "local configuration"
  fi
fi

if [ -L "$SOURCE_ROOT" ]; then
  bad "Forge source root is a symlink"
elif [ ! -d "$SOURCE_ROOT" ]; then
  warn "Forge source is not installed; source checks skipped"
else
  directory_content_state "$SOURCE_ROOT"
  source_content=$?
  if [ "$source_content" -eq 2 ]; then
    bad "Forge source root cannot be inspected"
  elif [ "$source_content" -eq 1 ]; then
    warn "Forge source root is empty; source installation has not completed"
  elif [ ! -d "$SOURCE_ROOT/deploy/container" ] ||
       [ -L "$SOURCE_ROOT/deploy" ] ||
       [ -L "$SOURCE_ROOT/deploy/container" ]; then
    bad "source deploy/container path is missing, linked, or non-directory"
  else
    if [ -f "$SOURCE_ROOT/deploy/container/compose.yaml" ] &&
       [ ! -L "$SOURCE_ROOT/deploy/container/compose.yaml" ] &&
       [ -r "$SOURCE_ROOT/deploy/container/compose.yaml" ]; then
      ok "source compose.yaml is a regular readable file"
    else
      bad "source compose.yaml is missing, linked, non-regular, or unreadable"
    fi
    check_executable "$SOURCE_ROOT/deploy/container/bootstrap.sh" "source bootstrap.sh"
    check_executable "$SOURCE_ROOT/deploy/container/verify.sh" "source verify.sh"
  fi
fi

if [ "$docker_ready" -eq 1 ]; then
  for image in eip-operator-shell:phone eip-cve-controller:local; do
    if "$D" image inspect "$image" >/dev/null 2>&1; then
      ok "image is present: $image"
    else
      warn "image is not present: $image"
    fi
  done

  containers=$("$D" ps -a --format '{{.Names}}' 2>/dev/null || true)
  for container in eip-cve-ui-1 eip-cve-chat-1; do
    if printf '%s\n' "$containers" | grep -qx "$container"; then
      state=$("$D" container inspect --format '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container" 2>/dev/null || true)
      case "$state" in
        running\|healthy) ok "$container is running and healthy" ;;
        running\|none) warn "$container is running without a health check" ;;
        running\|starting) warn "$container health check is still starting" ;;
        *) bad "$container state is ${state:-unknown}" ;;
      esac
    else
      warn "$container is not deployed"
    fi
  done
else
  warn "image and container checks skipped because Docker is unreachable"
fi

printf '\n===================================\n'
printf 'host audit: %s passed, %s failed, %s warnings\n' "$PASS" "$FAIL" "$WARN"
[ "$FAIL" -eq 0 ]
