# Boot script for bring-up: U-Boot looks for boot.scr on the first partition.
#
# Its purpose is bring-up stages A-D: get the board to a working kernel and
# console. The final partition layout and root parameters are decided by the
# gokrazy image build, which installs its own boot.scr.
#
# console=ttyS0: on the H618, UART0 is driven by 8250_dw, not by pl011. The
# baud rate must match chosen/stdout-path in the DTS.
#
# console=ttyGS0 is the serial gadget on the OTG port: plugged into a PC the
# board shows up as a COM port. It is listed last so it becomes /dev/console.
# The debug UART header on this board is not populated, so on an unmodified
# board this is the only console there is — and printk replays the whole
# buffer into a console registered this late, so nothing before enumeration is
# lost except what the bootloader itself printed.
#
# ttyS0 stays first: it costs nothing and is the only thing that can show SPL
# and U-Boot output once someone solders the header.

setenv fdtfile allwinner/sun50i-h618-bananapi-m4-zero.dtb
setenv bootargs console=ttyS0,115200 console=ttyGS0 earlycon rootwait panic=10

echo "Marvin: booting ${fdtfile}"

load mmc 0:1 ${kernel_addr_r} Image || echo "Marvin: Image not found"
load mmc 0:1 ${fdt_addr_r} ${fdtfile} || echo "Marvin: DTB not found"

# The initramfs is optional: if present alongside, it is passed to the kernel
# as the third argument.
if load mmc 0:1 ${ramdisk_addr_r} initramfs.cpio.gz; then
	booti ${kernel_addr_r} ${ramdisk_addr_r}:${filesize} ${fdt_addr_r}
else
	booti ${kernel_addr_r} - ${fdt_addr_r}
fi
