#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

CONFIG_FILE="${CONFIG_FILE:-/etc/klipper-farm/farm.env}"
ALLOWLIST_FILE="${ALLOWLIST_FILE:-/etc/klipper-farm/allowed_ipv4.txt}"

declare -a SSH_BASE=()
declare -a SCP_BASE=()
declare -a ACTIVE_IDENTITIES=()
declare -a REJECTED_IDENTITIES=()
declare -a ALLOWLIST_IPS=()
declare -A ID_TO_INDEX=()
declare -A INDEX_TO_ID=()
declare -A ACTIVE_CONNECTOR=()
declare -A ACTIVE_KERNEL_NODE=()
DISCOVERY_OK=1

usage() {
  cat <<'EOF'
Usage:
  klipper-farmctl reconcile
  klipper-farmctl loop
  klipper-farmctl map-list
  klipper-farmctl map-prune
  klipper-farmctl map-reset

Environment:
  CONFIG_FILE     Path to farm env file (default: /etc/klipper-farm/farm.env)
  ALLOWLIST_FILE  Path to IPv4 allowlist file (default: /etc/klipper-farm/allowed_ipv4.txt)
EOF
}

log() {
  printf '[farmctl] %s\n' "$*"
}

warn() {
  printf '[farmctl] WARN: %s\n' "$*" >&2
}

die() {
  printf '[farmctl] ERROR: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  local command_name
  for command_name in "$@"; do
    command -v "${command_name}" >/dev/null 2>&1 || die "Missing required command: ${command_name}"
  done
}

