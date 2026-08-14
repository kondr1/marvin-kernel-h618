#!/usr/bin/env bash
# Сборка контейнера сборки и фиксация его digest.
#
# Образ потребляется по digest, а не по тегу (ADR-0020): тег может уехать,
# digest — нет. Этот скрипт собирает образ локально и записывает digest в
# container.digest; в CI то же делает workflow при изменении Dockerfile.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
image=${IMAGE:-marvin-kernel-h618}
tag=${TAG:-local}

docker build -t "$image:$tag" "$root"

# У локально собранного образа нет digest реестра, поэтому фиксируем ID.
# После публикации в ghcr.io сюда пишется именно digest из реестра.
id=$(docker image inspect --format '{{.Id}}' "$image:$tag")
echo "$id" > "$root/container.digest"
echo "образ: $image:$tag"
echo "digest: $id"
