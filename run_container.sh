#!/usr/bin/env bash
# =============================================================================
#  run_container.sh — start, or re-enter, a dev container. The daily script.
#
#  Mounts your vllm and vllm-ascend checkouts at their own absolute host paths,
#  mounts your home at the path it has outside, and has the entrypoint install
#  both checkouts with `pip install -e`. Editing python on the host then changes
#  what runs in the container, with no rebuild.
#
#  It runs ANY image. Point a5.env's IMAGE at one the server already has and
#  skip the build entirely — the container-side scripts come from tools/.
#
#  ─── RECIPES ─────────────────────────────────────────────────────────────────
#
#    ./run_container.sh --dry-run        check paths, checkouts, driver. Starts
#                                        and changes nothing; reports EVERY
#                                        problem, not just the first.
#    ./run_container.sh                  the one you run every day
#    ./run_container.sh exp1             a second, independent container
#    ./run_container.sh dev --recreate   apply changed paths / mounts / devices /
#                                        memory / SOC_VERSION (docker fixes
#                                        those at creation; a running container
#                                        still has the old ones)
#    ./run_container.sh dev --no-attach  start it, stay on the host
#
#  Try anything for one run without editing a file:
#    IMAGE=vllm-ascend:some-tag ./run_container.sh --dry-run
#    DEVICES=0,1 CPUSET=0-63 ./run_container.sh numa0
#    MEM_LIMIT=512g SHM_SIZE=200g ./run_container.sh big
#    COMPILE_CUSTOM_KERNELS=0 ./run_container.sh py     # no kernel build, seconds
#    BOOTSTRAP_ON_START=0 ./run_container.sh dbg --recreate   # debug the bootstrap
#    MOUNT_TOOLS=1 ./run_container.sh dev --recreate    # run your edited tools/
#    ./run_container.sh --env-file profiles/forkA.env forkA   # two forks at once
#
#  NPU plumbing, as flags. Defaults follow the A3 / A5 cluster guide:
#  --privileged, the whole host driver plus firmware, NODRV.
#    ./run_container.sh --device-mode devices --driver-mount lib64
#    ./run_container.sh --device-mode visible --driver-mount none   # Ascend runtime
#    ./run_container.sh --devices 0,1,2,3
#  Also --privileged / --no-privileged, --nodrv / --no-nodrv. A flag you type
#  beats what DEVICE_MODE would imply, and says so.
#
#  ─── ONCE YOU ARE INSIDE ─────────────────────────────────────────────────────
#
#  A normal shell, your home at the same path, so your launch scripts work
#  unchanged:  cd ~/work/myexp && ./serve_qwen.sh
#  NETWORK=host means a port the server binds is the host's port — no -p flags.
#  The container survives your SSH session; your SHELL does not. For a long
#  serve use tmux inside it, or detach:
#      docker exec -d <prefix>-dev bash -lc 'cd ~/work && ./serve.sh >serve.log 2>&1'
#
#  Settings: a5.env's EDIT BLOCK. Reasons and traps: NOTES.md.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${HERE}/load_env.sh" "$@"        # also provides say/warn/die, usage,
set -- ${AEE_ARGS[@]+"${AEE_ARGS[@]}"}   # require_docker, and --help

# ── args ─────────────────────────────────────────────────────────────────────
# --env-file and -h/--help are consumed by load_env.sh above.
SUFFIX="dev"; RECREATE=0; DRY_RUN=0
suffix_set=0
# Whether --privileged / --no-privileged was TYPED: DEVICE_MODE=privileged
# implies it, and a typed flag has to beat an implication.
priv_explicit=0
# A while loop, not a for loop: the NPU toggles take a value. Both --x v and
# --x=v spellings work.
while (( $# )); do
    case "$1" in
        --recreate)        RECREATE=1 ;;
        --no-attach)       ATTACH=0 ;;
        --attach)          ATTACH=1 ;;
        --dry-run)         DRY_RUN=1 ;;
        --privileged)      PRIVILEGED=1; priv_explicit=1 ;;
        --no-privileged)   PRIVILEGED=0; priv_explicit=1 ;;
        --nodrv)           ASCEND_RUNTIME_OPTIONS="NODRV" ;;
        --no-nodrv)        ASCEND_RUNTIME_OPTIONS="" ;;
        --device-mode)     shift; DEVICE_MODE="${1:-}" ;;
        --device-mode=*)   DEVICE_MODE="${1#*=}" ;;
        --driver-mount)    shift; DRIVER_MOUNT="${1:-}" ;;
        --driver-mount=*)  DRIVER_MOUNT="${1#*=}" ;;
        --devices)         shift; DEVICES="${1:-}" ;;
        --devices=*)       DEVICES="${1#*=}" ;;
        -*)                die "unknown flag: $1 (try --help)" ;;
        # The container-name suffix, in any position.
        *)                 (( suffix_set )) && die "unexpected argument: $1"
                           SUFFIX="$1"; suffix_set=1 ;;
    esac
    shift
done
NAME="${NAME_PREFIX}-${SUFFIX}"

# Validated before anything is inspected or started, so a typo costs a second.
case "${DEVICE_MODE}" in
    privileged|devices|visible) ;;
    *) die "DEVICE_MODE must be privileged, devices or visible (got: ${DEVICE_MODE:-<empty>})
    privileged  --privileged, no per-chip flags. What the A3 / A5 guide does.
    devices     one --device per chip, plus the manager nodes.
    visible     -e ASCEND_VISIBLE_DEVICES, for a host that runs the Ascend
                Docker Runtime and does the wiring itself." ;;
esac
case "${DRIVER_MOUNT}" in
    full|lib64|none) ;;
    *) die "DRIVER_MOUNT must be full, lib64 or none (got: ${DRIVER_MOUNT:-<empty>})
    full   the whole ${ASCEND_DRIVER_DIR} plus the firmware directory.
    lib64  lib64 and version.info only.
    none   mount nothing of the driver; the Ascend Docker Runtime provides it." ;;
esac

# ── values that look fine and are not ────────────────────────────────────────
# check_clean, show_bytes and verdict come from load_env.sh.
check_clean IMAGE HOST_HOME HOST_DATA VLLM_DIR VLLM_ASCEND_DIR CONTAINER_HOME \
            SOC_VERSION NAME_PREFIX RUN_USER ASCEND_HOME ASCEND_DRIVER_DIR \
            ASCEND_FIRMWARE_DIR DEV_TOOLS_DIR UPSTREAM_DIR

require_docker

