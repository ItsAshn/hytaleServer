#!/usr/bin/env bash
#
# Downloads (or updates) the Hytale dedicated server using the official
# hytale-downloader CLI. Safe to run on every container start: when the
# installed version already matches the latest release, nothing happens.
#
# First run requires a one-time device-flow login with your Hytale account:
# watch the container logs, open the printed URL and enter the code. The
# downloader caches its refresh token in the data volume
# (.hytale-downloader-credentials.json), so every later run is hands-off.
#
set -euo pipefail

DATA_DIR="${HYTALE_DATA:-/data}"
PATCHLINE="${PATCHLINE:-release}"
DOWNLOADER_URL="https://downloader.hytale.com/hytale-downloader.zip"

TOOLS_DIR="${DATA_DIR}/.tools"
DOWNLOADER="${TOOLS_DIR}/hytale-downloader"
CREDENTIALS="${TOOLS_DIR}/.hytale-downloader-credentials.json"
VERSION_FILE="${DATA_DIR}/.server-version"
SERVER_JAR="${DATA_DIR}/Server/HytaleServer.jar"
GAME_ZIP="${DATA_DIR}/game.zip"

log() {
    echo "[download] $*"
}

# ---------------------------------------------------------------------------
# Fetch the downloader binary (cached in the data volume)
# ---------------------------------------------------------------------------
mkdir -p "${TOOLS_DIR}"

if [ ! -x "${DOWNLOADER}" ]; then
    log "Fetching hytale-downloader"
    tmp_zip="$(mktemp)"
    curl -fsSL "${DOWNLOADER_URL}" -o "${tmp_zip}"
    unzip -o -q "${tmp_zip}" -d "${TOOLS_DIR}"
    rm -f "${tmp_zip}"
    # The zip ships per-platform binaries; keep the linux amd64 one.
    if [ -f "${TOOLS_DIR}/hytale-downloader-linux-amd64" ]; then
        mv "${TOOLS_DIR}/hytale-downloader-linux-amd64" "${DOWNLOADER}"
    fi
    chmod +x "${DOWNLOADER}"
fi

# ---------------------------------------------------------------------------
# Check whether an update is needed
# ---------------------------------------------------------------------------
latest_version="$("${DOWNLOADER}" -credentials-path "${CREDENTIALS}" -patchline "${PATCHLINE}" -print-version 2>/dev/null | tr -d '[:space:]')"
installed_version=""
[ -f "${VERSION_FILE}" ] && installed_version="$(cat "${VERSION_FILE}")"

if [ -f "${SERVER_JAR}" ] && [ -n "${latest_version}" ] && [ "${installed_version}" = "${latest_version}" ]; then
    log "Server is up to date (${installed_version})"
    exit 0
fi

log "Downloading server version: ${latest_version:-unknown} (patchline: ${PATCHLINE})"
log "If this is the first run, follow the login URL printed by the downloader below."

# ---------------------------------------------------------------------------
# Download and extract
# ---------------------------------------------------------------------------
rm -f "${GAME_ZIP}"
"${DOWNLOADER}" \
    -credentials-path "${CREDENTIALS}" \
    -patchline "${PATCHLINE}" \
    -download-path "${GAME_ZIP}"

rm -rf "${DATA_DIR}/Server" "${DATA_DIR}/Assets.zip"
unzip -q "${GAME_ZIP}" -d "${DATA_DIR}"
rm -f "${GAME_ZIP}"

if [ ! -f "${SERVER_JAR}" ]; then
    log "ERROR: ${SERVER_JAR} missing after extraction"
    exit 1
fi

if [ -n "${latest_version}" ]; then
    echo "${latest_version}" > "${VERSION_FILE}"
fi

log "Server ${latest_version:-unknown} installed in ${DATA_DIR}"
