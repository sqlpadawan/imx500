#!/usr/bin/env bash
set -euo pipefail

################################################################################
# Raspberry Pi IMX500 Street Monitor Provisioning Script
################################################################################
# This script provisions a Raspberry Pi for headless operation as an AI
# camera street monitoring station. It enables the camera interface,
# optimizes GPU memory for the IMX500 camera stack, and prepares the
# log directory.
#
# Prerequisites:
# - Raspberry Pi OS / Debian Trixie (headless)
# - Internet connection established
# - User account already created
# - IMX500 AI camera connected via CSI ribbon cable
#
# Usage:
#   chmod +x imx500pi_provision.sh
#   sudo ./imx500pi_provision.sh <username>
#
# Arguments:
#   username - The non-root user account for SSH and systemd services
#
# Notes:
#   This script handles base OS provisioning only. Python packages and
#   application deployment are handled by separate scripts.
################################################################################

### Constants
readonly SCRIPT_VERSION="1.1.0"
readonly LOG_DIR="/var/log/imx500"
readonly LOG_FILE="${LOG_DIR}/imx500pi_provision.log"
readonly MIN_DISK_SPACE_MB=2048  # Minimum 2GB free (models + logs are large)

# Ensure log directory exists before the first log() call — including any
# failures that occur before argument validation completes. Section 3 sets
# final ownership and permissions once the target username is known.
mkdir -p "$LOG_DIR"

### Standardized logging function
log() {
    local level="$1"
    shift
    local message="$@"
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [$level] $message" | tee -a "$LOG_FILE"
}

### Check available disk space
check_disk_space() {
    log "INFO" "Checking available disk space..."

    local available_mb
    available_mb=$(df -BM / | awk 'NR==2 {print $4}' | sed 's/M//')

    log "INFO" "Available disk space: ${available_mb}MB"

    if [[ $available_mb -lt $MIN_DISK_SPACE_MB ]]; then
        log "ERROR" "Insufficient disk space: ${available_mb}MB available, ${MIN_DISK_SPACE_MB}MB required"
        return 1
    fi

    log "INFO" "Disk space check passed"
}

### Parse and validate arguments
if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <username>"
    echo ""
    echo "Arguments:"
    echo "  username - Existing non-root user for SSH and services"
    exit 1
fi

USERNAME="$1"

