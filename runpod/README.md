# RunPod template — Wan2GP fork (durable generation queue, hardened)

Hardened RunPod Pod template for the [riogesulgon/Wan2GP](https://github.com/riogesulgon/Wan2GP)
fork (based on upstream `deepbeepmeep/Wan2GP` v12.34). It keeps the **durable
generation queue** (`../QUEUE_PERSISTENCE_PLAN.md`) and adopts the proven
hardening from community templates (ProbeAI's `wan2gp-template`).

Target use case: **Wan 2.1 I2V 14B** on a single-user RunPod GPU pod.

## What persists on the /workspace Network Volume

| Artifact | Path | Why |
| --- | --- | --- |
| Generation queue | `/workspace/queue.zip` | `--config /workspace` → `AUTOSAVE_PATH` |
| App config | `/workspace/wgp_config.json` | `--config /workspace`; seeded by `start.sh` |
| Generated outputs | `/workspace/outputs` | `save_path` seeded in `wgp_config.json` |
| Model weights | `/workspace/ckpts` (symlinked from `/opt/Wan2GP/ckpts`) | Wan2GP downloads lazily on first generation; persists across restarts |
| Loaded-queue media cache | `/workspace/outputs/_loaded_queue_cache` | `_parse_queue_zip` cache_dir |
| HF cache / creds | `/workspace/hf-cache`, `/workspace/hf-home` | `HF_HOME`, `HUGGINGFACE_HUB_CACHE` |
| torchinductor cache | `/workspace/.torchinductor` | warm kernels persist |
| SSH host keys | `/workspace/.ssh` | unique per pod, stable across restarts |
| Logs | `/workspace/wan2gp.log` | debugging across restarts |

Model download is **not** our job — Wan2GP auto-downloads (architecture-aware) on
first generation to `ckpts/`, which we symlink to the volume, so the ~15 GB int8
Wan 2.1 I2V 14B transformer downloads **once, ever**.

## Files

| File | Purpose |
| --- | --- |
| `Dockerfile` | Stage-2 image: deps image + `tini gosu aria2 jq openssh-server rsync`; clones the fork at a pinned commit into `/opt/Wan2GP`; bakes hardening env; `ENTRYPOINT ["tini","-g","--"]`, `CMD ["/opt/start.sh"]`. |
| `start.sh` | Boot: chown volume, `ckpts` symlink, seed `wgp_config.json`, 16 GB swap, start sshd, launch `wgp.py --listen --config /workspace` via `gosu`, readiness probe, log tail. |
| `restart.sh` | `restart-wan2gp.sh` — restart WanGP without restarting the pod. |
| `template.json` | RunPod Pod template (API body format). |
| `PUBLISH.md` | How to publish the template (UI + REST API). |
| `PLAN.md` | The hardening plan (rationale + decisions). |

## Build & push the image (two stages)

```bash
# from the Wan2GP repo root
# 1. deps image (torch/mmgp/SageAttention) — slow; rebuild only when deps change.
#    CUDA_ARCHITECTURES covers every RunPod NVIDIA GPU with SM >= 8.0
#    (A100/A30, A40/A5000/A6000/3090, 4090/L4/L40/Ada-pros, H100/H200,
#    5090/B200/Blackwell). V100 (sm 7.0) runs via fallback.
docker build -t wan2gp-deps \
  --build-arg CUDA_ARCHITECTURES="8.0;8.6;8.9;9.0;12.0" -f Dockerfile .

# 2. hardened RunPod image (deps + start.sh + pinned fork commit).
#    Override WAN2GP_COMMIT when you rebuild after pushing new fork commits.
docker build -t wan2gp-runpod \
  --build-arg WAN2GP_COMMIT=main -f runpod/Dockerfile .

# 3. push to ghcr.io (immutable tag recommended)
docker tag wan2gp-runpod ghcr.io/riogesulgon/wan2gp:v1
docker push ghcr.io/riogesulgon/wan2gp:v1
```

> If the SageAttention build fails on `12.0` (Blackwell) with the pinned version,
> drop it: `--build-arg CUDA_ARCHITECTURES="8.0;8.6;8.9;9.0"`. RTX 5090/B200 still
> run via the SDPA fallback.

## Create the template on RunPod

`runpod/template.json` is in the RunPod `POST /templates` body format. Either
import via the API (see `PUBLISH.md`) or recreate in the UI
(`console.runpod.io → Templates → New Template`):

| UI field | Value |
| --- | --- |
| Template name | `Wan2GP (riogesulgon fork) — durable queue` |
| Container image | `ghcr.io/riogesulgon/wan2gp:v1` |
| Compute type | NVIDIA |
| Container disk | 40 GB |
| Volume disk size | 200 GB |
| Volume mount path | `/workspace` |
| HTTP port | `7862` |
| TCP port | `22` (SSH / rsync) |
| Container start command | *(leave empty — image `ENTRYPOINT` is `tini -g --` → `/opt/start.sh`)* |
| Env | `WAN2GP_PORT=7862`, `WAN2GP_COMMIT=main`, `HF_HUB_ENABLE_HF_TRANSFER=1` (+ optional `SSH_PUBLIC_KEY`) |
| Visibility | Public |

## Deploy & connect

1. Deploy a pod from the template on a RunPod NVIDIA GPU.
2. First boot logs show: `sshd started`, `Seeded /workspace/wgp_config.json`,
   `✅ Wan2GP UI READY on port 7862`.
3. Open the `7862/http` proxy URL → Gradio UI.
4. For SSH/rsync: read the external port + public IP from **Connect → Direct TCP
   Ports**.

## rsync (over the exposed `22/tcp`)

```bash
# upload models/checkpoints into the pod's persistent volume
rsync -avzP -e "ssh -p <ext-port> -i <key>" ./ckpts/ root@<pod-public-ip>:/workspace/ckpts/
# download generated outputs
rsync -avzP -e "ssh -p <ext-port> -i <key>" root@<pod-public-ip>:/workspace/outputs/ ./outputs/
```

Add your SSH public key via the `SSH_PUBLIC_KEY` env (or rely on RunPod's
account-key auto-injection when `22/tcp` is exposed). Restart the pod to apply
env changes.

## Verification

1. **Boot**: logs show `sshd started` and `✅ Wan2GP UI READY on port 7862`.
2. **First generation**: Wan 2.1 I2V 14B downloads once to `/workspace/ckpts`;
   output appears in `/workspace/outputs`.
3. **Durable queue (SIGTERM)**: enqueue 3 jobs → `kill -TERM 1` (or RunPod
   Stop) → `/workspace/queue.zip` exists with 3 pending tasks (`unzip -l`).
4. **Autoload**: Start the pod again, open a **new** browser session → the 3
   pending tasks + media autoload; completed tasks are not re-run.
5. **rsync**: `rsync` into `/workspace/ckpts` over the exposed SSH port succeeds.
6. **restart.sh**: `restart-wan2gp.sh` restarts WanGP without a pod restart; queue intact.
7. `free -h` shows swap (if the volume supports it); `env` shows the hardening vars.

## Caveats

- **GPU ↔ image match**: SageAttention is compiled at build time for
  `CUDA_ARCHITECTURES`. Deploy on a matching GPU, or rebuild with a different set.
- **Per-session queue**: the queue is per browser session. The durable store
  (`queue.zip`) is shared, so two simultaneous browser sessions against the same
  pod can both autoload the same pending tasks → duplicate generations. Fine for
  single-user use; not for multi-client serving.
- **SIGKILL / OOM-kill** can't be caught; per-mutation autosave (not the SIGTERM
  handler) covers those — on-disk `queue.zip` is at worst one mutation behind.
- **Swap** is best-effort on the network volume and may not engage; the env
  tuning (`PYTORCH_CUDA_ALLOC_CONF`, `MMGP_RESERVED_RAM_GB`) is the real OOM mitigation.
- **NVENC** `h264_nvenc` requires the host driver (present on RunPod); if a future
  image's ffmpeg lacks nvenc, fall back to libx264 via `WANGP_FFMPEG_VIDEO`.