# NAS Mount Setup for EndeavourOS

Automated NAS mounting using autofs with share mismatch detection and desktop notifications.

## Quick Start

```bash
# 1. Edit the script to set your NAS IP, username, and shares
nano setup-nas-mounts.sh

# 2. Run with sudo (from your regular user account)
sudo ./setup-nas-mounts.sh

# 3. Enter your SMB password when prompted

# 4. Restart your shell to enable aliases
source ~/.bashrc

# 5. Access your shares
ls ~/Drives/nas/{SHARE1}
```

That's it! Your NAS shares will now mount automatically when accessed and unmount after 5 minutes of idle time.

## Configuration

Edit these variables at the top of `setup-nas-mounts.sh` before running:

```bash
NAS_IP="{NAS_IP}"                                           # NAS IP or hostname
NAS_USER="{NAS_USER}"                                       # SMB username
SHARES=("{SHARE1}" "{SHARE2}" "{SHARE3}")                   # Shares to mount
```

### Share Name Requirements

- Must start with a letter or number
- May contain letters, numbers, underscores (`_`), and hyphens (`-`)
- No spaces or special characters
- Case-sensitive (must match NAS exactly)
- No duplicates allowed

### Username and Password Requirements

- Username cannot contain `=` or newline characters
- Password cannot contain newline or carriage return characters

## Commands

After setup, you have three commands available (all support `--help`, `--man`, `--version`):

| Command | Aliases | Purpose |
|---------|---------|---------|
| `nas-mount-setup` | — | Re-run setup or uninstall |
| `nas-share-edit` | `nas-edit`, `nasedit` | View configuration and available shares |
| `nas-share-monitor` | `nas-mon`, `nasmon` | Check for share mismatches |

### Common Tasks

```bash
# View what's configured vs. what's on the NAS
nas-share-edit

# Manually check for mismatches (also runs automatically)
nas-share-monitor

# Re-run setup after editing the script
sudo nas-mount-setup

# Uninstall (keeps credentials and config)
sudo nas-mount-setup --uninstall

# Complete uninstall (removes everything)
sudo nas-mount-setup --uninstall-full
```

## Troubleshooting

### Share not mounting

```bash
# Check if autofs is running
systemctl status autofs

# Check autofs logs
journalctl -u autofs -f

# Test SMB connectivity manually
smbclient -L {NAS_IP} -A /etc/samba/creds-mainstorage

# Verify credentials file format
sudo cat /etc/samba/creds-mainstorage
# Should show:
# username={NAS_USER}
# password=yourpassword
```

### "Permission denied" on mount

```bash
# Check UID/GID in autofs map matches your user
grep uid /etc/autofs/nas.autofs
id

# If mismatched, edit and restart
sudo nano /etc/autofs/nas.autofs
sudo systemctl restart autofs
```

### NAS unreachable

```bash
# Test SMB port connectivity
timeout 3 bash -c '</dev/tcp/{NAS_IP}/445' && echo "OK" || echo "FAILED"

# Ping test (may be blocked by firewall)
ping {NAS_IP}
```

### Stale mount after NAS reboot

```bash
# Force unmount a specific share
sudo umount -l /mnt/nas/{SHARE_NAME}

# Or restart autofs to clear all mounts
sudo systemctl restart autofs
```

### Monitor not sending notifications

```bash
# Check if timer is active
systemctl --user status nas-share-monitor.timer

# Check the log
cat ~/.cache/nas-share-monitor.log

# Force re-notification by clearing state
rm ~/.cache/nas-share-check-notified
nas-share-monitor
```

### Aliases not working

```bash
# Check if aliases were added
grep "nas-mount-setup aliases" ~/.bashrc

# Reload shell configuration
source ~/.bashrc
```

---

## How It Works

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│  User accesses  │────▶│  autofs daemon  │────▶│   NAS (SMB)     │
│  ~/Drives/nas/  │     │  mounts share   │     │  {NAS_IP}       │
│  Documents      │     │  on demand      │     │                 │
└─────────────────┘     └─────────────────┘     └─────────────────┘
                               │
                               ▼ (after 5 min idle)
                        ┌─────────────────┐
                        │ auto-unmounts   │
                        └─────────────────┘
```

### Features

- **On-demand mounting** — Shares mount automatically when accessed, unmount after 5 minutes idle
- **Soft mounts** — Non-blocking I/O prevents system hangs if NAS becomes unreachable
- **Fast failure detection** — 10-second keepalive detects dead connections in ~10-20s
- **Share mismatch monitoring** — Desktop notifications when configured shares differ from NAS (supports X11 and Wayland)
- **User-space file ownership** — Mounted files appear owned by your user, not root
- **Automatic SMB version** — Negotiates highest available (prefers SMB 3.1.1)

### What Gets Installed

The setup script:

1. Installs required packages (`autofs`, `cifs-utils`, `smbclient`, `libnotify`)
2. Creates a credentials file with your SMB username/password
3. Configures autofs to mount your shares on-demand
4. Installs monitoring scripts that notify you of share mismatches
5. Sets up a systemd timer to check shares at login and daily
6. Adds shell aliases for convenience

---

## Requirements

- **Arch-based distribution** (EndeavourOS, Arch, Manjaro, etc.) — uses `pacman`
- **Network access** to NAS on port 445 (SMB)
- **Run with sudo** from your regular user account (not as root directly)

### Dependencies

Installed automatically:

| Package | Purpose |
|---------|---------|
| `autofs` | Automount daemon |
| `cifs-utils` | CIFS/SMB filesystem support |
| `smbclient` | SMB client for share enumeration |
| `libnotify` | Desktop notifications |

---

## Uninstallation

### Partial Uninstall

Removes scripts and services but keeps configuration for easy reinstallation:

```bash
sudo nas-mount-setup --uninstall
```

**Removes:** Scripts, systemd services, cache files, shell aliases  
**Keeps:** Credentials, autofs config, mount points, symlink

### Full Uninstall

Removes everything:

```bash
sudo nas-mount-setup --uninstall-full
```

**Does NOT remove packages** (may be used by other programs):
```bash
# To remove packages manually:
sudo pacman -Rs autofs cifs-utils smbclient libnotify
```

---

## File Locations

```
Configuration:
├── /etc/auto.master                    # Autofs master map (modified)
├── /etc/autofs/nas.autofs              # Share definitions
└── /etc/samba/creds-mainstorage        # SMB credentials (mode 600)

