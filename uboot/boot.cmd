# Скрипт загрузки для bring-up: U-Boot ищет boot.scr на первом разделе.
#
# Назначение — этапы A–D bring-up: довести плату до работающего ядра и
# консоли. Финальную раскладку разделов и параметры root задаёт сборка образа
# gokrazy, она же положит свой boot.scr.
#
# console=ttyS0: на H618 UART0 обслуживается драйвером 8250_dw, а не pl011.
# Скорость должна совпадать с chosen/stdout-path в DTS.

setenv fdtfile allwinner/sun50i-h618-bananapi-m4-zero.dtb
setenv bootargs console=ttyS0,115200 earlycon rootwait panic=10

echo "Marvin: загрузка ${fdtfile}"

load mmc 0:1 ${kernel_addr_r} Image || echo "Marvin: не найден Image"
load mmc 0:1 ${fdt_addr_r} ${fdtfile} || echo "Marvin: не найден DTB"

# initramfs опционален: если положен рядом, ядру передаётся третьим аргументом.
if load mmc 0:1 ${ramdisk_addr_r} initramfs.cpio.gz; then
	booti ${kernel_addr_r} ${ramdisk_addr_r}:${filesize} ${fdt_addr_r}
else
	booti ${kernel_addr_r} - ${fdt_addr_r}
fi
