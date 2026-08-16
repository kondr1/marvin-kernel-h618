#!/usr/bin/env bash
# Downloads the onboard radio firmware into the KernelPackage layout.
#
# Firmware is not built — it is binary and taken as is, so all that happens
# here is a pinned download with checksum verification.
#
# A note on the CLM blob: without it brcmfmac stays on its built-in regulatory
# data (`country 99`) and refuses to take the radio into 5 GHz — exactly what
# was measured on the board under Armbian. We install it under the name the
# driver actually requests and confirm the outcome on hardware: this is a
# hypothesis, not a guarantee.
set -euo pipefail

ARMBIAN_COMMIT=${ARMBIAN_COMMIT:-f49ca1169c8eaea80658de3752ab6e2b4bc1ac40}
REGDB_VERSION=${REGDB_VERSION:-2026.05.30-1}
FIRMWARE_COMMIT=${FIRMWARE_COMMIT:-d9846710f54da5e4383e2d67311819659ac2cf5c}
BASE="https://raw.githubusercontent.com/armbian/build/$ARMBIAN_COMMIT"
FW_BASE="https://raw.githubusercontent.com/armbian/firmware/$FIRMWARE_COMMIT"

root=$(cd "$(dirname "$0")/.." && pwd)
manifest="$root/firmware/brcm.manifest"
wifi_manifest="$root/firmware/wifi.manifest"
sums="$root/firmware/brcm.sha256"
fwroot="$root/out/firmware/lib/firmware"
out="$fwroot/brcm"

mkdir -p "$out"
printf '\n== Firmware brcmfmac (Armbian @ %s)\n' "${ARMBIAN_COMMIT:0:12}"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

: > "$tmp/computed.sha256"

while read -r target source; do
	case "$target" in
	'#'* | '') continue ;;
	esac

	curl -fsSL -o "$tmp/$(basename "$target")" "$BASE/$source"
	cp "$tmp/$(basename "$target")" "$out/$target"

	sha=$(sha256sum "$out/$target" | cut -d' ' -f1)
	printf '%s  %s\n' "$sha" "$target" >> "$tmp/computed.sha256"
	printf '  %s (%s bytes)\n' "$target" "$(stat -c%s "$out/$target")"
done < "$manifest"

printf '\n== Adapter firmware (armbian/firmware @ %s)\n' "${FIRMWARE_COMMIT:0:12}"
while read -r origin source target; do
	case "$origin" in
	'#'* | '') continue ;;
	esac

	mkdir -p "$fwroot/$(dirname "$target")"
	curl -fsSL -o "$fwroot/$target" "$FW_BASE/$source"

	sha=$(sha256sum "$fwroot/$target" | cut -d' ' -f1)
	printf '%s  %s\n' "$sha" "$target" >> "$tmp/computed.sha256"
	printf '  %s (%s bytes)\n' "$target" "$(stat -c%s "$fwroot/$target")"
done < "$wifi_manifest"

printf '\n== Regulatory database (Debian %s)\n' "$REGDB_VERSION"
# Not from the Armbian mirror: it does not carry the file. Debian ships the
# upstream wireless-regdb release unchanged, from a URL that stays valid and
# can be pinned by version and checksum.
#
# The kernel is built with REQUIRE_SIGNED_REGDB, so the signature is not
# optional — without the pair the regulatory domain stays world-wide and 5 GHz
# is unusable for an access point.
deb="$tmp/wireless-regdb.deb"
curl -fsSL -o "$deb" \
	"https://deb.debian.org/debian/pool/main/w/wireless-regdb/wireless-regdb_${REGDB_VERSION}_all.deb"

# Debian ships two variants side by side and picks between them with
# alternatives. We take the upstream one: the kernel is built with
# USE_KERNEL_REGDB_KEYS, so it verifies the signature against the upstream
# wireless-regdb key, and the Debian-signed variant would be rejected.
(cd "$tmp" && ar x "$deb" && tar -xf data.tar.* \
	./usr/lib/firmware/regulatory.db-upstream \
	./usr/lib/firmware/regulatory.db.p7s-upstream)
for f in regulatory.db regulatory.db.p7s; do
	cp "$tmp/usr/lib/firmware/$f-upstream" "$fwroot/$f"
	sha=$(sha256sum "$fwroot/$f" | cut -d' ' -f1)
	printf '%s  %s\n' "$sha" "$f" >> "$tmp/computed.sha256"
	printf '  %s (%s bytes)\n' "$f" "$(stat -c%s "$fwroot/$f")"
done

# Same principle as with the sources: pinning only works if the checksums live
# in the repository. The first download prints them, later runs compare.
if [ -f "$sums" ]; then
	if diff -q <(sort "$sums") <(sort "$tmp/computed.sha256") >/dev/null; then
		echo "  checksums: ok"
	else
		echo "ERROR: firmware does not match the pinned checksums" >&2
		diff <(sort "$sums") <(sort "$tmp/computed.sha256") >&2 || true
		exit 1
	fi
else
	cp "$tmp/computed.sha256" "$sums"
	echo "  checksums pinned for the first time — commit $sums to the repository:"
	cat "$sums"
fi

ls -l "$out"
