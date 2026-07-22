#!/usr/bin/env bash
# RunPod container start script for Wan2GP (fork with durable queue).
#
# Bake this into the image (see runpod/Dockerfile) and set the pod template's
# containerStartCommand to "/start.sh".
#
# Behaviour:
#   - /workspace is a RunPod Network Volume (persists across pod stops/restarts).
#   - If the fork's code is not present in /workspace, clone it; otherwise pull.
#   - Launch WanGP with --config /workspace so queue.zip, wgp_config.json and the
#     _loaded_queue_cache media cache all land on the persistent volume.
#   - HF_HOME is pointed at the volume so downloaded models persist too.
set -euo pipefail

: "${WAN2GP_REPO_URL:=https://github.com/REPLACE/YOUR-FORK.git}"
: "${WAN2GP_BRANCH:=main}"
: "${SERVER_PORT:=7860}"

# Network volumes mount as root; give the unprivileged `user` (uid 1000, created
# by the base Dockerfile) ownership of the volume so it can write queue.zip etc.
chown -R user:user /workspace 2>/dev/null || true

if [ -d /workspace/.git ]; then
    echo "[runpod] existing clone found in /workspace; pulling updates"
    cd /workspace
    git fetch --depth 1 origin "$WAN2GP_BRANCH" || true
    git reset --hard "origin/$WAN2GP_BRANCH" || true
elif [ ! -f /workspace/wgp.py ]; then
    echo "[runpod] cloning $WAN2GP_REPO_URL (branch $WAN2GP_BRANCH) into /workspace"
    git clone --depth 1 -b "$WAN2GP_BRANCH" "$WAN2GP_REPO_URL" /workspace
    chown -R user:user /workspace 2>/dev/null || true
else
    echo "[runpod] /workspace has wgp.py but no .git; launching in place"
fi

cd /workspace

# Hand off to the unprivileged user. --listen binds 0.0.0.0 so the RunPod proxy
# can reach Gradio on the exposed port. --config /workspace puts queue.zip and
# wgp_config.json on the persistent volume.
export HF_HOME="${HF_HOME:-/workspace/hf_cache}"
export PYTHONUNBUFFERED=1
export TORCH_ALLOW_TF32_CUBLAS=1
export TORCH_ALLOW_TF32_CUDNN=1
export SDL_AUDIODRIVER=dummy

exec su -p user -c "python3 wgp.py --listen --config /workspace --server-port $SERVER_PORT"