# ── where every way in lands you ─────────────────────────────────────────────
# Computed once and used by all three exec paths, so `cd ~/work/x &&
# run_container.sh` lands in ~/work/x whether the container was created,
# started or re-attached.
WORKDIR="${CONTAINER_HOME}"
case "${PWD}" in
    "${HOST_HOME}"|"${HOST_HOME}"/*|"${HOST_DATA}"|"${HOST_DATA}"/*) WORKDIR="${PWD}" ;;
esac
# -w on a directory the container cannot see fails the exec, so verify first.
enter_container() {
    local w="${WORKDIR}"
    docker exec "${NAME}" test -d "${w}" 2>/dev/null || w=""
    say "entering ${NAME} — exit the shell with Ctrl-D; the container keeps running"
    if [[ -n "${w}" ]]; then exec docker exec -it -w "${w}" "${NAME}" bash -l
    else                     exec docker exec -it "${NAME}" bash -l; fi
}

# ── the bootstrap's verdict, on EVERY path into a container ──────────────────
# The flag holds ok / failed / skipped. Reading it on re-attach and restart too,
# not only on creation, is what stops a shell being handed out in a container
# where python imports the image's code. see NOTES.md: The bootstrap verdict
bootstrap_status() { docker exec "${NAME}" cat "${BOOTSTRAP_DONE_FLAG}" 2>/dev/null; }

# Does the flag belong to the run we are waiting on? There is a window between
# `docker start` returning and the entrypoint deleting the old flag, and reading
# the PREVIOUS run's "ok" inside it is how a container about to fail hands you a
# clean-looking prompt. Containers without `stat` fall back to plain existence.
BOOTSTRAP_EPOCH=0
FLAG_HAS_STAT=-1
flag_ready() {
    if (( FLAG_HAS_STAT < 0 )); then
        if docker exec "${NAME}" sh -c 'command -v stat >/dev/null 2>&1' 2>/dev/null; then
            FLAG_HAS_STAT=1
        else
            FLAG_HAS_STAT=0
        fi
    fi
    if (( FLAG_HAS_STAT )); then
        local mt
        mt="$(docker exec "${NAME}" stat -c %Y "${BOOTSTRAP_DONE_FLAG}" 2>/dev/null)" || return 1
        [[ "${mt}" =~ ^[0-9]+$ ]] || return 1
        (( mt + 2 >= BOOTSTRAP_EPOCH ))
        return $?
    fi
    docker exec "${NAME}" test -f "${BOOTSTRAP_DONE_FLAG}" 2>/dev/null
}

# Stream the container's output until the bootstrap writes its flag. The create
# path passes "all", the start path 0 so a restart does not replay an hour of an
# earlier kernel build.
BOOTSTRAP_TIMED_OUT=0
wait_for_bootstrap() {   # wait_for_bootstrap <tail-arg>
    local tail_arg="${1:-all}" log_pid waited=0
    BOOTSTRAP_TIMED_OUT=0
    say "waiting for the entrypoint bootstrap (Ctrl-C is safe — the container stays up)"
    docker logs -f --tail "${tail_arg}" "${NAME}" 2>&1 &
    log_pid=$!
    while ! flag_ready; do
        sleep 2; waited=$(( waited + 2 ))
        if (( waited >= BOOTSTRAP_TIMEOUT )); then
            BOOTSTRAP_TIMED_OUT=1
            warn "bootstrap still running after ${waited}s — leaving it to finish in the
    background. Watch it with: docker logs -f ${NAME}"
            break
        fi
        [[ "$(docker inspect -f '{{.State.Running}}' "${NAME}" 2>/dev/null)" == "true" ]] || {
            kill "${log_pid}" 2>/dev/null; wait "${log_pid}" 2>/dev/null
            die "${NAME} stopped while bootstrapping.
    See: docker logs ${NAME}"; }
    done
    kill "${log_pid}" 2>/dev/null; wait "${log_pid}" 2>/dev/null
}

# Returns 0 when it is safe to hand over a shell, 1 when it is not. Never
# attaches and never exits, so each caller decides what to do.
report_bootstrap() {
    case "$(bootstrap_status)" in
        ok)      return 0 ;;
        skipped) warn "BOOTSTRAP_ON_START=0 — your checkouts are NOT installed in this
    container. Install them when you are ready:
        docker exec -it ${NAME} bash ${DEV_TOOLS_DIR}/bootstrap_editable.sh"
                 return 0 ;;
        failed)  echo >&2
                 warn "THE BOOTSTRAP FAILED. python in ${NAME} does not import your
    checkouts — do not measure anything in it yet.
        docker logs ${NAME}            # or ${BOOTSTRAP_LOG} inside the container
        docker exec -it ${NAME} bash ${DEV_TOOLS_DIR}/bootstrap_editable.sh --check
        docker exec -it ${NAME} bash ${DEV_TOOLS_DIR}/bootstrap_editable.sh --force-all
    The 'spec:' lines at the end of that log split the diagnosis in two — see
    NOTES.md, 'The bootstrap verdict'. If pip could not reach an index, that is
    PIP_INDEX_URL / BUILD_*_PROXY, and they apply at creation:
        ./run_container.sh ${SUFFIX} --recreate"
                 echo >&2
                 say "the container is up so you can debug it: docker exec -it ${NAME} bash -l"
                 return 1 ;;
        *)       if (( BOOTSTRAP_TIMED_OUT )); then
                     warn "the bootstrap has not finished, so this is NOT attaching — a shell
    in a container whose editable installs are still going up is only
    confusing. Follow it, and come back in when it says it is done:
        docker logs -f ${NAME}
        ./run_container.sh ${SUFFIX}"
                 else
                     warn "the bootstrap left no status behind, so it is not known whether
    python in here imports your checkouts. This is NOT attaching. Check:
        docker logs ${NAME}
        docker exec -it ${NAME} bash ${DEV_TOOLS_DIR}/bootstrap_editable.sh --check"
                 fi
                 return 1 ;;
    esac
}

# ── already there? ───────────────────────────────────────────────────────────
# The commonest command of the day, and it needs no image and no path checks —
# only the bootstrap's verdict, which costs one `docker exec cat`.
existing_state="$(docker inspect -f '{{.State.Status}}' "${NAME}" 2>/dev/null)"
if [[ -n "${existing_state}" ]] && (( ! RECREATE )); then
    case "${existing_state}" in
        running)
            if (( DRY_RUN )); then
                say "${NAME} is already running. Without --dry-run this would check its"
                say "bootstrap status and, if it is ok, attach to it (workdir ${WORKDIR});"
                say "it would NOT re-check paths or re-create anything."
                say "bootstrap status in it: $(bootstrap_status || true)"
                exit 0
            fi
            say "${NAME} is already running."
            # Empty status on a running container means the bootstrap is still
            # going — somebody started it a moment ago. Wait rather than guess.
            if [[ -z "$(bootstrap_status)" ]]; then
                say "its bootstrap has not reported yet — following it."
                BOOTSTRAP_EPOCH=0
                wait_for_bootstrap 0
            fi
            report_bootstrap || exit 1
            (( ATTACH )) && enter_container
            exit 0 ;;
        exited|created)
            if (( DRY_RUN )); then
                say "${NAME} exists and is ${existing_state}. Without --dry-run this would"
                say "start it, wait for the entrypoint bootstrap to report, and attach. Its"
                say "mounts, devices and editable installs stay as they were."
                say "To apply changed settings from a5.env: ./run_container.sh ${SUFFIX} --recreate"
                exit 0
            fi
            # Worth saying, because the opposite is the common assumption:
            # `pip install -e` wrote into this container's writable layer, which
            # a stop keeps. Only --recreate (docker rm) loses it.
            say "${NAME} exists but is ${existing_state} — starting it. Your editable"
            say "installs are still in it; nothing is reinstalled or rebuilt."
            BOOTSTRAP_EPOCH="$(date +%s)"
            docker start "${NAME}" >/dev/null || die "could not start ${NAME}"
            # The entrypoint runs AGAIN on a start, so its verdict is new. Usually
            # "Nothing to do" in under a second, but it can also repair a damaged
            # triton or fail, and an immediate exec would race it either way.
            wait_for_bootstrap 0
            report_bootstrap || exit 1
            (( ATTACH )) && enter_container
            exit 0 ;;
        *)
            die "${NAME} is in state '${existing_state}'. Use --recreate, or
    sort it out with ./manage_containers.sh." ;;
    esac
fi

# ── from here we are creating a container, so the image matters ──────────────
IMG_KIND=""; IMG_TOOLS=""; IMG_UPSTREAM=""; IMG_SOC=""; IMG_SEED=""; IMG_BASE=""
IMG_BASE_KIND=""
# IDENTITY FIRST, LABELS SECOND, and never the two in one command: a single
# inspect with a label template and `2>/dev/null || die "not on this box"` turns
# every unrelated docker failure into one confident sentence that is false, about
# an image sitting in `docker images`. see NOTES.md: IMAGE, and the stray `\r`
_ins_err="$(mktemp 2>/dev/null)" || _ins_err="/tmp/.vllm-dev-inspect.$$"
IMG_ID="$(docker image inspect "${IMAGE}" --format '{{.Id}}' 2>"${_ins_err}")"
if [[ -z "${IMG_ID}" ]]; then
    _err="$(sed 's/^/        /' "${_ins_err}" 2>/dev/null)"
    rm -f "${_ins_err}"
    # `docker images` is a different code path with a trivial template, so it
    # answers "is it here" without depending on what just failed.
    _refs="$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null)"
    _ids="$(docker images --format '{{.Repository}}:{{.Tag}} {{.ID}}' 2>/dev/null)"
    if printf '%s\n' "${_refs}" | grep -qxF -- "${IMAGE}"; then
        # It IS here. Carry on rather than refuse over a failure that says
        # nothing about the image.
        IMG_ID="$(printf '%s\n' "${_ids}" | awk -v r="${IMAGE}" '$1==r{print $2; exit}')"
        warn "docker lists ${IMAGE} but \`docker image inspect\` on it failed:
${_err:-        (docker printed nothing)}
    The image is here, so this is not a missing image and nothing needs
    building. Continuing with the id \`docker images\` reports (${IMG_ID:-unknown});
    its labels could not be read, so its baked-in dev scripts and SoC default
    are treated as absent — the same as any image this bundle did not build."
    else
        # Not listed under that exact reference. A long registry reference
        # pasted by hand is wrong by one character far more often than absent.
        _near="$(printf '%s\n' "${_refs}" | grep -iF -- "${IMAGE##*:}" | head -5)"
        [[ -n "${_near}" ]] || _near="$(printf '%s\n' "${_refs}" | grep -iF -- "${IMAGE##*/}" | head -5)"
        [[ -n "${_near}" ]] || _near="$(printf '%s\n' "${_refs}" | grep -iF -- "${IMAGE%%:*}" | head -5)"
        die "image ${IMAGE} is not on this box under that reference, and nothing was pulled.
        you asked for : $(show_bytes "${IMAGE}")
    docker said:
