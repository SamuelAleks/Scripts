#!/bin/bash
# shellcheck shell=bash
# NAS Mount Setup for EndeavourOS
# Uses autofs with explicit share paths and mismatch detection

set -euo pipefail

# =============================================================================
# CONFIGURATION - Edit these values for your setup
# =============================================================================

NAS_IP="{NAS_IP}"
# NAS_USER must not contain '=' or newline characters as these would
# malform the credentials file format (key=value pairs).
NAS_USER="{NAS_USER}"
# Credentials file path is hardcoded intentionally for single-user/personal use
CREDS_FILE="/etc/samba/creds-mainstorage"
AUTOFS_MAP="/etc/autofs/nas.autofs"
SHARES=("{SHARE1}" "{SHARE2}" "{SHARE3}")

# =============================================================================
# SCRIPT METADATA
# =============================================================================

SCRIPT_VERSION="1.1.1"
SCRIPT_NAME="setup-nas-mounts"

# =============================================================================
# HELP AND MANUAL
# =============================================================================

show_help() {
    cat << 'HELP_EOF'
Usage: setup-nas-mounts [OPTION]

Automated NAS mounting setup using autofs with share mismatch detection.

Options:
  -h, --help          Show this help message and exit
  -m, --man           Show detailed manual page
  -v, --version       Show version information
  -u, --uninstall     Remove scripts and systemd services (keeps configs/mounts)
  -U, --uninstall-full
                      Remove everything: scripts, configs, mounts, credentials

Without options, runs the setup process (requires root via sudo).

Examples:
  sudo ./setup-nas-mounts.sh          # Run setup
  ./setup-nas-mounts.sh --help        # Show help
  sudo ./setup-nas-mounts.sh --uninstall
                                      # Remove scripts and services only
  sudo ./setup-nas-mounts.sh --uninstall-full
                                      # Complete removal

After setup, use these commands:
  nas-mount-setup --help              # This script (via alias)
  nas-share-edit                      # View/edit share configuration
  nas-share-monitor                   # Check for share mismatches

Report bugs to: {BUGS_URL}
HELP_EOF
}

show_man() {
    cat << 'MAN_EOF'
NAME
    setup-nas-mounts - Automated NAS mounting setup for EndeavourOS

SYNOPSIS
    setup-nas-mounts [OPTION]
    sudo setup-nas-mounts

DESCRIPTION
    Sets up automatic mounting of SMB/CIFS shares from a NAS device using
    autofs. Includes share mismatch detection with desktop notifications.

    The script performs the following:
      • Validates NAS connectivity and configuration
      • Installs required packages (autofs, cifs-utils, smbclient, libnotify)
      • Creates SMB credentials file with secure permissions
      • Configures autofs for on-demand mounting
      • Installs monitoring scripts and systemd user services
      • Sets up shell aliases for convenience commands

OPTIONS
    -h, --help
        Display brief usage information and exit.

    -m, --man
        Display this detailed manual page and exit.

    -v, --version
        Display version information and exit.

    -u, --uninstall
        Remove installed scripts and systemd services but preserve:
          • Credentials file (/etc/samba/creds-mainstorage)
          • Autofs map (/etc/autofs/nas.autofs)
          • auto.master modifications
          • Mount points

        This allows quick reinstallation without re-entering credentials.

    -U, --uninstall-full
        Complete removal of all components:
          • Scripts (/usr/local/bin/nas-share-*)
          • Systemd user services
          • Credentials file
          • Autofs map and auto.master entry
          • Mount point (/mnt/nas) and symlink (~/Drives/nas)
          • Shell aliases
          • Cache files

CONFIGURATION
    Edit these variables at the top of the script before running:

    NAS_IP="{NAS_IP}"
        IP address or hostname of your NAS device.

    NAS_USER="{NAS_USER}"
        SMB username for authentication.

    SHARES=("{SHARE1}" "{SHARE2}" ...)
        Array of share names to configure. Names must:
          • Start with a letter or number
          • Contain only letters, numbers, underscores, hyphens
          • Match the exact case on the NAS

FILES
    Created by setup:
        /etc/samba/creds-mainstorage
            SMB credentials (mode 600, root only)

        /etc/autofs/nas.autofs
            Autofs indirect map with share definitions

        /usr/local/bin/nas-share-monitor
            Share mismatch detection script

        /usr/local/bin/nas-share-edit
            Configuration viewing/editing helper

        /usr/local/bin/nas-mount-setup
            This setup script (for re-running or uninstall)

        ~/.config/systemd/user/nas-share-monitor.service
            Systemd user service unit

        ~/.config/systemd/user/nas-share-monitor.timer
            Systemd timer (15s after login + daily)

    Modified:
        /etc/auto.master
            Adds entry for /mnt/nas mount point

        ~/.bashrc or ~/.zshrc
            Adds aliases for nas-* commands (if bash/zsh detected)

    Runtime (created by monitor):
        ~/.cache/nas-share-check-notified
        ~/.cache/nas-share-monitor.log
        ~/.cache/nas-share-monitor.lock

MOUNT POINTS
    /mnt/nas/<ShareName>
        Autofs-managed mount points (created on-demand)

    ~/Drives/nas
        Symlink to /mnt/nas for convenience

MOUNT BEHAVIOR
    • Shares mount automatically when accessed
    • Unmount after 5 minutes idle (--timeout=300)
    • Soft mounts return errors instead of hanging
    • 10-second keepalive detects dead connections in ~10-20s
    • SMB version auto-negotiates (prefers 3.1.1)

ALIASES
    After setup, these aliases are available:

    nas-mount-setup
        Run the setup script (requires sudo)

    nas-edit, nasedit
        Shorthand for nas-share-edit

    nas-mon, nasmon
        Shorthand for nas-share-monitor

EXAMPLES
    Initial setup:
        $ sudo ./setup-nas-mounts.sh
        Enter SMB password for {NAS_USER}:
        === Setup Complete ===

    Check share configuration:
        $ nas-share-edit
        === NAS Share Configuration ===
        Currently configured shares:
          • Documents
          • Media
        ...

    Manually trigger mismatch check:
        $ nas-share-monitor

    Access a share:
        $ ls ~/Drives/nas/Documents/

    Complete removal:
        $ sudo ./setup-nas-mounts.sh --uninstall-full

EXIT STATUS
    0   Success
    1   Error (configuration, connectivity, permissions, etc.)

SEE ALSO
    autofs(8), mount.cifs(8), smbclient(1), systemctl(1)

VERSION
    1.1.1

MAN_EOF
}

show_version() {
    echo "$SCRIPT_NAME version $SCRIPT_VERSION"
}

# =============================================================================
# UNINSTALL FUNCTIONS
# =============================================================================

# Get real user info (works with sudo or direct root)
get_user_info() {
    if [[ -n "${SUDO_USER:-}" ]]; then
        REAL_USER="$SUDO_USER"
        REAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
        MOUNT_UID=$(id -u "$SUDO_USER")
    else
        REAL_USER="${USER:-root}"
        REAL_HOME="${HOME:-/root}"
        MOUNT_UID=$(id -u)
    fi
}

