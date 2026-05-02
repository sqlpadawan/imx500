#!/usr/bin/env bash
################################################################################
# IMX500 Capture Wrapper Script
################################################################################
# Wraps imx500_capture.py with sunrise/sunset gating. Called by the
# systemd service unit. Reads lat/long from config.json, sleeps until sunrise,
# runs the capture script until sunset, then exits cleanly.
#
# A clean exit tells systemd not to restart the service. The daily 03:00 timer
# restarts the service each morning, which re-evaluates sunrise/sunset for the
# current day.
#
# The HTTP and WebSocket server (imx500_server.py) runs as a separate always-on
# service and is NOT managed by this wrapper.
#
# Dependencies:
#   - astral (pip)
#   - config.json in the repo root with latitude and longitude fields
#   - imx500_server.service running (started at boot, independent of this script)
#
# Usage:
#   Called by systemd — not intended for direct invocation.
#   To test manually: bash imx500_capture_wrapper.sh
################################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_JSON="${SCRIPT_DIR}/config.json"
VENV_PYTHON="${HOME}/imx500_venv/bin/python3"
CAPTURE_SCRIPT="${SCRIPT_DIR}/imx500_capture.py"
LOG_DIR="/var/log/imx500"
LOG_FILE="${LOG_DIR}/wrapper.log"

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [${1}] ${2}" | tee -a "$LOG_FILE"
}

# ── Validate dependencies ─────────────────────────────────────────────────────
if [[ ! -f "$CONFIG_JSON" ]]; then
    log "ERROR" "config.json not found at $CONFIG_JSON"
    exit 1
fi

if [[ ! -f "$VENV_PYTHON" ]]; then
    log "ERROR" "Python venv not found at $VENV_PYTHON — run imx500pi_provision_python.sh first"
    exit 1
fi

if [[ ! -f "$CAPTURE_SCRIPT" ]]; then
    log "ERROR" "Capture script not found at $CAPTURE_SCRIPT"
    exit 1
fi

# ── Resolve sunrise/sunset via astral ────────────────────────────────────────
log "INFO" "Calculating sunrise/sunset from config.json..."

read -r SUNRISE_EPOCH SUNSET_EPOCH < <(
    "$VENV_PYTHON" - <<'PYEOF'
import json, os, sys
from pathlib import Path
from astral import LocationInfo
from astral.sun import sun
from datetime import datetime
from zoneinfo import ZoneInfo

script_dir = os.path.dirname(os.path.realpath(sys.argv[0]))
config_path = Path(script_dir) / "config.json"

with open(config_path) as f:
    config = json.load(f)

lat = config["location"]["latitude"]
lng = config["location"]["longitude"]

local_tz   = ZoneInfo("localtime")
today_local = datetime.now(local_tz).date()

location = LocationInfo(latitude=lat, longitude=lng)
s = sun(location.observer, date=today_local, tzinfo=local_tz)

print(int(s["sunrise"].timestamp()), int(s["sunset"].timestamp()))
PYEOF
)

if [[ -z "$SUNRISE_EPOCH" || -z "$SUNSET_EPOCH" ]]; then
    log "ERROR" "Failed to calculate sunrise/sunset times"
    exit 1
fi

NOW_EPOCH=$(date +%s)
SUNRISE_FMT=$(date -d "@${SUNRISE_EPOCH}" +'%H:%M:%S')
SUNSET_FMT=$(date -d  "@${SUNSET_EPOCH}"  +'%H:%M:%S')

log "INFO" "Today's sunrise: ${SUNRISE_FMT}  sunset: ${SUNSET_FMT}"

# ── Sleep until sunrise if we're early ───────────────────────────────────────
if [[ $NOW_EPOCH -lt $SUNRISE_EPOCH ]]; then
    SLEEP_S=$(( SUNRISE_EPOCH - NOW_EPOCH ))
    log "INFO" "Before sunrise — sleeping ${SLEEP_S}s until ${SUNRISE_FMT}"
    sleep "$SLEEP_S"
    log "INFO" "Sunrise reached — starting capture"
elif [[ $NOW_EPOCH -gt $SUNSET_EPOCH ]]; then
    log "INFO" "Already past sunset (${SUNSET_FMT}) — nothing to do today, exiting cleanly"
    exit 0
else
    log "INFO" "Within daylight window — starting capture immediately"
fi

# ── Calculate how long to run until sunset ───────────────────────────────────
NOW_EPOCH=$(date +%s)
RUN_S=$(( SUNSET_EPOCH - NOW_EPOCH ))

if [[ $RUN_S -le 0 ]]; then
    log "INFO" "Sunset already passed — exiting cleanly"
    exit 0
fi

log "INFO" "Capture will run for ${RUN_S}s (until ${SUNSET_FMT})"

# ── Rotate yesterday's event log if needed ───────────────────────────────────
EVENTS_LOG="${LOG_DIR}/events.jsonl"
if [[ -f "$EVENTS_LOG" ]]; then
    FILE_DATE=$(date -r "$EVENTS_LOG" +%Y-%m-%d)
    TODAY=$(date +%Y-%m-%d)
    if [[ "$FILE_DATE" != "$TODAY" ]]; then
        ROTATE_NAME="${EVENTS_LOG}.${FILE_DATE}"
        if [[ -f "$ROTATE_NAME" ]]; then
            log "WARN" "Rotated file already exists: $ROTATE_NAME — skipping bash rotation (Python will handle it)"
        else
            mv "$EVENTS_LOG" "$ROTATE_NAME"
            log "INFO" "Rotated stale log: $(basename "$EVENTS_LOG") → $(basename "$ROTATE_NAME")"
        fi
    else
        log "INFO" "Event log is current (${FILE_DATE}) — no rotation needed"
    fi
else
    log "INFO" "No existing event log found — fresh start"
fi

# ── Build event log summary for dashboard ─────────────────────────────────────
log "INFO" "Building event summary for dashboard..."
"$VENV_PYTHON" "${SCRIPT_DIR}/build_summary.py" \
    --log-dir "$LOG_DIR" \
    --out "${LOG_DIR}/summary.json" \
    && log "INFO" "summary.json written" \
    || log "WARN" "build_summary.py failed — dashboard may show stale data"

# ── Launch capture script, kill at sunset ────────────────────────────────────
# ── Launch capture script, restart on crash, kill at sunset ──────────────────
while true; do
    NOW_EPOCH=$(date +%s)
    if [[ $NOW_EPOCH -ge $SUNSET_EPOCH ]]; then
        log "INFO" "Sunset reached — exiting"
        exit 0
    fi

    log "INFO" "Starting imx500_capture.py..."
    "$VENV_PYTHON" "$CAPTURE_SCRIPT" &
    CAPTURE_PID=$!
    log "INFO" "Capture PID: ${CAPTURE_PID}"

    # Wait for either the capture script to exit or sunset
    while kill -0 "$CAPTURE_PID" 2>/dev/null; do
        if [[ $(date +%s) -ge $SUNSET_EPOCH ]]; then
            log "INFO" "Sunset reached — stopping capture"
            kill -TERM "$CAPTURE_PID" 2>/dev/null || true
            sleep 3
            kill -KILL "$CAPTURE_PID" 2>/dev/null || true
            log "INFO" "Capture stopped at sunset"
            exit 0
        fi
        sleep 5
    done

    log "WARN" "Capture script exited unexpectedly — restarting in 10s"
    sleep 10
done

