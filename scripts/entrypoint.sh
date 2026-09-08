#!/usr/bin/env bash
#
# Container entrypoint: prepares the data volume, guarantees a stable
# machine-id (required for persistent server authentication), drops to the
# unprivileged user and hands over to start-server.sh.
#
set -euo pipefail

DATA_DIR="${HYTALE_DATA:-/data}"
SCRIPTS_DIR="${HYTALE_HOME:-/opt/hytale}/scripts"

PUID="${PUID:-1000}"
PGID="${PGID:-1000}"

log() {
    echo "[entrypoint] $*"
}

# ---------------------------------------------------------------------------
# User / permissions
# ---------------------------------------------------------------------------
# Adjust the hytale user's ids when PUID/PGID are overridden so bind-mounted
# host folders stay writable. Ownership is changed by numeric id so this also
# works when the group 1000 has a different name in the image.
if [ "${PGID}" != "1000" ]; then
    log "Adjusting hytale group to PGID=${PGID}"
    groupmod -o -g "${PGID}" "$(id -gn hytale)"
fi
if [ "${PUID}" != "1000" ]; then
    log "Adjusting hytale user to PUID=${PUID}"
    usermod -o -u "${PUID}" -g "${PGID}" hytale
fi

mkdir -p "${DATA_DIR}"
chown -R "${PUID}:${PGID}" "${DATA_DIR}"

# ---------------------------------------------------------------------------
# Stable machine-id
# ---------------------------------------------------------------------------
# The Hytale server encrypts its persisted auth tokens (Server/auth.enc)
# against the host machine-id. A container gets a random machine-id on every
# recreate, which would force a fresh /auth login device each time. Persist a
# generated id inside the data volume and install it into /etc/machine-id on
# every boot so the encrypted auth keeps working across restarts.
MACHINE_ID_STORE="${DATA_DIR}/.machine-id"
if [ ! -s "${MACHINE_ID_STORE}" ]; then
    log "Generating persistent machine-id"
    # 32 hex chars, same format as systemd's machine-id.
    od -vN 16 -An -tx1 /dev/urandom | tr -d ' \n' > "${MACHINE_ID_STORE}"
    chown hytale:hytale "${MACHINE_ID_STORE}"
fi
install -m 0644 "${MACHINE_ID_STORE}" /etc/machine-id

# ---------------------------------------------------------------------------
# Handover
# ---------------------------------------------------------------------------
log "Starting Hytale server as hytale (PUID=$(id -u hytale), PGID=$(id -g hytale))"
exec gosu hytale "${SCRIPTS_DIR}/start-server.sh"
