#!/usr/bin/env bash
# Verifies the built kernel.
#
# The main merge_config trap: when an option's dependencies are not satisfied,
# it is silently dropped from the resulting .config, the build still succeeds,
# and the missing BTF only shows up on the board when dae refuses to start.
# That is why this checks the resulting .config and the vmlinux sections rather
# than the mere fact that a build happened.
#
# Usage: verify-kernel.sh <build-directory>
set -euo pipefail

build=${1:?build directory required}
config="$build/.config"
vmlinux="$build/vmlinux"
readelf_bin=${READELF:-aarch64-linux-gnu-readelf}

errors=0

fail() {
	echo "ERROR: $1" >&2
	errors=$((errors + 1))
}

[ -f "$config" ] || {
	echo "ERROR: missing $config" >&2
	exit 1
}

# Options without which the product does not work. The list is deliberately
# short: only things whose absence breaks a function belong here, not
# optimizations.
required="
CONFIG_BPF_SYSCALL
CONFIG_BPF_JIT
CONFIG_DEBUG_INFO_BTF
CONFIG_NET_CLS_BPF
CONFIG_NET_SCH_INGRESS
CONFIG_CGROUPS
CONFIG_NF_TABLES
CONFIG_NFT_NAT
CONFIG_NFT_MASQ
CONFIG_CFG80211
CONFIG_MAC80211
CONFIG_BRCMFMAC
CONFIG_RTW88_8812AU
CONFIG_RTL8XXXU
CONFIG_DEVTMPFS_MOUNT
CONFIG_SQUASHFS
"

for opt in $required; do
	grep -qE "^$opt=(y|m)$" "$config" ||
		fail "option $opt is not enabled in the resulting .config"
done

# DEBUG_INFO_REDUCED strips out the very types pahole builds BTF from.
if grep -qE "^CONFIG_DEBUG_INFO_REDUCED=y$" "$config"; then
	fail "CONFIG_DEBUG_INFO_REDUCED=y — BTF would be incomplete"
fi

# An option being present in the config does not mean BTF was actually
# generated: without pahole in the container the build succeeds but the section
# is missing.
if [ -f "$vmlinux" ]; then
	if "$readelf_bin" -S "$vmlinux" 2>/dev/null | grep -q '\.BTF'; then
		echo "ok: the .BTF section is present in vmlinux"
	else
		fail "vmlinux has no .BTF section — dae will not load eBPF"
	fi
else
	fail "missing $vmlinux, nothing to check BTF against"
fi

if [ "$errors" -gt 0 ]; then
	echo "Failed: $errors error(s)" >&2
	exit 1
fi

echo "Kernel verification passed"
