# Boot script for bring-up: U-Boot looks for boot.scr on the first partition.
#
# Its purpose is bring-up stages A-D: get the board to a working kernel and
# console. The final partition layout and root parameters are decided by the
# gokrazy image build, which installs its own boot.scr.
#
# console=ttyS0: on the H618, UART0 is driven by 8250_dw, not by pl011. The
# baud rate must match chosen/stdout-path in the DTS.

setenv fdtfile allwinner/sun50i-h618-bananapi-m4-zero.dtb
setenv bootargs console=ttyS0,115200 earlycon rootwait panic=10

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
