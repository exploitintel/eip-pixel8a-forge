#!/system/bin/sh
# Root-only, fail-closed lifecycle authority for the Pixel Docker/Forge host.
# It preserves Docker data and evidence: no deletion, force-kill, unmount, network,
# provider, or credential operation is available here.
set -u

PATH=/data/docker/bin:/system/bin:/system/xbin
export PATH
DOCKER=/data/docker/bin/docker
DOCKERD=/data/docker/bin/dockerd
CONTAINERD=/data/docker/bin/containerd
DOCKERD_SCRIPT=/data/docker/bin/dockerd.sh
HOSTCTL=/data/docker/bin/hostctl
DOCKER_ROOT=/data/docker
DOCKER_DATA=/data/docker/lib
DOCKER_DISK=/data/docker/disk.img
DOCKER_RUN=/data/docker/run
DOCKER_SOCKET=/data/docker/run/docker.sock
DOCKER_PIDFILE=/data/docker/run/docker.pid
EIP=/data/eip-cve-ops/eip.sh
STATE_INSPECTOR=/data/eip-cve-ops/hostctl-state.mjs
BINFMT_ROOT=/dev/binfmt_misc
BINFMT_AMD64=/dev/binfmt_misc/qemu-x86_64
BINFMT_IMAGE_ID=sha256:1e791088fb9dfb63ed7ce0b248acf8b90885a54b70d40d3b8fcb0f96dab31303
BINFMT_IMAGE_DIGEST=tonistiigi/binfmt@sha256:400a4873b838d1b89194d982c45e5fb3cda4593fbfd7e08a02e76b03b21166f0
PROC_ROOT=/proc
PIDOF=/system/bin/pidof
MOUNTS=/proc/mounts
IP_FORWARD=/proc/sys/net/ipv4/ip_forward
LOCK_DIR=/data/docker/run/eip-hostctl.lock
PARK_WHEN_IDLE_MARKER=/data/docker/eip-park-when-idle
MAINTENANCE_DIR=/data/docker/eip-cve-control
MAINTENANCE_FILE=/data/docker/eip-cve-control/maintenance-v1
READY_TRIES=30
STOP_TRIES=30
SLEEP_SECONDS=2
STABLE_IDLE_SECONDS=4
DOCKER_HOST=unix:///data/docker/run/docker.sock
export DOCKER_HOST

usage() {
  printf '%s\n' 'usage: eip-hostctl.sh status|start|park|park-when-idle|cancel-park-when-idle|reconcile|logs' >&2
  exit 2
}

die() {
  printf 'eip-hostctl: %s\n' "$1" >&2
  exit "${2:-1}"
}

[ "$#" -eq 1 ] || usage
COMMAND=$1
case "$COMMAND" in
  status|start|park|park-when-idle|cancel-park-when-idle|reconcile|logs) ;;
  *) usage ;;
esac
[ "$(id -u 2>/dev/null || printf unknown)" = 0 ] || die 'root is required' 2

docker_info() {
  "$DOCKER" info >/dev/null 2>&1
}

read_pidfile() {
  READ_PID=
  [ -f "$DOCKER_PIDFILE" ] && [ ! -L "$DOCKER_PIDFILE" ] && [ -r "$DOCKER_PIDFILE" ] || return 1
  READ_PID=$(cat "$DOCKER_PIDFILE" 2>/dev/null) || return 1
  case "$READ_PID" in ''|*[!0-9]*) return 1 ;; esac
  [ "$READ_PID" -gt 1 ] 2>/dev/null || return 1
  [ "$(printf '%s\n' "$READ_PID" | wc -l | tr -d ' ')" = 1 ] || return 1
  return 0
}

exact_daemon_pid() {
  EXACT_PID=$1
  [ -d "$PROC_ROOT/$EXACT_PID" ] || return 1
  EXACT_EXE=$(readlink "$PROC_ROOT/$EXACT_PID/exe" 2>/dev/null) || return 1
  [ "$EXACT_EXE" = "$DOCKERD" ] || return 1
  [ -r "$PROC_ROOT/$EXACT_PID/cmdline" ] || return 1
  EXACT_ARGV0=$(tr '\000' '\n' < "$PROC_ROOT/$EXACT_PID/cmdline" 2>/dev/null | sed -n '1p') || return 1
  [ "$EXACT_ARGV0" = "$DOCKERD" ]
}