Scripts:
├── /usr/local/bin/nas-mount-setup      # Setup/uninstall script
├── /usr/local/bin/nas-share-monitor    # Mismatch detection
└── /usr/local/bin/nas-share-edit       # Config viewer

User Files:
├── ~/.bashrc or ~/.zshrc               # Shell aliases (modified)
├── ~/.config/systemd/user/
│   ├── nas-share-monitor.service       # Systemd service
│   └── nas-share-monitor.timer         # Runs at login + daily
└── ~/.cache/
    ├── nas-share-monitor.log           # Monitor log
    ├── nas-share-monitor.lock          # Prevents concurrent runs
    └── nas-share-check-notified        # Notification state

Mount Points:
├── /mnt/nas/{SHARE_NAME}               # Autofs-managed (on-demand)
└── ~/Drives/nas -> /mnt/nas            # Convenience symlink
```

---

## Mount Options Reference

| Option | Value | Purpose |
|--------|-------|---------|
| `fstype` | `cifs` | SMB/CIFS filesystem |
| `credentials` | `/etc/samba/creds-mainstorage` | Authentication file |
| `uid` / `gid` | Your UID/GID | Files appear owned by you |
| `soft` | — | Return errors instead of hanging |
| `echo_interval` | `10` | Keepalive probe every 10 seconds |
| `nounix` | — | Disable UNIX extensions (compatibility) |
| `noserverino` | — | Client-generated inodes (compatibility) |
| `file_mode` | `0664` | File permissions (rw-rw-r--) |
| `dir_mode` | `0775` | Directory permissions (rwxrwxr-x) |
| `iocharset` | `utf8` | Filename encoding |

Autofs options:
- `--timeout=300` — Unmount after 5 minutes idle
- `--ghost` — Show empty mount points in directory listings

---

## Security Notes

- Credentials file has mode `600` (root-only readable)
- Password is never logged or echoed
- Scripts contain no secrets (only paths)
- Running as root directly (not via sudo) requires confirmation

---

## Shell Aliases

Added to `~/.bashrc` and/or `~/.zshrc`:

```bash
# >>> nas-mount-setup aliases >>>
alias nas-mount-setup='sudo /usr/local/bin/nas-mount-setup'
alias nas-edit='nas-share-edit'
alias nasedit='nas-share-edit'
alias nas-mon='nas-share-monitor'
alias nasmon='nas-share-monitor'
# <<< nas-mount-setup aliases <<<
```

---

## Systemd Services

### System Service

```bash
systemctl status autofs              # Check status
sudo systemctl restart autofs        # Restart after config changes
journalctl -u autofs -f              # View logs
```

### User Services

```bash
systemctl --user status nas-share-monitor.timer    # Timer status
systemctl --user start nas-share-monitor.service   # Run manually
systemctl --user disable --now nas-share-monitor.timer  # Disable
```

Timer schedule:
- 15 seconds after login
- Daily
- Catches up missed runs if session was active

---

## Manual Uninstall

If the script is unavailable:

```bash
# Stop services
sudo systemctl stop autofs
sudo systemctl disable autofs
systemctl --user disable --now nas-share-monitor.timer
systemctl --user disable nas-share-monitor.service
systemctl --user daemon-reload

# Remove files
sudo rm -f /etc/autofs/nas.autofs
sudo rm -f /etc/samba/creds-mainstorage
sudo rm -f /usr/local/bin/nas-share-{monitor,edit}
sudo rm -f /usr/local/bin/nas-mount-setup
rm -f ~/.config/systemd/user/nas-share-monitor.{service,timer}
rm -f ~/.cache/nas-share-{check-notified,monitor.log,monitor.lock}

# Edit /etc/auto.master and remove the /mnt/nas line
sudo nano /etc/auto.master

# Remove mount point and symlink
sudo umount -l /mnt/nas/* 2>/dev/null
sudo rmdir /mnt/nas
rm -f ~/Drives/nas
rmdir ~/Drives 2>/dev/null

# Edit ~/.bashrc and/or ~/.zshrc to remove alias block
```

---

## Version History

### 1.1.1
- Fixed: `local` keyword used outside function in symlink creation (shellcheck SC2168)
- Changed configuration to use placeholders (`{NAS_IP}`, `{NAS_USER}`, `{SHARE1}`, etc.)
