#!/usr/bin/env bash
# Air-gapped Ubuntu QEMU VM for the nix-airgap end-to-end test.
#
# The VM uses QEMU user networking with `restrict=on`, so the guest has no route
# to the host network or the internet. The only way in is the forwarded SSH port
# on 127.0.0.1, which stands in for the "rsync across the air gap" step.
#
# Usage: tests/vm.sh {prepare|start|stop|ssh|scp|reset|status}
set -o errexit -o nounset -o pipefail

# Kept outside the repo: path: flake inputs copy the whole directory.
WORK="${AIRGAP_VM_WORK:-${XDG_CACHE_HOME:-$HOME/.cache}/nix-airgap-e2e}"
BASE_IMG="${WORK}/noble.img"
DISK="${WORK}/disk.qcow2"
SEED="${WORK}/seed.iso"
KEY="${WORK}/id_ed25519"
PIDFILE="${WORK}/qemu.pid"
SSH_PORT="${SSH_PORT:-2222}"
VM_MEM="${VM_MEM:-4096}"
VM_CPUS="${VM_CPUS:-4}"
DISK_SIZE="${DISK_SIZE:-40G}"
UBUNTU_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"

# A stray LD_LIBRARY_PATH from the host shell can break the nixpkgs qemu.
unset LD_LIBRARY_PATH

# Pull qemu/cloud-utils from nixpkgs if they aren't on the PATH.
if ! command -v qemu-system-x86_64 >/dev/null || ! command -v cloud-localds >/dev/null; then
  exec nix shell nixpkgs#qemu_kvm nixpkgs#cloud-utils --command "$0" "$@"
fi

SSH_OPTS=(-i "$KEY" -p "$SSH_PORT" -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5)

prepare() {
  mkdir -p "$WORK"
  [[ -f "$BASE_IMG" ]] || curl -fL "$UBUNTU_URL" -o "$BASE_IMG"
  [[ -f "$KEY" ]] || ssh-keygen -q -t ed25519 -N '' -f "$KEY"

  cat >"${WORK}/user-data" <<EOF
#cloud-config
hostname: airgap
users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - $(cat "${KEY}.pub")
package_update: false
package_upgrade: false
EOF
  cloud-localds "$SEED" "${WORK}/user-data"

  if [[ ! -f "$DISK" ]]; then
    qemu-img create -q -f qcow2 -F qcow2 -b "$BASE_IMG" "$DISK" "$DISK_SIZE"
  fi
  echo "Prepared ${DISK}"
}

start() {
  [[ -f "$DISK" ]] || prepare
  if status >/dev/null; then
    echo "VM already running"
    return
  fi
  qemu-system-x86_64 \
    -enable-kvm -cpu host -m "$VM_MEM" -smp "$VM_CPUS" \
    -drive file="$DISK",if=virtio \
    -drive file="$SEED",if=virtio,format=raw,readonly=on \
    -nic "user,model=virtio-net-pci,restrict=on,hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22" \
    -display none -serial file:"${WORK}/serial.log" \
    -daemonize -pidfile "$PIDFILE"
  echo -n "Waiting for SSH"
  for _ in $(seq 120); do
    if ssh "${SSH_OPTS[@]}" ubuntu@127.0.0.1 'cloud-init status --wait >/dev/null 2>&1; true' 2>/dev/null; then
      echo " ready"
      return
    fi
    echo -n .
    sleep 2
  done
  echo " timed out (see ${WORK}/serial.log)" >&2
  return 1
}

stop() {
  if [[ -f "$PIDFILE" ]]; then
    kill "$(cat "$PIDFILE")" 2>/dev/null || true
    rm -f "$PIDFILE"
  fi
}

status() {
  [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null && echo running
}

# Throw away the VM disk so the next start is a clean machine.
reset() {
  stop
  rm -f "$DISK"
  prepare
}

cmd="${1:-}"
shift || true
case "$cmd" in
  prepare | start | stop | reset) "$cmd" ;;
  status) status || {
    echo stopped
    exit 1
  } ;;
  ssh) exec ssh "${SSH_OPTS[@]}" ubuntu@127.0.0.1 "$@" ;;
  # ./vm.sh scp <local files...>  -> copies into ~ on the VM
  scp) exec scp -i "$KEY" -P "$SSH_PORT" -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$@" ubuntu@127.0.0.1: ;;
  *)
    echo "usage: $0 {prepare|start|stop|ssh|scp|reset|status}" >&2
    exit 1
    ;;
esac
