#!/usr/bin/env bash
#
# Runs the Hytale dedicated server. Responsibilities:
#   1. Download/update the server files (unless disabled)
#   2. Generate Server/config.json from environment variables on first boot
#   3. Automate the one-time device-flow auth and enable encrypted auth
#      persistence so restarts are fully headless
#   4. Forward a FIFO to the server console and shut down cleanly on SIGTERM
#
set -euo pipefail

DATA_DIR="${HYTALE_DATA:-/data}"
SCRIPTS_DIR="${HYTALE_HOME:-/opt/hytale}/scripts"
SERVER_DIR="${DATA_DIR}/Server"
CONFIG_FILE="${SERVER_DIR}/config.json"
AUTH_FILE="${SERVER_DIR}/auth.enc"

# Tunables (see .env.example for documentation).
MEMORY="${MEMORY:-4G}"
SERVER_PORT="${SERVER_PORT:-5520}"
BIND_ADDRESS="${BIND_ADDRESS:-0.0.0.0}"
AUTH_MODE="${AUTH_MODE:-authenticated}"
PATCHLINE="${PATCHLINE:-release}"
DOWNLOAD_ON_START="${DOWNLOAD_ON_START:-true}"
AUTO_AUTH="${AUTO_AUTH:-true}"
AUTH_PERSISTENCE="${AUTH_PERSISTENCE:-Encrypted}"
USE_AOT_CACHE="${USE_AOT_CACHE:-true}"
JVM_ARGS="${JVM_ARGS:-}"
EXTRA_ARGS="${EXTRA_ARGS:-}"
SERVER_NAME="${SERVER_NAME:-Hytale Server}"
MOTD="${MOTD:-}"
MAX_PLAYERS="${MAX_PLAYERS:-20}"
MAX_VIEW_RADIUS="${MAX_VIEW_RADIUS:-12}"
GAME_MODE="${GAME_MODE:-Adventure}"
WORLD_NAME="${WORLD_NAME:-default}"

export PATCHLINE

log() {
    echo "[server] $*"
}

# ---------------------------------------------------------------------------
# 1. Download / update
# ---------------------------------------------------------------------------
if [ "${DOWNLOAD_ON_START}" = "true" ]; then
    "${SCRIPTS_DIR}/download-server.sh"
elif [ ! -f "${SERVER_DIR}/HytaleServer.jar" ]; then
    log "ERROR: DOWNLOAD_ON_START=false but no server files are installed in ${DATA_DIR}."
    exit 1
fi

# ---------------------------------------------------------------------------
# 2. Default config.json (only when none exists — never overwrites changes)
# ---------------------------------------------------------------------------
if [ ! -f "${CONFIG_FILE}" ]; then
    log "Creating default Server/config.json"
    jq -n \
        --arg serverName "${SERVER_NAME}" \
        --arg motd "${MOTD}" \
        --arg world "${WORLD_NAME}" \
        --arg gameMode "${GAME_MODE}" \
        --argjson maxPlayers "${MAX_PLAYERS}" \
        --argjson maxViewRadius "${MAX_VIEW_RADIUS}" \
        '{
            Version: 3,
            ServerName: $serverName,
            MOTD: $motd,
            Password: "",
            MaxPlayers: $maxPlayers,
            MaxViewRadius: $maxViewRadius,
            Defaults: { World: $world, GameMode: $gameMode },
            ConnectionTimeouts: { JoinTimeouts: {} },
            RateLimit: {},
            Modules: {},
            LogLevels: {},
            Mods: {},
            DisplayTmpTagsInStrings: false,
            PlayerStorage: { Type: "Hytale" }
        }' > "${CONFIG_FILE}"
fi

# ---------------------------------------------------------------------------
# 3. Build the java command line
# ---------------------------------------------------------------------------
java_args=("-Xms${MEMORY}" "-Xmx${MEMORY}")

# The server ships an AOT cache (JEP 515) that noticeably speeds up boot.
if [ "${USE_AOT_CACHE}" = "true" ] && [ -f "${SERVER_DIR}/HytaleServer.aot" ]; then
    java_args+=("-XX:AOTCache=${SERVER_DIR}/HytaleServer.aot")
fi

# shellcheck disable=SC2206 # intentional word splitting for user-supplied flags
[ -n "${JVM_ARGS}" ] && java_args+=(${JVM_ARGS})

server_args=(
    "--assets" "${DATA_DIR}/Assets.zip"
    "--bind" "${BIND_ADDRESS}:${SERVER_PORT}"
    "--auth-mode" "${AUTH_MODE}"
    "--accept-early-plugins"
)

