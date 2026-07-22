# Stage 2 image: take the deps image built from the repo's Dockerfile and bake
# in the RunPod start script. The WanGP source itself is NOT baked in -- it is
# cloned from your fork into the persistent /workspace volume at runtime by
# start.sh, so pod restarts keep both the code and the queue.
#
# Build order:
#   1. docker build -t wan2gp-deps -f Dockerfile .        # deps (torch, mmgp, SageAttention, ...)
#   2. docker build -t wan2gp-runpod -f runpod/Dockerfile .  # this file
#   3. docker tag wan2gp-runpod <registry>/wan2gp:latest && docker push <registry>/wan2gp:latest

FROM wan2gp-deps

COPY runpod/start.sh /start.sh
RUN chmod +x /start.sh

# Optional default repo URL baked into the image; the pod template's WAN2GP_REPO_URL
# env var overrides this at runtime.
ENV WAN2GP_REPO_URL=https://github.com/REPLACE/YOUR-FORK.git
ENV WAN2GP_BRANCH=main

ENTRYPOINT ["/start.sh"]