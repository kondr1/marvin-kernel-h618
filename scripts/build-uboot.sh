#!/usr/bin/env bash
# Сборка загрузчика: TF-A (BL31) + U-Boot с SPL для H618.
#
# Порядок обязателен: U-Boot встраивает готовый bl31.bin в итоговый образ,
# поэтому TF-A собирается первым. Без BL31 плата не выйдет из EL3.
#
# Запускается одинаково локально и в CI, внутри контейнера сборки:
#   docker run --rm -v "$PWD:/work" -w /work <образ-по-digest> \
#     bash scripts/build-uboot.sh
set -euo pipefail

UBOOT_VERSION=${UBOOT_VERSION:-2026.07}
TFA_VERSION=${TFA_VERSION:-2.15.0}
CROSS_COMPILE=${CROSS_COMPILE:-aarch64-linux-gnu-}
DEFCONFIG=bananapi_m4zero_defconfig
BOARD_DTS=sun50i-h618-bananapi-m4-zero

root=$(cd "$(dirname "$0")/.." && pwd)
downloads="$root/downloads"
srcdir="$root/src"
out="$root/out/uboot"

uboot_src="$srcdir/u-boot-$UBOOT_VERSION"
tfa_src="$srcdir/arm-trusted-firmware-$TFA_VERSION"

mkdir -p "$downloads" "$srcdir" "$out"

step() { printf '\n== %s\n' "$1"; }

# Скачивание с фиксацией контрольной суммы: при первой загрузке значение
# печатается и вносится в репозиторий отдельным коммитом.
fetch_pinned() {
	local url=$1 dest=$2 name=$3
	[ -f "$dest" ] || curl -fsSL -o "$dest" "$url"
	local actual expected_file expected
	actual=$(sha256sum "$dest" | cut -d' ' -f1)
	expected_file="$root/uboot/$name.sha256"
	if [ -f "$expected_file" ]; then
		expected=$(cut -d' ' -f1 < "$expected_file")
		[ "$actual" = "$expected" ] || {
			echo "ОШИБКА: SHA256 $name не совпал" >&2
			echo "  получено:  $actual" >&2
			echo "  ожидалось: $expected" >&2
			exit 1
		}
		echo "  $name: SHA256 ok"
	else
		echo "$actual  $(basename "$dest")" > "$expected_file"
		echo "  $name: SHA256 зафиксирован впервые — $actual"
	fi
}

# --- 1. TF-A -----------------------------------------------------------------
step "TF-A $TFA_VERSION"
tfa_tar="$downloads/arm-trusted-firmware-$TFA_VERSION.tar.gz"
fetch_pinned \
	"https://github.com/ARM-software/arm-trusted-firmware/archive/refs/tags/v$TFA_VERSION.tar.gz" \
	"$tfa_tar" "tfa-$TFA_VERSION"

[ -d "$tfa_src" ] || tar -xf "$tfa_tar" -C "$srcdir"

make -C "$tfa_src" CROSS_COMPILE="$CROSS_COMPILE" \
	PLAT=sun50i_h616 DEBUG=0 bl31 -j"$(nproc)"

bl31="$tfa_src/build/sun50i_h616/release/bl31.bin"
[ -f "$bl31" ] || {
	echo "ОШИБКА: BL31 не собран" >&2
	exit 1
}

# --- 2. U-Boot ---------------------------------------------------------------
step "U-Boot $UBOOT_VERSION"
uboot_tar="$downloads/u-boot-$UBOOT_VERSION.tar.bz2"
fetch_pinned \
	"https://ftp.denx.de/pub/u-boot/u-boot-$UBOOT_VERSION.tar.bz2" \
	"$uboot_tar" "u-boot-$UBOOT_VERSION"

[ -d "$uboot_src" ] || tar -xf "$uboot_tar" -C "$srcdir"

# Платы нет в upstream: кладём свой defconfig и тот же DTS, что и у ядра.
# U-Boot ≥ 2024 берёт деревья из dts/upstream — синхронизированной копии
# дерева ядра, поэтому файл подходит без изменений.
cp "$root/uboot/$DEFCONFIG" "$uboot_src/configs/$DEFCONFIG"
cp "$root"/dts/*.dts "$root"/dts/*.dtsi \
	"$uboot_src/dts/upstream/src/arm64/allwinner/"

make -C "$uboot_src" CROSS_COMPILE="$CROSS_COMPILE" "$DEFCONFIG"
make -C "$uboot_src" CROSS_COMPILE="$CROSS_COMPILE" \
	BL31="$bl31" -j"$(nproc)"

image="$uboot_src/u-boot-sunxi-with-spl.bin"
[ -f "$image" ] || {
	echo "ОШИБКА: образ загрузчика не собран" >&2
	exit 1
}

# --- 3. boot.scr -------------------------------------------------------------
# mkimage берётся из только что собранного U-Boot: версия инструмента и
# версия загрузчика тогда заведомо совпадают.
step "boot.scr"
"$uboot_src/tools/mkimage" -C none -A arm64 -T script \
	-d "$root/uboot/boot.cmd" "$out/boot.scr"

# --- 4. Артефакты ------------------------------------------------------------
step "Артефакты"
cp "$image" "$out/u-boot-sunxi-with-spl.bin"
sha=$(sha256sum "$out/u-boot-sunxi-with-spl.bin" | cut -d' ' -f1)
echo "$sha  u-boot-sunxi-with-spl.bin" > "$out/u-boot-sunxi-with-spl.bin.sha256"

cat > "$out/uboot-build-info.yaml" <<EOF
component: u-boot
version: "$UBOOT_VERSION"
tfa_version: "$TFA_VERSION"
tfa_platform: sun50i_h616
defconfig: $DEFCONFIG
board_dts: $BOARD_DTS
artifact_sha256: $sha
build_container_digest: ${BUILD_CONTAINER_DIGEST:-unknown}
notes: >
  Платы нет в upstream U-Boot: defconfig и DTS наши. Загрузка на железе не
  проверялась. Образ пишется на microSD со смещением 8 КиБ:
  dd if=u-boot-sunxi-with-spl.bin of=/dev/sdX bs=1024 seek=8 conv=fsync
EOF

ls -l "$out/u-boot-sunxi-with-spl.bin"
cat "$out/uboot-build-info.yaml"
