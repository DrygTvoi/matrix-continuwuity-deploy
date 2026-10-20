#!/bin/sh
# Internal liveness checks for the Docker stack.
# Runs in the curlimages/curl container and publishes state changes to ntfy.

set -u

NTFY_URL="${NTFY_URL:-http://ntfy:8080}"
NTFY_TOPIC="${NTFY_TOPIC:-alerts}"
CHECK_INTERVAL="${CHECK_INTERVAL:-60}"
ALERT_REPEAT="${ALERT_REPEAT:-30}"
STATE_DIR="/tmp/hc"
mkdir -p "$STATE_DIR"

log() {
    printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

notify() {
    title="$1"
    body="$2"
    curl -fsS --max-time 8 \
        -X POST \
        -H "Title: ${title}" \
        -H "Priority: high" \
        -H "Tags: warning" \
        -d "${body}" \
        "${NTFY_URL}/${NTFY_TOPIC}" >/dev/null 2>&1 \
        || log "ntfy publish failed (${NTFY_URL}/${NTFY_TOPIC})"
}

check_one() {
    name="$1"
    url="$2"
    expect="$3"

    code="$(curl -sS --max-time 8 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null)" || code="000"
    if [ "$expect" = "any" ]; then
        if [ "$code" != "000" ]; then up=1; else up=0; fi
    else
        if [ "$code" = "$expect" ]; then up=1; else up=0; fi
    fi

    state_file="${STATE_DIR}/${name}"
    count_file="${STATE_DIR}/${name}.count"
    prev="$(cat "$state_file" 2>/dev/null || echo unknown)"

    if [ "$up" -eq 0 ]; then
        if [ "$prev" != "down" ]; then
            log "DOWN ${name} (${url}: HTTP ${code})"
            notify "Matrix: ${name} is down" "${name} did not answer at ${url} (HTTP ${code})."
            echo 0 > "$count_file"
        else
            count="$(cat "$count_file" 2>/dev/null || echo 0)"
            count=$((count + 1))
            if [ "$count" -ge "$ALERT_REPEAT" ]; then
                log "STILL DOWN ${name} (${url}: HTTP ${code})"
                notify "Matrix: ${name} is still down" "${name} remains unavailable at ${url} (HTTP ${code})."
                count=0
            fi
            echo "$count" > "$count_file"
        fi
        echo down > "$state_file"
    else
        if [ "$prev" = "down" ]; then
            log "UP ${name} (${url}: HTTP ${code})"
            notify "Matrix: ${name} is up" "${name} answers again at ${url} (HTTP ${code})."
        fi
        echo up > "$state_file"
        echo 0 > "$count_file"
    fi
}

log "healthcheck started (interval=${CHECK_INTERVAL}s, repeat=${ALERT_REPEAT})"
while true; do
    check_one caddy        "http://caddy:80/"                               any
    check_one continuwuity "http://continuwuity:8008/_matrix/client/versions" 200
    check_one element-web  "http://element-web:8080/"                        200
    check_one element-call "http://element-call:8080/"                       200
    check_one livekit      "http://livekit:7880/"                            any
    check_one lk-jwt       "http://lk-jwt:8080/healthz"                      200
    check_one ntfy         "http://ntfy:8080/v1/health"                        200
    sleep "$CHECK_INTERVAL"
done