scan_exact_processes() {
  SCAN_EXECUTABLE=$1
  SCAN_COUNT=0
  SCAN_PID=
  SCAN_NAME=${SCAN_EXECUTABLE##*/}
  SCAN_PIDS=$($PIDOF "$SCAN_NAME" 2>/dev/null) || SCAN_PIDS=
  for SCAN_CANDIDATE in $SCAN_PIDS; do
    case "$SCAN_CANDIDATE" in ''|*[!0-9]*) continue ;; esac
    [ -d "$PROC_ROOT/$SCAN_CANDIDATE" ] || continue
    [ "$PROC_ROOT/$SCAN_CANDIDATE/exe" -ef "$SCAN_EXECUTABLE" ] 2>/dev/null || continue
    SCAN_COUNT=$((SCAN_COUNT + 1))
    SCAN_PID=$SCAN_CANDIDATE
  done
}

probe_daemon() {
  DAEMON_PID=
  DAEMON_STATE=ambiguous
  if docker_info; then
    DAEMON_PID=$(cat "$DOCKER_PIDFILE" 2>/dev/null || true)
    DAEMON_STATE=running
    return
  fi
  scan_exact_processes "$DOCKERD"
  if [ "$SCAN_COUNT" -gt 1 ]; then
    DAEMON_STATE=multiple-daemons
    return
  fi
  FOUND_DAEMON_PID=$SCAN_PID
  if [ ! -e "$DOCKER_PIDFILE" ] && [ ! -L "$DOCKER_PIDFILE" ]; then
    if [ "$SCAN_COUNT" -eq 1 ]; then
      DAEMON_PID=$FOUND_DAEMON_PID
      DAEMON_STATE=unmanaged-exact-daemon
    elif docker_info || [ -e "$DOCKER_SOCKET" ] || [ -L "$DOCKER_SOCKET" ]; then
      DAEMON_STATE=unmanaged
    else
      scan_exact_processes "$CONTAINERD"
      if [ "$SCAN_COUNT" -eq 0 ]; then DAEMON_STATE=stopped; else DAEMON_STATE=orphan-containerd; fi
    fi
    return
  fi
  if ! read_pidfile; then
    DAEMON_STATE=invalid-pidfile
    return
  fi
  DAEMON_PID=$READ_PID
  if [ "$SCAN_COUNT" -eq 1 ] && [ "$FOUND_DAEMON_PID" != "$DAEMON_PID" ]; then
    DAEMON_STATE=pidfile-mismatch
    return
  fi
  if [ ! -d "$PROC_ROOT/$DAEMON_PID" ]; then
    if [ "$SCAN_COUNT" -eq 1 ]; then
      DAEMON_STATE=pidfile-mismatch
    elif docker_info || [ -e "$DOCKER_SOCKET" ] || [ -L "$DOCKER_SOCKET" ]; then
      DAEMON_STATE=unmanaged
    else
      scan_exact_processes "$CONTAINERD"
      if [ "$SCAN_COUNT" -eq 0 ]; then DAEMON_STATE=stale-pidfile; else DAEMON_STATE=orphan-containerd; fi
    fi
    return
  fi
  if ! exact_daemon_pid "$DAEMON_PID"; then
    DAEMON_STATE=foreign-pid
    return
  fi
  if docker_info && [ -S "$DOCKER_SOCKET" ]; then
    DAEMON_STATE=running
  else
    DAEMON_STATE=unresponsive
  fi
}

inventory() {
  INVENTORY_UNKNOWN=0
  INVENTORY_TOTAL=0
  UI_ID=
  CHAT_ID=
  OLLAMA_ID=
  INVENTORY_OUTPUT=$("$DOCKER" ps --no-trunc --format '{{.ID}}|{{.Label "com.docker.compose.project"}}|{{.Label "com.docker.compose.service"}}|{{.State}}' 2>/dev/null) || return 1
  while IFS='|' read -r item_id item_project item_service item_state extra; do
    [ -n "$item_id$item_project$item_service$item_state$extra" ] || continue
    INVENTORY_TOTAL=$((INVENTORY_TOTAL + 1))
    case "$item_id" in ''|*[!0-9a-f]*) INVENTORY_UNKNOWN=$((INVENTORY_UNKNOWN + 1)); continue ;; esac
    [ "${#item_id}" -ge 12 ] && [ "${#item_id}" -le 64 ] && [ -z "$extra" ] || {
      INVENTORY_UNKNOWN=$((INVENTORY_UNKNOWN + 1)); continue;
    }
    if [ "$item_project" != eip-cve ]; then
      INVENTORY_UNKNOWN=$((INVENTORY_UNKNOWN + 1))
      continue
    fi
    case "$item_service" in
      ui)
        [ -z "$UI_ID" ] || INVENTORY_UNKNOWN=$((INVENTORY_UNKNOWN + 1))
        UI_ID=$item_id
        ;;
      chat)
        [ -z "$CHAT_ID" ] || INVENTORY_UNKNOWN=$((INVENTORY_UNKNOWN + 1))
        CHAT_ID=$item_id
        ;;
      ollama)
        [ -z "$OLLAMA_ID" ] || INVENTORY_UNKNOWN=$((INVENTORY_UNKNOWN + 1))
        OLLAMA_ID=$item_id
        ;;
      *) INVENTORY_UNKNOWN=$((INVENTORY_UNKNOWN + 1)) ;;
    esac
  done <<EOF
