# Farm Orchestrator (bash)

This folder contains a server-side reconciler that manages a Pi-hosted `ser2net`
bridge and per-printer `prind` instances (`p00`..`p15`) from USB hotplug events.

## Scope

`klipper-farmctl` does the following:
- discovers `/dev/ttyACM*` and `/dev/ttyUSB*` on the Pi
- prefers stable identity via `/dev/serial/by-id/*`, falls back to `/dev/serial/by-path/*`
- keeps sticky identity -> index mapping (`5000 + index`) in `device-index.tsv`
- regenerates and pushes a single `/etc/ser2net.yaml` to the Pi
- removes `/etc/ser2net/ser2net.yaml` to avoid split-config ambiguity
- optionally applies nftables IPv4 allowlist on the Pi
- clones `prind` per index under `/srv/printers/pXX`
- ensures per-project bridge link `/run/klipper-bridges/pXX.tty`
- patches `[mcu].serial` in `config/printer.cfg` when `[mcu]` exists
- reads Moonraker readiness and stops non-ready instances after grace + timeout

## Defaults

- Port range: `5000-5015`
- Poll interval: `30s`
- Not-ready grace: `5 minutes`
- Auto-stop timeout: `1 hour`
- Moonraker host ports for checks: `7200 + index` (localhost only)
- Frontend host ports: `18080 + index` (localhost only)

## Quick Setup

1. Copy script and config:
   - `sudo install -m 0755 farm/klipper-farmctl.sh /usr/local/bin/klipper-farmctl`
   - `sudo mkdir -p /etc/klipper-farm`
   - `sudo cp farm/farm.env.example /etc/klipper-farm/farm.env`
   - `sudo cp farm/allowed_ipv4.example /etc/klipper-farm/allowed_ipv4.txt`
2. Edit `/etc/klipper-farm/farm.env`:
   - set `PI_HOST`, `PI_SSH_KEY`, and paths for your server
3. Edit `/etc/klipper-farm/allowed_ipv4.txt`:
   - add one server IPv4 per line
4. Run one reconcile:
   - `sudo CONFIG_FILE=/etc/klipper-farm/farm.env ALLOWLIST_FILE=/etc/klipper-farm/allowed_ipv4.txt klipper-farmctl reconcile`

## Commands

- One shot: `klipper-farmctl reconcile`
- Continuous loop: `klipper-farmctl loop`
- Show mapping: `klipper-farmctl map-list`
- Prune inactive mappings: `klipper-farmctl map-prune`
- Reset mappings: `klipper-farmctl map-reset`

## Systemd Timer

Install service + timer:

```sh
sudo cp farm/systemd/klipper-farm-reconcile.service /etc/systemd/system/
sudo cp farm/systemd/klipper-farm-reconcile.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now klipper-farm-reconcile.timer
```

Inspect:

```sh
systemctl status klipper-farm-reconcile.timer --no-pager
journalctl -u klipper-farm-reconcile.service --no-pager -n 200
```

## Notes

- If `printer.cfg` has no `[mcu]`, the tool does not inject one. It logs:
  `you should add 'serial: /run/klipper-bridges/pXX.tty' under [mcu]`
- `map-prune` is the manual way to release sticky index assignments. It requires
  successful Pi device discovery and aborts if discovery fails.
- `map-prune` and `map-reset` also stop managed resources for removed mappings
  (bridge process/link, bad-state timer, and running project when Docker is available).
- If all 16 slots are consumed, new identities are rejected until capacity is freed.
- Default startup services are `klipper`, `moonraker`, and `mainsail` together.
