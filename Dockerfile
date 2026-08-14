# Контейнер сборки ядра для Marvin.
#
# Кросс-компиляция под arm64 на x86: без эмуляции и без native arm64-раннеров.
# pahole (пакет dwarves) обязателен — без него ядро соберётся, но секции .BTF
# в vmlinux не будет, и dae не загрузит eBPF уже на плате.
#
# Образ потребляется ПО DIGEST (container.digest), а не по тегу.
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
	gcc-aarch64-linux-gnu \
	libc6-dev-arm64-cross \
	build-essential \
	bc bison flex \
	libssl-dev libelf-dev \
	dwarves \
	cpio kmod rsync \
	xz-utils bzip2 zstd curl ca-certificates \
	gnupg \
	ccache \
	python3 \
	`# сборка U-Boot и TF-A: свои требования сверх ядерных` \
	python3-dev python3-setuptools swig \
	uuid-dev libgnutls28-dev device-tree-compiler \
	&& rm -rf /var/lib/apt/lists/*

ENV ARCH=arm64
ENV CROSS_COMPILE=aarch64-linux-gnu-
ENV PATH=/usr/lib/ccache:$PATH
WORKDIR /work