$INVENTORY_OUTPUT
EOF
  return 0
}

container_health() {
  HEALTH_ID=$1
  if [ -z "$HEALTH_ID" ]; then
    CONTAINER_HEALTH=stopped
    return
  fi
  HEALTH_RAW=$("$DOCKER" inspect --format '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$HEALTH_ID" 2>/dev/null) || {
    CONTAINER_HEALTH=unknown
    return
  }
  case "$HEALTH_RAW" in
    'running|healthy') CONTAINER_HEALTH=healthy ;;
    'running|starting') CONTAINER_HEALTH=starting ;;
    'running|unhealthy') CONTAINER_HEALTH=unhealthy ;;
    'exited|'*|'dead|'*|'created|'*) CONTAINER_HEALTH=stopped ;;
    *) CONTAINER_HEALTH=unknown ;;
  esac
}

forge_snapshot() {
  inventory || return 1
  container_health "$UI_ID"; UI_HEALTH=$CONTAINER_HEALTH
  container_health "$CHAT_ID"; CHAT_HEALTH=$CONTAINER_HEALTH
  if [ "$UI_HEALTH" = healthy ] && [ "$CHAT_HEALTH" = healthy ]; then
    FORGE_STATE=running
  elif [ -z "$UI_ID" ] && [ -z "$CHAT_ID" ]; then
    FORGE_STATE=stopped
  else
    FORGE_STATE=partial
  fi
  return 0
}

unknown_work() {
  WORK_STATE=ambiguous
  ACTIVE_COUNT=unknown
  ACTIVE_KIND=unknown
  ACTIVE_CVE=unknown
  ACTIVE_PHASE=unknown
  ACTIVE_STARTED_AT=unknown
}

parse_work_output() {
  WORK_OUTPUT=$1
  [ "$(printf '%s\n' "$WORK_OUTPUT" | wc -l | tr -d ' ')" = 6 ] || return 1
  [ "$(printf '%s\n' "$WORK_OUTPUT" | grep -c '^work=')" = 1 ] || return 1
  [ "$(printf '%s\n' "$WORK_OUTPUT" | grep -c '^active_count=')" = 1 ] || return 1
  [ "$(printf '%s\n' "$WORK_OUTPUT" | grep -c '^active_kind=')" = 1 ] || return 1
  [ "$(printf '%s\n' "$WORK_OUTPUT" | grep -c '^active_cve=')" = 1 ] || return 1
  [ "$(printf '%s\n' "$WORK_OUTPUT" | grep -c '^active_phase=')" = 1 ] || return 1
  [ "$(printf '%s\n' "$WORK_OUTPUT" | grep -c '^active_started_at=')" = 1 ] || return 1
  [ "$(printf '%s\n' "$WORK_OUTPUT" | grep -c -v -E '^(work|active_count|active_kind|active_cve|active_phase|active_started_at)=')" = 0 ] || return 1
  WORK_STATE=$(printf '%s\n' "$WORK_OUTPUT" | sed -n 's/^work=//p')
  ACTIVE_COUNT=$(printf '%s\n' "$WORK_OUTPUT" | sed -n 's/^active_count=//p')
  ACTIVE_KIND=$(printf '%s\n' "$WORK_OUTPUT" | sed -n 's/^active_kind=//p')
  ACTIVE_CVE=$(printf '%s\n' "$WORK_OUTPUT" | sed -n 's/^active_cve=//p')
  ACTIVE_PHASE=$(printf '%s\n' "$WORK_OUTPUT" | sed -n 's/^active_phase=//p')
  ACTIVE_STARTED_AT=$(printf '%s\n' "$WORK_OUTPUT" | sed -n 's/^active_started_at=//p')
  case "$WORK_STATE" in idle|active|ambiguous) ;; *) return 1 ;; esac
  case "$ACTIVE_COUNT" in unknown) ;; ''|*[!0-9]*) return 1 ;; esac
  case "$ACTIVE_KIND" in none|run|scout|qa|verify|publish|multiple|unknown) ;; *) return 1 ;; esac
  case "$ACTIVE_CVE" in
    none|multiple|unknown) ;;
    *) printf '%s\n' "$ACTIVE_CVE" | grep -q -E '^CVE-[0-9]{4}-[0-9]{4,}$' || return 1 ;;
  esac
  case "$ACTIVE_PHASE" in none|router|research|branch|poc|publish|scout|qa|verify|multiple|unknown) ;; *) return 1 ;; esac
  case "$ACTIVE_STARTED_AT" in none|multiple|unknown) ;; *) printf '%s\n' "$ACTIVE_STARTED_AT" | grep -q -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{3})?Z$' || return 1 ;; esac
  return 0
}

