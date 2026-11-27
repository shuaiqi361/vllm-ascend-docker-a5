#!/usr/bin/env bash
# =============================================================================
#  build_image.sh — build the DEPENDENCY image. Run this rarely, or never.
#
#  The image holds CANN, torch / torch-npu, triton-ascend, FLA and the A5
#  extras, and NONE of your code. This host needs DOCKER and nothing else — no
#  CANN, no driver, no npu-smi, no checkout. You can build on a box with no NPU.
#
#  ─── FIRST: YOU MAY NOT NEED THIS AT ALL ─────────────────────────────────────
#
#  run_container.sh runs ANY image, so a server that already has a vllm-ascend
#  or CANN image needs no build. Check before you spend an hour:
#      ./probe_image.sh --list
#      ./probe_image.sh <the most promising ref>
#      IMAGE=<ref> ./run_container.sh --dry-run
#  And if a colleague already built on this box, use THEIR image — it has no
#  paths and no code in it:   docker images | grep vllm-ascend
#
#  ─── RECIPES ─────────────────────────────────────────────────────────────────
#
#    ./build_image.sh --dry-run     resolve everything, check the host, build
#                                   nothing. Run this first on a new server.
#    ./build_image.sh --host-deps   first time ever here: install the docker
#                                   engine, enable it, add you to the group,
#                                   then build. Asks before yum.
#    ./build_image.sh               every build after that
#    ./build_image.sh --no-cache    when you suspect a stale layer
#    ./build_image.sh --host-deps -y            unattended, no y/N prompts
#
#    IMAGE=vllm-ascend-a5-dev:exp1 ./build_image.sh      a second image, to A/B
#    IMAGE=vllm-ascend-a5-dev:exp1 ./run_container.sh exp1   a container from it
#    BASE_IMAGE=<ref> BASE_KIND=ready ./build_image.sh   thin: seconds, a few MB
#
#  BASE_KIND is the one choice. `cann` (default) builds everything on a plain
#  CANN base: tens of minutes, ~25-30G. `ready` adds only the dev plumbing to a
#  base that is already a vllm-ascend runtime image. It derives SEED_DEPS,
#  SYS_PACKAGES and every INSTALL_* for you. see NOTES.md: BASE_KIND and SYS_PACKAGES
#
#  ─── WHEN DO I RUN THIS AT ALL? ──────────────────────────────────────────────
#
#    you changed                        | you run
#    -----------------------------------|------------------------------------
#    python in vllm / vllm-ascend       | nothing. It is bind-mounted and live.
#    csrc/ or an AscendC kernel         | in the container (minutes, incremental):
#                                       |   $DEV_TOOLS_DIR/bootstrap_editable.sh --force
#    requirements*.txt, a new pip dep   | in the container: ... --deps
#    any path, SOC_VERSION, your fork   | ./run_container.sh N --recreate
#    mounts / devices / memory          | ./run_container.sh N --recreate
#    BASE_IMAGE / CANN / torch_npu      | THIS
#    FLA / cannbot / mooncake versions  | THIS
#    UPSTREAM_VLLM_TAG (the baseline)   | THIS
#    Dockerfile.a5.dev                  | THIS
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${HERE}/load_env.sh" "$@"        # also provides say/warn/die/ask, usage,
set -- ${AEE_ARGS[@]+"${AEE_ARGS[@]}"}   # require_docker, and --help

# ── flags ────────────────────────────────────────────────────────────────────
# --env-file and -h/--help are consumed by load_env.sh above.
DO_HOST_DEPS=0; HOST_DEPS_ONLY=0; NO_CACHE=0; DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
        --host-deps)      DO_HOST_DEPS=1 ;;
        --host-deps-only) DO_HOST_DEPS=1; HOST_DEPS_ONLY=1 ;;
        --no-cache)       NO_CACHE=1 ;;
        --dry-run)        DRY_RUN=1 ;;
        -y|--yes)         ASSUME_YES=1 ;;
        *) die "unknown flag: $arg (try --help)" ;;
    esac
done

