# Runbook — from fork to a running hardened RunPod pod

End-to-end walkthrough. The fork (`https://github.com/riogesulgon/Wan2GP`) is
already published with the durable-queue code + `runpod/` template. This covers
the remaining operational steps: build the image, publish the RunPod template,
deploy, and verify the durable queue.

> **Build-host requirements:** the image is a CUDA 12.8 devel base + torch +
> SageAttention compiled for up to 5 SM architectures (~15–20 GB). That needs a
> host with Docker (or buildah) + ~80 GB free disk + ~16 GB RAM, and **no GPU**
> (the Dockerfile patches SageAttention to use `CUDA_ARCH_LIST` without GPU
> detection). GitHub Actions standard runners and a tight dev box can't fit it.
> See Phase B for the two working options (plain VM with Docker, or buildah on a
> RunPod pod) — Docker-in-Docker is **not** one of them (RunPod pods aren't
> privileged by default).

---

## Phase A — one-time GitHub / ghcr setup (once)

**A1. ✓ Fork is live.** `https://github.com/riogesulgon/Wan2GP` (durable-queue `wgp.py` + `runpod/` template).

**A2. Create a GitHub PAT** (to `docker push` to ghcr.io):
- https://github.com/settings/tokens → **Generate new token (classic)**.
- Scopes: **`write:packages`** + **`read:packages`**.
- Copy it; treat as a secret. You make the package public in Phase C.

---

## Phase B — build the image (no GPU needed)

The image is a CUDA 12.8 devel base + torch + SageAttention compiled for up to
5 SM architectures (~15–20 GB). That needs a build host with Docker (or buildah)
+ ~80 GB free disk + ~16 GB RAM, and **no GPU** (the Dockerfile patches
SageAttention to use `CUDA_ARCH_LIST` without GPU detection). GitHub Actions
standard runners and a tight dev box can't fit it.

> **Don't chase Docker-in-Docker on RunPod.** RunPod doesn't surface a DinD
template, and standard on-demand GPU pods aren't privileged by default, so the
Docker daemon can't run nested. Use one of the two options below instead.

### Option 1 — a plain cloud VM with Docker (recommended, simplest)

A normal VM isn't a container, so Docker runs natively and `runpod/build.sh`
works as-is — no DinD, no privileged, no rootless quirks. For a one-time ~1 h
build this is the path of least resistance.

1. Spin up **Ubuntu 22.04/24.04** with **≥ 80 GB disk + ≥ 16 GB RAM** (no GPU).
   Cheapest one-time options: Hetzner Cloud CX41 (~€0.05/h), DigitalOcean,
   Contabo, or any box you already have. Hourly billing = pennies for one build.
2. Install Docker: `curl -fsSL https://get.docker.com | sh`
3. Log in to ghcr and build:
   ```bash
   echo "<PASTE_YOUR_PAT>" | docker login ghcr.io -u riogesulgon --password-stdin
   git clone https://github.com/riogesulgon/Wan2GP && cd Wan2gp
   CUDA_ARCHITECTURES="8.0;8.6;8.9;9.0;12.0" WAN2GP_COMMIT=main \
     IMAGE=ghcr.io/riogesulgon/wan2gp:v1 PUSH=1 bash runpod/build.sh
   ```
4. Tear the VM down. The image is on ghcr; RunPod pulls it at deploy time.

### Option 2 — `buildah` on a RunPod pod (no privileged, no DinD)

Stay inside RunPod: `buildah` builds images without a daemon and without
privileges. Deploy any RunPod pod (PyTorch template is fine), **container disk
200 GB** (rootless buildah's `vfs` driver duplicates layers), cheapest GPU (idle
during build). Then:

```bash
apt-get update && apt-get install -y buildah git
echo "<PASTE_YOUR_PAT>" | buildah login --username riogesulgon --password-stdin ghcr.io

# stage 1 (deps) — MAX_JOBS=4 caps SageAttention parallelism to avoid OOM
buildah bud --isolation chroot \
  --build-arg CUDA_ARCHITECTURES="8.0;8.6;8.9;9.0;12.0" --build-arg MAX_JOBS=4 \
  -t wan2gp-deps -f Dockerfile .

# stage 2 (hardened RunPod image) — finds wan2gp-deps in buildah's local storage
buildah bud --isolation chroot --build-arg WAN2GP_COMMIT=main \
  -t ghcr.io/riogesulgon/wan2gp:v1 -f runpod/Dockerfile .

buildah push ghcr.io/riogesulgon/wan2gp:v1
```

- `--isolation chroot` avoids needing a container runtime.
- If `buildah info` shows `fuse-overlayfs` as the storage driver, 100 GB disk is
  enough; otherwise `vfs` needs the 200 GB above.
- This bypasses `runpod/build.sh` (which calls `docker build`); run the two
  `buildah bud` commands by hand as shown.

### Landmarks + troubleshooting (both options)

- Stage 1 pulls `nvidia/cuda:12.8.1-cudnn-devel-ubuntu22.04`, installs
  torch/mmgp, compiles SageAttention (slow, ~30–60 min). Stage 2 clones the fork
  at the cloned commit, adds hardening, tags `ghcr.io/riogesulgon/wan2gp:v1`, pushes.
  Final lines: `The push refers to repository [ghcr.io/riogesulgon/wan2gp]` + digest.