work_snapshot() {
  WORK_SNAPSHOT_MODE=${1:-status}
  WORK_SNAPSHOT_REASON=
  unknown_work
  [ "$UI_HEALTH" = healthy ] && [ -n "$UI_ID" ] || return 1
  [ -f "$STATE_INSPECTOR" ] && [ ! -L "$STATE_INSPECTOR" ] && [ -r "$STATE_INSPECTOR" ] || return 1
  case "$WORK_SNAPSHOT_MODE" in
    status)
      WORK_OUTPUT=$("$DOCKER" exec -i "$UI_ID" node --input-type=module - < "$STATE_INSPECTOR" 2>/dev/null)
      ;;
    park-proof)
      WORK_OUTPUT=$("$DOCKER" exec -i "$UI_ID" node --input-type=module - --park-proof < "$STATE_INSPECTOR" 2>/dev/null)
      ;;
    *) return 1 ;;
  esac
  WORK_STATUS=$?
  case "$WORK_STATUS" in 0|10|11) ;; *) return 1 ;; esac
  parse_work_output "$WORK_OUTPUT" || { unknown_work; return 1; }
  case "$WORK_STATUS:$WORK_STATE" in
    0:idle|10:active|11:ambiguous) return 0 ;;
    *) unknown_work; return 1 ;;
  esac
}

broker_snapshot() {
  BROKER_OK=unknown
  AGENT_BUSY=unknown
  [ -n "$CHAT_ID" ] || return 1
  BROKER_OUTPUT=$("$DOCKER" exec "$CHAT_ID" sh -c \
    "curl --silent --show-error --fail --max-time 10 --unix-socket \"\$EIP_CVE_CHAT_SOCKET\" http://localhost/v1/health" \
    2>/dev/null) || return 1
  case "$BROKER_OUTPUT" in
    *'"ok":true'*) BROKER_OK=true ;;
    *'"ok":false'*) BROKER_OK=false ;;
    *) return 1 ;;
  esac
  case "$BROKER_OUTPUT" in
    *'"busy":true'*) AGENT_BUSY=true ;;
    *'"busy":false'*) AGENT_BUSY=false ;;
    *) return 1 ;;
  esac
  return 0
}

enable_maintenance() {
  mkdir -p "$MAINTENANCE_DIR" || die 'cannot create Forge maintenance directory'
  chmod 0755 "$MAINTENANCE_DIR" || die 'cannot prepare Forge maintenance directory'
  MAINTENANCE_TEMP=$MAINTENANCE_DIR/.maintenance-v1.$$
  rm -f "$MAINTENANCE_TEMP"
  (umask 022; printf 'EIP_CVE_MAINTENANCE_V1\n' > "$MAINTENANCE_TEMP") ||
    die 'cannot create Forge maintenance record'
  chmod 0644 "$MAINTENANCE_TEMP" || {
    rm -f "$MAINTENANCE_TEMP"
    die 'cannot prepare Forge maintenance record'
  }
  mv -f "$MAINTENANCE_TEMP" "$MAINTENANCE_FILE" || {
    rm -f "$MAINTENANCE_TEMP"
    die 'cannot enable Forge maintenance'
  }
}

