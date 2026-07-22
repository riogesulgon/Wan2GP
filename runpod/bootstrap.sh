#!/usr/bin/env bash
# Bootstraps Wan2GP (riogesulgon fork) on a RunPod pod — no custom image build.
#
# What it does:
#   1. Clones (or updates) the fork onto the persistent /workspace volume.
#   2. Seeds /workspace/wgp_config.json so outputs land on the volume.
#   3. Installs torch 2.10+cu128 + requirements.txt (idempotent; pip cache on the
#      volume so re-installs after a wiped container disk are fast).
#   4. exec's wgp.py so it becomes PID 1 and receives RunPod's SIGTERM directly
#      -> the durable-queue _graceful_shutdown handler flushes queue.zip on stop.
#
# Use it as the pod/template start command (see runpod/template-simple.json), or
# run it manually from the RunPod web terminal:
#   bash /workspace/Wan2GP/runpod/bootstrap.sh
#
# Env (all optional):
#   WAN2GP_REPO     default https://github.com/riogesulgon/Wan2GP
#   WAN2GP_BRANCH   default main
#   WAN2GP_DIR      default /workspace/Wan2GP   (on the persistent volume)
#   WAN2GP_PORT     default 7862   (MUST match the HTTP port you expose in RunPod)
#   WAN2GP_CONFIG   default /workspace  (where queue.zip + wgp_config.json live)
#   TORCH_INDEX     default https://download.pytorch.org/whl/cu128
#   PIP_CACHE_DIR   default /workspace/pip-cache  (on the volume -> survives restarts)
set -euo pipefail

WAN2GP_REPO="${WAN2GP_REPO:-https://github.com/riogesulgon/Wan2GP}"
WAN2GP_BRANCH="${WAN2GP_BRANCH:-main}"
WAN2GP_DIR="${WAN2GP_DIR:-/workspace/Wan2GP}"
WAN2GP_PORT="${WAN2GP_PORT:-7862}"
WAN2GP_CONFIG="${WAN2GP_CONFIG:-/workspace}"
TORCH_INDEX="${TORCH_INDEX:-https://download.pytorch.org/whl/cu128}"
PIP_CACHE_DIR="${PIP_CACHE_DIR:-/workspace/pip-cache}"

log(){ printf '[bootstrap] %s\n' "$*"; }

mkdir -p "$WAN2GP_CONFIG/outputs" "$PIP_CACHE_DIR"
export PIP_CACHE_DIR

# --- base tools (skip if already present) -----------------------------------
if ! command -v git >/dev/null 2>&1; then
  log "installing git"; apt-get update -y && apt-get install -y --no-install-recommends git ca-certificates
fi
if ! command -v pip >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  log "installing pip"; apt-get update -y && apt-get install -y --no-install-recommends python3-pip
fi

# --- clone or update the fork onto the persistent volume --------------------
if [ -d "$WAN2GP_DIR/.git" ]; then
  log "updating existing clone at $WAN2GP_DIR"
  git -C "$WAN2GP_DIR" fetch --depth 1 origin "$WAN2GP_BRANCH"
  git -C "$WAN2GP_DIR" reset --hard "origin/$WAN2GP_BRANCH"
else
  log "cloning $WAN2GP_REPO ($WAN2GP_BRANCH) -> $WAN2GP_DIR"
  git clone --depth 1 -b "$WAN2GP_BRANCH" "$WAN2GP_REPO" "$WAN2GP_DIR"
fi
cd "$WAN2GP_DIR"

# --- seed wgp_config.json so outputs land on the volume (not the clone dir) --
if [ ! -f "$WAN2GP_CONFIG/wgp_config.json" ]; then
  log "seeding $WAN2GP_CONFIG/wgp_config.json (save_path=/workspace/outputs)"
  cat > "$WAN2GP_CONFIG/wgp_config.json" <<'JSON'
{
  "save_path": "/workspace/outputs",
  "image_save_path": "/workspace/outputs",
  "audio_save_path": "/workspace/outputs"
}
JSON
fi

# --- python deps (idempotent: "Requirement already satisfied" is instant, ---
#     so re-runs on restart are cheap; cache on the volume avoids re-downloads) -
log "upgrading pip/setuptools/wheel"
pip install --upgrade pip setuptools wheel

log "installing torch 2.10+cu128 (matches upstream Dockerfile; ~5 GB first time)"
pip install torch==2.10.0+cu128 torchvision==0.25.0+cu128 torchaudio==2.10.0+cu128 \
  --index-url "$TORCH_INDEX"

log "installing requirements.txt"
pip install -r requirements.txt

# --- start the server -------------------------------------------------------
# exec -> wgp.py replaces this shell as PID 1, so RunPod's SIGTERM on pod stop
# reaches it directly and the durable-queue handler flushes queue.zip.
log "starting Wan2GP on :$WAN2GP_PORT (config=$WAN2GP_CONFIG)"
cd "$WAN2GP_DIR"
exec python3 wgp.py --listen --config "$WAN2GP_CONFIG" --server-port "$WAN2GP_PORT"