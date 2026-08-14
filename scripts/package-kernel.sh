#!/usr/bin/env bash
# Сборка gokrazy KernelPackage из готовых артефактов ядра и загрузчика.
#
# Раскладка не произвольная: gok забирает из KernelPackage и ядро, и файлы,
# которые пишутся в «сырые» области диска. Список последних задаётся в
# gokrazy/internal/deviceconfig, и для нашего slug (nanopi_neo) там указан
# u-boot-sunxi-with-spl.bin со смещением 8 КиБ. Поэтому загрузчик обязан
# лежать здесь же, рядом с vmlinuz, а не отдельным артефактом.
#
#   kernelpackage/
#     vmlinuz
#     *.dtb
#     boot.scr
#     u-boot-sunxi-with-spl.bin
#     lib/modules/<версия>/
#     kernel.go                     пустой package kernel: путь должен быть
#                                   валидным Go-пакетом
#
# Запуск после build-kernel.sh и build-uboot.sh:
#   bash scripts/package-kernel.sh
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
kernel_out="$root/out/kernel"
uboot_out="$root/out/uboot"
pkg="$root/dist/kernelpackage"
dist="$root/dist"

step() { printf '\n== %s\n' "$1"; }

require() {
	[ -e "$1" ] || {
		echo "ОШИБКА: нет $1" >&2
		echo "Сначала выполни build-kernel.sh и build-uboot.sh" >&2
		exit 1
	}
}

require "$kernel_out/vmlinuz"
require "$uboot_out/u-boot-sunxi-with-spl.bin"
require "$uboot_out/boot.scr"

step "Раскладка KernelPackage"
rm -rf "$pkg"
mkdir -p "$pkg"

cp "$kernel_out/vmlinuz" "$pkg/"
cp "$kernel_out"/*.dtb "$pkg/"
cp "$kernel_out/config" "$pkg/"
cp "$kernel_out/System.map" "$pkg/"
cp -r "$kernel_out/lib" "$pkg/"
cp "$uboot_out/u-boot-sunxi-with-spl.bin" "$pkg/"
cp "$uboot_out/boot.scr" "$pkg/"

# Путь KernelPackage должен быть валидным Go-пакетом, хотя кода в нём нет.
cat > "$pkg/kernel.go" <<'EOF'
// Package kernel не содержит кода: gokrazy требует, чтобы KernelPackage был
// валидным Go-пакетом, а артефакты лежат рядом файлами.
package kernel
EOF

step "Манифест"
kernel_version=$(sed -n 's/^version: "\(.*\)"$/\1/p' "$kernel_out/build-info.yaml")
uboot_version=$(sed -n 's/^version: "\(.*\)"$/\1/p' "$uboot_out/uboot-build-info.yaml")
modules_version=$(ls "$pkg/lib/modules" 2>/dev/null | head -1)

cat > "$pkg/kernelpackage.yaml" <<EOF
component: kernelpackage
board: bpi-m4-zero
device_type: nanopi_neo
kernel_version: "$kernel_version"
kernel_modules: "$modules_version"
uboot_version: "$uboot_version"
build_container_digest: ${BUILD_CONTAINER_DIGEST:-unknown}
files:
$(cd "$pkg" && find . -maxdepth 1 -type f -printf '  - %P\n' | sort)
notes: >
  Раскладка под gokrazy DeviceType nanopi_neo: тот же slug задаёт запись
  u-boot-sunxi-with-spl.bin по смещению 8 КиБ и загрузочный раздел с 1 МиБ.
  На железе не проверялось.
EOF

step "Проверка состава"
# Отсутствие любого из этих файлов означает неработающий образ, причём
# выяснится это уже на плате.
for f in vmlinuz boot.scr u-boot-sunxi-with-spl.bin kernel.go; do
	[ -f "$pkg/$f" ] || {
		echo "ОШИБКА: в пакете нет $f" >&2
		exit 1
	}
done
ls "$pkg"/*.dtb >/dev/null || {
	echo "ОШИБКА: в пакете нет ни одного DTB" >&2
	exit 1
}
[ -n "$modules_version" ] || {
	echo "ОШИБКА: в пакете нет lib/modules" >&2
	exit 1
}

step "Архив"
tarball="$dist/marvin-kernelpackage-$kernel_version.tar.zst"
tar --zstd -cf "$tarball" -C "$dist" kernelpackage
sha=$(sha256sum "$tarball" | cut -d' ' -f1)
echo "$sha  $(basename "$tarball")" > "$tarball.sha256"

du -sh "$pkg"
ls -l "$tarball"
cat "$pkg/kernelpackage.yaml"
