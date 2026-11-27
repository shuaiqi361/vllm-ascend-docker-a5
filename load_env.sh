#!/usr/bin/env bash
# =============================================================================
#  load_env.sh — the config loader and the shared helpers. SOURCED, never run.
#
#  Gives the caller:
#    HERE          this bundle's directory
#    every setting from a5.env / a5.env.local
#    AEE_LOADED    which config files were read, for the --dry-run report
#    AEE_SHADOWED  a5.env EDIT settings that a5.env.local / --env-file override
#    AEE_ARGS      the caller's arguments with --env-file FILE removed
#    say warn die ask      coloured messages and y/N prompts
#    usage                 print the caller's own header comment as --help
#    require_docker        one docker preflight with one good error message
#
#  -h / --help is answered HERE, so it works even when a5.env is missing.
#
#  Precedence, highest first:
#    1. a variable already in the environment   HOST_HOME=/home/bob ./run_container.sh
#    2. --env-file FILE                         ./run_container.sh --env-file profiles/bob.env
#    3. a5.env.local                            your optional overrides
#    4. a5.env                                  the EDIT BLOCK and all defaults
#
#  That works because every assignment in those files has the form
#  NAME="${NAME:-value}", which leaves NAME alone if it is already set. Keep
#  that form in your own override files and the order above holds.
#
#  The cost of that order: an override file is read BEFORE a5.env, so nothing
#  a5.env defines exists while it runs. Spell paths out in full there, or derive
#  them — "${HOST_HOME}/code/x" in an override is an unbound variable, not the
#  home you meant. _aee_selfcontained below refuses it with that explanation.
# =============================================================================

# This file's own location, not the caller's: the caller's HERE exists only to
# find this file, and this is the authoritative one.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AEE_CALLER="${BASH_SOURCE[1]:-$0}"

# ── messages ─────────────────────────────────────────────────────────────────
# Colours only to a terminal, so a piped log stays readable.
if [[ -t 1 ]]; then
    C_INFO=$'\033[1;36m'; C_WARN=$'\033[1;33m'; C_ERR=$'\033[1;31m'
    C_HDR=$'\033[1m';     C_OK=$'\033[1;32m';   C_DIM=$'\033[2m'; C_RST=$'\033[0m'
else
    C_INFO=""; C_WARN=""; C_ERR=""; C_HDR=""; C_OK=""; C_DIM=""; C_RST=""
fi
say()  { echo "${C_INFO}==>${C_RST} $*"; }
warn() { echo "${C_WARN}[warn]${C_RST} $*" >&2; }
die()  { echo "${C_ERR}[error]${C_RST} $*" >&2; exit 1; }
# ASSUME_YES is set by the -y flag of whichever script has one.
ASSUME_YES="${ASSUME_YES:-0}"
ask()  { (( ASSUME_YES )) && return 0; read -r -p "$* [y/N] " a; [[ "${a,,}" == y* ]]; }

# Print a script's leading comment block: line 2 to the first non-comment line.
# No line numbers anywhere, so adding a recipe to a header cannot truncate its
# own --help.
usage() { sed -n '2,${/^#/!q;p;}' "${1:-${AEE_CALLER}}"; }

# ── config hygiene ───────────────────────────────────────────────────────────
# Render a value with its boundaries and control characters visible.
show_bytes() {
    printf '[%s]' "$(printf '%s' "$1" | LC_ALL=C sed -e 's/\r/<CR>/g' -e 's/\t/<TAB>/g')"
}
# Reject a \r or stray surrounding whitespace in the named variables. A \r from
# an a5.env edited on Windows is invisible in every message it causes, and on an
# image reference it makes docker say "No such image" for an image that is right
# there. see NOTES.md: IMAGE, and the stray `\r`
# Pass only values where whitespace is never meaningful — not PIP_PINS,
# EXTRA_MOUNTS or the space-separated index lists.
check_clean() {
    local var val trimmed
    for var in "$@"; do
        eval "val=\${${var}:-}"
        [[ -n "${val}" ]] || continue
        case "${val}" in
            *$'\r'*) die "${var} contains a carriage return:
        ${var}=$(show_bytes "${val}")
    A Windows line ending in a5.env or a5.env.local. Nothing downstream can
    work with it and nothing will say so plainly. On the HOST, in this folder:
        bash fix_line_endings.sh ." ;;
        esac
        trimmed="$(printf '%s' "${val}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [[ "${val}" == "${trimmed}" ]] || die "${var} has leading or trailing whitespace:
        ${var}=$(show_bytes "${val}")
    Usually a stray space left when a long value was pasted. docker compares
    references byte for byte, so this is a different image from the one you
    meant. Trim it to:
        ${var}=\"${trimmed}\""
    done
}
# ok | MISSING | unset — for the one-line path reports.
verdict() {
    [[ -z "$1" ]] && { echo "unset"; return; }
    [[ -e "$1" ]] && echo "ok" || echo "MISSING"
}