# Token-based auth path (alternative to the device flow, e.g. for providers).
[ -n "${HYTALE_SESSION_TOKEN:-}" ] && server_args+=("--session-token" "${HYTALE_SESSION_TOKEN}")
[ -n "${HYTALE_IDENTITY_TOKEN:-}" ] && server_args+=("--identity-token" "${HYTALE_IDENTITY_TOKEN}")
[ -n "${HYTALE_OWNER_UUID:-}" ] && server_args+=("--owner-uuid" "${HYTALE_OWNER_UUID}")
[ -n "${HYTALE_OWNER_NAME:-}" ] && server_args+=("--owner-name" "${HYTALE_OWNER_NAME}")

# shellcheck disable=SC2206 # intentional word splitting for user-supplied flags
[ -n "${EXTRA_ARGS}" ] && server_args+=(${EXTRA_ARGS})

# ---------------------------------------------------------------------------
# 4. Console FIFO + auth automation
# ---------------------------------------------------------------------------
# Server console commands are fed through a FIFO; a log watcher sends the
# /auth commands at the right moments. Encrypted persistence writes auth.enc
# (decryptable only with the stable machine-id installed by entrypoint.sh),
# which makes all later restarts fully headless.
CONSOLE_FIFO="${DATA_DIR}/.console-in"
rm -f "${CONSOLE_FIFO}"
mkfifo "${CONSOLE_FIFO}"

console_log="${DATA_DIR}/logs/latest-console.log"

auth_watcher() {
    [ "${AUTO_AUTH}" = "true" ] || return 0
    # Wait until the log file exists, then follow the server output.
    while [ ! -f "${console_log}" ]; do sleep 1; done
    while IFS= read -r line; do
        case "${line}" in
            *"No server tokens configured"*|*"Use /auth login"*)
                if [ ! -f "${AUTH_FILE}" ]; then
                    log "Starting device auth — open the URL printed in the log and confirm with your Hytale account."
                    printf '/auth login device\n' > "${CONSOLE_FIFO}"
                fi
                ;;
            *"Multiple profiles available"*)
                printf '/auth select %s\n' "${AUTH_SELECT_PROFILE:-1}" > "${CONSOLE_FIFO}"
                ;;
            *"Authentication successful"*)
                if [ ! -f "${AUTH_FILE}" ]; then
                    log "Authentication successful — enabling encrypted persistence (${AUTH_PERSISTENCE})."
                    printf '/auth persistence %s\n' "${AUTH_PERSISTENCE}" > "${CONSOLE_FIFO}"
                fi
                ;;
        esac
    done < <(tail -n +1 -F "${console_log}" 2>/dev/null)
}

mkdir -p "${DATA_DIR}/logs"
auth_watcher &
WATCHER_PID=$!

# ---------------------------------------------------------------------------
# 5. Run the server (restart on exit code 8 = in-game /update requested)
# ---------------------------------------------------------------------------
shutdown() {
    log "Shutdown requested — stopping server (this can take a few seconds)"
    if [ -n "${JAVA_PID:-}" ] && kill -0 "${JAVA_PID}" 2>/dev/null; then
        printf '/stop\n' > "${CONSOLE_FIFO}" 2>/dev/null || true
        # Give the server a moment to save; SIGTERM follows via docker's grace period.
        for _ in $(seq 1 25); do
            kill -0 "${JAVA_PID}" 2>/dev/null || break
            sleep 1
        done
        kill -TERM "${JAVA_PID}" 2>/dev/null || true
        wait "${JAVA_PID}" 2>/dev/null || true
    fi
    exit 0
}
trap shutdown TERM INT

cd "${SERVER_DIR}"

while true; do
    log "Starting Hytale server (port ${SERVER_PORT}/udp, memory ${MEMORY}, patchline ${PATCHLINE})"

    # The FIFO is kept open by fd 3 so the writer side never sees EOF.
    exec 3<>"${CONSOLE_FIFO}"
    java "${java_args[@]}" -jar HytaleServer.jar "${server_args[@]}" \
        < "${CONSOLE_FIFO}" \
        > >(tee -a "${console_log}") 2>&1 &
    JAVA_PID=$!
    wait "${JAVA_PID}"
    exit_code=$?
    exec 3>&-

    if [ "${exit_code}" = "8" ]; then
        log "Server requested a restart to apply an update — downloading latest version."
        "${SCRIPTS_DIR}/download-server.sh" || log "Update failed; restarting with current version."
        continue
    fi

    log "Server process exited with code ${exit_code}"
    kill "${WATCHER_PID}" 2>/dev/null || true
    exit "${exit_code}"
done
