#!/usr/bin/env bash
set -euo pipefail

################################################################################
# Raspberry Pi IMX500 Street Monitor - Service Provisioning Script
################################################################################
# This script configures the IMX500 capture service for unattended headless
# operation. It prompts for location (zip code), resolves lat/long offline,
# writes config.json, installs the systemd user service and daily restart
# timer, and enables both to start on boot.
#
# The capture script runs only between sunrise and sunset, gated by a wrapper
# script that uses the astral library with coordinates from config.json.
#
# Prerequisites:
#   - imx500pi_provision.sh already run (base OS provisioning)
#   - imx500pi_provision_python.sh already run (venv + packages)
#   - Repo cloned to ~/imx500/
#   - config.json does not yet exist (or use --reset to overwrite)
#
# Usage:
#   chmod +x imx500pi_provision_service.sh
#   sudo ./imx500pi_provision_service.sh
#   sudo ./imx500pi_provision_service.sh --reset
#
# Arguments:
#   --reset    Remove existing config.json and re-provision from scratch
################################################################################

### Constants
readonly SCRIPT_VERSION="1.0.0"
readonly LOG_DIR="/var/log/imx500"
readonly LOG_FILE="${LOG_DIR}/imx500pi_provision_service.log"

### Logging function
log() {
    local level="$1"
    shift
    local message="$@"

    if [[ ! -d "$LOG_DIR" ]]; then
        mkdir -p "$LOG_DIR"
    fi

    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [$level] $message" | tee -a "$LOG_FILE"
}

### Parse arguments
RESET_MODE=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --reset)
            RESET_MODE=true
            shift
            ;;
        -h|--help)
            cat << EOF
Usage: $0 [OPTIONS]

Options:
  --reset    Remove existing config.json and re-provision from scratch
  -h, --help Show this help message
EOF
            exit 0
            ;;
        *)
            echo "ERROR: Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

### Ensure script runs as root
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root (use sudo)"
    exit 1
fi

### Determine actual user (not root when using sudo)
if [[ -n "${SUDO_USER:-}" ]]; then
    ACTUAL_USER="$SUDO_USER"
    ACTUAL_HOME=$(eval echo ~"$SUDO_USER")
else
    ACTUAL_USER="$USER"
    ACTUAL_HOME="$HOME"
fi

if ! id "$ACTUAL_USER" &>/dev/null; then
    log "ERROR" "User '$ACTUAL_USER' does not exist"
    exit 1
fi

### Helper — run systemctl --user as the actual user from a sudo context
# systemctl --user requires XDG_RUNTIME_DIR and DBUS_SESSION_BUS_ADDRESS,
# which are not available in a sudo shell. This helper sets them explicitly.
run_user_systemctl() {
    local uid
    uid=$(id -u "$ACTUAL_USER")
    sudo -u "$ACTUAL_USER" \
        XDG_RUNTIME_DIR="/run/user/${uid}" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" \
        systemctl --user "$@"
}

### Derived paths
REPO_DIR="${ACTUAL_HOME}/imx500"
VENV_PYTHON="${ACTUAL_HOME}/imx500_venv/bin/python3"
CONFIG_JSON="${REPO_DIR}/config.json"
WRAPPER_SCRIPT="${REPO_DIR}/imx500_capture_wrapper.sh"
SYSTEMD_USER_DIR="${ACTUAL_HOME}/.config/systemd/user"
SERVICE_FILE="${SYSTEMD_USER_DIR}/imx500_capture.service"
TIMER_FILE="${SYSTEMD_USER_DIR}/imx500_capture.timer"

log "INFO" "Starting service provisioning (script v$SCRIPT_VERSION)"
log "INFO" "User: $ACTUAL_USER"
log "INFO" "Repo: $REPO_DIR"

