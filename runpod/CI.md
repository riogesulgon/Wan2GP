# CI — building the RunPod image via GitHub Actions

The workflow at `.github/workflows/build.yml` builds the hardened two-stage
RunPod image and pushes it to `ghcr.io/<owner>/wan2gp:<tag>`.

## Why a self-hosted runner

GitHub-hosted **standard** runners have ~14 GB free disk and ~16 GB RAM — too
small for this build (`nvidia/cuda:12.8.1-cudnn-devel-ubuntu22.04` base + torch
cu128 + SageAttention compiled for up to 5 SM architectures ≈ 15–20 GB + build
cache). GitHub-hosted **larger** runners require a paid Team/Enterprise plan and
aren't available for a personal public repo.

So the workflow targets a **self-hosted runner labelled `cuda-builder`**. A
RunPod pod is the natural host: large container disk, plenty of RAM, and the
build needs **no GPU** (the Dockerfile patches SageAttention to compile for
`CUDA_ARCH_LIST` without GPU detection).

## Set up a `cuda-builder` self-hosted runner on RunPod

1. **Deploy a RunPod pod** with a large container disk (≥ 80 GB; 200 GB is safe)
   and ≥ 16 GB RAM. GPU is optional (a cheap CPU pod works for building). Use a
   base image that has Docker available, or install Docker:

   ```bash
   # inside the pod (Ubuntu example)
   apt-get update && apt-get install -y docker.io
   systemctl start docker 2>/dev/null || dockerd > /tmp/dockerd.log 2>&1 &
   # if dockerd needs privileges, run the pod with Docker-in-Docker / privileged enabled
   ```

   > RunPod pods are containers; running `dockerd` inside needs Docker-in-Docker.
   > Easiest: use a RunPod template that already ships Docker, or enable the
   > pod's privileged/DinD option.

2. **Install the GitHub Actions runner** (GitHub docs: "Adding self-hosted
   runners"). On your fork: `Settings → Actions → Runners → New self-hosted
   runner`, follow the Linux commands. **Add the label `cuda-builder`** when
   configuring (the workflow's `runs-on: [self-hosted, cuda-builder]` targets it).

3. **Run the runner as a service** so it survives: `sudo ./svc.sh install &&
   sudo ./svc.sh start`.

4. **ghcr.io visibility**: after the first push, go to
   `https://github.com/riogesulgon?tab=packages` → the `wan2gp` package →
   **Package settings → Change visibility → Public**, so the public RunPod
   template can pull `ghcr.io/riogesulgon/wan2gp:v1` without auth.

## Triggering a build

- **On tag** (recommended for releases — immutable, reproducible):
  ```bash
  git tag v1
  git push fork v1
  ```
  The workflow builds at the tagged commit and pushes `ghcr.io/riogesulgon/wan2gp:v1`.

- **Manual** (for testing): `Actions → build-runpod-image → Run workflow`,
  set `image_tag` (e.g. `dev`), optionally override `cuda_architectures` and
  `wan2gp_commit`, and toggle `push_latest`.

## Point the RunPod template at the built image

After a successful build, `runpod/template.json` already references
`ghcr.io/riogesulgon/wan2gp:v1`. Publish the template (see `PUBLISH.md`).

## Notes

- **No build cache** in v1: the deps stage (torch + SageAttention) is slow
  (~30–60 min) but only runs when you tag a release or manually dispatch — not
  on every commit. If you release often, add buildx GHA cache
  (`--cache-to type=gha --cache-from type=gha`) to `runpod/build.sh`.
- **OOM during the SageAttention compile**: the upstream `Dockerfile` bakes
  `MAX_JOBS=8`. If the runner OOMs, drop `12.0` (Blackwell) via the workflow
  `cuda_architectures` input, or reduce `MAX_JOBS` in a build-arg (requires
  editing the upstream `Dockerfile` to make `MAX_JOBS` an `ARG`).
- **Runner cleanup**: the build leaves ~15–20 GB of Docker images on the runner.
  `docker system prune -af` between builds if disk is tight.