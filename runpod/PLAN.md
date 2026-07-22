# RunPod template hardening plan (Wan2GP fork — durable queue)

> **Status: implemented** in `runpod/` (`Dockerfile`, `start.sh`, `restart.sh`,
> `template.json`, `README.md`). JSON + bash validated. Build + RunPod deploy
> + the §10 verification steps remain (need a GPU + RunPod account). Fork
> published at https://github.com/riogesulgon/Wan2GP (commit 3646c7f).

Goal: ship a hardened RunPod Pod template for the Wan2GP fork that (a) keeps the
**durable generation queue** work, (b) adopts the proven hardening from existing
community templates (notably ProbeAI's `ArpitKhurana-ai/wan2gp-template`), and
(c) targets the user's single-model use case: **Wan 2.1 I2V 14B**.

Reference: see `runpod/PUBLISH.md` for how to publish the result, and
`../QUEUE_PERSISTENCE_PLAN.md` for the durable-queue code changes (already
implemented in `wgp.py`).

---

## 1. Code/data layout (decided)

| Layer | Location | Persists? | Why |
|---|---|---|---|
| Wan2GP fork code (pinned commit) | `/opt/Wan2GP` (baked in image) | no (ephemeral) | Reproducible, fast boot, no breaking nightly updates. Durable-queue code is baked in. |
| Generation queue | `/workspace/queue.zip` | **yes** (volume) | `--config /workspace` → `AUTOSAVE_PATH` |
| App config + loras multipliers | `/workspace/wgp_config.json` | **yes** | `--config /workspace`; seeded by `start.sh` if absent |
| Generated outputs | `/workspace/outputs` | **yes** | `save_path` seeded in `wgp_config.json` |
| HF model weights | `/workspace/hf-home`, `/workspace/hf-cache` | **yes** | `HF_HOME`, `HUGGINGFACE_HUB_CACHE` |
| Loaded-queue media cache | `/workspace/outputs/_loaded_queue_cache` | **yes** | `_parse_queue_zip` cache_dir |
| torchinductor cache | `/workspace/.torchinductor` | **yes** | `TORCHINDUCTOR_CACHE_DIR` |
| Logs | `/workspace/wan2gp.log` | **yes** | for debugging across restarts |

Volume = RunPod Network Volume mounted at `/workspace`. `start.sh` `chown`s it to
the unprivileged `user` (uid 1000, created by the repo `Dockerfile`) on boot.

> **Model download is NOT our job.** Wan2GP already auto-downloads
> (architecture-aware) lazily on first generation, to `ckpts/` — but since the
> repo root is now `/opt/Wan2GP` (ephemeral), we must redirect the checkpoints
> cache to the volume too. Wan2GP uses `ckpts/` relative to `wgp_root`
> (`os.getcwd()`). So `start.sh` will `cd /opt/Wan2GP` and symlink
> `/opt/Wan2GP/ckpts` → `/workspace/ckpts`, so the ~15 GB int8 Wan 2.1 I2V 14B
> transformer downloads once and persists. (Verified:
> `shared/utils/files_locator.py: _checkpoints_paths = ["ckpts", "."]`.)

---

## 2. Image build — two-stage

### Stage 1 — deps (unchanged): repo `Dockerfile`
`nvidia/cuda:12.8.1-cudnn-devel-ubuntu22.04` + torch 2.10 cu128 + mmgp + SageAttention
(built for `CUDA_ARCHITECTURES` build-arg). Heavy, rebuilt rarely. Tag `wan2gp-deps`.

### Stage 2 — `runpod/Dockerfile` (rewrite), `FROM wan2gp-deps`
- `apt-get install` additions: `tini gosu aria2 jq openssh-server rsync`
  (git/curl/ffmpeg/cmake already present from stage 1). `openssh-server` + `rsync`
  enable rsync-over-SSH (see §6).
- Clone the **fork** at a **pinned commit** into `/opt/Wan2GP` (build args
  `WAN2GP_REPO` default = the user's fork, `WAN2GP_COMMIT` default = the durable-queue
  commit). `git clone --depth 1` + fetch/checkout the commit.
- (Optional, env-gated, default **off**) pre-bake LoRAs via `runpod/prefetch.sh` —
  not needed for the Wan-2.1-I2V-14B-only use case.
- `COPY runpod/start.sh runpod/restart.sh` into `/opt/`.
- Bake env defaults (see §4) via `ENV`.
- Prepare persistent dirs: `mkdir -p /workspace/outputs /workspace/hf-home
  /workspace/hf-cache /workspace/.cache /workspace/.torchinductor`.
- `WORKDIR /opt/Wan2GP`
- `EXPOSE 7862 22` (7862 = RunPod HTTP proxy port, configurable via `WAN2GP_PORT`;
  22 = SSH for rsync-over-SSH + pod admin).
- `ENTRYPOINT ["tini","-g","--"]`  ← signal forwarding to the process group
- `CMD ["/opt/start.sh"]`

> **Why tini -g:** RunPod sends SIGTERM on pod stop. `tini -g` forwards it to the
> whole process group, so `wgp.py` receives SIGTERM and our `_graceful_shutdown`
> handler (`wgp.py`) flushes `queue.zip` before exit. Without this, `su` (the repo
> `entrypoint.sh`'s PID 1) may swallow the signal and the flush never runs.

---

## 3. `runpod/start.sh` (rewrite)

Responsibilities, in order:

1. **Drop to user safely** via `gosu` (signal-friendly, unlike `su`).
2. `chown -R user:user /workspace` (network volume mounts as root).
3. **Symlink** `/opt/Wan2GP/ckpts` → `/workspace/ckpts` so model weights persist.
4. **Seed `/workspace/wgp_config.json`** if absent, with:
   ```json
   { "save_path": "/workspace/outputs",
     "image_save_path": "/workspace/outputs",
     "audio_save_path": "/workspace/outputs" }
   ```
   (so outputs land on the volume, not ephemeral `/opt/Wan2GP/outputs`).
5. **16 GB swap** on `/workspace/wan2gp.swap` (`fallocate` → `mkswap` → `swapon`,
   best-effort) — prevents GPU OOM.
6. **Export hardening env** (idempotent `:=` defaults; see §4).
7. **Start sshd** for rsync-over-SSH + pod admin: `mkdir -p /run/sshd &&
   /usr/sbin/sshd`. Key auth only (`PermitRootLogin prohibit-password`); if the
   `SSH_PUBLIC_KEY` env is set, append it to `/root/.ssh/authorized_keys` (RunPod
   also injects your account SSH key automatically when `22/tcp` is exposed). This
   enables `rsync -avzP -e "ssh -p <ext> -i <key>" ./ root@<pod-ip>:/workspace/...`
   using the external port from Connect → Direct TCP Ports.
8. **(Optional, env-gated) prefetch** the Wan 2.1 I2V 14B int8 checkpoint to
   `/workspace/ckpts` before launch — only if `PREFETCH_MODEL=1`.
9. `cd /opt/Wan2GP` and launch:
   `exec gosu user python3 wgp.py --listen --config /workspace --server-port "$WAN2GP_PORT"`
   redirected to `/workspace/wan2gp.log`.
10. **Readiness probe**: poll `curl -fs http://127.0.0.1:$WAN2GP_PORT/` for ≤180×2s,
   log `✅ Wan2GP UI READY on port N`, then `exec tail -f /workspace/wan2gp.log`.

---

## 4. Hardening env (baked in Dockerfile, overridable in `template.json`)

| Env | Value | Purpose |
|---|---|---|
| `WAN2GP_PORT` | `7862` | UI port (RunPod HTTP proxy) |
| `HF_HOME` | `/workspace/hf-home` | HF creds persist |
| `HUGGINGFACE_HUB_CACHE` | `/workspace/hf-cache` | model weights persist |
| `XDG_CACHE_HOME` | `/workspace/.cache` | misc cache persists |
| `HF_HUB_ENABLE_HF_TRANSFER` | `1` | fast HF downloads |
| `TORCHINDUCTOR_CACHE_DIR` | `/workspace/.torchinductor` | warm kernels persist |
| `PYTORCH_CUDA_ALLOC_CONF` | `expandable_segments:True,max_split_size_mb:256` | reduce fragmentation/OOM |
| `CUBLAS_WORKSPACE_CONFIG` | `:16:8` | deterministic cuBLAS |
| `GRADIO_SERVER_NAME` | `0.0.0.0` | bind for RunPod proxy |
| `GRADIO_SERVER_PORT` | `7862` | matches `WAN2GP_PORT` |
| `GRADIO_ROOT_PATH` | `/` | behind-proxy hardening |
| `GRADIO_ALLOW_FLAGGING` | `never` | UI noise |
| `GRADIO_SHARE` | `False` | no ngrok tunnel |
| `GRADIO_USE_CDN` | `False` | offline assets |
| `GRADIO_NUM_WORKERS` | `1` | low mem |
| `GRADIO_CONCURRENCY_COUNT` | `1` | low mem |
| `UV_THREADPOOL_SIZE` | `8` | uvicorn threadpool |
| `MMGP_RESERVED_RAM_GB` | `10` | RAM headroom for mmgp offload |
| `OMP_NUM_THREADS` | `$(nproc)` | CPU threads |
| `WANGP_FFMPEG_VIDEO` | `-c:v h264_nvenc -preset p1 -rc vbr -cq 22 -pix_fmt yuv420p …` | NVENC encode (RunPod has driver) |
| `WANGP_FFMPEG_AUDIO` | `-c:a aac -b:a 128k` | audio encode |
| `PYTHONUNBUFFERED` | `1` | live logs |
| `TORCH_ALLOW_TF32_CUBLAS`/`CUDNN` | `1` | speed |

**Not adopted from ProbeAI:**
- **Pinning `gradio==4.44.1`** — no; keep Wan2GP's `requirements.txt` gradio
  (v12.34 needs a newer one). Overriding risks blank-UI regressions the other way.
- **Pre-baking LoRAs** — not needed (Wan 2.1 I2V 14B only). Provided as optional
  env-gated prefetch instead.
- **`WAN2GP_USERNAME/PASSWORD` basic auth** — ProbeAI claims it but it isn't wired
  in their `start.sh`; Wan2GP has no native basic-auth flag. Skipped (RunPod proxy
  URL is the de-facto gate). Can revisit if security needed.

---

## 5. `runpod/restart.sh` (new)

`pkill -f "wgp.py" || true; sleep 1; exec /opt/start.sh` — restart WanGP without
restarting the pod (keeps the volume + queue).

---

## 6. `runpod/template.json` (update — already API-body format)

- `imageName`: `ghcr.io/<user>/wan2gp:<tag>` (immutable tag recommended)
- `category`: `NVIDIA`, `isServerless`: false, `isPublic`: **true** (public template)
- `containerDiskInGb`: 40, `volumeInGb`: 200, `volumeMountPath`: `/workspace`
- `ports`: `["7862/http", "22/tcp"]` — Gradio UI + SSH (for rsync-over-SSH & pod admin).
  RunPod assigns a public IP + external port for `22/tcp`; read it from Connect →
  Direct TCP Ports. To force external==internal port, use a number > 70000 instead
  of 22 (symmetrical mapping).
- `env`: the §4 vars + `WAN2GP_PORT=7862` + optional `PREFETCH_MODEL=0` +
  `PREFETCH_MODEL_URL=<int8 ckpt url>` + `WAN2GP_COMMIT` (info only) +
  optional `SSH_PUBLIC_KEY` (your pub key, if you don't rely on RunPod's auto-injection)
- `readme`: short markdown describing the durable queue + Wan 2.1 I2V 14B target +
  rsync-over-SSH usage
- No `dockerStartCmd` — image `ENTRYPOINT` (tini) + `CMD` (start.sh) handle startup

### rsync usage (default-on, via the exposed `22/tcp`)

```bash
# upload into the pod's persistent volume
rsync -avzP -e "ssh -p <ext-port> -i <key>" ./ckpts/ root@<pod-public-ip>:/workspace/ckpts/
# download outputs back
rsync -avzP -e "ssh -p <ext-port> -i <key>" root@<pod-public-ip>:/workspace/outputs/ ./outputs/
```
`<ext-port>` and `<pod-public-ip>` come from the pod's Connect → Direct TCP Ports.

> Alternative (not used): an rsync **daemon** on `873/tcp` would expose a public,
> unencrypted, open-by-default share — worse than SSH. Avoid unless you also add
> `auth users` + secrets.

---

## 7. Durable-queue preservation checklist

- [x] `wgp.py` durable-queue changes are in the fork → baked into the image at the
      pinned commit (`WAN2GP_COMMIT=3646c7f`).
- [x] `tini -g` + `gosu` wired (`Dockerfile` ENTRYPOINT, `start.sh` launch) so
      SIGTERM reaches `wgp.py` → `_graceful_shutdown` flushes `queue.zip`.
      *(verify on a pod: `kill -TERM 1` → `/workspace/queue.zip` present + valid)*
- [x] `--config /workspace` → `queue.zip` at `/workspace/queue.zip` (volume).
- [x] Autoload on fresh session wired (`delete_autoqueue_file=False` in `wgp.py`).
      *(verify: pod stop/start → new browser session autoloads)*
- [x] `ckpts` symlink (`start.sh`) → Wan 2.1 I2V 14B weights persist on volume.
- [x] rsync-over-SSH via `22/tcp` (`openssh-server` + `sshd` in `start.sh`).

---

## 8. Files to create/modify

| File | Action |
|---|---|
| `runpod/Dockerfile` | **Rewrite** — two-stage, baked pinned commit, tini/gosu/aria2/jq, env, ENTRYPOINT tini -g, CMD start.sh |
| `runpod/start.sh` | **Rewrite** — gosu, chown, ckpts symlink, config seed, swap, env, optional prefetch, readiness probe, log tail |
| `runpod/restart.sh` | **New** — pkill + restart |
| `runpod/prefetch.sh` | **New (optional)** — env-gated `aria2c`/`curl` of the int8 ckpt to `/workspace/ckpts` |
| `runpod/template.json` | **Update** — env vars, port 7862, readme, image tag |
| `runpod/README.md` | **Update** — new build steps, hardening table, layout, verification |
| `runpod/PUBLISH.md` | **Minor** — note hardening env / port 7862 |

(`wgp.py`, `QUEUE_PERSISTENCE_PLAN.md` already done — unchanged here.)

---

## 9. Decisions (locked)

1. **GPU target / CUDA arch**: `CUDA_ARCHITECTURES="8.0;8.6;8.9;9.0;12.0"` on
   the existing CUDA 12.8.1 base — covers every RunPod NVIDIA GPU with SM >= 8.0
   (A100/A30, A40/A5000/A6000/3090, 4090/L4/L40/Ada-pros, H100/H200,
   5090/B200/Blackwell). V100 (sm 7.0) runs via fallback. Verify the build
   compiles; if 12.0 (Blackwell) fails with the pinned SageAttention, drop to
   `"8.0;8.6;8.9;9.0"`.
2. **Prefetch the int8 transformer on first boot**: **No** — rely on Wan2GP's
   built-in lazy download; the `ckpts` symlink to `/workspace/ckpts` makes the
   one-time download persist across pod restarts.
3. **Registry**: `ghcr.io` (`ghcr.io/<user>/wan2gp:v1`, immutable tag).
4. **Template visibility**: **Public** (`isPublic: true`).
5. **NVENC**: OK — `WANGP_FFMPEG_VIDEO` defaults to `h264_nvenc ...` (RunPod hosts
   have the driver; fall back to libx264 if a future image's ffmpeg lacks nvenc).

---

## 10. Verification (after implementation)

1. Build stage-1 (`wan2gp-deps`) for the chosen CUDA arch; build stage-2
   (`wan2gp-runpod`); push.
2. Deploy pod from `template.json` (UI or `POST /v2/templates`).
3. First boot: log shows `chown`, swap `swapon`, `✅ Wan2GP UI READY on port 7862`.
4. Open `7862/http` → Gradio UI loads.
5. Generate one Wan 2.1 I2V 14B job → model downloads once to `/workspace/ckpts`
   (verify via `ls /workspace/ckpts`); output appears in `/workspace/outputs`.
6. **Durable-queue test**: enqueue 3 jobs, `kill -TERM <pid>` (or RunPod Stop) →
   `/workspace/queue.zip` exists with 3 pending tasks (`unzip -l`).
7. Start pod again → queue autoloads in a fresh browser session; completed tasks
   not re-run.
8. `restart.sh` test: `pkill wgp.py` + start → UI returns without pod restart;
   queue intact.
9. `free -h` shows 16 GB swap; `env` in container shows the §4 vars.