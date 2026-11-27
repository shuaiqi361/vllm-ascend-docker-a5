#!/usr/bin/env bash
# =============================================================================
#  manage_containers.sh — interactive console for listing and acting on the
#  containers this workflow started. Prints the list plus a one-line cheat
#  sheet; press  h  for the full key table. Nothing destructive happens without
#  a y/N prompt unless you passed -y.
#
#  ─── FLAGS ───────────────────────────────────────────────────────────────────
#    --dev        only containers labelled vllm-ascend-dev (the default scope)
#    --mine       only your own, on a shared box
#    --all        every container on the host, when something else holds an NPU
#    -y, --yes    skip every y/N confirmation
#    -h, --help   this text
#
#  ─── RECIPES ─────────────────────────────────────────────────────────────────
#    ./manage_containers.sh          # the usual
#    ./manage_containers.sh --all    # hunt down whatever is holding an NPU
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${HERE}/load_env.sh" "$@"        # also provides say/warn/die/ask, usage,
set -- ${AEE_ARGS[@]+"${AEE_ARGS[@]}"}   # require_docker, and --help

# ── flags ────────────────────────────────────────────────────────────────────
# --env-file and -h/--help are consumed by load_env.sh above.
SCOPE="dev"          # dev | mine | all
for arg in "$@"; do
    case "$arg" in
        --all)    SCOPE="all" ;;
        --mine)   SCOPE="mine" ;;
        --dev)    SCOPE="dev" ;;
        -y|--yes) ASSUME_YES=1 ;;
        *) die "unknown flag: $arg (try --help)" ;;
    esac
done

require_docker

# ── the table ────────────────────────────────────────────────────────────────
declare -a IDS NAMES STATUS IMAGES
refresh() {
    IDS=(); NAMES=(); STATUS=(); IMAGES=()
    local filters=()
    case "${SCOPE}" in
        dev)  filters=( --filter "label=vllm-ascend-dev=1" ) ;;
        mine) filters=( --filter "label=vllm-ascend-dev.owner=${RUN_USER}" ) ;;
        all)  filters=() ;;
    esac
    while IFS='|' read -r id name st img; do
        [[ -z "${id}" ]] && continue
        IDS+=( "$id" ); NAMES+=( "$name" ); STATUS+=( "$st" ); IMAGES+=( "$img" )
    done < <(docker ps -a "${filters[@]+"${filters[@]}"}" \
                --format '{{.ID}}|{{.Names}}|{{.Status}}|{{.Image}}' 2>/dev/null)
}

is_running() { [[ "${STATUS[$1]}" == Up* ]]; }

show() {
    refresh
    echo
    if (( ${#IDS[@]} == 0 )); then
        case "${SCOPE}" in
            dev)  echo "  no containers carry the vllm-ascend-dev label." ;;
            mine) echo "  no containers labelled owner=${RUN_USER}." ;;
            all)  echo "  no containers at all on this host." ;;
        esac
        echo "  (scope is '${SCOPE}' — press 'a' to widen it, or start one with ./run_container.sh)"
        echo
        return
    fi
    printf "${C_HDR}  %-3s %-26s %-10s %-26s %-28s${C_RST}\n" "#" "NAME" "STATE" "STATUS" "IMAGE"
    local i
    for i in "${!IDS[@]}"; do
        local state col
        if is_running "$i"; then state="running"; col="${C_OK}"; else state="stopped"; col="${C_WARN}"; fi
        printf "  %-3s %-26s ${col}%-10s${C_RST} ${C_DIM}%-26s %-28s${C_RST}\n" \
            "$((i+1))" "${NAMES[$i]:0:26}" "$state" "${STATUS[$i]:0:26}" "${IMAGES[$i]:0:28}"
    done
    echo "${C_DIM}  s stop · k kill · u start · R restart · rm remove · p prune · e shell${C_RST}"
    echo "${C_DIM}  l logs · n npu-smi · i inspect · c check · t stats · a scope · h help · q quit${C_RST}"
    echo
}

