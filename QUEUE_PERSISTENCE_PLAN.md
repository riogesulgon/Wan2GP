# Queue Persistence — 80/20 Plan

> **Status: implemented** in `Wan2GP/wgp.py` (steps 1–6 applied; `python -c
> "import ast; ast.parse(open('wgp.py').read())"` passes). Run Step 7
> (end-to-end verification) before publishing.
>
> Fork change based on upstream `deepbeepmeep/Wan2GP` v12.34.
> Goal: keep the generation queue across client disconnects, process crashes,
> and RunPod pod stops on **Linux**, and restore it in a fresh browser session.

## Problem

On Linux, when a client disconnects (or the pod is stopped / OOM-killed), the
generation queue is lost. Root causes, confirmed in the code:

- The upstream "remote connection fix" (`shared/asyncio_utils.py:
  silence_proactor_connection_reset` + `WindowsSelectorEventLoopPolicy`) is
  **Windows-only** (`if os.name != "nt": return`). On Linux it does nothing.
- The queue lives in per-session Gradio state `state["gen"]["queue"]`
  (`get_gen_info`, `wgp.py:4066`), mirrored to a global `global_queue_ref`
  (`wgp.py:141`) used only for the autosave dump.
- `autosave_queue()` (`wgp.py:2220`) is called in **only three places**, none of
  which fire on disconnect or crash:
  - `quit_application()` (`wgp.py:2195`) — user clicks "Save & Quit"
  - `restart_application()` (`wgp.py:2202`) — user clicks "Restart"
  - `atexit.register(autosave_queue)` (`wgp.py:13450`) — clean process exit only
  - `atexit` does **not** run on SIGTERM/SIGKILL (RunPod pod stop, OOM-kill).
- The existing `save_queue_if_crash` / `error_queue.zip` path (`wgp.py:8230`)
  only fires on an in-worker **exception**, writes `error_queue.zip`, and is
  **not** autoloaded (autoload reads `queue.zip`). It does not cover
  disconnect/SIGTERM.

Result: a disconnect or hard kill produces no `queue.zip`, so the next session
autoloads nothing and the queue is gone.

## Goal

A minimal, low-risk change so that:

- The pending queue survives a client disconnect, a process crash, a
  SIGTERM/SIGKILL, or a RunPod pod stop.
- Opening the app in a fresh browser session restores the still-pending queue
  (tasks + media) automatically.

## Why 80/20 (not SQLite)

SQLite (metadata-only, media on disk) is a fine design for a larger durable
queue store, but it adds schema versioning, media GC, path reconciliation, and a
new concurrency model. The queue here only ever holds pending + in-progress
tasks (completed tasks are removed on finish, `wgp.py:8207`), so rewriting a
small `queue.zip` on every mutation is cheap. This fix reuses the existing zip
save/load path and the existing autoload-on-`main.load` wiring, and keeps
`queue.zip` as both the durability store and the export artifact.

## Design facts (already verified in code)

- **Completed tasks are removed from the queue as they finish** —
  `wgp.py:8207`: `queue[:] = [item for item in queue if item['id'] != task_id]`.
  So a persistent `queue.zip` only ever contains still-pending work; autoload
  never re-injects already-completed generations.
- **Autoload fires for any browser session** (including a fresh one) via
  `main.load` (`wgp.py:12791`). A fresh session has an empty `original_queue`
  (`gen.get("queue", [])` == `[]`), so the autoload branch (`wgp.py:2040`,
  `elif evt.target == None`) runs and reads `AUTOSAVE_PATH`
  (`config_dir/queue.zip`, set at `wgp.py:2478`).
- **Media restores correctly** — `_parse_queue_zip` (`wgp.py:1895`) extracts the
  zip to a temp dir, then `_load_task_attachments` (`wgp.py:1718`) copies each
  attachment into the **persistent** `save_path_base/_loaded_queue_cache` dir,
  loading images as `PIL.Image` and keeping video/audio as paths. So a fresh
  session gets tasks + media.
