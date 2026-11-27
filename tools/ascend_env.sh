#!/usr/bin/env bash
# =============================================================================
#  ascend_env.sh — the CANN environment, written down ONCE. SOURCED, never run.
#
#  Sourced by the Dockerfile's baseline installs, every login shell (through
#  /etc/profile.d), entrypoint.sh and bootstrap_editable.sh, so a kernel build's
#  LD_LIBRARY_PATH cannot depend on how you entered the container. It lives in
#  tools/, so a stock vllm-ascend image works unmodified.
#
#  It sources EXACTLY ONE toolkit, the one that can actually build (lib64 AND
#  headers), then scrubs every other out of the search paths: an image can
#  carry two CANN installs and cmake's find_library fallback would otherwise
#  bind the build to the runtime-only drop.
#  see NOTES.md: ascend_env.sh picks exactly one toolkit
#
#  Knobs: ASCEND_TOOLKIT_SET_ENV (the set_env.sh to use, skipping the choice),
#  ASCEND_EXTRA_SET_ENV (genuinely ADDITIVE set_env.sh files — an accelerator
#  library, not a toolkit; nnal/atb is handled already), ASCEND_SINGLE_TOOLKIT=0
#  (no scrubbing), ASCEND_ENV_QUIET=1, ASCEND_ENV_VERBOSE=1 (candidate table).
#  Publishes ASCEND_CANN_ROOT, ASCEND_CANN_ARCH_DIR, ASCEND_ENV_REJECTED and
#  ASCEND_ENV_REPORT, so nothing downstream has to guess.
#
#  Properties it has to keep: idempotent (three sources must not grow three
#  copies of LD_LIBRARY_PATH), `set -u` safe (vendor set_env.sh scripts read
#  unset variables), path-agnostic (each candidate is sourced in a SUBSHELL and
#  asked what it would set, so no version string or layout is ever parsed), and
#  POSIX sh — /etc/profile.d is read by whatever the login shell is.
# =============================================================================

