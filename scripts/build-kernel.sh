#!/usr/bin/env bash
# Cross-builds the arm64 kernel for Marvin.
#
# Runs identically locally and in CI, always inside the build container:
#   docker run --rm -v "$PWD:/work" -w /work <image-by-digest> \
#     bash scripts/build-kernel.sh
#
# The board plays no part in this step: it builds the kernel with our config
# fragments and verifies that BTF was actually generated. The board DTS and
# U-Boot are added by a separate step — mainline has no BPI-M4 Zero support.
set -euo pipefail

VERSION=${KERNEL_VERSION:-6.18.44}
ARCH=${ARCH:-arm64}
CROSS_COMPILE=${CROSS_COMPILE:-aarch64-linux-gnu-}

root=$(cd "$(dirname "$0")/.." && pwd)
downloads="$root/downloads"
src="$root/src/linux-$VERSION"
build="$root/build"
out="$root/out/kernel"
tarball="$downloads/linux-$VERSION.tar.xz"
base_url="https://cdn.kernel.org/pub/linux/kernel/v${VERSION%%.*}.x"

mkdir -p "$downloads" "$out" "$root/src" "$build"

step() { printf '\n== %s\n' "$1"; }

# --- 1. Sources --------------------------------------------------------------
step "Kernel sources $VERSION"
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
		echo "ERROR: tarball SHA256 mismatch" >&2
		echo "  got:      $sha256" >&2
		echo "  expected: $expected" >&2
		exit 1
	}
	echo "SHA256: ok"
else
	echo "$sha256  linux-$VERSION.tar.xz" > "$expected_file"
	echo "SHA256 pinned for the first time: $sha256"
fi
# TODO(build): verify the kernel.org PGP signature once the key fingerprint is
# pinned.

# --- 2. Unpack ---------------------------------------------------------------
step "Unpack"
if [ ! -d "$src" ]; then
	tar -xf "$tarball" -C "$root/src"
fi

# --- 2a. Board DTS -----------------------------------------------------------
# The board is absent from mainline, so we drop the DTS into the tree
# ourselves. The files come from Armbian (GPL-2.0+ OR MIT, authorship kept in
# the headers) — there is no point rewriting them from scratch, the pinout is
# already worked out there.
step "Board DTS"
dts_dir="$src/arch/arm64/boot/dts/allwinner"
board_dtb="sun50i-h618-bananapi-m4-zero"

cp "$root"/dts/*.dts "$root"/dts/*.dtsi "$dts_dir/"

# Without an entry in the Makefile, kbuild does not know about our DTS.
if ! grep -q "$board_dtb.dtb" "$dts_dir/Makefile"; then
	echo "dtb-\$(CONFIG_ARCH_SUNXI) += $board_dtb.dtb" >> "$dts_dir/Makefile"
fi

# --- 3. Configuration --------------------------------------------------------
# The build is out-of-tree (O=) so the source tree stays clean and is cached
# separately from the build results.
step "Configuration"
make -C "$src" O="$build" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" defconfig

"$src/scripts/kconfig/merge_config.sh" -m -O "$build" "$build/.config" \
	"$root"/config/*.config

make -C "$src" O="$build" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" olddefconfig

# --- 4. Build ----------------------------------------------------------------
step "Build kernel"
make -C "$src" O="$build" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" \
	-j"$(nproc)" Image modules

# Only our DTB is built: a full `dtbs` compiles hundreds of other boards.
# The path is given relative to arch/$ARCH/boot/dts — kbuild prepends that
# prefix itself, so a full path would be concatenated onto itself and the
# target would not be found.
step "Build board DTB"
make -C "$src" O="$build" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" \
	"allwinner/$board_dtb.dtb"

# --- 5. Verification ---------------------------------------------------------
step "Verification"
READELF="${CROSS_COMPILE}readelf" "$root/scripts/verify-kernel.sh" "$build"

# --- 6. Artifacts ------------------------------------------------------------
# Layout for a gokrazy KernelPackage: vmlinuz + lib/modules.
step "Artifacts"
rm -rf "$out"
mkdir -p "$out/lib/modules"

cp "$build/arch/arm64/boot/Image" "$out/vmlinuz"
cp "$build/.config" "$out/config"
cp "$build/System.map" "$out/System.map"
cp "$build/arch/arm64/boot/dts/allwinner/$board_dtb.dtb" "$out/"

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
board_dtb: $board_dtb.dtb
board_dtb_source: armbian (GPL-2.0+ OR MIT)
board_support: dtb-only
notes: >
  The DTS comes from Armbian and is absent from mainline. The U-Boot config for
  the board has not been added yet, so booting on hardware is untested.
EOF

echo "$vmlinuz_sha  vmlinuz" > "$out/vmlinuz.sha256"
du -h "$out/vmlinuz"
cat "$out/build-info.yaml"
