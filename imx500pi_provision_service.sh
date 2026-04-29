#!/usr/bin/env bash
set -euo pipefail

################################################################################
# Raspberry Pi IMX500 Street Monitor - Service Provisioning Script
################################################################################
# Installs and configures two systemd user services:
#
#   imx500_server.service   — Always-on HTTP + WebSocket server (port 8080/8081)
#                             Starts at boot, runs 24/7.
#
#   imx500_capture.service  — Camera capture, inference, event logging.
#                             Gated to sunrise/sunset by wrapper script.
#                             Started by imx500_capture.timer at 03:00 daily.
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
readonly SCRIPT_VERSION="2.0.0"
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
SERVER_SCRIPT="${REPO_DIR}/imx500_server.py"
SYSTEMD_USER_DIR="${ACTUAL_HOME}/.config/systemd/user"
SERVER_SERVICE_FILE="${SYSTEMD_USER_DIR}/imx500_server.service"
CAPTURE_SERVICE_FILE="${SYSTEMD_USER_DIR}/imx500_capture.service"
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

    if [[ -f "$CONFIG_JSON" ]]; then
        local zip place
        zip=$(python3   -c "import json; d=json.load(open('$CONFIG_JSON')); print(d['location']['zip'])"   2>/dev/null || echo "unknown")
        place=$(python3 -c "import json; d=json.load(open('$CONFIG_JSON')); print(d['location']['place'])" 2>/dev/null || echo "unknown")
        log "INFO" "  [OK]      config.json exists (zip: $zip, place: $place)"
    else
        log "INFO" "  [MISSING] config.json not found — zip code will be prompted"
        all_ok=false
    fi

    if [[ -f "$WRAPPER_SCRIPT" && -x "$WRAPPER_SCRIPT" ]]; then
        log "INFO" "  [OK]      Wrapper script exists and is executable"
    elif [[ -f "$WRAPPER_SCRIPT" ]]; then
        log "WARN" "  [WARN]    Wrapper script exists but is not executable — will fix"
    else
        log "INFO" "  [MISSING] Wrapper script not found: $WRAPPER_SCRIPT"
        all_ok=false
    fi

    if [[ -f "$SERVER_SCRIPT" ]]; then
        log "INFO" "  [OK]      Server script exists: $SERVER_SCRIPT"
    else
        log "INFO" "  [MISSING] Server script not found: $SERVER_SCRIPT"
        all_ok=false
    fi

    for f in "$SERVER_SERVICE_FILE" "$CAPTURE_SERVICE_FILE" "$TIMER_FILE"; do
        if [[ -f "$f" ]]; then
            log "INFO" "  [OK]      $(basename $f) exists"
        else
            log "INFO" "  [MISSING] $(basename $f) not found — will create"
            all_ok=false
        fi
    done

    log "INFO" "========================================="
}

check_existing_provision

################################################################################
### 1. Validate Prerequisites
################################################################################
log "INFO" "Validating prerequisites..."

if [[ ! -d "$REPO_DIR" ]]; then
    log "ERROR" "Repo directory not found: $REPO_DIR"
    exit 1
fi

if [[ ! -f "$VENV_PYTHON" ]]; then
    log "ERROR" "Python venv not found at $VENV_PYTHON"
    exit 1
fi

if [[ ! -f "$WRAPPER_SCRIPT" ]]; then
    log "ERROR" "Wrapper script not found at $WRAPPER_SCRIPT"
    exit 1
fi

if [[ ! -f "$SERVER_SCRIPT" ]]; then
    log "ERROR" "Server script not found at $SERVER_SCRIPT"
    log "ERROR" "Ensure imx500_server.py is present in the repo"
    exit 1
fi

if ! sudo -u "$ACTUAL_USER" "$VENV_PYTHON" -c "import astral" 2>/dev/null; then
    log "ERROR" "astral not available in venv — run imx500pi_provision_python.sh first"
    exit 1
fi

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

    for svc in imx500_server.service imx500_capture.service imx500_capture.timer; do
        if run_user_systemctl is-active "$svc" &>/dev/null; then
            run_user_systemctl stop "$svc" || true
            log "INFO" "Stopped $svc"
        fi
        if run_user_systemctl is-enabled "$svc" &>/dev/null; then
            run_user_systemctl disable "$svc" || true
            log "INFO" "Disabled $svc"
        fi
    done

    for f in "$CONFIG_JSON" "$SERVER_SERVICE_FILE" "$CAPTURE_SERVICE_FILE" "$TIMER_FILE"; do
        [[ -f "$f" ]] && rm -f "$f" && log "INFO" "Removed $f"
    done

    log "INFO" "Reset complete — continuing with fresh provisioning..."
fi

################################################################################
### 3. Write config.json
################################################################################
log "INFO" "Configuring location..."

if [[ -f "$CONFIG_JSON" && "$RESET_MODE" == false ]]; then
    log "INFO" "config.json already exists — skipping (use --reset to reconfigure)"
else
    while true; do
        echo ""
        read -r -p "Enter US zip code for sunrise/sunset calculation: " ZIP_CODE

        if ! [[ "$ZIP_CODE" =~ ^[0-9]{5}$ ]]; then
            echo "ERROR: Zip code must be exactly 5 digits"
            continue
        fi

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
### 4. Make Scripts Executable
################################################################################
log "INFO" "Setting script permissions..."
chmod +x "$WRAPPER_SCRIPT"
log "INFO" "Wrapper script is executable"

