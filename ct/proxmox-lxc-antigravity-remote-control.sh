#!/usr/bin/env bash
_CS_DEFAULT_URL="${ANTIGRAVITY_REMOTE_CONTROL_REPO_URL:-https://raw.githubusercontent.com/gskbyte/proxmox-lxc-antigravity-remote-control/main}"
_cs_boot="${COMMUNITY_SCRIPTS_CORE_DIR:-$(dirname "${BASH_SOURCE[0]:-}")/../../core}/core/build.func"
source "$_cs_boot" 2>/dev/null || source <(curl -fsSL "${COMMUNITY_SCRIPTS_CORE_URL:-https://raw.githubusercontent.com/community-scripts/core/main}/core/build.func")
# Copyright (c) 2021-2026 community-scripts ORG
# Author: Jose Alcalá Correa
# License: MIT | https://github.com/community-scripts/DevScripts/raw/main/LICENSE
# Source: https://antigravity.google/docs/remote-control

APP="Proxmox-LXC-Antigravity-Remote-Control"
var_hostname="${var_hostname:-antigravity-remote-control}"
var_tags="${var_tags:-ai;dev-tools}"
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-2048}"
var_disk="${var_disk:-16}"
var_os="${var_os:-debian}"
var_version="${var_version:-13}"
#var_arm64="${var_arm64:-no}" # unset = ask the user; set yes/no only when verified
var_unprivileged="${var_unprivileged:-1}"

header_info "$APP"
variables
color
catch_errors

function update_script() {
  header_info
  check_container_storage
  check_container_resources

  local agy_user="antigravity"
  local agy_home="/home/${agy_user}"
  local agy_bin="${agy_home}/.local/bin/agy"
  local agy_uid

  if ! agy_uid="$(id -u "$agy_user" 2>/dev/null)" || [[ ! -x "$agy_bin" ]]; then
    msg_error "No Antigravity CLI Installation Found!"
    exit 1
  fi

  if [[ -f "/var/lib/systemd/linger/${agy_user}" ]]; then
    systemctl start "user@${agy_uid}.service" 2>/dev/null || true
  fi

  _run_as_agy() {
    local -a env_args=(
      -C "$agy_home"
      -u TMPDIR
      "HOME=${agy_home}"
      "USER=${agy_user}"
      "LOGNAME=${agy_user}"
      "PATH=${agy_home}/.local/bin:/usr/local/bin:/usr/bin:/bin"
      "container=lxc"
    )
    if [[ -d "/run/user/${agy_uid}" ]]; then
      env_args+=("XDG_RUNTIME_DIR=/run/user/${agy_uid}")
    fi
    if [[ -S "/run/user/${agy_uid}/bus" ]]; then
      env_args+=("DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${agy_uid}/bus")
    fi
    runuser -u "$agy_user" -- env "${env_args[@]}" "$@" </dev/null
  }

  local before_ver after_ver update_out daemon_state daemon_pid
  local daemon_active=0 daemon_stale=0

  before_ver="$(_run_as_agy "$agy_bin" --version 2>/dev/null | head -n 1 || true)"

  daemon_state="$(_run_as_agy systemctl --user show -p ActiveState --value antigravity-cli-daemon.service 2>/dev/null || true)"
  case "$daemon_state" in
  active | reloading | activating | failed) daemon_active=1 ;;
  esac

  msg_info "Updating Antigravity CLI"
  if ! update_out="$(_run_as_agy "$agy_bin" update 2>&1)"; then
    msg_error "Failed to update Antigravity CLI"
    [[ -n "$update_out" ]] && echo "$update_out" >&2
    exit 1
  fi

  after_ver="$(_run_as_agy "$agy_bin" --version 2>/dev/null | head -n 1 || true)"

  if ((daemon_active == 1)); then
    daemon_pid="$(_run_as_agy systemctl --user show -p MainPID --value antigravity-cli-daemon.service 2>/dev/null || true)"
    if [[ "$daemon_pid" =~ ^[1-9][0-9]*$ && -e "/proc/${daemon_pid}/exe" ]] && [[ ! "/proc/${daemon_pid}/exe" -ef "$agy_bin" ]]; then
      daemon_stale=1
    fi
  fi

  _restart_daemon() {
    _run_as_agy systemctl --user daemon-reload
    _run_as_agy systemctl --user reset-failed antigravity-cli-daemon.service 2>/dev/null || true
    _run_as_agy systemctl --user restart antigravity-cli-daemon.service
  }

  if [[ -n "$after_ver" && "$after_ver" != "$before_ver" ]]; then
    msg_ok "Updated Antigravity CLI (${before_ver:-unknown} -> ${after_ver})"
    if ((daemon_active == 1)); then
      msg_info "Restarting Antigravity Remote Control Daemon"
      _restart_daemon
      msg_ok "Restarted Antigravity Remote Control Daemon"
    fi
    msg_ok "Updated successfully!"
  elif ((daemon_active == 1 && daemon_stale == 1)); then
    msg_ok "Antigravity CLI is up to date${after_ver:+ (${after_ver})}"
    msg_info "Restarting Antigravity Remote Control Daemon to load updated binary"
    _restart_daemon
    msg_ok "Restarted Antigravity Remote Control Daemon"
  elif ((daemon_active == 1)) && [[ "$daemon_state" == "failed" ]]; then
    msg_ok "Antigravity CLI is already up to date${after_ver:+ (${after_ver})}"
    msg_info "Restarting failed Antigravity Remote Control Daemon"
    _restart_daemon
    msg_ok "Restarted Antigravity Remote Control Daemon"
  else
    msg_ok "Antigravity CLI is already up to date${after_ver:+ (${after_ver})}"
  fi
  exit
}