if [ -z "${ASCEND_ENV_DONE:-}" ]; then

    # Vendor set_env.sh scripts expand variables they never set, fatal under
    # `set -u`, so it is lifted for the duration and put back.
    case "$-" in *u*) _aee_restore_u=1; set +u ;; *) _aee_restore_u=0 ;; esac

    # ── where CANN is ────────────────────────────────────────────────────────
    # Probed only if unset. cann/set_env.sh counts: some images have no
    # ascend-toolkit/set_env.sh at all.
    if [ -z "${ASCEND_HOME:-}" ]; then
        for _aee_h in /usr/local/Ascend /opt/Ascend "${HOME:-/root}/Ascend"; do
            if [ -f "${_aee_h}/ascend-toolkit/set_env.sh" ] || [ -f "${_aee_h}/cann/set_env.sh" ]; then
                ASCEND_HOME="${_aee_h}"; break
            fi
        done
        ASCEND_HOME="${ASCEND_HOME:-/usr/local/Ascend}"
    fi
    export ASCEND_HOME

    # ── helpers ──────────────────────────────────────────────────────────────
    # latest/ is a symlink, so two different-looking prefixes can be one
    # install; only the resolved paths tell a duplicate from a second toolkit.
    _aee_real() {
        if readlink -f / >/dev/null 2>&1; then
            readlink -f "$1" 2>/dev/null
        else
            ( cd "$1" 2>/dev/null && pwd -P )
        fi
    }

    # What root would this set_env.sh put us on? Sourced in a SUBSHELL, so
    # nothing escapes and no version string or layout is ever assumed.
    _aee_probe() {
        ( set +u
          ASCEND_HOME_PATH=""; ASCEND_TOOLKIT_HOME=""
          . "$1" >/dev/null 2>&1
          printf '%s' "${ASCEND_HOME_PATH:-${ASCEND_TOOLKIT_HOME:-}}" )
    }

    # lib64 is not enough: a runtime drop has lib64 and no headers, which is
    # what produces "includes non-existent path" half an hour into a build. The
    # markers are what the CANN find modules make INTERFACE_INCLUDE_DIRECTORIES.
    _aee_buildable() {
        [ -n "$1" ] && [ -d "$1/lib64" ] || return 1
        for _aee_bm in include/exe_graph include/graph pkg_inc/base \
                       include/aclnn x86_64-linux/include/aclnn \
                       aarch64-linux/include/aclnn; do
            if [ -d "$1/${_aee_bm}" ]; then unset _aee_bm; return 0; fi
        done
        unset _aee_bm
        return 1
    }

    # Drop every entry under a rejected root, then deduplicate; one awk, not a
    # shell loop, because this runs in every login shell. Matched on the
    # resolved AND the literal spelling, which a symlink makes differ.
    _aee_clean_list() {   # _aee_clean_list <colon-list> <space-separated bad prefixes>
        printf '%s' "$1" | tr ':' '\n' | awk -v bad="$2" '
            BEGIN { n = split(bad, b, " ") }
            NF == 0 { next }
            {
                for (i = 1; i <= n; i++)
                    if (b[i] != "" && index($0, b[i]) == 1) next
                if (!seen[$0]++) print
            }' | paste -sd: -
    }

    # ── the candidates ───────────────────────────────────────────────────────
    # In preference order; an explicit ASCEND_TOOLKIT_SET_ENV short-circuits it.
    _aee_cands="${ASCEND_TOOLKIT_SET_ENV:-}"
    if [ -z "${_aee_cands}" ]; then
        _aee_cands="${ASCEND_HOME}/ascend-toolkit/set_env.sh ${ASCEND_HOME}/cann/set_env.sh ${ASCEND_HOME}/set_env.sh"
    fi

    _aee_chosen=""; _aee_chosen_root=""
    _aee_first=""; _aee_first_root=""
    _aee_table=""; _aee_roots=""
    for _aee_c in ${_aee_cands}; do
        [ -f "${_aee_c}" ] || continue
        _aee_r="$(_aee_probe "${_aee_c}")"
        [ -n "${_aee_r}" ] || _aee_r="$(_aee_real "${_aee_c%/set_env.sh}/latest")"
        _aee_rr="$(_aee_real "${_aee_r}")"
        [ -n "${_aee_rr}" ] && _aee_r="${_aee_rr}"
        # A second spelling of a root already seen is not a second toolkit.
        case " ${_aee_roots} " in *" ${_aee_r} "*) continue ;; esac
        _aee_roots="${_aee_roots} ${_aee_r}"
        if _aee_buildable "${_aee_r}"; then
            _aee_kind="buildable"
            [ -n "${_aee_chosen}" ] || { _aee_chosen="${_aee_c}"; _aee_chosen_root="${_aee_r}"; }
        else
            if [ -d "${_aee_r}/lib64" ]; then _aee_kind="runtime-only (lib64, no headers)"
            else _aee_kind="unusable"; fi
        fi
        [ -n "${_aee_first}" ] || { _aee_first="${_aee_c}"; _aee_first_root="${_aee_r}"; }
        _aee_table="${_aee_table}
    [ascend_env]   ${_aee_c} -> ${_aee_r}   [${_aee_kind}]"
    done

    # Nothing buildable: take the first that exists. A pure-serve container
    # needs no headers, and a kernel build then fails with a real "not found".
    if [ -z "${_aee_chosen}" ] && [ -n "${_aee_first}" ]; then
        _aee_chosen="${_aee_first}"; _aee_chosen_root="${_aee_first_root}"
        if [ -z "${ASCEND_ENV_QUIET:-}" ]; then
            echo "[ascend_env] no CANN toolkit here has both lib64 and headers; using" >&2
            echo "[ascend_env] ${_aee_chosen_root}. A serve is fine; the custom-op build will" >&2
            echo "[ascend_env] fail on a missing library or header, and that failure is real." >&2
        fi
    fi

    # ── every other toolkit has to leave the search paths ────────────────────
    # Not only the candidates above: a toolkit the IMAGE put on PATH wins a
    # find_library just as well, and sourcing one toolkit does not remove it.
    _aee_reject=""
    if [ -n "${_aee_chosen_root}" ] && [ "${ASCEND_SINGLE_TOOLKIT:-1}" = "1" ]; then
        for _aee_c in "${ASCEND_HOME}"/cann-* "${ASCEND_HOME}"/ascend-toolkit \
                      "${ASCEND_HOME}"/ascend-toolkit/latest \
                      "${ASCEND_HOME}"/cann "${ASCEND_HOME}"/cann/latest; do
            # lib64 is what makes a directory a toolkit ROOT, not just the
            # parent one sits in. Rejecting bare ascend-toolkit/ would strip the
            # prefix every real set_env.sh uses to spell what it put on PATH,
            # chosen toolkit included, leaving no CANN on PATH at all.
            [ -d "${_aee_c}/lib64" ] || continue
            _aee_r="$(_aee_real "${_aee_c}")"
            [ "${_aee_r}" = "${_aee_chosen_root}" ] && continue
            # Both spellings: the literal is on PATH, the resolved one on
            # LD_LIBRARY_PATH after a symlink.
            _aee_reject="${_aee_reject} ${_aee_c}/ ${_aee_r}/"
        done
    fi
    if [ -n "${_aee_reject}" ]; then
        for _aee_v in PATH LD_LIBRARY_PATH CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH \
                      LIBRARY_PATH PYTHONPATH LD_PRELOAD CMAKE_PREFIX_PATH; do
            eval "_aee_old=\${${_aee_v}:-}"
            [ -n "${_aee_old}" ] || continue
            _aee_new="$(_aee_clean_list "${_aee_old}" "${_aee_reject}")"
            [ "${_aee_new}" = "${_aee_old}" ] && continue
            if [ -n "${_aee_new}" ]; then eval "export ${_aee_v}=\"\${_aee_new}\""
            else eval "unset ${_aee_v}"; fi
        done
        # cmake 3.23+ reads these from the environment and they suppress the
        # PATH-to-parent fallback, so the wrong toolkit cannot come back inside
        # a nested FetchContent sub-build. Platform separator, as CMAKE_PREFIX_PATH.
        for _aee_r in ${_aee_reject}; do
            _aee_r="${_aee_r%/}"
            case ":${CMAKE_IGNORE_PATH:-}:" in *":${_aee_r}:"*) continue ;; esac
            CMAKE_IGNORE_PATH="${CMAKE_IGNORE_PATH:+${CMAKE_IGNORE_PATH}:}${_aee_r}"
            CMAKE_IGNORE_PREFIX_PATH="${CMAKE_IGNORE_PREFIX_PATH:+${CMAKE_IGNORE_PREFIX_PATH}:}${_aee_r}"
        done
        export CMAKE_IGNORE_PATH CMAKE_IGNORE_PREFIX_PATH
    fi

    # ── now, and only now, the one toolkit ───────────────────────────────────
    if [ -n "${_aee_chosen}" ]; then
        # shellcheck disable=SC1090
        . "${_aee_chosen}"
    else
        echo "[ascend_env] no set_env.sh under ${ASCEND_HOME} — this image has no CANN" >&2
        echo "[ascend_env] toolkit where ASCEND_HOME says. Set ASCEND_HOME in a5.env to" >&2
        echo "[ascend_env] where it really is; ./probe_image.sh prints it." >&2
    fi
    export ASCEND_CANN_ROOT="${_aee_chosen_root}"

    # Genuinely additive accelerator libraries, not toolkits, so they do not
    # fight with the one above. nnal/atb is the one every A5 image has.
    [ -f "${ASCEND_HOME}/nnal/atb/set_env.sh" ] && . "${ASCEND_HOME}/nnal/atb/set_env.sh"
    for _aee_c in ${ASCEND_EXTRA_SET_ENV:-}; do
        [ -f "${_aee_c}" ] && . "${_aee_c}"
    done

    # ── devlib, from the toolkit actually in force ───────────────────────────
    # devlib is what the custom-op build links against, and the one directory
    # set_env.sh does not add itself. Resolved against the CHOSEN root (a
    # hardcoded ascend-toolkit/latest puts the rejected toolkit's devlib straight
    # back) and by glob, because `uname -i` answers "unknown" on many aarch64
    # kernels, silently skipping devlib on exactly the ARM boxes we support.
    ASCEND_CANN_ARCH_DIR=""
    if [ -n "${ASCEND_CANN_ROOT}" ]; then
        _aee_arch="$(uname -m 2>/dev/null)"
        if [ -n "${_aee_arch}" ] && [ -d "${ASCEND_CANN_ROOT}/${_aee_arch}-linux" ]; then
            ASCEND_CANN_ARCH_DIR="${ASCEND_CANN_ROOT}/${_aee_arch}-linux"
        else
            for _aee_d in "${ASCEND_CANN_ROOT}"/*-linux; do
                [ -d "${_aee_d}" ] && { ASCEND_CANN_ARCH_DIR="${_aee_d}"; break; }
            done
        fi
    fi
    export ASCEND_CANN_ARCH_DIR
    if [ -n "${ASCEND_CANN_ARCH_DIR}" ] && [ -d "${ASCEND_CANN_ARCH_DIR}/devlib" ]; then
        export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}:${ASCEND_CANN_ARCH_DIR}/devlib"
    fi
    # memfabric and the other wheels that ship .so files put them here.
    export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}:/usr/local/lib"

    # Probed, not hardcoded: an LD_PRELOAD pointing at a file that is not there
    # makes EVERY command in the container print a loader warning. Costs one
    # torch_npu warning per process. see NOTES.md: ascend_env.sh picks exactly
    # one toolkit
    if [ "${ASCEND_JEMALLOC:-1}" = "1" ]; then
        for _aee_jem in /usr/lib64/libjemalloc.so.2 \
                        /usr/lib/aarch64-linux-gnu/libjemalloc.so.2 \
                        /usr/lib/x86_64-linux-gnu/libjemalloc.so.2 \
                        /usr/lib64/libjemalloc.so; do
            if [ -f "${_aee_jem}" ]; then
                case ":${LD_PRELOAD:-}:" in
                    *":${_aee_jem}:"*) ;;
                    *) export LD_PRELOAD="${_aee_jem}${LD_PRELOAD:+:${LD_PRELOAD}}" ;;
                esac
                break
            fi
        done
    fi

    # ── one deduplication pass, and the rejected roots AGAIN ─────────────────
    # Deduplication, because the guard at the top cannot undo what the IMAGE
    # already had in these variables. And the rejected roots a SECOND time: the
    # scrub above ran before the chosen set_env.sh, and a vendor script reaching
    # for ascend-toolkit/latest whatever install it belongs to would otherwise
    # hand the wrong lib64 straight back.
    for _aee_v in PATH LD_LIBRARY_PATH CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH \
                  LIBRARY_PATH PYTHONPATH; do
        eval "_aee_old=\${${_aee_v}:-}"
        [ -n "${_aee_old}" ] || continue
        _aee_new="$(_aee_clean_list "${_aee_old}" "${_aee_reject}")"
        [ -n "${_aee_new}" ] && eval "export ${_aee_v}=\"\${_aee_new}\""
    done

    # ── say what was decided, once, and only when it is news ─────────────────
    ASCEND_ENV_REJECTED="$(printf '%s' "${_aee_reject}" | tr ' ' '\n' | sed 's|/$||' | awk 'NF && !s[$0]++' | paste -sd' ' -)"
    export ASCEND_ENV_REJECTED
    ASCEND_ENV_REPORT="CANN ${ASCEND_CANN_ROOT:-<none>}${ASCEND_CANN_ARCH_DIR:+ (${ASCEND_CANN_ARCH_DIR##*/})}${ASCEND_ENV_REJECTED:+; not used: ${ASCEND_ENV_REJECTED}}"
    export ASCEND_ENV_REPORT
    if [ -n "${ASCEND_ENV_VERBOSE:-}" ]; then
        echo "[ascend_env] candidates:${_aee_table}" >&2
        echo "[ascend_env] ${ASCEND_ENV_REPORT}" >&2
    elif [ -n "${_aee_reject}" ] && [ -z "${ASCEND_ENV_QUIET:-}" ]; then
        # Worth one line in every shell: this container holds more than one
        # CANN, and which is in force decides whether a kernel build can work.
        echo "[ascend_env] ${ASCEND_ENV_REPORT}" >&2
    fi

    unset _aee_h _aee_jem _aee_c _aee_r _aee_rr _aee_d _aee_v _aee_arch \
          _aee_old _aee_new _aee_cands _aee_chosen _aee_chosen_root \
          _aee_first _aee_first_root _aee_table _aee_roots _aee_reject \
          _aee_kind
    unset -f _aee_real _aee_probe _aee_buildable _aee_clean_list 2>/dev/null
    export ASCEND_ENV_DONE=1
    [ "${_aee_restore_u}" = "1" ] && set -u
    unset _aee_restore_u
fi
true