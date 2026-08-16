# Boot script for both card layouts this package ends up on.
#
# gokrazy image:  vmlinuz + <board>.dtb in the root of the boot partition,
#                 root file system in partition 2.
# bring-up card:  Image + allwinner/<board>.dtb, no root file system at all.
#
# One script instead of two because the same boot.scr is copied into both by
# whoever assembles the card, and a mismatch shows up as a silent board.
#
# console=ttyS0: on the H618, UART0 is driven by 8250_dw, not by pl011.
# console=ttyGS0 is the serial gadget on the OTG port and is listed last so it
# becomes /dev/console — on an unmodified board the debug UART header is not
# populated, making the gadget the only console there is.
#
# The root PARTUUID is asked of U-Boot rather than hardcoded: the packer
# derives it from the MBR disk identifier, which differs per image.
#
# TODO(ota): A/B updates switch the active root by rewriting cmdline.txt on the
# boot partition. U-Boot cannot read a raw command line into a variable, so
# that switch is not honoured here yet and partition 2 is always booted.

setenv fdtfile sun50i-h618-bananapi-m4-zero.dtb
setenv consoles "console=ttyS0,115200 console=ttyGS0 earlycon"

if load mmc 0:1 ${kernel_addr_r} vmlinuz; then
	echo "Marvin: gokrazy image"
	# Корень задаётся именем устройства, а PARTUUID — только если U-Boot
	# смог его отдать. Обратный порядок опаснее, чем кажется: `part uuid`
	# зависит от CONFIG_PARTITION_UUIDS, и без него переменная остаётся
	# пустой, ядро получает `root=PARTUUID=` и вместе с `rootwait` ждёт
	# корень вечно — молча, продолжая мигать светодиодом.
	setenv rootdev /dev/mmcblk0p2
	if part uuid mmc 0:2 rootpartuuid; then
		if test -n "${rootpartuuid}"; then
			setenv rootdev "PARTUUID=${rootpartuuid}"
		fi
	fi
	echo "Marvin: root=${rootdev}"
	setenv bootargs "${consoles} root=${rootdev} rootwait init=/gokrazy/init panic=10 oops=panic"
	load mmc 0:1 ${fdt_addr_r} ${fdtfile} || load mmc 0:1 ${fdt_addr_r} allwinner/${fdtfile}
else
	echo "Marvin: bring-up card, no root file system"
	setenv bootargs "${consoles} rootwait panic=10"
	load mmc 0:1 ${kernel_addr_r} Image || echo "Marvin: no kernel found"
	load mmc 0:1 ${fdt_addr_r} allwinner/${fdtfile} || echo "Marvin: DTB not found"
fi

echo "Marvin: booting ${fdtfile}"
booti ${kernel_addr_r} - ${fdt_addr_r}
