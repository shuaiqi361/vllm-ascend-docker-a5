#!/usr/bin/env bash
# =============================================================================
#  probe_in_container.sh — "what is actually in here?" Runs INSIDE a container
#  or an image and prints one report. Reads only; changes nothing. Reached from
#  the host by ./probe_image.sh <image>, or by hand with
#  `docker exec -it NAME $TOOLS/probe_in_container.sh`.
#
#  It never imports torch or vllm: that pulls in the whole plugin stack, takes
#  tens of seconds and can fail for reasons that say nothing about what is
#  installed. Versions come from the package metadata pip itself reads.
# =============================================================================
set -uo pipefail

ASCEND_HOME="${ASCEND_HOME:-/usr/local/Ascend}"
DEV_TOOLS_DIR="${DEV_TOOLS_DIR:-/opt/vllm-dev}"

row() { printf '  %-16s %s\n' "$1" "$2"; }

# ── the distro ───────────────────────────────────────────────────────────────
os="unknown"
[[ -r /etc/os-release ]] && os="$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-${NAME:-unknown}}")"
row "os" "${os}"
row "arch" "$(uname -m)"
row "libc" "$(getconf GNU_LIBC_VERSION 2>/dev/null || echo unknown)"

# ── CANN ─────────────────────────────────────────────────────────────────────
# The version file differs by release; all three are read, first hit wins.
cann="NOT FOUND at ${ASCEND_HOME}"
for f in "${ASCEND_HOME}/ascend-toolkit/latest/version.cfg" \
         "${ASCEND_HOME}/ascend-toolkit/latest/ascend_toolkit_install.info" \
         "${ASCEND_HOME}/ascend-toolkit/latest/version.info"; do
    if [[ -r "$f" ]]; then
        v="$(grep -oE '[0-9]+\.[0-9]+\.(RC)?[0-9A-Za-z.]+' "$f" 2>/dev/null | head -1)"
        [[ -n "${v}" ]] && { cann="${v}   (${f})"; break; }
        cann="present, version unreadable   (${f})"
    fi
done
row "CANN toolkit" "${cann}"
row "ASCEND_HOME" "${ASCEND_HOME}$( [[ -d "${ASCEND_HOME}" ]] || echo "   <- does not exist" )"
# The driver is the host's and is bind-mounted in; absent in a bare image probe.
row "driver (host)" "$( [[ -r "${ASCEND_HOME}/driver/version.info" ]] \
    && grep -m1 -oE '[0-9][0-9.]*' "${ASCEND_HOME}/driver/version.info" \
    || echo "not mounted (expected when probing an image)" )"

# ── python and the packages that matter ──────────────────────────────────────
if ! python3 -c "import sys" >/dev/null 2>&1; then
    row "python3" "NOT FOUND — this image cannot run vllm at all"
    echo
    echo "  VERDICT: unusable. No python3."
    exit 1
fi
row "python3" "$(python3 -c 'import sys,platform;print(platform.python_version(), "at", sys.executable)')"
row "pip" "$(python3 -m pip --version 2>/dev/null | awk '{print $2}' || echo MISSING)"

# One python call for every package: metadata only, no imports.
python3 - <<'PY'
import importlib.metadata as md, importlib.util as iu, os, sys

def ver(name):
    try:
        return md.version(name)
    except Exception:
        return None

def where(mod):
    try:
        spec = iu.find_spec(mod)
    except Exception:
        return None
    if spec is None or not spec.origin:
        return None
    return os.path.dirname(os.path.dirname(os.path.abspath(spec.origin)))

def row(k, v):
    print("  %-16s %s" % (k, v))

# The two that this bundle replaces with your checkouts.
for dist, mod in (("vllm", "vllm"), ("vllm-ascend", "vllm_ascend")):
    v, root = ver(dist), where(mod)
    if v is None and root is None:
        row(dist, "not installed")
        continue
    # A resolved root outside site-packages is the reliable tell for editable.
    kind = "installed"
    if root and "site-packages" not in root and "dist-packages" not in root:
        kind = "EDITABLE from " + root
    elif root:
        kind = "in " + root
    row(dist, "%s   %s" % (v or "unknown version", kind))
    if mod == "vllm_ascend" and root:
        import glob
        so = glob.glob(os.path.join(root, "vllm_ascend", "*vllm_ascend_C*.so"))
        row("", "custom kernels: %s" % (os.path.basename(so[0]) if so else "NO .so in that copy"))

for dist in ("torch", "torch-npu", "torchvision", "triton-ascend", "triton",
             "transformers", "ray", "modelscope", "mooncake-transfer-engine",
             "pytest", "setuptools", "numpy"):
    v = ver(dist)
    if v:
        row(dist, v)

# FLA ships under a per-family name; find whichever one is here.
fla = [d.metadata["Name"] for d in md.distributions()
       if (d.metadata["Name"] or "").startswith(("flash-linear-attention", "flash-attn"))]
row("FLA / flash-attn", ", ".join("%s %s" % (n, ver(n)) for n in sorted(set(fla))) or "not installed")
PY

# ── the toolchain a kernel build needs ───────────────────────────────────────
have=""
for c in git tmux rsync cmake ninja gcc g++ make patch clang mfcli npu-smi; do
    command -v "$c" >/dev/null 2>&1 && have+="${c} "
done
row "tools present" "${have:-none}"
row "dev tools dir" "$( [[ -d "${DEV_TOOLS_DIR}" ]] \
    && echo "${DEV_TOOLS_DIR} exists ($(ls "${DEV_TOOLS_DIR}" 2>/dev/null | tr '\n' ' '))" \
    || echo "${DEV_TOOLS_DIR} absent — run_container.sh mounts tools/ there" )"

# ── verdict ──────────────────────────────────────────────────────────────────
# A CANN toolkit, torch-npu and a compiler. Everything else is convenience.
echo
miss=""
[[ -f "${ASCEND_HOME}/ascend-toolkit/set_env.sh" ]] || miss+="CANN toolkit, "
python3 -c 'import importlib.metadata as m; m.version("torch-npu")' 2>/dev/null || miss+="torch-npu, "
command -v cmake >/dev/null 2>&1 || miss+="cmake, "
command -v gcc   >/dev/null 2>&1 || miss+="gcc, "
if [[ -n "${miss}" ]]; then
    echo "  VERDICT: NOT usable as-is — missing: ${miss%, }"
    echo "           Build on top of it instead: BASE_IMAGE=<this> BASE_KIND=ready ./build_image.sh"
else
    echo "  VERDICT: usable as-is. Point a5.env's IMAGE at it and run ./run_container.sh"
    echo "           Your checkouts replace the vllm / vllm-ascend above (pip uninstall,"
    echo "           then pip install -e), and the custom kernels are rebuilt in YOUR"
    echo "           checkout — the image's .so belongs to the image's sources."
fi
