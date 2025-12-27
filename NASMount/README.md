# NAS Mount Setup for EndeavourOS

Automated SMB/CIFS mounting using autofs with share mismatch detection and desktop notifications.

**Features:** On-demand mounting • Auto-unmount after idle • Soft mounts (no hangs) • Fast failure detection • Share monitoring with notifications • User-space file ownership

## Quick Start

```bash
# 1. Install autofs from AUR
yay -S autofs   # or: paru -S autofs

# 2. Configure your NAS details
nano setup-nas-mounts.sh
```

Edit these variables at the top of the script:

```bash
NAS_IP="192.168.1.100"              # Your NAS IP or hostname
NAS_USER="your_username"            # SMB username
SHARES=("Documents" "Media" "Backups")  # Shares to mount
```

```bash
# 3. Run setup
sudo ./setup-nas-mounts.sh

# 4. Reload shell and access shares
source ~/.bashrc
ls ~/Drives/nas/Documents
```

## Commands

| Command | Aliases | Description |
|---------|---------|-------------|
| `nas-mount-setup` | — | Re-run setup or uninstall |
| `nas-share-edit` | `nas-edit`, `nasedit` | View config and available shares |
| `nas-share-monitor` | `nas-mon`, `nasmon` | Check for share mismatches |

All commands support `--help`, `--man`, and `--version`.

## Uninstall

```bash
# Keep credentials and config (for reinstall)
sudo nas-mount-setup --uninstall

# Remove everything
sudo nas-mount-setup --uninstall-full
```

---

## How It Works

```
User accesses              autofs daemon              NAS
~/Drives/nas/Documents  →  mounts on demand  →  \\192.168.1.100\Documents
                                ↓
                        unmounts after 5 min idle
```

Shares mount automatically when accessed and unmount after 5 minutes of inactivity. Soft mounts with 10-second keepalive probes ensure the system won't hang if the NAS becomes unreachable—dead connections are detected in ~10-20 seconds.

---

## Requirements

| Requirement | Details |
|-------------|---------|
| **OS** | Arch-based (EndeavourOS, Arch, Manjaro) |
| **Network** | NAS reachable on port 445 (SMB) |
| **Execution** | Run with `sudo` from regular user account |

### Dependencies

| Package | Source | Purpose |
|---------|--------|---------|
| `autofs` | AUR | Automount daemon (**install manually first**) |
| `cifs-utils` | Official | CIFS filesystem support (auto-installed) |
| `smbclient` | Official | Share enumeration (auto-installed) |
| `libnotify` | Official | Desktop notifications (auto-installed) |

---

## Configuration

### Share Names

- Must start with a letter or number
- May contain: letters, numbers, underscores (`_`), hyphens (`-`)
- Case-sensitive (must match NAS exactly)
- No spaces, special characters, or duplicates

### Credentials

- Username cannot contain `=` or newlines
- Password cannot contain newlines or carriage returns
- Stored in `/etc/samba/creds-mainstorage` (mode 640)

---

## Troubleshooting

<details>
<summary><strong>Share not mounting</strong></summary>

```bash
# Check autofs status
systemctl status autofs
journalctl -u autofs -f

# Test SMB connection
smbclient -L YOUR_NAS_IP -A /etc/samba/creds-mainstorage

# Verify credentials format
sudo cat /etc/samba/creds-mainstorage
# Expected:
# username=your_user
# password=your_pass
```

</details>

<details>
<summary><strong>Permission denied</strong></summary>

```bash
# Compare UID/GID in config vs your user
grep uid /etc/autofs/nas.autofs
id

# Fix if mismatched
sudo nano /etc/autofs/nas.autofs
sudo systemctl restart autofs
```

</details>

<details>
<summary><strong>NAS unreachable</strong></summary>

```bash
# Test SMB port
timeout 3 bash -c '</dev/tcp/YOUR_NAS_IP/445' && echo "OK" || echo "FAILED"

# Test network
ping YOUR_NAS_IP
```

</details>

<details>
<summary><strong>Stale mount after NAS reboot</strong></summary>

```bash
# Unmount specific share
sudo umount -l /mnt/nas/ShareName

# Or restart autofs
sudo systemctl restart autofs
```

</details>

<details>
<summary><strong>Mounts not working (autofs reading wrong config)</strong></summary>