- **Autoload currently deletes `queue.zip` after loading** —
  `wgp.py:2046` sets `delete_autoqueue_file = True`, and the `finally` block at
  `wgp.py:2144` does `os.remove(filename)`. This one-shot "resume after graceful
  shutdown" design must change for durability.

## Mutation map (verified) — where persistence belongs

The queue mutates through two paths:

- **`update_queue_data(queue)`** (`wgp.py:2380`) → calls
  `update_global_queue_ref(queue)` then returns the queue HTML. This is the
  return value of: enqueue (`:513,619,692`), reorder (`:1530,1537,1546,1550`),
  remove (`:1560`), clear (`:2190`), and load (`:2122`). → **one funnel**.
- **Direct `update_global_queue_ref(queue)`** (bypass the HTML funnel): task
  completion (`:8208`) and error-clear (`:8241`).
- **Abort** (`:4224,4228,4231`) returns raw `gr.HTML(generate_queue_html(queue))`
  and syncs **neither** `global_queue_ref` nor anything — a pre-existing
  staleness gap.

So persistence is added in 4 spots: the `update_queue_data` funnel, completion
`:8208`, error-clear `:8241`, and the 3 abort returns.

## Caveats / non-goals

- The queue is **per-session** (`state["gen"]["queue"]`), not server-wide.
  If two browser sessions autoload the same `queue.zip` simultaneously (after
  this change keeps the file), both get a copy of the pending tasks and both
  could process them → duplicate generations. For a single-user RunPod box
  (one browser at a time) this is a non-issue. Multi-client concurrency is a
  separate problem this plan does not address.
- RunPod ephemeral filesystems: place `queue.zip` on a persistent volume
  (`/workspace`/netboot), same as today's `config_dir`. The plan does not
  change where the file lives.
- `SIGKILL`/OOM-kill cannot be caught; the per-mutation autosave (Steps 2–4)
  is what protects against them. The SIGTERM handler (Step 6) only helps for
  graceful pod stop.

## Implementation — ordered, executable steps

Each step lists the exact location, the edit, and a check to run here before
moving on.

---

### Step 1 — Atomic write in `_save_queue_to_zip` (`wgp.py:1576`)

**Why:** a crash mid-write must not leave a truncated `queue.zip` that autoload
then consumes.

**Edit:** in the final zip-building `try`, branch on whether `output` is a
filename vs a `BytesIO`:

- filename → write to `<output>.tmp`, then `os.replace(<output>.tmp, output)`
  (atomic on the same filesystem)
- BytesIO → unchanged (browser download path, atomicity irrelevant)

Sketch (final `try`):

```python
if isinstance(output, (str, os.PathLike)):
    tmp = f"{output}.tmp"
    with zipfile.ZipFile(tmp, 'w', zipfile.ZIP_DEFLATED) as zf:
        zf.write(manifest_path, arcname="queue.json")
        for saved_file_rel_path in file_paths_in_zip.values():
            saved_file_abs_path = os.path.join(tmpdir, saved_file_rel_path)
            if os.path.exists(saved_file_abs_path):
                zf.write(saved_file_abs_path, arcname=saved_file_rel_path)
    os.replace(tmp, output)         # atomic rename
else:
    with zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED) as zf:
        zf.write(manifest_path, arcname="queue.json")
        for saved_file_rel_path in file_paths_in_zip.values():
            saved_file_abs_path = os.path.join(tmpdir, saved_file_rel_path)
            if os.path.exists(saved_file_abs_path):
                zf.write(saved_file_abs_path, arcname=saved_file_rel_path)
```

**Check:** `python -c "import ast; ast.parse(open('wgp.py').read())"` parses;
`_save_queue_to_zip([...], "/tmp/q.zip")` leaves no `q.zip.tmp` and
`unzip -t /tmp/q.zip` is OK.

---

### Step 2 — Add `autosave_queue()` to the `update_queue_data` funnel (`wgp.py:2380`)

