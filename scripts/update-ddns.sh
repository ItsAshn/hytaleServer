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
#   cloudflare — your own domain on Cloudflare DNS
#                (DDNS_API_TOKEN, DDNS_ZONE_NAME=example.com,
#                 DDNS_HOSTNAME=play.example.com — comma-separate several
#                 records; optional DDNS_TTL / DDNS_PROXIED)
#   duckdns    — https://www.duckdns.org (DDNS_HOSTNAME=name.duckdns.org, DDNS_TOKEN)
#   noip       — https://www.noip.com    (DDNS_HOSTNAME, DDNS_USERNAME, DDNS_PASSWORD)
#   custom     — any update URL; {IP} in DDNS_UPDATE_URL is replaced with the
#                detected public IP, e.g.
#                DDNS_UPDATE_URL="https://api.example.com/set?host=home&ip={IP}"
#   manual     — DNS record only created once (any other DNS host, or a static
#                IP): point an A record at the current public IP and log the
#                address players should use. No ongoing updates.
#
set -euo pipefail

PROVIDER="${DDNS_PROVIDER:-}"
HOSTNAME="${DDNS_HOSTNAME:-}"
TOKEN="${DDNS_TOKEN:-}"
USERNAME="${DDNS_USERNAME:-}"
PASSWORD="${DDNS_PASSWORD:-}"
UPDATE_URL="${DDNS_UPDATE_URL:-}"
API_TOKEN="${DDNS_API_TOKEN:-}"
ZONE_NAME="${DDNS_ZONE_NAME:-}"
CF_TTL="${DDNS_TTL:-1}"           # 1 = "auto" at Cloudflare
CF_PROXIED="${DDNS_PROXIED:-false}"
INTERVAL="${DDNS_INTERVAL:-300}"

CF_API="https://api.cloudflare.com/client/v4"

log() {
    # stderr, so messages from inside a command substitution
    # (response="$(update_dns ...)") are not captured as the response.
    echo "[ddns] $*" >&2
}

public_ip() {
    curl -fsS --max-time 15 https://api.ipify.org \
        || curl -fsS --max-time 15 https://ifconfig.me \
        || curl -fsS --max-time 15 https://checkip.amazonaws.com
}

# --- Cloudflare -------------------------------------------------------------

cf_api() {
    # cf_api <method> <path> [json-body]
    local method="$1" path="$2" body="${3:-}"
    local args=(-fsS --max-time 30 -X "${method}"
        -H "Authorization: Bearer ${DDNS_API_TOKEN}"
        -H "Content-Type: application/json")
    [ -n "${body}" ] && args+=(--data "${body}")
    curl "${args[@]}" "${CF_API}${path}"
}

cf_zone_id() {
    local response
    response="$(cf_api GET "/zones?name=${ZONE_NAME}")" \
        || { log "ERROR: Cloudflare zone lookup failed (check DDNS_API_TOKEN / network)"; return 1; }
    jq -er '.result[0].id // empty' <<<"${response}" \
        || { log "ERROR: zone '${ZONE_NAME}' not found in this Cloudflare account (check DDNS_ZONE_NAME)"; return 1; }
}

cf_update_record() {
    # cf_update_record <zone-id> <record-name> <ip>
    local zone_id="$1" name="$2" ip="$3"
    local payload response
    payload="$(jq -cn --arg name "${name}" --arg ip "${ip}" \
        --argjson ttl "${CF_TTL}" --argjson proxied "${CF_PROXIED}" \
        '{type: "A", name: $name, content: $ip, ttl: $ttl, proxied: $proxied}')"

    response="$(cf_api GET "/zones/${zone_id}/dns_records?type=A&name=${name}")" \
        || { log "ERROR: DNS record lookup failed for ${name}"; return 1; }
    local record_id current_ip
    record_id="$(jq -r '.result[0].id // empty' <<<"${response}")"
    current_ip="$(jq -r '.result[0].content // empty' <<<"${response}")"

    if [ -n "${record_id}" ]; then
        if [ "${current_ip}" = "${ip}" ]; then
            log "${name}: already up to date (${ip})"
            return 0
        fi
        response="$(cf_api PUT "/zones/${zone_id}/dns_records/${record_id}" "${payload}")" \
            || { log "ERROR: updating ${name} failed"; return 1; }
    else
        response="$(cf_api POST "/zones/${zone_id}/dns_records" "${payload}")" \
            || { log "ERROR: creating ${name} failed"; return 1; }
    fi

    if jq -e '.success == true' <<<"${response}" >/dev/null 2>&1; then
        log "${name}: record now points at ${ip}"
    else
        log "ERROR: Cloudflare rejected the update for ${name}: $(jq -rc '.errors // .' <<<"${response}")"
        return 1
    fi
}

