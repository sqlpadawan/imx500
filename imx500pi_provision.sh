#!/usr/bin/env bash
set -euo pipefail

################################################################################
# Raspberry Pi IMX500 Street Monitor Provisioning Script
################################################################################
# This script provisions a Raspberry Pi for headless operation as an AI
# camera street monitoring station. It performs system updates, enables the
# camera interface, installs base packages, optimizes power consumption, and
# configures the system for remote access.
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
readonly SCRIPT_VERSION="1.0.0"
readonly LOG_DIR="/var/log/imx500"
readonly LOG_FILE="${LOG_DIR}/imx500pi_provision.log"
readonly MIN_DISK_SPACE_MB=2048  # Minimum 2GB free (models + logs are large)

### Standardized logging function
log() {
    local level="$1"
    shift
    local message="$@"

    # Create log directory if it doesn't exist
    if [[ ! -d "$LOG_DIR" ]]; then
        mkdir -p "$LOG_DIR"
    fi

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
### 1. System Update
################################################################################
log "INFO" "Updating system packages..."
export DEBIAN_FRONTEND=noninteractive

# Update package lists with retry
update_package_lists() {
    local max_retries=3
    local retry_count=0

    while [[ $retry_count -lt $max_retries ]]; do
        if apt-get update -y 2>&1 | tee -a "$LOG_FILE"; then
            log "INFO" "Package lists updated successfully"
            return 0
        else
            retry_count=$((retry_count + 1))
            log "WARN" "Package list update failed (attempt $retry_count/$max_retries)"
            if [[ $retry_count -lt $max_retries ]]; then
                sleep 5
            fi
        fi
    done

    log "ERROR" "Failed to update package lists after $max_retries attempts"
    return 1
}

if ! update_package_lists; then
    log "WARN" "Continuing despite package list update failure..."
fi

# Upgrade system packages
log "INFO" "Upgrading system packages..."
if apt-get -y -o Dpkg::Options::="--force-confnew" full-upgrade 2>&1 | tee -a "$LOG_FILE"; then
    log "INFO" "System packages upgraded successfully"
else
    log "WARN" "Initial upgrade failed, retrying with --fix-missing..."
    if apt-get -y -o Dpkg::Options::="--force-confnew" full-upgrade --fix-missing 2>&1 | tee -a "$LOG_FILE"; then
        log "INFO" "System packages upgraded successfully (retry)"
    else
        log "ERROR" "System upgrade failed after retry"
        exit 1
    fi
fi

################################################################################
### 2. Enable I2C
################################################################################
log "INFO" "Enabling I2C interface..."

if raspi-config nonint do_i2c 0; then
    log "INFO" "I2C enabled successfully"
else
    log "ERROR" "Failed to enable I2C"
    exit 1
fi

# Verify I2C is enabled in config
if grep -q "^dtparam=i2c_arm=on" /boot/firmware/config.txt; then
    log "INFO" "I2C verified in config.txt"
else
    log "WARN" "I2C may not be properly configured in config.txt"
fi

# Ensure I2C kernel modules will load
if ! grep -q "^i2c-dev" /etc/modules; then
    echo "i2c-dev" >> /etc/modules
    log "INFO" "Added i2c-dev to /etc/modules"
fi

################################################################################
### 3. Enable Camera Interface
################################################################################
log "INFO" "Enabling camera interface..."

# raspi-config method (works on Bookworm/Trixie)
if raspi-config nonint do_camera 0 2>&1 | tee -a "$LOG_FILE"; then
    log "INFO" "Camera interface enabled via raspi-config"
else
    log "WARN" "raspi-config camera enable returned non-zero; verifying config.txt directly..."
fi

CONFIG_FILE="/boot/firmware/config.txt"

# Verify camera_auto_detect is set (required for IMX500 CSI detection)
if grep -q "^camera_auto_detect=1" "$CONFIG_FILE"; then
    log "INFO" "camera_auto_detect=1 verified in config.txt"
elif grep -q "^camera_auto_detect=0" "$CONFIG_FILE"; then
    sed -i "s|^camera_auto_detect=0|camera_auto_detect=1|" "$CONFIG_FILE"
    log "INFO" "Updated camera_auto_detect to 1 in config.txt"
else
    echo "camera_auto_detect=1" >> "$CONFIG_FILE"
    log "INFO" "Added camera_auto_detect=1 to config.txt"
fi

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
### 4. Disable WiFi Power Saving
################################################################################
log "INFO" "Disabling WiFi power saving..."

WLAN_CONF="/etc/NetworkManager/conf.d/wifi-powersave-off.conf"

# Create directory if it doesn't exist
mkdir -p "$(dirname "$WLAN_CONF")"

# Write configuration
cat > "$WLAN_CONF" << 'EOF'
[connection]
wifi.powersave = 2
EOF

if [[ -f "$WLAN_CONF" ]]; then
    log "INFO" "WiFi power saving disabled (will apply after reboot)"
    chmod 644 "$WLAN_CONF"
else
    log "WARN" "Failed to create WiFi power saving configuration"
fi

################################################################################
### 5. Install Required Base Packages
################################################################################
log "INFO" "Installing required base packages..."

# Base packages only — Python/picamera2/imx500 packages handled separately
readonly REQUIRED_PKGS=(
    rpi-connect-lite
    i2c-tools          # I2C device inspection (i2cdetect)
    v4l-utils          # Camera device inspection (v4l2-ctl)
    python3-libcamera  # Headless-safe libcamera Python bindings (no display deps)
)

install_package() {
    local pkg="$1"
    local max_retries=2
    local retry_count=0

    if dpkg -s "$pkg" &> /dev/null; then
        log "INFO" "$pkg already installed"
        return 0
    fi

    while [[ $retry_count -le $max_retries ]]; do
        log "INFO" "Installing $pkg (attempt $((retry_count + 1))/$((max_retries + 1)))..."

        if apt-get install -y "$pkg" 2>&1 | tee -a "$LOG_FILE"; then
            log "INFO" "$pkg installed successfully"
            return 0
        fi

        retry_count=$((retry_count + 1))
        if [[ $retry_count -le $max_retries ]]; then
            log "WARN" "Install failed, retrying with --fix-missing..."
            apt-get install -y "$pkg" --fix-missing 2>&1 | tee -a "$LOG_FILE" && return 0
        fi
    done

    log "ERROR" "Failed to install $pkg after all retry attempts"
    return 1
}

for pkg in "${REQUIRED_PKGS[@]}"; do
    if ! install_package "$pkg"; then
        log "ERROR" "Critical package installation failed: $pkg"
        exit 1
    fi
done

################################################################################
### 6. Enable User Lingering
################################################################################
log "INFO" "Configuring systemd user lingering for '$USERNAME'..."

if loginctl show-user "$USERNAME" 2>/dev/null | grep -q '^Linger=yes'; then
    log "INFO" "Linger already enabled for '$USERNAME'"
else
    if loginctl enable-linger "$USERNAME"; then
        log "INFO" "Linger enabled for '$USERNAME'"

        # Verify lingering was enabled
        if loginctl show-user "$USERNAME" 2>/dev/null | grep -q '^Linger=yes'; then
            log "INFO" "Linger status verified"
        else
            log "WARN" "Linger may not have been enabled properly"
        fi
    else
        log "ERROR" "Failed to enable linger for '$USERNAME'"
        exit 1
    fi
fi

################################################################################
### 7. Optimize /boot/firmware/config.txt for Headless Mode
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

# Reduce GPU memory — headless, no display needed
add_or_update_config "gpu_mem" "16"

# Disable Bluetooth to save power
if ! grep -q "^dtoverlay=disable-bt" "$CONFIG_FILE"; then
    echo "dtoverlay=disable-bt" >> "$CONFIG_FILE"
    log "INFO" "Added: dtoverlay=disable-bt"
else
    log "INFO" "Bluetooth already disabled"
fi

# Disable HDMI output (saves ~25mA)
add_or_update_config "hdmi_blanking" "2"

# Disable activity LED
if ! grep -q "^dtparam=act_led_trigger" "$CONFIG_FILE"; then
    cat >> "$CONFIG_FILE" << 'EOF'

# Disable LEDs to save power
dtparam=act_led_trigger=none
dtparam=act_led_activelow=on
EOF
    log "INFO" "Added: Activity LED configuration"
else
    log "INFO" "Activity LED configuration already present"
fi

# Disable power LED
if ! grep -q "^dtparam=pwr_led_trigger" "$CONFIG_FILE"; then
    cat >> "$CONFIG_FILE" << 'EOF'
dtparam=pwr_led_trigger=none
dtparam=pwr_led_activelow=on
EOF
    log "INFO" "Added: Power LED configuration"
else
    log "INFO" "Power LED configuration already present"
fi

log "INFO" "Boot configuration optimized"

################################################################################
### 8. Create IMX500 Log Directory
################################################################################
log "INFO" "Creating IMX500 log directory..."

# /var/log/imx500 is used by imx500_demo.py (TimedRotatingFileHandler)
# Must be owned by the service user, not root
if [[ ! -d "$LOG_DIR" ]]; then
    mkdir -p "$LOG_DIR"
    log "INFO" "Created $LOG_DIR"
fi

chown "${USERNAME}:${USERNAME}" "$LOG_DIR"
chmod 755 "$LOG_DIR"
log "INFO" "Set ownership of $LOG_DIR to $USERNAME"

################################################################################
### 9. Configure Log Rotation
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
### 10. Final Summary
################################################################################
echo ""
log "INFO" "========================================="
log "INFO" "PROVISIONING COMPLETE"
log "INFO" "========================================="
log "INFO" "Script Version: $SCRIPT_VERSION"
log "INFO" "User: $USERNAME"
log "INFO" "Camera Interface: Enabled (camera_auto_detect=1)"
log "INFO" "I2C: Enabled"
log "INFO" "Video Group: $USERNAME added"
log "INFO" "WiFi Power Saving: Disabled"
log "INFO" "Base Packages: Installed"
log "INFO" "User Lingering: Enabled"
log "INFO" "Boot Config: Optimized for headless"
log "INFO" "Log Directory: $LOG_DIR (owned by $USERNAME)"
log "INFO" "Log Rotation: Configured"
log "INFO" "Log file: $LOG_FILE"
log "INFO" "Config backup: $BACKUP_FILE"
log "INFO" "========================================="
log "INFO" "Next steps after reboot:"
log "INFO" "  1. Verify camera: python3 -c 'import libcamera; print(libcamera.__version__)'"
log "INFO" "  2. Run Python provisioning script"
log "INFO" "  3. Start RPI Connect: rpi-connect on && rpi-connect signin"
log "INFO" "========================================="

echo ""

# Prompt for reboot
log "INFO" "System will reboot in 10 seconds to apply changes..."
log "INFO" "Press Ctrl+C to cancel reboot and review changes"
sleep 10

log "INFO" "Rebooting now..."
reboot