################################################################################
### Check Existing Provision State
################################################################################
check_existing_provision() {
    log "INFO" "========================================="
    log "INFO" "Checking existing provision state..."
    log "INFO" "========================================="

    local all_ok=true

    # config.json
    if [[ -f "$CONFIG_JSON" ]]; then
        local zip place
        zip=$(python3   -c "import json; d=json.load(open('$CONFIG_JSON')); print(d['location']['zip'])"   2>/dev/null || echo "unknown")
        place=$(python3 -c "import json; d=json.load(open('$CONFIG_JSON')); print(d['location']['place'])" 2>/dev/null || echo "unknown")
        log "INFO" "  [OK]      config.json exists (zip: $zip, place: $place)"
    else
        log "INFO" "  [MISSING] config.json not found — zip code will be prompted"
        all_ok=false
    fi

    # Wrapper script
    if [[ -f "$WRAPPER_SCRIPT" && -x "$WRAPPER_SCRIPT" ]]; then
        log "INFO" "  [OK]      Wrapper script exists and is executable"
    elif [[ -f "$WRAPPER_SCRIPT" ]]; then
        log "WARN" "  [WARN]    Wrapper script exists but is not executable — will fix"
    else
        log "INFO" "  [MISSING] Wrapper script not found: $WRAPPER_SCRIPT"
        all_ok=false
    fi

    # Systemd unit files
    if [[ -f "$SERVICE_FILE" ]]; then
        log "INFO" "  [OK]      Service unit exists: $SERVICE_FILE"
    else
        log "INFO" "  [MISSING] Service unit not found — will create"
        all_ok=false
    fi

    if [[ -f "$TIMER_FILE" ]]; then
        log "INFO" "  [OK]      Timer unit exists: $TIMER_FILE"
    else
        log "INFO" "  [MISSING] Timer unit not found — will create"
        all_ok=false
    fi

    # Service and timer runtime status
    local svc_enabled svc_active timer_enabled timer_active
    svc_enabled=$(run_user_systemctl is-enabled imx500_capture.service 2>/dev/null || echo "not-found")
    svc_active=$(run_user_systemctl is-active  imx500_capture.service 2>/dev/null || echo "inactive")
    timer_enabled=$(run_user_systemctl is-enabled imx500_capture.timer  2>/dev/null || echo "not-found")
    timer_active=$(run_user_systemctl is-active  imx500_capture.timer  2>/dev/null || echo "inactive")

    log "INFO" "  [INFO]    Service: enabled=$svc_enabled  active=$svc_active"
    log "INFO" "  [INFO]    Timer:   enabled=$timer_enabled  active=$timer_active"

    log "INFO" "========================================="

    if [[ "$all_ok" == true ]]; then
        log "INFO" "Environment appears fully provisioned"
        log "INFO" "Re-running will stop the service, rewrite unit files, and restart"
        log "INFO" "Use --reset to also wipe config.json and re-enter zip code"
    else
        log "INFO" "Some components are missing — provisioning will create them now"
    fi

    log "INFO" "========================================="
}

check_existing_provision

################################################################################
### 1. Validate Prerequisites
################################################################################
log "INFO" "Validating prerequisites..."

if [[ ! -d "$REPO_DIR" ]]; then
    log "ERROR" "Repo directory not found: $REPO_DIR"
    log "ERROR" "Clone the repo first: git clone <url> ~/imx500"
    exit 1
fi

if [[ ! -f "$VENV_PYTHON" ]]; then
    log "ERROR" "Python venv not found at $VENV_PYTHON"
    log "ERROR" "Run imx500pi_provision_python.sh first"
    exit 1
fi

if [[ ! -f "$WRAPPER_SCRIPT" ]]; then
    log "ERROR" "Wrapper script not found at $WRAPPER_SCRIPT"
    log "ERROR" "Ensure imx500_capture_wrapper.sh is present in the repo"
    exit 1
fi

# Verify astral is available in the venv (required for wrapper)
if ! sudo -u "$ACTUAL_USER" "$VENV_PYTHON" -c "import astral" 2>/dev/null; then
    log "ERROR" "astral not available in venv — run imx500pi_provision_python.sh first"
    exit 1
fi

# Verify pgeocode is available in the venv (required for zip resolution)
if ! sudo -u "$ACTUAL_USER" "$VENV_PYTHON" -c "import pgeocode" 2>/dev/null; then
    log "ERROR" "pgeocode not available in venv — run imx500pi_provision_python.sh first"
    exit 1
fi

log "INFO" "Prerequisites validated"

################################################################################
### 2. Handle Reset
################################################################################
if [[ "$RESET_MODE" == true ]]; then
    log "INFO" "Reset mode — removing existing config and service files..."

    # Stop and disable service/timer if running
    if run_user_systemctl is-active imx500_capture.service &>/dev/null; then
        run_user_systemctl stop imx500_capture.service || true
        log "INFO" "Service stopped"
    fi
    if run_user_systemctl is-enabled imx500_capture.timer &>/dev/null; then
        run_user_systemctl disable imx500_capture.timer || true
        log "INFO" "Timer disabled"
    fi

    [[ -f "$CONFIG_JSON" ]]  && rm -f "$CONFIG_JSON"  && log "INFO" "Removed $CONFIG_JSON"
    [[ -f "$SERVICE_FILE" ]] && rm -f "$SERVICE_FILE" && log "INFO" "Removed $SERVICE_FILE"
    [[ -f "$TIMER_FILE" ]]   && rm -f "$TIMER_FILE"   && log "INFO" "Removed $TIMER_FILE"

    log "INFO" "Reset complete — continuing with fresh provisioning..."