disable_maintenance() {
  rm -f "$MAINTENANCE_FILE" || die 'cannot disable Forge maintenance'
}

park_when_idle_snapshot() {
  if [ ! -e "$PARK_WHEN_IDLE_MARKER" ] && [ ! -L "$PARK_WHEN_IDLE_MARKER" ]; then
    DRAIN_STATE=off
  elif [ -f "$PARK_WHEN_IDLE_MARKER" ] && [ ! -L "$PARK_WHEN_IDLE_MARKER" ] &&
       [ "$(cat "$PARK_WHEN_IDLE_MARKER" 2>/dev/null)" = requested ]; then
    DRAIN_STATE=pending
  else
    DRAIN_STATE=unknown
  fi
}

status_snapshot() {
  probe_daemon
  park_when_idle_snapshot
  BOOT_POLICY=unmanaged
  case "$DAEMON_STATE" in
    stopped)
      SYSTEM_STATE=parked
      DOCKER_STATE=stopped
      FORGE_STATE=stopped
      UI_HEALTH=stopped
      CHAT_HEALTH=stopped
      INVENTORY_UNKNOWN=0
      WORK_STATE=idle
      ACTIVE_COUNT=0
      ACTIVE_KIND=none
      ACTIVE_CVE=none
      ACTIVE_PHASE=none
      ACTIVE_STARTED_AT=none
      ;;
    running)
      DOCKER_STATE=running
      if ! forge_snapshot; then
        SYSTEM_STATE=attention
        FORGE_STATE=unknown
        UI_HEALTH=unknown
        CHAT_HEALTH=unknown
        INVENTORY_UNKNOWN=unknown
        unknown_work
      else
        if [ "$INVENTORY_TOTAL" = 0 ]; then
          WORK_STATE=idle
          ACTIVE_COUNT=0
          ACTIVE_KIND=none
          ACTIVE_CVE=none
          ACTIVE_PHASE=none
          ACTIVE_STARTED_AT=none
        else
          work_snapshot || true
        fi
        if [ "$INVENTORY_UNKNOWN" != 0 ]; then
          SYSTEM_STATE=attention
        elif [ "$FORGE_STATE" = running ] && [ "$WORK_STATE" = idle ]; then
          SYSTEM_STATE=ready
        elif [ "$FORGE_STATE" = running ] && [ "$WORK_STATE" = active ]; then
          SYSTEM_STATE=running
        elif [ "$FORGE_STATE" = running ]; then
          SYSTEM_STATE=attention
        else
          SYSTEM_STATE=degraded
        fi
      fi
      ;;
    *)
      SYSTEM_STATE=attention
      DOCKER_STATE=ambiguous
      FORGE_STATE=unknown
      UI_HEALTH=unknown
      CHAT_HEALTH=unknown
      INVENTORY_UNKNOWN=unknown
      unknown_work
      ;;
  esac
}

print_status() {
  status_snapshot
  printf '%s\n' \
    'schema_version=1' \
    "system=$SYSTEM_STATE" \
    "docker=$DOCKER_STATE" \
    "forge=$FORGE_STATE" \
    "work=$WORK_STATE" \
    "ui_health=$UI_HEALTH" \
    "chat_health=$CHAT_HEALTH" \
    "unknown_containers=$INVENTORY_UNKNOWN" \
    "drain=$DRAIN_STATE" \
    "boot_policy=$BOOT_POLICY" \
    "active_count=$ACTIVE_COUNT" \
    "active_kind=$ACTIVE_KIND" \
    "active_cve=$ACTIVE_CVE" \
    "active_phase=$ACTIVE_PHASE" \
    "active_started_at=$ACTIVE_STARTED_AT"
}

release_lock() {
  rm -f "$LOCK_DIR/pid" 2>/dev/null || true
  rmdir "$LOCK_DIR" 2>/dev/null || true
}

release_for_signal() {
  SIGNAL_STATUS=$1
  trap - EXIT HUP INT TERM
  release_lock
  exit "$SIGNAL_STATUS"
}

