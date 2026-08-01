#!/bin/bash
# family-matrix-server host tuning. Run as: sudo bash ./host-fixes.sh
#
# 1. UDP buffer sysctls (always): LiveKit requests 16 MiB socket buffers on
#    its single media mux port; below that it is SILENTLY capped (no warning
#    is logged at exactly 5 MB) and bursty calls drop packets server-side.
# 2. AppArmor docker-default patch (ONLY if needed): some newer kernels with
#    AppArmor 4.1 (notably Proxmox pve 6.14+) deny af_unix socket creation in
#    all docker containers ("failed protocol match" in dmesg), which crashes
#    postgres, nginx, and anything else using unix sockets. This script tests
#    for the bug first and patches only when the test fails.
#    Ref: https://github.com/containerd/containerd/issues/12726
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: must run as root (sudo bash $0)" >&2
  exit 1
fi

# ── 1. UDP buffers (unconditional) ──────────────────────────────────────────
echo "==> Setting UDP buffer sizes for LiveKit..."
cat > /etc/sysctl.d/99-family-matrix-udp-buffers.conf <<'SYSCTL_EOF'
# LiveKit requests 16 MiB UDP socket buffers on its media mux;
# must be >= 16777216 or it is silently capped.
net.core.rmem_max = 25165824
net.core.wmem_max = 25165824
SYSCTL_EOF
sysctl -p /etc/sysctl.d/99-family-matrix-udp-buffers.conf

# ── 2. AppArmor af_unix regression (conditional) ────────────────────────────
echo "==> Testing af_unix socket creation inside a container..."
TEST_IMG=docker.io/library/python:3.12-alpine
if docker run --rm "$TEST_IMG" \
    python3 -c 'import socket; a, b = socket.socketpair(); a.close(); b.close(); print("af_unix OK")'; then
  echo "==> af_unix works — AppArmor patch not needed on this host. Done."
  exit 0
fi

echo "==> af_unix is BROKEN in containers — installing patched docker-default profile..."
command -v apparmor_parser >/dev/null || { echo "ERROR: apparmor_parser not found but af_unix broken — investigate manually (dmesg | grep -i denied)" >&2; exit 1; }

TMP_PROFILE=$(mktemp)
trap 'rm -f "$TMP_PROFILE"' EXIT

cat > "$TMP_PROFILE" <<'PROFILE_EOF'
abi <abi/3.0>,
#include <tunables/global>

# Patched docker-default profile: identical to the profile dockerd generates
# at startup, plus two changes:
#  - `abi <abi/3.0>,` pin: affected kernels mediate AF_UNIX through the
#    network class in a way profiles compiled against the newer ABI cannot
#    match ("failed protocol match" denials). Pinning to the 3.0 ABI restores
#    the coarse `network,` semantics that allow unix sockets.
#  - explicit `unix,` rule (belt and suspenders under the pinned ABI).
# dockerd skips generating its built-in profile when one named docker-default
# is already loaded, so this file (loaded at boot) wins across reboots.

profile docker-default flags=(attach_disconnected,mediate_deleted) {
  #include <abstractions/base>

  network,
  unix,
  capability,
  file,
  umount,
  # Host (privileged) processes may send signals to container processes.
  signal (receive) peer=unconfined,
  # runc may send signals to container processes.
  signal (receive) peer=runc,
  # crun may send signals to container processes.
  signal (receive) peer=crun,
  # Manager may send signals to container processes.
  signal (receive) peer=/usr/bin/docker,
  # Container processes may send signals amongst themselves.
  signal (send,receive) peer=docker-default,

  deny @{PROC}/* w,   # deny write for all files directly in /proc (not in a subdir)
  # deny write to files not in /proc/<number>/** or /proc/sys/**
  deny @{PROC}/{[^1-9],[^1-9][^0-9],[^1-9s][^0-9y][^0-9s],[^1-9][^0-9][^0-9][^0-9/]*}/** w,
  deny @{PROC}/sys/[^k]** w,  # deny /proc/sys except /proc/sys/k* (effectively /proc/sys/kernel)
  deny @{PROC}/sys/kernel/{?,??,[^s][^h][^m]**} w,  # deny everything except shm* in /proc/sys/kernel/
  deny @{PROC}/sysrq-trigger rwklx,
  deny @{PROC}/kcore rwklx,

  deny mount,

  deny /sys/[^f]*/** wklx,
  deny /sys/f[^s]*/** wklx,
  deny /sys/fs/[^c]*/** wklx,
  deny /sys/fs/c[^g]*/** wklx,
  deny /sys/fs/cg[^r]*/** wklx,
  deny /sys/firmware/** rwklx,
  deny /sys/devices/virtual/powercap/** rwklx,
  deny /sys/kernel/security/** rwklx,

  # allow processes within the container to trace each other,
  # provided all other LSM and yama setting allow it.
  ptrace (trace,read,tracedby,readby) peer=docker-default,
}
PROFILE_EOF

echo "==> Validating profile syntax..."
apparmor_parser -Q "$TMP_PROFILE"

echo "==> Installing to /etc/apparmor.d/docker-default and loading..."
cp "$TMP_PROFILE" /etc/apparmor.d/docker-default
chmod 644 /etc/apparmor.d/docker-default
apparmor_parser -r /etc/apparmor.d/docker-default

echo "==> Re-testing af_unix..."
if docker run --rm "$TEST_IMG" \
    python3 -c 'import socket; a, b = socket.socketpair(); a.close(); b.close(); print("af_unix OK")'; then
  echo "==> AppArmor fix VERIFIED. Note: containers started before the fix may"
  echo "    still log harmless denial noise until their next restart."
else
  echo "ERROR: af_unix still failing — check dmesg | grep -i apparmor" >&2
  exit 1
fi
