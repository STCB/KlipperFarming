# KlipperFarming
Server-managed, multi-printer Klipper stacks bridged by Raspberry Pi Zero.

This repo captures the firmware build config, bridge scripts, Raspberry Pi Zero setup,
and a bash orchestrator for running multiple isolated Klipper stacks from one server.

## Architecture (dense)
- Each printer is flashed with Klipper, offloading computation to the server.
- The Pi Zero exposes printer USB serial links with `ser2net`.
- The server runs one `prind` project per printer index (`p00`..`p15`).
- A small socat bridge on the server turns each TCP stream into a stable local PTY.
- Server reconciliation is automated by `farm/klipper-farmctl.sh`.

## Repo layout
- `firmware/` MCU build config for SKR mini E3 v2.0.
- `bridge/` socat bridge script + service template.
- `rasp-zero/` Raspberry Pi Zero bridge notes and single-port fallback config.
- `farm/` bash reconciler + examples + systemd timer units.
- `case/` 3D printable case for Pi Zero + USB Ethernet dongle.
- `docs/` architecture/server/Pi notes.

## Quick start (farm mode)
1. Flash the SKR mini e3 v2.0's MCU using `firmware/current/.config` (see `firmware/README.md`).
2. Configure Pi bridge host + SSH access (see `docs/rasp-zero.md`).
3. Install and configure `farm/klipper-farmctl.sh` on the server (see `farm/README.md`).
4. Run one reconcile, then enable the systemd timer.

## Docs
- `docs/architecture.md`
- `docs/server.md`
- `docs/rasp-zero.md`
- `docs/case.md`
- `farm/README.md`

# History

This project was first tried, and R&Ded with a single-board [Ethernet to Serial converter](https://aliexpress.com/item/4001175906764.html).

The supposed benefit was easiness of deployment: changing the Klipper's firmware communication port to an available UART one, then the converter itself would expose it over LAN with a hardware "**ser2net**" equivalent.
But problems arose: the Aliexpress converter has an inner latency of 150ms per way (in & out), so 300ms total per round-trip, and the SKR Mini e3 v2.0, flashed with Klipper set on "USART 2" port appears to simply not use its serial port for Klippy communication.