function configure_lan_firewall() {
  if ! command -v pct >/dev/null 2>&1 || [[ ! -d /etc/pve ]] || [[ -z "${CTID:-}" ]]; then
    return 0
  fi

  local block_lan="${ANTIGRAVITY_BLOCK_LAN:-}"
  case "${block_lan,,}" in
  yes | y | 1 | true) block_lan="yes" ;;
  no | n | 0 | false) block_lan="no" ;;
  "")
    if (declare -f is_unattended >/dev/null 2>&1 && is_unattended) || [[ "${PHS_SILENT:-0}" == "1" ]]; then
      block_lan="no"
    elif [[ -r /dev/tty && -w /dev/tty ]]; then
      local prompt_msg="Enable the Proxmox VE firewall on CT ${CTID} to block outbound access to private LAN networks (RFC1918, IPv4 link-local, CGNAT, IPv6 ULA) while allowing DHCP and DNS?\n\nRecommended when running autonomous AI agents."
      if command -v whiptail >/dev/null 2>&1; then
        if whiptail --backtitle "Proxmox VE Helper Scripts" --title "${APP} Firewall" \
          --yesno "$prompt_msg" 13 72 </dev/tty >/dev/tty 2>&1; then
          block_lan="yes"
        else
          block_lan="no"
        fi
      else
        local reply=""
        printf 'Enable Proxmox LAN-isolation firewall on CT %s? [Y/n]: ' "$CTID" >/dev/tty
        read -r reply </dev/tty || reply="n"
        case "${reply,,}" in
        "" | y | yes) block_lan="yes" ;;
        *) block_lan="no" ;;
        esac
      fi
    else
      block_lan="no"
    fi
    ;;
  *)
    msg_warn "Invalid ANTIGRAVITY_BLOCK_LAN value '${block_lan}' (expected yes or no); skipping firewall setup."
    return 0
    ;;
  esac

  [[ "$block_lan" == "yes" ]] || return 0

  local net0_val updated_net0
  net0_val="$(pct config "$CTID" | sed -n 's/^net0:[[:space:]]*//p' | head -n 1)"
  if [[ -z "$net0_val" ]]; then
    msg_warn "Could not find net0 in CT ${CTID} config; skipping firewall setup."
    return 0
  fi

  _is_valid_cidr_or_ip() {
    local val="$1"
    if command -v python3 >/dev/null 2>&1; then
      python3 -c 'import ipaddress, sys; ipaddress.ip_network(sys.argv[1], strict=False)' "$val" 2>/dev/null
      return $?
    fi
    [[ "$val" =~ ^((25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])(/([0-9]|[12][0-9]|3[0-2]))?$ ]]
  }

  local ssh_rule="" ssh_warn=""
  local allow_ssh_from="${ANTIGRAVITY_ALLOW_SSH_FROM:-}"
  case "${allow_ssh_from,,}" in
  none | no | 0 | false)
    ssh_rule=""
    ;;
  "")
    if [[ "${SSH_ROOT:-no}" == "yes" || "${SSH:-no}" == "yes" || "${var_ssh:-no}" == "yes" || -n "${SSH_AUTHORIZED_KEY:-}" || -n "${var_ssh_authorized_key:-}" ]] ||
      pct exec "$CTID" -- sh -c 'systemctl is-enabled -q ssh 2>/dev/null || systemctl is-enabled -q sshd 2>/dev/null' 2>/dev/null; then
      ssh_rule="IN ACCEPT -p tcp -dport 22 # Allow SSH"
    fi
    ;;
  *)
    if _is_valid_cidr_or_ip "$allow_ssh_from"; then
      ssh_rule="IN ACCEPT -source ${allow_ssh_from} -p tcp -dport 22 # Allow SSH from allowed source"
    else
      ssh_warn="Invalid ANTIGRAVITY_ALLOW_SSH_FROM value '${allow_ssh_from}'; skipping inbound SSH rule."
    fi
    ;;
  esac

  msg_info "Configuring Proxmox VE LAN-Isolation Firewall"
  if [[ ",${net0_val}," == *",firewall=0,"* ]]; then
    updated_net0="$(printf '%s' "$net0_val" | sed -E 's/(^|,)firewall=0(,|$)/\1firewall=1\2/')"
    pct set "$CTID" -net0 "$updated_net0" >/dev/null
  elif [[ ",${net0_val}," != *",firewall=1,"* ]]; then
    pct set "$CTID" -net0 "${net0_val},firewall=1" >/dev/null
  fi

  mkdir -p /etc/pve/firewall
  local fw_file="/etc/pve/firewall/${CTID}.fw"
  {
    cat <<'EOF'
[OPTIONS]
enable: 1
dhcp: 1
ndp: 1
policy_in: DROP
policy_out: ACCEPT

[RULES]
EOF
    if [[ -n "$ssh_rule" ]]; then
      printf '%s\n' "$ssh_rule"
    fi
    cat <<'EOF'
OUT ACCEPT -p udp -dport 53 # Allow DNS (UDP)
OUT ACCEPT -p tcp -dport 53 # Allow DNS (TCP)
OUT DROP -dest 10.0.0.0/8 # Block RFC1918 10.0.0.0/8
OUT DROP -dest 172.16.0.0/12 # Block RFC1918 172.16.0.0/12
OUT DROP -dest 192.168.0.0/16 # Block RFC1918 192.168.0.0/16
OUT DROP -dest 169.254.0.0/16 # Block IPv4 link-local
OUT DROP -dest 100.64.0.0/10 # Block CGNAT 100.64.0.0/10
OUT DROP -dest fc00::/7 # Block IPv6 ULA
EOF
  } >"$fw_file"
  msg_ok "Configured Proxmox VE LAN-Isolation Firewall (${fw_file})"

  if [[ -n "$ssh_warn" ]]; then
    msg_warn "$ssh_warn"
  fi

  if ! grep -Eq '^[[:space:]]*enable:[[:space:]]*1([[:space:]]|$)' /etc/pve/firewall/cluster.fw 2>/dev/null; then
    msg_warn "Proxmox Datacenter firewall is disabled. Set Firewall to Yes under Datacenter -> Firewall -> Options for CT ${CTID} rules to become active."
  fi
}

start
build_container
description
configure_lan_firewall

msg_ok "Completed Successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW}Container IP: ${BGN}${IP:-N/A}${CL}"
echo -e "${INFO}${YW}Complete first-run sign-in inside the container:${CL}"
echo -e "${INFO}${BGN}su --whitelist-environment=SSH_CONNECTION,SSH_CLIENT,SSH_TTY - antigravity${CL}"
echo -e "${INFO}${BGN}SSH_TTY=\"\$(tty)\" agy${CL}  ${YW}(sign in, then stop with /exit)${CL}"
echo -e "${INFO}${BGN}agy remote-control start --name \"${HN:-antigravity-remote-control}\"${CL}"
echo -e "${INFO}${YW}Access your instance from the Remote Control Dashboard:${CL}"
echo -e "${GATEWAY}${BGN}https://antigravity.google.com${CL}"