acquire_lock() {
  [ -d "$DOCKER_RUN" ] && [ ! -L "$DOCKER_RUN" ] || die 'Docker run directory is unavailable'
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    if [ -d "$LOCK_DIR" ] && [ ! -L "$LOCK_DIR" ] &&
       [ -f "$LOCK_DIR/pid" ] && [ ! -L "$LOCK_DIR/pid" ]; then
      LOCK_PID=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
      case "$LOCK_PID" in ''|*[!0-9]*) die 'lifecycle lock is malformed; refusing recovery' ;; esac
      [ ! -d "$PROC_ROOT/$LOCK_PID" ] || die 'another lifecycle operation is in progress'
      rm -f "$LOCK_DIR/pid" || die 'cannot remove proved-stale lifecycle lock owner'
      rmdir "$LOCK_DIR" || die 'cannot remove proved-stale lifecycle lock'
      mkdir "$LOCK_DIR" 2>/dev/null || die 'another lifecycle operation is in progress'
    else
      die 'lifecycle lock is ambiguous; refusing recovery'
    fi
  fi
  printf '%s\n' "$$" > "$LOCK_DIR/pid" || { rmdir "$LOCK_DIR"; die 'cannot record lifecycle lock'; }
  chmod 0700 "$LOCK_DIR" || { release_lock; die 'cannot protect lifecycle lock'; }
  chmod 0600 "$LOCK_DIR/pid" || { release_lock; die 'cannot protect lifecycle lock owner'; }
  trap release_lock EXIT
  trap 'release_for_signal 129' HUP
  trap 'release_for_signal 130' INT
  trap 'release_for_signal 143' TERM
}

require_start_prerequisites() {
  mkdir -p "$MAINTENANCE_DIR" || die 'cannot create Forge maintenance directory'
  for executable in "$HOSTCTL" "$DOCKER" "$DOCKERD" "$CONTAINERD" "$DOCKERD_SCRIPT" "$EIP"; do
    [ -f "$executable" ] && [ ! -L "$executable" ] && [ -x "$executable" ] ||
      die "required executable is unavailable: $executable"
  done
  grep -q '^HOSTCTL_RUNTIME_ONLY_CONTRACT=1$' "$DOCKERD_SCRIPT" 2>/dev/null ||
    die 'installed Docker startup script lacks the reviewed runtime-only contract; reinstall the matched host bundle'
  [ -f "$STATE_INSPECTOR" ] && [ ! -L "$STATE_INSPECTOR" ] && [ -r "$STATE_INSPECTOR" ] ||
    die 'run-state inspector is unavailable'
}

binfmt_amd64_ready() {
  awk -v target="$BINFMT_ROOT" '$2 == target && $3 == "binfmt_misc" { found=1 } END { exit found ? 0 : 1 }' "$MOUNTS" 2>/dev/null || return 1
  [ -e "$BINFMT_AMD64" ] || return 1
  grep -q '^enabled$' "$BINFMT_AMD64" 2>/dev/null || return 1
  grep -q '^interpreter /usr/bin/qemu-x86_64$' "$BINFMT_AMD64" 2>/dev/null || return 1
  BINFMT_FLAGS=$(sed -n 's/^flags: //p' "$BINFMT_AMD64" 2>/dev/null)
  case "$BINFMT_FLAGS" in *F*) return 0 ;; *) return 1 ;; esac
}

