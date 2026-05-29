#!/usr/bin/env bash
set -euo pipefail

################################################################################
# Raspberry Pi IMX500 Street Monitor - Python Environment Provisioning Script
################################################################################
# This script creates a Python virtual environment with all required packages
# for the IMX500 AI camera street monitoring system.
#
# Note: picamera2 and imx500-all are installed via apt (not pip) and are made
# available inside the venv via --system-site-packages.
#
# Features:
# - Installs required apt packages (picamera2, imx500-all, build tools)
# - Creates imx500_venv virtual environment with --system-site-packages
# - Installs required pip packages (opencv-python-headless, websockets)
# - Proper user ownership handling when run with sudo
# - Reset capability to recreate environment
# - Customizable package list
#
# Prerequisites:
# - Python 3 installed
# - Root privileges (for apt package installation)
# - imx500pi_provision.sh already run (camera interface enabled, log dir exists)
#
# Usage:
#   chmod +x imx500pi_provision_python.sh
#   sudo ./imx500pi_provision_python.sh
#   sudo ./imx500pi_provision_python.sh --venv-dir /custom/path
#   sudo ./imx500pi_provision_python.sh --requirement extra-package
#   sudo ./imx500pi_provision_python.sh --reset
#
# Arguments:
#   --venv-dir <path>      - Custom virtual environment directory
#   --requirement <pkg>    - Add additional pip package
#   --reset                - Remove and recreate virtual environment
################################################################################

### Constants
readonly SCRIPT_VERSION="1.0.0"
readonly LOG_DIR="/var/log/imx500"
readonly LOG_FILE="${LOG_DIR}/provision_python_venv.log"
readonly MIN_DISK_SPACE_MB=1024  # Models + venv require more headroom than weatherpi

### Default Configuration
readonly DEFAULT_VENV_DIR_NAME="imx500_venv"

# apt packages — picamera2 and imx500-all must be apt-installed;
# their Python bindings are exposed to the venv via --system-site-packages
readonly DEFAULT_APT_PACKAGES=(
    "python3-pip"
    "python3-venv"
    "python3-dev"
    "build-essential"
    "python3-libcamera"        # Headless-safe libcamera Python bindings (no display deps)
    "python3-picamera2"        # Picamera2 Python library + IMX500 device support
    "imx500-all"               # IMX500 firmware, models, and postprocessing tools
)

# pip packages installed into the venv
readonly DEFAULT_REQUIREMENTS=(
    "opencv-python-headless"   # OpenCV without Qt/display deps (headless Pi)
    "websockets"               # WebSocket server for live stream (imx500_capture.py)
    "astral"                   # Sunrise/sunset calculation for daylight-only operation
    "pgeocode"                 # Offline zip code to lat/long resolution (no API key needed)
)

### Variables
VENV_DIR=""
REQUIREMENTS=("${DEFAULT_REQUIREMENTS[@]}")
APT_PACKAGES=("${DEFAULT_APT_PACKAGES[@]}")
RESET_MODE=false

### Logging function
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
    local path="$1"
    local required_mb="$2"

    log "INFO" "Checking available disk space for $path..."

    local available_mb
    available_mb=$(df -BM "$(dirname "$path")" | awk 'NR==2 {print $4}' | sed 's/M//')

    log "INFO" "Available disk space: ${available_mb}MB"

    if [[ $available_mb -lt $required_mb ]]; then
        log "ERROR" "Insufficient disk space: ${available_mb}MB available, ${required_mb}MB required"
        return 1
    fi

    log "INFO" "Disk space check passed"
    return 0
}

### Ensure disk-backed swap exists (Pi Zero 2W OOM guard)
ensure_swap() {
    log "INFO" "Checking for disk-backed swap..."

    if swapon --show | grep -q "^/swapfile"; then
        log "INFO" "Disk-backed swap already active at /swapfile — skipping"
        return 0
    fi

    if [[ -f /swapfile ]]; then
        log "INFO" "/swapfile exists but is not active — activating..."
        swapon /swapfile
        log "INFO" "Swap activated"
    else
        log "INFO" "Creating 1G swapfile at /swapfile..."
        fallocate -l 1G /swapfile
        chmod 600 /swapfile
        mkswap /swapfile
        swapon /swapfile
        log "INFO" "Swapfile created and activated"
    fi

    if ! grep -q '^/swapfile' /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
        log "INFO" "Added /swapfile to /etc/fstab for persistence"
    else
        log "INFO" "/swapfile already in /etc/fstab"
    fi
}