SUDO=""
if [[ "$(id -u)" != "0" ]]; then
    command -v sudo >/dev/null || warn "not root and no sudo — privileged steps will fail"
    SUDO="sudo"
fi

# ─────────────────────── 1. the docker engine (opt-in) ───────────────────────
# The only host-side dependency this bundle has.
install_host_deps() {
    say "host dependencies: the docker engine, and nothing else"
    if command -v docker >/dev/null 2>&1; then
        echo "    docker : already installed ($(docker --version 2>/dev/null))"
    else
        echo "    docker : not found, will try docker-engine / docker / moby-engine"
        ask "proceed with yum install?" || { warn "skipped"; return 0; }
        # openEuler ships the engine under different names depending on release.
        local ok=0
        for p in docker-engine docker moby-engine; do
            if $SUDO yum install -y "$p"; then ok=1; break; fi
        done
        (( ok )) || die "could not install a docker engine. Install it by hand, then re-run."
    fi

    say "enabling and starting the docker service"
    $SUDO systemctl enable docker  >/dev/null 2>&1 || warn "systemctl enable docker failed"
    $SUDO systemctl start  docker  >/dev/null 2>&1 || warn "systemctl start docker failed"

    if [[ "$(id -u)" != "0" ]] && ! id -nG "${RUN_USER}" | tr ' ' '\n' | grep -qx docker; then
        say "adding ${RUN_USER} to the docker group"
        $SUDO groupadd -f docker
        $SUDO usermod -aG docker "${RUN_USER}"
        # Group membership only takes effect in a NEW login shell, so stop here
        # rather than falling into a preflight certain to fail on exactly this.
        if ! docker version >/dev/null 2>&1; then
            say "done. ${RUN_USER} is in the docker group now, but this shell does"
            say "not know that yet. Start a new login shell (or run: newgrp docker)"
            say "and then:"
            echo
            echo "    ./build_image.sh"
            echo
            exit 0
        fi
    fi
}

(( DO_HOST_DEPS )) && install_host_deps
(( HOST_DEPS_ONLY )) && { say "host deps done (--host-deps-only)"; exit 0; }

# ─────────────────────── 2. preflight ────────────────────────────────────────
say "preflight"
echo "    config loaded : ${AEE_LOADED:-<none>}"
[[ -n "${AEE_SHADOWED}" ]] && echo "    overriding    : ${AEE_SHADOWED}  (a5.env's EDIT BLOCK value is ignored)"
require_docker

# A \r or a stray space in a reference is a different image to docker, and the
# resulting error names anything but the real cause.
check_clean IMAGE BASE_IMAGE CANN_VERSION ASCEND_HOME DEV_TOOLS_DIR UPSTREAM_DIR

[[ -n "${BASE_IMAGE}" ]] || die "BASE_IMAGE is empty — set it, or the three
    CANN_* parts it is built from, in a5.env's EDIT BLOCK."

