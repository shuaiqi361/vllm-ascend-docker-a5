#!/usr/bin/env bash
# =============================================================================
#  bootstrap_editable.sh — runs INSIDE the container. This is what puts YOUR
#  code in charge: it `pip install -e`s your bind-mounted vllm / vllm-ascend
#  checkouts over whatever the image had, so python imports your code and
#  editing a .py file on the host changes what runs — no rebuild, no copy.
#
#  COMMANDS. Run the copy baked into or mounted in a container, never the one in
#  tools/ on the host. $TOOLS is ${DEV_TOOLS_DIR}; ./manage_containers.sh lists
#  the containers.
#
#      docker exec -it NAME bash $TOOLS/bootstrap_editable.sh <flag>
#      bash $TOOLS/bootstrap_editable.sh <flag>          # already inside
#
#    (no flag)        do whatever is missing. What the entrypoint runs on every
#                     container start.
#    --force          re-install vllm-ascend and rebuild the kernels. THE common
#                     one, after a csrc/ or AscendC edit; incremental, because
#                     cmake's build dir lives in your checkout on the host.
#    --check          report only, change nothing: resolution, kernels, husk
#                     directories, build backend, git, pins, requirements. Run
#                     it first whenever something imports from the wrong place.
#    --deps           resolve dependencies too, after a requirements*.txt change.
#    --force-all      re-install vllm as well. Rare; after a failed bootstrap.
#    --clean-kernels  delete csrc/build, KEEP csrc/build_cache, for a build tree
#                     in a state a lock sweep does not explain. The provenance
#                     purge below is automatic; this is the manual one, for when
#                     the marker agrees and the tree is still wrong.
#
#  You edited PYTHON? Run nothing — the sources are bind-mounted and editable.
#
#  Three things have to hold before an editable install works, and all three
#  fail during "Preparing editable metadata" reading like a broken checkout: the
#  build backend must already be importable (--no-build-isolation fetches
#  nothing), git must accept the checkouts and every submodule, and no husk
#  directory may shadow the install. see NOTES.md: The husk, git safe.directory
#
#  Build output lives in your CHECKOUT, so it outlives every container. Before
#  installing, the marker is checked against this container and this source: a
#  build made for a different soc / python / image / commit / box, or one left
#  by an install that was killed, is REMOVED rather than built on top of. A
#  marker that agrees is left alone, so cmake stays incremental.
#  see NOTES.md: Build provenance, and purging a cache you cannot trust
#
#  Costs: once per CONTAINER, the editable installs; once per CHECKOUT, the
#  custom kernels (tens of minutes, landing on the HOST so a stop/start never
#  repeats them); never, for a python edit.
# =============================================================================
set -uo pipefail

# Prints this file's leading comment block, so no line number has to be kept in
# step. Answered before the required-variable checks, so --help works anywhere.
usage() { sed -n '2,${/^#/!q;p;}' "$0"; }
case "${1:-}" in -h|--help) usage; exit 0 ;; esac

# Your vllm-ascend checkout, mounted. Required — it is the whole point.
VLLM_ASCEND_DIR="${VLLM_ASCEND_DIR:?VLLM_ASCEND_DIR is not set — run_container.sh passes it}"
# checkout = your mounted VLLM_DIR becomes the vllm python imports; image =
# leave it alone and use the image's own baseline.
VLLM_FROM="${VLLM_FROM:-checkout}"
VLLM_DIR="${VLLM_DIR:-}"
[[ "${VLLM_FROM}" == "checkout" && -z "${VLLM_DIR}" ]] \
    && { echo "[bootstrap] [error] VLLM_FROM=checkout but VLLM_DIR is not set" >&2; exit 1; }
SOC_VERSION="${SOC_VERSION:-}"
# 1 = build the custom kernels into the mounted checkout when they are missing.
COMPILE_CUSTOM_KERNELS="${COMPILE_CUSTOM_KERNELS:-1}"
# Container paths the image ENVs. The fallbacks cover a hand-run copy.
DEV_TOOLS_DIR="${DEV_TOOLS_DIR:-/opt/vllm-dev}"
ASCEND_ENV_FILE="${ASCEND_ENV_FILE:-${DEV_TOOLS_DIR}/ascend_env.sh}"
UPSTREAM_DIR="${UPSTREAM_DIR:-/opt/upstream}"
# a5.env owns these strings and passes them in, so the staleness it predicts and
# the decision made here cannot disagree.
# see NOTES.md: The kernel marker, and "first start is seconds"
KERNEL_SO_GLOB="${KERNEL_SO_GLOB:-vllm_ascend/*vllm_ascend_C*.so}"
KERNEL_MARKER="${KERNEL_MARKER:-.vllm-ascend-dev-build}"
CATLASS_MARKER="${CATLASS_MARKER:-csrc/third_party/catlass/include}"
PYTORCH_INDEX_URL="${PYTORCH_INDEX_URL:-https://download.pytorch.org/whl/cpu/}"
# Space-separated list; pip accepts that through PIP_EXTRA_INDEX_URL.
ASCEND_INDEX_URL="${ASCEND_INDEX_URL:-https://mirrors.huaweicloud.com/ascend/repos/pypi https://mirrors.huaweicloud.com/ascend/repos/pypi/nightly}"
# Bounds the kernel build's parallelism, and so its memory. Empty = one per core.
MAX_JOBS="${MAX_JOBS:-}"
# What --no-build-isolation needs already importable, as "module:pip-name".
BUILD_DEPS="${BUILD_DEPS:-setuptools_rust:setuptools-rust setuptools_scm:setuptools-scm pybind11:pybind11 wheel:wheel}"
# Tools the build SHELLS OUT TO, as "binary:pip-name", checked with
# `command -v`, never an import: the pypi ninja wheel's module and executable
# can part company, so `import ninja` succeeds while cmake dies running it.
BUILD_BINS="${BUILD_BINS:-ninja:ninja cmake:cmake>=3.26}"
# Requirements that must hold in EVERY container from this image. A pip install
# you do by hand lives in the writable layer and is lost on --recreate.
# see NOTES.md: PIP_PINS and PIP_GUARD_PACKAGES
PIP_PINS="${PIP_PINS:-}"
# The exact pins as a constraints file, so a version that must hold holds for
# the WHOLE resolution. In /tmp: it describes the CONTAINER, not your source.
PIP_CONSTRAINTS_FILE="${PIP_CONSTRAINTS_FILE:-/tmp/.vllm-dev-pip-constraints.txt}"
# The binary ABI, pinned to WHATEVER THIS IMAGE HAS rather than to a version
# written down anywhere. One innocuous PIP_PINS entry can otherwise drag a stock
# torch over torch-npu's, and you hear of it from a serve that sees no NPU.
# see NOTES.md: PIP_PINS and PIP_GUARD_PACKAGES
PIP_GUARD_PACKAGES="${PIP_GUARD_PACKAGES:-torch torch-npu triton-ascend numpy}"
# Extra git safe directories. The checkouts and submodules are found already.
GIT_SAFE_DIRS="${GIT_SAFE_DIRS:-}"
# 1 = skip the git safe.directory handling entirely.
GIT_SAFE_SKIP="${GIT_SAFE_SKIP:-0}"
# 1 = reinstall triton-ascend even when the installed triton imports cleanly.
# See ensure_triton for why a healthy one is left alone.
TRITON_FORCE="${TRITON_FORCE:-0}"
# Searched for a triton-ascend wheel before the index. The A5 images ship a
# LOCAL +dev build no index carries, so a wheel on disk is the only exact copy.
TRITON_WHEEL_DIR="${TRITON_WHEEL_DIR:-}"
# 1 = remove a leftover package directory pip uninstall could not (purge_husk);
# 0 = report and refuse. The alternative to 1 is python importing an empty
# module and every number you measure being wrong.
PURGE_HUSK="${PURGE_HUSK:-1}"
# 1 = a purge also drops csrc/build_cache, the content-keyed store behind the
# log's "[build-cache] HIT". Kept by default: dropping it turns an incremental
# rebuild into a total one. Set it when a purge did not fix the build.
# see NOTES.md: Build provenance, and purging a cache you cannot trust
PURGE_BUILD_CACHE="${PURGE_BUILD_CACHE:-0}"

MODE="auto"
WITH_DEPS=0
# 1 = delete the kernel build tree before rebuilding. See clean_kernel_build.
CLEAN_KERNELS=0
for arg in "$@"; do
    case "$arg" in
        --check)     MODE="check" ;;
        --force)     MODE="force-ascend" ;;
        --force-all) MODE="force-all" ;;
        --deps)      WITH_DEPS=1 ;;
        --clean-kernels) CLEAN_KERNELS=1; MODE="force-ascend" ;;
        *) echo "[bootstrap] [error] unknown flag: $arg (try --help)" >&2; exit 2 ;;
    esac
done

say()  { echo "[bootstrap] $*"; }
warn() { echo "[bootstrap] [warn] $*" >&2; }
die()  { echo "[bootstrap] [error] $*" >&2; exit 1; }

# ── 0. the mounts have to actually be there ──────────────────────────────────
[[ -d "${VLLM_ASCEND_DIR}" ]] || die "${VLLM_ASCEND_DIR} does not exist inside the
    container. The bind mount did not happen, or VLLM_ASCEND_DIR changed after
    this container was created. Fix it in ascend-dev-env-a5/a5.env.local and:
        ./run_container.sh <name> --recreate"