fi

################################################################################
### 3. Write config.json
################################################################################
log "INFO" "Configuring location..."

if [[ -f "$CONFIG_JSON" && "$RESET_MODE" == false ]]; then
    log "INFO" "config.json already exists at $CONFIG_JSON — skipping"
    log "INFO" "Use --reset to reconfigure"
else
    # Prompt for zip code
    while true; do
        echo ""
        read -r -p "Enter US zip code for sunrise/sunset calculation: " ZIP_CODE

        # Basic format validation
        if ! [[ "$ZIP_CODE" =~ ^[0-9]{5}$ ]]; then
            echo "ERROR: Zip code must be exactly 5 digits"
            continue
        fi

        # Resolve zip to lat/long using pgeocode
        log "INFO" "Resolving zip code $ZIP_CODE..."

        LOCATION_RESULT=$(sudo -u "$ACTUAL_USER" "$VENV_PYTHON" - <<PYEOF
import pgeocode, sys
nomi = pgeocode.Nominatim("us")
result = nomi.query_postal_code("${ZIP_CODE}")
if result is None or str(result.get("latitude", "")) == "nan":
    print("ERROR")
    sys.exit(1)
print(f"{result['place_name']},{result['state_name']},{result['latitude']:.6f},{result['longitude']:.6f}")
PYEOF
        )

        if [[ "$LOCATION_RESULT" == "ERROR" || -z "$LOCATION_RESULT" ]]; then
            echo "ERROR: Could not resolve zip code $ZIP_CODE — please try again"
            continue
        fi

        # Parse result
        PLACE_NAME=$(echo "$LOCATION_RESULT" | cut -d',' -f1)
        STATE_NAME=$(echo "$LOCATION_RESULT" | cut -d',' -f2)
        LATITUDE=$(echo "$LOCATION_RESULT"   | cut -d',' -f3)
        LONGITUDE=$(echo "$LOCATION_RESULT"  | cut -d',' -f4)

        echo ""
        echo "  Location: ${PLACE_NAME}, ${STATE_NAME}"
        echo "  Latitude: ${LATITUDE}"
        echo "  Longitude: ${LONGITUDE}"
        echo ""
        read -r -p "Is this correct? (yes/no): " CONFIRM

        if [[ "$CONFIRM" == "yes" ]]; then
            break
        fi
    done

    # Write config.json
    log "INFO" "Writing config.json..."

    cat > "$CONFIG_JSON" << EOF
{
  "location": {
    "zip": "${ZIP_CODE}",
    "place": "${PLACE_NAME}, ${STATE_NAME}",
    "latitude": ${LATITUDE},
    "longitude": ${LONGITUDE}
  },
  "logging": {
    "max_log_files": 30
  }
}
EOF

    chown "${ACTUAL_USER}:${ACTUAL_USER}" "$CONFIG_JSON"
    chmod 644 "$CONFIG_JSON"
    log "INFO" "config.json written to $CONFIG_JSON"
fi

################################################################################
### 4. Make Wrapper Script Executable
################################################################################
log "INFO" "Setting wrapper script permissions..."

if chmod +x "$WRAPPER_SCRIPT"; then
    log "INFO" "Wrapper script is executable: $WRAPPER_SCRIPT"
else
    log "ERROR" "Failed to set executable bit on wrapper script"
    exit 1
fi

################################################################################
### 5. Create Systemd User Directory
################################################################################
log "INFO" "Creating systemd user directory..."

if [[ ! -d "$SYSTEMD_USER_DIR" ]]; then
    sudo -u "$ACTUAL_USER" mkdir -p "$SYSTEMD_USER_DIR"
    log "INFO" "Created $SYSTEMD_USER_DIR"
else
    log "INFO" "$SYSTEMD_USER_DIR already exists"
fi

################################################################################
### 6. Stop Service Before Rewriting Unit Files
################################################################################
log "INFO" "Stopping service before rewriting unit files..."

if run_user_systemctl is-active imx500_capture.service &>/dev/null; then
    run_user_systemctl stop imx500_capture.service 2>&1 | tee -a "$LOG_FILE" || true
    log "INFO" "Service stopped"
else
    log "INFO" "Service was not running — nothing to stop"
fi

################################################################################
### 7. Write Systemd Service Unit
################################################################################
log "INFO" "Writing systemd service unit..."