load_config() {
  if [[ -f "${CONFIG_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${CONFIG_FILE}"
  fi

  PI_HOST="${PI_HOST:-piusb@192.168.1.66}"
  PI_SSH_PORT="${PI_SSH_PORT:-22}"
  PI_SSH_KEY="${PI_SSH_KEY:-}"
  PI_SSH_EXTRA_OPTS="${PI_SSH_EXTRA_OPTS:-}"
  PI_BRIDGE_HOST="${PI_BRIDGE_HOST:-${PI_HOST##*@}}"

  PRIND_UPSTREAM="${PRIND_UPSTREAM:-https://github.com/mkuf/prind.git}"
  PRINTER_ROOT="${PRINTER_ROOT:-/srv/printers}"
  PROJECT_PREFIX="${PROJECT_PREFIX:-p}"
  PORT_BASE="${PORT_BASE:-5000}"
  PORT_COUNT="${PORT_COUNT:-16}"
  MOONRAKER_PORT_BASE="${MOONRAKER_PORT_BASE:-7200}"
  FRONTEND_PROFILE="${FRONTEND_PROFILE:-mainsail}"
  FRONTEND_SERVICE="${FRONTEND_SERVICE:-mainsail}"
  FRONTEND_PORT_BASE="${FRONTEND_PORT_BASE:-18080}"
  PROJECT_SERVICES="${PROJECT_SERVICES:-klipper moonraker ${FRONTEND_SERVICE}}"
  SER2NET_BAUD="${SER2NET_BAUD:-250000}"

  BRIDGE_SCRIPT="${BRIDGE_SCRIPT:-${REPO_ROOT}/bridge/start_socat.sh}"
  BRIDGE_DIR="${BRIDGE_DIR:-/run/klipper-bridges}"
  POLL_INTERVAL_SEC="${POLL_INTERVAL_SEC:-30}"
  BAD_GRACE_SEC="${BAD_GRACE_SEC:-300}"
  AUTO_STOP_SEC="${AUTO_STOP_SEC:-3600}"

  STATE_DIR="${STATE_DIR:-/var/lib/klipper-farm}"
  MAP_FILE="${MAP_FILE:-${STATE_DIR}/device-index.tsv}"
  BRIDGE_PID_DIR="${BRIDGE_PID_DIR:-${STATE_DIR}/bridge-pids}"
  HEALTH_DIR="${HEALTH_DIR:-${STATE_DIR}/health}"
  LOG_DIR="${LOG_DIR:-${STATE_DIR}/logs}"
  APPLY_FIREWALL="${APPLY_FIREWALL:-1}"

  [[ "${PORT_BASE}" =~ ^[0-9]+$ ]] || die "PORT_BASE must be numeric"
  [[ "${PORT_COUNT}" =~ ^[0-9]+$ ]] || die "PORT_COUNT must be numeric"
  [[ "${MOONRAKER_PORT_BASE}" =~ ^[0-9]+$ ]] || die "MOONRAKER_PORT_BASE must be numeric"
  [[ "${FRONTEND_PORT_BASE}" =~ ^[0-9]+$ ]] || die "FRONTEND_PORT_BASE must be numeric"
  [[ "${SER2NET_BAUD}" =~ ^[0-9]+$ ]] || die "SER2NET_BAUD must be numeric"
  [[ "${POLL_INTERVAL_SEC}" =~ ^[0-9]+$ ]] || die "POLL_INTERVAL_SEC must be numeric"
  [[ "${BAD_GRACE_SEC}" =~ ^[0-9]+$ ]] || die "BAD_GRACE_SEC must be numeric"
  [[ "${AUTO_STOP_SEC}" =~ ^[0-9]+$ ]] || die "AUTO_STOP_SEC must be numeric"
  (( PORT_COUNT > 0 )) || die "PORT_COUNT must be > 0"

  mkdir -p "${STATE_DIR}" "${BRIDGE_PID_DIR}" "${HEALTH_DIR}" "${LOG_DIR}" "${BRIDGE_DIR}"
  mkdir -p "${PRINTER_ROOT}"

  [[ -x "${BRIDGE_SCRIPT}" ]] || die "Bridge script is not executable: ${BRIDGE_SCRIPT}"

  SSH_BASE=(ssh -o BatchMode=yes -o ConnectTimeout=8 -p "${PI_SSH_PORT}")
  SCP_BASE=(scp -o BatchMode=yes -o ConnectTimeout=8 -P "${PI_SSH_PORT}")
  if [[ -n "${PI_SSH_KEY}" ]]; then
    SSH_BASE+=(-i "${PI_SSH_KEY}")
    SCP_BASE+=(-i "${PI_SSH_KEY}")
  fi
  if [[ -n "${PI_SSH_EXTRA_OPTS}" ]]; then
    local extra_opts=()
    read -r -a extra_opts <<<"${PI_SSH_EXTRA_OPTS}"
    SSH_BASE+=("${extra_opts[@]}")
    SCP_BASE+=("${extra_opts[@]}")
  fi
  SSH_BASE+=("${PI_HOST}")
}

ssh_pi() {
  "${SSH_BASE[@]}" "$@"
}

scp_to_pi() {
  local source_path="$1"
  local destination_path="$2"
  "${SCP_BASE[@]}" "${source_path}" "${destination_path}"
}

project_name_for_index() {
  local index="$1"
  printf '%s%02d' "${PROJECT_PREFIX}" "${index}"
}

project_dir_for_index() {
  local index="$1"
  printf '%s/%s\n' "${PRINTER_ROOT}" "$(project_name_for_index "${index}")"
}

bridge_link_for_project() {
  local project_name="$1"
  printf '%s/%s.tty\n' "${BRIDGE_DIR}" "${project_name}"
}

moonraker_port_for_index() {
  local index="$1"
  printf '%s\n' "$((MOONRAKER_PORT_BASE + index))"
}

frontend_port_for_index() {
  local index="$1"
  printf '%s\n' "$((FRONTEND_PORT_BASE + index))"
}

bad_since_file_for_project() {
  local project_name="$1"
  printf '%s/%s.bad_since\n' "${HEALTH_DIR}" "${project_name}"
}

bridge_pid_file_for_project() {
  local project_name="$1"
  printf '%s/%s.pid\n' "${BRIDGE_PID_DIR}" "${project_name}"
}

load_map() {
  ID_TO_INDEX=()
  INDEX_TO_ID=()
  [[ -f "${MAP_FILE}" ]] || return 0

  local identity index
  while IFS=$'\t' read -r identity index; do
    [[ -n "${identity}" ]] || continue
    [[ "${index}" =~ ^[0-9]+$ ]] || continue
    ID_TO_INDEX["${identity}"]="${index}"
    INDEX_TO_ID["${index}"]="${identity}"
  done < "${MAP_FILE}"
}

save_map() {
  local temp_file
  temp_file="$(mktemp)"
  if ((${#ID_TO_INDEX[@]})); then
    local identity
    for identity in "${!ID_TO_INDEX[@]}"; do
      printf '%s\t%s\n' "${identity}" "${ID_TO_INDEX[${identity}]}"
    done | sort -t$'\t' -k2,2n -k1,1 > "${temp_file}"
  fi
  mv "${temp_file}" "${MAP_FILE}"
}

discover_pi_devices() {
  ssh_pi bash <<'EOF'
set -euo pipefail
shopt -s nullglob

declare -A by_id=()
declare -A by_path=()

for device_link in /dev/serial/by-id/*; do
  target_path="$(readlink -f "${device_link}" 2>/dev/null || true)"
  [[ -n "${target_path}" ]] || continue
  device_name="$(basename "${target_path}")"
  [[ "${device_name}" =~ ^tty(ACM|USB)[0-9]+$ ]] || continue
  by_id["${device_name}"]="${device_link}"
done

for device_link in /dev/serial/by-path/*; do
  target_path="$(readlink -f "${device_link}" 2>/dev/null || true)"
  [[ -n "${target_path}" ]] || continue
  device_name="$(basename "${target_path}")"
  [[ "${device_name}" =~ ^tty(ACM|USB)[0-9]+$ ]] || continue
  by_path["${device_name}"]="${device_link}"
done

declare -A emitted=()
for kernel_node in /dev/ttyACM* /dev/ttyUSB*; do
  [[ -e "${kernel_node}" ]] || continue
  kernel_name="$(basename "${kernel_node}")"

  if [[ -n "${by_id[${kernel_name}]:-}" ]]; then
    identity="by-id:$(basename "${by_id[${kernel_name}]}")"
    connector="${by_id[${kernel_name}]}"
  elif [[ -n "${by_path[${kernel_name}]:-}" ]]; then
    identity="by-path:$(basename "${by_path[${kernel_name}]}")"
    connector="${by_path[${kernel_name}]}"
  else
    identity="tty:${kernel_name}"
    connector="${kernel_node}"
  fi

  [[ -n "${emitted[${identity}]:-}" ]] && continue
  emitted["${identity}"]=1
  printf '%s\t%s\t%s\n' "${identity}" "${connector}" "${kernel_node}"
done | sort -t $'\t' -k1,1
EOF
}

refresh_active_devices() {
  ACTIVE_IDENTITIES=()
  ACTIVE_CONNECTOR=()
  ACTIVE_KERNEL_NODE=()
  DISCOVERY_OK=0

  local discovery_output
  if ! discovery_output="$(discover_pi_devices)"; then
    warn "Pi device discovery failed"
    return 1
  fi
  DISCOVERY_OK=1

  local identity connector kernel_node
  while IFS=$'\t' read -r identity connector kernel_node; do
    [[ -n "${identity}" ]] || continue
    ACTIVE_IDENTITIES+=("${identity}")
    ACTIVE_CONNECTOR["${identity}"]="${connector}"
    ACTIVE_KERNEL_NODE["${identity}"]="${kernel_node}"
  done <<<"${discovery_output}"
}

find_free_index() {
  local index
  for ((index = 0; index < PORT_COUNT; index++)); do
    [[ -z "${INDEX_TO_ID[${index}]:-}" ]] || continue
    printf '%s\n' "${index}"
    return 0
  done
  return 1
}

assign_active_identities() {
  REJECTED_IDENTITIES=()
  local identity next_index
  for identity in "${ACTIVE_IDENTITIES[@]}"; do
    [[ -n "${ID_TO_INDEX[${identity}]:-}" ]] && continue
    if next_index="$(find_free_index)"; then
      ID_TO_INDEX["${identity}"]="${next_index}"
      INDEX_TO_ID["${next_index}"]="${identity}"
      log "Assigned ${identity} -> index ${next_index} (port $((PORT_BASE + next_index)))"
    else
      REJECTED_IDENTITIES+=("${identity}")
      warn "Rejected ${identity}: no free slots in ${PORT_BASE}-$((PORT_BASE + PORT_COUNT - 1))"
    fi
  done
}

active_assigned_lines() {
  local identity index
  for identity in "${ACTIVE_IDENTITIES[@]}"; do
    index="${ID_TO_INDEX[${identity}]:-}"
    [[ -n "${index}" ]] || continue
    printf '%s\t%s\n' "${index}" "${identity}"
  done | sort -t$'\t' -k1,1n
}

generate_ser2net_file() {
  local output_file="$1"
  {
    echo "%YAML 1.1"
    echo "---"
    echo "# Managed by klipper-farmctl. Manual edits will be overwritten."

    local index identity connector port
    while IFS=$'\t' read -r index identity; do
      connector="${ACTIVE_CONNECTOR[${identity}]}"
      port="$((PORT_BASE + index))"
      echo
      printf 'connection: &p%02d\n' "${index}"
      printf '  accepter: tcp,%s\n' "${port}"
      echo "  timeout: 0"
      echo "  enable: on"
      printf '  connector: serialdev,%s,%sn81,local\n' "${connector}" "${SER2NET_BAUD}"
      echo "  options:"
      echo "    kickolduser: true"
      echo "    max-connections: 1"
    done < <(active_assigned_lines)
  } > "${output_file}"
}

push_ser2net_to_pi() {
  local source_file="$1"
  local remote_tmp="/tmp/klipper-farm-ser2net.yaml"
  local local_sum
  local_sum="$(sha256sum "${source_file}" | awk '{print $1}')"

  scp_to_pi "${source_file}" "${PI_HOST}:${remote_tmp}"

  ssh_pi "LOCAL_SUM='${local_sum}' REMOTE_TMP='${remote_tmp}' bash -s" <<'EOF'
set -euo pipefail

current_sum="$(sha256sum /etc/ser2net.yaml 2>/dev/null | awk '{print $1}' || true)"
if [[ "${LOCAL_SUM}" != "${current_sum}" ]]; then
  sudo install -m 0644 "${REMOTE_TMP}" /etc/ser2net.yaml
  sudo rm -f /etc/ser2net/ser2net.yaml
  if grep -q '^CONFFILE="/etc/ser2net.yaml"$' /etc/default/ser2net; then
    :
  elif grep -q '^CONFFILE=' /etc/default/ser2net; then
    sudo sed -i 's|^CONFFILE=.*|CONFFILE="/etc/ser2net.yaml"|' /etc/default/ser2net
  else
    printf '\nCONFFILE="/etc/ser2net.yaml"\n' | sudo tee -a /etc/default/ser2net >/dev/null
  fi
  sudo systemctl reload ser2net || sudo systemctl restart ser2net
fi
rm -f "${REMOTE_TMP}"
EOF
}

is_valid_ipv4() {
  local candidate="$1"
  [[ "${candidate}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  local o1 o2 o3 o4
  IFS='.' read -r o1 o2 o3 o4 <<<"${candidate}"
  ((o1 >= 0 && o1 <= 255)) || return 1
  ((o2 >= 0 && o2 <= 255)) || return 1
  ((o3 >= 0 && o3 <= 255)) || return 1
  ((o4 >= 0 && o4 <= 255)) || return 1
  return 0
}

load_allowlist() {
  ALLOWLIST_IPS=()
  [[ -f "${ALLOWLIST_FILE}" ]] || return 0

  local line ip
  while IFS= read -r line; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -n "${line}" ]] || continue
    ip="${line}"
    if is_valid_ipv4 "${ip}"; then
      ALLOWLIST_IPS+=("${ip}")
    else
      warn "Ignoring invalid IPv4 in allowlist: ${ip}"
    fi
  done < "${ALLOWLIST_FILE}"
}

generate_nftables_file() {
  local output_file="$1"
  local from_port to_port
  from_port="${PORT_BASE}"
  to_port="$((PORT_BASE + PORT_COUNT - 1))"

  {
    echo "table inet klipper_farm {"
    echo "  set allowed_servers {"
    echo "    type ipv4_addr"
    if ((${#ALLOWLIST_IPS[@]})); then
      printf '    elements = { '
      local first=1 ip
      for ip in "${ALLOWLIST_IPS[@]}"; do
        if ((first)); then
          first=0
        else
          printf ', '
        fi
        printf '%s' "${ip}"
      done
      echo " }"
    else
      echo "    elements = { 127.0.0.1 }"
    fi
    echo "  }"
    echo
    echo "  chain input {"
    echo "    type filter hook input priority 0; policy accept;"
    printf '    tcp dport %s-%s ip saddr @allowed_servers accept\n' "${from_port}" "${to_port}"
    printf '    tcp dport %s-%s drop\n' "${from_port}" "${to_port}"
    echo "  }"
    echo "}"
  } > "${output_file}"
}

push_nftables_to_pi() {
  local nft_file="$1"
  local remote_tmp="/tmp/klipper-farm.nft"

  scp_to_pi "${nft_file}" "${PI_HOST}:${remote_tmp}"
  ssh_pi "REMOTE_TMP='${remote_tmp}' bash -s" <<'EOF'
set -euo pipefail

if ! command -v nft >/dev/null 2>&1; then
  echo "nft command not found on Pi" >&2
  exit 1
fi

sudo mkdir -p /etc/klipper-farm
sudo install -m 0644 "${REMOTE_TMP}" /etc/klipper-farm/nftables-klipper-farm.nft
rm -f "${REMOTE_TMP}"

sudo tee /etc/systemd/system/klipper-farm-nftables.service >/dev/null <<'UNIT'
[Unit]
Description=Klipper Farm nftables allowlist
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/nft -f /etc/klipper-farm/nftables-klipper-farm.nft
ExecReload=/usr/sbin/nft -f /etc/klipper-farm/nftables-klipper-farm.nft
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT

sudo systemctl daemon-reload
sudo systemctl enable --now klipper-farm-nftables.service
sudo systemctl reload klipper-farm-nftables.service || sudo systemctl restart klipper-farm-nftables.service
EOF
}

apply_firewall_if_enabled() {
  [[ "${APPLY_FIREWALL}" == "1" ]] || return 0
  load_allowlist
  if ((${#ALLOWLIST_IPS[@]} == 0)); then
    warn "ALLOWLIST_FILE has no valid IPv4 entries. Skipping firewall update."
    return 0
  fi
  local nft_file
  nft_file="$(mktemp)"
  generate_nftables_file "${nft_file}"
  push_nftables_to_pi "${nft_file}"
  rm -f "${nft_file}"
}

ensure_prind_project() {
  local index="$1"
  local project_dir
  project_dir="$(project_dir_for_index "${index}")"
  [[ -d "${project_dir}" ]] && return 0
  log "Cloning prind for $(project_name_for_index "${index}")"
  git clone --depth 1 "${PRIND_UPSTREAM}" "${project_dir}" >/dev/null
}

write_project_override() {
  local index="$1"
  local project_dir moonraker_port frontend_port
  project_dir="$(project_dir_for_index "${index}")"
  moonraker_port="$(moonraker_port_for_index "${index}")"
  frontend_port="$(frontend_port_for_index "${index}")"

  cat > "${project_dir}/docker-compose.override.yaml" <<EOF
services:
  klipper:
    volumes:
      - "/dev/pts:/dev/pts"
      - "${BRIDGE_DIR}:${BRIDGE_DIR}"
  moonraker:
    ports:
      - "127.0.0.1:${moonraker_port}:7125"
  ${FRONTEND_SERVICE}:
    ports:
      - "127.0.0.1:${frontend_port}:80"
EOF
}

set_mcu_serial() {
  local printer_cfg="$1"
  local serial_path="$2"
  [[ -f "${printer_cfg}" ]] || return 1

  local tmp_file
  tmp_file="$(mktemp)"

  if awk -v serial_line="serial: ${serial_path}" '
BEGIN {
  in_mcu = 0
  found_mcu = 0
  serial_written = 0
}
/^\[mcu\][[:space:]]*$/ {
  in_mcu = 1
  found_mcu = 1
  print
  next
}
/^\[/ {
  if (in_mcu && !serial_written) {
    print serial_line
    serial_written = 1
  }
  in_mcu = 0
}
{
  if (in_mcu && $0 ~ /^[[:space:]]*serial:[[:space:]]*/) {
    if (!serial_written) {
      print serial_line
      serial_written = 1
    }
    next
  }
  print
}
END {
  if (in_mcu && !serial_written) {
    print serial_line
  }
  if (!found_mcu) {
    exit 42
  }
}
' "${printer_cfg}" > "${tmp_file}"; then
    :
  else
    local exit_code="$?"
    rm -f "${tmp_file}"
    if [[ "${exit_code}" == "42" ]]; then
      warn "${printer_cfg} has no [mcu]; you should add 'serial: ${serial_path}' under [mcu]"
      return 1
    fi
    return "${exit_code}"
  fi

  if ! cmp -s "${printer_cfg}" "${tmp_file}"; then
    mv "${tmp_file}" "${printer_cfg}"
  else
    rm -f "${tmp_file}"
  fi
}

project_running() {
  local index="$1"
  local project_name project_dir
  project_name="$(project_name_for_index "${index}")"
  project_dir="$(project_dir_for_index "${index}")"
  [[ -d "${project_dir}" ]] || return 1

  local container_id
  container_id="$(docker compose --project-name "${project_name}" --project-directory "${project_dir}" ps --status running -q moonraker 2>/dev/null || true)"
  [[ -n "${container_id}" ]]
}

start_project() {
  local index="$1"
  local project_name project_dir
  local -a services
  project_name="$(project_name_for_index "${index}")"
  project_dir="$(project_dir_for_index "${index}")"
  read -r -a services <<<"${PROJECT_SERVICES}"
  docker compose --project-name "${project_name}" --project-directory "${project_dir}" --profile "${FRONTEND_PROFILE}" up -d "${services[@]}" >/dev/null
}

stop_project() {
  local index="$1"
  local project_name project_dir
  local -a services
  project_name="$(project_name_for_index "${index}")"
  project_dir="$(project_dir_for_index "${index}")"
  read -r -a services <<<"${PROJECT_SERVICES}"
  docker compose --project-name "${project_name}" --project-directory "${project_dir}" stop "${services[@]}" >/dev/null || true
}

start_bridge() {
  local index="$1"
  local project_name port pid_file log_file link_path bridge_pid
  project_name="$(project_name_for_index "${index}")"
  port="$((PORT_BASE + index))"
  pid_file="$(bridge_pid_file_for_project "${project_name}")"
  log_file="${LOG_DIR}/${project_name}.bridge.log"
  link_path="$(bridge_link_for_project "${project_name}")"

  if [[ -f "${pid_file}" ]]; then
    local existing_pid
    existing_pid="$(cat "${pid_file}")"
    if [[ -n "${existing_pid}" ]] && kill -0 "${existing_pid}" >/dev/null 2>&1; then
      return 0
    fi
    rm -f "${pid_file}"
  fi

  nohup env \
    ZERO_HOST="${PI_BRIDGE_HOST}" \
    ZERO_PORT="${port}" \
    LINK_PATH="${link_path}" \
    LOG_PATH="${log_file}" \
    "${BRIDGE_SCRIPT}" \
    >/dev/null 2>&1 < /dev/null &
  bridge_pid="$!"
  disown "${bridge_pid}" 2>/dev/null || true
  echo "${bridge_pid}" > "${pid_file}"
}

stop_bridge() {
  local index="$1"
  local project_name pid_file link_path
  project_name="$(project_name_for_index "${index}")"
  pid_file="$(bridge_pid_file_for_project "${project_name}")"
  link_path="$(bridge_link_for_project "${project_name}")"

  if [[ -f "${pid_file}" ]]; then
    local pid
    pid="$(cat "${pid_file}")"
    if [[ -n "${pid}" ]] && kill -0 "${pid}" >/dev/null 2>&1; then
      kill "${pid}" >/dev/null 2>&1 || true
    fi
    rm -f "${pid_file}"
  fi
  rm -f "${link_path}"
}

moonraker_state() {
  local index="$1"
  local moonraker_port response
  moonraker_port="$(moonraker_port_for_index "${index}")"
  response="$(curl -fsS --max-time 2 "http://127.0.0.1:${moonraker_port}/printer/info" 2>/dev/null || true)"
  [[ -n "${response}" ]] || {
    printf 'unreachable\n'
    return 0
  }
  if grep -Eq '"state"[[:space:]]*:[[:space:]]*"ready"' <<<"${response}"; then
    printf 'ready\n'
  else
    printf 'not_ready\n'
  fi
}

clear_bad_timer() {
  local project_name="$1"
  rm -f "$(bad_since_file_for_project "${project_name}")"
}

update_bad_timer_and_maybe_stop() {
  local index="$1"
  local project_name now bad_file since elapsed total_limit
  project_name="$(project_name_for_index "${index}")"
  bad_file="$(bad_since_file_for_project "${project_name}")"
  now="$(date +%s)"
  total_limit="$((BAD_GRACE_SEC + AUTO_STOP_SEC))"

  if [[ ! -f "${bad_file}" ]]; then
    printf '%s\n' "${now}" > "${bad_file}"
    return 0
  fi

  since="$(cat "${bad_file}")"
  [[ "${since}" =~ ^[0-9]+$ ]] || since="${now}"
  elapsed="$((now - since))"
  ((elapsed < total_limit)) && return 0

  if project_running "${index}"; then
    log "Stopping $(project_name_for_index "${index}") after ${elapsed}s not-ready interval"
    stop_project "${index}"
  fi
}

retire_index_resources() {
  local index="$1"
  local project_name project_dir
  project_name="$(project_name_for_index "${index}")"
  project_dir="$(project_dir_for_index "${index}")"

  if [[ -d "${project_dir}" ]]; then
    if command -v docker >/dev/null 2>&1; then
      if project_running "${index}"; then
        log "Stopping $(project_name_for_index "${index}") due to mapping removal"
        stop_project "${index}" || warn "Failed stopping $(project_name_for_index "${index}")"
      fi
    else
      warn "docker not found; cannot stop $(project_name_for_index "${index}")"
    fi
  fi

  stop_bridge "${index}"
  clear_bad_timer "${project_name}"
}

reconcile_projects() {
  local index identity project_name project_dir serial_path state started_now
  local sorted_indices=()
  if ((${#INDEX_TO_ID[@]})); then
    mapfile -t sorted_indices < <(printf '%s\n' "${!INDEX_TO_ID[@]}" | sort -n)
  fi

  for index in "${sorted_indices[@]}"; do
    identity="${INDEX_TO_ID[${index}]}"
    project_name="$(project_name_for_index "${index}")"
    project_dir="$(project_dir_for_index "${index}")"
    serial_path="$(bridge_link_for_project "${project_name}")"
    started_now=0

    if [[ -n "${ACTIVE_CONNECTOR[${identity}]:-}" ]]; then
      ensure_prind_project "${index}"
      write_project_override "${index}"
      set_mcu_serial "${project_dir}/config/printer.cfg" "${serial_path}" || true
      start_bridge "${index}"
      if ! project_running "${index}"; then
        start_project "${index}"
        started_now=1
      fi
    else
      stop_bridge "${index}"
    fi

    if ((started_now)); then
      clear_bad_timer "${project_name}"
      continue
    fi

    if ! project_running "${index}"; then
      clear_bad_timer "${project_name}"
      continue
    fi

    state="$(moonraker_state "${index}")"
    if [[ "${state}" == "ready" ]]; then
      clear_bad_timer "${project_name}"
    else
      update_bad_timer_and_maybe_stop "${index}"
    fi
  done
}

map_list() {
  load_map
  if ! refresh_active_devices; then
    warn "Pi discovery unavailable; STATUS set to unknown"
  fi
  printf 'INDEX\tPORT\tSTATUS\tIDENTITY\tCONNECTOR\n'
  if ((${#INDEX_TO_ID[@]} == 0)); then
    return 0
  fi
  local index identity status connector
  while IFS= read -r index; do
    identity="${INDEX_TO_ID[${index}]}"
    if [[ "${DISCOVERY_OK}" != "1" ]]; then
      status="unknown"
      connector="?"
    elif [[ -n "${ACTIVE_CONNECTOR[${identity}]:-}" ]]; then
      status="active"
      connector="${ACTIVE_CONNECTOR[${identity}]}"
    else
      status="inactive"
      connector="-"
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "${index}" "$((PORT_BASE + index))" "${status}" "${identity}" "${connector}"
  done < <(printf '%s\n' "${!INDEX_TO_ID[@]}" | sort -n)
}

map_prune() {
  load_map
  refresh_active_devices || die "Cannot prune mappings: Pi discovery failed"
  local -A active_lookup=()
  local identity
  for identity in "${ACTIVE_IDENTITIES[@]}"; do
    active_lookup["${identity}"]=1
  done

  local removed=0
  local -a removed_indices=()
  for identity in "${!ID_TO_INDEX[@]}"; do
    [[ -n "${active_lookup[${identity}]:-}" ]] && continue
    removed_indices+=("${ID_TO_INDEX[${identity}]}")
    unset "INDEX_TO_ID[${ID_TO_INDEX[${identity}]}]"
    unset "ID_TO_INDEX[${identity}]"
    ((removed += 1))
  done

  local index
  for index in "${removed_indices[@]}"; do
    retire_index_resources "${index}"
  done

  save_map
  log "Pruned ${removed} inactive mapping entries"
}

map_reset() {
  load_map
  local -a mapped_indices=()
  if ((${#INDEX_TO_ID[@]})); then
    mapfile -t mapped_indices < <(printf '%s\n' "${!INDEX_TO_ID[@]}" | sort -n)
  fi

  local index
  for index in "${mapped_indices[@]}"; do
    retire_index_resources "${index}"
  done

  ID_TO_INDEX=()
  INDEX_TO_ID=()
  save_map
  log "Cleared all identity mappings"
}

reconcile_once() {
  require_cmd ssh scp git docker curl awk sed grep sort sha256sum mktemp
  load_map
  refresh_active_devices || die "Pi device discovery failed"
  assign_active_identities
  save_map

  local ser2net_file
  ser2net_file="$(mktemp)"
  generate_ser2net_file "${ser2net_file}"
  push_ser2net_to_pi "${ser2net_file}"
  rm -f "${ser2net_file}"

  apply_firewall_if_enabled
  reconcile_projects

  if ((${#REJECTED_IDENTITIES[@]})); then
    warn "Rejected devices due to full port range:"
    local identity
    for identity in "${REJECTED_IDENTITIES[@]}"; do
      warn "  ${identity}"
    done
  fi
}

loop_forever() {
  while true; do
    if ! reconcile_once; then
      warn "Reconcile run failed"
    fi
    sleep "${POLL_INTERVAL_SEC}"
  done
}

main() {
  local command="${1:-}"
  case "${command}" in
    reconcile)
      load_config
      reconcile_once
      ;;
    loop)
      load_config
      loop_forever
      ;;
    map-list)
      load_config
      map_list
      ;;
    map-prune)
      load_config
      map_prune
      ;;
    map-reset)
      load_config
      map_reset
      ;;
    ""|-h|--help|help)
      usage
      ;;
    *)
      usage
      die "Unknown command: ${command}"
      ;;
  esac
}

main "$@"
