# Hardened RunPod image for the Wan2GP fork (durable generation queue).
#
# Stage 2: layer the RunPod hardening on top of the deps image built from the
# repo's root Dockerfile (torch + mmgp + SageAttention). The Wan2GP source is
# cloned from your fork at a pinned commit (reproducible; the durable-queue
# code is baked in). Only data lives on the /workspace volume.
#
# Build order (from the Wan2GP repo root):
#   1. docker build -t wan2gp-deps \
#        --build-arg CUDA_ARCHITECTURES="8.0;8.6;8.9;9.0;12.0" -f Dockerfile .
#   2. docker build -t wan2gp-runpod \
#        --build-arg WAN2GP_COMMIT=main -f runpod/Dockerfile .
#   3. docker tag wan2gp-runpod ghcr.io/<your-user>/wan2gp:v1
#      docker push ghcr.io/<your-user>/wan2gp:v1

FROM wan2gp-deps

# Fork source. WAN2GP_COMMIT defaults to "main" (branch tip). To pin a specific
# commit for reproducibility, pass --build-arg WAN2GP_COMMIT=<sha> — a full
# clone + checkout is used so arbitrary SHAs resolve (shallow clones can't fetch
# an arbitrary SHA from GitHub).
ARG WAN2GP_REPO="https://github.com/riogesulgon/Wan2GP.git"
ARG WAN2GP_COMMIT="main"

ENV WAN2GP_DIR=/opt/Wan2GP \
    WAN2GP_PORT=7862

# System packages: tini (PID 1 signal forwarding), gosu (priv drop, signal-safe),
# aria2 (fast downloads), jq, openssh-server + rsync (rsync-over-SSH).
RUN apt-get update -y && apt-get install -y --no-install-recommends \
        tini gosu aria2 jq openssh-server rsync \
 && rm -rf /var/lib/apt/lists/*

# Clone the fork into /opt/Wan2GP (baked into the image). Shallow clone for the
# default (main); full clone + checkout for a pinned commit SHA (GitHub rejects
# fetching an arbitrary SHA into a shallow clone — "couldn't find remote ref").
RUN if [ "${WAN2GP_COMMIT}" = "main" ]; then \
      git clone --depth 1 "${WAN2GP_REPO}" "${WAN2GP_DIR}"; \
    else \
      git clone "${WAN2GP_REPO}" "${WAN2GP_DIR}" && \
      cd "${WAN2GP_DIR}" && git checkout "${WAN2GP_COMMIT}"; \
    fi

# /opt/Wan2GP is baked as root, but wgp.py runs as `user` (gosu) and creates
# `settings/` (and other runtime files) in cwd — chown the repo so it can write.
RUN chown -R user:user "${WAN2GP_DIR}"

# SSH: key-only root login (drop-in). Host keys are generated at runtime by
# start.sh and persisted on the /workspace volume (unique per pod, stable).
RUN mkdir -p /run/sshd /root/.ssh && chmod 700 /root/.ssh && \
    printf 'PermitRootLogin prohibit-password\nPubkeyAuthentication yes\nPasswordAuthentication no\n' \
      > /etc/ssh/sshd_config.d/10-wan2gp.conf

# Hardening env defaults (overridable via the RunPod template env).
ENV PYTHONUNBUFFERED=1 \
    HF_HOME=/workspace/hf-home \
    HUGGINGFACE_HUB_CACHE=/workspace/hf-cache \
    XDG_CACHE_HOME=/workspace/.cache \
    HF_HUB_ENABLE_HF_TRANSFER=1 \
    TORCHINDUCTOR_CACHE_DIR=/workspace/.torchinductor \
    PYTORCH_CUDA_ALLOC_CONF="expandable_segments:True,max_split_size_mb:256" \
    CUBLAS_WORKSPACE_CONFIG=:16:8 \
    GRADIO_SERVER_NAME=0.0.0.0 \
    GRADIO_SERVER_PORT=7862 \
    GRADIO_ROOT_PATH=/ \
    GRADIO_ALLOW_FLAGGING=never \
    GRADIO_SHARE=False \
    GRADIO_USE_CDN=False \
    GRADIO_NUM_WORKERS=1 \
    GRADIO_CONCURRENCY_COUNT=1 \
    UV_THREADPOOL_SIZE=8 \
    MMGP_RESERVED_RAM_GB=10 \
    TORCH_ALLOW_TF32_CUBLAS=1 \
    TORCH_ALLOW_TF32_CUDNN=1 \
    SDL_AUDIODRIVER=dummy \
    WAN2GP_LOG=/workspace/wan2gp.log \
    WANGP_FFMPEG_VIDEO="-c:v h264_nvenc -preset p1 -rc vbr -cq 22 -pix_fmt yuv420p -vf scale=trunc(iw/16)*16:trunc(ih/16)*16" \
    WANGP_FFMPEG_AUDIO="-c:a aac -b:a 128k"

COPY runpod/start.sh    /opt/start.sh
COPY runpod/restart.sh  /usr/local/bin/restart-wan2gp.sh
RUN chmod +x /opt/start.sh /usr/local/bin/restart-wan2gp.sh

# Persistent subdirs (network volume mounts here at runtime).
RUN mkdir -p /workspace/outputs /workspace/hf-home /workspace/hf-cache \
             /workspace/.cache /workspace/.torchinductor /workspace/ckpts

WORKDIR ${WAN2GP_DIR}
EXPOSE 7862 22

# tini -g forwards signals (SIGTERM from RunPod pod stop) to the whole process
# group so wgp.py's _graceful_shutdown handler flushes queue.zip before exit.
ENTRYPOINT ["/usr/bin/tini","-g","--"]
CMD ["/opt/start.sh"]