# `docker version` rather than `docker info`: it answers the only question we
# have off a trivial endpoint, instead of making a loaded daemon enumerate every
# plugin, driver and image.
require_docker() {
    command -v docker >/dev/null 2>&1 \
        || die "docker is not installed. Run: ./build_image.sh --host-deps-only"
    docker version >/dev/null 2>&1 \
        || die "cannot talk to the docker daemon.
    Either it is not running (systemctl start docker) or your user is not in
    the docker group (newgrp docker, or log out and back in)."
}

# ── the caller's arguments ───────────────────────────────────────────────────
# --env-file is ours, so it is consumed here and everything else handed back in
# AEE_ARGS. Each script then parses only the flags it actually has.
_AEE_FILES=()
AEE_ARGS=()
AEE_LOADED=""
_aee_want_file=0
_aee_help=0
for _aee_arg in ${1+"$@"}; do
    if (( _aee_want_file )); then
        _AEE_FILES+=( "${_aee_arg}" ); _aee_want_file=0; continue
    fi
    case "${_aee_arg}" in
        --env-file)   _aee_want_file=1 ;;
        --env-file=*) _AEE_FILES+=( "${_aee_arg#--env-file=}" ) ;;
        -h|--help)    _aee_help=1 ;;
        *)            AEE_ARGS+=( "${_aee_arg}" ) ;;
    esac
done
(( _aee_want_file )) && die "--env-file needs a filename after it"
# Answered before any config is required, so --help always works.
(( _aee_help )) && { usage; exit 0; }

# ── the config files, lowest precedence last ─────────────────────────────────
# a5.env's EDIT BLOCK is the one place meant to be edited. A value set in
# a5.env.local or an --env-file silently wins over it, which is the one way an
# edit you just made can appear to do nothing — so note which ones, and let the
# callers' reports print it. Snapshot first: a variable from the command line is
# the caller's own doing and is not shadowing anything.
AEE_EDIT_VARS="IMAGE HOST_HOME VLLM_DIR VLLM_ASCEND_DIR HOST_DATA SOC_VERSION BASE_IMAGE"

# An override file runs before a5.env, so a ${VAR} of a5.env's own in one is
# unbound: under `set -u` bash aborts naming the override file and the line, and
# nothing says that the variable simply does not exist yet. Checked here, where
# the reason can be given. Only the braced reference is a mistake — the
# "${HOST_HOME:-...}" that every assignment opens with is the point of the form.
_aee_selfcontained() {
    local f="$1" bad
    bad="$(sed 's/#.*//' "${f}" 2>/dev/null \
           | grep -oE '\$\{(RUN_USER|HOST_HOME|HOST_DATA|CONTAINER_HOME|ASCEND_HOME|ASCEND_DRIVER_DIR|ASCEND_FIRMWARE_DIR|DEV_TOOLS_DIR|UPSTREAM_DIR|NAME_PREFIX)\}' \
           | sort -u | tr '\n' ' ')"
    [[ -z "${bad// }" ]] || die "${f} refers to ${bad}— a5.env has not been read yet.
    Override files are loaded FIRST so they win, which means nothing a5.env
    defines exists while yours runs. Write the value out in full instead:
        VLLM_DIR=\"\${VLLM_DIR:-/home/you/code/vllm}\"
    or derive it without a5.env:
        VLLM_DIR=\"\${VLLM_DIR:-/home/\$(id -un)/code/vllm}\""
}

_aee_preset=" "
for _aee_v in ${AEE_EDIT_VARS}; do
    [[ -n "${!_aee_v:-}" ]] && _aee_preset+="${_aee_v} "
done

for _aee_f in ${_AEE_FILES+"${_AEE_FILES[@]}"}; do
    [[ -f "${_aee_f}" ]] || die "--env-file ${_aee_f}: no such file"
    _aee_selfcontained "${_aee_f}"
    # shellcheck disable=SC1090
    source "${_aee_f}"
    AEE_LOADED+="${AEE_LOADED:+ }${_aee_f}"
done

if [[ -f "${HERE}/a5.env.local" ]]; then
    _aee_selfcontained "${HERE}/a5.env.local"
    # shellcheck disable=SC1091
    source "${HERE}/a5.env.local"
    AEE_LOADED+="${AEE_LOADED:+ }${HERE}/a5.env.local"
fi

AEE_SHADOWED=""
for _aee_v in ${AEE_EDIT_VARS}; do
    [[ -n "${!_aee_v:-}" ]] || continue
    [[ "${_aee_preset}" == *" ${_aee_v} "* ]] && continue
    AEE_SHADOWED+="${AEE_SHADOWED:+ }${_aee_v}"
done

if [[ -f "${HERE}/a5.env" ]]; then
    # shellcheck disable=SC1091
    source "${HERE}/a5.env"
    AEE_LOADED+="${AEE_LOADED:+ }${HERE}/a5.env"
else
    die "${HERE}/a5.env is missing — no script in this bundle can run without it."
fi

unset _AEE_FILES _aee_arg _aee_f _aee_want_file _aee_help _aee_v _aee_preset
