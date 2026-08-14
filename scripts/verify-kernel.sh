#!/usr/bin/env bash
# Проверка собранного ядра.
#
# Главная ловушка merge_config: если у опции не выполнены зависимости, она
# молча не попадает в итоговый .config, сборка при этом проходит успешно, и
# отсутствие BTF выясняется уже на плате, когда dae откажется стартовать.
# Поэтому проверяется не факт сборки, а итоговый .config и секции vmlinux.
#
# Использование: verify-kernel.sh <каталог-сборки>
set -euo pipefail

build=${1:?нужен каталог сборки}
config="$build/.config"
vmlinux="$build/vmlinux"
readelf_bin=${READELF:-aarch64-linux-gnu-readelf}

errors=0

fail() {
	echo "ОШИБКА: $1" >&2
	errors=$((errors + 1))
}

[ -f "$config" ] || {
	echo "ОШИБКА: нет $config" >&2
	exit 1
}

# Опции, без которых продукт не работает. Список намеренно короткий: сюда
# попадает только то, отсутствие чего ломает функцию, а не оптимизации.
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
CONFIG_DEVTMPFS_MOUNT
CONFIG_SQUASHFS
"

for opt in $required; do
	grep -qE "^$opt=(y|m)$" "$config" ||
		fail "опция $opt не включена в итоговом .config"
done

# DEBUG_INFO_REDUCED вычищает типы, из которых pahole строит BTF.
if grep -qE "^CONFIG_DEBUG_INFO_REDUCED=y$" "$config"; then
	fail "CONFIG_DEBUG_INFO_REDUCED=y — BTF будет неполным"
fi

# Наличие опции в конфиге ещё не значит, что BTF реально сгенерирован:
# без pahole в контейнере сборка проходит, а секции нет.
if [ -f "$vmlinux" ]; then
	if "$readelf_bin" -S "$vmlinux" 2>/dev/null | grep -q '\.BTF'; then
		echo "ok: секция .BTF присутствует в vmlinux"
	else
		fail "в vmlinux нет секции .BTF — dae не загрузит eBPF"
	fi
else
	fail "нет $vmlinux, проверить BTF нечем"
fi

if [ "$errors" -gt 0 ]; then
	echo "Провалено: ошибок $errors" >&2
	exit 1
fi

echo "Проверка ядра пройдена"
