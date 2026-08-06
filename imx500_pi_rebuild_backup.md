# imx500 Pi Rebuild — Pre-Flash Backup Checklist

## 1. Create local backup folder

```bash
mkdir -p ./imx500_backup/logs
```

## 2. Application code & config

Most `.py` / `.sh` / `.html` files should already be safe in the `imx500` GitHub repo — confirm `git status` is clean on the Pi first. The one file that is **not** in git (gitignored, contains generated location data) is `config.json`:

```bash
scp -i ~/.ssh/id_ed25519_imx500piz01 {piuser}@{pi_ip_address}:/home/raspi/imx500/config.json ./imx500_backup/
```

If you've hand-edited the provisioning scripts locally and haven't pushed:
- `imx500pi_provision.sh`
- `imx500pi_provision_python.sh`
- `imx500pi_provision_service.sh`

## 3. Logs

`/var/log/imx500/` is likely owned by root or a service user, not `raspi`. If a direct `scp -r` gives a permission error, copy it to a `raspi`-owned location on the Pi first:

```bash
# on the Pi
sudo cp -r /var/log/imx500 /home/raspi/imx500_log_backup
sudo chown -R raspi:raspi /home/raspi/imx500_log_backup
```

Then pull it down:

```bash
# from the laptop
scp -r -i ~/.ssh/id_ed25519_imx500piz01 {piuser}@{pi_ip_address}:/home/raspi/imx500_log_backup/ ./imx500_backup/logs/
```

Covers:
- `events.jsonl` (+ any rotated `.jsonl` siblings)
- `wrapper.log` (+ logrotated copies)

## 4. Systemd user units

Pull anything hand-edited (not committed elsewhere) from:

```
~/.config/systemd/user/
```

on the Pi — covers the capture and server service unit files.

## 5. SSH host key

```bash
scp -i ~/.ssh/id_ed25519_imx500piz01 {piuser}@{pi_ip_address}:~/.ssh/id_ed25519_imx500piz01* ./imx500_backup/
```

Needed again post-flash, or plan to regenerate and re-add the new public key as a GitHub deploy key if one is used.

## Notes

- `scp` needs `-r` for directories — omitting it produces `not a regular file`.
- `scp` needs the destination directory to already exist — omitting `mkdir -p` first produces `Is a directory`.
