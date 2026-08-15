#!/usr/bin/env bash
# Assembles a gokrazy KernelPackage from prebuilt kernel and bootloader
# artifacts.
#
# The layout is not arbitrary: gok pulls both the kernel and the files written
# to the disk's raw areas out of the KernelPackage. The latter are listed in
# gokrazy/internal/deviceconfig, and for our slug (nanopi_neo) that list names
# u-boot-sunxi-with-spl.bin at an 8 KiB offset. Hence the bootloader must live
# right here next to vmlinuz, not as a separate artifact.
#
#   kernelpackage/
#     vmlinuz
#     *.dtb
#     boot.scr
#     u-boot-sunxi-with-spl.bin
#     lib/modules/<version>/
#     kernel.go                     empty package kernel: the path has to be a
#                                   valid Go package
#
# Run after build-kernel.sh and build-uboot.sh:
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
		echo "ERROR: missing $1" >&2
		echo "Run build-kernel.sh and build-uboot.sh first" >&2
		exit 1
	}
}

require "$kernel_out/vmlinuz"
require "$uboot_out/u-boot-sunxi-with-spl.bin"
require "$uboot_out/boot.scr"

step "KernelPackage layout"
rm -rf "$pkg"
mkdir -p "$pkg"

cp "$kernel_out/vmlinuz" "$pkg/"
cp "$kernel_out"/*.dtb "$pkg/"
cp "$kernel_out/config" "$pkg/"
cp "$kernel_out/System.map" "$pkg/"
cp -r "$kernel_out/lib" "$pkg/"

# Firmware goes into the same lib/ as the modules: gokrazy copies that
# directory into rootfs wholesale, and the driver looks the files up only after
# the mount.
if [ -d "$root/out/firmware/lib/firmware" ]; then
	mkdir -p "$pkg/lib/firmware"
	cp -r "$root/out/firmware/lib/firmware/." "$pkg/lib/firmware/"
else
	echo "WARNING: firmware was not downloaded, the BCM43455 radio will not work"
fi

cp "$uboot_out/u-boot-sunxi-with-spl.bin" "$pkg/"
cp "$uboot_out/boot.scr" "$pkg/"

# The KernelPackage path has to be a valid Go package, even though it holds no
# code.
cat > "$pkg/kernel.go" <<'EOF'
// Package kernel contains no code: gokrazy requires a KernelPackage to be a
// valid Go package, while the artifacts sit next to it as plain files.
package kernel
EOF

step "Manifest"
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
  Layout for the gokrazy DeviceType nanopi_neo: that same slug dictates writing
  u-boot-sunxi-with-spl.bin at an 8 KiB offset and placing the boot partition
  at 1 MiB. Untested on hardware.
EOF

step "Contents check"
# A missing file here means a broken image, and it would only become apparent
# on the board.
for f in vmlinuz boot.scr u-boot-sunxi-with-spl.bin kernel.go; do
	[ -f "$pkg/$f" ] || {
		echo "ERROR: the package is missing $f" >&2
		exit 1
	}
done
ls "$pkg"/*.dtb >/dev/null || {
	echo "ERROR: the package contains no DTB at all" >&2
	exit 1
}
[ -n "$modules_version" ] || {
	echo "ERROR: the package has no lib/modules" >&2
	exit 1
}

step "Archive"
tarball="$dist/marvin-kernelpackage-$kernel_version.tar.zst"
tar --zstd -cf "$tarball" -C "$dist" kernelpackage
sha=$(sha256sum "$tarball" | cut -d' ' -f1)
echo "$sha  $(basename "$tarball")" > "$tarball.sha256"

du -sh "$pkg"
ls -l "$tarball"
cat "$pkg/kernelpackage.yaml"
