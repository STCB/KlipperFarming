# Raspberry Pi Zero

The Pi Zero is used only as a USB serial bridge host:
- Printer USB serial -> `ser2net` (TCP) -> server.

Primary reference:
- `rasp-zero/README.md`
- `farm/README.md`

Quick checks:
```sh
systemctl status ser2net --no-pager -l
ss -ltnp | grep -E '(:5000\\b|:5015\\b|ser2net)' || true
cat /etc/default/ser2net
```

Expected:
- one canonical config file: `/etc/ser2net.yaml`
- `CONFFILE="/etc/ser2net.yaml"` in `/etc/default/ser2net`
- optional nftables service: `klipper-farm-nftables.service`
