#!/usr/bin/env bash
# Проверка собранного KernelPackage перед публикацией.
#
# Проверяется состав и пригодность, а не факт сборки: пакет без загрузчика
# или без модулей соберётся в образ молча, а плата после этого не загрузится
# либо останется без драйверов.
#
# Использование: verify-package.sh <каталог-пакета>
set -euo pipefail

pkg=${1:?нужен каталог KernelPackage}
errors=0

fail() {
	echo "ОШИБКА: $1" >&2
	errors=$((errors + 1))
}

# Обязательный состав. u-boot-sunxi-with-spl.bin читается gok из пакета и
# пишется в сырую область диска по смещению 8 КиБ (slug nanopi_neo).
for f in vmlinuz boot.scr u-boot-sunxi-with-spl.bin kernel.go kernelpackage.yaml; do
	[ -f "$pkg/$f" ] || fail "нет $f"
done

ls "$pkg"/*.dtb >/dev/null 2>&1 || fail "нет ни одного DTB"

modules_dir=$(find "$pkg/lib/modules" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | head -1)
[ -n "$modules_dir" ] || fail "нет lib/modules/<версия>"

# Пустой каталог модулей означает, что modules_install отработал вхолостую.
if [ -n "$modules_dir" ]; then
	count=$(find "$modules_dir" -name '*.ko*' | wc -l)
	[ "$count" -gt 0 ] || fail "в lib/modules нет ни одного модуля"
	echo "модулей: $count"
fi

# Ядро arm64 начинается с магии 'ARM\x64' по смещению 56 — быстрая проверка,
# что это действительно образ нужной архитектуры, а не чужой файл.
if [ -f "$pkg/vmlinuz" ]; then
	magic=$(dd if="$pkg/vmlinuz" bs=1 skip=56 count=4 2>/dev/null | tr -d '\0')
	[ "$magic" = "ARM" ] || [ "$magic" = "ARMd" ] ||
		echo "ВНИМАНИЕ: не найдена магия arm64 в vmlinuz (получено '$magic')"
	size=$(stat -c%s "$pkg/vmlinuz")
	[ "$size" -gt 1000000 ] || fail "vmlinuz подозрительно мал: $size байт"
fi

# Загрузчик меньше сотни килобайт означает, что BL31 не встроился.
if [ -f "$pkg/u-boot-sunxi-with-spl.bin" ]; then
	size=$(stat -c%s "$pkg/u-boot-sunxi-with-spl.bin")
	[ "$size" -gt 200000 ] || fail "загрузчик подозрительно мал: $size байт"
	# Область под загрузчик в раскладке nanopi_neo — 2032 сектора от 16-го.
	limit=$((2032 * 512))
	[ "$size" -lt "$limit" ] ||
		fail "загрузчик не влезает в отведённую область: $size ≥ $limit байт"
fi

if [ "$errors" -gt 0 ]; then
	echo "Провалено: ошибок $errors" >&2
	exit 1
fi

echo "KernelPackage проверен"
