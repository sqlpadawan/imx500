# IMX500 Street Monitor Project
## Git Setup on Raspberry Pi OS Debian Trixie (Headless)

### Update the System
```bash
sudo apt update
sudo apt upgrade -y
sudo reboot
```

### Install Git
```bash
sudo apt install git -y
git --version
```

### Configure Git Identity
```bash
git config --global user.name "Your Name"
git config --global user.email "your_email@example.com"
git config --global --list
```

### Authentication Options

#### Option A: HTTPS + Personal Access Token
Create a PAT on your Git hosting service, then clone using HTTPS:
```bash
git clone https://github.com/USERNAME/imx500.git
```
Cache credentials:
```bash
git config --global credential.helper store
```

#### Option B: SSH Keys (Recommended)

Generate SSH Key:
```bash
ssh-keygen -t ed25519 -C "your_email@example.com" -f ~/.ssh/id_ed25519_github
```
Display Public Key:
```bash
cat ~/.ssh/id_ed25519_github.pub
```
Paste the public key into your account's SSH key settings, then test:
```bash
ssh -T git@github.com
```
Configure `~/.ssh/config`:
```
Host github.com
    HostName github.com
    User git
    IdentityFile ~/.ssh/id_ed25519_github
```

### Clone the Repository
```bash
cd ~
git clone git@github.com:USERNAME/imx500.git
```

### Execute Provisioning Scripts
```bash
cd ~/imx500
chmod +x *.sh
sudo ./imx500pi_provision.sh <username>
```
*(system reboots)*
```bash
rpi-connect on
rpi-connect signin
sudo ./imx500pi_provision_python.sh
sudo ./imx500pi_provision_service.sh
```

### Verify the Installation

Check the service is running:
```bash
systemctl --user status imx500_capture.service
```

Check the timer is active:
```bash
systemctl --user list-timers imx500_capture.timer
```

Tail the event log:
```bash
tail -f /var/log/imx500/events.jsonl
```

Follow the systemd journal:
```bash
journalctl --user -u imx500_capture -f
```

### Useful Service Commands

| Action | Command |
|---|---|
| Start service | `systemctl --user start imx500_capture.service` |
| Stop service | `systemctl --user stop imx500_capture.service` |
| Restart service | `systemctl --user restart imx500_capture.service` |
| Service status | `systemctl --user status imx500_capture.service` |
| Timer status | `systemctl --user list-timers imx500_capture.timer` |
| Live journal | `journalctl --user -u imx500_capture -f` |
| Event log | `tail -f /var/log/imx500/events.jsonl` |

### Re-Provisioning

All provisioning scripts are re-runnable and will display a pre-run state
check before making any changes.

| Script | Re-run behavior |
|---|---|
| `imx500pi_provision.sh` | Skips already-applied changes, re-applies missing ones |
| `imx500pi_provision_python.sh` | Skips installed packages and existing venv; use `--reset` to rebuild venv |
| `imx500pi_provision_service.sh` | Stops service, rewrites unit files, restarts; use `--reset` to reconfigure location |