# Validate username format (alphanumeric, underscore, hyphen only)
if ! [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
    log "ERROR" "Invalid username format: $USERNAME"
    log "ERROR" "Username must start with lowercase letter or underscore, contain only lowercase letters, numbers, underscores, or hyphens"
    exit 1
fi

# Validate user exists
if ! id "$USERNAME" &>/dev/null; then
    log "ERROR" "User '$USERNAME' does not exist. Please create the user first."
    exit 1
fi

# Ensure script runs as root
if [[ $EUID -ne 0 ]]; then
    log "ERROR" "This script must be run as root (use sudo)"
    exit 1
fi

log "INFO" "Starting provisioning for user '$USERNAME' (script v$SCRIPT_VERSION)"

# Check disk space before proceeding
if ! check_disk_space; then
    exit 1
fi

################################################################################
### 1. Enable Camera Interface
################################################################################
log "INFO" "Enabling camera interface..."

# raspi-config method (works on Bookworm/Trixie)
if raspi-config nonint do_camera 0 2>&1 | tee -a "$LOG_FILE"; then
    log "INFO" "Camera interface enabled via raspi-config"
else
    log "WARN" "raspi-config camera enable returned non-zero; verifying config.txt directly..."
fi

CONFIG_FILE="/boot/firmware/config.txt"

# Add user to video group for camera access
if id -nG "$USERNAME" | grep -qw "video"; then
    log "INFO" "User '$USERNAME' already in video group"
else
    if usermod -aG video "$USERNAME"; then
        log "INFO" "Added '$USERNAME' to video group"
    else
        log "ERROR" "Failed to add '$USERNAME' to video group"
        exit 1
    fi
fi

################################################################################
### 2a. Enable User Lingering
################################################################################
log "INFO" "Enabling user lingering for $USERNAME..."
if loginctl enable-linger "$USERNAME"; then
    log "INFO" "Lingering enabled — user systemd instance will run at boot without login"
else
    log "ERROR" "Failed to enable lingering for $USERNAME"
    exit 1
fi

################################################################################
### 3. Optimize /boot/firmware/config.txt for Headless Mode
################################################################################
log "INFO" "Optimizing /boot/firmware/config.txt for headless operation..."

# Verify config file exists
if [[ ! -f "$CONFIG_FILE" ]]; then
    log "ERROR" "Config file not found: $CONFIG_FILE"
    exit 1
fi

# Backup original config with timestamp
BACKUP_FILE="${CONFIG_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
if cp "$CONFIG_FILE" "$BACKUP_FILE"; then
    log "INFO" "Created backup at $BACKUP_FILE"
    chmod 644 "$BACKUP_FILE"
else
    log "ERROR" "Failed to create backup of config file"
    exit 1
fi

# Function to safely add or update config entries
add_or_update_config() {
    local key="$1"
    local value="$2"
    local entry="${key}=${value}"

    # Validate key format
    if ! [[ "$key" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
        log "WARN" "Invalid config key format: $key"
        return 1
    fi

    # Check if key exists (uncommented)
    if grep -q "^${key}=" "$CONFIG_FILE"; then
        # Update existing entry
        sed -i "s|^${key}=.*|${entry}|" "$CONFIG_FILE"
        log "INFO" "Updated: $entry"
    else
        # Add new entry
        echo "$entry" >> "$CONFIG_FILE"
        log "INFO" "Added: $entry"
    fi
}

# GPU memory — 128MB required for IMX500 camera stack (VCHI/ISP initialization)
# NOTE: 16MB is too low — causes "Failed to open VCHI service connection" at boot
# which prevents libcamera and picamera2 from seeing the camera entirely.
add_or_update_config "gpu_mem" "128"

# ─────────────────────────────────────────────────────────────────
# IMX500 camera overlay (required)
#
# Explicitly loads the IMX500 sensor + on-sensor AI accelerator via
# device tree overlay. Do NOT rely on camera_auto_detect=1 for this —
# auto-detect has proven unreliable for the IMX500 on Debian Trixie,
# and a silent failure here means the Pi boots fine but picamera2
# can't see the camera or its inference output at all (no error,
# just an empty CSI connector as far as the kernel is concerned).
#
# Takes effect on next reboot only (device tree overlays are read
# at boot time, not hot-reloadable).
# ─────────────────────────────────────────────────────────────────
add_or_update_config "dtoverlay" "imx500"

log "INFO" "Boot configuration optimized"

################################################################################
### 4. Create IMX500 Log Directory
################################################################################
log "INFO" "Creating IMX500 log directory..."

# /var/log/imx500 is used by imx500_capture.py (TimedRotatingFileHandler)
# Must be owned by the service user, not root
if [[ ! -d "$LOG_DIR" ]]; then
    mkdir -p "$LOG_DIR"
    log "INFO" "Created $LOG_DIR"
fi

chown "${USERNAME}:${USERNAME}" "$LOG_DIR"
chmod 755 "$LOG_DIR"
log "INFO" "Set ownership of $LOG_DIR to $USERNAME"

################################################################################
### 5. Configure Persistent Journal Logging
################################################################################
log "INFO" "Configuring persistent systemd journal logging..."

JOURNALD_CONF="/etc/systemd/journald.conf"

# Enable persistent storage so journal survives reboots
if grep -q "^Storage=persistent" "$JOURNALD_CONF"; then
    log "INFO" "Journal persistence already configured"
else
    sed -i 's/^#Storage=.*/Storage=persistent/' "$JOURNALD_CONF"
    # If the line wasn't present at all (not just commented), add it
    if ! grep -q "^Storage=persistent" "$JOURNALD_CONF"; then
        echo "Storage=persistent" >> "$JOURNALD_CONF"
    fi
    systemctl restart systemd-journald
    log "INFO" "Journal persistence enabled: $JOURNALD_CONF"
fi

# Cap journal size to avoid filling the SD card over time
if grep -q "^SystemMaxUse=50M" "$JOURNALD_CONF"; then
    log "INFO" "Journal size cap already configured"
else
    sed -i 's/^#SystemMaxUse=.*/SystemMaxUse=50M/' "$JOURNALD_CONF"
    if ! grep -q "^SystemMaxUse=50M" "$JOURNALD_CONF"; then
        echo "SystemMaxUse=50M" >> "$JOURNALD_CONF"
    fi
    systemctl restart systemd-journald
    log "INFO" "Journal size cap set to 50M"
fi

################################################################################
### 6. Disable WiFi Power Management
################################################################################
log "INFO" "Disabling WiFi power management..."

# WiFi power management puts the radio to sleep during idle periods, causing
# latency spikes on SSH connections when the radio wakes to handle incoming
# packets. Defaults to ON in Raspberry Pi OS — disable for responsive SSH.
WIFI_PM_CONF="/etc/NetworkManager/conf.d/wifi-power-management.conf"

cat > "$WIFI_PM_CONF" << EOF
[connection]
wifi.powersave = 2
EOF

chmod 644 "$WIFI_PM_CONF"
log "INFO" "WiFi power management disabled: $WIFI_PM_CONF"
log "INFO" "Note: Takes effect after reboot or NetworkManager restart"

################################################################################
### 7. Configure Log Rotation
################################################################################
log "INFO" "Configuring log rotation..."

LOGROTATE_CONF="/etc/logrotate.d/imx500"

cat > "$LOGROTATE_CONF" << EOF
/var/log/imx500/*.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    create 0644 ${USERNAME} ${USERNAME}
}
EOF

if [[ -f "$LOGROTATE_CONF" ]]; then
    chmod 644 "$LOGROTATE_CONF"
    log "INFO" "Log rotation configured: $LOGROTATE_CONF"
else
    log "WARN" "Failed to create log rotation configuration"
fi

################################################################################
### 8. Final Summary
################################################################################
echo ""
log "INFO" "========================================="
log "INFO" "PROVISIONING COMPLETE"
log "INFO" "========================================="
log "INFO" "Script Version: $SCRIPT_VERSION"
log "INFO" "User: $USERNAME"
log "INFO" "Camera Interface: Enabled"
log "INFO" "Video Group: $USERNAME added"
log "INFO" "Boot Config: Optimized for headless (gpu_mem=128)"
log "INFO" "WiFi Power Mgmt: Disabled (prevents SSH keystroke lag)"
log "INFO" "Log Directory: $LOG_DIR (owned by $USERNAME)"
log "INFO" "Log Rotation: Configured"
log "INFO" "Log file: $LOG_FILE"
log "INFO" "Config backup: $BACKUP_FILE"
log "INFO" "========================================="
log "INFO" "Next steps:"
log "INFO" "  1. Reboot to apply boot config changes: sudo reboot"
log "INFO" "  2. After reboot, verify camera: python3 -c 'import libcamera; print(libcamera.__version__)'"
log "INFO" "  3. Run Python provisioning script: sudo ./imx500pi_provision_python.sh"
log "INFO" "  4. Run service provisioning script: sudo ./imx500pi_provision_service.sh"
log "INFO" "========================================="