[[ -f "${VLLM_ASCEND_DIR}/setup.py" ]] \
    || die "${VLLM_ASCEND_DIR} is mounted but holds no setup.py."
if [[ "${VLLM_FROM}" == "checkout" ]]; then
    [[ -d "${VLLM_DIR}" ]] || die "${VLLM_DIR} does not exist inside the container.
    Same causes as above; ./run_container.sh <name> --recreate after fixing it,
    or set VLLM_FROM=image to use the vllm the image already has."
    [[ -f "${VLLM_DIR}/setup.py" || -f "${VLLM_DIR}/pyproject.toml" ]] \
        || die "${VLLM_DIR} is mounted but holds no python package."
fi

# ── the repositories git has to be willing to look at ────────────────────────
# /etc/gitconfig (--system, container-local), with --global only as a loud
# fallback because HOME is your mounted host home. Submodules are separate
# repositories to this check. see NOTES.md: git safe.directory
GIT_SAFE_WENT_GLOBAL=0
git_safe_has() {   # git_safe_has <scope> <path>
    git config "$1" --get-all safe.directory 2>/dev/null | grep -qxF "$2"
}
git_safe_add() {   # git_safe_add <path>  ->  0 added/present, 1 could not
    local p="$1"
    git_safe_has --system "${p}" && return 0
    git config --system --add safe.directory "${p}" 2>/dev/null && return 0
    git_safe_has --global "${p}" && return 0
    if git config --global --add safe.directory "${p}" 2>/dev/null; then
        GIT_SAFE_WENT_GLOBAL=1; return 0
    fi
    return 1
}
# Every working tree this install touches: the checkouts, plus their submodules.
git_repos() {
    local dirs=() d p
    [[ -e "${VLLM_ASCEND_DIR}/.git" ]] && dirs+=( "${VLLM_ASCEND_DIR}" )
    [[ "${VLLM_FROM}" == "checkout" && -n "${VLLM_DIR}" && -e "${VLLM_DIR}/.git" ]] \
        && dirs+=( "${VLLM_DIR}" )
    for d in ${dirs[@]+"${dirs[@]}"}; do
        [[ -f "${d}/.gitmodules" ]] || continue
        while read -r _ p; do
            [[ -n "${p}" && -e "${d}/${p}/.git" ]] && dirs+=( "${d}/${p}" )
        done < <(git config --file "${d}/.gitmodules" --get-regexp '^submodule\..*\.path$' 2>/dev/null)
    done
    printf '%s\n' ${dirs[@]+"${dirs[@]}"} ${GIT_SAFE_DIRS}
}
# Accepted from THIS shell? For reporting only; git_ok_strict decides.
git_ok() {   # git_ok <dir>
    git -C "$1" rev-parse --show-toplevel >/dev/null 2>&1
}

