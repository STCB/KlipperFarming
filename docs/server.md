# Server

This host is the source of truth for:
- USB identity -> index mapping (`p00..p15`)
- generated Pi `/etc/ser2net.yaml`
- per-index `prind` projects in `/srv/printers/pXX`
- bridge PTY links in `/run/klipper-bridges/pXX.tty`

## Recommended flow

1. Install prerequisites:
   - Docker Engine + Docker Compose v2
   - `git`, `curl`, `socat`, `netcat-openbsd`
2. Install orchestrator:
   - `sudo install -m 0755 farm/klipper-farmctl.sh /usr/local/bin/klipper-farmctl`
3. Configure:
   - `sudo mkdir -p /etc/klipper-farm`
   - `sudo cp farm/farm.env.example /etc/klipper-farm/farm.env`
   - `sudo cp farm/allowed_ipv4.example /etc/klipper-farm/allowed_ipv4.txt`
4. Edit `farm.env` and set:
   - Pi SSH host/key
   - `PRINTER_ROOT`, `PORT_BASE`, `PORT_COUNT`
   - `BRIDGE_SCRIPT` path
5. Run reconcile once:
   - `sudo CONFIG_FILE=/etc/klipper-farm/farm.env ALLOWLIST_FILE=/etc/klipper-farm/allowed_ipv4.txt klipper-farmctl reconcile`
6. Enable timer:
   - `sudo cp farm/systemd/klipper-farm-reconcile.service /etc/systemd/system/`
   - `sudo cp farm/systemd/klipper-farm-reconcile.timer /etc/systemd/system/`
   - `sudo systemctl daemon-reload`
   - `sudo systemctl enable --now klipper-farm-reconcile.timer`

## Lifecycle policy

- Poll interval: every 30 seconds.
- Active USB identities are mapped to sticky indexes.
- Rejected identities: when all indexes (`PORT_COUNT`) are consumed.
- Readiness source: Moonraker `/printer/info` on localhost mapped ports.
- Frontend exposure: Mainsail on localhost mapped ports (`FRONTEND_PORT_BASE + index`).
- Auto-stop: project stops after `BAD_GRACE_SEC + AUTO_STOP_SEC` in not-ready state.
- Auto-start: if identity returns, project and bridge are started automatically.

## Mapping operations

- List map: `klipper-farmctl map-list`
- Prune disconnected identities: `klipper-farmctl map-prune`
- Reset map: `klipper-farmctl map-reset`

## PTY requirement

Klipper inside Docker must see host PTYs and stable bridge link path. The reconciler writes:

```yaml
services:
  klipper:
    volumes:
      - "/dev/pts:/dev/pts"
      - "/run/klipper-bridges:/run/klipper-bridges"
```
