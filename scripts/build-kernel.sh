#!/usr/bin/env bash
# Кросс-сборка ядра под arm64 для Marvin.
#
# Запускается одинаково локально и в CI, всегда внутри контейнера сборки:
#   docker run --rm -v "$PWD:/work" -w /work <образ-по-digest> \
#     bash scripts/build-kernel.sh
#
# Плата на этом шаге не участвует: собирается ядро с нашими фрагментами и
# проверяется, что BTF реально сгенерирован. DTS платы и U-Boot добавляются
# отдельным шагом — в mainline поддержки BPI-M4 Zero нет.
set -euo pipefail

VERSION=${KERNEL_VERSION:-6.18.44}
ARCH=${ARCH:-arm64}
CROSS_COMPILE=${CROSS_COMPILE:-aarch64-linux-gnu-}

root=$(cd "$(dirname "$0")/.." && pwd)
downloads="$root/downloads"
src="$root/src/linux-$VERSION"
build="$root/build"
out="$root/out"
tarball="$downloads/linux-$VERSION.tar.xz"
base_url="https://cdn.kernel.org/pub/linux/kernel/v${VERSION%%.*}.x"

mkdir -p "$downloads" "$out" "$root/src" "$build"

step() { printf '\n== %s\n' "$1"; }

# --- 1. Исходники ------------------------------------------------------------
step "Исходники ядра $VERSION"
if [ ! -f "$tarball" ]; then
	curl -fsSL -o "$tarball" "$base_url/linux-$VERSION.tar.xz"
	curl -fsSL -o "$tarball.sign" "$base_url/linux-$VERSION.tar.sign" || true
fi

sha256=$(sha256sum "$tarball" | cut -d' ' -f1)
expected_file="$root/kernel/linux-$VERSION.sha256"
mkdir -p "$root/kernel"
if [ -f "$expected_file" ]; then
	expected=$(cut -d' ' -f1 < "$expected_file")
	[ "$sha256" = "$expected" ] || {
		echo "ОШИБКА: SHA256 тарболла не совпал" >&2
		echo "  получено:  $sha256" >&2
		echo "  ожидалось: $expected" >&2
		exit 1
	}
	echo "SHA256: ok"
else
	echo "$sha256  linux-$VERSION.tar.xz" > "$expected_file"
	echo "SHA256 зафиксирован впервые: $sha256"
fi
# TODO(build): проверка PGP-подписи kernel.org после фиксации отпечатка ключа.

# --- 2. Распаковка -----------------------------------------------------------
step "Распаковка"
if [ ! -d "$src" ]; then
	tar -xf "$tarball" -C "$root/src"
fi

# --- 3. Конфигурация ---------------------------------------------------------
# Сборка идёт out-of-tree (O=), чтобы дерево исходников оставалось чистым и
# кешировалось отдельно от результатов.
step "Конфигурация"
make -C "$src" O="$build" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" defconfig

"$src/scripts/kconfig/merge_config.sh" -m -O "$build" "$build/.config" \
	"$root"/config/*.config

make -C "$src" O="$build" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" olddefconfig

# --- 4. Сборка ---------------------------------------------------------------
step "Сборка ядра"
make -C "$src" O="$build" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" \
	-j"$(nproc)" Image modules

# --- 5. Проверки -------------------------------------------------------------
step "Проверки"
READELF="${CROSS_COMPILE}readelf" "$root/scripts/verify-kernel.sh" "$build"

# --- 6. Артефакты ------------------------------------------------------------
# Раскладка под gokrazy KernelPackage: vmlinuz + lib/modules.
step "Артефакты"
rm -rf "$out"
mkdir -p "$out/lib/modules"

cp "$build/arch/arm64/boot/Image" "$out/vmlinuz"
cp "$build/.config" "$out/config"
cp "$build/System.map" "$out/System.map"

make -C "$src" O="$build" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" \
	INSTALL_MOD_PATH="$out" modules_install >/dev/null

vmlinuz_sha=$(sha256sum "$out/vmlinuz" | cut -d' ' -f1)

cat > "$out/build-info.yaml" <<EOF
component: kernel
version: "$VERSION"
arch: $ARCH
source_url: $base_url/linux-$VERSION.tar.xz
source_sha256: $sha256
vmlinuz_sha256: $vmlinuz_sha
build_container_digest: ${BUILD_CONTAINER_DIGEST:-unknown}
btf: present
board_support: none
notes: >
  DTS BPI-M4 Zero и конфиг U-Boot в mainline отсутствуют и добавляются
  отдельным шагом; этот артефакт содержит только ядро и модули.
EOF

echo "$vmlinuz_sha  vmlinuz" > "$out/vmlinuz.sha256"
du -h "$out/vmlinuz"
cat "$out/build-info.yaml"