# Would a BUILD TOOL see this repository as safe? The only question that
# matters: setuptools_scm strips every GIT_* variable but a tiny allowlist, so
# the "command"-scope exports below never reach it and only the config FILE
# does. Asking with our exports in place answers "yes" for a doomed tree.
git_ok_strict() {   # git_ok_strict <dir>
    local v strip=()
    while read -r v; do
        case "${v}" in
            GIT_EXEC_PATH|GIT_SSH|GIT_SSH_COMMAND) continue ;;
            GIT_*) strip+=( -u "${v}" ) ;;
        esac
    done < <(compgen -e)
    env ${strip[@]+"${strip[@]}"} git -C "$1" rev-parse --show-toplevel >/dev/null 2>&1
}
ensure_git_safe_dirs() {
    # This FIRST, gated on nothing — not git being on PATH, not GIT_SAFE_SKIP,
    # not the repo list being non-empty, which came back empty on one box and
    # made the function return silently. This scope survives an unwritable
    # /etc/gitconfig, a mounted HOME and GIT_CONFIG_NOSYSTEM.
    local _n="${GIT_CONFIG_COUNT:-0}"
    export "GIT_CONFIG_KEY_${_n}=safe.directory" "GIT_CONFIG_VALUE_${_n}=*"
    export GIT_CONFIG_COUNT=$(( _n + 1 ))

    # Everything below writes FILES, for later `docker exec` shells. Optional.
    command -v git >/dev/null 2>&1 || return 0
    (( GIT_SAFE_SKIP )) && { say "GIT_SAFE_SKIP=1 — leaving git safe.directory files alone"; return 0; }
    local repos=() r failed=()
    mapfile -t repos < <(git_repos)
    (( ${#repos[@]} )) || return 0
    # Silent when git is already content: the common case on a second run.
    local need=0
    for r in "${repos[@]}"; do git_ok_strict "${r}" || { need=1; break; }; done
    (( need )) || return 0
    say "registering ${#repos[@]} git safe director$( (( ${#repos[@]} == 1 )) && echo y || echo ies) in /etc/gitconfig"
    say "  this container is root and those trees are yours, so git refuses them"
    say "  until told otherwise; setuptools_scm needs git to read a version."
    for r in "${repos[@]}"; do
        git_safe_add "${r}" || failed+=( "${r}" )
    done
    # One wildcard, only if a specific entry did not take. Still container-local.
    for r in "${repos[@]}"; do
        git_ok_strict "${r}" && continue
        warn "git still refuses ${r} — falling back to safe.directory=*"
        git_safe_add '*' || true
        break
    done
    for r in "${repos[@]}"; do
        git_ok_strict "${r}" || failed+=( "${r}" )
    done
    if (( GIT_SAFE_WENT_GLOBAL )); then
        warn "could not write /etc/gitconfig, so this went into ${HOME:-/root}/.gitconfig
    instead — which run_container.sh mounts from your HOST home, so the change
    is visible outside the container too. Remove it with:
        git config --global --unset-all safe.directory"
    fi
    if (( ${#failed[@]} )); then
        warn "git will not introspect: ${failed[*]}
    setuptools_scm-derived versions will fail. Try by hand in this container:
        git config --system --add safe.directory '*'
    and re-run me with --force-all."
    else
        say "git safe directories ok (verified the way a build tool asks: with"
        say "  every GIT_* variable stripped, which is what setuptools_scm does)"
    fi
}

# ── 1. where does python think vllm / vllm_ascend live? ──────────────────────
# find_spec, not import: importing vllm drags in torch_npu and the whole plugin
# stack, slowly, and can fail for reasons with nothing to do with us.
pkg_root() {
    python3 - "$1" <<'PY' 2>/dev/null
import importlib.util, os, sys
spec = importlib.util.find_spec(sys.argv[1])
if spec is None or not spec.origin:
    print(""); raise SystemExit
# <root>/<pkg>/__init__.py -> <root>
print(os.path.dirname(os.path.dirname(os.path.abspath(spec.origin))))
PY
}

# WHAT KIND of thing python finds, because pkg_root prints one empty string for
# two states needing opposite fixes: `namespace` is a husk directory to remove,
# `absent` needs installing, `error` is a .pth whose finder will not import.
pkg_kind() {
    python3 - "$1" <<'PY' 2>/dev/null || echo error
import importlib.util as u, sys
try:
    s = u.find_spec(sys.argv[1])
except Exception:
    print("error"); raise SystemExit
if s is None:
    print("absent")
elif s.origin and s.origin != "namespace":
    print("regular")
else:
    print("namespace")
PY
}

# Where the name resolves, origin or not, so a message can NAME the husk.
pkg_locations() {
    python3 - "$1" <<'PY' 2>/dev/null
import importlib.util as u, os, sys
try:
    s = u.find_spec(sys.argv[1])
except Exception:
    s = None
if s is None:
    raise SystemExit
if s.origin and s.origin != "namespace":
    print(os.path.abspath(s.origin))
for p in list(getattr(s, "submodule_search_locations", None) or []):
    print(os.path.abspath(p))
PY
}

# Asked of python, never assembled from a version string: the A5 images put it
# at /usr/local/python3.11.10/lib/python3.11/site-packages, the next elsewhere.
site_dirs() {
    python3 - <<'PY' 2>/dev/null
import site, sysconfig
ds = set()
try:
    ds.update(site.getsitepackages() or [])
except Exception:
    pass
try:
    ds.add(site.getusersitepackages())
except Exception:
    pass
for k in ("purelib", "platlib"):
    p = sysconfig.get_paths().get(k)
    if p:
        ds.add(p)
print("\n".join(sorted(d for d in ds if d)))
PY
}

# ── THE HUSK ─────────────────────────────────────────────────────────────────
# `pip uninstall` removes the RECORD's files and nothing else, so an in-place
# kernel .so or a _cann_ops_custom/ tree leaves a directory with no __init__.py
# that still imports and out-votes the editable install — and pip then reports
# the distribution as not installed, so --force-all changes nothing and it has
# to go by name. Scoped to the module names this script owns, inside a directory
# python itself calls site-packages, never the checkout. see NOTES.md: The husk
purge_husk() {   # purge_husk <module> <our dir>  -> 0 if something was removed
    local mod="$1" ours="$2" d p removed=0
    while read -r d; do
        [[ -n "${d}" ]] || continue
        p="${d}/${mod}"
        [[ -d "${p}" ]] || continue
        # Never the checkout, whatever anyone has configured.
        [[ -n "${ours}" && ( "${p}" == "${ours}" || "${p}" == "${ours}"/* || "${ours}" == "${p}"/* ) ]] && continue
        if ! (( PURGE_HUSK )); then
            warn "${p} is still there after the uninstall and PURGE_HUSK=0, so it is
    being left alone. python will import THAT and not ${ours:-your checkout}.
    Remove it by hand and re-run me:  rm -rf ${p}"
            continue
        fi
        if [[ -f "${p}/__init__.py" ]]; then
            warn "${p} still has an __init__.py after the uninstall — that is a SECOND
    install of ${mod} rather than a leftover, and it would shadow yours.
    Removing it."
        else
            say "  leftover ${p} has no __init__.py, so python imports it as an EMPTY"
            say "  namespace package and never looks at your checkout. Removing it."
            say "  (pip left it: the kernel .so and _cann_ops_custom/ in there were"
            say "   never in its RECORD. This is the husk the header describes.)"
        fi
        if rm -rf "${p}"; then
            removed=1
        else
            warn "could not remove ${p} — python will keep importing it instead of
    ${ours:-your checkout}. Remove it by hand in this container and re-run me
    with --force-all."
        fi
    done < <(site_dirs)
    (( removed )) && return 0
    return 1
}

# Report it without touching it, for --check and for the failure message.
husk_report() {   # husk_report <module> <our dir>  -> prints the husk paths, if any
    local mod="$1" ours="$2" d p
    while read -r d; do
        [[ -n "${d}" ]] || continue
        p="${d}/${mod}"
        [[ -d "${p}" ]] || continue
        [[ -n "${ours}" && ( "${p}" == "${ours}" || "${p}" == "${ours}"/* ) ]] && continue
        [[ -f "${p}/__init__.py" ]] && printf '%s (a second install)\n' "${p}" \
                                    || printf '%s (no __init__.py: an empty namespace package)\n' "${p}"
    done < <(site_dirs)
}

# torch's dynamo guards triton with nothing more than `try: import triton`,
# then uses the upstream API — so a triton that is PRESENT but wrong takes down
# `import torch._dynamo`, and with it `import vllm`, with "module
# 'triton.language' has no attribute 'dtype'". On Ascend that import name
# belongs to triton-ascend, which need not match upstream's API.
triton_state() {
    python3 - <<'PY' 2>/dev/null
import importlib.util
if importlib.util.find_spec("triton") is None:
    print("absent"); raise SystemExit
try:
    import triton.language as tl
    print("ok" if hasattr(tl, "dtype") else "broken")
except Exception:
    print("broken")
PY
}

# torch's cmake package files, for find_package(Torch) in the kernel build.
# find_spec, not import: the torch_npu autoload prints a driver line to STDOUT,
# which is precisely what breaks the checkout's own lookup (section 3).
torch_cmake_prefix() {
    python3 - <<'PY' 2>/dev/null
import importlib.util, os
try:
    spec = importlib.util.find_spec("torch")
except Exception:
    spec = None
print(os.path.join(os.path.dirname(spec.origin), "share", "cmake")
      if spec and spec.origin else "")
PY
}

VLLM_ROOT="$(pkg_root vllm)"
VLLM_ASCEND_ROOT="$(pkg_root vllm_ascend)"
VLLM_KIND="$(pkg_kind vllm)"
VLLM_ASCEND_KIND="$(pkg_kind vllm_ascend)"
# "<not importable>" means two opposite things, so say which, at the top.
describe_resolution() {   # describe_resolution <root> <kind>
    if [[ -n "$1" ]]; then printf '%s' "$1"; return; fi
    case "$2" in
        namespace) printf '<an EMPTY namespace package — a husk directory, see below>' ;;
        absent)    printf '<not installed>' ;;
        error)     printf '<a finder raised; run with --check for the traceback>' ;;
        *)         printf '<not importable>' ;;
    esac
}
if [[ "${VLLM_FROM}" == "checkout" ]]; then
    say "vllm        resolves to: $(describe_resolution "${VLLM_ROOT}" "${VLLM_KIND}")   (want ${VLLM_DIR})"
else
    say "vllm        resolves to: $(describe_resolution "${VLLM_ROOT}" "${VLLM_KIND}")   (VLLM_FROM=image: leaving it alone)"
fi
say "vllm_ascend resolves to: $(describe_resolution "${VLLM_ASCEND_ROOT}" "${VLLM_ASCEND_KIND}")   (want ${VLLM_ASCEND_DIR})"

# Upstream removes triton right after installing vllm, BEFORE vllm-ascend
# brings in triton-ascend, so there is nothing to damage yet. Route A inverts
# that order — the image already HAS it — so this script never uninstalls.
#
# Every requirement the CHECKOUT declares, against what the IMAGE has. Reports
# only: resolving the whole file would move torch / torch-npu / triton-ascend
# under a working stack, so a gap is a decision, not a default.
check_requirements() {
    local f out
    for f in "${VLLM_ASCEND_DIR}/requirements.txt" "${VLLM_ASCEND_DIR}/requirements-dev.txt"; do
        [[ -r "${f}" ]] || continue
        out="$(python3 - "${f}" <<'PYREQ' 2>/dev/null
import sys
import importlib.metadata as md
try:
    from packaging.requirements import Requirement
except Exception:
    print("(packaging not importable, skipped)"); raise SystemExit
bad = []
for raw in open(sys.argv[1], encoding="utf-8", errors="replace"):
    line = raw.split("#")[0].strip()
    if not line or line.startswith("-"):
        continue
    try:
        r = Requirement(line)
    except Exception:
        continue
    if r.marker is not None and not r.marker.evaluate():
        continue
    try:
        have = md.version(r.name)
    except Exception:
        bad.append("%s MISSING" % r.name)
        continue
    if r.specifier and not r.specifier.contains(have, prereleases=True):
        bad.append("%s=%s (wants %s)" % (r.name, have, r.specifier))
print(", ".join(bad))
PYREQ
)"
        say "${f##*/}  : ${out:-every requirement satisfied}"
        # The commonest cause of a serve dying in config validation on an
        # ImportError that names a symbol, so it gets more than one line.
        if [[ -n "${out}" && "${f}" == *"/requirements.txt" ]]; then
            warn "your checkout wants versions this image does not have (above).
    Nothing is broken yet and nothing is being changed: an editable install
    goes in with --no-deps, so a gap only bites when something actually
    imports the missing symbol — and then it does so from inside a serve,
    naming a class rather than a package.
    When one does, add that package to PIP_PINS in a5.env with the version the
    line above asks for, then:  ./run_container.sh <name> --recreate
    Moving a version is a decision about this image's ABI, which is why this
    reports and does not fix."
        fi
    done
}

triton_version() {
    python3 -c 'import importlib.metadata as m; print(m.version("triton-ascend"))' \
        2>/dev/null
}

# A wheel left behind by the image's build layer is the ONLY way to put its
# triton-ascend back byte-for-byte: that +dev version is on no index.
triton_wheel_local() {
    local d ver all hit
    all="$(for d in ${TRITON_WHEEL_DIR} /opt /tmp /root /wheels /var/cache/pip-wheels; do
               [[ -d "${d}" ]] || continue
               find "${d}" -maxdepth 3 -type f -name 'triton*ascend*.whl' 2>/dev/null
           done | sort -u)"
    [[ -n "${all}" ]] || return 0
    # The wheel matching the RECORDED version beats the newest: `sort -V` ranks
    # a plain 3.6.0 above 3.6.0+dev... and would swap the image's build out.
    ver="$(triton_version)"
    if [[ -n "${ver}" ]]; then
        hit="$(grep -F -- "-${ver}-" <<<"${all}" | head -1)"
        [[ -n "${hit}" ]] || hit="$(grep -F -- "${ver}" <<<"${all}" | head -1)"
        [[ -n "${hit}" ]] && { printf '%s\n' "${hit}"; return 0; }
    fi
    sort -V <<<"${all}" | tail -1
}

# The checkout's own requirement, verbatim: `===` is valid pip syntax.
triton_req_pin() {
    local f="${VLLM_ASCEND_DIR}/requirements.txt"
    [[ -r "${f}" ]] || return 0
    sed 's/#.*//' "${f}" | grep -i '^[[:space:]]*triton' | head -1 | tr -d '[:space:]'
}

# Three sources, in the order that stays closest to what the image shipped.
install_triton() {
    local wheel pin
    wheel="$(triton_wheel_local)"
    if [[ -n "${wheel}" ]]; then
        say "  from ${wheel}"
        say "  (a wheel found on this box — no index needed, and it can carry a +dev build)"
        python3 -m pip install --force-reinstall --no-deps "${wheel}" && return 0
        warn "that wheel did not install; trying the index"
    fi
    pin="$(triton_req_pin)"
    if [[ -n "${pin}" ]]; then
        say "  from the index as '${pin}' (the pin in ${VLLM_ASCEND_DIR##*/}/requirements.txt)"
        PIP_EXTRA_INDEX_URL="${ASCEND_INDEX_URL}" \
            python3 -m pip install --force-reinstall --no-deps "${pin}" && return 0
        warn "${pin} did not install; trying triton-ascend unpinned"
    fi
    say "  from the index as 'triton-ascend', unpinned"
    PIP_EXTRA_INDEX_URL="${ASCEND_INDEX_URL}" \
        python3 -m pip install --force-reinstall --no-deps triton-ascend
}

# On every start, before the "nothing to do" exit, because `docker rm` throws
# away a repair done by hand. A HEALTHY triton is never touched: pip cannot be
# asked for an installed +dev version, so "repairing" a working stack is a
# one-way swap with nothing to swap back to. TRITON_FORCE=1 asks anyway.
ensure_triton() {
    local state ver
    state="$(triton_state)"
    ver="$(triton_version)"
    if [[ "${state}" == "ok" ]] && (( ! TRITON_FORCE )); then
        say "triton         : ok (triton-ascend ${ver:-unknown}) — left alone"
        return 0
    fi
    case "${state}" in
        ok)     say "triton is ok, but TRITON_FORCE=1 — reinstalling anyway" ;;
        absent) say "triton is absent. vllm-ascend requires triton-ascend, which owns that
    import name on Ascend — installing it." ;;
        broken) say "triton imports but is incomplete${ver:+, and triton-ascend ${ver} owns that import name}.
    torch only asks whether triton imports, never whether it is the right one,
    so torch._dynamo — and with it 'import vllm' — dies on it:
        AttributeError: module 'triton.language' has no attribute 'dtype'
    Repairing." ;;
    esac
    # What an unconditional `pip uninstall -y triton` leaves behind. Drop the
    # upstream dist first, or the reinstall lands next to a RECORD that will
    # delete these files all over again.
    if [[ -n "${ver}" ]] \
       && python3 -c 'import importlib.metadata as m; m.version("triton")' 2>/dev/null; then
        say "  both 'triton' and 'triton-ascend' are installed — dropping upstream 'triton'"
        python3 -m pip uninstall -y triton >/dev/null 2>&1 || true
    fi
    # Same husk as vllm_ascend's: an empty directory imports, so a reinstall
    # would land next to something that already wins. Clear it first.
    if [[ "$(pkg_kind triton)" == "namespace" ]]; then
        say "  'triton' is a directory with no __init__.py — an empty namespace package."
        say "  A reinstall alone would not win against it, so it goes first."
        purge_husk triton "" || true
    fi
    install_triton || warn "the install failed — see the pip output above"
    state="$(triton_state)"
    if [[ "${state}" == "ok" ]]; then
        say "triton         : ok (triton-ascend $(triton_version))"
        return 0
    fi
    warn "triton is still '${state}' after reinstalling. If it is ABSENT, nothing
    could be fetched: check that this container has the proxy env it needs
    (echo \$https_proxy) and that ASCEND_INDEX_URL is reachable. The surest fix
    is the one that needs no network at all — ./run_container.sh <name>
    --recreate, which puts the image's own build back."
}

# Is each PIP_PINS entry satisfied? Asked of `packaging`, the library pip
# resolves with, as tab-separated "<state> <spec> <installed> <name>". Not a
# string comparison: that understands only `==`, so a RANGE pin fell into
# "something is installed, leave it alone" — skipping the floor pins that exist
# precisely because a package can be too OLD.
pin_classify() {
    python3 - "$@" <<'PY' 2>/dev/null
import sys
import importlib.metadata as md
try:
    from packaging.requirements import Requirement
except Exception:
    Requirement = None
for raw in sys.argv[1:]:
    if Requirement is None:
        print("unknown\t%s\t\t" % raw); continue
    try:
        r = Requirement(raw)
    except Exception:
        print("unknown\t%s\t\t" % raw); continue
    try:
        have = md.version(r.name)
    except Exception:
        print("absent\t%s\t\t%s" % (raw, r.name)); continue
    ok = (not r.specifier) or r.specifier.contains(have, prereleases=True)
    print("%s\t%s\t%s\t%s" % ("ok" if ok else "stale", raw, have, r.name))
PY
}

# PIP_CONSTRAINT is the environment form of --constraint, so this reaches the
# editable installs and the triton repair too. A constraint applies whether or
# not the package is being installed, which is the whole difference: a SATISFIED
# pin drops out of an install command, and that is how numpy's guard goes absent
# and pip pulls numpy 2 under torch_npu.
write_pip_constraints() {
    local raw spec out=""
    for raw in ${PIP_PINS}; do
        case "${raw}" in *"=="*) ;; *) continue ;; esac
        # EXTRAS ARE STRIPPED: older pip rejects the whole constraints file over
        # one, so every install then fails for an unrelated-looking reason.
        if [[ "${raw}" == *"["*"]"* ]]; then
            spec="${raw%%"["*}${raw#*"]"}"
        else
            spec="${raw}"
        fi
        out="${out}${spec}"$'\n'
    done
    # Only where PIP_PINS does not pin explicitly: a decision beats "do not
    # move".
    local g gv
    for g in ${PIP_GUARD_PACKAGES}; do
        case " ${PIP_PINS} " in *" ${g}=="*|*" ${g}["*) continue ;; esac
        gv="$(python3 -c "import importlib.metadata as m; print(m.version('${g}'))" 2>/dev/null)"
        [[ -n "${gv}" ]] || continue
        out="${out}${g}==${gv}"$'\n'
    done
    if [[ -z "${out}" ]]; then
        rm -f "${PIP_CONSTRAINTS_FILE}" 2>/dev/null
        return 0
    fi
    if printf '%s' "${out}" > "${PIP_CONSTRAINTS_FILE}" 2>/dev/null; then
        export PIP_CONSTRAINT="${PIP_CONSTRAINTS_FILE}"
        say "pip constraints: $(printf '%s' "${out}" | tr '\n' ' ')"
    else
        warn "could not write ${PIP_CONSTRAINTS_FILE}; the exact pins in PIP_PINS will
    hold only for the installs that name them. An install of something else
    could still move them."
    fi
}

ensure_pip_pins() {
    write_pip_constraints
    [[ -n "${PIP_PINS}" ]] || return 0
    local state raw have name need=() report=""
    while IFS=$'\t' read -r state raw have name; do
        [[ -n "${state:-}" ]] || continue
        case "${state}" in
            ok)      ;;
            stale)   need+=( "${raw}" ); report="${report} ${raw} (have ${have})" ;;
            absent)  need+=( "${raw}" ); report="${report} ${raw} (not installed)" ;;
            unknown) need+=( "${raw}" ); report="${report} ${raw} (could not be parsed)" ;;
        esac
    done < <(pin_classify ${PIP_PINS})
    if (( ! ${#need[@]} )); then
        say "pip pins       : satisfied$( [[ -n "${PIP_CONSTRAINT:-}" ]] && echo " (and held as constraints)")"
        return 0
    fi
    say "applying PIP_PINS (a5.env):${report}"
    # What pip can actually offer, when it turns out it can offer nothing.
    _pin_names=""
    for raw in ${need[@]+"${need[@]}"}; do
        name="${raw%%[<>=!~]*}"; name="${name%%"["*}"
        _pin_names="${_pin_names} ${name}"
    done
    # The torch CPU index as well as the Ascend ones: +cpu sorts HIGHER than the
    # bare version, so offering both picks the build that matches torch +cpu.
    PIP_EXTRA_INDEX_URL="${ASCEND_INDEX_URL}" \
    python3 -m pip install --extra-index-url "${PYTORCH_INDEX_URL}" "${need[@]}" \
        || { warn "could not apply PIP_PINS:${report}
    The run continues, but whatever needed that version still will not import.
    MIND THE MESSAGE pip printed, and mind that a constraints file makes it
    WORSE. With PIP_CONSTRAINT set, pip reports a version that simply does not
    exist as a ResolutionImpossible between your requirement and your own
    constraint — \"no matching distributions available for your environment\" —
    and never prints the versions that DO exist. Without the file the same
    situation reads \"Could not find a version that satisfies the requirement X
    (from versions: ...)\", which is the message you actually want. That is why
    the listing below is printed. Three causes, commonest first:
      * THE VERSION DOES NOT EXIST. Compare your pin against the listing below.
        A date-stamped version you copied from a changelog or guessed is the
        usual culprit; nothing about the interpreter or the ABI is involved.
      * A REAL CONFLICT: pip names ${PIP_CONSTRAINTS_FILE} and two DIFFERENT
        versions of one package. Then what you asked for cannot coexist with a
        pin or an ABI guard, and one of the two has to give. A decision, not a
        thing to force — read which one it named.
      * pip could not reach an index at all — see PIP_INDEX_URL /
        BUILD_HTTP(S)_PROXY in a5.env; they apply at container creation, so
        --recreate after."
        explain_pin_failure ${_pin_names}; }
}

# pip's resolver error names the requirement and the constraint and leaves you
# guessing which end is wrong. An empty version listing is itself the diagnosis.
explain_pin_failure() {
    local name
    for name in "$@"; do
        [[ -n "${name}" ]] || continue
        say "  what python ${PY_TAG} can install of '${name}':"
        PIP_EXTRA_INDEX_URL="${ASCEND_INDEX_URL}" \
            python3 -m pip index versions "${name}" 2>&1 \
            | head -4 | sed 's/^/      /'
    done
    say "  If your pin is not in that list, that is the answer: correct the version"
    say "  in PIP_PINS. If the list is empty or errors while the package plainly"
    say "  exists, then Requires-Python excludes python ${PY_TAG} and you need a"
    say "  different IMAGE rather than a different pin — check that before"
    say "  assuming it, with: python3 -m pip index versions <name>"
}
# ── 2. is the custom kernel extension built in the MOUNTED tree? ─────────────
MARKER="${VLLM_ASCEND_DIR}/${KERNEL_MARKER}"
# Baked by ./build_image.sh; an image we did not build has none, so
# run_container.sh passes IMAGE_REF directly and that wins.
# shellcheck disable=SC1091
if [[ -z "${IMAGE_REF:-}" && -f "${DEV_TOOLS_DIR}/image-info.env" ]]; then
    source "${DEV_TOOLS_DIR}/image-info.env"
fi
# The key records what the build was made FOR; IMAGE_REF is the honest identity
# of the CANN toolkit, since a hand-written version string survives a
# BASE_IMAGE override untouched.
PY_TAG="$(python3 -c 'import sys;print("%d.%d"%sys.version_info[:2])')"
BUILD_KEY="soc=${SOC_VERSION};py=${PY_TAG};img=${IMAGE_REF:-${IMAGE_CANN_VERSION:-unknown}}"
# src= and host= answer "from THESE sources, on THIS box?". run_container.sh
# derives both and passes them, for the reason it passes IMAGE_REF: it predicts
# staleness before starting anything, and a value derived twice can differ —
# git in here needs safe.directory, and with NETWORK=bridge this container's
# hostname is not the host's — which would read as a stale build forever.
# Appended only when known, because marker_mismatch treats an absent field as
# UNKNOWN, and unknown must never cost a rebuild.
# see NOTES.md: Build provenance, and purging a cache you cannot trust
[[ -n "${SRC_REF:-}" ]]       && BUILD_KEY="${BUILD_KEY};src=${SRC_REF}"
[[ -n "${BUILD_HOST_ID:-}" ]] && BUILD_KEY="${BUILD_KEY};host=${BUILD_HOST_ID}"

have_kernels() {
    compgen -G "${VLLM_ASCEND_DIR}/${KERNEL_SO_GLOB}" > /dev/null 2>&1
}

# ── CANN's per-kernel compile lock ───────────────────────────────────────────
# opc refuses a kernel_meta directory whose lock records another pid ("Another
# process is using this dir"). Genuine concurrency says that too — bound it with
# MAX_JOBS — so only a DEAD pid's lock is cleared here.
# see NOTES.md: Stale opc locks and stale CMakeCache
clear_stale_kernel_locks() {
    local build="${VLLM_ASCEND_DIR}/csrc/build"
    [[ -d "${build}" ]] || return 0
    local lock pid removed=0 held=0
    while IFS= read -r lock; do
        [[ -n "${lock}" ]] || continue
        pid="$(LC_ALL=C tr -dc '0-9' < "${lock}" 2>/dev/null | head -c 10)"
        if [[ -n "${pid}" && -d "/proc/${pid}" ]]; then
            held=$(( held + 1 )); continue
        fi
        rm -f "${lock}" && removed=$(( removed + 1 ))
    done < <(find "${build}" -path '*kernel_meta*' -name '*.lock' -type f 2>/dev/null)
    (( held )) && warn "${held} kernel compile lock(s) are held by a process that IS running.
    Left alone — another build is in progress in this container, and two
    builds against one checkout will fight over every lock. Wait for it, or
    find it with:  ps -ef | grep -c opc"
    if (( removed )); then
        say "cleared ${removed} STALE kernel compile lock(s) under csrc/build"
        say "  (their owning pid is gone — an interrupted build left them, and"
        say "   csrc/build is in your checkout, so they would have failed every"
        say "   later build with \"Another process is using this dir\")"
    fi
    return 0
}

# ── a CMakeCache from a container that no longer exists ──────────────────────
# It records absolute paths to tools that live in the CONTAINER while sitting in
# csrc/build inside your mounted checkout, and nothing invalidates it on its own
# — not --force, not a different image.
# see NOTES.md: Stale opc locks and stale CMakeCache
stale_cmake_cache() {   # prints the dead entries, returns 0 if any
    local cache="${VLLM_ASCEND_DIR}/csrc/build/CMakeCache.txt" line k v bad=""
    [[ -f "${cache}" ]] || return 1
    while IFS= read -r line; do
        case "${line}" in
            CMAKE_MAKE_PROGRAM:*|CMAKE_C_COMPILER:*|CMAKE_CXX_COMPILER:*|\
            CMAKE_COMMAND:*|CMAKE_AR:*|CMAKE_LINKER:*|CMAKE_RANLIB:*|\
            CMAKE_STRIP:*|Python3_EXECUTABLE:*|PYTHON_EXECUTABLE:*)
                k="${line%%:*}"; v="${line#*=}"
                [[ "${v}" == /* ]] || continue
                [[ -e "${v}" ]] || bad="${bad}
       ${k} = ${v}"
                ;;
        esac
    done < "${cache}"
    [[ -n "${bad}" ]] || return 1
    printf '%s\n' "${bad}"
    return 0
}

# Cheaper than it sounds: csrc/build is generated output, while csrc/build_cache
# — what makes the log say "[build-cache] HIT" — is KEPT.
clean_kernel_build() {
    local build="${VLLM_ASCEND_DIR}/csrc/build"
    [[ -d "${build}" ]] || { say "no csrc/build to clean"; return 0; }
    say "--clean-kernels: removing ${build}"
    say "  csrc/build_cache is NOT touched, so the cached kernel binaries survive"
    say "  and this costs far less than a first build."
    rm -rf "${build}" || warn "could not remove ${build} — check permissions on your checkout"
}
# Field-wise rather than one string comparison, so a field the stored marker
# does not carry is treated as UNKNOWN and not as a mismatch. That is what lets
# src= and host= be added without condemning every build made before they
# existed: only a field present on both sides and DIFFERING condemns one.
marker_mismatch() {   # prints the field names that moved; returns 0 if any did
    [[ -f "${MARKER}" ]] || return 1
    local stored field k want have out=""
    stored=";$(tr -d '\r\n' < "${MARKER}" 2>/dev/null);"
    for field in ${BUILD_KEY//;/ }; do
        k="${field%%=*}"; want="${field#*=}"
        # Anchored on the separator: a value could otherwise contain a key name.
        case "${stored}" in *";${k}="*) ;; *) continue ;; esac
        have="${stored#*;${k}=}"; have="${have%%;*}"
        [[ "${have}" == "${want}" ]] || out="${out} ${k}"
    done
    [[ -n "${out}" ]] || return 1
    printf '%s\n' "${out# }"
}
marker_ok() {
    [[ -f "${MARKER}" ]] && ! marker_mismatch >/dev/null
}

# Build output lives in your MOUNTED checkout, so it outlives every container
# and nothing invalidates it on its own. Three ways it stops describing what is
# about to be built, all of them silent until cmake fails strangely or — worse —
# succeeds against the wrong objects:
#   * the marker records a different soc, python, image or source commit;
#   * the marker records a different box;
#   * there is build output and NO marker, which is exactly what a build that
#     was killed or failed leaves: the marker is deleted before a build starts
#     and written only once one has produced a .so.
# A first build has no output and so no decision to make.
# see NOTES.md: Build provenance, and purging a cache you cannot trust
purge_stale_build() {
    local build="${VLLM_ASCEND_DIR}/csrc/build"
    local cache="${VLLM_ASCEND_DIR}/csrc/build_cache"
    local reason moved
    local -a sos=() eggs=()
    mapfile -t sos  < <(compgen -G "${VLLM_ASCEND_DIR}/${KERNEL_SO_GLOB}" 2>/dev/null)
    mapfile -t eggs < <(compgen -G "${VLLM_ASCEND_DIR}/*.egg-info" 2>/dev/null)
    [[ -d "${build}" || ${#sos[@]} -gt 0 ]] || return 0

    if moved="$(marker_mismatch)"; then
        reason="it was built for a different ${moved// /, }"
    elif [[ ! -f "${MARKER}" ]]; then
        reason="there is build output but no ${KERNEL_MARKER}, so whatever produced it never finished"
    else
        return 0   # the marker agrees: this tree is ours, and cmake is incremental
    fi

    warn "removing stale build output from your checkout before installing:
    ${reason}.
        marker holds : $( [[ -f "${MARKER}" ]] && tr -d '\r\n' < "${MARKER}" || echo '<no marker file>' )
        marker wants : ${BUILD_KEY}
    Keeping it would feed cmake objects and a CMakeCache that do not match this
    toolchain or these sources. csrc/ is rebuilt from scratch below."
    rm -f "${MARKER}"
    if [[ -d "${build}" ]]; then
        rm -rf "${build}" && say "  removed csrc/build" \
            || warn "  could not remove ${build} — check the permissions on your checkout"
    fi
    (( ${#sos[@]}  )) && { rm -f  "${sos[@]}"  && say "  removed ${#sos[@]} stale kernel .so"; }
    (( ${#eggs[@]} )) && { rm -rf "${eggs[@]}" && say "  removed a stale *.egg-info left by an earlier install"; }
    [[ -d "${VLLM_ASCEND_DIR}/build" ]] \
        && { rm -rf "${VLLM_ASCEND_DIR}/build" && say "  removed the setuptools build/ tree"; }
    if (( PURGE_BUILD_CACHE )); then
        [[ -d "${cache}" ]] \
            && { rm -rf "${cache}" && say "  removed csrc/build_cache (PURGE_BUILD_CACHE=1) — a total rebuild"; }
    elif [[ -d "${cache}" ]]; then
        say "  csrc/build_cache is KEPT: it is keyed by source content, so its"
        say "  compiled kernels still match wherever the sources did not move."
        say "  If this rebuild still fails oddly, drop it too: PURGE_BUILD_CACHE=1"
    fi
    return 0
}

NEED_VLLM=0
NEED_ASCEND=0
[[ "${VLLM_FROM}" == "checkout" && "${VLLM_ROOT}" != "${VLLM_DIR}" ]] && NEED_VLLM=1
[[ "${VLLM_ASCEND_ROOT}" != "${VLLM_ASCEND_DIR}" ]] && NEED_ASCEND=1
# Missing or stale kernels justify a reinstall only if we may build them.
if (( COMPILE_CUSTOM_KERNELS )) && { ! have_kernels || ! marker_ok; }; then NEED_ASCEND=1; fi
# --force is the kernel rebuild; re-installing vllm too is a rarer need.
[[ "${MODE}" == "force-ascend" ]] && NEED_ASCEND=1
[[ "${MODE}" == "force-all" ]] && { NEED_VLLM=1; NEED_ASCEND=1; }

# On a fresh container those are whatever the image ships, which is correct —
# say so, or the install below reads as something going wrong.
FOREIGN=0
[[ -n "${VLLM_ROOT}"        && "${VLLM_ROOT}"        != "${VLLM_DIR}"        ]] && FOREIGN=1
[[ -n "${VLLM_ASCEND_ROOT}" && "${VLLM_ASCEND_ROOT}" != "${VLLM_ASCEND_DIR}" ]] && FOREIGN=1
if (( ( NEED_VLLM || NEED_ASCEND ) && FOREIGN )); then
    say "those are the copies the image came with, which is normal for a new"
    say "container. Handing over to your mounted checkout(s) — that is an install,"
    say "not a build, and nothing is being downloaded."
fi

if [[ "${MODE}" == "check" ]]; then
    _locks_total=0; _locks_stale=0
    if [[ -d "${VLLM_ASCEND_DIR}/csrc/build" ]]; then
        while IFS= read -r _l; do
            [[ -n "${_l}" ]] || continue
            _locks_total=$(( _locks_total + 1 ))
            _p="$(LC_ALL=C tr -dc '0-9' < "${_l}" 2>/dev/null | head -c 10)"
            [[ -n "${_p}" && -d "/proc/${_p}" ]] || _locks_stale=$(( _locks_stale + 1 ))
        done < <(find "${VLLM_ASCEND_DIR}/csrc/build" -path '*kernel_meta*' -name '*.lock' -type f 2>/dev/null)
    fi
    say "kernel locks   : ${_locks_total} present, ${_locks_stale} STALE$( (( _locks_stale )) && echo "   <- these fail every build with 'Another process is using this dir'; a run without --check clears them" )"
    say "kernels wanted : ${COMPILE_CUSTOM_KERNELS}"
    say "kernels present: $(have_kernels && echo yes || echo no)"
    say "marker current : $(marker_ok && echo yes || echo no)"
    say "  marker wants : ${BUILD_KEY}"
    say "  marker holds : $( [[ -f "${MARKER}" ]] && tr -d '\r\n' < "${MARKER}" || echo '<no marker file>' )"
    _moved="$(marker_mismatch)" && say "  fields moved : ${_moved}"
    if [[ -d "${VLLM_ASCEND_DIR}/csrc/build" ]] && [[ ! -f "${MARKER}" ]]; then
        say "stale output   : csrc/build exists with NO marker — a killed or failed"
        say "                 build left it; a run without --check removes it first"
    elif [[ -n "${_moved:-}" ]]; then
        say "stale output   : the build output in your checkout would be REMOVED"
        say "                 before installing (a run without --check does it)"
    else
        say "stale output   : none — any build output present was made here"
    fi
    say "would reinstall vllm: ${NEED_VLLM}, vllm-ascend: ${NEED_ASCEND}"
    # Whether a "<not importable>" is a missing install or a husk shadowing a
    # good one. Opposite fixes.
    say "import shape   : vllm=${VLLM_KIND}  vllm_ascend=${VLLM_ASCEND_KIND}"
    say "  'regular' is what you want. 'namespace' means an EMPTY directory is winning"
    say "  over your editable install — a run without --check removes it."
    for _m in vllm vllm_ascend; do
        _loc="$(pkg_locations "${_m}" | paste -sd' ' )"
        say "  ${_m} at: ${_loc:-<nothing>}"
    done
    _hv="$(husk_report vllm "${VLLM_DIR}" | tr '\n' ';' | sed 's|;$||')"
    _ha="$(husk_report vllm_ascend "${VLLM_ASCEND_DIR}" | tr '\n' ';' | sed 's|;$||')"
    say "husk dirs      : vllm=${_hv:-none}  vllm_ascend=${_ha:-none}"
    # Reported, never fixed. The first two things to look at when an install
    # failed during "Preparing editable metadata".
    missing_bd=""
    for pair in ${BUILD_DEPS}; do
        python3 -c "import ${pair%%:*}" >/dev/null 2>&1 || missing_bd="${missing_bd} ${pair#*:}(import)"
    done
    for pair in ${BUILD_BINS}; do
        command -v "${pair%%:*}" >/dev/null 2>&1 || missing_bd="${missing_bd} ${pair#*:}(binary)"
    done
    say "build backend  :${missing_bd:- all present}"
    for pair in ${BUILD_BINS}; do
        say "  $(printf '%-6s' "${pair%%:*}"): $(command -v "${pair%%:*}" 2>/dev/null || echo 'NOT ON PATH')"
    done
    if _dead="$(stale_cmake_cache)"; then
        say "cmake cache    : STALE — names tools that are not in this container:${_dead}"
        say "  a run without --check drops csrc/build so cmake looks again"
    else
        say "cmake cache    : $( [[ -f "${VLLM_ASCEND_DIR}/csrc/build/CMakeCache.txt" ]] && echo 'present, every recorded tool exists' || echo 'none yet' )"
    fi
    # The same classifier a real run uses, so --check cannot disagree with it.
    pins_bad=""
    while IFS=$'\t' read -r _s _raw _h _pn; do
        [[ -n "${_s:-}" && "${_s}" != "ok" ]] && pins_bad="${pins_bad} ${_raw}(have ${_h:-none})"
    done < <(pin_classify ${PIP_PINS})
    check_requirements
    _ts="$(triton_state)"; _tv="$(triton_version)"
    _tw="$(triton_wheel_local)"; _tp="$(triton_req_pin)"
    say "triton         : ${_ts} (triton-ascend ${_tv:-not installed}, import shape $(pkg_kind triton))   <- only 'ok' is left alone; absent and broken are reinstalled"
    say "triton repair  : wheel=${_tw:-none on this box}  pin=${_tp:-none in requirements.txt}"
    if [[ -z "${PIP_PINS}" ]]; then say "pip pins       : none set"
    elif [[ -z "${pins_bad}" ]]; then say "pip pins       : satisfied (${PIP_PINS})"
    else say "pip pins       : WOULD BE APPLIED:${pins_bad}"
    fi
    _tcp="$(torch_cmake_prefix)"
    if [[ -n "${_tcp}" && -f "${_tcp}/Torch/TorchConfig.cmake" ]]; then
        say "torch cmake    : ${_tcp}"
    else
        say "torch cmake    : NOT USABLE (${_tcp:-torch not importable})   <- find_package(Torch) would fail"
    fi
    if command -v git >/dev/null 2>&1; then
        # They disagree exactly when it matters: readable from here but NOT
        # stripped is the dubious-ownership failure waiting to happen.
        git_bad=""; git_bad_strict=""
        while read -r r; do
            [[ -n "${r}" ]] || continue
            git_ok        "${r}" || git_bad="${git_bad} ${r}"
            git_ok_strict "${r}" || git_bad_strict="${git_bad_strict} ${r}"
        done < <(git_repos)
        say "git from here  :${git_bad:- all readable}"
        say "git stripped   :${git_bad_strict:- all readable}$( [[ -n "${git_bad_strict}" ]] && echo "   <- THIS is the one that breaks the editable install; a run without --check registers them" )"
    fi
    exit 0
fi

ensure_pip_pins
ensure_triton

# On every start, not only under --check: a requirement the image lacks is
# otherwise invisible until a serve dies half an hour later on an ImportError
# naming a SYMBOL. One metadata read each, no network.
check_requirements

# The one state that makes "nothing to do" a lie: pkg_root gives the same empty
# string for "not installed" and "shadowed by an empty directory", where the
# whole repair is removing it. Done before the early exit, so a stop/start heals
# itself instead of printing "Nothing to do" over a broken import.
heal_husk() {   # -> 0 if it removed something and the resolution improved
    local healed=0
    if [[ "${VLLM_FROM}" == "checkout" && "${VLLM_KIND}" == "namespace" ]]; then
        say "vllm is an empty namespace package — looking for the husk that is shadowing"
        say "your editable install (no reinstall needed if that is all it is):"
        purge_husk vllm "${VLLM_DIR}" && healed=1
    fi
    if [[ "${VLLM_ASCEND_KIND}" == "namespace" ]]; then
        say "vllm_ascend is an empty namespace package — looking for the husk that is"
        say "shadowing your editable install (no reinstall needed if that is all it is):"
        purge_husk vllm_ascend "${VLLM_ASCEND_DIR}" && healed=1
    fi
    (( healed )) || return 1
    VLLM_ROOT="$(pkg_root vllm)";               VLLM_KIND="$(pkg_kind vllm)"
    VLLM_ASCEND_ROOT="$(pkg_root vllm_ascend)"; VLLM_ASCEND_KIND="$(pkg_kind vllm_ascend)"
    say "after removing it: vllm -> $(describe_resolution "${VLLM_ROOT}" "${VLLM_KIND}") ; vllm_ascend -> $(describe_resolution "${VLLM_ASCEND_ROOT}" "${VLLM_ASCEND_KIND}")"
    NEED_VLLM=0; NEED_ASCEND=0
    [[ "${VLLM_FROM}" == "checkout" && "${VLLM_ROOT}" != "${VLLM_DIR}" ]] && NEED_VLLM=1
    [[ "${VLLM_ASCEND_ROOT}" != "${VLLM_ASCEND_DIR}" ]] && NEED_ASCEND=1
    if (( COMPILE_CUSTOM_KERNELS )) && { ! have_kernels || ! marker_ok; }; then NEED_ASCEND=1; fi
    [[ "${MODE}" == "force-ascend" ]] && NEED_ASCEND=1
    [[ "${MODE}" == "force-all" ]] && { NEED_VLLM=1; NEED_ASCEND=1; }
    return 0
}
heal_husk || true

if (( ! NEED_VLLM && ! NEED_ASCEND )); then
    say "python already imports your mounted checkout(s)$( (( COMPILE_CUSTOM_KERNELS )) && echo " and the kernels are built")."
    say "Nothing to do."
    exit 0
fi

# ── 3. (re)install ───────────────────────────────────────────────────────────
# --no-build-isolation: the build dependencies are in the image already, and a
# fresh isolated env would download torch again — minutes, and the wrong wheel.
PIP_COMMON=( --no-build-isolation )
if (( WITH_DEPS )); then
    PIP_COMMON+=( --extra-index-url "${PYTORCH_INDEX_URL}" )
    export PIP_EXTRA_INDEX_URL="${ASCEND_INDEX_URL}"
else
    PIP_COMMON+=( --no-deps )
fi

# Idempotent, so sourcing it again is free. It adds the devlib directory the
# custom-op build links against.
# shellcheck disable=SC1090
source "${ASCEND_ENV_FILE}" 2>/dev/null \
    || warn "no ${ASCEND_ENV_FILE} — if the kernel build fails to link, that is why"

# ── 3a. what the installs below need to exist first ──────────────────────────
# Both fail during "Preparing editable metadata", before a file is compiled, and
# both read like a problem with your checkout. Neither is.
ensure_git_safe_dirs

ensure_build_deps() {
    local pair mod bin dist want=()
    for pair in ${BUILD_DEPS}; do
        mod="${pair%%:*}"; dist="${pair#*:}"
        python3 -c "import ${mod}" >/dev/null 2>&1 || want+=( "${dist}" )
    done
    # The ones that are RUN rather than imported.
    for pair in ${BUILD_BINS}; do
        bin="${pair%%:*}"; dist="${pair#*:}"
        command -v "${bin}" >/dev/null 2>&1 || want+=( "${dist}" )
    done
    (( ${#want[@]} )) || return 0
    say "build backend missing from this image: ${want[*]}"
    say "  installing it before the editable installs, which use"
    say "  --no-build-isolation and so cannot fetch it themselves."
    PIP_EXTRA_INDEX_URL="${ASCEND_INDEX_URL}" \
        python3 -m pip install "${want[@]}" \
        || die "could not install the build backend: ${want[*]}
    pip needs to reach an index from inside this container. The index and any
    proxy come from a5.env (PIP_INDEX_URL, BUILD_HTTP_PROXY,
    BUILD_HTTPS_PROXY) and apply at container creation, so:
        ./run_container.sh <name> --recreate
    Or install them by hand in here and re-run me:
        python3 -m pip install ${want[*]}
        bash ${DEV_TOOLS_DIR}/bootstrap_editable.sh --force-all"
    say "build backend ok"
}
ensure_build_deps

# Remove the image's own copy BEFORE installing yours: pip replaces an install
# in place only unreliably, and when it gets that wrong you find out from an
# import that silently resolves to the image's tree. purge_husk is the other
# half of the job. see NOTES.md: The husk
displace() {   # displace <dist> <module> <our dir>
    local dist="$1" mod="$2" ours="$3" root kind
    root="$(pkg_root "${mod}")"
    kind="$(pkg_kind "${mod}")"
    # "absent" is tested with pkg_kind, never an empty pkg_root: a husk gives an
    # empty root too, and returning on that is how a container gets stuck.
    [[ "${root}" == "${ours}" ]] && return 0
    [[ "${kind}" == "absent" ]] && return 0
    case "${kind}" in
        namespace) say "the ${mod} python finds is an EMPTY namespace package, not a real
    install — a husk left by an earlier uninstall. pip will report ${dist} as
    not installed; the directory still has to go." ;;
        *)         say "removing the ${dist} the image came with (${root}), so yours can take over" ;;
    esac
    python3 -m pip uninstall -y "${dist}" >/dev/null 2>&1 \
        || warn "pip could not uninstall ${dist} — continuing; the husk sweep below and
    the verification at the end of this script will say whether that mattered."
    # Whatever pip's RECORD did not cover.
    purge_husk "${mod}" "${ours}" || true
}

if (( NEED_VLLM )); then
    displace vllm vllm "${VLLM_DIR}"
    say "installing vllm editable from ${VLLM_DIR} ..."
    ( cd "${VLLM_DIR}" && VLLM_TARGET_DEVICE=empty \
        python3 -m pip install -e . "${PIP_COMMON[@]}" ) \
        || die "editable install of vllm failed (see above).
    Two failures look like a broken checkout and are not:
      * ModuleNotFoundError while 'Preparing editable metadata' — a
        build-backend package this image lacks. Add its module and pip name to
        BUILD_DEPS (see the top of this file).
      * 'detected dubious ownership' / 'git introspection failed' — git
        refusing a tree root does not own. Run me again, or by hand:
            git config --system --add safe.directory '*'"
    # Upstream's recipe runs `pip uninstall -y triton` right here. This does
    # not: the install above is --no-deps, and that import name belongs to
    # triton-ascend, so the uninstall would mutilate it instead.
    ensure_triton
fi

if (( NEED_ASCEND )); then
    [[ -n "${SOC_VERSION}" ]] || die "SOC_VERSION is empty. Set it in ascend-dev-env-a5/a5.env."
    # The ACLNN half needs the catlass submodule, which travels with the mount
    # only if you checked it out. Said now, not deep inside cmake.
    if (( COMPILE_CUSTOM_KERNELS )) && ! have_kernels \
       && [[ ! -d "${VLLM_ASCEND_DIR}/${CATLASS_MARKER}" ]]; then
        die "the kernels need ${CATLASS_MARKER}, which is not checked out.
    On the HOST, not in here:
        git -C ${VLLM_ASCEND_DIR} submodule update --init --recursive
    Then re-run me with --force (the container can stay up)."
    fi
    # setup.py shells out to csrc/build_aclnn.sh, so a carriage return there is
    # fatal and bash blames bash, from inside pip's "Building editable for
    # vllm_ascend" — a long way to travel. Two greps, up front.
    # see NOTES.md: Windows line endings
    if (( COMPILE_CUSTOM_KERNELS )); then
        _crlf=""
        while IFS= read -r _f; do
            [[ -n "${_f}" ]] || continue
            LC_ALL=C grep -qU -e $'\r' "${_f}" 2>/dev/null && _crlf="${_crlf} ${_f#${VLLM_ASCEND_DIR}/}"
        done < <(find "${VLLM_ASCEND_DIR}" -maxdepth 2 -type f -name '*.sh' \
                      -not -path '*/.git/*' -not -path '*/third_party/*' \
                      -not -path '*/build/*' 2>/dev/null)
        [[ -n "${_crlf}" ]] && die "shell script(s) in your checkout have Windows line endings:
       ${_crlf}
    The kernel build runs csrc/build_aclnn.sh, so bash fails on the \r before a
    single kernel is compiled, with a syntax error that names bash:
        csrc/build_aclnn.sh: line 7: syntax error near unexpected token \$'{\\r''
    On the HOST, not in here — and --check first if you want to see the scope:
        bash fix_line_endings.sh ${VLLM_ASCEND_DIR}
    Then re-run me with --force (the container can stay up). To stop it coming
    back, in that checkout:  git config core.autocrlf false && git config core.eol lf"
    fi
    if (( COMPILE_CUSTOM_KERNELS )); then
        # First, because it can remove the whole tree the two checks below
        # inspect — and because its question is the broader one: not "is this
        # cache usable" but "was this output made here, from this source".
        purge_stale_build
        (( CLEAN_KERNELS )) && clean_kernel_build
        if _dead="$(stale_cmake_cache)"; then
            warn "csrc/build/CMakeCache.txt names tool(s) that do not exist in this
    container:${_dead}
    Those paths were recorded by a build in an EARLIER container, and pip
    installs ninja into the interpreter's bin directory — which went away with
    that container, while the cache stayed in your checkout. cmake would fail
    at its first line. Dropping the build tree so it looks again;
    csrc/build_cache keeps the compiled kernels, so this is not a rebuild from
    scratch."
            clean_kernel_build
        fi
        clear_stale_kernel_locks
        # The other way to get "Another process is using this dir": too many
        # compile actions racing for one kernel_meta. vllm-ascend CI passes 32.
        if [[ -z "${MAX_JOBS}" ]]; then
            _cores="$(nproc 2>/dev/null || echo 0)"
            if (( _cores > 32 )); then
                warn "MAX_JOBS is unset, so the kernel build gets one job per core and this
    container has ${_cores}. Besides the memory, that is what produces
        RuntimeError: Another process is using this dir
    from opc when two actions reach the same kernel_meta directory. If this
    build fails that way, bound it (a5.env, or once):
        MAX_JOBS=32 bash ${DEV_TOOLS_DIR}/bootstrap_editable.sh --force"
            fi
        fi
    fi
    displace vllm-ascend vllm_ascend "${VLLM_ASCEND_DIR}"
    say "installing vllm-ascend editable from ${VLLM_ASCEND_DIR}"
    say "  SOC_VERSION=${SOC_VERSION}  COMPILE_CUSTOM_KERNELS=${COMPILE_CUSTOM_KERNELS}"
    if (( COMPILE_CUSTOM_KERNELS )); then
        if have_kernels; then
            say "  kernels are already built in that checkout — cmake is incremental"
        else
            say "  compiling the custom kernels into the mounted tree. This is the slow"
            say "  one: tens of minutes, and it happens once for this checkout."
        fi
    fi
    rm -f "${MARKER}"
    # An array handed to `env`, so an empty MAX_JOBS is simply absent: an inline
    # VAR=${MAYBE_EMPTY} prefix sets it to "", which cmake reads as zero jobs.
    BUILD_ENV=(
        SOC_VERSION="${SOC_VERSION}"
        COMPILE_CUSTOM_KERNELS="${COMPILE_CUSTOM_KERNELS}"
        VLLM_BATCH_INVARIANT=1
        PIP_EXTRA_INDEX_URL="${ASCEND_INDEX_URL}"
        # The checkout's CMakeLists.txt compares torch's version by capturing
        # the stdout of `python -c "import torch; print(torch.__version__)"`,
        # and the torch_npu autoload prints a driver line there first — so the
        # comparison fails naming "DrvMngGetConsoleLogLevel failed. (ret=4)" as
        # the version found. Scoped to this build; a serve still autoloads.
        TORCH_DEVICE_BACKEND_AUTOLOAD=0
    )
    [[ -n "${MAX_JOBS}" ]] && BUILD_ENV+=(
        MAX_JOBS="${MAX_JOBS}"
        CMAKE_BUILD_PARALLEL_LEVEL="${MAX_JOBS}"
    )
    # Same driver line, second victim: the checkout feeds find_package(Torch)
    # from that same capture, so cmake gets a non-path, nothing complains, and
    # it dies with "Could not find a package configuration file provided by
    # Torch". cmake also reads CMAKE_PREFIX_PATH from the ENVIRONMENT, so this
    # fixes the lookup without touching the checkout.
    _torch_cmake="$(torch_cmake_prefix)"
    if [[ -n "${_torch_cmake}" && -f "${_torch_cmake}/Torch/TorchConfig.cmake" ]]; then
        BUILD_ENV+=( CMAKE_PREFIX_PATH="${_torch_cmake}${CMAKE_PREFIX_PATH:+:${CMAKE_PREFIX_PATH}}" )
        say "  torch cmake prefix: ${_torch_cmake}"
    else
        warn "no Torch/TorchConfig.cmake under ${_torch_cmake:-<torch not importable>}.
    find_package(Torch) in the kernel build will fail with \"Could not find a
    package configuration file provided by Torch\". That is a property of this
    IMAGE, not of your checkout: its torch ships no cmake package files. Use an
    image whose torch has share/cmake/Torch, or install a matching torch in the
    container and re-run me with --force."
    fi
    ( cd "${VLLM_ASCEND_DIR}" && \
        env "${BUILD_ENV[@]}" python3 -m pip install -e . "${PIP_COMMON[@]}" ) \
        || die "editable install of vllm-ascend failed (see above)."
    if ! (( COMPILE_CUSTOM_KERNELS )); then
        say "kernels skipped (COMPILE_CUSTOM_KERNELS=0); no marker written."
    elif have_kernels; then
        echo "${BUILD_KEY}" > "${MARKER}"
        say "kernels built; marker written to ${MARKER}"
    else
        warn "install finished but no kernel .so matched ${KERNEL_SO_GLOB} under
    ${VLLM_ASCEND_DIR} — anything that needs the custom ops will fail. Look
    for the cmake output above."
    fi
fi

# ── 4. verify, do not assume ─────────────────────────────────────────────────
# A silently failed install leaves python importing the image's baseline, and
# every number measured after that is quietly wrong. Failing here is cheaper.
FINAL_VLLM="$(pkg_root vllm)"
FINAL_ASCEND="$(pkg_root vllm_ascend)"
FINAL_VLLM_KIND="$(pkg_kind vllm)"
FINAL_ASCEND_KIND="$(pkg_kind vllm_ascend)"

is_bad() {
    [[ "${VLLM_FROM}" == "checkout" && "${FINAL_VLLM}" != "${VLLM_DIR}" ]] && return 0
    [[ "${VLLM_FROM}" == "image"    && -z "${FINAL_VLLM}"              ]] && return 0
    [[ "${FINAL_ASCEND}" != "${VLLM_ASCEND_DIR}" ]] && return 0
    return 1
}

# One more husk sweep, the important one: the install reports success and a
# leftover directory takes the import anyway. Nothing needs reinstalling — the
# pointer pip wrote is correct, just out-voted. Remove it and re-resolve.
if is_bad; then
    say "the install reported success but python resolves elsewhere. Before failing,"
    say "checking for a leftover directory in site-packages that would out-vote it:"
    _swept=0
    if [[ "${VLLM_FROM}" == "checkout" && "${FINAL_VLLM}" != "${VLLM_DIR}" ]]; then
        purge_husk vllm "${VLLM_DIR}" && _swept=1
    fi
    if [[ "${FINAL_ASCEND}" != "${VLLM_ASCEND_DIR}" ]]; then
        purge_husk vllm_ascend "${VLLM_ASCEND_DIR}" && _swept=1
    fi
    if (( _swept )); then
        FINAL_VLLM="$(pkg_root vllm)";               FINAL_VLLM_KIND="$(pkg_kind vllm)"
        FINAL_ASCEND="$(pkg_root vllm_ascend)";      FINAL_ASCEND_KIND="$(pkg_kind vllm_ascend)"
        is_bad || say "that was it — the editable installs were fine and were being shadowed."
    else
        say "  nothing to sweep: no leftover directory, so this is a real failure."
    fi
fi

say "done. vllm -> $(describe_resolution "${FINAL_VLLM}" "${FINAL_VLLM_KIND}") ; vllm_ascend -> $(describe_resolution "${FINAL_ASCEND}" "${FINAL_ASCEND_KIND}")"

if is_bad; then
    # pkg_root has to hide stderr, so ask again loudly and show it.
    for _m in vllm vllm_ascend; do
        echo "    --- find_spec(${_m}), its locations, and import ${_m}:" >&2
        python3 -c "import importlib.util as u; print('        spec:', u.find_spec('${_m}'))" 2>&1 \
            | sed 's/^/    /' >&2
        pkg_locations "${_m}" | sed 's/^/        at: /' >&2
        python3 -c "import ${_m}" 2>&1 | tail -4 | sed 's/^/        /' >&2
    done
    _hv="$(husk_report vllm "${VLLM_DIR}" | tr '\n' ';' | sed 's|;$||')"
    _ha="$(husk_report vllm_ascend "${VLLM_ASCEND_DIR}" | tr '\n' ';' | sed 's|;$||')"
    [[ -n "${_hv}${_ha}" ]] && {
        echo "    --- directories still in site-packages under those names:" >&2
        [[ -n "${_hv}" ]] && echo "        vllm:        ${_hv}" >&2
        [[ -n "${_ha}" ]] && echo "        vllm_ascend: ${_ha}" >&2
    }
    die "python does not import what it should.
    wanted  vllm        : ${VLLM_DIR:-<any importable copy: VLLM_FROM=image>}
            vllm_ascend : ${VLLM_ASCEND_DIR}
    DO NOT run anything in this container yet — python would import the copy
    the image came with (its own, or the baseline under ${UPSTREAM_DIR})
    instead of your checkout, and the results would look plausible and be
    wrong.

    Read the 'spec:' lines above FIRST, because they split this into two very
    different problems:

      origin=None, loader=None, _NamespacePath([...])
          An empty DIRECTORY is winning. The install is fine and is being
          shadowed. I try to remove it automatically; if the line above says I
          could not, the mount is read-only or the file is in use. Remove it
          and nothing else:
              rm -rf <the path in _NamespacePath>
              bash ${DEV_TOOLS_DIR}/bootstrap_editable.sh

      origin=<a path in site-packages or ${UPSTREAM_DIR}>
          A real second install is winning. Two installs of one package
          disagreeing about what they own, which this clears up:
              python3 -m pip uninstall -y vllm vllm-ascend
              bash ${DEV_TOOLS_DIR}/bootstrap_editable.sh --force-all

      spec: None
          Nothing was installed at all. Look at the pip output above; the usual
          cause is a read-only bind mount, so pip could not write the
          .egg-info / __editable__ files into your checkout."
fi