#!/usr/bin/env bash
# Smoke test of the built kernel under QEMU.
#
# Runs ON A DEVELOPER MACHINE, not in CI: QEMU is driven manually and locally
# by default (ADR-0014). There is no full firmware here — this checks exactly
# what a bare kernel allows checking:
#
#   1. the kernel boots at all under arm64 virt;
#   2. BTF is available at runtime (/sys/kernel/btf/vmlinux), not merely
#      present as a section in vmlinux — dae does not start without it;
#   3. the virtio interfaces that will become WAN and LAN in the firmware are
#      visible.
#
# Wi-Fi, hostapd, dae and the DNS flow are out of scope here: they arrive with
# the image and are exercised on a separate rig (docs/testing/ in
# marvin-research).
#
# Usage:
#   scripts/qemu-smoke.sh [path-to-vmlinuz]
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
kernel=${1:-$root/out/kernel/vmlinuz}
work="$root/build/qemu"
initramfs="$work/initramfs.cpio.gz"
logfile="$work/serial.log"
timeout_s=${TIMEOUT:-120}

[ -f "$kernel" ] || {
	echo "ERROR: no kernel at $kernel" >&2
	echo "Build it in CI and drop the artifact here, or pass a path as an arg." >&2
	exit 1
}

command -v qemu-system-aarch64 >/dev/null || {
	echo "ERROR: qemu-system-aarch64 is not installed." >&2
	echo "Debian/Ubuntu: sudo apt-get install -y qemu-system-arm" >&2
	exit 1
}

mkdir -p "$work"

# --- initramfs ---------------------------------------------------------------
# Minimal: a static busybox from the Alpine aarch64 repository plus our own
# init. Built once and reused.
if [ ! -f "$initramfs" ]; then
	echo "== Building initramfs"
	command -v docker >/dev/null || {
		echo "ERROR: docker is required to fetch a static aarch64 busybox." >&2
		exit 1
	}

	cat > "$work/init" <<'INIT'
#!/bin/sh
# Init of the minimal initramfs: prints markers and powers the machine off.
mount -t proc none /proc 2>/dev/null
mount -t sysfs none /sys 2>/dev/null

if [ -f /sys/kernel/btf/vmlinux ]; then
	echo "MARVIN-SMOKE: BTF=yes size=$(wc -c < /sys/kernel/btf/vmlinux)"
else
	echo "MARVIN-SMOKE: BTF=no"
fi

echo "MARVIN-SMOKE: NET=$(ls /sys/class/net | tr '\n' ',')"
echo "MARVIN-SMOKE: KERNEL=$(cat /proc/version | cut -d' ' -f3)"
echo "MARVIN-SMOKE: DONE"

poweroff -f
INIT

	docker run --rm -v "$work:/w" alpine:3.22 sh -c '
		set -e
		apk add -q --no-cache --arch aarch64 --allow-untrusted \
			--root /r --initdb \
			--repository https://dl-cdn.alpinelinux.org/alpine/v3.22/main \
			busybox-static
		mkdir -p /r/proc /r/sys /r/dev
		cp /r/bin/busybox.static /r/bin/busybox 2>/dev/null || true
		for a in sh mount ls cat wc poweroff; do ln -sf /bin/busybox /r/bin/$a; done
		cp /w/init /r/init && chmod +x /r/init
		cd /r && find . | cpio -o -H newc 2>/dev/null | gzip -9 > /w/initramfs.cpio.gz
	'
	echo "initramfs: $(du -h "$initramfs" | cut -f1)"
fi

# --- run ---------------------------------------------------------------------
# Two virtio NICs — the future WAN and LAN. -cpu is mandatory: virt has no
# default.
echo "== QEMU"
set +e
timeout "$timeout_s" qemu-system-aarch64 \
	-M virt -cpu cortex-a72 -m 1024 -smp 2 \
	-nographic -no-reboot \
	-kernel "$kernel" \
	-initrd "$initramfs" \
	-append "console=ttyAMA0 panic=1" \
	-netdev user,id=wan -device virtio-net-device,netdev=wan \
	-netdev user,id=lan -device virtio-net-device,netdev=lan \
	> "$logfile" 2>&1
qemu_status=$?
set -e

# --- analysis ----------------------------------------------------------------
echo "== Result (full log: $logfile)"
grep "MARVIN-SMOKE" "$logfile" || true

fail=0
grep -q "MARVIN-SMOKE: DONE" "$logfile" || {
	echo "ERROR: kernel did not reach the end of init (qemu status $qemu_status)" >&2
	tail -30 "$logfile" >&2
	fail=1
}
grep -q "MARVIN-SMOKE: BTF=yes" "$logfile" || {
	echo "ERROR: BTF unavailable at runtime — dae will not be able to load eBPF" >&2
	fail=1
}
grep -qE "MARVIN-SMOKE: NET=.*eth0.*eth1" "$logfile" || {
	echo "WARNING: two network interfaces are not visible" >&2
}

[ "$fail" -eq 0 ] && echo "Smoke test passed"
exit "$fail"