ensure_binfmt_amd64() {
  binfmt_amd64_ready && return 0

  [ ! -L "$BINFMT_ROOT" ] || die 'binfmt mountpoint is a symlink; refusing repair'
  if ! awk -v target="$BINFMT_ROOT" '$2 == target && $3 == "binfmt_misc" { found=1 } END { exit found ? 0 : 1 }' "$MOUNTS" 2>/dev/null; then
    mkdir -p "$BINFMT_ROOT" || die 'cannot create the binfmt mountpoint'
    mount -t binfmt_misc none "$BINFMT_ROOT" || die 'cannot mount binfmt_misc for amd64 registration'
    awk -v target="$BINFMT_ROOT" '$2 == target && $3 == "binfmt_misc" { found=1 } END { exit found ? 0 : 1 }' "$MOUNTS" 2>/dev/null ||
      die 'binfmt_misc mount did not become visible'
  fi

  BINFMT_IMAGE_METADATA=$("$DOCKER" image inspect --format '{{.Id}}|{{.Architecture}}' "$BINFMT_IMAGE_ID" 2>/dev/null) ||
    die 'pinned amd64 binfmt image is not cached; refusing a network pull'
  [ "$BINFMT_IMAGE_METADATA" = "$BINFMT_IMAGE_ID|arm64" ] ||
    die 'cached amd64 binfmt image identity or architecture is invalid'
  BINFMT_IMAGE_DIGESTS=$("$DOCKER" image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$BINFMT_IMAGE_ID" 2>/dev/null) ||
    die 'cannot inspect the pinned amd64 binfmt image digest'
  printf '%s\n' "$BINFMT_IMAGE_DIGESTS" | grep -Fx "$BINFMT_IMAGE_DIGEST" >/dev/null ||
    die 'cached amd64 binfmt image digest is invalid'

  "$DOCKER" run --pull=never --network=none --privileged --rm \
    "$BINFMT_IMAGE_ID" --install amd64 >/dev/null ||
    die 'pinned amd64 binfmt registration failed; Docker remains available for recovery'
  binfmt_amd64_ready ||
    die 'amd64 binfmt registration did not become ready; Docker remains available for recovery'
}

start_docker() {
  "$HOSTCTL" start >/dev/null || die 'Pixel host failed to start Docker'
  probe_daemon
  [ "$DAEMON_STATE" = running ] || die "Docker did not become ready (state=$DAEMON_STATE)"
}

start_system() {
  enable_maintenance
  require_start_prerequisites
  start_docker
  forge_snapshot || die 'cannot inspect Docker container ownership before Forge start'
  [ "$INVENTORY_UNKNOWN" = 0 ] || die 'unknown containers are present; refusing Forge start'
  ensure_binfmt_amd64
  "$EIP" up || die 'Forge start failed; Docker remains available for recovery'
  START_ATTEMPT=0
  while [ "$START_ATTEMPT" -lt "$READY_TRIES" ]; do
    forge_snapshot || die 'cannot inspect Forge health after start'
    [ "$INVENTORY_UNKNOWN" = 0 ] || die 'unknown container appeared during Forge start'
    if [ "$FORGE_STATE" = running ]; then
      break
    fi
    sleep "$SLEEP_SECONDS"
    START_ATTEMPT=$((START_ATTEMPT + 1))
  done
  [ "$FORGE_STATE" = running ] ||
    die "Forge did not become healthy (ui=$UI_HEALTH chat=$CHAT_HEALTH); Docker remains available for recovery"

  disable_maintenance
  START_ATTEMPT=0
  while [ "$START_ATTEMPT" -lt "$READY_TRIES" ]; do
    forge_snapshot || {
      enable_maintenance
      die 'cannot inspect Forge health after reopening admission'
    }
    if [ "$INVENTORY_UNKNOWN" = 0 ] && [ "$FORGE_STATE" = running ] &&
       broker_snapshot && [ "$BROKER_OK" = true ]; then
      rm -f "$PARK_WHEN_IDLE_MARKER" || {
        enable_maintenance
        die 'Forge is ready but the park-when-idle marker could not be cleared'
      }
      printf '%s\n' 'result=ready'
      return 0
    fi
    sleep "$SLEEP_SECONDS"
    START_ATTEMPT=$((START_ATTEMPT + 1))
  done
  enable_maintenance
  die "Forge did not pass normal post-maintenance health (ui=$UI_HEALTH chat=$CHAT_HEALTH broker=$BROKER_OK); Docker remains available for recovery"
}

safe_idle_snapshot() {
  probe_daemon
  [ "$DAEMON_STATE" = running ] || { PARK_REASON="docker-$DAEMON_STATE"; return 1; }
  forge_snapshot || { PARK_REASON=container-inventory-unavailable; return 1; }
  [ "$INVENTORY_UNKNOWN" = 0 ] || { PARK_REASON=unknown-containers; return 1; }
  if [ "$INVENTORY_TOTAL" = 0 ]; then
    PARK_REASON=safe
    return 0
  fi
  [ "$FORGE_STATE" = running ] || { PARK_REASON=forge-not-healthy; return 1; }
  work_snapshot park-proof || {
    PARK_REASON=${WORK_SNAPSHOT_REASON:-run-metadata-ambiguous}
    return 1
  }
  case "$WORK_STATE" in
    idle) ;;
    active) PARK_REASON=active-work; return 1 ;;
    *) PARK_REASON=run-metadata-ambiguous; return 1 ;;
  esac
  broker_snapshot || { PARK_REASON=agent-state-unavailable; return 1; }
  [ "$AGENT_BUSY" = false ] || { PARK_REASON=agent-busy; return 1; }
  PARK_REASON=safe
  return 0
}