```bash
# Check which config autofs is reading
timeout 3 automount -f -v 2>&1 | grep "reading files master"

# Look for conflicting entries
grep "/mnt/nas" /etc/auto.master /etc/autofs/auto.master 2>/dev/null

# Remove conflicting entry, then restart
sudo systemctl restart autofs
```

</details>

<details>
<summary><strong>Monitor not sending notifications</strong></summary>

```bash
# Check timer
systemctl --user status nas-share-monitor.timer

# View log
cat ~/.cache/nas-share-monitor.log

# Force re-notification
rm ~/.cache/nas-share-check-notified
nas-share-monitor
```

</details>

<details>
<summary><strong>Aliases not working</strong></summary>

```bash
# Check if added
grep "nas-mount-setup aliases" ~/.bashrc

# Reload
source ~/.bashrc
```

</details>

---

## File Locations

```
/etc/
├── auto.master                         # Modified (or /etc/autofs/auto.master)
├── autofs/
│   └── nas.autofs                      # Share definitions
└── samba/
    └── creds-mainstorage               # Credentials (mode 640)

/usr/local/bin/
├── nas-mount-setup                     # This script
├── nas-share-monitor                   # Mismatch detection
└── nas-share-edit                      # Config viewer

~/.config/systemd/user/
├── nas-share-monitor.service           # Monitor service
└── nas-share-monitor.timer             # Runs at login + daily

~/.cache/
├── nas-share-monitor.log               # Monitor log
├── nas-share-monitor.lock              # Prevents concurrent runs
└── nas-share-check-notified            # Notification state hash

/mnt/nas/                               # Mount points (on-demand)
~/Drives/nas → /mnt/nas                 # Convenience symlink
```

---

## Mount Options

| Option | Value | Purpose |
|--------|-------|---------|
| `soft` | — | Return errors instead of hanging |
| `echo_interval` | `10` | Keepalive probe interval (seconds) |
| `uid` / `gid` | Your IDs | Files appear owned by you |
| `file_mode` | `0664` | File permissions (rw-rw-r--) |
| `dir_mode` | `0775` | Directory permissions (rwxrwxr-x) |
| `iocharset` | `utf8` | Filename encoding |
| `nounix` | — | Disable UNIX extensions (compatibility) |
| `noserverino` | — | Client-generated inodes (compatibility) |

**Autofs options:** `--timeout=300` (unmount after 5 min) `--ghost` (show mount points)

---

## Security

- Credentials file: mode `640`, readable by root and user's group only
- Password never logged or echoed to terminal
- Scripts contain no secrets
- Running as root directly (not via sudo) requires confirmation

---

## Systemd Services

```bash
# System service (autofs)
systemctl status autofs
sudo systemctl restart autofs
journalctl -u autofs -f

# User services (monitor)
systemctl --user status nas-share-monitor.timer
systemctl --user start nas-share-monitor.service
```

---

## Manual Uninstall

If the script is unavailable:

```bash
# Stop services
sudo systemctl disable --now autofs
systemctl --user disable --now nas-share-monitor.timer
systemctl --user disable nas-share-monitor.service

# Remove files
sudo rm -f /etc/autofs/nas.autofs /etc/samba/creds-mainstorage
sudo rm -f /usr/local/bin/nas-{mount-setup,share-monitor,share-edit}
rm -f ~/.config/systemd/user/nas-share-monitor.{service,timer}
rm -f ~/.cache/nas-share-{check-notified,monitor.log,monitor.lock}

# Remove /mnt/nas line from auto.master
sudo nano /etc/auto.master  # or /etc/autofs/auto.master

# Clean up mount points
sudo umount -l /mnt/nas/* 2>/dev/null; sudo rmdir /mnt/nas
rm ~/Drives/nas; rmdir ~/Drives 2>/dev/null

# Remove alias block from ~/.bashrc and ~/.zshrc
```

---

## Changelog

### 1.2.0

- Auto-detects primary `auto.master` location
- Detects and handles conflicting configurations
- Credentials file now mode 640 (was 600) for monitor access
- autofs must be installed from AUR before running
- Added configuration verification step
- Uninstall cleans both `auto.master` locations

### 1.1.1

- Fixed `local` keyword outside function
- Changed to placeholder configuration values

### 1.1.0

- Added `--help`, `--man`, `--version` to all commands
- Added `--uninstall` and `--uninstall-full` options
- Added shell alias configuration
- Added duplicate share detection
- Added password validation
- Improved Wayland notification support

### 1.0.0

- Initial release
