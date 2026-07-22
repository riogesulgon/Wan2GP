# RunPod template — Wan2GP fork (durable generation queue)

This template runs the Wan2GP fork with the **durable generation queue** change
(see [`../QUEUE_PERSISTENCE_PLAN.md`](../QUEUE_PERSISTENCE_PLAN.md)). On RunPod the
key is mounting a **Network Volume at `/workspace`** and launching with
`--config /workspace`, so `queue.zip`, `outputs/`, the `_loaded_queue_cache`
media cache, `wgp_config.json`, and downloaded HuggingFace models all live on the
persistent volume and survive pod stops / restarts / redeployments.

## Files

| File | Purpose |
| --- | --- |
| `start.sh` | Container start script (baked into the image). Clones/updates your fork into `/workspace`, `chown`s the volume to the unprivileged `user`, launches `wgp.py --listen --config /workspace`. |
| `Dockerfile` | Stage-2 image: deps image (from the repo's `Dockerfile`) + `start.sh`. The WanGP source is **not** baked in — it is cloned from your fork into the persistent volume at runtime. |
| `template.json` | RunPod Pod template spec (image, `/workspace` volume, port `7860/http`, env, start command). |

## Build & push the image

The repo's `Dockerfile` builds a deps-only image (torch, mmgp, SageAttention, ffmpeg, …).
The `runpod/Dockerfile` layers `start.sh` on top. **Build for your GPU's CUDA
architecture** (see the `CUDA_ARCHITECTURES` build-arg in the repo `Dockerfile`,
e.g. `8.9` for RTX 4090, `12.0` for RTX 5090).

```bash
# from the Wan2GP repo root
# 1. deps image (torch/mmgp/SageAttention) — slow, rebuild only when deps change
docker build -t wan2gp-deps --build-arg CUDA_ARCHITECTURES="8.9" -f Dockerfile .

# 2. runpod image (deps + start.sh) — fast
docker build -t wan2gp-runpod -f runpod/Dockerfile .

# 3. push to a registry RunPod can pull (ghcr.io, Docker Hub, etc.)
docker tag wan2gp-runpod ghcr.io/<your-user>/wan2gp:latest
docker push ghcr.io/<your-user>/wan2gp:latest
```

## Fill in the placeholders

Search-and-replace `REPLACE` across these files:

- `runpod/Dockerfile` — `ENV WAN2GP_REPO_URL=https://github.com/REPLACE/YOUR-FORK.git`
- `runpod/start.sh` — `WAN2GP_REPO_URL` default
- `runpod/template.json` — `"image": "ghcr.io/REPLACE/wan2gp:latest"` and the
  `WAN2GP_REPO_URL` env value (must point to **your** published fork, since it
  contains the durable-queue changes)

## Create the template on RunPod

You can create the template from the **Web console** or the **REST API**.
"Publishing" = setting visibility: **Private** (only you/your team) or **Public**
(appears in the Explore section for all RunPod users). The template itself just
references an image tag and a config; it does not store the image. Use an
immutable tag (e.g. `:v1`) rather than `:latest` if you want reproducible pods.

### Option A — Web console

`runpod/template.json` is already in the RunPod **REST API** body format (see
Option B). For the UI, go to **console.runpod.io → Templates → New Template**
and fill the form with these values:

| UI field | Value |
| --- | --- |
| Template name | `Wan2GP (fork) — durable queue` |
| Container image | `ghcr.io/<your-user>/wan2gp:v1` |
| Compute type | NVIDIA |
| Container disk | 40 GB |
| Volume disk size | 200 GB (fit your models + outputs) |
| Volume mount path | `/workspace` |
| HTTP port | `7860` |
| Container start command | *(leave empty — the image `ENTRYPOINT` is `/start.sh`)* |
| Registry credentials | add if your image is in a private registry |
| Env vars | `WAN2GP_REPO_URL`, `WAN2GP_BRANCH=main`, `HF_HOME=/workspace/hf_cache`, … (as in `template.json`) |
| Visibility | Private (default) or Public to share |

Save, then **deploy a Pod from it** to test before making it Public.

### Option B — REST API

```bash
curl -X POST https://api.runpod.io/v2/templates \
  -H "Authorization: Bearer $RUNPOD_API_KEY" \
  -H "Content-Type: application/json" \
  --data @runpod/template.json
```

Set `"isPublic": true` in `template.json` to publish it to all RunPod users
(or keep `false` and flip it later in the UI). The response returns the template
`id`; other users deploy from it with `POST /pods` referencing that id, or via
the Explore page if public.

Note: the API uses `imageName`, `containerDiskInGb`, `volumeInGb`, `ports`
(array of `"<port>/<proto>"`), `env` (a `{KEY: value}` object), and
`dockerStartCmd`/`dockerEntrypoint` (arrays that override CMD/ENTRYPOINT). We
omit `dockerStartCmd` because the image already has `ENTRYPOINT ["/start.sh"]`.
GPU count/type are chosen at deploy time, not in the template.

## Deploy & connect

1. Deploy a pod from the template. First boot clones your fork into `/workspace`
   (a few seconds); subsequent boots `git pull` (fast) or launch in place.
2. Open the `7860/http` port in the RunPod console → the Gradio UI.
3. Enqueue a few jobs, then **stop the pod** (RunPod sends SIGTERM). The
   durable-queue code flushes `queue.zip` on the SIGTERM handler and on every
   queue mutation, so `/workspace/queue.zip` is current.
4. **Start the pod again** → the queue autoloads automatically into the new
   session (tasks + media), without re-running already-completed jobs.

## How persistence maps to the volume

| Artifact | Path | Persists because |
| --- | --- | --- |
| Generation queue | `/workspace/queue.zip` | `--config /workspace` → `AUTOSAVE_PATH` |
| App config | `/workspace/wgp_config.json` | `--config /workspace` |
| Generated outputs | `/workspace/outputs/` | default `save_path="outputs"` under WORKDIR |
| Loaded-queue media cache | `/workspace/outputs/_loaded_queue_cache/` | `_parse_queue_zip` cache_dir |
| HuggingFace models | `/workspace/hf_cache/` | `HF_HOME=/workspace/hf_cache` |

## Notes / caveats

- **GPU ↔ image match**: SageAttention is compiled at build time for the
  `CUDA_ARCHITECTURES` build-arg. Deploy on a GPU matching what you built for,
  or rebuild.
- **Per-session queue**: the queue is per browser session. The durable store
  (`queue.zip`) is shared, so if two browser sessions connect to the same pod
  simultaneously they can both autoload the same pending tasks → duplicate
  generations. Fine for single-user use; not intended for multi-client serving.
- **SIGKILL / OOM-kill** cannot be caught; the per-mutation autosave (not the
  SIGTERM handler) is what covers those — so the on-disk `queue.zip` is at worst
  one mutation behind.
- **Registry auth**: if your image is in a private registry, add the registry
  credentials in RunPod's *Registry auth* settings so the pod can pull it.