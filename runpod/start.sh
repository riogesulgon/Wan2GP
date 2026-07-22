#!/usr/bin/env bash
# Hardened RunPod start script for the Wan2GP fork (durable generation queue).
# Baked into the image at /opt/start.sh; the RunPod template runs it as CMD
# under `tini -g --` (PID 1), which forwards SIGTERM to this process group so
# wgp.py's _graceful_shutdown handler can flush queue.zip on pod stop.
set -Eeuo pipefail

: "${WAN2GP_PORT:=7862}"
: "${WAN2GP_LOG:=/workspace/wan2gp.log}"
WAN2GP_DIR="${WAN2GP_DIR:-/opt/Wan2GP}"

log(){ echo "[$(date -u +%H:%M:%S)] $*"; }

# --- /workspace is a RunPod Network Volume (persists across pod stops) ---
# Mounts as root; give the unprivileged `user` (uid 1000) ownership of the dirs
# it needs to write. Non-recursive (fast even with 100 GB of models on volume).
mkdir -p /workspace/outputs /workspace/hf-home /workspace/hf-cache \
         /workspace/.cache /workspace/.torchinductor /workspace/ckpts \
         /workspace/.ssh "$(dirname "$WAN2GP_LOG")"
touch "$WAN2GP_LOG"
chown user:user /workspace /workspace/outputs /workspace/hf-home /workspace/hf-cache \
                /workspace/.cache /workspace/.torchinductor /workspace/ckpts \
                /workspace/.ssh 2>/dev/null || true

# Persist model weights on the volume: symlink /opt/Wan2GP/ckpts -> /workspace/ckpts.
# Wan2GP's files_locator resolves "ckpts" relative to cwd (/opt/Wan2GP), so this
# makes the one-time ~15 GB Wan 2.1 I2V 14B download survive pod restarts.
if [ -e /opt/Wan2GP/ckpts ] && [ ! -L /opt/Wan2GP/ckpts ]; then
  log "WARN: /opt/Wan2GP/ckpts exists and is not a symlink; leaving as-is"
else
  ln -sfn /workspace/ckpts /opt/Wan2GP/ckpts
fi

# Seed /workspace/wgp_config.json if absent so outputs land on the volume.
# (Default save_path="outputs" is relative to /opt/Wan2GP, which is ephemeral.)
if [ ! -f /workspace/wgp_config.json ]; then
  cat > /workspace/wgp_config.json <<'JSON'
{
  "save_path": "/workspace/outputs",
  "image_save_path": "/workspace/outputs",
  "audio_save_path": "/workspace/outputs"
}
JSON
  log "Seeded /workspace/wgp_config.json (save_path=/workspace/outputs)"
fi
chown user:user /workspace/wgp_config.json 2>/dev/null || true

# 16 GB swap on the volume (best-effort; may not engage on network volumes).
if ! grep -q "/workspace/wan2gp.swap" /proc/swaps 2>/dev/null; then
  ( fallocate -l 16G /workspace/wan2gp.swap || dd if=/dev/zero of=/workspace/wan2gp.swap bs=1G count=16 ) 2>/dev/null || true
  chmod 600 /workspace/wan2gp.swap 2>/dev/null || true
  mkswap /workspace/wan2gp.swap >/dev/null 2>&1 || true
  swapon  /workspace/wan2gp.swap >/dev/null 2>&1 || true
fi

# CPU thread defaults.
export OMP_NUM_THREADS="$(nproc)"
export MKL_NUM_THREADS="$OMP_NUM_THREADS" OPENBLAS_NUM_THREADS="$OMP_NUM_THREADS"

# --- SSH: rsync-over-SSH + pod admin (port 22/tcp exposed in the template) ---
# Persist host keys on the volume (unique per pod, stable across restarts).
for kt in ed25519 rsa ecdsa; do
  if [ ! -f "/workspace/.ssh/ssh_host_${kt}_key" ]; then
    ssh-keygen -q -t "$kt" -N "" -f "/workspace/.ssh/ssh_host_${kt}_key" 2>/dev/null || true
  fi
  ln -sf "/workspace/.ssh/ssh_host_${kt}_key"     "/etc/ssh/ssh_host_${kt}_key"
  ln -sf "/workspace/.ssh/ssh_host_${kt}_key.pub" "/etc/ssh/ssh_host_${kt}_key.pub"
done
# Optional public key via env (RunPod also auto-injects your account key when
# 22/tcp is exposed). Append + dedupe.
if [ -n "${SSH_PUBLIC_KEY:-}" ]; then
  printf '%s\n' "$SSH_PUBLIC_KEY" >> /root/.ssh/authorized_keys
  sort -u -o /root/.ssh/authorized_keys /root/.ssh/authorized_keys 2>/dev/null || true
  chmod 600 /root/.ssh/authorized_keys
fi
mkdir -p /run/sshd
/usr/sbin/sshd
log "sshd started (port 22, key-only root login)"

# --- Launch Wan2GP with --config /workspace so queue.zip + config persist ---
log "=== BOOT $(date -u) | Wan2GP hardened RunPod image ==="
cd "$WAN2GP_DIR"
log "🚀 Starting Wan2GP on :$WAN2GP_PORT (--config /workspace for durable queue)"
# gosu drops to `user` (signal-safe); tini -g forwards SIGTERM to this group so
# the durable-queue _graceful_shutdown flush fires on RunPod pod stop.
gosu user python3 wgp.py --listen --config /workspace --server-port "$WAN2GP_PORT" >>"$WAN2GP_LOG" 2>&1 &

log "⌛ Waiting for UI ..."
for i in $(seq 1 180); do
  if curl -fs "http://127.0.0.1:${WAN2GP_PORT}/" >/dev/null 2>&1; then
    log "✅ Wan2GP UI READY on port ${WAN2GP_PORT}"
    break
  fi
  sleep 2
done

# Keep the container alive and stream logs. Signals reach the backgrounded
# wgp.py via tini -g's process-group forwarding.
exec tail -f "$WAN2GP_LOG"