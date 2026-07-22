#!/usr/bin/env bash
# Build the two-stage hardened RunPod image and optionally push to ghcr.io.
#
# Run this on a host with plenty of free disk (>= ~60 GB) and RAM (>= ~16 GB):
#   - a RunPod pod with a large container disk (no GPU needed for the build —
#     the Dockerfile patches SageAttention to compile for env CUDA_ARCH_LIST
#     without GPU detection), or
#   - a CI runner with a large disk.
# Not on a tight dev box (the CUDA devel base + torch + 5-arch SageAttention
# build is ~15-20 GB plus build cache).
#
# Usage:
#   CUDA_ARCHITECTURES="8.0;8.6;8.9;9.0;12.0" WAN2GP_COMMIT=3646c7f \
#     IMAGE=ghcr.io/riogesulgon/wan2gp:v1 PUSH=1 bash runpod/build.sh
#
# If the 5-arch build OOMs or is too slow, drop 12.0 (Blackwell) and rebuild:
#   CUDA_ARCHITECTURES="8.0;8.6;8.9;9.0" bash runpod/build.sh
# Or cap the SageAttention parallelism to avoid OOM on a low-RAM build host:
#   MAX_JOBS=4 CUDA_ARCHITECTURES="8.0;8.6;8.9;9.0;12.0" bash runpod/build.sh
set -euo pipefail

CUDA_ARCHITECTURES="${CUDA_ARCHITECTURES:-8.0;8.6;8.9;9.0;12.0}"
WAN2GP_COMMIT="${WAN2GP_COMMIT:-3646c7f}"
MAX_JOBS="${MAX_JOBS:-8}"
IMAGE="${IMAGE:-ghcr.io/riogesulgon/wan2gp:v1}"
PUSH="${PUSH:-0}"

# Run from the Wan2GP repo root (this script lives in runpod/).
cd "$(dirname "$0")/.."

echo "==> Stage 1: deps image (CUDA_ARCHITECTURES=$CUDA_ARCHITECTURES, MAX_JOBS=$MAX_JOBS)"
docker build -t wan2gp-deps \
  --build-arg CUDA_ARCHITECTURES="$CUDA_ARCHITECTURES" \
  --build-arg MAX_JOBS="$MAX_JOBS" -f Dockerfile .

echo "==> Stage 2: hardened RunPod image (WAN2GP_COMMIT=$WAN2GP_COMMIT)"
docker build -t wan2gp-runpod \
  --build-arg WAN2GP_COMMIT="$WAN2GP_COMMIT" -f runpod/Dockerfile .

echo "==> Tag $IMAGE"
docker tag wan2gp-runpod "$IMAGE"

if [ "$PUSH" = "1" ]; then
  echo "==> Push $IMAGE"
  docker push "$IMAGE"
else
  echo "==> Built locally as $IMAGE (set PUSH=1 to push)"
fi