# ── selection parsing: "1", "1 3", "2-4", "all" ──────────────────────────────
parse_sel() {
    local out=() tok
    if [[ "$*" == "all" || "$*" == "a" ]]; then
        local i; for i in "${!IDS[@]}"; do out+=( "$i" ); done
        printf '%s\n' "${out[@]+"${out[@]}"}"; return 0
    fi
    for tok in "$@"; do
        if [[ "$tok" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            local a="${BASH_REMATCH[1]}" b="${BASH_REMATCH[2]}" n
            for (( n=a; n<=b; n++ )); do out+=( "$((n-1))" ); done
        elif [[ "$tok" =~ ^[0-9]+$ ]]; then
            out+=( "$((tok-1))" )
        else
            warn "not an index: ${tok}"; return 1
        fi
    done
    local idx
    for idx in "${out[@]+"${out[@]}"}"; do
        if (( idx < 0 || idx >= ${#IDS[@]} )); then warn "index out of range: $((idx+1))"; return 1; fi
    done
    printf '%s\n' "${out[@]+"${out[@]}"}"
}

# mapfile would swallow parse_sel's exit status, so go through a variable.
# Both helpers fill the global array `sel`.
declare -a sel
need_sel() {
    local out
    (( $# )) || { warn "needs a selection, e.g. '1', '1 3', '2-4' or 'all'"; return 1; }
    out="$(parse_sel "$@")" || return 1
    [[ -z "${out}" ]] && { warn "empty selection"; return 1; }
    mapfile -t sel <<< "${out}"
}
need_one() {
    need_sel "$@" || return 1
    (( ${#sel[@]} == 1 )) || { warn "pick exactly one container"; return 1; }
}

names_of() { local i; for i in "$@"; do echo "  - ${NAMES[$i]} (${STATUS[$i]})"; done; }

# ── operations ───────────────────────────────────────────────────────────────
# One loop for all five lifecycle verbs. The docker call is made ONCE for the
# whole selection: `docker stop a b c` waits concurrently, so stopping four
# containers costs one grace period instead of four.
op_each() {   # op_each <verb> <past> <running-only 0|1> "<docker words>" <idx>...
    local verb="$1" past="$2" only="$3" dcmd="$4"; shift 4
    local i ids=()
    for i in "$@"; do
        if (( only )) && ! is_running "$i"; then
            echo "    ${NAMES[$i]} is already stopped — skipping"; continue
        fi
        say "${verb} ${NAMES[$i]}"
        ids+=( "${IDS[$i]}" )
    done
    (( ${#ids[@]} )) || return 0
    # shellcheck disable=SC2086
    if docker $dcmd "${ids[@]}" >/dev/null; then
        echo "    ${past} ${#ids[@]}"
    else
        warn "one or more did not ${verb% *} — press 'r' to see the current state"
    fi
}
op_stop()    { op_each "stopping"   "stopped"   1 "stop -t ${STOP_TIMEOUT}"    "$@"; }
op_kill()    { op_each "killing"    "killed"    1 "kill"                       "$@"; }
op_start()   { op_each "starting"   "started"   0 "start"                      "$@"; }
op_restart() { op_each "restarting" "restarted" 0 "restart -t ${STOP_TIMEOUT}" "$@"; }
op_rm()      { op_each "removing"   "removed"   0 "rm -f"                      "$@"; }

op_shell() {
    local i="$1"
    is_running "$i" || { warn "${NAMES[$i]} is not running — start it first (u $((i+1)))"; return 1; }
    say "entering ${NAMES[$i]} — Ctrl-D returns here, the container keeps running"
    # Land in the current directory when the container can see it — the usual
    # case, since the paths are mirrored; otherwise let the image decide.
    if docker exec "${IDS[$i]}" test -d "${PWD}" 2>/dev/null; then
        docker exec -it -w "${PWD}" "${IDS[$i]}" bash -l
    else
        docker exec -it "${IDS[$i]}" bash -l
    fi
}
op_logs() {
    local i="$1"
    say "following ${NAMES[$i]} — Ctrl-C stops following, not the container"
    docker logs -f --tail 200 "${IDS[$i]}" || true
}
op_npu() {
    local i="$1"
    is_running "$i" || { warn "${NAMES[$i]} is not running"; return 1; }
    docker exec "${IDS[$i]}" bash -lc 'npu-smi info' || warn "npu-smi failed inside ${NAMES[$i]}"
}
# Where the in-container helpers live is a property of the IMAGE, not of this
# host's a5.env, so read it back off the container. see NOTES.md: MOUNT_TOOLS — whose tools/ actually runs
tools_dir_of() {
    local d
    d="$(docker inspect "$1" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
         | sed -n 's/^DEV_TOOLS_DIR=//p' | tail -1)"
    echo "${d:-${DEV_TOOLS_DIR}}"
}
op_bootstrap_check() {
    local i="$1" tools
    is_running "$i" || { warn "${NAMES[$i]} is not running — start it first (u $((i+1)))"; return 1; }
    tools="$(tools_dir_of "${IDS[$i]}")"
    say "checking the editable installs inside ${NAMES[$i]} (reports only, changes nothing)"
    # `bash <script>`, not `<script>`: ${tools} may be a read-only bind mount of
    # the host's tools/, whose execute bit a Windows share can have dropped.
    docker exec "${IDS[$i]}" bash -lc "bash ${tools}/bootstrap_editable.sh --check" \
        || warn "the check itself failed — see the output above"
    echo
    echo "  if it says it WOULD reinstall, do that explicitly:"
    echo "      docker exec -it ${NAMES[$i]} bash ${tools}/bootstrap_editable.sh --force"
}
op_stats() {
    local want=( "$@" ) ids=() i
    for i in "${want[@]}"; do is_running "$i" && ids+=( "${IDS[$i]}" ); done
    (( ${#ids[@]} )) || { warn "nothing running in that selection"; return 1; }
    docker stats --no-stream "${ids[@]}"
}
op_inspect() {
    local i="$1"
    docker inspect "${IDS[$i]}" --format '
  name     : {{.Name}}
  image    : {{.Config.Image}}
  state    : {{.State.Status}} (started {{.State.StartedAt}})
  shm      : {{.HostConfig.ShmSize}}
  memory   : {{.HostConfig.Memory}} (0 = unlimited)
  network  : {{.HostConfig.NetworkMode}}
  devices  :{{range .HostConfig.Devices}} {{.PathOnHost}}{{end}}
  mounts   :{{range .Mounts}}
             {{.Source}} -> {{.Destination}}{{end}}'
    # Two containers from the SAME image routinely run different forks, and this
    # is the only place that tells you which codebase and home one is using.
    echo "  pointed at:"
    docker inspect "${IDS[$i]}" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
        | sed -nE 's/^(HOME|VLLM_DIR|VLLM_ASCEND_DIR|VLLM_FROM|SOC_VERSION|COMPILE_CUSTOM_KERNELS)=/             &/p'
}
op_prune() {
    local stopped=() i
    for i in "${!IDS[@]}"; do is_running "$i" || stopped+=( "$i" ); done
    (( ${#stopped[@]} )) || { say "nothing stopped to prune"; return 0; }
    echo "these stopped containers would be removed:"; names_of "${stopped[@]}"
    ask "remove them?" && op_rm "${stopped[@]}"
}

# The one key table; the list footer carries the short version.
help_text() {
cat <<'EOF'
  selection: index (2), several (1 3), a range (2-4), or "all"

    s <sel>    stop        SIGTERM then wait — the clean way to free the NPUs
    k <sel>    kill        SIGKILL — only when stop will not finish
    u <sel>    start       bring a stopped container back up
    R <sel>    restart     stop + start
    rm <sel>   remove      delete the container (force if running)
    p          prune       remove every stopped container in the current scope

    e <n>      exec        login shell inside one container
    l <n>      logs        follow its output (Ctrl-C to stop following)
    n <n>      npu-smi     run npu-smi inside it
    i <n>      inspect     devices, mounts, shm, memory, and which fork/home
    c <n>      check       is the editable install pointed at the right checkout,
                           and are the kernels built? Reports only.
    t <sel>    stats       one-shot cpu / mem / io

    a          scope       cycle dev -> mine -> all -> dev
    r          refresh     redraw the list
    h          help
    q          quit
EOF
}

# ── main loop ────────────────────────────────────────────────────────────────
confirm_and_run() {
    # $1 = verb, $2 = function, rest = indexes
    local verb="$1" fn="$2"; shift 2
    echo "about to ${verb}:"; names_of "$@"
    ask "${verb}?" || { say "cancelled"; return 0; }
    "$fn" "$@"
}

say "scope: ${SCOPE}   (dev = containers started by run_container.sh)"
show
while true; do
    read -r -p "docker> " cmd rest || { echo; break; }
    [[ -z "${cmd:-}" ]] && { show; continue; }
    # shellcheck disable=SC2086
    set -- ${rest:-}
    # One line per command, so adding one means a line here and one in help_text.
    case "${cmd}" in
        q|quit|exit) break ;;
        h|help)      help_text ;;
        r|refresh)   show ;;
        a|scope)     case "${SCOPE}" in dev) SCOPE=mine ;; mine) SCOPE=all ;; *) SCOPE=dev ;; esac
                     say "scope: ${SCOPE}"; show ;;
        p|prune)     op_prune; show ;;
        s|stop)      need_sel "$@" && { confirm_and_run "stop"    op_stop    "${sel[@]}"; show; } ;;
        k|kill)      need_sel "$@" && { confirm_and_run "KILL"    op_kill    "${sel[@]}"; show; } ;;
        rm|remove)   need_sel "$@" && { confirm_and_run "REMOVE"  op_rm      "${sel[@]}"; show; } ;;
        R|restart)   need_sel "$@" && { confirm_and_run "restart" op_restart "${sel[@]}"; show; } ;;
        u|start)     need_sel "$@" && { op_start "${sel[@]}"; show; } ;;
        t|stats)     need_sel "$@" && op_stats "${sel[@]}" ;;
        e|exec)      need_one "$@" && op_shell           "${sel[0]}" ;;
        l|logs)      need_one "$@" && op_logs            "${sel[0]}" ;;
        n|npu)       need_one "$@" && op_npu             "${sel[0]}" ;;
        i|inspect)   need_one "$@" && op_inspect         "${sel[0]}" ;;
        c|check)     need_one "$@" && op_bootstrap_check "${sel[0]}" ;;
        *) warn "unknown command '${cmd}' — press h for the list" ;;
    esac
done
say "bye"