${_err:-        (docker printed nothing)}
$( [[ -n "${_near}" ]] && { echo "    references here that look like it — compare character by character:"
                            printf '%s\n' "${_near}" | sed 's/^/        /'; } )
    Cheapest way out first — any CANN / vllm-ascend image here will do, even a
    colleague's, because your code is mounted into it and not baked:
        ./probe_image.sh --list
        IMAGE=<the exact ref> ./run_container.sh --dry-run
    Or build one:  ./build_image.sh"
    fi
else
    rm -f "${_ins_err}"
fi

# The labels, separately. A failure here means only "no labels we recognise",
# which is the normal case for an image we did not build.
img_labels="$(docker image inspect "${IMAGE}" \
    --format '{{range $k, $v := .Config.Labels}}{{$k}}={{$v}}{{println}}{{end}}' 2>/dev/null)" \
    || img_labels=""
while IFS='=' read -r k v; do
    case "$k" in
        vllm-ascend-dev.kind)         IMG_KIND="$v" ;;
        vllm-ascend-dev.tools-dir)    IMG_TOOLS="$v" ;;
        vllm-ascend-dev.upstream-dir) IMG_UPSTREAM="$v" ;;
        vllm-ascend-dev.soc-default)  IMG_SOC="$v" ;;
        vllm-ascend-dev.seed-deps)    IMG_SEED="$v" ;;
        vllm-ascend-dev.base-image)   IMG_BASE="$v" ;;
        vllm-ascend-dev.base-kind)    IMG_BASE_KIND="$v" ;;
    esac
done < <(printf '%s\n' "${img_labels}")
# The image knows where its own scripts and baseline are; trust that over
# a5.env, which may describe a different image than the one you are running.
[[ -n "${IMG_TOOLS}"    ]] && DEV_TOOLS_DIR="${IMG_TOOLS}"
[[ -n "${IMG_UPSTREAM}" ]] && UPSTREAM_DIR="${IMG_UPSTREAM}"

# ── one look INSIDE the image, for the two things labels cannot tell us ──────
# A throwaway container (--rm, no network, no NPU, nothing mounted), about a
# second, only on the path that creates a container:
#   * the image's PYTHON VERSION — a third of the kernel marker's key, so
#     predicting without it promises "seconds" and delivers a rebuild.
#     see NOTES.md: The kernel marker, and "first start is seconds"
#   * the CHECKSUMS of the container-side scripts it carries, which is the only
#     way to answer "why is my edit to tools/ doing nothing?".
PROBE_OK=0; PROBE_PY="unknown"; PROBE_TOOLS=""
probe_image() {
    local out tmo=()
    command -v timeout >/dev/null 2>&1 && tmo=( timeout 120 )
    out="$("${tmo[@]}" docker run --rm --network none \
            -e "TD=${DEV_TOOLS_DIR}" --entrypoint bash "${IMAGE}" -c '
        py=$(python3 -c "import sys;print(\"%d.%d\"%sys.version_info[:2])" 2>/dev/null) || py=""
        printf "py=%s\n" "${py:-unknown}"
        for f in entrypoint.sh bootstrap_editable.sh ascend_env.sh probe_in_container.sh; do
            if [ -f "$TD/$f" ]; then
                printf "tool=%s:%s\n" "$f" "$(md5sum < "$TD/$f" 2>/dev/null | cut -d" " -f1)"
            else
                printf "tool=%s:ABSENT\n" "$f"
            fi
        done' 2>/dev/null)" || return 1
    [[ -n "${out}" ]] || return 1
    local line
    while IFS= read -r line; do
        case "${line}" in
            py=*)   PROBE_PY="${line#py=}" ;;
            tool=*) PROBE_TOOLS+="${line#tool=} " ;;
        esac
    done <<< "${out}"
    PROBE_OK=1
    return 0
}
probe_image || warn "could not look inside ${IMAGE} (no bash, or docker run refused it).
    Carrying on: the kernel-freshness prediction below falls back to the SoC and
    the image only, so it cannot see a python change, and the tools/ staleness
    check is skipped."
probe_tool() {   # probe_tool <filename>  -> md5 | ABSENT | <empty if unknown>
    local f="$1" t
    for t in ${PROBE_TOOLS}; do
        [[ "${t%%:*}" == "${f}" ]] && { printf '%s' "${t#*:}"; return; }
    done
}

# ── where do the container-side scripts come from? ───────────────────────────
# Bind-mounting them from tools/ is the trick that lets a stock vllm-ascend
# image be used with no build and no modification.
# see NOTES.md: MOUNT_TOOLS — whose tools/ actually runs
case "${MOUNT_TOOLS}" in
    auto) [[ -n "${IMG_TOOLS}" ]] && TOOLS_FROM="image" || TOOLS_FROM="host" ;;
    1)    TOOLS_FROM="host" ;;
    0)    TOOLS_FROM="image" ;;
    *)    die "MOUNT_TOOLS must be auto, 0 or 1 (got: ${MOUNT_TOOLS}). Fix it in a5.env." ;;
esac
if [[ -n "${IMG_KIND}" ]]; then
    IMG_DESC="  (${IMG_KIND})"
else
    IMG_DESC="  (not built by ./build_image.sh — used as-is)"
fi

PROBLEMS=()
problem() { PROBLEMS+=( "$*" ); }