################################################################################
### Parse Command Line Arguments
################################################################################
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --venv-dir)
                if [[ -z "${2:-}" ]]; then
                    echo "ERROR: --venv-dir requires a path argument"
                    exit 1
                fi
                if [[ "$2" =~ [^a-zA-Z0-9/_.-] ]]; then
                    echo "ERROR: Invalid characters in venv path: $2"
                    exit 1
                fi
                VENV_DIR="$2"
                shift 2
                ;;
            --requirement)
                if [[ -z "${2:-}" ]]; then
                    echo "ERROR: --requirement requires a package name"
                    exit 1
                fi
                if [[ "$2" =~ [^a-zA-Z0-9._-] ]]; then
                    echo "ERROR: Invalid characters in package name: $2"
                    exit 1
                fi
                REQUIREMENTS+=("$2")
                shift 2
                ;;
            --reset)
                RESET_MODE=true
                shift
                ;;
            -h|--help)
                cat << EOF
Usage: $0 [OPTIONS]

Options:
  --venv-dir <path>      Custom virtual environment directory
  --requirement <pkg>    Add additional pip package (can be used multiple times)
  --reset                Remove and recreate virtual environment
  -h, --help             Show this help message

Default virtual environment: ~/imx500_venv

Examples:
  sudo $0
  sudo $0 --venv-dir /opt/imx500/venv
  sudo $0 --requirement some-extra-package
  sudo $0 --reset
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
}

################################################################################
### Determine Actual User and Home Directory
################################################################################
determine_user() {
    # Get the actual user (not root when using sudo)
    if [[ -n "${SUDO_USER:-}" ]]; then
        ACTUAL_USER="$SUDO_USER"
        ACTUAL_HOME=$(eval echo ~"$SUDO_USER")
    else
        ACTUAL_USER="$USER"
        ACTUAL_HOME="$HOME"
    fi

    # Validate user exists
    if ! id "$ACTUAL_USER" &>/dev/null; then
        log "ERROR" "User '$ACTUAL_USER' does not exist"
        exit 1
    fi

    # Set default venv directory if not specified
    if [[ -z "$VENV_DIR" ]]; then
        VENV_DIR="$ACTUAL_HOME/$DEFAULT_VENV_DIR_NAME"
    fi

    # Expand tilde if present
    VENV_DIR="${VENV_DIR/#\~/$ACTUAL_HOME}"

    log "INFO" "Target user: $ACTUAL_USER"
    log "INFO" "Home directory: $ACTUAL_HOME"
    log "INFO" "Virtual environment: $VENV_DIR"
}

################################################################################
### Reset Virtual Environment
################################################################################
reset_environment() {
    log "INFO" "========================================="
    log "INFO" "Python Environment Reset Started"
    log "INFO" "========================================="

    if [[ -d "$VENV_DIR" ]]; then
        log "INFO" "Removing virtual environment at $VENV_DIR..."

        # Verify we're not accidentally removing something critical
        if [[ "$VENV_DIR" == "/" ]] || [[ "$VENV_DIR" == "/home" ]] || [[ "$VENV_DIR" == "/opt" ]]; then
            log "ERROR" "Refusing to remove critical directory: $VENV_DIR"
            exit 1
        fi

        # Check if it looks like a venv (has bin/activate)
        if [[ ! -f "$VENV_DIR/bin/activate" ]]; then
            log "WARN" "Directory doesn't appear to be a Python venv (missing bin/activate)"
            read -p "Continue with removal? (y/n): " confirm
            if [[ "$confirm" != "y" && "$confirm" != "yes" ]]; then
                log "INFO" "Reset cancelled by user"
                exit 0
            fi
        fi

        rm -rf "$VENV_DIR"
        log "INFO" "Virtual environment removed"
    else
        log "INFO" "No virtual environment found at $VENV_DIR"
    fi

    log "INFO" "========================================="
    log "INFO" "Reset Complete"
    log "INFO" "========================================="
}