- If the SageAttention compile **OOMs** (`MAX_JOBS=8` default), rerun with
  `CUDA_ARCHITECTURES="8.0;8.6;8.9;9.0"` (drop Blackwell `12.0`), or cap
  parallelism with `MAX_JOBS=4`.

**B4. Verify on ghcr:** https://github.com/riogesulgon?tab=packages → a `wan2gp`
package with the `v1` tag. You can now stop/delete the build pod.

---

## Phase C — make the ghcr package public

https://github.com/riogesulgon?tab=packages → **wan2gp** → **Package settings** →
**Danger Zone → Change visibility → Public**. Lets the public RunPod template
pull `ghcr.io/riogesulgon/wan2gp:v1` without auth.

---

## Phase D — publish the RunPod template

**D1. Get your RunPod API key:** console → **Settings → API** → copy.

**D2. Publish via the API** (`runpod/template.json` is already in the API body format):
```bash
curl -X POST https://api.runpod.io/v2/templates \
  -H "Authorization: Bearer <YOUR_RUNPOD_API_KEY>" \
  -H "Content-Type: application/json" \
  --data @runpod/template.json
```
- **Landmark:** JSON response with `"id": "xxxxx"`. Save it.
- (UI alternative: **Templates → New Template**, fill per `runpod/PUBLISH.md` —
  image `ghcr.io/riogesulgon/wan2gp:v1`, `/workspace` volume 200 GB, HTTP `7862`,
  TCP `22`, env vars, **Public**.)

**D3. Confirm:** console → **Templates** → "Wan2GP (riogesulgon fork) — durable queue".

---

## Phase E — deploy + connect

**E1. Deploy a pod from the template:** **Templates → Wan2GP (riogesulgon fork) →
Deploy** → pick an **NVIDIA GPU** matching what you built for (RTX 4090/5090/
A100/A40/…; V100 won't get SageAttention), **Disk size 200 GB** (the persistent
`/workspace` volume), start.

**E2. Watch boot logs.** Landmarks in order:
- `sshd started (port 22, key-only root login)`
- `Seeded /workspace/wgp_config.json (save_path=/workspace/outputs)`
- `🚀 Starting Wan2GP on :7862 (--config /workspace for durable queue)`
- `✅ Wan2GP UI READY on port 7862`

**E3. Open the Gradio UI:** **Connect → HTTP [7862]** → proxy URL.

**E4. (Optional) SSH / rsync:** **Connect → Direct TCP Ports** → note external
port + public IP for `22`. Add your SSH pub key via the pod **Env**
(`SSH_PUBLIC_KEY=ssh-ed25519 AAAA…`) and restart, or rely on RunPod's
account-key auto-injection. Then:
```bash
rsync -avzP -e "ssh -p <ext-port> -i <key>" ./ckpts/ root@<pod-ip>:/workspace/ckpts/
```

---

## Phase F — verify the durable queue (the payoff)

**F1. First generation (downloads model once):** in Gradio select
**Wan 2.1 I2V 14B**, queue 3 short jobs, Generate. First run downloads the
~15 GB int8 transformer to `/workspace/ckpts` (one-time; persists on the volume).
Subsequent runs are fast.

**F2. SIGTERM test:** with 3 jobs still **pending**, **Stop the pod** (RunPod
sends SIGTERM). `tini -g` + `gosu` forwards it to `wgp.py` → `_graceful_shutdown`
flushes `queue.zip`.
```bash
ssh -p <ext-port> root@<pod-ip> 'ls -l /workspace/queue.zip && unzip -l /workspace/queue.zip'
# expect: queue.zip present with 3 pending tasks in queue.json
```

**F3. Autoload test:** **Start the pod again**, open the proxy URL in a
**fresh/incognito browser session** (new Gradio session). Landmark: the 3
pending tasks + their media **autoload automatically** into the empty queue —
no action needed. Completed tasks are **not** re-run (pruned on completion). ✓

**F4. SIGKILL edge (optional):** `kill -9 1` (or OOM-kill) → `queue.zip`
reflects the last completed-mutation snapshot (one mutation behind at worst),
since per-mutation autosave covers uncatchable kills.

---

## Phase G — updating the fork / image later

1. Commit + push to the fork: `git push fork main`.
2. On the build pod, rebuild with the new commit and a new immutable tag:
   ```bash
   WAN2GP_COMMIT=<new-sha> IMAGE=ghcr.io/riogesulgon/wan2gp:v2 PUSH=1 bash runpod/build.sh
   ```
   (the `/workspace` volume + queue persist across image bumps.)
3. Update `runpod/template.json` `imageName` → `:v2` and `WAN2GP_COMMIT`, re-publish
   (or edit the template in the UI).
4. Pull upstream Wan2GP updates anytime: `git fetch origin && git merge origin/main`
   (`origin` is still `deepbeepmeep/Wan2GP`), resolve, push to fork, rebuild.

---

## Quick reference

| Doc | For |
| --- | --- |
| `QUEUE_PERSISTENCE_PLAN.md` | durable-queue code changes (done) |
| `runpod/PLAN.md` | hardening design + locked decisions |
| `runpod/README.md` | template usage + persistence layout + verification |
| `runpod/PUBLISH.md` | template publishing (UI + API field reference) |
| `runpod/build.sh` | two-stage build + push command |

First milestone to aim at: **Phase B3** — get `ghcr.io/riogesulgon/wan2gp:v1`
pushed. Everything after that is console clicks.