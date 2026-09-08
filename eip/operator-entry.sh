#!/bin/bash
# Runs INSIDE the operator container on the phone. The container has the phone's
# docker socket at /var/run/docker.sock, the state root and the repo checkout
# bind-mounted at their real phone paths, and --network host so the published
# UI port on 127.0.0.1 is the same loopback compose publishes to.
set -euo pipefail

SRC=/data/eip-cve-src
OPS=/data/eip-cve-ops
ROOT=/data/eip-cve
OWNER=eipcve
UID_WANT=2000
GID_WANT=2000

export EIP_CVE_ROOT="$ROOT"
export EIP_CVE_CONTAINER_ENV="$ROOT/container.env"
ENV_FILE="$EIP_CVE_CONTAINER_ENV"

# bootstrap.sh resolves --owner through the passwd database, so the operator
# account must exist in this container with the uid/gid baked into the image.
ensure_owner() {
  if ! getent group "$GID_WANT" >/dev/null; then
    groupadd -g "$GID_WANT" "$OWNER"
  fi
  if ! getent passwd "$UID_WANT" >/dev/null; then
    useradd -u "$UID_WANT" -g "$GID_WANT" -M -s /sbin/nologin "$OWNER"
  fi
  OWNER=$(getent passwd "$UID_WANT" | cut -d: -f1)
}

# Mirrors eip-ctl.sh's file selection and appends the Android host override.
# eip-ctl.sh hardcodes its own -f list, so lifecycle commands are issued here
# instead; bootstrap and verify still run the repository's own scripts.
compose_cmd() {
  [[ -f "$ENV_FILE" ]] || { printf 'entry: %s is missing; run bootstrap first\n' "$ENV_FILE" >&2; exit 1; }
  local kvm broker
  kvm=$(grep '^EIP_CVE_KVM=' "$ENV_FILE" | cut -d= -f2- || true)
  broker=$(grep '^EIP_CVE_BROKER_VOLUME=' "$ENV_FILE" | cut -d= -f2- || true)
  COMPOSE=(docker compose --env-file "$ENV_FILE" -f "$SRC/deploy/container/compose.yaml")
  case "$kvm" in
    present) COMPOSE+=(-f "$SRC/deploy/container/compose.kvm.yaml") ;;
    absent) ;;
    *) printf 'entry: invalid EIP_CVE_KVM marker\n' >&2; exit 1 ;;
  esac
  case "$broker" in
    true) COMPOSE+=(-f "$SRC/deploy/container/compose.broker-volume.yaml") ;;
    false) ;;
    *) printf 'entry: invalid EIP_CVE_BROKER_VOLUME marker\n' >&2; exit 1 ;;
  esac
  COMPOSE+=(-f "$OPS/compose.android.yaml")
}

case "${1:-}" in
  bootstrap)
    shift
    ensure_owner
    # No usable KVM here: Android does not pass /dev/kvm to containers, and the
    # kernel lab is x86 QEMU, which gets no acceleration on arm64 regardless.
    exec "$SRC/deploy/container/bootstrap.sh" --owner "$OWNER" --root "$ROOT" --allow-no-kvm "$@"
    ;;
  up)
    shift; compose_cmd; exec "${COMPOSE[@]}" up -d "$@" ;;
  down)
    shift; compose_cmd; exec "${COMPOSE[@]}" down "$@" ;;
  ps)
    shift; compose_cmd; exec "${COMPOSE[@]}" ps "$@" ;;
  logs)
    shift; compose_cmd; exec "${COMPOSE[@]}" logs "$@" ;;
  exec)
    shift; compose_cmd; exec "${COMPOSE[@]}" exec "$@" ;;
  config)
    shift; compose_cmd; exec "${COMPOSE[@]}" config "$@" ;;
  verify)
    shift
    exec "$SRC/deploy/container/verify.sh" \
      --external-ollama --compose-file "$OPS/compose.android.yaml" "$@"
    ;;
  skills-release)
    shift
    exec python3 "$OPS/rebase-managed-skills.py" "$@"
    ;;
  managed-state)
    shift
    exec "$OPS/redeploy-managed-state.sh" "$@"
    ;;
  password)
    exec "$SRC/deploy/container/eip-ctl.sh" password
    ;;
  shell)
    shift; exec bash "$@" ;;
  *)
    printf 'usage: entry.sh bootstrap|up|down|ps|logs|exec|config|verify|skills-release|managed-state|password|shell\n' >&2
    exit 1
    ;;
esac