stop_exact_daemon() {
  "$HOSTCTL" stop >/dev/null || die 'Pixel host failed to stop Docker'
  probe_daemon
  [ "$DAEMON_STATE" = stopped ] || die "Docker did not stop cleanly (state=$DAEMON_STATE)"
}

park_system() {
  PARK_MODE=${1:-immediate}
  enable_maintenance
  probe_daemon
  if [ "$DAEMON_STATE" = stopped ]; then
    rm -f "$PARK_WHEN_IDLE_MARKER" || die 'cannot clear park-when-idle marker'
    printf '%s\n' 'result=parked'
    return 0
  fi
  if ! safe_idle_snapshot; then
    [ "$PARK_MODE" = pending ] || disable_maintenance
    return 3
  fi
  sleep "$STABLE_IDLE_SECONDS"
  if ! safe_idle_snapshot; then
    [ "$PARK_MODE" = pending ] || disable_maintenance
    return 3
  fi
  if [ "$INVENTORY_TOTAL" -gt 0 ]; then
    "$EIP" down || die 'Forge did not stop cleanly; Docker remains running'
  fi
  inventory || die 'cannot inspect containers after Forge stop; Docker remains running'
  [ "$INVENTORY_TOTAL" = 0 ] || die 'containers remain after Forge stop; Docker remains running'
  stop_exact_daemon
  rm -f "$PARK_WHEN_IDLE_MARKER" || die 'system is parked but park-when-idle marker could not be cleared'
  printf '%s\n' 'result=parked'
}

write_park_when_idle_marker() {
  enable_maintenance
  PARK_TEMP=$PARK_WHEN_IDLE_MARKER.tmp.$$
  rm -f "$PARK_TEMP"
  (umask 077; printf '%s\n' requested > "$PARK_TEMP") || {
    disable_maintenance
    die 'cannot create park-when-idle marker'
  }
  chmod 0600 "$PARK_TEMP" || {
    rm -f "$PARK_TEMP"
    disable_maintenance
    die 'cannot protect park-when-idle marker'
  }
  mv -f "$PARK_TEMP" "$PARK_WHEN_IDLE_MARKER" || {
    rm -f "$PARK_TEMP"
    disable_maintenance
    die 'cannot publish park-when-idle marker'
  }
  printf '%s\n' 'result=pending'
}

cancel_park_when_idle() {
  rm -f "$PARK_WHEN_IDLE_MARKER" || die 'cannot clear park-when-idle marker'
  disable_maintenance
  printf '%s\n' 'result=cancelled'
}

reconcile_park_when_idle() {
  park_when_idle_snapshot
  case "$DRAIN_STATE" in
    off) printf '%s\n' 'result=idle'; return 0 ;;
    unknown) die 'park-when-idle marker is malformed' ;;
  esac
  park_system pending
  PARK_STATUS=$?
  if [ "$PARK_STATUS" -eq 3 ]; then
    printf 'result=pending\nreason=%s\n' "$PARK_REASON"
    return 0
  fi
  return "$PARK_STATUS"
}

bounded_logs() {
  printf '%s\n' '== dockerd (last 80 lines, at most 64 KiB) =='
  if [ -f "$DOCKER_ROOT/dockerd.log" ] && [ ! -L "$DOCKER_ROOT/dockerd.log" ]; then
    tail -c 65536 "$DOCKER_ROOT/dockerd.log" 2>/dev/null | tail -n 80
  else
    printf '%s\n' '(unavailable)'
  fi
  probe_daemon
  [ "$DAEMON_STATE" = running ] || return 0
  inventory || return 0
  for LOG_ID in "$UI_ID" "$CHAT_ID"; do
    [ -n "$LOG_ID" ] || continue
    printf '%s\n' "== container $LOG_ID (last 80 lines, at most 64 KiB) =="
    "$DOCKER" logs --tail 80 "$LOG_ID" 2>&1 | tail -c 65536
  done
}

case "$COMMAND" in
  status) print_status ;;
  logs) bounded_logs ;;
  start) acquire_lock; start_system ;;
  park)
    acquire_lock
    park_system
    PARK_STATUS=$?
    [ "$PARK_STATUS" -ne 3 ] || die "park refused: $PARK_REASON"
    exit "$PARK_STATUS"
    ;;
  park-when-idle) acquire_lock; write_park_when_idle_marker ;;
  cancel-park-when-idle) acquire_lock; cancel_park_when_idle ;;
  reconcile) acquire_lock; reconcile_park_when_idle ;;
esac
