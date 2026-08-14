#!/usr/bin/env bash
# Smoke-тест собранного ядра в QEMU.
#
# Запускается НА МАШИНЕ РАЗРАБОТЧИКА, не в CI: QEMU по умолчанию гоняется
# вручную локально (ADR-0014). Полноценной прошивки здесь нет — проверяется
# ровно то, что можно проверить на голом ядре:
#
#   1. ядро вообще загружается под arm64 virt;
#   2. BTF доступен в рантайме (/sys/kernel/btf/vmlinux), а не просто
#      присутствует секцией в vmlinux — без этого dae не стартует;
#   3. видны virtio-интерфейсы, из которых на прошивке станут WAN и LAN.
#
# Wi-Fi, hostapd, dae и DNS-поток сюда не входят: они появляются вместе с
# образом и проверяются отдельным стендом (docs/testing/ в marvin-research).
#
# Использование:
#   scripts/qemu-smoke.sh [путь-к-vmlinuz]
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
kernel=${1:-$root/out/kernel/vmlinuz}
work="$root/build/qemu"
initramfs="$work/initramfs.cpio.gz"
logfile="$work/serial.log"
timeout_s=${TIMEOUT:-120}

[ -f "$kernel" ] || {
	echo "ОШИБКА: нет ядра $kernel" >&2
	echo "Собери его в CI и положи артефакт сюда, либо укажи путь аргументом." >&2
	exit 1
}

command -v qemu-system-aarch64 >/dev/null || {
	echo "ОШИБКА: qemu-system-aarch64 не установлен." >&2
	echo "Debian/Ubuntu: sudo apt-get install -y qemu-system-arm" >&2
	exit 1
}

mkdir -p "$work"

# --- initramfs ---------------------------------------------------------------
# Минимальный: статический busybox из aarch64-репозитория Alpine плюс наш
# init. Собирается один раз и переиспользуется.
if [ ! -f "$initramfs" ]; then
	echo "== Сборка initramfs"
	command -v docker >/dev/null || {
		echo "ОШИБКА: нужен docker, чтобы достать статический busybox под aarch64." >&2
		exit 1
	}

	cat > "$work/init" <<'INIT'
#!/bin/sh
# Init минимального initramfs: печатает маркеры и выключает машину.
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

# --- запуск ------------------------------------------------------------------
# Два virtio-NIC — будущие WAN и LAN. -cpu обязателен: у virt нет дефолта.
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

# --- разбор ------------------------------------------------------------------
echo "== Результат (полный лог: $logfile)"
grep "MARVIN-SMOKE" "$logfile" || true

fail=0
grep -q "MARVIN-SMOKE: DONE" "$logfile" || {
	echo "ОШИБКА: ядро не дошло до конца init (статус qemu $qemu_status)" >&2
	tail -30 "$logfile" >&2
	fail=1
}
grep -q "MARVIN-SMOKE: BTF=yes" "$logfile" || {
	echo "ОШИБКА: BTF недоступен в рантайме — dae не сможет загрузить eBPF" >&2
	fail=1
}
grep -qE "MARVIN-SMOKE: NET=.*eth0.*eth1" "$logfile" || {
	echo "ВНИМАНИЕ: не видно двух сетевых интерфейсов" >&2
}

[ "$fail" -eq 0 ] && echo "Smoke-тест пройден"
exit "$fail"