uninstall_scripts_and_services() {
    echo "=== Uninstalling Scripts and Services ==="
    get_user_info

    # Stop and disable user services
    echo "Disabling user services..."
    if [[ -d "/run/user/$MOUNT_UID" ]]; then
        sudo -u "$REAL_USER" XDG_RUNTIME_DIR="/run/user/$MOUNT_UID" \
            systemctl --user disable --now nas-share-monitor.timer 2>/dev/null || true
        sudo -u "$REAL_USER" XDG_RUNTIME_DIR="/run/user/$MOUNT_UID" \
            systemctl --user disable nas-share-monitor.service 2>/dev/null || true
        sudo -u "$REAL_USER" XDG_RUNTIME_DIR="/run/user/$MOUNT_UID" \
            systemctl --user daemon-reload 2>/dev/null || true
    fi

    # Remove user service files
    echo "Removing user service files..."
    rm -f "$REAL_HOME/.config/systemd/user/nas-share-monitor.service"
    rm -f "$REAL_HOME/.config/systemd/user/nas-share-monitor.timer"

    # Remove scripts
    echo "Removing scripts..."
    rm -f /usr/local/bin/nas-share-monitor
    rm -f /usr/local/bin/nas-share-edit
    rm -f /usr/local/bin/nas-mount-setup

    # Remove cache files
    echo "Removing cache files..."
    rm -f "$REAL_HOME/.cache/nas-share-check-notified"
    rm -f "$REAL_HOME/.cache/nas-share-monitor.log"
    rm -f "$REAL_HOME/.cache/nas-share-monitor.lock"

    # Remove shell aliases
    echo "Removing shell aliases..."
    remove_shell_aliases

    echo ""
    echo "=== Uninstall Complete (Scripts/Services) ==="
    echo ""
    echo "Preserved (use --uninstall-full to remove):"
    echo "  • /etc/samba/creds-mainstorage (credentials)"
    echo "  • /etc/autofs/nas.autofs (share map)"
    echo "  • /etc/auto.master entry"
    echo "  • /mnt/nas mount point"
    echo "  • ~/Drives/nas symlink"
    echo "  • autofs service (still running)"
}

