#!/usr/bin/env bash
set -euo pipefail

# --- config ---
ZERO_HOST="${ZERO_HOST:-192.168.1.66}"   # IP/hostname de la Pi Zero
ZERO_PORT="${ZERO_PORT:-5000}"           # port ser2net
LINK_PATH="${LINK_PATH:-/tmp/ttySKR0}"   # PTY local (simple pour test)
LOG_PATH="${LOG_PATH:-/tmp/klipper-bridge.log}"

# --- sanity checks ---
command -v socat >/dev/null 2>&1 || { echo "socat introuvable. Installe: sudo apt install socat"; exit 1; }
command -v nc >/dev/null 2>&1 || { echo "nc introuvable. Installe: sudo apt install netcat-openbsd"; exit 1; }

echo "[bridge] Target: ${ZERO_HOST}:${ZERO_PORT}" | tee -a "$LOG_PATH"
echo "[bridge] PTY: ${LINK_PATH}" | tee -a "$LOG_PATH"

# Si un ancien PTY/link existe, on le dégage
rm -f "$LINK_PATH"

# Attend que le port TCP soit joignable (évite de lancer socat dans le vide)
for i in {1..30}; do
  if nc -z "$ZERO_HOST" "$ZERO_PORT" >/dev/null 2>&1; then
    echo "[bridge] TCP up" | tee -a "$LOG_PATH"
    break
  fi
  echo "[bridge] waiting TCP... ($i/30)" | tee -a "$LOG_PATH"
  sleep 1
done

# Boucle: (re)lance socat si ça tombe
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
