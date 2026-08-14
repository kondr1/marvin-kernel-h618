#!/usr/bin/env bash
# Скачивание firmware онбордового радио в раскладку KernelPackage.
#
# Firmware не собирается — оно бинарное и берётся как есть, поэтому здесь
# только загрузка с пином и проверкой контрольных сумм.
#
# Отдельно про CLM blob: без него brcmfmac остаётся на встроенном regulatory
# (`country 99`) и не пускает радио в 5 ГГц — ровно это и измерено на плате
# под Armbian. Кладём его под именем, которое драйвер действительно
# запрашивает, и проверяем результат на железе: это гипотеза, а не гарантия.
set -euo pipefail

ARMBIAN_COMMIT=${ARMBIAN_COMMIT:-f49ca1169c8eaea80658de3752ab6e2b4bc1ac40}
BASE="https://raw.githubusercontent.com/armbian/build/$ARMBIAN_COMMIT"

root=$(cd "$(dirname "$0")/.." && pwd)
manifest="$root/firmware/brcm.manifest"
sums="$root/firmware/brcm.sha256"
out="$root/out/firmware/lib/firmware/brcm"

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
	printf '  %s (%s байт)\n' "$target" "$(stat -c%s "$out/$target")"
done < "$manifest"

# Тот же принцип, что и с исходниками: пин работает, только если суммы лежат
# в репозитории. Первая загрузка их печатает, дальше они сверяются.
if [ -f "$sums" ]; then
	if diff -q <(sort "$sums") <(sort "$tmp/computed.sha256") >/dev/null; then
		echo "  контрольные суммы: ok"
	else
		echo "ОШИБКА: firmware не совпало с зафиксированными суммами" >&2
		diff <(sort "$sums") <(sort "$tmp/computed.sha256") >&2 || true
		exit 1
	fi
else
	cp "$tmp/computed.sha256" "$sums"
	echo "  суммы зафиксированы впервые — внеси $sums в репозиторий:"
	cat "$sums"
fi

ls -l "$out"
