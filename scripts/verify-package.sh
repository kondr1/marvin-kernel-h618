#!/usr/bin/env bash
# Verifies a built KernelPackage before publishing.
#
# What is checked is the contents and their fitness, not the fact that a build
# happened: a package missing the bootloader or the modules gets assembled into
# an image silently, and the board then either fails to boot or comes up with
# no drivers.
#
# Usage: verify-package.sh <package-directory>
set -euo pipefail

pkg=${1:?KernelPackage directory required}
errors=0

fail() {
	echo "ERROR: $1" >&2
	errors=$((errors + 1))
}

# Mandatory contents. u-boot-sunxi-with-spl.bin is read by gok out of the
# package and written to the disk's raw area at an 8 KiB offset (slug
# nanopi_neo).
for f in vmlinuz boot.scr u-boot-sunxi-with-spl.bin kernel.go kernelpackage.yaml \
	cmdline.txt config.txt; do
	[ -f "$pkg/$f" ] || fail "missing $f"
done

# A dangling symlink under lib/modules aborts the image build: the packer walks
# the tree and stats every entry. modules_install creates exactly such links.
dangling=$(find "$pkg/lib/modules" -xtype l 2>/dev/null | head -5)
[ -z "$dangling" ] || fail "dangling symlinks in lib/modules: $dangling"

ls "$pkg"/*.dtb >/dev/null 2>&1 || fail "no DTB at all"

modules_dir=$(find "$pkg/lib/modules" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | head -1)
[ -n "$modules_dir" ] || fail "missing lib/modules/<version>"

# An empty modules directory means modules_install ran but produced nothing.
if [ -n "$modules_dir" ]; then
	count=$(find "$modules_dir" -name '*.ko*' | wc -l)
	[ "$count" -gt 0 ] || fail "lib/modules contains no modules at all"
	echo "modules: $count"
fi

# Without firmware the onboard radio never comes up, and that only becomes
# apparent on the board: the driver loads and silently finds no device.
for fw in brcm/brcmfmac43455-sdio.bin brcm/brcmfmac43455-sdio.clm_blob \
	rtw88/rtw8812a_fw.bin rtlwifi/rtl8188eufw.bin; do
	[ -f "$pkg/lib/firmware/$fw" ] || fail "missing firmware $fw"
done
ls "$pkg"/lib/firmware/brcm/brcmfmac43455-sdio.*.txt >/dev/null 2>&1 ||
	fail "missing board NVRAM brcmfmac43455-sdio.<compatible>.txt"

# An arm64 kernel carries the 'ARM\x64' magic at offset 56 — a quick check that
# this really is an image of the right architecture and not some stray file.
if [ -f "$pkg/vmlinuz" ]; then
	magic=$(dd if="$pkg/vmlinuz" bs=1 skip=56 count=4 2>/dev/null | tr -d '\0')
	[ "$magic" = "ARM" ] || [ "$magic" = "ARMd" ] ||
		echo "WARNING: no arm64 magic found in vmlinuz (got '$magic')"
	size=$(stat -c%s "$pkg/vmlinuz")
	[ "$size" -gt 1000000 ] || fail "vmlinuz is suspiciously small: $size bytes"
fi

# A bootloader under a hundred kilobytes means BL31 was not embedded.
if [ -f "$pkg/u-boot-sunxi-with-spl.bin" ]; then
	size=$(stat -c%s "$pkg/u-boot-sunxi-with-spl.bin")
	[ "$size" -gt 200000 ] || fail "bootloader is suspiciously small: $size bytes"
	# In the nanopi_neo layout the bootloader area is 2032 sectors from sector 16.
	limit=$((2032 * 512))
	[ "$size" -lt "$limit" ] ||
		fail "the bootloader does not fit its reserved area: $size >= $limit bytes"
fi

if [ "$errors" -gt 0 ]; then
	echo "Failed: $errors error(s)" >&2
	exit 1
fi

echo "KernelPackage verified"