uninstall_full() {
    echo "=== Full Uninstall ==="
    get_user_info

    # First do the partial uninstall
    uninstall_scripts_and_services

    echo ""
    echo "Removing configuration and mounts..."

    # Stop and disable autofs
    echo "Stopping autofs..."
    systemctl stop autofs 2>/dev/null || true
    systemctl disable autofs 2>/dev/null || true

    # Remove autofs map
    echo "Removing autofs map..."
    rm -f "$AUTOFS_MAP"

    # Remove credentials file
    echo "Removing credentials file..."
    rm -f "$CREDS_FILE"

    # Remove entry from auto.master
    echo "Cleaning auto.master..."
    if [[ -f /etc/auto.master ]]; then
        grep -v "^/mnt/nas[[:space:]]" /etc/auto.master > /etc/auto.master.tmp.$$ 2>/dev/null || true
        mv /etc/auto.master.tmp.$$ /etc/auto.master
    fi

    # Remove auto.master backups
    echo "Removing auto.master backups..."
    rm -f /etc/auto.master.bak.*
    rm -f /etc/auto.master.lock
    rm -f /etc/auto.master.tmp.* 2>/dev/null || true

    # Remove symlink
    echo "Removing symlink..."
    rm -f "$REAL_HOME/Drives/nas"
    rmdir "$REAL_HOME/Drives" 2>/dev/null || true

    # Unmount and remove mount point
    echo "Removing mount point..."
    # Unmount any active mounts under /mnt/nas
    if mountpoint -q /mnt/nas 2>/dev/null || [[ -d /mnt/nas ]]; then
        for mount in /mnt/nas/*/; do
            [[ -d "$mount" ]] && umount -l "$mount" 2>/dev/null || true
        done
        umount -l /mnt/nas 2>/dev/null || true
    fi
    rmdir /mnt/nas 2>/dev/null || true

    # Remove empty directories
    rmdir /etc/autofs 2>/dev/null || true
    rmdir /etc/samba 2>/dev/null || true

    echo ""
    echo "=== Full Uninstall Complete ==="
    echo ""
    echo "All NAS mount components have been removed."
    echo ""
    echo "Note: The following packages were NOT removed (may be used by other programs):"
    echo "  autofs, cifs-utils, smbclient, libnotify"
    echo ""
    echo "To remove them: sudo pacman -Rs autofs cifs-utils smbclient libnotify"
}

# =============================================================================
# SHELL ALIAS FUNCTIONS
# =============================================================================

# Marker comments to identify our alias block
ALIAS_MARKER_START="# >>> nas-mount-setup aliases >>>"
ALIAS_MARKER_END="# <<< nas-mount-setup aliases <<<"

get_alias_block() {
    cat << 'ALIAS_EOF'
# >>> nas-mount-setup aliases >>>
# Added by setup-nas-mounts.sh - do not edit manually
alias nas-mount-setup='sudo /usr/local/bin/nas-mount-setup'
alias nas-edit='nas-share-edit'
alias nasedit='nas-share-edit'
alias nas-mon='nas-share-monitor'
alias nasmon='nas-share-monitor'
# <<< nas-mount-setup aliases <<<
ALIAS_EOF
}

add_shell_aliases() {
    get_user_info
    local rc_files=()
    local added_to=()

    # Detect which shell rc files exist or should be created
    # Check for bash
    if [[ -f "$REAL_HOME/.bashrc" ]]; then
        rc_files+=("$REAL_HOME/.bashrc")
    elif command -v bash &>/dev/null && [[ "$REAL_HOME" != "/root" ]]; then
        # User has bash but no .bashrc - could create, but we'll skip
        :
    fi

    # Check for zsh
    if [[ -f "$REAL_HOME/.zshrc" ]]; then
        rc_files+=("$REAL_HOME/.zshrc")
    fi

    # Check for fish (uses different syntax, skip for now)
    # Fish would need: alias nas-edit 'nas-share-edit' in ~/.config/fish/config.fish

    if [[ ${#rc_files[@]} -eq 0 ]]; then
        echo "No shell rc files found (.bashrc, .zshrc). Skipping alias setup."
        echo "You can manually add aliases to your shell configuration."
        return 0
    fi

    for rc_file in "${rc_files[@]}"; do
        # Check if aliases already exist
        if grep -q "$ALIAS_MARKER_START" "$rc_file" 2>/dev/null; then
            echo "Aliases already present in $rc_file, updating..."
            # Remove old block and add new one
            remove_alias_block_from_file "$rc_file"
        fi

        # Add alias block
        echo "" >> "$rc_file"
        get_alias_block >> "$rc_file"
        added_to+=("$rc_file")

        # Fix ownership if we're running as root via sudo
        if [[ -n "${SUDO_USER:-}" ]]; then
            chown "$SUDO_USER:$SUDO_USER" "$rc_file"
        fi
    done

    if [[ ${#added_to[@]} -gt 0 ]]; then
        echo "Shell aliases added to: ${added_to[*]}"
        echo "Aliases available after restarting your shell or running: source ~/.bashrc"
    fi
}

remove_alias_block_from_file() {
    local rc_file="$1"
    local temp_file
    temp_file=$(mktemp)

    # Use awk to remove everything between markers (inclusive)
    awk -v start="$ALIAS_MARKER_START" -v end="$ALIAS_MARKER_END" '
        $0 ~ start { skip=1; next }
        $0 ~ end { skip=0; next }
        !skip { print }
    ' "$rc_file" > "$temp_file"

    # Remove trailing blank lines that might accumulate
    # (keeps one trailing newline)
    # Note: This sed syntax is GNU sed-specific (target: EndeavourOS/Arch).
    # BSD sed (macOS) would require different syntax.
    sed -i -e :a -e '/^\s*$/{ $d; N; ba' -e '}' "$temp_file" 2>/dev/null || true

    mv "$temp_file" "$rc_file"
}

remove_shell_aliases() {
    get_user_info
    local rc_files=("$REAL_HOME/.bashrc" "$REAL_HOME/.zshrc")

    for rc_file in "${rc_files[@]}"; do
        if [[ -f "$rc_file" ]] && grep -q "$ALIAS_MARKER_START" "$rc_file" 2>/dev/null; then
            echo "Removing aliases from $rc_file..."
            remove_alias_block_from_file "$rc_file"

            # Fix ownership
            if [[ -n "${SUDO_USER:-}" ]]; then
                chown "$SUDO_USER:$SUDO_USER" "$rc_file"
            fi
        fi
    done
}

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

# Parse arguments before requiring root (so --help works without sudo)
case "${1:-}" in
    -h|--help)
        show_help
        exit 0
        ;;
    -m|--man)
        show_man | ${PAGER:-less}
        exit 0
        ;;
    -v|--version)
        show_version
        exit 0
        ;;
    -u|--uninstall)
        if [[ $EUID -ne 0 ]]; then
            echo "ERROR: --uninstall requires root"
            echo "Usage: sudo $0 --uninstall"
            exit 1
        fi
        uninstall_scripts_and_services
        exit 0
        ;;
    -U|--uninstall-full)
        if [[ $EUID -ne 0 ]]; then
            echo "ERROR: --uninstall-full requires root"
            echo "Usage: sudo $0 --uninstall-full"
            exit 1
        fi
        uninstall_full
        exit 0
        ;;
    "")
        # No arguments - continue with setup
        ;;
    *)
        echo "Unknown option: $1"
        echo "Try '$0 --help' for more information."
        exit 1
        ;;
esac

# =============================================================================
# MAIN SETUP
# =============================================================================

# Cleanup function for trap
cleanup() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        echo ""
        echo "ERROR: Script failed (exit code $exit_code)"
        echo "Partial configuration may exist. Check:"
        echo "  • /etc/auto.master"
        echo "  • $AUTOFS_MAP"
        echo "  • $CREDS_FILE"
    fi
    # Clean up temp files if they exist
    # Note: These files are in /etc so require root. The 2>/dev/null suppresses
    # errors if files were never created (e.g., script failed before that point).
    # The || true is belt-and-suspenders defensive coding.
    rm -f "${AUTOFS_MAP}.tmp" 2>/dev/null || true
    rm -f "/etc/auto.master.tmp.$$" 2>/dev/null || true
    exit "$exit_code"
}
trap cleanup EXIT

# Require running as root to avoid partial configuration from permission errors
# partway through. The script writes to /etc and runs systemctl, so root is needed.
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root"
    echo "Usage: sudo $0"
    exit 1
fi

# Get current user's UID/GID (works even when run with sudo)
if [[ -n "${SUDO_USER:-}" ]]; then
    MOUNT_UID=$(id -u "$SUDO_USER")
    MOUNT_GID=$(id -g "$SUDO_USER")
    REAL_USER="$SUDO_USER"
    REAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
    # Running as root directly (not via sudo) - mounts will be configured for root user
    # This is usually unintended for a personal/single-user setup
    echo ""
    echo "WARNING: Running as root directly (not via sudo)"
    echo "Mounts will be configured with uid=0, gid=0 (root ownership)"
    echo "This means files will appear owned by root, not your regular user."
    echo ""
    echo "Recommended: Run with 'sudo $0' from your regular user account instead."
    echo ""
    if [[ ! -t 0 ]]; then
        echo "ERROR: Cannot prompt for confirmation - stdin is not a terminal"
        exit 1
    fi
    read -rp "Continue anyway? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 1
    fi
    MOUNT_UID=$(id -u)
    MOUNT_GID=$(id -g)
    REAL_USER="$USER"
    REAL_HOME="$HOME"
fi

echo "=== NAS Mount Setup ==="
echo "Configuring for user: $REAL_USER (UID=$MOUNT_UID, GID=$MOUNT_GID)"

# Validate NAS_IP format (IPv4 address or hostname)
# Accepts: dotted-quad IPv4 (192.168.1.100) or valid hostname (nas.local, my-nas)
if [[ ! "$NAS_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && \
   [[ ! "$NAS_IP" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]]; then
    echo "ERROR: Invalid NAS_IP format: '$NAS_IP'"
    echo "Must be an IPv4 address (e.g., 192.168.1.100) or hostname (e.g., nas.local)"
    exit 1
fi

# Additional validation for IPv4: each octet must be 0-255
# Also normalizes the IP by stripping leading zeros to avoid ambiguity (some tools
# interpret leading zeros as octal, e.g., 010 = 8 in octal). After this block,
# NAS_IP is guaranteed to be in canonical form (e.g., 192.168.1.100, not 192.168.000.005).
if [[ "$NAS_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    IFS='.' read -ra octets <<< "$NAS_IP"
    normalized_octets=()
    for octet in "${octets[@]}"; do
        # Strip leading zeros using parameter expansion (10#$octet forces base-10)
        octet=$((10#$octet))
        # Note: The regex check below is intentionally redundant after arithmetic expansion.
        # It serves as defense-in-depth and documents the expected invariant for readers.
        if ! [[ "$octet" =~ ^[0-9]+$ ]] || [[ $octet -gt 255 ]]; then
            echo "ERROR: Invalid IPv4 address: '$NAS_IP' (octet $octet invalid)"
            exit 1
        fi
        normalized_octets+=("$octet")
    done
    # Reconstruct NAS_IP with normalized octets
    NAS_IP="${normalized_octets[0]}.${normalized_octets[1]}.${normalized_octets[2]}.${normalized_octets[3]}"
fi

# Validate NAS_USER (must not contain = or newlines which break credentials file)
if [[ "$NAS_USER" == *"="* ]] || [[ "$NAS_USER" == *$'\n'* ]]; then
    echo "ERROR: NAS_USER cannot contain '=' or newline characters"
    echo "Current value: '$NAS_USER'"
    exit 1
fi

# Validate SHARES array
if [[ ${#SHARES[@]} -eq 0 ]]; then
    echo "ERROR: No shares defined in SHARES array"
    exit 1
fi

# Validate share names (no spaces, slashes, or special chars that break mounts)
# Must start with alphanumeric to avoid confusion with autofs options (which start with -)
for share in "${SHARES[@]}"; do
    if [[ ! "$share" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]]; then
        echo "ERROR: Invalid share name '$share'"
        echo "Share names must start with a letter or number, followed by"
        echo "letters, numbers, underscores, and hyphens only"
        exit 1
    fi
done

# Check for duplicate share names
declare -A seen_shares
for share in "${SHARES[@]}"; do
    if [[ -n "${seen_shares[$share]:-}" ]]; then
        echo "ERROR: Duplicate share name '$share' in SHARES array"
        exit 1
    fi
    seen_shares[$share]=1
done
unset seen_shares

# Check NAS is reachable before proceeding
# Note: Uses TCP connection to SMB port (445) instead of ping because ICMP is
# often blocked by firewalls, while the SMB port must be open for shares to work
echo "Checking NAS connectivity..."
if ! timeout 3 bash -c "</dev/tcp/$NAS_IP/445" 2>/dev/null; then
    echo "ERROR: Cannot reach NAS at $NAS_IP (port 445)"
    echo "Please verify:"
    echo "  • NAS is powered on"
    echo "  • Network connection is active"
    echo "  • IP address is correct"
    echo "  • SMB/CIFS service is running on NAS"
    exit 1
fi
echo "NAS is reachable."

# Install packages
echo "Installing packages..."
if ! command -v pacman &>/dev/null; then
    echo "ERROR: pacman not found. This script is designed for Arch-based distributions."
    echo "For other distributions, manually install: autofs cifs-utils smbclient libnotify"
    exit 1
fi
pacman -S --needed --noconfirm autofs cifs-utils smbclient libnotify

# Create credentials file
echo "Setting up credentials..."
mkdir -p /etc/samba
if [[ ! -f "$CREDS_FILE" ]]; then
    # Check for interactive terminal
    if [[ ! -t 0 ]]; then
        echo "ERROR: Cannot read password - stdin is not a terminal"
        echo "Run this script interactively to enter the SMB password"
        exit 1
    fi
    echo "Enter SMB password for $NAS_USER:"
    # Note: Password is briefly held in SMB_PASS variable until script exits.
    # This is intentional for simplicity; the variable is not exported and the
    # script is short-lived. For higher security environments, consider using
    # a secrets manager or prompting directly into the file.
    read -rs SMB_PASS
    echo ""
    # Reject empty or whitespace-only passwords; these would technically be stored
    # but almost certainly indicate user error (accidental Enter) and would fail
    # SMB authentication anyway.
    if [[ -z "$SMB_PASS" || -z "${SMB_PASS//[[:space:]]/}" ]]; then
        echo "ERROR: Password cannot be empty or whitespace-only"
        exit 1
    fi
    # Reject passwords containing newlines as they would corrupt the credentials file format
    if [[ "$SMB_PASS" == *$'\n'* ]] || [[ "$SMB_PASS" == *$'\r'* ]]; then
        echo "ERROR: Password cannot contain newline or carriage return characters"
        exit 1
    fi
    # Create file with restricted permissions before writing credentials
    # to avoid brief window of world-readable sensitive data
    install -m 600 /dev/null "$CREDS_FILE"
    # Note: Using quoted heredoc delimiter to prevent expansion of special
    # characters in passwords (e.g., $, `, \). Variables are written via echo.
    {
        echo "username=$NAS_USER"
        echo "password=$SMB_PASS"
    } > "$CREDS_FILE"
    echo "Credentials saved."
else
    echo "Credentials file already exists, validating..."
    # Validate credentials file has required fields
    # Use -s to check file exists and is non-empty first to avoid grep failures under set -e
    if [[ ! -s "$CREDS_FILE" ]] || \
       ! grep -q '^username=' "$CREDS_FILE" || \
       ! grep -q '^password=' "$CREDS_FILE"; then
        echo "ERROR: Credentials file is malformed (missing username= or password=)"
        echo "Delete $CREDS_FILE and re-run this script"
        exit 1
    fi
    echo "Credentials file valid."
fi

# Validate that configured shares actually exist on NAS before proceeding
# Note: This validation is intentionally placed AFTER credentials setup so that
# smbclient can authenticate. On first run, credentials are created above; on
# subsequent runs, existing credentials are used. This catches typos in SHARES
# array early, before writing config files.
echo "Validating configured shares exist on NAS..."
available_shares=$(smbclient -L "$NAS_IP" -A "$CREDS_FILE" -g 2>/dev/null | grep "^Disk|" | cut -d'|' -f2 || true)
if [[ -z "$available_shares" ]]; then
    echo "WARNING: Could not list NAS shares (credentials issue?)"
    echo "         Continuing anyway; monitor will detect mismatches later."
else
    missing_shares=()
    for share in "${SHARES[@]}"; do
        if ! echo "$available_shares" | grep -qx "$share"; then
            missing_shares+=("$share")
        fi
    done
    if [[ ${#missing_shares[@]} -gt 0 ]]; then
        echo "WARNING: The following configured shares were not found on NAS:"
        for share in "${missing_shares[@]}"; do
            echo "  • $share"
        done
        echo "Check for typos in SHARES array. Continuing anyway."
    fi
fi

# Create autofs directory (may already exist from package, but ensure it's there
# in case of minimal install or manual package management)
mkdir -p /etc/autofs

# Backup and modify auto.master
# Note: Uses flock + temp file + atomic move to prevent race conditions.
# This ensures that concurrent script runs or other processes modifying
# auto.master won't cause corruption or duplicate entries.
echo "Configuring auto.master..."
(
    flock -x 200 || { echo "ERROR: Could not acquire lock on auto.master"; exit 1; }
    
    if [[ -f /etc/auto.master ]]; then
        # Create timestamped backup, keeping only the 5 most recent to prevent
        # indefinite accumulation from repeated script runs
        backup_file="/etc/auto.master.bak.$(date +%Y%m%d-%H%M%S)"
        echo "Backing up /etc/auto.master to $backup_file..."
        cp /etc/auto.master "$backup_file"
        
        # Clean up old backups, keeping only the 5 most recent
        # Note: Uses find instead of ls to avoid parsing ls output, which is
        # fragile with special characters (though our timestamp format is safe)
        find /etc -maxdepth 1 -name 'auto.master.bak.*' -printf '%T@ %p\n' 2>/dev/null | \
            sort -rn | tail -n +6 | cut -d' ' -f2- | xargs -r rm -f --
        
        # Create new auto.master without old /mnt/nas entry, then add our entry
        grep -v "^/mnt/nas[[:space:]]" /etc/auto.master > "/etc/auto.master.tmp.$$" 2>/dev/null || true
    else
        # No existing file; create empty temp file
        : > "/etc/auto.master.tmp.$$"
    fi
    
    # Add our entry
    echo "/mnt/nas $AUTOFS_MAP --timeout=300 --ghost" >> "/etc/auto.master.tmp.$$"
    
    # Atomic move into place
    mv "/etc/auto.master.tmp.$$" /etc/auto.master
    chmod 644 /etc/auto.master
) 200>/etc/auto.master.lock || exit 1

# Clean up lock file (empty file left behind by flock)
rm -f /etc/auto.master.lock

# Create the map with explicit entries (write to temp file first)
# Mount options explained:
#   - No explicit vers= : Auto-negotiates SMB version (prefers newest: 3.1.1 > 3.0 > 2.1)
#     This is intentional for maximum compatibility across NAS firmware versions.
#   - soft : Returns errors instead of hanging indefinitely if server is unreachable
#   - echo_interval=10 : Send keepalive probes every 10s (default 60s). This allows
#     dead connections to be detected in ~10-20s instead of ~60-120s, preventing
#     file manager hangs when NAS becomes unreachable.
#   - nounix : Disables UNIX extensions (improves compatibility with non-Linux NAS)
#   - noserverino : Uses client-generated inode numbers (prevents inode collisions on some NAS)
# Note: Unlike NFS, CIFS has no 'timeo' option. The 'soft' option provides non-blocking
# behavior; echo_interval controls how quickly dead connections are detected.
echo "Creating autofs map with explicit shares..."
{
    echo "# NAS shares - explicit entries"
    echo "# Options: soft mount (non-blocking), 10s keepalive for fast failure detection"
    echo ""
    for share in "${SHARES[@]}"; do
        if [[ -n "$share" ]]; then
            # Use printf instead of echo to avoid issues with share names that
            # could be misinterpreted as echo flags (e.g., -n, -e). While our
            # validation now requires alphanumeric first char, this is defensive.
            printf '%s -fstype=cifs,credentials=%s,uid=%s,gid=%s,iocharset=utf8,nounix,noserverino,file_mode=0664,dir_mode=0775,soft,echo_interval=10 ://%s/%s\n' \
                "$share" "$CREDS_FILE" "$MOUNT_UID" "$MOUNT_GID" "$NAS_IP" "$share"
        fi
    done
} | tee "${AUTOFS_MAP}.tmp" > /dev/null

# Validate generated map before moving into place
if ! grep -q "fstype=cifs" "${AUTOFS_MAP}.tmp"; then
    echo "ERROR: Failed to generate valid autofs map"
    exit 1
fi

# Atomic move into place
mv "${AUTOFS_MAP}.tmp" "$AUTOFS_MAP"
chmod 644 "$AUTOFS_MAP"

# Create the share monitor script
# Note: Script path and credentials path are intentionally world-readable (755/644)
# since they don't contain secrets; the credentials file itself is 600.
# Using unquoted heredoc to allow variable substitution for NAS_IP, CREDS_FILE, AUTOFS_MAP.
# This is safe because NAS_IP and share names are validated earlier (lines 82-98, 107-114)
# to contain only alphanumeric characters, dots, hyphens, and underscores - no shell
# metacharacters that could cause injection issues in the generated script.
echo "Installing share monitor script..."
tee /usr/local/bin/nas-share-monitor > /dev/null << MONITOR_EOF
#!/bin/bash
# shellcheck shell=bash
# Monitors NAS shares and notifies user of mismatches

# Note: set -e is intentionally omitted. This script uses custom error handling
# throughout (checking exit codes, || true patterns) because we want partial
# failures to be logged and handled gracefully rather than causing immediate exit.
# For example, if notification fails we still want to log and continue.
set -uo pipefail

SCRIPT_VERSION="$SCRIPT_VERSION"
NAS_IP="$NAS_IP"
CREDS_FILE="$CREDS_FILE"
AUTOFS_MAP="$AUTOFS_MAP"

# =============================================================================
# HELP AND MANUAL
# =============================================================================

show_help() {
    cat << 'HELP_TEXT'
Usage: nas-share-monitor [OPTION]

Check for mismatches between configured NAS shares and actual shares on the NAS.
Sends desktop notifications when differences are found.

Options:
  -h, --help          Show this help message and exit
  -m, --man           Show detailed manual page
  -v, --version       Show version information

Without options, runs the share check.

Examples:
  nas-share-monitor           # Run share check
  nas-share-monitor --help    # Show help

Aliases: nas-mon, nasmon
HELP_TEXT
}

show_man() {
    cat << 'MAN_TEXT'
NAME
    nas-share-monitor - Check for NAS share configuration mismatches

SYNOPSIS
    nas-share-monitor [OPTION]

DESCRIPTION
    Compares the shares configured in the autofs map against the actual
    shares available on the NAS. Sends desktop notifications when:
    
    • A configured share doesn't exist on the NAS (typo or removed share)
    • A share exists on the NAS but isn't configured (new share available)

    The script is designed to run automatically via systemd timer (at login
    and daily), but can also be run manually.

OPTIONS
    -h, --help
        Display brief usage information and exit.

    -m, --man
        Display this detailed manual page and exit.

    -v, --version
        Display version information and exit.

BEHAVIOR
    1. Waits for NAS connectivity (up to 60 seconds)
    2. Lists configured shares from autofs map
    3. Lists actual shares from NAS (via smbclient)
    4. Compares the two lists
    5. Sends desktop notification if differences found
    6. Triggers mounting of all configured shares

    Notifications are de-duplicated using a state hash stored in:
        ~/.cache/nas-share-check-notified

    To force re-notification, delete this file.

FILES
    ~/.cache/nas-share-monitor.log
        Log file (auto-rotated at 100KB)

    ~/.cache/nas-share-monitor.lock
        Lock file preventing concurrent runs

    ~/.cache/nas-share-check-notified
        Hash of last mismatch state

EXIT STATUS
    0   Success (or no changes from last check)
    1   NAS unreachable or authentication failed

SEE ALSO
    nas-share-edit(1), setup-nas-mounts(1)
MAN_TEXT
}

show_version() {
    echo "nas-share-monitor version \$SCRIPT_VERSION"
}

# Parse arguments
case "\${1:-}" in
    -h|--help)
        show_help
        exit 0
        ;;
    -m|--man)
        show_man | \${PAGER:-less}
        exit 0
        ;;
    -v|--version)
        show_version
        exit 0
        ;;
    "")
        # No arguments - continue with check
        ;;
    *)
        echo "Unknown option: \$1"
        echo "Try 'nas-share-monitor --help' for more information."
        exit 1
        ;;
esac

# =============================================================================
# MAIN SCRIPT
# =============================================================================

# Determine home directory robustly (works in systemd context)
if [[ -n "\${HOME:-}" ]]; then
    USER_HOME="\$HOME"
else
    USER_HOME="\$(getent passwd "\$(id -un)" | cut -d: -f6)"
fi

CACHE_DIR="\${XDG_CACHE_HOME:-\$USER_HOME/.cache}"
CACHE_FILE="\$CACHE_DIR/nas-share-check-notified"
LOG_FILE="\$CACHE_DIR/nas-share-monitor.log"
LOCK_FILE="\$CACHE_DIR/nas-share-monitor.lock"

# Ensure cache directory exists
if ! mkdir -p "\$CACHE_DIR"; then
    echo "ERROR: Failed to create cache directory \$CACHE_DIR" >&2
    exit 1
fi

# Acquire lock to prevent concurrent executions (from timer + manual run)
exec 9>"\$LOCK_FILE"
if ! flock -n 9; then
    echo "Another instance is already running, exiting."
    exit 0
fi

log() {
    echo "\$(date '+%Y-%m-%d %H:%M:%S'): \$*" >> "\$LOG_FILE"
}

# Send notification only if display is available
send_notification() {
    local urgency="\$1"
    local title="\$2"
    local message="\$3"
    
    # Check if we have a display
    if [[ -z "\${DISPLAY:-}" && -z "\${WAYLAND_DISPLAY:-}" ]]; then
        # Try to find a display from logged-in user sessions
        local user_display=""
        
        # Method 1: Check who output for X11 display
        if [[ -z "\$user_display" ]]; then
            user_display=\$(who 2>/dev/null | grep -oE '\(:[0-9]+(\.[0-9]+)?\)' | head -1 | tr -d '()') || true
        fi
        
        # Method 2: Check loginctl for graphical sessions
        if [[ -z "\$user_display" ]] && command -v loginctl &>/dev/null; then
            local session_id
            session_id=\$(loginctl list-sessions --no-legend 2>/dev/null | awk '\$3 == "'"$(id -un)"'" {print \$1; exit}') || true
            if [[ -n "\$session_id" ]]; then
                local session_type
                session_type=\$(loginctl show-session "\$session_id" -p Type --value 2>/dev/null) || true
                if [[ "\$session_type" == "x11" ]]; then
                    user_display=\$(loginctl show-session "\$session_id" -p Display --value 2>/dev/null) || true
                elif [[ "\$session_type" == "wayland" ]]; then
                    # For Wayland, we just need WAYLAND_DISPLAY which we'll set below
                    export WAYLAND_DISPLAY="\${WAYLAND_DISPLAY:-wayland-0}"
                fi
            fi
        fi
        
        if [[ -n "\$user_display" ]]; then
            export DISPLAY="\$user_display"
        elif [[ -z "\${WAYLAND_DISPLAY:-}" ]]; then
            log "No display available for notification: \$title - \$message"
            return 1
        fi
    fi
    
    # Also need DBUS_SESSION_BUS_ADDRESS for notify-send
    if [[ -z "\${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
        local uid
        uid=\$(id -u)
        if [[ -S "/run/user/\$uid/bus" ]]; then
            export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/\$uid/bus"
        else
            log "No D-Bus session for notification: \$title - \$message"
            return 1
        fi
    fi
    
    # Timeout of 30 seconds (30000ms) is intentional: long enough to be noticed,
    # short enough to not clutter the notification area indefinitely.
    # Critical notifications may still persist depending on DE settings.
    notify-send -u "\$urgency" -t 30000 "\$title" "\$message"
}

# Get configured shares from autofs map
get_configured_shares() {
    grep -v '^#' "\$AUTOFS_MAP" 2>/dev/null | grep -v '^\$' | awk '{print \$1}' | sort
}

# Get actual shares from NAS
get_nas_shares() {
    local output
    # Initialize exit_code to 0; the || assignment only runs on failure, so
    # without initialization, set -u would error on the subsequent -ne check
    local exit_code=0
    
    # Capture stdout only; stderr goes to log for debugging but doesn't pollute output
    # This prevents partial success scenarios where error messages mix with share names
    output=\$(smbclient -L "\$NAS_IP" -A "\$CREDS_FILE" -g 2>>"\$LOG_FILE") || exit_code=\$?
    
    if [[ \$exit_code -ne 0 ]]; then
        log "ERROR: smbclient failed (exit \$exit_code)"
        # Return both ERROR string and non-zero exit for defense in depth;
        # callers can check either the output or the return code
        echo "ERROR"
        return 1
    fi
    
    # Filter out admin shares (those containing \$, e.g., IPC\$, C\$, ADMIN\$).
    # Note: This also filters any user shares containing \$ anywhere in the name,
    # which is acceptable since \$ in share names is rare and conventionally
    # indicates hidden/admin shares on Windows/Samba systems.
    # Use character class [\$] because bare \$ in regex matches end-of-line.
    # The { ... || true; } groups the entire pipeline so || true applies to the
    # whole thing, not just sort. This prevents empty results from causing exit.
    { echo "\$output" | grep "^Disk|" | cut -d'|' -f2 | grep -v '[\$]' | sort; } || true
}

# Wait for network
wait_for_network() {
    local max_attempts=30
    local attempt=0
    # Note: Uses TCP connection to SMB port (445) instead of ping because ICMP
    # is often blocked by firewalls, while the SMB port must be open anyway
    while ! timeout 1 bash -c "</dev/tcp/\$NAS_IP/445" 2>/dev/null; do
        ((attempt++))
        if ((attempt >= max_attempts)); then
            log "NAS not reachable after \$max_attempts attempts"
            return 1
        fi
        sleep 2
    done
    return 0
}

# Main check
main() {
    # Rotate log if over 100KB (lock is already held, so rotation is safe)
    # Note: If script crashes between tail and mv, .tmp file is orphaned.
    # This is acceptable; the next run will overwrite it.
    if [[ -f "\$LOG_FILE" ]]; then
        local log_size
        log_size=\$(stat -c%s "\$LOG_FILE" 2>/dev/null || stat -f%z "\$LOG_FILE" 2>/dev/null || echo 0)
        if [[ "\$log_size" -gt 102400 ]]; then
            tail -n 500 "\$LOG_FILE" > "\$LOG_FILE.tmp" && mv "\$LOG_FILE.tmp" "\$LOG_FILE"
        fi
    fi

    log "Starting share check..."
    
    if ! wait_for_network; then
        send_notification critical "NAS Monitor" "Cannot reach NAS at \$NAS_IP"
        exit 1
    fi

    configured=\$(get_configured_shares)
    actual=\$(get_nas_shares)
    
    # Check for smbclient errors
    if [[ "\$actual" == "ERROR" ]]; then
        send_notification critical "NAS Monitor" "Failed to list shares. Check credentials and logs."
        exit 1
    fi
    
    if [[ -z "\$actual" ]]; then
        log "WARNING: No shares returned from NAS (credentials issue?)"
        send_notification warning "NAS Monitor" "No shares found on NAS. Check credentials."
        exit 1
    fi

    # Find differences
    # Note: comm requires sorted input. Both get_configured_shares() and get_nas_shares()
    # return sorted output, but we explicitly sort again here as a defensive measure
    # in case those functions change. Empty strings are handled separately above.
    if [[ -z "\$configured" ]]; then
        missing_on_nas=""
        new_on_nas="\$actual"
    elif [[ -z "\$actual" ]]; then
        missing_on_nas="\$configured"
        new_on_nas=""
    else
        # Note: printf '%s\n' ensures each variable ends with a newline, which comm
        # requires for correct line-by-line comparison. Without the trailing newline,
        # the last line of each input would not be compared correctly.
        # The extra sort is defensive in case upstream functions change.
        missing_on_nas=\$(comm -23 <(printf '%s\n' "\$configured" | sort) <(printf '%s\n' "\$actual" | sort))
        new_on_nas=\$(comm -13 <(printf '%s\n' "\$configured" | sort) <(printf '%s\n' "\$actual" | sort))
    fi

    # Build notification message using actual newlines instead of \n escapes
    # because notify-send doesn't interpret \n on all desktop environments
    message=""
    newline=\$'\n'
    
    if [[ -n "\$missing_on_nas" ]]; then
        message+="⚠️ Configured but not on NAS:\${newline}"
        while IFS= read -r share; do
            [[ -n "\$share" ]] && message+="  • \$share\${newline}"
        done <<< "\$missing_on_nas"
        message+="\${newline}"
    fi

    if [[ -n "\$new_on_nas" ]]; then
        message+="📁 On NAS but not configured:\${newline}"
        while IFS= read -r share; do
            [[ -n "\$share" ]] && message+="  • \$share\${newline}"
        done <<< "\$new_on_nas"
    fi

    if [[ -n "\$message" ]]; then
        # Create a hash of current state to avoid repeat notifications.
        # Note: md5sum is intentionally used here as this script targets EndeavourOS/Arch
        # where md5sum is available in coreutils. For cross-platform portability (e.g.,
        # macOS which uses 'md5'), this would need conditional logic.
        state_hash=\$(echo "\$missing_on_nas\$new_on_nas" | md5sum | cut -d' ' -f1)
        
        if [[ ! -f "\$CACHE_FILE" ]] || [[ "\$(cat "\$CACHE_FILE" 2>/dev/null)" != "\$state_hash" ]]; then
            echo "\$state_hash" > "\$CACHE_FILE"
            
            # Desktop notification
            send_notification normal "NAS Share Mismatch" "\${message}Run: nas-share-edit"
            
            log "Share mismatch detected"
            log "\$message"
        fi
    else
        rm -f "\$CACHE_FILE"
        log "All shares match"
    fi

    # Touch all configured shares to trigger mounting (with timeout)
    while IFS= read -r share; do
        [[ -n "\$share" ]] && timeout 5 ls "/mnt/nas/\$share" &>/dev/null || true
    done <<< "\$configured"
}

main "\$@"
MONITOR_EOF
chmod +x /usr/local/bin/nas-share-monitor

# Create helper script to edit shares
# Note: Using unquoted heredoc to allow variable substitution. Safe for the same
# reason as the monitor script above - all substituted values are pre-validated.
echo "Installing share edit helper..."
tee /usr/local/bin/nas-share-edit > /dev/null << EDIT_EOF
#!/bin/bash
# shellcheck shell=bash
# Helper to edit NAS share configuration

SCRIPT_VERSION="$SCRIPT_VERSION"
NAS_IP="$NAS_IP"
CREDS_FILE="$CREDS_FILE"
AUTOFS_MAP="$AUTOFS_MAP"

# =============================================================================
# HELP AND MANUAL
# =============================================================================

show_help() {
    cat << 'HELP_TEXT'
Usage: nas-share-edit [OPTION]

View NAS share configuration and available shares on the NAS.

Options:
  -h, --help          Show this help message and exit
  -m, --man           Show detailed manual page
  -v, --version       Show version information

Without options, displays current configuration and available shares.

Examples:
  nas-share-edit           # Show configuration
  nas-share-edit --help    # Show help

Aliases: nas-edit, nasedit
HELP_TEXT
}

show_man() {
    cat << 'MAN_TEXT'
NAME
    nas-share-edit - View and edit NAS share configuration

SYNOPSIS
    nas-share-edit [OPTION]

DESCRIPTION
    Displays the currently configured NAS shares alongside the shares
    actually available on the NAS. Provides instructions for adding
    or removing shares from the configuration.

OPTIONS
    -h, --help
        Display brief usage information and exit.

    -m, --man
        Display this detailed manual page and exit.

    -v, --version
        Display version information and exit.

OUTPUT
    The command displays:
    
    1. Currently configured shares (from autofs map)
    2. Shares available on the NAS (via smbclient)
    3. Instructions for editing the configuration
    4. Example entry format with correct UID/GID

EDITING SHARES
    To add a new share:
    
    1. Run: sudo nano /etc/autofs/nas.autofs
    2. Add a line in the format shown by nas-share-edit
    3. Run: sudo systemctl restart autofs
    
    To remove a share:
    
    1. Run: sudo nano /etc/autofs/nas.autofs
    2. Delete or comment out the line
    3. Run: sudo systemctl restart autofs

FILES
    /etc/autofs/nas.autofs
        Autofs indirect map with share definitions

    /etc/samba/creds-mainstorage
        SMB credentials file (used for NAS authentication)

SEE ALSO
    nas-share-monitor(1), setup-nas-mounts(1), autofs(5)
MAN_TEXT
}

show_version() {
    echo "nas-share-edit version \$SCRIPT_VERSION"
}

# Parse arguments
case "\${1:-}" in
    -h|--help)
        show_help
        exit 0
        ;;
    -m|--man)
        show_man | \${PAGER:-less}
        exit 0
        ;;
    -v|--version)
        show_version
        exit 0
        ;;
    "")
        # No arguments - continue with display
        ;;
    *)
        echo "Unknown option: \$1"
        echo "Try 'nas-share-edit --help' for more information."
        exit 1
        ;;
esac

# =============================================================================
# MAIN SCRIPT
# =============================================================================

echo "=== NAS Share Configuration ==="
echo ""
echo "Currently configured shares:"
grep -v '^#' "\$AUTOFS_MAP" 2>/dev/null | grep -v '^\$' | awk '{print "  • " \$1}'
echo ""
echo "Shares available on NAS:"
# Capture both stdout and stderr; stderr contains SMB negotiation details which
# may be useful for diagnosing connection issues
smb_output=\$(smbclient -L "\$NAS_IP" -A "\$CREDS_FILE" -g 2>&1)
smb_exit=\$?
if [[ \$smb_exit -eq 0 ]]; then
    # Filter out admin shares (those containing \$, e.g., IPC\$, C\$, ADMIN\$).
    # Note: This also filters any user shares containing \$ anywhere in the name,
    # which is acceptable since \$ in share names is rare and conventionally
    # indicates hidden/admin shares on Windows/Samba systems.
    echo "\$smb_output" | grep "^Disk|" | cut -d'|' -f2 | grep -v '[\$]' | while read -r share; do
        echo "  • \$share"
    done
else
    echo "  (ERROR: Could not connect to NAS - exit code \$smb_exit)"
    echo "  Output: \$smb_output"
    echo "  Check network connectivity and credentials file."
fi
echo ""
echo "To edit, run:"
echo "  sudo nano \$AUTOFS_MAP"
echo ""
echo "After editing, restart autofs:"
echo "  sudo systemctl restart autofs"
echo ""
echo "Entry format (use your actual UID/GID):"
echo "  ShareName -fstype=cifs,credentials=\$CREDS_FILE,uid=\$(id -u),gid=\$(id -g),iocharset=utf8,nounix,noserverino,file_mode=0664,dir_mode=0775,soft,echo_interval=10 ://\$NAS_IP/ShareName"
EDIT_EOF
chmod +x /usr/local/bin/nas-share-edit

# Install the setup script itself to /usr/local/bin for the alias
echo "Installing setup script to /usr/local/bin..."
cp "$0" /usr/local/bin/nas-mount-setup
chmod +x /usr/local/bin/nas-mount-setup

# Create systemd user service for monitoring
# Runs at login and can also be triggered manually
echo "Setting up systemd user service..."

# Intentionally create directory as real user rather than as root then chown;
# avoids touching permissions on parent directories we didn't create
if [[ -n "${SUDO_USER:-}" ]]; then
    sudo -u "$SUDO_USER" mkdir -p "$REAL_HOME/.config/systemd/user"
else
    mkdir -p "$REAL_HOME/.config/systemd/user"
fi

# Write service files as real user to avoid root-owned files in user's home.
# While later chown would fix ownership, this avoids a race where systemd might
# see root-owned files before the chown runs.
if [[ -n "${SUDO_USER:-}" ]]; then
    sudo -u "$SUDO_USER" tee "$REAL_HOME/.config/systemd/user/nas-share-monitor.service" > /dev/null << 'SERVICE_EOF'
[Unit]
Description=NAS Share Monitor
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/nas-share-monitor

[Install]
WantedBy=default.target
SERVICE_EOF

    sudo -u "$SUDO_USER" tee "$REAL_HOME/.config/systemd/user/nas-share-monitor.timer" > /dev/null << 'TIMER_EOF'
[Unit]
Description=NAS share check timer
After=network-online.target

[Timer]
# Run 15 seconds after user session starts (not after network-online;
# After= in [Unit] only orders activation, it doesn't delay the timer)
OnStartupSec=15s
# Then run daily
OnCalendar=daily
# Note: Persistent=true for user timers only catches up missed runs if the user
# session was active when the timer would have fired. If user wasn't logged in,
# the timer won't run retroactively. This is intentional/acceptable since the
# OnStartupSec handles the login case, and daily checks are best-effort.
Persistent=true

[Install]
WantedBy=timers.target
TIMER_EOF
else
    cat > "$REAL_HOME/.config/systemd/user/nas-share-monitor.service" << 'SERVICE_EOF'
[Unit]
Description=NAS Share Monitor
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/nas-share-monitor

[Install]
WantedBy=default.target
SERVICE_EOF

    cat > "$REAL_HOME/.config/systemd/user/nas-share-monitor.timer" << 'TIMER_EOF'
[Unit]
Description=NAS share check timer
After=network-online.target

[Timer]
# Run 15 seconds after user session starts (not after network-online;
# After= in [Unit] only orders activation, it doesn't delay the timer)
OnStartupSec=15s
# Then run daily
OnCalendar=daily
# Note: Persistent=true for user timers only catches up missed runs if the user
# session was active when the timer would have fired. If user wasn't logged in,
# the timer won't run retroactively. This is intentional/acceptable since the
# OnStartupSec handles the login case, and daily checks are best-effort.
Persistent=true

[Install]
WantedBy=timers.target
TIMER_EOF
fi

# Enable user services (must run as actual user, not root)
# Note: we both enable AND start the timer so it begins running immediately,
# not just on next login.
echo "Enabling user services..."
if [[ -n "${SUDO_USER:-}" ]]; then
    # Check if user session runtime directory exists before attempting to
    # enable user services; it won't exist if user has no active session
    if [[ -d "/run/user/$MOUNT_UID" ]]; then
        sudo -u "$SUDO_USER" XDG_RUNTIME_DIR="/run/user/$MOUNT_UID" systemctl --user daemon-reload
        sudo -u "$SUDO_USER" XDG_RUNTIME_DIR="/run/user/$MOUNT_UID" systemctl --user enable nas-share-monitor.service
        sudo -u "$SUDO_USER" XDG_RUNTIME_DIR="/run/user/$MOUNT_UID" systemctl --user enable --now nas-share-monitor.timer
    else
        echo "WARNING: User session not active (/run/user/$MOUNT_UID not found)"
        echo "         Service files installed but not enabled."
        echo "         After logging in graphically, run:"
        echo "           systemctl --user daemon-reload"
        echo "           systemctl --user enable nas-share-monitor.service"
        echo "           systemctl --user enable --now nas-share-monitor.timer"
        echo ""
        echo "         Or enable lingering to allow user services without login:"
        echo "           sudo loginctl enable-linger $REAL_USER"
    fi
else
    systemctl --user daemon-reload
    systemctl --user enable nas-share-monitor.service
    systemctl --user enable --now nas-share-monitor.timer
fi

# Remove old autostart if exists
rm -f "$REAL_HOME/.config/autostart/mount-nas.desktop"

# Create mount point and symlink in home
echo "Creating /mnt/nas and ~/Drives/nas symlink..."
mkdir -p /mnt/nas
mkdir -p "$REAL_HOME/Drives"

# Handle symlink creation atomically to avoid TOCTOU race.
# Create symlink in temp location then atomically move it into place.
# If target exists as a real directory, warn and skip.
if [[ -e "$REAL_HOME/Drives/nas" && ! -L "$REAL_HOME/Drives/nas" ]]; then
    echo ""
    echo "WARNING: $REAL_HOME/Drives/nas exists as a regular file/directory"
    echo "         Symlink NOT created. Remove it manually if you want the symlink:"
    echo "         rm -rf '$REAL_HOME/Drives/nas'"
    echo ""
    echo "         Shares are still accessible at /mnt/nas/<share>"
    echo ""
else
    # Atomic symlink creation: create in temp location, then rename
    # This avoids any race between checking existence and creating
    temp_link="$REAL_HOME/Drives/.nas-symlink-$$"
    if [[ -n "${SUDO_USER:-}" ]]; then
        sudo -u "$SUDO_USER" ln -sfn /mnt/nas "$temp_link"
        sudo -u "$SUDO_USER" mv -Tf "$temp_link" "$REAL_HOME/Drives/nas"
    else
        ln -sfn /mnt/nas "$temp_link"
        mv -Tf "$temp_link" "$REAL_HOME/Drives/nas"
    fi
fi

if [[ -n "${SUDO_USER:-}" ]]; then
    chown "$SUDO_USER:$SUDO_USER" "$REAL_HOME/Drives"
fi
# Note: When running as root directly (not via sudo), $REAL_HOME/Drives remains
# root-owned. This is intentional and consistent with the user confirmation prompt
# earlier - if the user chose to run as root, root ownership is expected.

# Set up shell aliases
echo "Setting up shell aliases..."
add_shell_aliases

# Enable and restart autofs
# Note: restart (not reload) is required because we modified /etc/auto.master.
# Reload only re-reads map files, not the master file.
echo "Starting autofs..."
systemctl enable autofs
systemctl restart autofs

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Configured shares (accessible via /mnt/nas/<share> or ~/Drives/nas/<share>):"
for share in "${SHARES[@]}"; do
    echo "  • $share"
done
echo ""
echo "Behavior:"
echo "  • Shares auto-unmount after 5 minutes idle (prevents hangs if NAS offline)"
echo "  • Soft mount with 10s keepalive detects dead connections in ~10-20s"
echo "  • SMB version auto-negotiated (prefers newest available)"
echo ""
echo "Commands:"
echo "  nas-share-edit    - View config and available shares (alias: nas-edit)"
echo "  nas-share-monitor - Manually check for mismatches (alias: nas-mon)"
echo "  nas-mount-setup   - Re-run setup or uninstall"
echo ""
echo "Use --help with any command for more information."
echo ""
echo "The monitor runs at login, 15s after session starts, and daily."
echo ""
echo "Shell aliases added. Restart your shell or run: source ~/.bashrc"
