#!/usr/bin/env bash
################################################################################
# IMX500 Capture Wrapper Script
################################################################################
# Wraps imx500_capture_log.py with sunrise/sunset gating. Called by the
# systemd service unit. Reads lat/long from config.json, sleeps until sunrise,
# runs the capture script until sunset, then exits cleanly.
#
# A clean exit tells systemd not to restart the service. The daily 03:00 timer
# restarts the service each morning, which re-evaluates sunrise/sunset for the
# current day.
#
# Dependencies:
#   - astral (pip)
#   - config.json in the repo root with latitude and longitude fields
#
# Usage:
#   Called by systemd — not intended for direct invocation.
#   To test manually: bash imx500_capture_wrapper.sh
################################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_JSON="${SCRIPT_DIR}/config.json"
VENV_PYTHON="${HOME}/imx500_venv/bin/python3"
CAPTURE_SCRIPT="${SCRIPT_DIR}/imx500_capture_log.py"
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
from datetime import date
from zoneinfo import ZoneInfo

# Find config.json relative to this script's real location
script_dir = os.path.dirname(os.path.realpath(sys.argv[0]))
config_path = Path(script_dir) / "config.json"

with open(config_path) as f:
    config = json.load(f)

lat = config["location"]["latitude"]
lng = config["location"]["longitude"]

# Use the system local timezone so today's date and times are correct locally
local_tz = ZoneInfo("localtime")

location = LocationInfo(latitude=lat, longitude=lng)
s = sun(location.observer, date=date.today(), tzinfo=local_tz)

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

# ── Launch capture script, kill at sunset ────────────────────────────────────
log "INFO" "Starting imx500_capture_log.py..."

"$VENV_PYTHON" "$CAPTURE_SCRIPT" &
CAPTURE_PID=$!

log "INFO" "Capture PID: ${CAPTURE_PID}"

# Wait for sunset or for the capture script to exit on its own
if wait_result=$(sleep "$RUN_S" & SLEEP_PID=$!
    wait -n $CAPTURE_PID $SLEEP_PID 2>/dev/null
    echo $?); then
    # Check if capture script is still running (sleep expired = sunset reached)
    if kill -0 "$CAPTURE_PID" 2>/dev/null; then
        log "INFO" "Sunset reached — stopping capture"
        kill -TERM "$CAPTURE_PID" 2>/dev/null || true
        # Give it a moment to shut down cleanly
        sleep 3
        kill -KILL "$CAPTURE_PID" 2>/dev/null || true
        log "INFO" "Capture stopped at sunset"
    else
        log "WARN" "Capture script exited before sunset"
    fi
fi

log "INFO" "Wrapper exiting cleanly"
exit 0
