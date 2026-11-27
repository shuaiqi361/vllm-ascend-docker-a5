#!/usr/bin/env bash
# =============================================================================
#  fix_line_endings.sh — make files copied from Windows runnable on Linux. Run
#  it once right after copying this bundle to the server, and on any other
#  directory you push from Windows.
#
#  Takes DIRECTORIES or single files and repairs the four things such a copy
#  breaks every time: CRLF line endings, a UTF-8 BOM, missing exec bits and
#  non-breaking spaces (U+00A0). None of them reports itself honestly — you get
#  "bad interpreter", a syntax error on $'\r', "Permission denied", or
#  "command not found". see NOTES.md: Windows line endings
#
#  Idempotent, skips binaries and .git/, and finishes with `bash -n` over every
#  shell file so a problem that is NOT a line ending says so immediately.
#
#  ─── FLAGS ───────────────────────────────────────────────────────────────────
#    --check, -n   report what would change, change nothing
#    --all         every text file, not only the EXTENSIONS set (slower)
#    --fix-nbsp    also replace non-breaking spaces; off, as in a .md or a
#                  docstring they may be deliberate
#    --no-exec     leave permissions alone (read-only checkout, or a CIFS/NTFS
#                  mount that fakes them)
#    -h, --help    this text
#
#  ─── RECIPES ─────────────────────────────────────────────────────────────────
#    ./fix_line_endings.sh .                      # the usual, after a copy
#    ./fix_line_endings.sh --check .              # look first, change nothing
#    ./fix_line_endings.sh ~/code ~/bin/serve.sh  # a tree, plus a single file
#
#  If THIS script has CRLF, bash cannot run it either. Break the circle once:
#      sed -i 's/\r$//' fix_line_endings.sh && chmod +x fix_line_endings.sh
# =============================================================================
set -uo pipefail

# Deliberately standalone: it has to work before anything else in the bundle
# does, so it sources no load_env.sh and keeps its own message helpers.
say()  { echo -e "\033[1;36m==>\033[0m $*"; }
warn() { echo -e "\033[1;33m[warn]\033[0m $*" >&2; }
die()  { echo -e "\033[1;31m[error]\033[0m $*" >&2; exit 1; }
# Print this file's leading comment block, with no line number to keep in step.
usage() { sed -n '2,${/^#/!q;p;}' "$0"; }

CHECK_ONLY=0
DO_EXEC=1
FIX_NBSP=0
ALL_FILES=0
TARGETS=()

for arg in "$@"; do
    case "$arg" in
        --check|-n)   CHECK_ONLY=1 ;;
        --no-exec)    DO_EXEC=0 ;;
        --fix-nbsp)   FIX_NBSP=1 ;;
        --all)        ALL_FILES=1 ;;
        -h|--help)    usage; exit 0 ;;
        -*)           die "unknown flag: $arg (try --help)" ;;
        *)            TARGETS+=( "$arg" ) ;;
    esac
done

