# Kernel build container for Marvin.
#
# Cross-compiles for arm64 on x86: no emulation, no native arm64 runners.
# pahole (the dwarves package) is mandatory — without it the kernel still
# builds, but vmlinux ends up with no .BTF section and dae fails to load its
# eBPF programs once on the board.
#
# The image is consumed BY DIGEST (container.digest), not by tag.
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
	`# U-Boot and TF-A builds: requirements of their own on top of the kernel's` \
	python3-dev python3-setuptools swig \
	uuid-dev libgnutls28-dev device-tree-compiler \
	&& rm -rf /var/lib/apt/lists/*

ENV ARCH=arm64
ENV CROSS_COMPILE=aarch64-linux-gnu-
ENV PATH=/usr/lib/ccache:$PATH
WORKDIR /work
