# NOTES — why each knob exists, and every trap worth knowing

The scripts and `a5.env` carry one-line comments. This file carries the reasons.
Nothing here is needed to *use* the bundle — [README.md](README.md) is. Come here
when a knob looks arbitrary, or when something fails in a way that makes no sense.

Sections are named after the knob or the symptom, so a comment in a script can
point at one: `# see NOTES.md: the husk`.

- [The one idea](#the-one-idea)
- [Two routes to a container](#two-routes-to-a-container)
- [IMAGE, and the stray `\r`](#image-and-the-stray-r)
- [BASE_KIND and SYS_PACKAGES](#base_kind-and-sys_packages)
- [SEED_DEPS — the dependency baseline](#seed_deps--the-dependency-baseline)
- [CMAKE_TLS_VERIFY — the intercepted-https trap](#cmake_tls_verify--the-intercepted-https-trap)
- [PIP_PINS and PIP_GUARD_PACKAGES](#pip_pins-and-pip_guard_packages)
- [ais_bench_benchmark — the date-stamped pin](#ais_bench_benchmark--the-date-stamped-pin)
- [DEVICE_MODE and DRIVER_MOUNT](#device_mode-and-driver_mount)
- [no_proxy must cover this host's own names](#no_proxy-must-cover-this-hosts-own-names)
- [The kernel marker, and "first start is seconds"](#the-kernel-marker-and-first-start-is-seconds)
- [MOUNT_TOOLS — whose tools/ actually runs](#mount_tools--whose-tools-actually-runs)
- [The bootstrap verdict, on every path in](#the-bootstrap-verdict-on-every-path-in)
- [Check everything, then destroy anything](#check-everything-then-destroy-anything)
- [The husk](#the-husk)
- [Stale opc locks and stale CMakeCache](#stale-opc-locks-and-stale-cmakecache)
- [git safe.directory](#git-safedirectory)
- [ascend_env.sh picks exactly one toolkit](#ascend_envsh-picks-exactly-one-toolkit)
- [Windows line endings](#windows-line-endings)
- [Sharing an image, and never sharing a checkout](#sharing-an-image-and-never-sharing-a-checkout)
- [Keeping up with upstream](#keeping-up-with-upstream)
- [Another machine or NPU family](#another-machine-or-npu-family)
- [Knobs nothing sets](#knobs-nothing-sets)

---

## The one idea

The image holds **dependencies only**: CANN, torch / torch-npu, triton-ascend,
FLA, the A5 extras. It contains none of your code and none of your paths.

Your `vllm` and `vllm-ascend` checkouts are bind-mounted at their own absolute
host paths and installed with `pip install -e` when the container starts. So:

* editing python changes what runs immediately — no rebuild, no copy;
* two people on different forks share one image;
* the image build needs **nothing** from the machine except docker — no CANN, no
  driver, no `npu-smi`, no checkout. Those are run-time things, which is why
  `run_container.sh` checks them and `build_image.sh` does not.

## Two routes to a container

Because the image only has to supply dependencies, **any** image that has them
will do — including one already on the server.

**Route A, no build.** Point `IMAGE` at an image the box already has. The
container-side scripts are bind-mounted from `tools/`, so the image is used
exactly as it is, unmodified. Whatever `vllm` / `vllm-ascend` it came with are
displaced by your checkouts at start.

**Route B, build.** Set `BASE_IMAGE` and run `./build_image.sh`, when nothing
here has what you need. `BASE_KIND` decides how much work that is.

Neither route saves you the **custom kernel build**: those are compiled against
*your* vllm-ascend sources, once per checkout, inside the container. An image's
own `.so` belongs to that image's own sources and goes with its uninstall.

## IMAGE, and the stray `\r`

`IMAGE` is the only thing `run_container.sh` starts. A trailing carriage return
on it — one `a5.env` edit on Windows — makes `docker image inspect` answer
**"No such image"** for an image sitting right there in `docker images`. The
obvious conclusion, "not on this box", is false, and acting on it means
rebuilding a 40G image you already have.

`run_container.sh`'s `check_clean` therefore rejects a CR or stray surrounding
whitespace in every value where neither is ever meaningful, and prints the bytes
with the boundaries visible. `PIP_PINS`, `EXTRA_MOUNTS` and the index lists are
space-separated by design and are deliberately *not* in that list.

Both `run_container.sh` and `probe_image.sh` also ask **identity first, labels
second, never in one command**. A single `docker image inspect` carrying a
multi-line label template, with `2>/dev/null` and `|| die "not on this box"`,
turns *every* way that command can fail — a template this docker CLI will not
parse, a daemon error, a permission problem — into one confident sentence that
is wrong. So: identity with the simplest possible template and stderr kept;
labels as a separate query whose failure means only "this image has no labels we
recognise", which is the normal case for an image we did not build.

## BASE_KIND and SYS_PACKAGES

`BASE_KIND` is the one choice you make for a build; `build_image.sh` derives
`SEED_DEPS`, `SYS_PACKAGES` and every `INSTALL_*` from it, rather than leaving
them in `a5.env` where one forgotten flag would reinstall FLA over a working one
and move a pinned version under a working vllm.

| `BASE_KIND` | base is | cost | what happens |
|---|---|---|---|
| `cann` | a plain CANN image | tens of minutes, ~25-30G | everything: system packages, dependency baseline, A5 extras |
| `ready` | already a vllm-ascend runtime image | seconds, a few MB | only the CANN env file, `tools/` and the labels |

`SYS_PACKAGES` is the one build step that can disturb a working base:
`update` = distro update then the package list (right for a plain CANN base),
`install` = the list only (what `ready` uses), `skip` = touch nothing. Both `yum`
and `apt-get` are handled, so route B works on an Ubuntu-based base too.

## SEED_DEPS — the dependency baseline

`SEED_DEPS=1` makes the build clone **upstream** vllm + vllm-ascend into
`UPSTREAM_DIR` (`/opt/upstream`) and install them. Your checkouts are not
involved and are not in the image. It exists purely so every dependency —
torch, torch-npu, triton-ascend, memfabric, xgrammar — is already present, which
is what makes a container's first start `pip install -e . --no-deps` and
therefore seconds.

With `SEED_DEPS=0` the image is smaller, but every container's first start has
to resolve and download the whole dependency tree, needs working network inside
the container, and takes many minutes.

`UPSTREAM_DIR` is kept well away from any path you would mount, so a bind mount
cannot hide it. `run_container.sh` refuses to start if one of your mounts covers
it.

## CMAKE_TLS_VERIFY — the intercepted-https trap

A proxy that **intercepts** https — any corporate MITM appliance, recognisable
from the vendor name or a `Proxy-agent` header in a CONNECT reply — presents its own
self-signed CA. pip usually survives it, because pip carries its own bundle.
**The custom kernel build does not.** cmake's `ExternalProject` / `FetchContent`
downloads (makeself, abseil-cpp, ascend_protobuf) fail with

```
status_code: 60   SSL peer certificate ... was not OK
SSL certificate problem: self-signed certificate in certificate chain
```

and the editable install of vllm-ascend then dies in "Building editable for
vllm_ascend", with no `.so` and no marker written.

cmake 3.30+ reads `CMAKE_TLS_VERIFY` from the **environment** and applies it to
both `file(DOWNLOAD)` and `git clone` inside `ExternalProject` / `FetchContent`
— including the nested `FetchContent` sub-build, which is why an environment
variable and not a `-D` is what fixes it. 3.31+ verify by *default*, which is
why this started biting.

* `0` — do not verify. What an intercepted network needs. `GIT_SSL_NO_VERIFY=1`
  is passed with it, for a third-party step that clones with git itself.
* `1` — verify, only if the container already trusts your proxy's CA.
* empty — pass nothing, leave cmake's own default alone.

The alternative, if your **host's** CA bundle already trusts the proxy (test it:
`curl https://gitcode.com` succeeds on the host but not in the container): mount
the host bundle over the container's own and set `CMAKE_TLS_VERIFY=1`. No new
knob is needed — `EXTRA_MOUNTS` already does files:

```
EXTRA_MOUNTS="/etc/pki/tls/certs/ca-bundle.crt:/etc/pki/tls/certs/ca-bundle.crt:ro"
```

## PIP_PINS and PIP_GUARD_PACKAGES

`PIP_PINS` is the list of versions **this image** needs corrected, re-applied by
the bootstrap on every container start. A `pip install` you do by hand lives in
the container's writable layer and is lost on `--recreate`; this is not.

An entry may also be written `name@/absolute/path`, which installs that
directory **editable** (with `--use-pep517`) instead of fetching a version, once
per container. Use it only to run from a source checkout — a fork, or a version
pypi does not carry. The path has to be visible *inside* the container, so under
your mounted home, and the name before the `@` must be the **distribution** name
or the bootstrap cannot tell it is already installed and reinstalls it every
start. Those entries are resolved **with** their dependencies, which is why they
run first and the version pins run after them: that ordering is what stops them
moving numpy or pyarrow under the stack.

`PIP_GUARD_PACKAGES` is the binary ABI, frozen at whatever **this image** has
rather than at a version written down anywhere. torch and torch-npu are built
against each other and against the image's CANN, triton-ascend is a local `+dev`
build no index carries, and numpy 1.x vs 2.x decides whether any of them import.
The bootstrap adds `name==<installed version>` for each to the pip constraints
file, so no dependency of anything in `PIP_PINS` can move them — pip reports a
conflict instead of quietly replacing them. An explicit pin in `PIP_PINS` for
the same package wins, because that is a decision. **Add to this list rather
than removing from it.**

Why the current `PIP_PINS` entries are what they are:

| entry | reason |
|---|---|
| `pyarrow==17.0.0` | `ais_bench` imports `datasets` → pyarrow, and this image pins numpy 1.26.4. A pyarrow built for numpy 2 raises "pyarrow requires NumPy 2.0 or newer" on import. 17.0.0 is the last release that still declares a numpy 1.x dependency. Moving numpy instead would rebuild the ABI under torch_npu and vllm — the far more expensive mistake. |
| `torchvision==0.25.0` | In vllm-ascend's own `requirements.txt`, and simply absent from this image. Reached from `vllm_ascend.patch.worker` → `qwen3_5` → `qwen3_vl` → transformers' `qwen2_vl` image processor, **during config validation** — so a serve dies on it long before a model loads, with a `ModuleNotFoundError` that names nothing nearby. 0.25.0 is the release paired with torch 2.10.0. |
| `numpy==1.26.4` | A floor guard, not a missing package: torch_npu, transformers and the FLA wheels here were built against the 1.x ABI. Empty this and the `pyarrow` entry together once the image itself ships numpy 2. |
| `ais_bench_benchmark[full]` | See the next section. |

The **version mismatches** the image has against the checkout's
`requirements.txt` — transformers, triton-ascend, memfabric-hybrid,
memcache-hybrid — are deliberately *not* in `PIP_PINS`, because moving those
moves working binaries under a working stack. Add one only when an `ImportError`
actually names it. `bootstrap_editable.sh --check` lists every requirement the
image is missing, which is how to find the rest in one go.

## ais_bench_benchmark — the date-stamped pin

No image on these boxes has it, so a fresh container cannot run the benchmark at
all: `ModuleNotFoundError: No module named 'ais_bench'`.

**The version is the one thing to get right**, and it is date-stamped, so a
plausible-looking wrong value is easy to write. Only two releases exist on pypi
— `3.1.20260611` and `3.1.20260630` — and a pin to anything else fails in a way
that does **not** say "no such version", because `PIP_CONSTRAINTS_FILE` is in
play: pip reports a `ResolutionImpossible` between your requirement and your own
constraint, says "no matching distributions available for your environment", and
lists no versions at all. That phrasing is about the resolver, not your
interpreter — the package declares `Requires-Python >=3.10.0` with no upper
bound, so python 3.12 is fine. Check before changing the line:

```bash
python3 -m pip index versions ais_bench_benchmark
```

The bootstrap prints that listing for you whenever a pin fails.

Two more traps:

* **The distribution is named `ais_bench_benchmark`; `ais_bench` is only the
  import name.** So `pip show ais_bench` answers "not found" even when it *is*
  installed. The only check that means anything is
  `python3 -m pip list | grep -i ais`.
* `[full]` is one of four real extras (hf-vl, bfcl, ocrbench-v2, full), and the
  entry most likely to disturb this image: `full` pulls sentence-transformers,
  which requires torch, and pypi's torch is not this image's torch-npu-matched
  build. `PIP_GUARD_PACKAGES` is what stops that. Drop `[full]` to plain
  `ais_bench_benchmark` if you only need the core datasets.

AISBench also has two optional dependency sets its docs install separately
(`requirements/api.txt`, `requirements/extra.txt`); add what an `ImportError`
actually names rather than all of it.

## DEVICE_MODE and DRIVER_MOUNT

Which route works is a property of the **host**, not of this bundle. Each is
also a `run_container.sh` flag, so trying another costs no edit:
`./run_container.sh --device-mode devices --driver-mount lib64`.

`DEVICE_MODE`:

* `privileged` (default) — `--privileged`, no per-chip flags. What the A3 / A5
  cluster guide prescribes for these machines. `/dev` arrives whole, so the
  manager, memory and HDC nodes come with it.
* `devices` — one `--device` per `/dev/davinci<N>` plus the manager nodes.
  Grants the least. On some driver builds the runtime then cannot enumerate the
  chips even though the nodes are visible: `aclInit 507899`,
  `Resource_Busy(EL0005)`, `chipType=CHIP_MINI(0)`.
* `visible` — `-e ASCEND_VISIBLE_DEVICES=<ids>`, for a host running the Ascend
  Docker Runtime, whose hook injects devices **and** driver itself. Pair it with
  `DRIVER_MOUNT=none`.

`DRIVER_MOUNT`:

* `full` (default) — the whole `ASCEND_DRIVER_DIR` plus `ASCEND_FIRMWARE_DIR`,
  both read-**write**, exactly as the guide does it. The driver writes into its
  own tree (logs, device state), and a read-only mount of it has been seen to
  fail in ways that look like a broken driver install. `lib64` alone is enough
  to *link* against and not enough to drive the hardware, which surfaces as "An
  internal error occurs in the Driver module" rather than as a missing file.
* `lib64` — `lib64` and `version.info` only.
* `none` — nothing; only right when the Ascend Docker Runtime provides it.

`ASCEND_RUNTIME_OPTIONS=NODRV` means "mount the chips, not the driver
directories", which is what you want whenever this script mounts the driver
itself. It is emptied automatically when `DRIVER_MOUNT=none`, since then nobody
would mount it and the two would cancel out to no driver at all.

A flag you **type** wins over what `DEVICE_MODE` implies, so
`--device-mode privileged --no-privileged` leaves `--privileged` off and says
so, instead of silently putting it back.

`DRIVER_RO_MOUNTS` are files a healthy Ascend box always has, so a missing one
warns. `OPTIONAL_RO_MOUNTS` are per-family and per-topology, so a missing one is
silent:

| path | applies to |
|---|---|
| `/etc/hccn.conf` | A2 / A3 RoCE fabric config |
| `/lib/route.conf`, `/etc/hccl_rootinfo.json`, `/etc/hixlep` | A5 / 950DT, whose NPUs talk over **UB**, not RoCE. Needed for multi-NPU and multi-node collectives |
| `/etc/vnpu.cfg` | virtualised NPUs only |

Multi-NPU / multi-node on 950 also needs the host side configured — those three
files must exist and be correct before collectives work. That is a server
precheck, not something this bundle can do; see the 950DT section of the
vllm-ascend installation docs.

## no_proxy must cover this host's own names

Loopback must never go through a proxy, and **nor must this host's own names and
addresses**. With `NETWORK=host`, vLLM's API server, its workers, ray and the
EP/DP handshakes all talk to the box they are on by its real address, not by
`127.0.0.1`. An `http_proxy` set so pip can reach an index then swallows that
traffic too, and the symptom is a serve that hangs or 502s on its own `/health`.

So `run_container.sh` seeds `no_proxy` from `NO_PROXY_HOSTS` **plus**
`hostname`, `hostname -s` and every address from `hostname -I`, deduped.
Deliberately **not** `hostname -f`: it resolves, and on a cluster node whose DNS
is unreachable it blocks for the resolver's whole timeout. Add the FQDN to
`NO_PROXY_HOSTS` if you need it.

The proxies are named `BUILD_HTTP_PROXY` / `BUILD_HTTPS_PROXY` because
`docker build` was once the only consumer. A container that needs a proxy to
reach an index needs them just as much, so they are passed into the container
too — never baked into an image.

**A proxy URL with credentials in it** (`http://user:pass@host:port`) becomes
part of the container's environment, which means `docker inspect` shows it to
anyone who can reach the docker socket on this box. `run_container.sh` masks it
in its own output, which does not change that. Prefer a proxy that needs no
credentials, or a `~/.netrc` / `pip.conf` you own.

## The kernel marker, and "first start is seconds"

The custom-op build (`csrc/`, AscendC) is the slow one: tens of minutes. It
happens **once per vllm-ascend checkout**, never once per container, because the
result lands in your checkout on the host and survives container stop / kill /
rm.

The marker file `KERNEL_MARKER` (`.vllm-ascend-dev-build`) records what the
build was *for*, as one string:

```
soc=<SOC_VERSION>;py=<python X.Y>;img=<image key>
```

All three matter. `run_container.sh` predicts staleness with the **same string
comparison** the container makes, before it starts anything, so "first start is
seconds" can never turn into forty minutes:

* `soc=` — a different `SOC_VERSION` is a different kernel.
* `py=` — read from **the image**, by a throwaway `docker run` (`--rm`, no
  network, no NPU, nothing mounted). Not from the host, which need not even have
  a python and whose python is not the one the kernels get built for. Predicting
  from SoC and image alone, as this once did, turns an image whose python moved
  3.11 → 3.12 into a surprise rebuild.
* `img=` — for an image we built, its **base** image reference, so a CANN change
  reached by overriding `BASE_IMAGE` is visible even though every hand-written
  version string stayed the same. For any other image, its own id, which also
  changes when a tag is re-pulled onto new content — exactly when kernels should
  be rebuilt.

`KERNEL_SO_GLOB`, `KERNEL_MARKER` and `CATLASS_MARKER` live in `a5.env` so that
the predicting side and the deciding side cannot disagree about what "already
built" means.

The build needs the **catlass submodule** (`CATLASS_MARKER`). Its working tree
is ordinary files, so it travels with the mount — but only if you checked it
out:

```bash
git -C <your vllm-ascend> submodule update --init --recursive
```

Without it the build fails inside cmake, so both `run_container.sh` and the
bootstrap refuse to start a kernel build without it, and name that command.

## MOUNT_TOOLS — whose tools/ actually runs

Where the container gets `entrypoint.sh` / `bootstrap_editable.sh` /
`ascend_env.sh` from:

* `1` (the default) — always bind-mount from this folder's `tools/`, read-only.
  This is what makes an image nobody built for this bundle usable exactly as it
  is, and it means an edit to `tools/` takes effect on the next `--recreate`
  with no rebuild.
* `auto` — baked into the image when it says so with a label, mounted from
  `tools/` when it does not.
* `0` — always use the image's own copies.

The silent trap is `auto` or `0` on an image that *has* them baked in: the baked
copy is what runs and the host's `tools/` is never read. That is correct and
documented and completely invisible until you have spent an hour on it, so
`run_container.sh` md5s both sides and warns when they differ.

## The bootstrap verdict, on every path in

The flag file `BOOTSTRAP_DONE_FLAG` holds `ok` / `failed` / `skipped`, and its
path comes from `a5.env` so both sides agree on it. Reading it is what stops a
shell being handed out in a container where python imports the image's code
instead of yours — and that has to happen on a **re-attach** and on a **restart**
too, not only on the run that created the container. A bootstrap that failed
yesterday is still failed today.

The flag only counts when it is at least as new as the moment we asked for the
start. The entrypoint deletes it as its first act, but there is a window between
`docker start` returning and the entrypoint reaching that line, and reading the
*previous* run's "ok" inside that window is exactly how a container about to
fail hands you a clean-looking prompt.

When the bootstrap fails, the container is **left up on purpose**, so you have a
shell to debug in — but `run_container.sh` exits non-zero and does *not* drop you
into it. The `spec:` lines at the end of the bootstrap log split the diagnosis in
two:

* `origin=None` with a `_NamespacePath` — an empty leftover directory in
  site-packages is shadowing a perfectly good editable install. Removing it is
  the whole fix. See [the husk](#the-husk).
* an origin inside site-packages or `UPSTREAM_DIR` — a real second install is
  winning.

## Check everything, then destroy anything

`--recreate` removes the old container **only after** every path, checkout,
device and driver file has been validated. It used to remove it first, which
meant one wrong path in your config deleted the container that worked and then
refused to build its replacement — leaving you with nothing at all, from a
command whose entire purpose is to hand you a working container.

For the same reason problems are **collected and reported together** rather than
fatal one at a time: a fresh config usually has more than one path to fix, and
finding them one run at a time is miserable.

A relative path matters here too — it reaches docker as a **volume name**, not a
directory, so every path is checked for being absolute.

`mount_rw` skips a `-v` for a path already inside something we mount. It would
work (docker orders mounts by destination depth, so the child lands on top and
resolves to the same host inode), but it is a second mount point for one
directory: it clutters `docker inspect` and the report, and `docker cp`,
`--volumes-from` and anything that walks the mount table then see one tree twice.

## The husk

A directory left in site-packages — `vllm/`, `vllm_ascend/` or `triton/` with no
`dist-info` behind it — shadows a perfectly good editable install. Python finds
the directory first, treats it as a namespace package, and
`importlib.util.find_spec` reports `origin=None` with a `_NamespacePath`. Every
import then resolves to nothing at all, and the error names your checkout
nowhere.

The bootstrap removes such directories (`PURGE_HUSK=1`, the default) scoped
strictly to paths python itself reports as site/dist-packages — never your
checkout. `PURGE_HUSK=0` turns it into a report that refuses to continue, for
when you want to look first.

## Stale opc locks and stale CMakeCache

Two ways a kernel build fails for a reason that has nothing to do with your code:

* **opc locks.** `csrc/build/**/*kernel_meta*/*.lock` files record a pid. A
  container that was killed mid-build leaves them behind, and the next build
  waits on a process that no longer exists. The bootstrap removes a lock only
  when `/proc/<pid>` is gone.
* **stale `CMakeCache.txt`.** It records absolute paths from the container that
  wrote it. A different image, or a different `ASCEND_HOME`, and cmake fails
  pointing at paths that are not there. The bootstrap detects this and
  `rm -rf csrc/build` — deliberately **keeping** `csrc/build_cache`, which is
  what makes the rebuild incremental rather than total.

`--clean-kernels` does that removal unconditionally.

## git safe.directory

`setuptools_scm` runs git inside your checkout to derive a version. Inside the
container the checkout is owned by a uid git does not recognise as the current
user, so git refuses with "detected dubious ownership" and the install fails
somewhere that reads as a broken checkout.

The bootstrap adds each repo to `safe.directory` in `/etc/gitconfig` (system
scope, which dies with the container). It falls back to `--global` only if that
is not writable, and warns loudly when it does — because `HOME` is your
**mounted host home**, so a `--global` write lands in a file that outlives
everything.

## ascend_env.sh picks exactly one toolkit

An image can carry more than one CANN toolkit, and some carry a runtime-only
drop next to a full one. `ascend_env.sh` sources exactly one `set_env.sh` and
then **scrubs every other toolkit** out of `PATH`, `LD_LIBRARY_PATH`, the include
paths and the cmake paths, and sets `CMAKE_IGNORE_PATH` /
`CMAKE_IGNORE_PREFIX_PATH`. Without that, cmake's `find_library` walks
`PATH` → parent → `lib64` and can bind the build to the runtime-only drop, which
fails at link time with a message about a library that is plainly present.

It is **sourced, never executed**, is POSIX sh (no arrays, no `[[ ]]`), is
`set -u`-safe, and is idempotent via `ASCEND_ENV_DONE`.

`ASCEND_TOOLKIT_SET_ENV` names a toolkit explicitly and short-circuits the
choice. `ASCEND_SINGLE_TOOLKIT=0` turns the scrubbing off. Both are inert unless
set.

`ASCEND_JEMALLOC=1` LD_PRELOADs jemalloc in every shell. It costs one torch_npu
warning per process ("LD_PRELOAD detected, FunctionLoader prefers RTLD_DEFAULT
for symbol resolution"). Keep it at 1 for expert offload, whose pinned host
expert store makes the host allocator matter; 0 if you want the log clean.

`/etc/profile.d/ascend_env.sh` is a fixed path by OS convention. `HOME` points
at your mounted home, so the image's `.bashrc` is never read — but a login shell
still reads `profile.d`. In route B it is a copy of `tools/ascend_env.sh`; in
route A the entrypoint writes a one-line shim pointing at the mounted copy.

## Windows line endings

Four things a Windows → Linux copy breaks, every time, and all four report
themselves as something else:

1. **CRLF** — `bad interpreter: /bin/bash^M`, `syntax error near unexpected
   token $'\r'`, or a variable whose value silently ends in `\r`.
2. **UTF-8 BOM** — three invisible bytes before `#!`, so the kernel does not
   recognise the shebang at all.
3. **missing exec bits** — anything over SMB, a zip, or scp from NTFS arrives
   0644; `./script.sh` says "Permission denied".
4. **non-breaking spaces** (U+00A0), pasted from a browser, a PDF or a chat
   window. bash treats one as part of a word: "command not found".

`fix_line_endings.sh` repairs all four, is idempotent, skips binaries and
`.git/`, and finishes with `bash -n` over every shell file so you learn
immediately if something is broken for a reason that is **not** line endings.

It matters inside your **checkout** too, not just this bundle: the kernel build
shells out to `csrc/build_aclnn.sh`, so a `\r` there is fatal and surfaces as a
bash syntax error after the container has started and pip has reached "Building
editable for vllm_ascend" — a long way to travel for a line-ending problem.
`run_container.sh` scans the checkout's top two levels of `*.sh` and blocks when
the kernels are actually going to be built.

If the fixer itself has CRLF, bash cannot run it either. Break the circle once:

```bash
sed -i 's/\r$//' fix_line_endings.sh && chmod +x fix_line_endings.sh
```

To stop it recurring, on the Windows side: `git config core.autocrlf false`,
`git config core.eol lf`, and a `.gitattributes` with `* text=auto eol=lf`.

Every `grep` that looks for raw bytes in that script uses `-U`: on MSYS2 / Git
Bash / Cygwin, grep opens files in text mode and strips CR before matching, so
without it a line-ending fixer reports zero CRLF in a file full of them.

## Sharing an image, and never sharing a checkout

Docker images are machine-wide, and the images this bundle builds contain no
code and no paths — so **if a colleague already built on this box, do not build
again**. Their image is exactly as good as one you build yourself.

Sharing an image shares nothing else. An image is immutable: every container
gets its own copy-on-write layer, and pip writing into site-packages (or
deleting a file that came from the image) lands in *that* layer.

| | shared between two people on one image | why |
|---|---|---|
| the image's own files | read-only, shared | that is the point: one 30G image, not two |
| site-packages, i.e. the editable installs | **no** | per-container writable layer, gone on `docker rm` |
| `HOST_HOME` | no | each of you mounts your own |
| your checkouts | no | only mounted into the container that names them |
| `HOST_DATA` | **yes, read-write** | deliberate: one copy of the model weights |

This bundle never runs `docker commit`, never uses named volumes, and mounts
nothing over any python library path — the three ways that could stop being true.

**Do not share a checkout.** An editable install writes its metadata into the
source tree, and the vllm-ascend checkout also receives the compiled kernels
plus the marker recording which SoC, python and image they were built for. Two
people on one checkout overwrite each other, and if their images or SoCs differ,
*each* start reads the other's marker as stale and rebuilds — tens of minutes,
every time, for both. `run_container.sh` warns when a checkout is not owned by
you (skipped as root, where every file looks foreign).

The same applies to one person A/B-testing two images against one checkout: the
marker makes every switch a rebuild. Give each image its own clone.

## Keeping up with upstream

Two values mirror upstream pins, and both move. Both live in your own
vllm-ascend checkout, so re-check them after every sync of it:

| setting | check it against |
|---|---|
| `UPSTREAM_VLLM_TAG` | `grep -m1 'ARG VLLM_TAG' <your vllm-ascend>/Dockerfile.a5.openEuler` |
| `BASE_IMAGE` | `grep -m1 ^FROM <your vllm-ascend>/Dockerfile.a5.openEuler` |

`main` moved vllm `v0.33.0` → `v0.34.0` in November 2026, which is what `a5.env`
carries. It matters in route B only, and only for the `SEED_DEPS` baseline — the
vllm that actually runs is your `VLLM_DIR`, so the tag you want is whatever
*your* vllm-ascend expects. The same applies to the FLA, cannbot and mooncake
versions next to it.

The default `BASE_IMAGE` is likely wrong on a new server for two reasons: its
tag carries a **build date** (`9.3.0_<timestamp>`), so it moves; and the `swr.*`
registry it names — the one vllm-ascend's own `Dockerfile.a5*` use — is not
reachable from every network. Find what you can actually pull, in this order:

```bash
docker images | grep -i cann
grep -m1 ^FROM <your vllm-ascend>/Dockerfile.a5.openEuler
# then ask whoever administers the cluster
```

A public quay.io alternative (usually older) looks like
`CANN_REGISTRY=quay.io/ascend/cann`, `CANN_VERSION=9.1.0`.

## Another machine or NPU family

Nothing here is A5-only. Everything family-specific is a variable:

| setting | A5 / 950 | A3 | note |
|---|---|---|---|
| `SOC_VERSION` | `ascend950pr_9579` / `ascend950dt_9582` | `ascend910_9391` / `ascend910_9382` | run-time only, no rebuild. A2 is `ascend910b1`, Atlas 300I Duo `ascend310p1`. Anything starting `ascend950` takes the A5 code paths in `CMakeLists.txt` |
| `CANN_IMAGE_SUFFIX` | `950-openeuler24.03-py3.12` | `a3-openeuler24.03-py3.12` | part of `BASE_IMAGE` |
| `FLA_PACKAGE` | `flash-linear-attention-npu-a5` | `...-a3` | per family on the Ascend mirror; `-a2` for A2 |
| `FLASH_ATTN_BUILD_NPU` | `950` | `910` | |
| `MF_SOC` | `A5` | `A3` | `mfcli kernel install --soc-version` |
| `INSTALL_CANNBOT` | `1` | `0` | A5 only upstream. A missing wheel warns and skips; it does not fail the build |
| `OPTIONAL_RO_MOUNTS` | `/lib/route.conf`, `/etc/hccl_rootinfo.json`, `/etc/hixlep` | `/etc/hccn.conf` | absent files are skipped silently, so the default list covers both |

Change the A5 extras **together with** the base image, not on their own: the
versions are matched to the CANN in it.

`/usr/local/bin/vllm-dev-entrypoint` stays a fixed path too: in a route B image
it is a symlink to `$DEV_TOOLS_DIR/entrypoint.sh`, because `ENTRYPOINT`'s exec
form cannot expand variables. `run_container.sh` does not use it — it passes
`--entrypoint bash <script>` so route A works the same way — but it makes a
hand-written `docker run` behave.

`--entrypoint bash <script> sleep infinity` is explicit on purpose: a stock
vllm-ascend image has an `ENTRYPOINT` of its own, sometimes a serve script, and
we want neither that nor a dependency on ours being baked in. It also needs no
execute bit on a file that may have arrived over a Windows share.

## Knobs nothing sets

These are read by `tools/` scripts and have working defaults, but nothing in
this bundle ever sets them. They are escape hatches, documented here rather than
in `a5.env` so that the config file lists only knobs that do something:

| knob | read by | effect if set |
|---|---|---|
| `ASCEND_ENV_FILE` | entrypoint, bootstrap | the CANN env file to source; always `${DEV_TOOLS_DIR}/ascend_env.sh` in practice |
| `BUILD_DEPS` / `BUILD_BINS` | bootstrap | `module:pip-name` / `binary:pip-name` pairs that must exist for `--no-build-isolation` |
| `TRITON_FORCE` | bootstrap | reinstall triton-ascend even when it imports cleanly |
| `TRITON_WHEEL_DIR` | bootstrap | an extra directory to search for a triton-ascend wheel |
| `GIT_SAFE_DIRS` / `GIT_SAFE_SKIP` | bootstrap | extra `safe.directory` paths / skip writing them |
| `ASCEND_EXTRA_SET_ENV` | ascend_env | additional `set_env.sh` files, sourced after the chosen toolkit |
| `ASCEND_ENV_QUIET` / `ASCEND_ENV_VERBOSE` | ascend_env | suppress the report / print the full candidate table |

Set any of them in the environment, or in `a5.env.local`, when you need it:

```bash
ASCEND_ENV_VERBOSE=1 ./run_container.sh dbg --recreate
```

That works because `run_container.sh` forwards every name in its `OPTIONAL_ENV`
list into the container when, and only when, it is set. A knob reachable from
the host has to be in that list; one that is not is reachable only from inside
(`docker exec -e …`). Add the name there when you add a knob to `tools/`.
