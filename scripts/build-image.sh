#!/usr/bin/env bash
# Builds the build container and pins its digest.
#
# The image is consumed by digest, not by tag (ADR-0020): a tag can move, a
# digest cannot. This script builds the image locally and writes the digest to
# container.digest; in CI the same is done by the workflow whenever the
# Dockerfile changes.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
image=${IMAGE:-marvin-kernel-h618}
tag=${TAG:-local}

docker build -t "$image:$tag" "$root"

# A locally built image has no registry digest, so we pin its ID instead. Once
# published to ghcr.io, it is the registry digest that gets written here.
id=$(docker image inspect --format '{{.Id}}' "$image:$tag")
echo "$id" > "$root/container.digest"
echo "image: $image:$tag"
echo "digest: $id"