################################################################################
### Install System Packages
################################################################################
install_system_packages() {
    log "INFO" "Installing system packages..."
    export DEBIAN_FRONTEND=noninteractive

    log "INFO" "Updating package lists..."
    local max_retries=3
    local retry_count=0

    while [[ $retry_count -lt $max_retries ]]; do
        if apt-get update 2>&1 | tee -a "$LOG_FILE"; then
            log "INFO" "Package lists updated"
            break
        else
            retry_count=$((retry_count + 1))
            log "WARN" "Update failed (attempt $retry_count/$max_retries)"
            if [[ $retry_count -lt $max_retries ]]; then
                sleep 5
            else
                log "ERROR" "Failed to update package lists after $max_retries attempts"
                return 1
            fi
        fi
    done

    # Install each package
    for pkg in "${APT_PACKAGES[@]}"; do
        if dpkg -s "$pkg" &>/dev/null; then
            local version
            version=$(dpkg -s "$pkg" | grep '^Version:' | awk '{print $2}')
            log "INFO" "$pkg already installed (version: $version)"
        else
            log "INFO" "Installing $pkg..."
            if apt-get install -y "$pkg" 2>&1 | tee -a "$LOG_FILE"; then
                log "INFO" "$pkg installed successfully"
            else
                log "ERROR" "Failed to install $pkg"
                return 1
            fi
        fi
    done

    log "INFO" "All system packages installed"
}

################################################################################
### Verify Python Installation
################################################################################
verify_python() {
    log "INFO" "Verifying Python installation..."

    if ! command -v python3 &>/dev/null; then
        log "ERROR" "Python 3 not found"
        return 1
    fi

    local python_version
    python_version=$(python3 --version 2>&1 | awk '{print $2}')
    log "INFO" "Python $python_version found"

    # Check Python version is at least 3.7
    local major minor
    major=$(echo "$python_version" | cut -d. -f1)
    minor=$(echo "$python_version" | cut -d. -f2)

    if [[ $major -lt 3 ]] || [[ $major -eq 3 && $minor -lt 7 ]]; then
        log "ERROR" "Python 3.7 or higher required (found $python_version)"
        return 1
    fi

    if ! python3 -m venv --help &>/dev/null; then
        log "ERROR" "Python venv module not available"
        return 1
    fi

    log "INFO" "Python venv module available"
}

################################################################################
### Create Virtual Environment
################################################################################
create_virtual_environment() {
    if [[ -d "$VENV_DIR" ]]; then
        log "INFO" "Virtual environment already exists at $VENV_DIR"
        log "WARN" "Use --reset to recreate"
        return 0
    fi

    # Create parent directory if needed
    local parent_dir
    parent_dir=$(dirname "$VENV_DIR")
    if [[ ! -d "$parent_dir" ]]; then
        log "INFO" "Creating parent directory: $parent_dir"
        mkdir -p "$parent_dir"
        chown "$ACTUAL_USER:$ACTUAL_USER" "$parent_dir"
    fi

    log "INFO" "Creating virtual environment at $VENV_DIR..."
    log "INFO" "Using --system-site-packages so apt-installed picamera2 is accessible"

    # --system-site-packages is required: picamera2 and its IMX500 bindings are
    # apt-installed into system site-packages and cannot be pip-installed into
    # the venv directly.
    if sudo -u "$ACTUAL_USER" python3 -m venv --system-site-packages "$VENV_DIR" 2>&1 | tee -a "$LOG_FILE"; then
        log "INFO" "Virtual environment created"

        # Verify activation script exists
        if [[ -f "$VENV_DIR/bin/activate" ]]; then
            log "INFO" "Activation script verified: $VENV_DIR/bin/activate"
        else
            log "ERROR" "Virtual environment created but activation script missing"
            return 1
        fi
    else
        log "ERROR" "Failed to create virtual environment"
        return 1
    fi
}