**Why:** covers enqueue, reorder, remove, clear, and load in one edit.

**Edit:**

```python
def update_queue_data(queue):
    update_global_queue_ref(queue)
    autosave_queue(quiet=True)             # persist after every UI-driven mutation
    html_content = generate_queue_html(queue)
    return gr.HTML(value=html_content)
```

`autosave_queue()` now takes a `quiet=False` flag (see Step 2b); per-mutation
callers pass `quiet=True` so logs aren't spammed on every enqueue/remove/complete.
It no-ops on empty `global_queue_ref`, so clear (which passes `[]` and already
deletes the file at `:2175`) won't recreate it.

**Check:** enqueue a task → `ls config_dir/queue.zip` exists; remove it → file
reflects the shorter queue; logs are not spammed.

### Step 2b — Add a `quiet` flag to `autosave_queue()` (`wgp.py:2232`)

**Why:** `autosave_queue()` is now called on every mutation; its two `print`
lines would flood the logs. Shutdown callers keep the default verbose behavior.

**Edit:** signature `def autosave_queue(quiet=False):`; guard the three
success/empty prints with `if not quiet:`. Error prints stay unconditional.
Shutdown paths (`quit_application`, `restart_application`,
`atexit.register(autosave_queue)`, the SIGTERM handler) call `autosave_queue()`
(default verbose); the four per-mutation sites pass `quiet=True`.

---

### Step 3 — Add `autosave_queue(quiet=True)` at completion (`wgp.py:8208`) and error-clear (`wgp.py:8241`)

**Why:** these bypass the HTML funnel (direct `update_global_queue_ref`).

**Edit** at `:8207-8208`:

```python
with lock:
    queue[:] = [item for item in queue if item['id'] != task_id]
update_global_queue_ref(queue)
autosave_queue(quiet=True)                # persist queue.zip after a task completes
```

At `:8241` (after the `error_queue.zip` block, right after
`update_global_queue_ref(queue)`):

```python
update_global_queue_ref(queue)
autosave_queue(quiet=True)                # keep queue.zip in sync after a worker error/crash too
```

**Check:** let one task finish → `queue.zip` no longer contains it.

---

### Step 4 — Persist on abort (`wgp.py:4226+`) and fix two `lock` re-entrancy deadlocks

**Why:** abort mutates the queue but syncs nothing (closes the staleness gap too).
But `update_global_queue_ref` re-acquires `lock` (a non-reentrant
`threading.Lock`, `wgp.py:173`), so it **cannot** be called from inside a
`with lock:` block. Two places did exactly that:

- `move_task` returned `update_queue_data(queue)` from inside `with lock:` on
  the invalid-index path (`wgp.py:1537`) — a **pre-existing** latent deadlock.
- `abort_generation`'s three returns were inside `with lock:`.

**Edit 4a — `move_task` (`wgp.py:1532`):** drop the early `return` from inside
the lock; guard the mutation instead (behavior-preserving — invalid index now
just skips the move and returns the unchanged queue):

```python
with lock:
    old_idx += 1
    new_idx += 1
    if 0 < old_idx < len(queue):
        item_to_move = queue.pop(old_idx)
        if old_idx < new_idx:
            new_idx -= 1
        clamped_new_idx = max(1, min(new_idx, len(queue)))
        queue.insert(clamped_new_idx, item_to_move)
return update_queue_data(queue)
```

**Edit 4b — `abort_generation` (`wgp.py:4226`):** set an `aborted` flag inside
the lock (cases A/C/D), then persist + return **after** the `with lock:` block
so neither `update_global_queue_ref` re-acquires the lock nor file I/O happens
under it:

