# Architecture

Goal: scale many printers by keeping Klipper services centralized on a local server,
while one Pi Zero + USB hub acts as a USB-to-TCP bridge host.

Data flow per printer:
- Printer USB -> Pi Zero `ser2net` -> server TCP port (`5000 + index`)
- Server `socat` -> stable PTY link (`/run/klipper-bridges/pXX.tty`) -> Klipper
- Moonraker reads Klipper state and drives lifecycle policy

Key properties:
- Each printer identity gets a sticky index (`p00..p15`) in a local map file.
- Identity preference is `/dev/serial/by-id`, then `/dev/serial/by-path`, then kernel tty fallback.
- A server reconciler (`farm/klipper-farmctl.sh`) regenerates Pi `/etc/ser2net.yaml`.
- `prind` projects are auto-provisioned per index under `/srv/printers/pXX`.
- Instances that stay not-ready are auto-stopped after `BAD_GRACE_SEC + AUTO_STOP_SEC`.
