# IMX500 Street Monitor Project
## Git Setup on Raspberry Pi OS Debian Trixie (Headless)

### Update the System
```bash
sudo apt update
sudo apt upgrade -y
sudo reboot
```

### Enable Remote Access
After the reboot, enable RPI Connect so the Pi is reachable without a monitor:
```bash
rpi-connect on
rpi-connect signin
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

### SSH Key Authentication

Generate an SSH key:
```bash
ssh-keygen -t ed25519 -C "your_email@example.com" -f ~/.ssh/id_ed25519_github
```

Display the public key and paste it into your GitHub account's SSH key settings:
```bash
cat ~/.ssh/id_ed25519_github.pub
```

Test the connection:
```bash
ssh -T git@github.com
```

Add an entry to `~/.ssh/config`:
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

### Prevent Permission Change Conflicts

Raspberry Pi OS marks shell scripts as executable with `chmod +x`, which git
tracks as a file change and blocks future pulls. Disable permission tracking
in this repo so that doesn't happen:

```bash
git config core.fileMode false
```

This is a local repo setting — it only affects this clone on the Pi and does
not change anything in GitHub.

### Execute Provisioning Scripts

Run the three provisioning scripts in order. The first script ends with a reboot.

```bash
cd ~/imx500
chmod +x *.sh
sudo ./imx500pi_provision.sh <username>
# --- system reboots ---
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

### Daylight-Only Operation

The capture service runs only between sunrise and sunset. This is handled
automatically using your location's coordinates stored in `config.json`.

#### How it works

During `imx500pi_provision_service.sh`, you are prompted for a US zip code.
The script resolves this offline using the `pgeocode` library (no API key or
internet connection required at runtime) and writes the resolved coordinates
to `~/imx500/config.json`:

```json
{
  "location": {
    "zip": "48838",
    "place": "Greenville, Michigan",
    "latitude": 43.1793,
    "longitude": -85.2497
  },
  "logging": {
    "max_log_files": 30
  }
}
```

A systemd timer starts the service each morning at 03:00. The wrapper script
(`imx500_capture_wrapper.sh`) then:

1. Reads `config.json` to get the lat/long
2. Calls the `astral` Python library to calculate today's sunrise and sunset times
3. Sleeps until sunrise
4. Launches `imx500_capture_log.py` at sunrise
5. Stops the capture script at sunset and exits cleanly

A clean exit tells systemd not to restart the service — it stays stopped until
the 03:00 timer fires the next morning.

#### Typical daily cycle

```
03:00  →  Timer fires → wrapper starts → calculates today's sunrise/sunset
           → sleeps until sunrise (e.g. 6:43 AM)
06:43  →  Wrapper wakes → launches imx500_capture_log.py
           → TimedRotatingFileHandler detects midnight has passed since last
             run, renames yesterday's log (events.jsonl.YYYY-MM-DD), starts
             a fresh events.jsonl for today
20:35  →  Sunset reached → wrapper stops capture script → exits cleanly
           → systemd does NOT restart (clean exit)
03:00  →  Next morning, timer fires again → repeat
```

#### Updating your location

To change the zip code, re-run the service provisioning script with `--reset`:

```bash
sudo ./imx500pi_provision_service.sh --reset
```

This will prompt for a new zip code, resolve new coordinates, rewrite
`config.json`, and restart the service.

#### Controlling log file retention

The number of daily event log files kept in `/var/log/imx500/` is controlled
by `max_log_files` in `config.json`. The default is 30 days. To change it,
edit the value and restart the service:

```json
"logging": {
  "max_log_files": 14
}
```

```bash
imx500 restart imx500_capture.service
```

If `max_log_files` is missing from `config.json`, the capture script defaults
to 30.

#### Checking today's sunrise and sunset

```bash
~/imx500_venv/bin/python3 - <<'PYEOF'
import json
from pathlib import Path
from astral import LocationInfo
from astral.sun import sun
from datetime import datetime
from zoneinfo import ZoneInfo

config = json.loads(Path("~/imx500/config.json").expanduser().read_text())
tz = ZoneInfo("localtime")
loc = LocationInfo(latitude=config["location"]["latitude"],
                   longitude=config["location"]["longitude"])
s = sun(loc.observer, date=datetime.now(tz).date(), tzinfo=tz)
print(f"Sunrise: {s['sunrise'].strftime('%I:%M %p %Z')}")
print(f"Sunset:  {s['sunset'].strftime('%I:%M %p %Z')}")
PYEOF
```

### Re-Provisioning

All provisioning scripts are re-runnable and will display a pre-run state
check before making any changes.

| Script | Re-run behavior |
|---|---|
| `imx500pi_provision.sh` | Skips already-applied changes, re-applies missing ones |
| `imx500pi_provision_python.sh` | Skips installed packages and existing venv; use `--reset` to rebuild venv |
| `imx500pi_provision_service.sh` | Stops service, rewrites unit files, restarts; use `--reset` to reconfigure location |
