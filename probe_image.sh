#!/usr/bin/env bash
# =============================================================================
#  probe_image.sh — "what is inside this image, and can I use it as-is?" Run it
#  first on a new server: a box you did not set up usually already has images
#  carrying CANN, torch-npu and even vllm / vllm-ascend, and this answers from
#  facts rather than from a tag name. see NOTES.md: Two routes to a container
#
#  It starts a throwaway container (--rm, no network, no NPU, nothing mounted
#  but tools/ read-only), prints what it finds and exits. It changes nothing and
#  never pulls: an image that is not on this box is reported, not downloaded.
#
#  ─── FLAGS ───────────────────────────────────────────────────────────────────
#    --list [pat]   local images worth looking at; pat defaults to LIST_PATTERN
#    -h, --help     this text
#
#  ─── RECIPES ─────────────────────────────────────────────────────────────────
#    ./probe_image.sh --list                 # what is already on this box
#    ./probe_image.sh vllm-ascend:vq2a8 ...  # look inside, several at once
#    ./probe_image.sh                        # the image a5.env points at
#
#  "usable as-is" = CANN toolkit + torch-npu + a compiler, so set IMAGE to it in
#  a5.env and run ./run_container.sh. "NOT usable" = add only what it lacks:
#  BASE_IMAGE=<ref> BASE_KIND=ready ./build_image.sh. Either way your vllm and
#  vllm-ascend come from YOUR checkouts, and kernels are built in your checkout.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${HERE}/load_env.sh" "$@"        # also provides say/warn/die, usage,
set -- ${AEE_ARGS[@]+"${AEE_ARGS[@]}"}   # require_docker, and --help

# Deliberately not DEV_TOOLS_DIR: a mount there would hide the image's own copy,
# and whether it has one is exactly what we are trying to find out.
PROBE_MNT="/.vllm-dev-probe"
# Images worth looking at on an Ascend box, when --list is given no pattern.
LIST_PATTERN="cann|ascend|vllm|mindie|mega|mace|torch"

DO_LIST=0
IMAGES=()
for arg in "$@"; do
    case "$arg" in
        --list) DO_LIST=1 ;;
        -*)     die "unknown flag: $arg (try --help)" ;;
        *)      IMAGES+=( "$arg" ) ;;
    esac
done

require_docker

if (( DO_LIST )); then
    # The pattern is the first non-flag argument, if there is one.
    pat="${IMAGES[0]:-${LIST_PATTERN}}"
    say "local images matching '${pat}' — newest first"
    echo
    docker images --format '{{.Repository}}:{{.Tag}}\t{{.ID}}\t{{.Size}}\t{{.CreatedSince}}' \
        | grep -Ei "${pat}" \
        | awk -F'\t' '{printf "  %-62s %-14s %8s  %s\n", $1, $2, $3, $4}'
    echo
    say "look inside one with: ./probe_image.sh REPOSITORY:TAG   (copy one of the refs above)"
    exit 0
fi

(( ${#IMAGES[@]} )) || IMAGES=( "${IMAGE}" )

rc=0
for img in "${IMAGES[@]}"; do
    echo
    echo "${C_HDR}=== ${img} ===${C_RST}"

    # Host-side facts first, with stderr KEPT and "is it here" asked of
    # `docker images` rather than inferred from this command failing — which
    # turned an unparsable template, a daemon error or a stray \r into a
    # confident "not on this box". see NOTES.md: IMAGE, and the stray `\r`
    ins_err="$(mktemp 2>/dev/null)" || ins_err="/tmp/.vllm-dev-probe.$$"
    meta="$(docker image inspect "${img}" --format '{{.Id}}|{{.Created}}|{{.Size}}|{{.Config.WorkingDir}}|{{json .Config.Entrypoint}}|{{json .Config.Cmd}}' 2>"${ins_err}")"
    if [[ -z "${meta}" ]]; then
        err="$(sed 's/^/        /' "${ins_err}" 2>/dev/null)"; rm -f "${ins_err}"
        if docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -qxF -- "${img}"; then
            warn "docker LISTS ${img}, but \`docker image inspect\` on it failed:
${err:-        (docker printed nothing)}
    So the image is here and this says nothing about it. Nothing to pull and
    nothing to build. The report below is as much as this image will tell us."
        else
            warn "${img} is not on this box under that reference. Nothing was pulled.
        you asked for : [${img}]
    docker said:
${err:-        (docker printed nothing)}
    Compare that against the exact references the daemon has — a long registry
    reference is wrong by one character far more often than it is absent:
        ./probe_image.sh --list
    Then either pull it (docker pull ${img}) or use one that is here."
        fi
        rc=1; continue
    fi
    rm -f "${ins_err}"
    IFS='|' read -r id created size workdir entrypoint cmd <<< "${meta}"
    short_id="${id#sha256:}"
    printf '  %-16s %s\n' "id" "${short_id:0:12}"
    printf '  %-16s %s   %s GB\n' "created" "${created%T*}" "$(( size / 1000000000 ))"
    printf '  %-16s %s\n' "workdir" "${workdir:-/}"
    printf '  %-16s entrypoint %s  cmd %s\n' "starts with" "${entrypoint}" "${cmd}"
    # Our own labels, if ./build_image.sh made this image. Filtered here rather
    # than in the Go template, which has no prefix test.
    labels="$(docker image inspect "${img}" \
        --format '{{range $k, $v := .Config.Labels}}{{$k}}={{$v}}{{println}}{{end}}' 2>/dev/null \
        | grep '^vllm-ascend-dev' | tr '\n' ' ')"
    printf '  %-16s %s\n' "dev labels" "${labels:-none — not built by ./build_image.sh (that is fine)}"

    # bash, because the probe uses arrays and [[ ]] — and an image without bash
    # is not one to develop in anyway.
    docker run --rm --network none \
        -v "${HERE}/tools:${PROBE_MNT}:ro" \
        -e "DEV_TOOLS_DIR=${DEV_TOOLS_DIR}" \
        -e "ASCEND_HOME=${ASCEND_HOME}" \
        --entrypoint bash "${img}" "${PROBE_MNT}/probe_in_container.sh" || {
            warn "the probe could not run in ${img} (no bash? no python3?). The lines
    above are all this image will tell us."
            rc=1; }
done

echo
cat <<EOF
  Next, with the one you picked:
      IMAGE=<ref> ./run_container.sh --dry-run     # try it without editing a file
      # happy with it? write it into a5.env as IMAGE, then:
      ./run_container.sh

EOF
exit ${rc}