# --- Provider dispatch ------------------------------------------------------

update_dns() {
    local ip="$1"
    case "${PROVIDER}" in
        cloudflare)
            local zone_id name failed=0
            zone_id="$(cf_zone_id)" || return 1
            # Comma-separated list, e.g. "play.example.com,example.com".
            for name in ${HOSTNAME//,/ }; do
                cf_update_record "${zone_id}" "${name}" "${ip}" || failed=1
            done
            return "${failed}"
            ;;
        duckdns)
            # DuckDNS expects the bare subdomain, not the FQDN.
            local domain="${HOSTNAME%.duckdns.org}"
            curl -fsS --max-time 20 \
                "https://www.duckdns.org/update?domains=${domain}&token=${TOKEN}&ip=${ip}"
            ;;
        noip)
            curl -fsS --max-time 20 \
                "https://${USERNAME}:${PASSWORD}@dynupdate.no-ip.com/nic/update?hostname=${HOSTNAME}&myip=${ip}"
            ;;
        custom)
            curl -fsS --max-time 20 "${UPDATE_URL//\{IP\}/${ip}}"
            ;;
        *)
            log "ERROR: unknown DDNS_PROVIDER '${PROVIDER}' (expected cloudflare, duckdns, noip, custom or manual)"
            exit 1
            ;;
    esac
}

# --- Preflight ---------------------------------------------------------------

if [ -z "${PROVIDER}" ]; then
    log "ERROR: set DDNS_PROVIDER (see .env.example)"
    exit 1
fi

case "${PROVIDER}" in
    cloudflare)
        if [ -z "${API_TOKEN}" ] || [ -z "${ZONE_NAME}" ] || [ -z "${HOSTNAME}" ]; then
            log "ERROR: cloudflare needs DDNS_API_TOKEN, DDNS_ZONE_NAME and DDNS_HOSTNAME (see .env.example)"
            exit 1
        fi
        ;;
    noip)
        if [ -z "${HOSTNAME}" ] || [ -z "${USERNAME}" ] || [ -z "${PASSWORD}" ]; then
            log "ERROR: noip needs DDNS_HOSTNAME, DDNS_USERNAME and DDNS_PASSWORD (see .env.example)"
            exit 1
        fi
        ;;
    duckdns)
        if [ -z "${HOSTNAME}" ] || [ -z "${TOKEN}" ]; then
            log "ERROR: duckdns needs DDNS_HOSTNAME and DDNS_TOKEN (see .env.example)"
            exit 1
        fi
        ;;
    custom)
        if [ -z "${UPDATE_URL}" ]; then
            log "ERROR: custom needs DDNS_UPDATE_URL with an {IP} placeholder (see .env.example)"
            exit 1
        fi
        ;;
    manual) ;; # nothing required
    *)
        log "ERROR: unknown DDNS_PROVIDER '${PROVIDER}' (expected cloudflare, duckdns, noip, custom or manual)"
        exit 1
        ;;
esac

# --- Main --------------------------------------------------------------------

# Manual: nothing to update — just tell the user where to point their DNS.
if [ "${PROVIDER}" = "manual" ]; then
    ip="$(public_ip | tr -d '[:space:]' || true)"
    if [ -n "${ip}" ]; then
        log "Public IP is ${ip}"
        log "Create/update an A record for your domain pointing at ${ip}, then players connect to <your-domain>:5520"
    else
        log "WARNING: could not determine public IP (check outbound connectivity)"
    fi
    log "Nothing more to do (DDNS_PROVIDER=manual) — sidecar exiting. Remove --profile ddns once your DNS is set."
    exit 0
fi

log "Starting DDNS updater: provider=${PROVIDER} hostname=${HOSTNAME:-<from URL>} interval=${INTERVAL}s"

last_ip=""
while true; do
    current_ip="$(public_ip | tr -d '[:space:]' || true)"
    if [ -z "${current_ip}" ]; then
        log "WARNING: could not determine public IP; retrying in ${INTERVAL}s"
    elif [ "${current_ip}" != "${last_ip}" ]; then
        # Only remember the IP after a successful update, so a failed attempt
        # is retried on the next pass instead of being skipped.
        if response="$(update_dns "${current_ip}")"; then
            [ -n "${response}" ] && log "IP changed -> ${current_ip}; update response: ${response}"
            last_ip="${current_ip}"
        else
            log "WARNING: DNS update failed for ${current_ip}; retrying in ${INTERVAL}s"
        fi
    fi
    sleep "${INTERVAL}"
done