cat > "$SERVICE_FILE" << EOF
[Unit]
Description=IMX500 AI Camera Street Monitor
Documentation=https://github.com/${ACTUAL_USER}/imx500
# Wait for network so the IP socket lookup in the capture script succeeds
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${REPO_DIR}
ExecStart=${WRAPPER_SCRIPT}
# Restart on crash/error but NOT on clean exit (exit 0 = past sunset, don't restart)
Restart=on-failure
RestartSec=10s
# Log stdout/stderr to the systemd journal (readable via journalctl --user -u imx500_capture)
StandardOutput=journal
StandardError=journal
# Environment
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=default.target
EOF

chown "${ACTUAL_USER}:${ACTUAL_USER}" "$SERVICE_FILE"
chmod 644 "$SERVICE_FILE"
log "INFO" "Service unit written: $SERVICE_FILE"

################################################################################
### 8. Write Systemd Timer Unit
################################################################################
log "INFO" "Writing systemd timer unit..."

cat > "$TIMER_FILE" << EOF
[Unit]
Description=IMX500 Capture Daily Restart Timer
# Restart the capture service each morning before sunrise to pick up the
# new day's sunrise/sunset times and clear any stale state.

[Timer]
# Fire at 03:00 local time daily (before earliest possible sunrise)
OnCalendar=*-*-* 03:00:00
# If the Pi was off at 03:00, fire as soon as it boots
Persistent=true
Unit=imx500_capture.service

[Install]
WantedBy=timers.target
EOF

chown "${ACTUAL_USER}:${ACTUAL_USER}" "$TIMER_FILE"
chmod 644 "$TIMER_FILE"
log "INFO" "Timer unit written: $TIMER_FILE"

################################################################################
### 9. Enable and Start Service and Timer
################################################################################
log "INFO" "Reloading systemd user daemon..."
run_user_systemctl daemon-reload
log "INFO" "Daemon reloaded"

log "INFO" "Enabling imx500_capture.service..."
if run_user_systemctl enable imx500_capture.service 2>&1 | tee -a "$LOG_FILE"; then
    log "INFO" "Service enabled"
else
    log "ERROR" "Failed to enable service"
    exit 1
fi

log "INFO" "Enabling imx500_capture.timer..."
if run_user_systemctl enable imx500_capture.timer 2>&1 | tee -a "$LOG_FILE"; then
    log "INFO" "Timer enabled"
else
    log "ERROR" "Failed to enable timer"
    exit 1
fi

log "INFO" "Starting imx500_capture.timer..."
if run_user_systemctl start imx500_capture.timer 2>&1 | tee -a "$LOG_FILE"; then
    log "INFO" "Timer started"
else
    log "ERROR" "Failed to start timer"
    exit 1
fi

log "INFO" "Starting imx500_capture.service..."
if run_user_systemctl start imx500_capture.service 2>&1 | tee -a "$LOG_FILE"; then
    log "INFO" "Service started"
else
    log "ERROR" "Failed to start service"
    exit 1
fi

################################################################################
### 10. Verify Service Status
################################################################################
log "INFO" "Verifying service and timer status..."

sleep 3  # Give systemd a moment to settle

SERVICE_STATUS=$(run_user_systemctl is-active imx500_capture.service 2>/dev/null || true)
TIMER_STATUS=$(run_user_systemctl is-active imx500_capture.timer  2>/dev/null || true)

log "INFO" "Service status: $SERVICE_STATUS"
log "INFO" "Timer status:   $TIMER_STATUS"

if [[ "$TIMER_STATUS" != "active" ]]; then
    log "WARN" "Timer does not appear to be active — check: systemctl --user status imx500_capture.timer"
fi

################################################################################
### 11. Final Summary
################################################################################
echo ""
log "INFO" "========================================="
log "INFO" "SERVICE PROVISIONING COMPLETE"
log "INFO" "========================================="
log "INFO" "Script Version: $SCRIPT_VERSION"
log "INFO" "User: $ACTUAL_USER"
log "INFO" "Repo: $REPO_DIR"
log "INFO" "Config: $CONFIG_JSON"
log "INFO" "Service: $SERVICE_FILE"
log "INFO" "Timer: $TIMER_FILE"
log "INFO" "Log file: $LOG_FILE"
log "INFO" "========================================="
log "INFO" "Useful commands:"
log "INFO" "  Status:      systemctl --user status imx500_capture.service"
log "INFO" "  Logs:        journalctl --user -u imx500_capture -f"
log "INFO" "  Stop:        systemctl --user stop imx500_capture.service"
log "INFO" "  Timer next:  systemctl --user list-timers imx500_capture.timer"
log "INFO" "  Event log:   tail -f /var/log/imx500/events.jsonl"
log "INFO" "========================================="