```python
def abort_generation(state, client_id="", notify = True):
    gen = get_gen_info(state)
    queue = gen.get("queue", [])
    aborted = False
    with lock:
        if len(queue):
            if len(client_id):
                for i, task in enumerate(queue):
                    queue_client_id = task["params"].get("client_id","")
                    if queue_client_id == client_id:
                        if i == 0:
                            if "in_progress" not in gen:
                                del queue[0]
                                if "prompt_no" in gen: gen["prompt_no"] += 1
                                aborted = True
                            break
                        del queue[i]
                        if "prompt_no" in gen: gen["prompt_no"] += 1
                        aborted = True
                        break
            elif "in_progress" not in gen:
                del queue[0]
                gen["prompt_no"] += 1
                aborted = True

    if aborted:
        update_global_queue_ref(queue)
        autosave_queue(quiet=True)
        return gr.update(), gr.HTML(value=generate_queue_html(queue))

    gen["resume"] = True
    ...
```

Control flow is preserved exactly: cases A/C/D (delete + return HTML) set
`aborted=True`; case B (head in progress → `break`), empty queue, and
no-matching-task leave `aborted=False` and fall through to `gen["resume"] = True`.

**Check:** abort a queued task → `queue.zip` reflects the removal; no deadlock.

---

### Step 5 — Stop deleting `queue.zip` on autoload (`wgp.py:2046`)

**Why:** keep the file as the persistent safety net so a resuming (or later)
session is still covered.

**Edit:**

```python
if Path(AUTOSAVE_PATH).is_file():
    autoload_path = AUTOSAVE_PATH
    delete_autoqueue_file = False         # ← was True
```

Deletion stays only for explicit Clear Queue (`:2175-2180`, `:2133`).

**Check:** open a fresh session → queue autoloads → `queue.zip` still on disk.

---

### Step 6 — SIGTERM / SIGHUP handler so shutdown flushes the queue (in `main()`, ~`wgp.py:13535`)

**Why:** `atexit` doesn't run on SIGTERM/SIGKILL; RunPod sends SIGTERM on pod
stop. SIGKILL stays uncovered by design — Steps 2–4 cover it.

**Edit:** install a handler before `demo.launch(...)`, after `clear_startup_lock()`:

```python
import signal
def _graceful_shutdown(signum, frame):
    print(f"[shutdown] received signal {signum}; flushing queue...")
    try:
        autosave_queue()              # verbose — shutdown path
    except Exception as e:
        print(f"[shutdown] autosave failed: {e}")
    try:
        clear_startup_lock()
    except Exception:
        pass
    signal.signal(signum, signal.SIG_DFL)
    os.kill(os.getpid(), signum)
signal.signal(signal.SIGTERM, _graceful_shutdown)
if hasattr(signal, "SIGHUP"):
    signal.signal(signal.SIGHUP, _graceful_shutdown)
```

**Check:** `kill -TERM <pid>` mid-queue → process exits → `queue.zip` present
and valid.

---

### Step 7 — End-to-end verification

1. **SIGTERM path:** enqueue 3 tasks → `kill -TERM <pid>` → confirm
   `config_dir/queue.zip` has 3 pending tasks (`unzip -l`).
2. **Fresh-session autoload:** relaunch, open a new browser session → 3 tasks
   + media autoload without action; `queue.zip` still on disk afterward.
3. **SIGKILL path:** enqueue, `kill -9 <pid>` → `queue.zip` reflects the last
   completed-mutation snapshot.
4. **Completed-task pruning:** enqueue 1, let it finish → `queue.zip`
   empty/absent (no finished work re-injected on next open).
5. **Save Queue download still works:** click "Save Queue" → `queue.zip`
   downloads (BytesIO path untouched by Step 1).
6. **Parse check:** `python -c "import ast; ast.parse(open('wgp.py').read())"`
   after every edit.

---

## Notes for publishing the fork

- These changes are additive and confined to `wgp.py` (plus the existing
  `shared/asyncio_utils.py`, which is untouched and stays Windows-only). No new
  dependencies, no schema, no DB.
- `queue.zip` remains both the durability store and the user-facing "Save
  Queue" download artifact — the load path is unchanged.
- Suggested changelog entry for the fork's README (see README update):
  "Generation queue now survives client disconnects, process crashes, and pod
  stops on Linux, and auto-restores in a new browser session."