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
XDG_RUNTIME_DIR=/run/user/$(id -u) systemctl --user status imx500_capture.service
```

Check the timer is active:
```bash
XDG_RUNTIME_DIR=/run/user/$(id -u) systemctl --user list-timers imx500_capture.timer
```

Tail the event log:
```bash
tail -f /var/log/imx500/events.jsonl
```

Follow the systemd journal:
```bash
journalctl _SYSTEMD_USER_UNIT=imx500_capture.service -f
```

### Service Aliases

`systemctl --user` requires `XDG_RUNTIME_DIR` to be set when run via sudo or
from certain shell contexts. Add these aliases to `~/.bashrc` to avoid typing
the full prefix every time:

```bash
echo "alias imx500='XDG_RUNTIME_DIR=/run/user/\$(id -u) systemctl --user'" >> ~/.bashrc
source ~/.bashrc
```

Then use the alias for all service commands:

```bash
imx500 start imx500_capture.service
imx500 stop imx500_capture.service
imx500 restart imx500_capture.service
imx500 status imx500_capture.service
imx500 list-timers imx500_capture.timer
```

### Useful Service Commands

All commands below assume the `imx500` alias is configured. If not, prefix
each `systemctl --user` call with `XDG_RUNTIME_DIR=/run/user/$(id -u)`.

| Action | Command |
|---|---|
| Start service | `imx500 start imx500_capture.service` |
| Stop service | `imx500 stop imx500_capture.service` |
| Restart service | `imx500 restart imx500_capture.service` |
| Service status | `imx500 status imx500_capture.service` |
| Timer status | `imx500 list-timers imx500_capture.timer` |
| Live journal | `journalctl _SYSTEMD_USER_UNIT=imx500_capture.service -f` |
| Event log | `tail -f /var/log/imx500/events.jsonl` |
| Wrapper log | `tail -f /var/log/imx500/wrapper.log` |

### Re-Provisioning

All provisioning scripts are re-runnable and will display a pre-run state
check before making any changes.

| Script | Re-run behavior |
|---|---|
| `imx500pi_provision.sh` | Skips already-applied changes, re-applies missing ones |
| `imx500pi_provision_python.sh` | Skips installed packages and existing venv; use `--reset` to rebuild venv |
| `imx500pi_provision_service.sh` | Stops service, rewrites unit files, restarts; use `--reset` to reconfigure location |
