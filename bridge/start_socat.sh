#!/usr/bin/env bash
set -euo pipefail

# --- config ---
ZERO_HOST="${ZERO_HOST:-192.168.1.66}"   # Pi Zero IP/hostname
ZERO_PORT="${ZERO_PORT:-5000}"           # ser2net port
LINK_PATH="${LINK_PATH:-/tmp/ttySKR0}"   # local PTY (simple for testing)
LOG_PATH="${LOG_PATH:-/tmp/klipper-bridge.log}"

# --- sanity checks ---
command -v socat >/dev/null 2>&1 || { echo "socat not found. Install: sudo apt install socat"; exit 1; }
command -v nc >/dev/null 2>&1 || { echo "nc not found. Install: sudo apt install netcat-openbsd"; exit 1; }

echo "[bridge] Target: ${ZERO_HOST}:${ZERO_PORT}" | tee -a "$LOG_PATH"
echo "[bridge] PTY: ${LINK_PATH}" | tee -a "$LOG_PATH"

# If an old PTY/link exists, remove it
rm -f "$LINK_PATH"

# Wait until the TCP port is reachable (avoid launching socat into the void)
for i in {1..30}; do
  if nc -z "$ZERO_HOST" "$ZERO_PORT" >/dev/null 2>&1; then
    echo "[bridge] TCP up" | tee -a "$LOG_PATH"
    break
  fi
  echo "[bridge] waiting TCP... ($i/30)" | tee -a "$LOG_PATH"
  sleep 1
done

# Loop: (re)start socat if it dies
while true; do
  echo "[bridge] starting socat..." | tee -a "$LOG_PATH"
  if socat -d -d \
    PTY,link="$LINK_PATH",raw,echo=0,waitslave,mode=666 \
    "TCP:${ZERO_HOST}:${ZERO_PORT},nodelay" \
    >>"$LOG_PATH" 2>&1; then
    echo "[bridge] socat exited with code 0" | tee -a "$LOG_PATH"
  else
    rc="$?"
    echo "[bridge] socat exited with code ${rc}" | tee -a "$LOG_PATH"
  fi

  echo "[bridge] socat exited. restarting in 1s..." | tee -a "$LOG_PATH"
  rm -f "$LINK_PATH"
  sleep 1
done
