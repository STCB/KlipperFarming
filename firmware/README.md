# Firmware Config

This folder stores the current Klipper micro‑controller build configuration exported from the working `klipper/.config`.

- Source repo: `Klipper3d/klipper` (repo + commit recorded in `current/metadata.json`).
- Primary config: `current/.config` (use with `make menuconfig` / `make`).

Restore this config into a Klipper checkout:

1) Copy `current/.config` to the checkout root as `.config`.
   - Check out the matching Klipper commit from `current/metadata.json` for maximal reproducibility.
2) Run `make clean && make -j`.
3) Flash the resulting firmware per your board’s method (DFU/USB/UART).