# Paths INSIDE the image: checked for shape only, never for existence here,
# because this machine does not have to provide them.
for v in ASCEND_HOME DEV_TOOLS_DIR UPSTREAM_DIR; do
    [[ "${!v}" == /* ]] || die "${v} is a path inside the container and must be
    absolute, got: ${!v:-<empty>}
    Fix it in ascend-dev-env-a5/a5.env."
done
echo "    in-image paths: ASCEND_HOME=${ASCEND_HOME} DEV_TOOLS_DIR=${DEV_TOOLS_DIR} UPSTREAM_DIR=${UPSTREAM_DIR}"

# BASE_KIND sets the individual knobs HERE rather than in a5.env, so "build on
# an image that already works" cannot half-happen: one forgotten INSTALL_* would
# reinstall FLA over a working one and move a pinned version under a working vllm.
case "${BASE_KIND}" in
    cann) ;;
    ready)
        SEED_DEPS=0
        INSTALL_FLA=0; INSTALL_MOONCAKE=0; INSTALL_CANNBOT=0
        INSTALL_DEV_REQS=0; INSTALL_RUST_FRONTEND=0
        SYS_PACKAGES="install"
        say "BASE_KIND=ready — thin build. What gets added is the CANN env file,"
        say "tools/ and the labels. Seconds, a few MB. Not sure the base qualifies?"
        say "    ./probe_image.sh ${BASE_IMAGE}" ;;
    *)  die "BASE_KIND must be 'cann' or 'ready', got: ${BASE_KIND}
    Fix it in ascend-dev-env-a5/a5.env." ;;
esac

case "${SYS_PACKAGES}" in
    update|install|skip) ;;
    *) die "SYS_PACKAGES must be update, install or skip, got: ${SYS_PACKAGES}" ;;
esac

case "${SEED_DEPS}" in
    0|1) ;;
    *) die "SEED_DEPS must be 0 or 1, got: ${SEED_DEPS}" ;;
esac
# On a ready base there is nothing to seed, so this is not a warning there.
if (( ! SEED_DEPS )) && [[ "${BASE_KIND}" != "ready" ]]; then
    warn "SEED_DEPS=0: the image will carry no dependency baseline, so every
    container's first start has to resolve and download the whole dependency
    tree itself and takes many minutes. see NOTES.md: SEED_DEPS"
fi

if [[ "${BASE_KIND}" != "ready" ]]; then
    avail_gb=$(df -BG --output=avail /var/lib/docker 2>/dev/null | tail -1 | tr -dc '0-9')
    [[ -n "${avail_gb}" && "${avail_gb}" -lt 60 ]] \
        && warn "only ${avail_gb}G free where docker stores images; this image wants ~40-60G."
fi

# ─────────────────────── 3. build ────────────────────────────────────────────
# Every ARG the Dockerfile declares. Names only: the value always comes from the
# variable of the same name, so a typo cannot silently pass the wrong thing, and
# the list reads side by side with the Dockerfile's own ARG block.
BUILD_ARG_NAMES=(
    BASE_IMAGE CANN_VERSION BASE_KIND SYS_PACKAGES
    ASCEND_HOME DEV_TOOLS_DIR UPSTREAM_DIR
    SEED_DEPS
    UPSTREAM_VLLM_REPO UPSTREAM_VLLM_TAG UPSTREAM_VLLM_COMMIT
    UPSTREAM_VLLM_ASCEND_REPO UPSTREAM_VLLM_ASCEND_REF
    SOC_VERSION MAX_JOBS CARGO_BUILD_JOBS
    INSTALL_RUST_FRONTEND INSTALL_DEV_REQS
    INSTALL_FLA FLA_PACKAGE FLA_VERSION
    FLASH_ATTN_NPU_VERSION FLASH_ATTN_BUILD_NPU MF_SOC
    INSTALL_CANNBOT CANNBOT_DSL_VERSION CANNBOT_NET_OPS_VERSION
    INSTALL_MOONCAKE MOONCAKE_VERSION
    PIP_INDEX_URL PYTORCH_INDEX_URL ASCEND_INDEX_URL
)
BUILD_ARGS=()
for v in "${BUILD_ARG_NAMES[@]}"; do
    BUILD_ARGS+=( --build-arg "${v}=${!v}" )
done
# Renamed on purpose: build-only proxies, not baked into the image.
BUILD_ARGS+=(
    --build-arg "http_proxy=${BUILD_HTTP_PROXY}"
    --build-arg "https_proxy=${BUILD_HTTPS_PROXY}"
    --build-arg "no_proxy=${NO_PROXY_HOSTS}"
)
(( NO_CACHE )) && BUILD_ARGS+=( --no-cache )

# A knob in only one of the two files is the one drift this design can still
# suffer, and it fails silently — the Dockerfile's own default wins. One sed
# catches it at the right moment.
dockerfile_args="$(sed -n 's/^ARG \([A-Za-z_][A-Za-z0-9_]*\).*/\1/p' "${HERE}/Dockerfile.a5.dev" | sort -u)"
only_dockerfile="$(comm -23 <(printf '%s\n' "${dockerfile_args}") <(printf '%s\n' "${BUILD_ARG_NAMES[@]}" | sort -u) | tr '\n' ' ')"
only_here="$(comm -13 <(printf '%s\n' "${dockerfile_args}") <(printf '%s\n' "${BUILD_ARG_NAMES[@]}" | sort -u) | tr '\n' ' ')"
[[ -n "${only_dockerfile// }" ]] && warn "Dockerfile.a5.dev declares ARG(s) this script does not pass:
    ${only_dockerfile}
    They will silently use the Dockerfile's own default instead of a5.env.
    Add them to BUILD_ARG_NAMES."
[[ -n "${only_here// }" ]] && warn "this script passes build-arg(s) the Dockerfile does not declare:
    ${only_here}
    docker will warn and ignore them. Remove them from BUILD_ARG_NAMES."

# The context is this folder, and .dockerignore keeps everything out of it
# except tools/ — so nothing of yours is sent to the daemon or lands in an image.
DOCKER_CMD=( docker build -f "${HERE}/Dockerfile.a5.dev" -t "${IMAGE}" "${BUILD_ARGS[@]}" "${HERE}" )

if (( SEED_DEPS )); then
    baseline="upstream vllm ${UPSTREAM_VLLM_COMMIT:-${UPSTREAM_VLLM_TAG}} + vllm-ascend ${UPSTREAM_VLLM_ASCEND_REF}"
elif [[ "${BASE_KIND}" == "ready" ]]; then
    baseline="whatever the base image has (BASE_KIND=ready)"
else
    baseline="none (SEED_DEPS=0)"
fi
if [[ "${BASE_KIND}" == "ready" ]]; then
    base_kind_note="   (thin: dev plumbing only, seconds)"
else
    base_kind_note="   (full: system packages, dependency baseline, A5 extras)"
fi
cat <<EOF

  TO BUILD, CHECK ONE THING — this host needs only docker
  -------------------------------------------------------
  BASE_IMAGE    : ${BASE_IMAGE}
                  already on this box? docker images | grep -F '${BASE_IMAGE%%:*}'
                  not yet?            docker pull ${BASE_IMAGE}
                  what is in it?      ./probe_image.sh ${BASE_IMAGE}

  image         : ${IMAGE}
  base kind     : ${BASE_KIND}${base_kind_note}
  contains      : dependencies only. None of your code, none of your paths.
  dep baseline  : ${baseline}
  context       : ${HERE}  (tools/ only — see .dockerignore)
  log dir       : ${LOG_DIR}

  Your paths, your NPU driver and SOC_VERSION are not needed to build and are
  not checked here. On the machine that will run containers:
      ./run_container.sh --dry-run

EOF

if (( DRY_RUN )); then
    say "dry run — nothing was built, and no log directory was created."
    say "the command would be:"
    printf '   '; printf ' %q' "${DOCKER_CMD[@]}"; echo
    echo
    say "if BASE_IMAGE is right: ./build_image.sh"
    exit 0
fi

mkdir -p "${LOG_DIR}" 2>/dev/null || LOG_DIR="${TMPDIR:-/tmp}/${RUN_USER}-vllm-a5-docker-logs"
mkdir -p "${LOG_DIR}" 2>/dev/null || die "cannot create a log directory (tried ${LOG_DIR})"
LOG="${LOG_DIR}/build_$(date +%Y%m%d_%H%M%S).log"

say "building — this takes a while; follow along with: tail -f ${LOG}"
start=$(date +%s)
"${DOCKER_CMD[@]}" 2>&1 | tee "${LOG}"
rc=$?
dur=$(( $(date +%s) - start ))
(( rc )) && die "build FAILED after ${dur}s. Full log: ${LOG}"

say "built ${IMAGE} in ${dur}s"
docker images --filter "reference=${IMAGE}" --format '    {{.Repository}}:{{.Tag}}  {{.Size}}  {{.CreatedSince}}'
cat <<EOF

  Next:
      ./run_container.sh --dry-run    # check your paths and the NPU driver
      ./run_container.sh              # start a container and drop into it
      ./manage_containers.sh          # list / stop / kill / shell into containers

  You will not need this script again for a code change of any kind. After
  editing kernel (csrc/ AscendC) code, run this inside the container instead:
      ${DEV_TOOLS_DIR}/bootstrap_editable.sh --force

EOF