################################################################################
### Install Python Packages
################################################################################
install_python_packages() {
    log "INFO" "Installing Python packages..."

    local failed_packages=()

    for pkg in "${REQUIREMENTS[@]}"; do
        log "INFO" "Installing $pkg..."

        if sudo -u "$ACTUAL_USER" bash -c "source '$VENV_DIR/bin/activate' && python3 -m pip install '$pkg' 2>&1" | tee -a "$LOG_FILE"; then
            log "INFO" "$pkg installed successfully"
        else
            log "ERROR" "Failed to install $pkg"
            failed_packages+=("$pkg")
        fi
    done

    if [[ ${#failed_packages[@]} -gt 0 ]]; then
        log "ERROR" "Failed to install ${#failed_packages[@]} package(s): ${failed_packages[*]}"
        return 1
    fi

    log "INFO" "All Python packages installed successfully"
}

################################################################################
### Verify Critical Packages
################################################################################
verify_packages() {
    log "INFO" "Verifying critical package installations..."

    # Verify python3-libcamera (apt-installed, visible via --system-site-packages)
    log "INFO" "Checking libcamera..."
    # Note: libcamera does not expose __version__ on all builds; test import only
    if sudo -u "$ACTUAL_USER" bash -c "source '$VENV_DIR/bin/activate' && python3 -c 'import libcamera; print(\"libcamera OK\")'" 2>&1 | tee -a "$LOG_FILE"; then
        log "INFO" "libcamera verified"
    else
        log "ERROR" "libcamera not importable — ensure python3-libcamera is installed and venv uses --system-site-packages"
        return 1
    fi

    # Verify picamera2 (apt-installed, visible via --system-site-packages)
    log "INFO" "Checking picamera2..."
    if sudo -u "$ACTUAL_USER" bash -c "source '$VENV_DIR/bin/activate' && python3 -c 'import picamera2; print(\"picamera2 version:\", picamera2.__version__)'" 2>&1 | tee -a "$LOG_FILE"; then
        log "INFO" "picamera2 verified"
    else
        log "ERROR" "picamera2 not importable — ensure python3-picamera2 is installed and venv uses --system-site-packages"
        return 1
    fi

    # Verify cv2 (opencv-python-headless)
    log "INFO" "Checking cv2 (opencv-python-headless)..."
    if sudo -u "$ACTUAL_USER" bash -c "source '$VENV_DIR/bin/activate' && python3 -c 'import cv2; print(\"cv2 version:\", cv2.__version__)'" 2>&1 | tee -a "$LOG_FILE"; then
        log "INFO" "cv2 verified"
    else
        log "ERROR" "cv2 not importable — opencv-python-headless may not have installed correctly"
        return 1
    fi

    # Verify websockets
    log "INFO" "Checking websockets..."
    if sudo -u "$ACTUAL_USER" bash -c "source '$VENV_DIR/bin/activate' && python3 -c 'import websockets; print(\"websockets version:\", websockets.__version__)'" 2>&1 | tee -a "$LOG_FILE"; then
        log "INFO" "websockets verified"
    else
        log "ERROR" "websockets not importable"
        return 1
    fi

    # Verify astral
    log "INFO" "Checking astral..."
    if sudo -u "$ACTUAL_USER" bash -c "source '$VENV_DIR/bin/activate' && python3 -c 'import astral; print(\"astral version:\", astral.__version__)'" 2>&1 | tee -a "$LOG_FILE"; then
        log "INFO" "astral verified"
    else
        log "ERROR" "astral not importable"
        return 1
    fi

    # Verify pgeocode
    log "INFO" "Checking pgeocode..."
    if sudo -u "$ACTUAL_USER" bash -c "source '$VENV_DIR/bin/activate' && python3 -c 'import pgeocode; print(\"pgeocode version:\", pgeocode.__version__)'" 2>&1 | tee -a "$LOG_FILE"; then
        log "INFO" "pgeocode verified"
    else
        log "ERROR" "pgeocode not importable"
        return 1
    fi

    # List all installed packages
    log "INFO" "Installed packages:"
    sudo -u "$ACTUAL_USER" bash -c "source '$VENV_DIR/bin/activate' && python3 -m pip list" 2>&1 | tee -a "$LOG_FILE"
}

################################################################################
### Set Proper Ownership
################################################################################
set_ownership() {
    log "INFO" "Setting proper ownership..."

    if chown -R "$ACTUAL_USER:$ACTUAL_USER" "$VENV_DIR" 2>&1 | tee -a "$LOG_FILE"; then
        log "INFO" "Ownership set to $ACTUAL_USER:$ACTUAL_USER"

        # Verify ownership
        local owner
        owner=$(stat -c '%U:%G' "$VENV_DIR")
        if [[ "$owner" == "$ACTUAL_USER:$ACTUAL_USER" ]]; then
            log "INFO" "Ownership verified: $owner"
        else
            log "WARN" "Ownership verification failed: expected $ACTUAL_USER:$ACTUAL_USER, got $owner"
        fi
    else
        log "ERROR" "Failed to set ownership"
        return 1
    fi
}

################################################################################
### Main Execution
################################################################################

# Parse command line arguments first
parse_arguments "$@"

# Ensure script runs as root
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root (use sudo)"
    echo "This is required to install system packages"
    exit 1
fi

log "INFO" "Starting Python environment provisioning script v$SCRIPT_VERSION"

# Determine actual user and directories
determine_user

# Handle reset mode
if [[ "$RESET_MODE" == true ]]; then
    reset_environment
    exit 0
fi

# Check disk space
if ! check_disk_space "$VENV_DIR" "$MIN_DISK_SPACE_MB"; then
    exit 1
fi

log "INFO" "========================================="
log "INFO" "Python Environment Setup Started"
log "INFO" "========================================="
log "INFO" "User: $ACTUAL_USER"
log "INFO" "Virtual environment: $VENV_DIR"
log "INFO" "System site-packages: enabled (required for picamera2)"
log "INFO" "Apt packages: ${#APT_PACKAGES[@]}"
log "INFO" "Pip packages: ${#REQUIREMENTS[@]}"

### Ensure swap (guards against OOM during large apt installs on Pi Zero 2W)
if ! ensure_swap; then
    log "WARN" "Could not ensure disk-backed swap — continuing anyway, but install may OOM on low-memory devices"
fi

### Install system packages
if ! install_system_packages; then
    log "ERROR" "System package installation failed"
    exit 1
fi

### Verify Python installation
if ! verify_python; then
    log "ERROR" "Python verification failed"
    exit 1
fi

### Create virtual environment
if ! create_virtual_environment; then
    log "ERROR" "Virtual environment creation failed"
    exit 1
fi

### Install Python packages
if ! install_python_packages; then
    log "ERROR" "Python package installation failed"
    exit 1
fi

### Verify packages
if ! verify_packages; then
    log "WARN" "Some package verifications failed, but continuing..."
fi

### Set proper ownership
if ! set_ownership; then
    log "ERROR" "Failed to set proper ownership"
    exit 1
fi

### Final summary
log "INFO" "========================================="
log "INFO" "Python Environment Setup Complete"
log "INFO" "========================================="
log "INFO" "Script Version: $SCRIPT_VERSION"
log "INFO" "Virtual environment: $VENV_DIR"
log "INFO" "Owner: $ACTUAL_USER"
log "INFO" "System site-packages: enabled"
log "INFO" "Log file: $LOG_FILE"
log "INFO" ""
log "INFO" "Apt packages installed:"
for pkg in "${APT_PACKAGES[@]}"; do
    log "INFO" "  - $pkg"
done
log "INFO" ""
log "INFO" "Pip packages installed:"
for pkg in "${REQUIREMENTS[@]}"; do
    log "INFO" "  - $pkg"
done
log "INFO" ""
log "INFO" "To activate the virtual environment:"
log "INFO" "  source $VENV_DIR/bin/activate"
log "INFO" ""
log "INFO" "To verify the installation:"
log "INFO" "  source $VENV_DIR/bin/activate"
log "INFO" "  python3 -c 'import picamera2, cv2, websockets, astral, pgeocode; print(\"All imports OK\")'"
