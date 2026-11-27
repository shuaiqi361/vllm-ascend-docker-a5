# vllm-ascend dev environment — A5 / 950 (950PR, 950DT)

A container in which **your own vllm and vllm-ascend checkouts are live**, so
your serve and benchmark scripts run against the code you are editing.

**The one idea:** your code is never in the image. The image only supplies
dependencies — CANN, torch / torch-npu, triton-ascend, FLA, the A5 extras.
`run_container.sh` bind-mounts your two checkouts at their own absolute host
paths and installs them with `pip install -e`, so

* editing python changes what runs — no rebuild, no reinstall, nothing to copy;
* two people on different forks share one image;
* **any image with those dependencies will do**, including one already on the
  server — which is why you will usually not build anything at all.

---

## First time on a server: five commands

```bash
bash fix_line_endings.sh .
```

```bash
vi a5.env            # the EDIT BLOCK at the top. Nothing else.
```

```bash
./probe_image.sh --list          # what is already here?
```

```bash
./run_container.sh --dry-run     # checks everything, starts nothing
```

```bash
./run_container.sh               # start it and drop into a shell
```

If `--dry-run` says the image is not here, you have two choices — see
[the two routes](#two-routes-try-route-a-first). Everything else it reports is a
path to fix in the EDIT BLOCK, and it reports **every** problem at once rather
than one per run.

---

## The scripts, in the order you meet them

| | what it is for | how often |
|---|---|---|
| `fix_line_endings.sh .` | repair a Windows → Linux copy: CRLF, BOM, exec bits, non‑breaking spaces. Point it at your checkouts too. | once per copy |
| `probe_image.sh` | "what is inside this image, and can I use it as-is?" Starts a throwaway container, prints the facts, gives one verdict. Never pulls. | when picking an image |
| `build_image.sh` | build the dependency image. Needs **only docker** on this host. | rarely, or never |
| `run_container.sh` | start or re-enter a container with your code live. **The daily one.** | daily |
| `manage_containers.sh` | interactive console: list / stop / kill / start / shell / logs / npu-smi / inspect / check. | as needed |

Supporting files:

| | |
|---|---|
| `a5.env` | **every setting.** The EDIT BLOCK at the top is the only part you edit. |
| `a5.env.local.example` | optional per-machine overrides. `cp` it to `a5.env.local` only if you need one; you usually do not, and that copy is never committed. |
| `load_env.sh` | the config loader and the shared helpers. Sourced, never run. |
| `Dockerfile.a5.dev` | route B only: the dependency image. |
| `tools/` | the four container-side scripts: `entrypoint.sh`, `bootstrap_editable.sh`, `ascend_env.sh`, `probe_in_container.sh`. Bind-mounted read-only into every container by default (`MOUNT_TOOLS=1`) — **that is what makes route A work**, and it means an edit here needs only a `--recreate`. A route B image also carries them baked in. |
| [`NOTES.md`](NOTES.md) | why each knob exists, and every trap worth knowing. |

Every script answers `--help` with its own recipes:

```bash
./run_container.sh --help
```

---

## What to edit

All of it is the **EDIT BLOCK at the top of `a5.env`**, marked `# <<< EDIT`.

| setting | how to find the right value |
|---|---|
| `IMAGE` | an image this box already has: `./probe_image.sh --list`, then `./probe_image.sh <ref>` for the verdict |
| `HOST_HOME` | `echo $HOME` — mounted at the same path and used as `HOME` inside |
| `VLLM_DIR` | your vLLM checkout. Only ever edit vllm-ascend? Set `VLLM_FROM=image` and this is ignored |
| `VLLM_ASCEND_DIR` | your vllm-ascend checkout. Also run `git submodule update --init --recursive` — see [Kernels](#kernels) |
| `HOST_DATA` | the disk with model weights: `df -h \| sort -k2 -h \| tail -5` |
| `SOC_VERSION` | `npu-smi info -t board -i 0`, lowercased. 950PR `ascend950pr_9579`, 950DT `ascend950dt_9582` |
| `BASE_IMAGE` | **build only.** Skip it unless you build. Its default is the one vllm-ascend's own `Dockerfile.a5.openEuler` uses; that tag carries a build date and the registry is not reachable everywhere, so expect to change it |

Everything under the EDIT BLOCK has a working default. Override one for a single
run instead of editing it:

```bash
IMAGE=vllm-ascend:vq2a8 SHM_SIZE=200g ./run_container.sh dbg
```

Precedence, highest first:

```
environment  >  --env-file FILE  >  a5.env.local  >  a5.env
```

`a5.env.local` therefore **wins over the EDIT BLOCK**. That is the one way an
edit can appear to do nothing, so `run_container.sh` prints an `overriding:`
line naming any EDIT setting that something else has already set.

Loading first is also the one limit of an override file: nothing `a5.env`
defines exists yet, so `"${HOST_HOME}/code/vllm"` in one is an unbound variable
rather than your home. Write the path in full, or derive it with `$(id -un)`.
`load_env.sh` refuses such a file and says so instead of letting it through.

---

## Two routes. Try route A first.

| | Route A — use an image the server has | Route B — build one |
|---|---|---|
| when | some image here has CANN + torch-npu + a compiler | nothing here has what you need |
| cost | nothing. Container up in seconds | `BASE_KIND=ready`: seconds. `BASE_KIND=cann`: tens of minutes, ~25‑30G |
| how | set `IMAGE` in the EDIT BLOCK | set `BASE_IMAGE`, run `./build_image.sh` |
| image modified? | no. Used exactly as it is | a new image; the base is untouched |
| your code | mounted, editable, live | mounted, editable, live |
| custom kernels | built in your checkout, once | built in your checkout, once |

`probe_image.sh` decides it for you, from facts rather than from a tag name:

```bash
./probe_image.sh --list
```

```bash
./probe_image.sh vllm-ascend:some-tag
```

* **"usable as-is"** → route A. Put that ref in the EDIT BLOCK as `IMAGE`.
* **"NOT usable — missing: …"** → route B, usually
  `BASE_IMAGE=<that ref> BASE_KIND=ready ./build_image.sh`, which adds only
  what it lacks.

Route A is the part that is easy to distrust, so: the bootstrap uninstalls
whatever vllm / vllm-ascend the image carried and installs your checkouts
editable in their place, **inside your container only** — an image is immutable
and every container has its own writable layer. It then re-resolves both and
**refuses to hand you a shell if either still points anywhere but your
checkout**, because the alternative is measuring the image's code and believing
it was yours. What route A does *not* save you is the kernel build.

Details: [NOTES.md — Two routes](NOTES.md#two-routes-to-a-container) and
[Sharing an image](NOTES.md#sharing-an-image-and-never-sharing-a-checkout).

---

## What needs rebuilding, and what does not

**Almost nothing.** This is the part worth internalising.

| you changed | you run |
|---|---|
| python in vllm / vllm-ascend | **nothing.** It is bind-mounted and live. Restart your process. |
| `csrc/` or an AscendC kernel | in the container, incremental, minutes: `docker exec -it NAME bash /opt/vllm-dev/bootstrap_editable.sh --force` |
| `requirements*.txt`, a new pip dep | in the container: `... bootstrap_editable.sh --deps` |
| any path, your fork, `SOC_VERSION`, `IMAGE` | `./run_container.sh <name> --recreate` |
| mounts / devices / memory / shm | `./run_container.sh <name> --recreate` |
| `VLLM_FROM` (checkout ↔ image) | `./run_container.sh <name> --recreate` |
| a script in `tools/` | `./run_container.sh <name> --recreate` (it is mounted). Only an image that baked them in needs `./build_image.sh` |
| `BASE_IMAGE`, CANN, torch_npu, FLA | `./build_image.sh` |
| `UPSTREAM_VLLM_TAG`, `Dockerfile.a5.dev` | `./build_image.sh` |

`--recreate` exists only for what docker fixes at container creation: mounts,
devices, memory, the image, and any `-e` value such as `SOC_VERSION`. Everyday
work needs none of it — leave the container running and ignore it.

### Stopping and starting is free

`pip install -e` writes into the container's own writable layer, and **`docker
stop` does not touch that layer** — only `docker rm` does. Re-entering a
container you stopped yesterday costs nothing: the entrypoint runs, the
bootstrap finds both packages already pointing at your checkouts and the kernel
marker current, prints `Nothing to do`, and you have a shell in under a second.

| what you do | editable installs | custom kernels |
|---|---|---|
| exit your shell (container keeps running) | kept | kept |
| `./run_container.sh` again, still up | kept | kept |
| stop, then `./run_container.sh` | **kept** | kept |
| `--recreate`, or `docker rm` | redone: seconds to ~2 min | kept — they are in your checkout on the host |
| a fresh vllm-ascend checkout | redone | rebuilt: tens of minutes, once |
| changing `SOC_VERSION`, or another image | redone | rebuilt — the marker says they were built for something else |

---

## Kernels

The custom-op build (`csrc/`, AscendC) is the slow one: tens of minutes. It
happens **once per vllm-ascend checkout**, never once per container — the `.so`,
`_cann_ops_custom/` and the marker `.vllm-ascend-dev-build` land in your
checkout on the host and survive stop / kill / rm.

It needs the **catlass submodule**, which travels with the mount only if you
checked it out:

```bash
git -C <your vllm-ascend> submodule update --init --recursive
```

`run_container.sh` predicts a rebuild with the same test the container uses,
before it starts anything, so "first start is seconds" is never a surprise forty
minutes. Pure-python session in seconds instead:
`COMPILE_CUSTOM_KERNELS=0 ./run_container.sh py` — the custom ops will then fail.

Why the marker has three parts, and what makes it stale:
[NOTES.md — The kernel marker](NOTES.md#the-kernel-marker-and-first-start-is-seconds).

### `bootstrap_editable.sh`, inside the container

```bash
docker exec -it NAME bash /opt/vllm-dev/bootstrap_editable.sh --check
```

| flag | what it does |
|---|---|
| `--check` | reports where python resolves vllm / vllm_ascend and whether the kernels are built. Changes nothing. **Run this first whenever something imports from the wrong place, or a result looks impossible.** |
| `--force` | reinstall vllm-ascend and rebuild the kernels, incrementally (after a `csrc/` change) |
| `--force-all` | also re-install vLLM. Rare. |
| `--deps` | re-resolve dependencies too (after a `requirements*.txt` change). Needs network in the container. |
| `--clean-kernels` | `rm -rf csrc/build` first, keeping `csrc/build_cache`. For a build that fails on stale cmake state. |
| *(none)* | do whatever is missing. This is what the entrypoint runs on every start. |

`./manage_containers.sh` → `c <n>` runs the `--check` for you, and
`docker exec -it NAME bash /opt/vllm-dev/probe_in_container.sh` prints the full
"what is actually in here" report.

---

## Running a server in the container

A normal shell with your home mounted at the same path, so your own launch
scripts work unchanged:

```bash
cd ~/work/myexp && ./serve_qwen.sh
```

`NETWORK=host` (the default) means a port the server binds is the host's port —
`curl localhost:8000` from outside works with no `-p` flags.

The container is detached and survives your SSH session, but **your shell does
not**. For a long serve use tmux inside it, or detach the command:

```bash
docker exec -d <prefix>-dev bash -lc 'cd ~/work/myexp && ./serve_qwen.sh > serve.log 2>&1'
```

Logs under `$HOME` or `$HOST_DATA` are on the host disk at the same path, so you
can read and rotate them from outside while the server runs.

---

## Troubleshooting

Most failures here name their own fix. These are the ones whose cause is not
what the message looks like:

| symptom | cause |
|---|---|
| `bad interpreter: /bin/bash^M`, `syntax error near $'\r'`, `Permission denied`, or `command not found` for a command that plainly exists | all four are Windows line endings. `bash fix_line_endings.sh <dir>` — and it matters inside your **checkout** too, because the kernel build shells out to `csrc/build_aclnn.sh`. [NOTES.md](NOTES.md#windows-line-endings) |
| `image … is not on this box` for an image you can see in `docker images` | a stray `\r` or space on `IMAGE`. The message prints the bytes. [NOTES.md](NOTES.md#image-and-the-stray-r) |
| the kernel build dies in cmake with `status_code: 60` / `self-signed certificate` | a proxy intercepting https. `CMAKE_TLS_VERIFY=0`. [NOTES.md](NOTES.md#cmake_tls_verify--the-intercepted-https-trap) |
| `ModuleNotFoundError: No module named 'ais_bench'`, or a pin that fails with "no matching distributions" and lists no versions | the date-stamped AISBench version. [NOTES.md](NOTES.md#ais_bench_benchmark--the-date-stamped-pin) |
| an import resolves to nothing, `spec:` shows `origin=None` and a `_NamespacePath` | a husk directory in site-packages shadowing a good editable install. [NOTES.md](NOTES.md#the-husk) |
| "An internal error occurs in the Driver module" | `DRIVER_MOUNT=lib64` is enough to link against and not enough to drive the hardware. [NOTES.md](NOTES.md#device_mode-and-driver_mount) |
| `aclInit 507899`, `Resource_Busy(EL0005)`, `chipType=CHIP_MINI(0)` | `DEVICE_MODE=devices` on a driver build that cannot enumerate the chips that way. [NOTES.md](NOTES.md#device_mode-and-driver_mount) |
| a serve hangs or 502s on its own `/health` | an `http_proxy` swallowing traffic to this host. [NOTES.md](NOTES.md#no_proxy-must-cover-this-hosts-own-names) |
| your edit to a `tools/` script does nothing | the image's baked copy is what runs. `MOUNT_TOOLS=1`. [NOTES.md](NOTES.md#mount_tools--whose-tools-actually-runs) |
| a kernel build that should be incremental rebuilds everything, or waits forever | a stale `CMakeCache.txt` or a stale opc lock. [NOTES.md](NOTES.md#stale-opc-locks-and-stale-cmakecache) |
| `[ascend_env] no …/ascend-toolkit/set_env.sh` | the image keeps CANN somewhere other than `ASCEND_HOME`. `./probe_image.sh <ref>` prints where. |
| `cannot talk to the docker daemon` | `systemctl start docker`, or you are not in the `docker` group yet (`newgrp docker`). |

Three messages that look like errors and are not:

* **`was not built by ./build_image.sh — using it exactly as it is`** — route A
  reporting that the container-side scripts come from `tools/`.
* **`VLLM_ASCEND_DIR does not exist on this host`** — correct and deliberate.
  This bundle puts no code in the image, so your checkout has to be there.
* **the bootstrap failed and the container is still up** — deliberate, so you
  have a shell to debug in. `run_container.sh` exits non-zero and does *not*
  drop you into it, because a prompt in a container where your code is not
  installed is the one outcome worth refusing.

---

## Not included

Serving and benchmarking — `vllm serve` command lines, log layout, AISBench runs
— are out of scope. This bundle's job is to give you a container with your code
live inside it, which your own scripts then run in.