################################################################################
### 5. Create Systemd User Directory
################################################################################
if [[ ! -d "$SYSTEMD_USER_DIR" ]]; then
    sudo -u "$ACTUAL_USER" mkdir -p "$SYSTEMD_USER_DIR"
    log "INFO" "Created $SYSTEMD_USER_DIR"
fi

################################################################################
### 6. Stop Services Before Rewriting Unit Files
################################################################################
for svc in imx500_server.service imx500_capture.service; do
    if run_user_systemctl is-active "$svc" &>/dev/null; then
        run_user_systemctl stop "$svc" 2>&1 | tee -a "$LOG_FILE" || true
        log "INFO" "Stopped $svc"
    fi
done

################################################################################
### 7. Write imx500_server.service
################################################################################
log "INFO" "Writing imx500_server.service..."

cat > "$SERVER_SERVICE_FILE" << EOF
[Unit]
Description=IMX500 HTTP and WebSocket Server
Documentation=https://github.com/${ACTUAL_USER}/imx500
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${REPO_DIR}
ExecStart=${VENV_PYTHON} ${REPO_DIR}/imx500_server.py
Restart=always
RestartSec=5s
StandardOutput=journal
StandardError=journal
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=default.target
EOF

chown "${ACTUAL_USER}:${ACTUAL_USER}" "$SERVER_SERVICE_FILE"
chmod 644 "$SERVER_SERVICE_FILE"
log "INFO" "imx500_server.service written"

################################################################################
### 8. Write imx500_capture.service
################################################################################
log "INFO" "Writing imx500_capture.service..."

cat > "$CAPTURE_SERVICE_FILE" << EOF
[Unit]
Description=IMX500 AI Camera Capture and Event Logger
Documentation=https://github.com/${ACTUAL_USER}/imx500
After=network-online.target imx500_server.service
Wants=network-online.target
Requires=imx500_server.service

[Service]
Type=simple
WorkingDirectory=${REPO_DIR}
ExecStart=${WRAPPER_SCRIPT}
Restart=on-failure
RestartSec=10s
StandardOutput=journal
StandardError=journal
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=default.target
EOF

chown "${ACTUAL_USER}:${ACTUAL_USER}" "$CAPTURE_SERVICE_FILE"
chmod 644 "$CAPTURE_SERVICE_FILE"
log "INFO" "imx500_capture.service written"

################################################################################
### 9. Write imx500_capture.timer
################################################################################
log "INFO" "Writing imx500_capture.timer..."

cat > "$TIMER_FILE" << EOF
[Unit]
Description=IMX500 Capture Daily Restart Timer

[Timer]
OnCalendar=*-*-* 03:00:00
Persistent=true
Unit=imx500_capture.service

[Install]
WantedBy=timers.target
EOF

chown "${ACTUAL_USER}:${ACTUAL_USER}" "$TIMER_FILE"
chmod 644 "$TIMER_FILE"
log "INFO" "imx500_capture.timer written"

################################################################################
### 10. Enable and Start Everything
################################################################################
log "INFO" "Reloading systemd user daemon..."
run_user_systemctl daemon-reload

log "INFO" "Enabling and starting imx500_server.service..."
run_user_systemctl enable imx500_server.service
run_user_systemctl start  imx500_server.service

log "INFO" "Enabling imx500_capture.service and timer..."
run_user_systemctl enable imx500_capture.service
run_user_systemctl enable imx500_capture.timer
run_user_systemctl start  imx500_capture.timer
run_user_systemctl start  imx500_capture.service

################################################################################
### 11. Verify
################################################################################
sleep 3

SERVER_STATUS=$(run_user_systemctl is-active imx500_server.service  2>/dev/null || true)
CAPTURE_STATUS=$(run_user_systemctl is-active imx500_capture.service 2>/dev/null || true)
TIMER_STATUS=$(run_user_systemctl is-active  imx500_capture.timer   2>/dev/null || true)

log "INFO" "imx500_server.service:  $SERVER_STATUS"
log "INFO" "imx500_capture.service: $CAPTURE_STATUS"
log "INFO" "imx500_capture.timer:   $TIMER_STATUS"

if [[ "$SERVER_STATUS" != "active" ]]; then
    log "WARN" "Server service does not appear active — check: systemctl --user status imx500_server.service"
fi

################################################################################
### 12. Final Summary
################################################################################
echo ""
log "INFO" "========================================="
log "INFO" "SERVICE PROVISIONING COMPLETE"
log "INFO" "========================================="
log "INFO" "Script Version: $SCRIPT_VERSION"
log "INFO" "User: $ACTUAL_USER"
log "INFO" "Repo: $REPO_DIR"
log "INFO" "Config: $CONFIG_JSON"
log "INFO" "========================================="
log "INFO" "Services:"
log "INFO" "  imx500_server.service   — always-on, starts at boot"
log "INFO" "  imx500_capture.service  — sunrise to sunset"
log "INFO" "  imx500_capture.timer    — restarts capture at 03:00 daily"
log "INFO" "========================================="
log "INFO" "Useful commands:"
log "INFO" "  imx500 status imx500_server.service"
log "INFO" "  imx500 status imx500_capture.service"
log "INFO" "  imx500 list-timers imx500_capture.timer"
log "INFO" "  journalctl --user -u imx500_server.service -f"
log "INFO" "  journalctl --user -u imx500_capture.service -f"
log "INFO" "  tail -f /var/log/imx500/events.jsonl"
log "INFO" "========================================="
