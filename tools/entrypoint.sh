#!/usr/bin/env bash
# =============================================================================
#  entrypoint.sh — runs inside the container, once, before anything else:
#  sources the CANN environment so every later process (docker exec shells
#  included) sees it, then runs bootstrap_editable.sh, which pip install -e's
#  the bind-mounted checkouts and builds the custom kernels into the
#  vllm-ascend tree. BOOTSTRAP_ON_START=0 skips that second step.
#
#  A bootstrap failure is reported loudly but never kills the container — you
#  want a shell to debug in. The verdict lands in BOOTSTRAP_DONE_FLAG and
#  run_container.sh reads it. see NOTES.md: The bootstrap verdict, on every path in
#
#  No hardcoded paths, and this file need not be baked into the image:
#  run_container.sh starts the container with `--entrypoint bash <this file>`
#  and bind-mounts tools/ for an image ./build_image.sh did not make.
# =============================================================================
set -uo pipefail

DEV_TOOLS_DIR="${DEV_TOOLS_DIR:-/opt/vllm-dev}"
# Baked in by the Dockerfile, or bind-mounted from the host's tools/. Idempotent,
# so the login shells that source it again later cost nothing.
ASCEND_ENV_FILE="${ASCEND_ENV_FILE:-${DEV_TOOLS_DIR}/ascend_env.sh}"
if [[ -f "${ASCEND_ENV_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${ASCEND_ENV_FILE}"
    # HOME is the mounted host home, so the image's own .bashrc is never read;
    # profile.d is what gives later exec shells CANN. see NOTES.md: ascend_env.sh
    # picks exactly one toolkit
    mkdir -p /etc/profile.d 2>/dev/null
    if [[ ! -e /etc/profile.d/ascend_env.sh && -w /etc/profile.d ]]; then
        if printf 'source %s\n' "${ASCEND_ENV_FILE}" > /etc/profile.d/ascend_env.sh; then
            chmod 644 /etc/profile.d/ascend_env.sh
            echo "[entrypoint] /etc/profile.d/ascend_env.sh now sources ${ASCEND_ENV_FILE}"
        fi
    fi
else
    echo "[entrypoint] [warn] no ${ASCEND_ENV_FILE} — the CANN environment will be" >&2
    echo "[entrypoint] [warn] incomplete. If this container runs an image that is not" >&2
    echo "[entrypoint] [warn] ours, tools/ should have been mounted at ${DEV_TOOLS_DIR}." >&2
fi

BOOTSTRAP_ON_START="${BOOTSTRAP_ON_START:-1}"
BOOTSTRAP_LOG="${BOOTSTRAP_LOG:-/tmp/bootstrap_editable.log}"
# run_container.sh waits for this file and reads it: ok / failed / skipped.
DONE_FLAG="${BOOTSTRAP_DONE_FLAG:-/tmp/.vllm-dev-bootstrap-done}"
rm -f "${DONE_FLAG}"

if [[ "${BOOTSTRAP_ON_START}" == "1" ]]; then
    echo "[entrypoint] running bootstrap_editable.sh (log: ${BOOTSTRAP_LOG})"
    if bash "${DEV_TOOLS_DIR}/bootstrap_editable.sh" 2>&1 | tee "${BOOTSTRAP_LOG}"; then
        echo "[entrypoint] bootstrap OK"
        echo ok > "${DONE_FLAG}"
    else
        echo "" >&2
        echo "[entrypoint] [error] bootstrap_editable.sh FAILED — the container is" >&2
        echo "[entrypoint] [error] still up so you can debug. Full log: ${BOOTSTRAP_LOG}" >&2
        echo "[entrypoint] [error] Re-run it by hand with:" >&2
        echo "[entrypoint] [error]     bash ${DEV_TOOLS_DIR}/bootstrap_editable.sh --force-all" >&2
        echo "" >&2
        echo failed > "${DONE_FLAG}"
    fi
else
    echo "[entrypoint] BOOTSTRAP_ON_START=0 — skipping the editable bootstrap."
    echo skipped > "${DONE_FLAG}"
fi

exec "$@"