if [[ "${TOOLS_FROM}" == "host" ]]; then
    [[ -f "${HERE}/tools/entrypoint.sh" ]] \
        || die "${HERE}/tools/entrypoint.sh is missing — this bundle is incomplete."
    [[ -f "${HERE}/tools/bootstrap_editable.sh" ]] \
        || die "${HERE}/tools/bootstrap_editable.sh is missing — this bundle is incomplete."
    TOOLS_NOTE="mounted read-only from ${HERE}/tools"
else
    TOOLS_NOTE="baked into the image at ${DEV_TOOLS_DIR}"
    # The label says the scripts are in there. If they are not, docker starts a
    # container that dies a quarter of a second later with the only clue in
    # `docker logs`. Cheaper to say now.
    if (( PROBE_OK )); then
        for f in entrypoint.sh bootstrap_editable.sh; do
            [[ "$(probe_tool "$f")" == "ABSENT" ]] && problem \
"${IMAGE} is labelled as carrying the dev scripts at ${DEV_TOOLS_DIR}, but
      ${DEV_TOOLS_DIR}/${f} is not in it. The label is wrong (a retag, or a
      hand-built image). Use this bundle's copies instead:
          MOUNT_TOOLS=1 ./run_container.sh ${SUFFIX} --recreate"
        done
    fi
    # The silent trap: your edit to tools/ is not what will run.
    if (( PROBE_OK )) && command -v md5sum >/dev/null 2>&1; then
        STALE_TOOLS=""
        for f in entrypoint.sh bootstrap_editable.sh ascend_env.sh probe_in_container.sh; do
            [[ -f "${HERE}/tools/${f}" ]] || continue
            img_md5="$(probe_tool "$f")"
            [[ -n "${img_md5}" && "${img_md5}" != "ABSENT" ]] || continue
            host_md5="$(md5sum < "${HERE}/tools/${f}" | cut -d' ' -f1)"
            [[ "${host_md5}" == "${img_md5}" ]] || STALE_TOOLS+=" ${f}"
        done
        if [[ -n "${STALE_TOOLS}" ]]; then
            warn "tools/ on this host DIFFERS from the copies baked into ${IMAGE}:
   ${STALE_TOOLS}
    MOUNT_TOOLS=${MOUNT_TOOLS} means the IMAGE's copies are what run, so your
    edits to those files will have NO effect in this container. Pick one:
        MOUNT_TOOLS=1 ./run_container.sh ${SUFFIX} --recreate   # run yours now, no rebuild
        ./build_image.sh                                        # bake yours in"
        fi
    fi
fi

# No labels is the NORMAL case for an image you did not build, not an error.
if [[ -z "${IMG_KIND}" ]]; then
    say "${IMAGE} was not built by ./build_image.sh — using it exactly as it is."
    say "container-side scripts: ${TOOLS_NOTE}"
    say "what is in it, and whether that is enough: ./probe_image.sh ${IMAGE}"
fi