if (( ${#TARGETS[@]} == 0 )); then
    echo "usage: $0 [--check] [--all] [--fix-nbsp] [--no-exec] DIR_OR_FILE..." >&2
    echo "       $0 --help" >&2
    exit 2
fi

# Text by default; a file with no extension joins in when its first two bytes
# declare an interpreter, which catches hook scripts and the like.
EXTENSIONS=( sh bash env py md txt yaml yml json toml cfg ini conf service rules )
SKIP_DIRS=( .git .hg .svn __pycache__ node_modules .venv venv build dist .mypy_cache .pytest_cache .ruff_cache )

CR=$'\r'
BOM=$'\357\273\277'      # EF BB BF
NBSP=$'\302\240'         # C2 A0

# -U on every raw-byte grep: on MSYS2 / Git Bash / Cygwin grep opens files in
# TEXT mode and strips CR before matching, so without it a line-ending fixer
# reports zero CRLF in a file full of them. No effect on Linux.
GREP=( grep -U )

# ── which files to consider ──────────────────────────────────────────────────
is_binary() {
    # A NUL byte: good enough, and what git uses to decide the same question.
    LC_ALL=C "${GREP[@]}" -qI . "$1" 2>/dev/null && return 1 || return 0
}

wanted() {
    local f="$1" base ext e
    base="${f##*/}"
    if (( ALL_FILES )); then return 0; fi
    case "${base}" in
        Dockerfile*|Makefile|.bashrc|.bash_profile|.profile|.gitattributes|.dockerignore|.gitignore) return 0 ;;
    esac
    if [[ "${base}" == *.* ]]; then
        # Walk every suffix, so a5.env.local and serve.sh.bak match too.
        local rest="${base}"
        while [[ "${rest}" == *.* ]]; do
            ext="${rest##*.}"
            for e in "${EXTENSIONS[@]}"; do [[ "${ext}" == "${e}" ]] && return 0; done
            rest="${rest%.*}"
        done
        return 1
    fi
    [[ "$(LC_ALL=C head -c 2 "$f" 2>/dev/null)" == '#!' ]]
}

collect() {
    local t
    for t in "${TARGETS[@]}"; do
        if [[ -f "$t" ]]; then
            printf '%s\n' "$t"
        elif [[ -d "$t" ]]; then
            local prune=() d
            for d in "${SKIP_DIRS[@]}"; do prune+=( -name "$d" -o ); done
            # -o leaves a trailing -o; close it with -false
            find "$t" \( "${prune[@]}" -false \) -prune -o -type f -print 2>/dev/null
        else
            warn "not a file or directory, skipped: $t"
        fi
    done
}

# ── the four repairs ─────────────────────────────────────────────────────────
n_seen=0; n_crlf=0; n_bom=0; n_exec=0; n_nbsp=0; n_nbsp_left=0; n_bad=0; n_cr_inner=0
SHELL_FILES=()
# Under --check, the files this run WOULD have rewritten. The parse check at the
# bottom must skip them: a file whose CRLF is still in place cannot parse as
# bash, so calling that a real syntax error is the opposite of the truth.
UNFIXED=()
FIRST_LINE=""        # set by read_first_line, reused by fix_one and is_shell

read_first_line() {
    # One builtin read instead of three `head` pipelines per file.
    IFS= read -r FIRST_LINE < "$1" 2>/dev/null || FIRST_LINE=""
}
is_shell() {
    local l="${FIRST_LINE#"${BOM}"}"; l="${l%"${CR}"}"
    [[ "${1##*/}" == *.sh ]] && return 0
    [[ "${l}" =~ ^#!.*(bash|sh)( |$) ]]
}

fix_one() {
    local f="$1" did=() sed_ops=()
    local had_crlf=0 had_bom=0 had_nbsp=0 want_exec=0

    # One combined grep first: on a tree never near Windows, that is the only
    # byte scan most files need.
    if LC_ALL=C "${GREP[@]}" -q -e "${CR}" -e "${NBSP}" "$f" 2>/dev/null; then
        LC_ALL=C "${GREP[@]}" -q "${CR}\$"  "$f" 2>/dev/null && had_crlf=1
        LC_ALL=C "${GREP[@]}" -q "${NBSP}"  "$f" 2>/dev/null && had_nbsp=1
        # A CR away from end of line is reported, never silently rewritten.
        if LC_ALL=C "${GREP[@]}" -q "${CR}." "$f" 2>/dev/null; then
            n_cr_inner=$(( n_cr_inner + 1 ))
            warn "$f has a CR that is NOT at end of line — left alone, look at it by hand"
        fi
    fi

    [[ "${FIRST_LINE}" == "${BOM}"* ]] && had_bom=1

    if (( DO_EXEC )) && [[ ! -x "$f" ]]; then
        local l="${FIRST_LINE#"${BOM}"}"
        [[ "${f##*/}" == *.sh || "${l}" == '#!'* ]] && want_exec=1
    fi

    (( had_crlf ))  && { did+=( "CRLF->LF" ); n_crlf=$(( n_crlf + 1 )); sed_ops+=( -e "s/${CR}\$//" ); }
    (( had_bom ))   && { did+=( "BOM" );      n_bom=$((  n_bom  + 1 )); sed_ops+=( -e "1s/^${BOM}//" ); }
    (( want_exec )) && { did+=( "+x" );       n_exec=$(( n_exec + 1 )); }
    if (( had_nbsp )); then
        if (( FIX_NBSP )); then
            did+=( "NBSP->space" ); n_nbsp=$(( n_nbsp + 1 )); sed_ops+=( -e "s/${NBSP}/ /g" )
        else
            did+=( "NBSP(left: --fix-nbsp)" ); n_nbsp_left=$(( n_nbsp_left + 1 ))
        fi
    fi

    (( ${#did[@]} )) || return 0
    echo "    ${f}  [${did[*]}]"
    if (( CHECK_ONLY )); then
        # Only a rewrite changes whether a file parses, so +x and a left-alone
        # NBSP keep theirs in the parse check where they belong.
        (( ${#sed_ops[@]} )) && UNFIXED+=( "$f" )
        return 0
    fi

    # Temp file in the same directory, then mv: a half-written script is worse
    # than a CRLF one, and mv within one filesystem is atomic. The original mode
    # is carried over, so a 0755 script cannot become mktemp's 0600.
    if (( ${#sed_ops[@]} )); then
        local tmp dir mode
        dir="$(dirname "$f")"
        mode="$(stat -c '%a' "$f" 2>/dev/null || true)"
        tmp="$(mktemp "${dir}/.fixle.XXXXXX" 2>/dev/null)" || tmp="$(mktemp)" \
            || die "cannot create a temp file next to $f"
        LC_ALL=C sed "${sed_ops[@]}" "$f" > "${tmp}" \
            || { rm -f "${tmp}"; die "cannot rewrite $f"; }
        if [[ -n "${mode}" ]]; then chmod "${mode}" "${tmp}" 2>/dev/null || true
        else chmod --reference="$f" "${tmp}" 2>/dev/null || chmod 644 "${tmp}" 2>/dev/null || true; fi
        mv -f "${tmp}" "$f" || die "cannot replace $f"
    fi
    (( want_exec )) && { chmod +x "$f" || warn "chmod +x failed on $f"; }
    return 0
}

# ── go ───────────────────────────────────────────────────────────────────────
VERB="changed"
(( CHECK_ONLY )) && VERB="would change"
if (( CHECK_ONLY )); then
    say "checking (nothing will be changed): ${TARGETS[*]}"
else
    say "fixing: ${TARGETS[*]}"
fi

# One walk, so the parse check below can never report a file this pass skipped.
mapfile -t FILES < <(collect | sort)
for f in ${FILES[@]+"${FILES[@]}"}; do
    [[ -n "$f" ]] || continue
    [[ -L "$f" ]] && continue                 # leave symlinks alone
    wanted "$f" || continue
    is_binary "$f" && continue
    n_seen=$(( n_seen + 1 ))
    read_first_line "$f"
    is_shell "$f" && SHELL_FILES+=( "$f" )
    fix_one "$f"
done

# ── a parse check is the only proof that matters for shell files ─────────────
# A file can be perfectly LF and still broken, and you want to know now rather
# than from a failing run. Skipped for anything --check left with its CRLF in
# place: such a file is guaranteed not to parse, and saying so would send you
# hunting for a syntax error that does not exist.
n_skipped=0
is_unfixed() {
    local u
    for u in ${UNFIXED[@]+"${UNFIXED[@]}"}; do [[ "$u" == "$1" ]] && return 0; done
    return 1
}
for f in ${SHELL_FILES[@]+"${SHELL_FILES[@]}"}; do
    if (( CHECK_ONLY )) && is_unfixed "$f"; then
        n_skipped=$(( n_skipped + 1 )); continue
    fi
    if ! bash -n "$f" 2>/dev/null; then
        n_bad=$(( n_bad + 1 ))
        warn "still does not parse as bash: $f"
        bash -n "$f" 2>&1 | sed 's/^/        /' >&2
    fi
done

echo
say "${VERB}:"
printf '    %-28s %s\n' "files examined"        "${n_seen}"
printf '    %-28s %s\n' "shell files checked"   "${#SHELL_FILES[@]}"
printf '    %-28s %s\n' "CRLF line endings"     "${n_crlf}"
printf '    %-28s %s\n' "UTF-8 BOM removed"     "${n_bom}"
printf '    %-28s %s\n' "exec bit set"          "${n_exec}"
if (( FIX_NBSP )); then
    printf '    %-28s %s\n' "non-breaking spaces" "${n_nbsp}"
else
    printf '    %-28s %s\n' "non-breaking spaces" "${n_nbsp_left} (left alone; --fix-nbsp)"
fi
(( n_cr_inner )) && printf '    %-28s %s\n' "interior CR, NOT touched" "${n_cr_inner}"
(( n_skipped ))  && printf '    %-28s %s\n' "parse check deferred"     "${n_skipped} (their CRLF is still in place)"
(( n_bad ))      && printf '    %-28s %s\n' "still fail bash -n"       "${n_bad}"
echo

if (( n_bad )); then
    die "${n_bad} shell file(s) do not parse, and line endings are not the reason:
    they were either already LF or have just been fixed. Read the errors above —
    that is a real syntax error."
fi
if (( n_skipped )); then
    say "${n_skipped} shell file(s) were not parse-checked: --check left their CRLF
    in place, so they cannot parse yet and saying so would tell you nothing. They
    are checked on the run that fixes them."
fi
if (( CHECK_ONLY )) && (( n_crlf + n_bom + n_exec + n_nbsp_left )); then
    say "re-run without --check to apply$( (( n_nbsp_left )) && echo " (add --fix-nbsp for the spaces)" )."
fi
exit 0