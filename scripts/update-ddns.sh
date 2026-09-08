#!/usr/bin/env bash
#
# Dynamic DNS updater sidecar.
#
# The Hytale server itself has no dynamic-IP handling: players reach your
# home-hosted server through a hostname whose DNS record this script keeps
# pointed at your current public IP. Point players at
#   <DDNS_HOSTNAME>:5520
# and their client will always resolve to wherever your connection is now.
#
# Supported providers:
#   duckdns  — https://www.duckdns.org (DDNS_HOSTNAME=name.duckdns.org, DDNS_TOKEN)
#   noip     — https://www.noip.com    (DDNS_HOSTNAME, DDNS_USERNAME, DDNS_PASSWORD)
#   custom   — any update URL; {IP} in DDNS_UPDATE_URL is replaced with the
#              detected public IP, e.g.
#              DDNS_UPDATE_URL="https://api.example.com/set?host=home&ip={IP}"
#
set -euo pipefail

PROVIDER="${DDNS_PROVIDER:-}"
HOSTNAME="${DDNS_HOSTNAME:-}"
TOKEN="${DDNS_TOKEN:-}"
USERNAME="${DDNS_USERNAME:-}"
PASSWORD="${DDNS_PASSWORD:-}"
UPDATE_URL="${DDNS_UPDATE_URL:-}"
INTERVAL="${DDNS_INTERVAL:-300}"

log() {
    echo "[ddns] $*"
}

public_ip() {
    curl -fsS --max-time 15 https://api.ipify.org \
        || curl -fsS --max-time 15 https://ifconfig.me \
        || curl -fsS --max-time 15 https://checkip.amazonaws.com
}

build_url() {
    local ip="$1"
    case "${PROVIDER}" in
        duckdns)
            # DuckDNS expects the bare subdomain, not the FQDN.
            local domain="${HOSTNAME%.duckdns.org}"
            echo "https://www.duckdns.org/update?domains=${domain}&token=${TOKEN}&ip=${ip}"
            ;;
        noip)
            echo "https://${USERNAME}:${PASSWORD}@dynupdate.no-ip.com/nic/update?hostname=${HOSTNAME}&myip=${ip}"
            ;;
        custom)
            echo "${UPDATE_URL//\{IP\}/${ip}}"
            ;;
        *)
            log "ERROR: unknown DDNS_PROVIDER '${PROVIDER}' (expected duckdns, noip or custom)"
            exit 1
            ;;
    esac
}

if [ -z "${PROVIDER}" ] || { [ "${PROVIDER}" != "custom" ] && [ -z "${HOSTNAME}" ]; }; then
    log "ERROR: set DDNS_PROVIDER and DDNS_HOSTNAME (see .env.example)"
    exit 1
fi

log "Starting DDNS updater: provider=${PROVIDER} hostname=${HOSTNAME:-<from URL>} interval=${INTERVAL}s"

last_ip=""
while true; do
    current_ip="$(public_ip | tr -d '[:space:]' || true)"
    if [ -z "${current_ip}" ]; then
        log "WARNING: could not determine public IP; retrying in ${INTERVAL}s"
    elif [ "${current_ip}" != "${last_ip}" ]; then
        response="$(curl -fsS --max-time 20 "$(build_url "${current_ip}")" || true)"
        log "IP changed -> ${current_ip}; update response: ${response:-<none>}"
        last_ip="${current_ip}"
    fi
    sleep "${INTERVAL}"
done