# ── check everything, then report everything, THEN destroy anything ──────────
# Problems are collected, not fatal one at a time, and the --recreate removal
# happens after all of them. see NOTES.md: Check everything, then destroy anything
require_abs() {   # a relative path reaches docker as a volume NAME, not a path
    local var="$1" path="$2"
    [[ "${path}" == /* ]] || problem "${var} must be an absolute path, got: ${path}
      A relative path becomes a docker volume name, not a directory. Fix it in
      ascend-dev-env-a5/a5.env."
}

MOUNT_ARGS=(); MOUNTED_SRCS=(); MOUNT_LINES=()
covered() {
    local p="$1" s
    for s in ${MOUNTED_SRCS[@]+"${MOUNTED_SRCS[@]}"}; do
        [[ "$p" == "$s" || "$p" == "$s"/* ]] && return 0
    done
    return 1
}
# Every mount is recorded once, here, so the summary prints exactly what docker
# is given. A path already inside another mount gets no -v of its own — it would
# work, but it is a second mount point for one directory.
mount_rw() {
    if covered "$1"; then
        MOUNTED_SRCS+=( "$1" )
        MOUNT_LINES+=( "$1   (already inside a mount above — no second -v needed)" )
        return
    fi
    MOUNT_ARGS+=( -v "$1:$1" ); MOUNTED_SRCS+=( "$1" ); MOUNT_LINES+=( "$1 -> $1" )
}

require_abs "HOST_HOME" "${HOST_HOME}"
[[ -d "${HOST_HOME}" ]] || problem "HOST_HOME does not exist: ${HOST_HOME}
      Set it in a5.env's EDIT BLOCK."
mount_rw "${HOST_HOME}"

require_abs "HOST_DATA" "${HOST_DATA}"
if [[ -d "${HOST_DATA}" ]]; then
    mount_rw "${HOST_DATA}"
else
    warn "HOST_DATA does not exist: ${HOST_DATA} — not mounting it. Model weights
    will not be reachable until you fix it in a5.env's EDIT BLOCK."
fi

for m in ${EXTRA_MOUNTS}; do
    src="${m%%:*}"
    [[ -e "${src}" ]] || { warn "EXTRA_MOUNTS entry skipped, no such path: ${src}"; continue; }
    MOUNT_ARGS+=( -v "${m}" ); MOUNTED_SRCS+=( "${src}" )
    MOUNT_LINES+=( "${src} -> ${m#*:}" )
done

# The container-side scripts, when the image does not carry them. Read-only, and
# deliberately NOT in MOUNTED_SRCS: it is not a place your checkouts can live,
# and letting it "cover" one would be a trap.
if [[ "${TOOLS_FROM}" == "host" ]]; then
    require_abs "DEV_TOOLS_DIR" "${DEV_TOOLS_DIR}"
    MOUNT_ARGS+=( -v "${HERE}/tools:${DEV_TOOLS_DIR}:ro" )
    MOUNT_LINES+=( "${HERE}/tools -> ${DEV_TOOLS_DIR}   (ro: the dev scripts)" )
fi

# ── the checkouts ────────────────────────────────────────────────────────────
# They are not in the image. They have to exist here, and be inside something we
# mount, or they simply will not be in the container.
check_checkout() {   # check_checkout VAR path marker...
    local var="$1" path="$2"; shift 2
    local m found=0
    require_abs "${var}" "${path}"
    if [[ ! -d "${path}" ]]; then
        problem "${var} does not exist on this host: ${path}
      This bundle does not put code in the image — your checkout IS the code,
      so it has to be here. Clone it, or fix the path in a5.env's EDIT BLOCK."
        return
    fi
    for m in "$@"; do [[ -e "${path}/${m}" ]] && { found=1; break; }; done
    (( found )) || problem "${path} contains none of: $* — that is not a ${var}
      checkout. Check the path in a5.env's EDIT BLOCK."
    # Both the editable install and the kernel build WRITE into a checkout, so
    # two people sharing one overwrite each other and each start rebuilds.
    # see NOTES.md: Sharing an image, and never sharing a checkout
    # Skipped as root, where every file looks foreign.
    if [[ "$(id -u)" != "0" ]] && command -v stat >/dev/null 2>&1; then
        local owner; owner="$(stat -c '%U' "${path}" 2>/dev/null)"
        if [[ -n "${owner}" && "${owner}" != "$(id -un)" ]]; then
            warn "${var} (${path}) belongs to ${owner}, not you. Both the editable
    install and the kernel build write into a checkout, so sharing one means
    overwriting each other — and a different image or SoC on either side makes
    every start rebuild the kernels. Clone your own, or proceed knowing this."
        fi
    fi
    # pip writes .egg-info / __editable__ files here and the kernel build writes
    # the .so and the marker. A tree you cannot write to fails deep inside
    # "Preparing editable metadata", where it reads as a broken checkout.
    if [[ -d "${path}" && ! -w "${path}" ]]; then
        problem "${var} (${path}) is not writable by you. The editable install writes
      its metadata there and the kernel build writes the .so and the marker, so
      this fails inside pip with an error that looks like a broken checkout.
      Fix the permissions, or clone your own."
    fi
    if covered "${path}"; then
        mount_rw "${path}"
    else
        problem "${var} (${path}) is outside every mount, so it would not exist
      inside the container. Either move it under ${HOST_HOME}, or add it to
      EXTRA_MOUNTS in a5.env.local:
          EXTRA_MOUNTS=\"\${EXTRA_MOUNTS:-${path}:${path}}\""
    fi
}

# The checkout's own shell scripts have to be runnable: the kernel build shells
# out to csrc/build_aclnn.sh, so a \r there is fatal and reports itself as a bash
# syntax error after pip has reached "Building editable for vllm_ascend".
# see NOTES.md: Windows line endings
crlf_scripts() {   # crlf_scripts <checkout> -> offending paths, relative
    local d="$1" f
    [[ -d "${d}" ]] || return 0
    while IFS= read -r f; do
        [[ -n "${f}" ]] || continue
        LC_ALL=C grep -qU -e $'\r' "${f}" 2>/dev/null && printf '%s ' "${f#${d}/}"
    done < <(find "${d}" -maxdepth 2 -type f -name '*.sh' \
                  -not -path '*/.git/*' -not -path '*/third_party/*' \
                  -not -path '*/build/*' 2>/dev/null)
}
# Blocking only when the kernels are actually going to be built.
check_crlf() {   # check_crlf <VAR> <checkout>
    local bad; bad="$(crlf_scripts "$2")"
    [[ -n "${bad}" ]] || return 0
    local msg="$1 has shell script(s) with Windows line endings: ${bad}
      bash cannot run them. Fix it on the HOST (--check first to see the scope):
          bash ${HERE}/fix_line_endings.sh $2
      and to stop it recurring, in that checkout:
          git config core.autocrlf false && git config core.eol lf"
    if (( COMPILE_CUSTOM_KERNELS )); then problem "${msg}"; else warn "${msg}"; fi
}

# vllm-ascend is the point of the exercise: always yours, always required.
check_checkout "VLLM_ASCEND_DIR" "${VLLM_ASCEND_DIR}" "setup.py"
check_crlf "VLLM_ASCEND_DIR" "${VLLM_ASCEND_DIR}"

case "${VLLM_FROM}" in
    checkout)
        check_checkout "VLLM_DIR" "${VLLM_DIR}" "setup.py" "pyproject.toml"
        vllm_desc="${VLLM_DIR}   ($(verdict "${VLLM_DIR}"), editable, live)" ;;
    image)
        # Only an image we built can tell us it has no vllm in it. A stock
        # vllm-ascend image has one and carries no label to say so.
        if [[ -n "${IMG_KIND}" && "${IMG_SEED}" == "0" && "${IMG_BASE_KIND}" != "ready" ]]; then
            problem "VLLM_FROM=image, but this image was built with SEED_DEPS=0 and
      has no vllm in it. Either set VLLM_FROM=checkout with a real VLLM_DIR:
          git clone -b ${UPSTREAM_VLLM_TAG} ${UPSTREAM_VLLM_REPO} ${HOST_HOME}/code/vllm
      or rebuild with SEED_DEPS=1."
        fi
        vllm_desc="the copy in the image — your VLLM_DIR is not mounted"
        say "VLLM_FROM=image: vllm comes from the image's upstream baseline. Your"
        say "edits to vllm will NOT be live. Set VLLM_FROM=checkout to change that." ;;
    *)  problem "VLLM_FROM must be 'checkout' or 'image', got: ${VLLM_FROM}"
        vllm_desc="<invalid VLLM_FROM>" ;;
esac

# A mount over the image's own baseline would hide it.
if [[ -n "${UPSTREAM_DIR}" ]] && covered "${UPSTREAM_DIR}"; then
    problem "one of your mounts covers ${UPSTREAM_DIR}, where the image keeps its
      upstream dependency baseline. That would hide it. Move the mount, or set
      UPSTREAM_DIR elsewhere and rebuild."
fi

# ── will the first start compile the kernels? ────────────────────────────────
# Asked the same way the container will decide it, with the same three-part key,
# so the two cannot disagree. For an image we built the BASE reference is used,
# so a CANN change reached by overriding BASE_IMAGE is visible; for any other
# image its own id, which also changes when a tag is re-pulled onto new content.
# see NOTES.md: The kernel marker, and "first start is seconds"
IMAGE_KEY="${IMG_BASE:-${IMG_ID:0:19}}"
BUILD_KEY="soc=${SOC_VERSION};py=${PROBE_PY};img=${IMAGE_KEY}"

# When the image's python is known this is the container's exact string
# comparison. When it is not, it falls back to the two facts we do have.
kernel_state() {
    compgen -G "${VLLM_ASCEND_DIR}/${KERNEL_SO_GLOB}" >/dev/null 2>&1 || { echo missing; return; }
    local mk="${VLLM_ASCEND_DIR}/${KERNEL_MARKER}"
    [[ -f "${mk}" ]] || { echo stale; return; }
    if [[ "${PROBE_PY}" != "unknown" ]]; then
        [[ "$(cat "${mk}" 2>/dev/null)" == "${BUILD_KEY}" ]] && echo built || echo stale
        return
    fi
    grep -q "soc=${SOC_VERSION};" "${mk}" 2>/dev/null || { echo stale; return; }
    if [[ -n "${IMAGE_KEY}" ]] && ! grep -qF "img=${IMAGE_KEY}" "${mk}" 2>/dev/null; then
        echo stale; return
    fi
    echo built
}
if [[ ! -d "${VLLM_ASCEND_DIR}" ]]; then
    # Already reported above; saying anything about its kernels would be noise.
    KERNELS_NOTE="unknown (fix VLLM_ASCEND_DIR first)"
elif (( ! COMPILE_CUSTOM_KERNELS )); then
    KERNELS_NOTE="disabled (COMPILE_CUSTOM_KERNELS=0)"
    warn "COMPILE_CUSTOM_KERNELS=0 — the custom kernels will NOT be built. The
    container comes up in seconds and python edits work, but anything that
    needs the custom ops will fail."
else
    KERNEL_STATE="$(kernel_state)"
    case "${KERNEL_STATE}" in
        built)
            KERNELS_NOTE="already built in your checkout — first start is seconds"
            say "kernels: already built for this SoC, python and image — first start is seconds" ;;
        stale)
            KERNELS_NOTE="WILL BE REBUILT (the marker does not match this SoC / python / image)"
            warn "the kernels in ${VLLM_ASCEND_DIR} were built for something else, so the
    first start REBUILDS them — tens of minutes, once.
        marker wants : ${BUILD_KEY}
        marker holds : $( [[ -f "${VLLM_ASCEND_DIR}/${KERNEL_MARKER}" ]] \
                            && cat "${VLLM_ASCEND_DIR}/${KERNEL_MARKER}" \
                            || echo '<no marker file>' )
    Watch it with: docker logs -f ${NAME}" ;;
        missing)
            KERNELS_NOTE="WILL BE BUILT on first start"
            warn "that vllm-ascend checkout has no built kernels yet, so the first
    start COMPILES THEM INTO IT — tens of minutes, once per checkout. Every
    later start of every later container on it is seconds. Watch it with:
        docker logs -f ${NAME}" ;;
    esac
    if [[ ! -d "${VLLM_ASCEND_DIR}/${CATLASS_MARKER}" && "${KERNEL_STATE}" != "built" ]]; then
        problem "the kernel build needs ${CATLASS_MARKER}, which is not checked out.
      On the HOST:  git -C ${VLLM_ASCEND_DIR} submodule update --init --recursive"
    fi
fi

# ── NPU devices ──────────────────────────────────────────────────────────────
# "All NPUs" = every /dev/davinci<N> the host exposes. How those map to physical
# chips is per family (on A3, one chip = two dies = two nodes), so check
# `npu-smi info` before handing out subsets.
DEV_ARGS=()
if [[ "${DEVICES}" == "auto" ]]; then
    mapfile -t davinci < <(ls -1 /dev/davinci[0-9]* 2>/dev/null | sort -V)
    (( ${#davinci[@]} )) || warn "no /dev/davinci* on this host — the container
    will start, but it will have no NPU. That is the Ascend DRIVER, which is a
    property of the machine and cannot come from the image."
else
    IFS=',' read -r -a davinci <<< "${DEVICES}"
    for i in "${!davinci[@]}"; do davinci[$i]="/dev/davinci${davinci[$i]}"; done
    for d in "${davinci[@]}"; do
        [[ -e "$d" ]] || problem "${d} does not exist on this host (DEVICES=${DEVICES})"
    done
fi
NPU_COUNT=${#davinci[@]}
# The bare ids, for ASCEND_VISIBLE_DEVICES: /dev/davinci3 -> 3.
VISIBLE_IDS=""
for d in ${davinci[@]+"${davinci[@]}"}; do
    VISIBLE_IDS+="${VISIBLE_IDS:+,}${d#/dev/davinci}"
done

# ── and HOW they reach it ────────────────────────────────────────────────────
# Which mode works is a property of the host, not of this bundle.
# see NOTES.md: DEVICE_MODE and DRIVER_MOUNT
case "${DEVICE_MODE}" in
    privileged)
        # An implication, not an override: a typed --no-privileged has to win,
        # or the flag silently does nothing at all.
        if (( priv_explicit )) && ! (( PRIVILEGED )); then
            warn "DEVICE_MODE=privileged normally implies --privileged, but you passed
    --no-privileged, so it stays OFF. Without it this mode hands over no chips
    at all. Use --device-mode devices if that is what you meant."
            DEVICE_NOTE="DEVICE_MODE=privileged but --no-privileged was passed: NO chips handed over"
        else
            PRIVILEGED=1
            DEVICE_NOTE="--privileged, no per-chip flags (the A3 / A5 guide)"
        fi ;;
    devices)
        for d in ${davinci[@]+"${davinci[@]}"}; do DEV_ARGS+=( --device "$d" ); done
        # Manager / memory / HDC nodes: required for any NPU access at all.
        for d in /dev/davinci_manager /dev/davinci_manager_docker /dev/devmm_svm /dev/hisi_hdc; do
            [[ -e "$d" ]] && DEV_ARGS+=( --device "$d" )
        done
        DEVICE_NOTE="one --device per chip + the manager nodes" ;;
    visible)
        [[ -n "${VISIBLE_IDS}" ]] || problem "DEVICE_MODE=visible needs chip ids, and no
      /dev/davinci* was found on this host. Name them with --devices 0,1 if the
      nodes live somewhere this script cannot see them."
        DEVICE_NOTE="-e ASCEND_VISIBLE_DEVICES=${VISIBLE_IDS} (Ascend Docker Runtime wires it)" ;;
esac

# ── the host's driver files ──────────────────────────────────────────────────
# HOST paths, from the driver install. The CANN toolkit is in the image and is
# not looked for here. Recorded in MOUNT_LINES as well as MOUNT_ARGS so the
# report shows them — their absence is exactly what you want to see when the
# runtime says the driver module failed. Deliberately NOT in MOUNTED_SRCS.
add_ro()  { [[ -e "$1" ]] && { MOUNT_ARGS+=( -v "$1:$1:ro" ); MOUNT_LINES+=( "$1 -> $1   (ro: driver)" ); } \
                          || warn "driver file missing on host, not mounted: $1"; }
# Silent when absent: per-family / per-topology files.
add_opt() { [[ -e "$1" ]] && { MOUNT_ARGS+=( -v "$1:$1:ro" ); MOUNT_LINES+=( "$1 -> $1   (ro: optional)" ); }; }
# Read-write, as the A3 / A5 guide mounts driver and firmware: the driver writes
# into its own tree, and a read-only mount has been seen to fail in ways that
# look like a broken driver install.
add_rw()  { [[ -e "$1" ]] && { MOUNT_ARGS+=( -v "$1:$1" );    MOUNT_LINES+=( "$1 -> $1   (rw: driver)" ); } \
                          || warn "driver path missing on host, not mounted: $1"; }

case "${DRIVER_MOUNT}" in
    full)
        # The whole driver tree PLUS the firmware. lib64 alone is enough to link
        # against and not enough to talk to the hardware, which surfaces as "An
        # internal error occurs in the Driver module", not as a missing file.
        add_rw "${ASCEND_DRIVER_DIR}"
        add_rw "${ASCEND_FIRMWARE_DIR}"
        for p in ${DRIVER_RO_MOUNTS};   do add_ro  "$p"; done ;;
    lib64)
        add_ro "${ASCEND_DRIVER_DIR}/lib64"
        add_ro "${ASCEND_DRIVER_DIR}/version.info"
        for p in ${DRIVER_RO_MOUNTS};   do add_ro  "$p"; done ;;
    none)
        say "DRIVER_MOUNT=none — mounting nothing of the host driver. Only right on
    a host whose Ascend Docker Runtime injects it (DEVICE_MODE=visible)." ;;
esac
for p in ${OPTIONAL_RO_MOUNTS}; do add_opt "$p"; done

# With DRIVER_MOUNT=none nobody would mount the driver at all, so NODRV (which
# tells the Ascend Docker Runtime not to either) has to go.
if [[ "${DRIVER_MOUNT}" == "none" && "${ASCEND_RUNTIME_OPTIONS}" == *NODRV* ]]; then
    warn "DRIVER_MOUNT=none with ASCEND_RUNTIME_OPTIONS=${ASCEND_RUNTIME_OPTIONS} would leave
    the container with no driver at all. Dropping NODRV."
    ASCEND_RUNTIME_OPTIONS=""
fi

# ── memory / cpu ─────────────────────────────────────────────────────────────
# Docker gives a container ALL host RAM unless --memory says otherwise, so the
# default is no --memory at all. /dev/shm is the one that bites: docker's default
# is 64m and vLLM's workers need far more.
host_mem_gb=$(awk '/MemTotal/{printf "%d", int($2/1024/1024)}' /proc/meminfo 2>/dev/null || echo 0)
if [[ "${SHM_SIZE}" == "auto" ]]; then
    shm="$(( host_mem_gb / 2 ))g"
    [[ "${shm}" == "0g" ]] && shm="64g"
else
    shm="${SHM_SIZE}"
fi
RES_ARGS=( --shm-size "${shm}"
           --ulimit memlock=-1 --ulimit stack=67108864 --ulimit nofile=65536 )
[[ -n "${MEM_LIMIT}" ]] && RES_ARGS+=( --memory "${MEM_LIMIT}" --memory-swap "${MEM_LIMIT}" )
[[ -n "${CPUS}"      ]] && RES_ARGS+=( --cpus "${CPUS}" )
[[ -n "${CPUSET}"    ]] && RES_ARGS+=( --cpuset-cpus "${CPUSET}" )
(( PRIVILEGED )) && RES_ARGS+=( --privileged )
# gdb / py-spy / msprof need to look at other processes.
(( DEBUG_CAPS )) && RES_ARGS+=( --cap-add=SYS_PTRACE --security-opt seccomp=unconfined )

# ── network ──────────────────────────────────────────────────────────────────
NET_ARGS=( --network "${NETWORK}" )
if [[ "${NETWORK}" != "host" ]]; then
    for p in ${PUBLISH_PORTS}; do NET_ARGS+=( -p "$p" ); done
elif [[ -n "${PUBLISH_PORTS}" ]]; then
    warn "PUBLISH_PORTS is ignored with NETWORK=host (every port is already the host's)."
fi

# ── environment ──────────────────────────────────────────────────────────────
# Loopback AND this host's own names must never go through a proxy: with
# NETWORK=host, vLLM's workers, ray and the EP/DP handshakes talk to the box by
# its real address, and an http_proxy set for pip swallows that traffic too.
# Deliberately no `hostname -f` — it resolves, and blocks for the whole resolver
# timeout on a node whose DNS is unreachable.
# see NOTES.md: no_proxy must cover this host's own names
host_self_names() {
    local n a
    printf '%s\n' 127.0.0.1 localhost ::1
    n="$(hostname 2>/dev/null)";    [[ -n "${n}" ]] && printf '%s\n' "${n}"
    n="$(hostname -s 2>/dev/null)"; [[ -n "${n}" ]] && printf '%s\n' "${n}"
    if n="$(hostname -I 2>/dev/null)"; then
        for a in ${n}; do printf '%s\n' "${a}"; done
    fi
    return 0
}
NO_PROXY_LIST="$( { host_self_names; printf '%s\n' ${NO_PROXY_HOSTS//,/ }; } \
                 | awk 'NF && !seen[$0]++' | paste -sd,)"

ENV_ARGS=(
    -e "HOME=${CONTAINER_HOME}"
    -e "SOC_VERSION=${SOC_VERSION}"
    -e "VLLM_ASCEND_DIR=${VLLM_ASCEND_DIR}"
    -e "VLLM_FROM=${VLLM_FROM}"
    -e "COMPILE_CUSTOM_KERNELS=${COMPILE_CUSTOM_KERNELS}"
    -e "KERNEL_SO_GLOB=${KERNEL_SO_GLOB}"
    -e "KERNEL_MARKER=${KERNEL_MARKER}"
    -e "CATLASS_MARKER=${CATLASS_MARKER}"
    -e "DEV_TOOLS_DIR=${DEV_TOOLS_DIR}"
    # An image we did not build ENVs whatever it likes, so a5.env's value for
    # where CANN is gets passed either way.
    -e "ASCEND_HOME=${ASCEND_HOME}"
    -e "UPSTREAM_DIR=${UPSTREAM_DIR}"
    # The image half of the kernel marker, passed rather than read from inside,
    # so an image with no image-info.env still gets an honest staleness key.
    -e "IMAGE_REF=${IMAGE_KEY}"
    -e "PIP_PINS=${PIP_PINS}"
    -e "PIP_GUARD_PACKAGES=${PIP_GUARD_PACKAGES}"
    -e "ASCEND_JEMALLOC=${ASCEND_JEMALLOC}"
    -e "BOOTSTRAP_ON_START=${BOOTSTRAP_ON_START}"
    -e "BOOTSTRAP_LOG=${BOOTSTRAP_LOG}"
    -e "BOOTSTRAP_DONE_FLAG=${BOOTSTRAP_DONE_FLAG}"
    -e "PYTORCH_INDEX_URL=${PYTORCH_INDEX_URL}"
    -e "ASCEND_INDEX_URL=${ASCEND_INDEX_URL}"
    -e "no_proxy=${NO_PROXY_LIST}"
    -e "NO_PROXY=${NO_PROXY_LIST}"
)
# VLLM_DIR only means something when it is your checkout.
[[ "${VLLM_FROM}" == "checkout" ]] && ENV_ARGS+=( -e "VLLM_DIR=${VLLM_DIR}" )
# Forwarded ONLY when set, because to their consumers an empty value is not
# "use the default": an empty MAX_JOBS reaches cmake as "zero jobs", an empty
# PIP_INDEX_URL reaches pip as a request for an empty index and breaks every
# install. Everything the container-side scripts can be steered with goes
# through this one list, so a knob documented as settable from the host really
# is — which is the whole of what makes it settable.
# see NOTES.md: Knobs nothing sets
OPTIONAL_ENV=(
    MAX_JOBS PIP_INDEX_URL
    # 0 turns the bootstrap's husk removal into a report. see NOTES.md: The husk
    PURGE_HUSK
    # Where the bootstrap writes the == entries of PIP_PINS as a pip constraints
    # file, so a pin holds for every resolution, not only the install naming it.
    PIP_CONSTRAINTS_FILE
    # An explicit CANN toolkit, the switch that turns the single-toolkit scrub
    # off, extra set_env.sh files, and how loudly the pick is reported.
    # see NOTES.md: ascend_env.sh picks exactly one toolkit
    ASCEND_TOOLKIT_SET_ENV ASCEND_SINGLE_TOOLKIT ASCEND_EXTRA_SET_ENV
    ASCEND_ENV_FILE ASCEND_ENV_QUIET ASCEND_ENV_VERBOSE
    # The bootstrap's own escape hatches: reinstall a triton that imports
    # cleanly, a local wheel directory to prefer, git safe.directory handling,
    # and the import:pip-name lists --no-build-isolation needs present.
    TRITON_FORCE TRITON_WHEEL_DIR GIT_SAFE_DIRS GIT_SAFE_SKIP
    BUILD_DEPS BUILD_BINS
)
for v in "${OPTIONAL_ENV[@]}"; do
    [[ -n "${!v:-}" ]] && ENV_ARGS+=( -e "${v}=${!v}" )
done
# Read by the Ascend Docker Runtime when it is the active runtime; inert without.
[[ -n "${ASCEND_RUNTIME_OPTIONS}" ]] && ENV_ARGS+=( -e "ASCEND_RUNTIME_OPTIONS=${ASCEND_RUNTIME_OPTIONS}" )
[[ "${DEVICE_MODE}" == "visible" ]] && ENV_ARGS+=( -e "ASCEND_VISIBLE_DEVICES=${VISIBLE_IDS}" )
# Named BUILD_* because `docker build` was once the only consumer, but the
# editable installs run pip INSIDE the container, where an unset http_proxy on a
# box that requires one looks exactly like a dead mirror. Container environment
# only — nothing is baked into an image. Both spellings: tools differ.
[[ -n "${BUILD_HTTP_PROXY}"  ]] && ENV_ARGS+=( -e "http_proxy=${BUILD_HTTP_PROXY}"   -e "HTTP_PROXY=${BUILD_HTTP_PROXY}"  )
[[ -n "${BUILD_HTTPS_PROXY}" ]] && ENV_ARGS+=( -e "https_proxy=${BUILD_HTTPS_PROXY}" -e "HTTPS_PROXY=${BUILD_HTTPS_PROXY}" )

mask_url() {
    local u="$1"
    case "${u}" in
        "")      printf '' ;;
        *://*@*) printf '%s//%s@%s' "${u%%//*}" '***:***' "${u##*@}" ;;
        *)       printf '%s' "${u}" ;;
    esac
}
if [[ "${BUILD_HTTP_PROXY}${BUILD_HTTPS_PROXY}" == *"@"* ]]; then
    warn "the proxy URL carries credentials. They are passed into the container's
    environment (they have to be, for pip), so \`docker inspect ${NAME}\` shows
    them to anyone with access to the docker socket on this host. This script's
    own output masks them; that does not change the above."
fi

# The same proxy that lets pip reach an index also intercepts https on many
# corporate networks. pip shrugs that off; the KERNEL BUILD does not.
# see NOTES.md: CMAKE_TLS_VERIFY — the intercepted-https trap
if [[ -n "${CMAKE_TLS_VERIFY}" ]]; then
    ENV_ARGS+=( -e "CMAKE_TLS_VERIFY=${CMAKE_TLS_VERIFY}" )
    [[ "${CMAKE_TLS_VERIFY}" == "0" ]] && ENV_ARGS+=( -e "GIT_SSL_NO_VERIFY=1" )
fi

# How manage_containers.sh finds our containers without guessing from names.
LABEL_ARGS=(
    --label "vllm-ascend-dev=1"
    --label "vllm-ascend-dev.owner=${RUN_USER}"
    --label "vllm-ascend-dev.soc=${SOC_VERSION}"
    --label "vllm-ascend-dev.image=${IMAGE}"
)

# --entrypoint is explicit on purpose: a stock vllm-ascend image has an
# ENTRYPOINT of its own (sometimes a serve script), and `bash <script> sleep
# infinity` runs the bootstrap and then becomes `sleep infinity` in ANY image —
# needing no execute bit on a file that may have arrived over a Windows share.
DOCKER_CMD=( docker run -d --name "${NAME}" -w "${WORKDIR}"
             --entrypoint bash
             "${DEV_ARGS[@]}" "${MOUNT_ARGS[@]}" "${RES_ARGS[@]}"
             "${NET_ARGS[@]}" "${ENV_ARGS[@]}" "${LABEL_ARGS[@]}"
             "${IMAGE}" "${DEV_TOOLS_DIR}/entrypoint.sh" sleep infinity )

# ── report ───────────────────────────────────────────────────────────────────
# Built before the heredoc: a ${x} nested inside a ${x:+...} is not a valid
# substitution, and the failure is a runtime one that bash -n cannot see.
CONFIG_LINE="  config     : ${AEE_LOADED:-<none>}"
if [[ -n "${AEE_SHADOWED}" ]]; then
    CONFIG_LINE+=$'\n'"  overriding : ${AEE_SHADOWED}  (set outside a5.env, so its EDIT BLOCK value is ignored)"
fi
cat <<EOF

  TO RUN, THESE ARE YOURS — none of them is in the image
  -----------------------------------------------------
  your home        ${HOST_HOME}   ($(verdict "${HOST_HOME}"))
  your vllm        ${vllm_desc}
  your vllm-ascend ${VLLM_ASCEND_DIR}   ($(verdict "${VLLM_ASCEND_DIR}"), editable, live)
  model weights    ${HOST_DATA}   ($(verdict "${HOST_DATA}"))
  SOC_VERSION      ${SOC_VERSION}${IMG_SOC:+   (image default ${IMG_SOC})}
  NPU driver       ${ASCEND_DRIVER_DIR}   ($(verdict "${ASCEND_DRIVER_DIR}"))

  container  : ${NAME}
  image      : ${IMAGE}${IMG_DESC}
  image id   : ${IMG_ID:0:19}   python ${PROBE_PY}
  dev scripts: ${TOOLS_NOTE}
${CONFIG_LINE}
  NPUs       : ${DEVICES}  (${NPU_COUNT} davinci node(s) on this host)
  how        : ${DEVICE_NOTE}
  driver     : ${DRIVER_MOUNT} of ${ASCEND_DRIVER_DIR}  ($(verdict "${ASCEND_DRIVER_DIR}"))${ASCEND_RUNTIME_OPTIONS:+   ASCEND_RUNTIME_OPTIONS=${ASCEND_RUNTIME_OPTIONS}}
  firmware   : ${ASCEND_FIRMWARE_DIR}  ($(verdict "${ASCEND_FIRMWARE_DIR}"))
  memory     : ${MEM_LIMIT:-unlimited (all ${host_mem_gb}G of host RAM)}   shm=${shm}
  cpus       : ${CPUS:-all}${CPUSET:+  pinned to ${CPUSET}}
  network    : ${NETWORK}
  workdir    : ${WORKDIR}
  bootstrap  : ${BOOTSTRAP_ON_START}  (pip install -e your checkouts)
  kernels    : ${KERNELS_NOTE}
  kernel key : ${BUILD_KEY}
  pip index  : ${PIP_INDEX_URL:-the pip.conf inside the image (PIP_INDEX_URL unset in a5.env)}
  pip proxy  : $(mask_url "${BUILD_HTTPS_PROXY:-${BUILD_HTTP_PROXY:-}}")$( [[ -z "${BUILD_HTTPS_PROXY}${BUILD_HTTP_PROXY}" ]] && echo none )
  no_proxy   : ${NO_PROXY_LIST}
  cmake TLS  : CMAKE_TLS_VERIFY=${CMAKE_TLS_VERIFY:-<unset: cmake decides>}
EOF
printf '  mounts     : %s\n' "${MOUNT_LINES[0]}"
(( ${#MOUNT_LINES[@]} > 1 )) && printf '               %s\n' "${MOUNT_LINES[@]:1}"
echo
if [[ -n "${existing_state}" ]]; then        # --recreate
    if (( DRY_RUN )); then
        say "${NAME} exists (${existing_state}); --recreate WOULD remove and re-create it."
        say "the new container would redo the editable installs (seconds to a couple of"
        say "minutes); your built kernels are in the checkout and would be kept."
        say "nothing has been removed — this is a dry run."
    else
        say "${NAME} exists (${existing_state}) and will be removed once the checks below pass."
    fi
fi
echo

# One report of everything that is wrong, and before anything has been removed.
if (( ${#PROBLEMS[@]} )); then
    echo "${C_ERR}  ${#PROBLEMS[@]} problem(s) must be fixed before a container can start:${C_RST}" >&2
    for p in "${PROBLEMS[@]}"; do echo "    * ${p}" >&2; echo >&2; done
    if [[ -n "${existing_state}" ]] && (( RECREATE )); then
        echo "  ${NAME} was NOT removed — it is still there, exactly as it was:" >&2
        echo "      ./run_container.sh ${SUFFIX}        # go back into it" >&2
        echo >&2
    fi
    exit 1
fi

if (( DRY_RUN )); then
    say "dry run — nothing was started, nothing was removed. The command would be:"
    printf '   '; printf ' %q' "${DOCKER_CMD[@]}"; echo
    exit 0
fi

# Only now, with every path, checkout, device and driver file verified, is it
# safe to throw the old container away.
if [[ -n "${existing_state}" ]]; then
    say "removing existing container ${NAME} (${existing_state})"
    say "its editable installs go with it — the new one redoes them (seconds to a"
    say "couple of minutes). Your built kernels are in the checkout and are kept."
    docker rm -f "${NAME}" >/dev/null || die "could not remove ${NAME}. Stop whatever
    is holding it (./manage_containers.sh) and try again."
fi

say "starting ${NAME}"
BOOTSTRAP_EPOCH="$(date +%s)"
"${DOCKER_CMD[@]}" >/dev/null || die "docker run failed"

# The bootstrap runs in the entrypoint; stream it rather than leaving you to
# wonder why the first shell takes a minute — or, on a first kernel build, an hour.
wait_for_bootstrap all
report_bootstrap || exit 1

if (( ATTACH )); then
    enter_container
fi

cat <<EOF

  Running detached. Useful next steps:
      docker exec -it ${NAME} bash -l                   # shell in
      docker exec -d  ${NAME} bash -lc 'cd ~ && ./your_serve_script.sh'
      ./manage_containers.sh                            # list / stop / kill / logs
      docker logs ${NAME}                               # bootstrap output
      docker exec -it ${NAME} bash ${DEV_TOOLS_DIR}/bootstrap_editable.sh --check

EOF
