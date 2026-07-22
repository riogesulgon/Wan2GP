# Publishing a RunPod template

A RunPod **Pod template** packages a container image + configuration for reuse
and sharing. "Publishing" = setting its **visibility**: **Private** (only
you/your team) or **Public** (appears in the Explore section for all RunPod
users). The template itself just references an image tag and a config — it does
not store the image. Use an immutable tag (e.g. `:v1`) rather than `:latest` if
you want reproducible pods.

## Prerequisites

1. Build and push the image to a registry RunPod can pull (ghcr.io, Docker Hub,
   etc.). If the registry is private, add **Registry credentials** in RunPod so
   the pod can pull the image.
2. Replace all `REPLACE` placeholders in `template.json` / `start.sh` /
   `Dockerfile` (fork repo URL + image path).

## Option A — Web console (easiest)

1. Go to **console.runpod.io → Templates → New Template**.
2. Fill the form:

   | UI field | Value |
   | --- | --- |
   | Template name | `Wan2GP (riogesulgon fork) — durable queue` |
   | Container image | `ghcr.io/riogesulgon/wan2gp:v1` |
   | Compute type | NVIDIA |
   | Container disk | 40 GB |
   | Volume disk size | 200 GB (holds models + outputs + queue) |
   | Volume mount path | `/workspace` |
   | Expose HTTP port(s) | `7862` |
   | Expose TCP port(s) | `22` (SSH / rsync-over-SSH) |
   | Start command | *(leave blank — the image CMD is `/opt/start.sh`)* |
   | Entrypoint | *(leave blank — the image ENTRYPOINT is `tini -g --`)* |
   | Registry credentials | none needed if the ghcr package is **Public**; add ghcr username + PAT if private |
   | Env vars | `WAN2GP_PORT=7862`, `WAN2GP_COMMIT=3646c7f`, `HF_HUB_ENABLE_HF_TRANSFER=1` (optional `SSH_PUBLIC_KEY=ssh-ed25519 AAAA…`) |
   | Visibility | **Private** first → test → flip to **Public** to share |

   > The hardening env (`HF_HOME`, `PYTORCH_CUDA_ALLOC_CONF`, `GRADIO_*`, `MMGP_RESERVED_RAM_GB`, NVENC `WANGP_FFMPEG_*`, …) is already **baked into the image** via the Dockerfile `ENV` block — do **not** re-add them in the template. GPU type/count are chosen at **deploy** time, not in the template.
3. **Save Template** (private by default).
4. **Deploy a Pod from it** to test before making it Public.
5. To publish publicly: flip **Visibility → Public** in the template's settings
   → it appears in the Explore section for all RunPod users.

## Option B — REST API

```bash
curl -X POST https://api.runpod.io/v2/templates \
  -H "Authorization: Bearer $RUNPOD_API_KEY" \
  -H "Content-Type: application/json" \
  --data @runpod/template.json
```

- Set `"isPublic": true` in `template.json` to publish it to all RunPod users
  (or keep `false` and flip it later in the UI).
- The response returns the template `id`. Other users deploy from it with
  `POST /pods` referencing that id, or via the Explore page if public.

> **Check the endpoint prefix.** RunPod's docs reference `POST /templates`; the
> `/v2` prefix is their standard base. If you get a 404, try without the prefix
> or check your API key's region endpoint.

## API body field reference

`runpod/template.json` is already in the RunPod `POST /templates` body format.
Key fields and their types:

| API field | Type | Notes |
| --- | --- | --- |
| `name` | string (required) | Unique template name. |
| `imageName` | string (required) | Docker image, e.g. `ghcr.io/you/wan2gp:v1`. |
| `category` | enum | `NVIDIA` / `AMD` / `CPU`. |
| `isServerless` | boolean | `false` = Pod template (this one). `true` = Serverless worker (different schema). |
| `isPublic` | boolean | `true` = visible to all RunPod users; `false` = private. |
| `containerDiskInGb` | integer | Ephemeral container disk (wiped on restart). |
| `volumeInGb` | integer | Persistent network volume size. |
| `volumeMountPath` | string | Where the volume mounts, e.g. `/workspace`. |
| `ports` | string[] | e.g. `["7862/http", "22/tcp"]` (or `/tcp`). |
| `env` | object | A `{KEY: value}` map (not an array). |
| `dockerStartCmd` | string[] | Overrides image **CMD**. Omit to use the image's. |
| `dockerEntrypoint` | string[] | Overrides image **ENTRYPOINT**. Omit to use the image's. |
| `containerRegistryAuthId` | string | ID of saved registry credentials (private images). |
| `readme` | string | Markdown shown in the RunPod UI. |

**We omit `dockerStartCmd`/`dockerEntrypoint`** because the image already has
`ENTRYPOINT ["/start.sh"]`, so the container starts correctly on its own.
**GPU count/type are chosen at deploy time**, not in the template.

## After publishing — verify the persistence story

1. Deploy a pod from the template. The fork is **baked into `/opt/Wan2GP`** in
   the image (pinned commit) — boot is instant, no clone at runtime. `/workspace`
   (the network volume) holds `queue.zip`, `wgp_config.json`, `outputs/`,
   `ckpts/` (model weights), and HF/torchinductor caches.
2. Open the `7862/http` port → Gradio UI.
3. Enqueue a few jobs, then **stop the pod** (RunPod sends SIGTERM). `tini -g` +
   `gosu` forward SIGTERM to `wgp.py` → `_graceful_shutdown` flushes `queue.zip`;
   per-mutation autosave also keeps it current.
4. **Start the pod again** → the queue autoloads automatically into the new
   session (tasks + media), without re-running already-completed jobs.

## Caveats

- **GPU ↔ image match**: SageAttention is compiled at build time for the
  `CUDA_ARCHITECTURES` build-arg. Deploy on a GPU matching what you built for,
  or rebuild.
- **Per-session queue**: the queue is per browser session. The durable store
  (`queue.zip`) is shared, so two simultaneous browser sessions against the same
  pod can both autoload the same pending tasks → duplicate generations. Fine
  for single-user use; not for multi-client serving.
- **SIGKILL / OOM-kill** cannot be caught; per-mutation autosave (not the
  SIGTERM handler) covers those — so on-disk `queue.zip` is at worst one
  mutation behind.

## References

- Create template (API): https://docs.runpod.io/api-reference/templates/POST/templates
- Manage Pod templates: https://docs.runpod.io/pods/templates/manage-templates
- Custom template overview: https://docs.runpod.io/pods/templates/overview
- Secrets (for sensitive env values): https://docs.runpod.io/pods/templates/secrets