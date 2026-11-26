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

function configure_antigravity_ssh() {
  AGY_SSH_AUTH_CONFIGURED=0
  if ! command -v pct >/dev/null 2>&1 || [[ -z "${CTID:-}" ]]; then
    return 0
  fi

  local agy_user="antigravity"

  _ct_append_agy_keys() {
    local raw="$1"
    [[ -n "$raw" ]] || return 0
    printf '%s\n' "$raw" | pct exec "$CTID" -- bash -c '
set -euo pipefail
agy_user="$1"
agy_home="/home/${agy_user}"
install -d -m 700 -o "$agy_user" -g "$agy_user" "${agy_home}/.ssh"
if [[ ! -f "${agy_home}/.ssh/authorized_keys" ]]; then
  install -m 600 -o "$agy_user" -g "$agy_user" /dev/null "${agy_home}/.ssh/authorized_keys"
fi
while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line%$'\''\r'\''}"
  [[ -z "${line//[[:space:]]/}" || "$line" =~ ^[[:space:]]*# ]] && continue
  if ! grep -Fxq -- "$line" "${agy_home}/.ssh/authorized_keys" 2>/dev/null; then
    printf "%s\n" "$line" >>"${agy_home}/.ssh/authorized_keys"
  fi
done
chown "${agy_user}:${agy_user}" "${agy_home}/.ssh/authorized_keys"
chmod 600 "${agy_home}/.ssh/authorized_keys"
' _ "$agy_user"
  }

  _ct_has_agy_ssh_auth() {
    pct exec "$CTID" -- bash -c '
agy_user="$1"
agy_home="/home/${agy_user}"
if grep -Eq "^[[:space:]]*[^#[:space:]]" "${agy_home}/.ssh/authorized_keys" 2>/dev/null; then
  exit 0
fi
shadow_hash="$(getent shadow "$agy_user" 2>/dev/null | cut -d: -f2 || true)"
if [[ -n "$shadow_hash" && "$shadow_hash" != "*" && "$shadow_hash" != !* ]]; then
  exit 0
fi
exit 1
' _ "$agy_user" </dev/null
  }

  _is_valid_ssh_pubkey() {
    local key_data="$1"
    if command -v ssh-keygen >/dev/null 2>&1; then
      printf '%s\n' "$key_data" | ssh-keygen -l -f - >/dev/null 2>&1
      return $?
    fi
    [[ "$key_data" =~ (ssh-(ed25519|rsa|dss)|ecdsa-sha2-nistp(256|384|521)|sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh\.com)[[:space:]]+[A-Za-z0-9+/=]+ ]]
  }

  # Ensure antigravity account is unlocked for key auth and sync any keys already provided
  pct exec "$CTID" -- bash -c '
set -euo pipefail
agy_user="$1"
agy_home="/home/${agy_user}"
shadow_hash="$(getent shadow "$agy_user" 2>/dev/null | cut -d: -f2 || true)"
if [[ -z "$shadow_hash" || "$shadow_hash" == "!" || "$shadow_hash" == "!!" ]]; then
  usermod -p "*" "$agy_user"
fi
install -d -m 700 -o "$agy_user" -g "$agy_user" "${agy_home}/.ssh"
if [[ ! -f "${agy_home}/.ssh/authorized_keys" ]]; then
  install -m 600 -o "$agy_user" -g "$agy_user" /dev/null "${agy_home}/.ssh/authorized_keys"
fi
if [[ -r /root/.ssh/authorized_keys ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\''\r'\''}"
    [[ -z "${line//[[:space:]]/}" || "$line" =~ ^[[:space:]]*# ]] && continue
    if ! grep -Fxq -- "$line" "${agy_home}/.ssh/authorized_keys" 2>/dev/null; then
      printf "%s\n" "$line" >>"${agy_home}/.ssh/authorized_keys"
    fi
  done </root/.ssh/authorized_keys
fi
chown "${agy_user}:${agy_user}" "${agy_home}/.ssh/authorized_keys"
chmod 600 "${agy_home}/.ssh/authorized_keys"
' _ "$agy_user" </dev/null

  local env_key
  for env_key in "${ANTIGRAVITY_SSH_AUTHORIZED_KEY:-}" "${SSH_AUTHORIZED_KEY:-}" "${var_ssh_authorized_key:-}"; do
    if [[ -n "$env_key" ]]; then
      if ! _is_valid_ssh_pubkey "$env_key"; then
        msg_warn "Provided SSH public key did not pass ssh-keygen validation; writing it to /home/${agy_user}/.ssh/authorized_keys anyway."
      fi
      _ct_append_agy_keys "$env_key"
    fi
  done

  if [[ -n "${ANTIGRAVITY_SSH_PASSWORD:-}" ]]; then
    msg_info "Setting SSH Password for ${agy_user}"
    printf '%s:%s\n' "$agy_user" "${ANTIGRAVITY_SSH_PASSWORD}" | pct exec "$CTID" -- chpasswd
    msg_ok "Set SSH Password for ${agy_user}"
  fi

  if _ct_has_agy_ssh_auth; then
    AGY_SSH_AUTH_CONFIGURED=1
    return 0
  fi

  if (declare -f is_unattended >/dev/null 2>&1 && is_unattended) || [[ "${PHS_SILENT:-0}" == "1" ]] || [[ ! -r /dev/tty || ! -w /dev/tty ]]; then
    msg_warn "No SSH public key or password configured for '${agy_user}'. Add a key to /home/${agy_user}/.ssh/authorized_keys or set a password before connecting via SSH."
    return 0
  fi

  local input_key=""
  if command -v whiptail >/dev/null 2>&1; then
    while true; do
      if input_key="$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "${APP} SSH Access" \
        --inputbox "Clients connect via SSH as the '${agy_user}' user.\n\nPaste an SSH public key for '${agy_user}' (recommended), or leave blank / Cancel to skip:" 13 74 \
        3>&1 1>&2 2>&3 </dev/tty)"; then
        input_key="${input_key#"${input_key%%[![:space:]]*}"}"
        input_key="${input_key%"${input_key##*[![:space:]]}"}"
        if [[ -z "$input_key" ]]; then
          break
        elif _is_valid_ssh_pubkey "$input_key"; then
          msg_info "Adding SSH Public Key for ${agy_user}"
          _ct_append_agy_keys "$input_key"
          msg_ok "Added SSH Public Key for ${agy_user}"
          AGY_SSH_AUTH_CONFIGURED=1
          return 0
        else
          whiptail --backtitle "Proxmox VE Helper Scripts" --title "${APP} SSH Access" \
            --msgbox "The value entered does not look like a valid OpenSSH public key (for example: ssh-ed25519 AAAA... user@host). Please try again or leave blank to skip." 10 72 </dev/tty >/dev/tty 2>&1 || true
        fi
      else
        break
      fi
    done

    if whiptail --backtitle "Proxmox VE Helper Scripts" --title "${APP} SSH Password" \
      --defaultno --yesno "No SSH public key was configured for '${agy_user}'.\n\nWould you like to set a password for '${agy_user}' so SSH clients can log in with password authentication?" 11 72 </dev/tty >/dev/tty 2>&1; then
      local pw1="" pw2=""
      while true; do
        pw1="$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "${APP} SSH Password" \
          --passwordbox "Enter password for '${agy_user}':" 9 60 \
          3>&1 1>&2 2>&3 </dev/tty)" || break
        if [[ -z "$pw1" ]]; then
          break
        fi
        pw2="$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "${APP} SSH Password" \
          --passwordbox "Confirm password for '${agy_user}':" 9 60 \
          3>&1 1>&2 2>&3 </dev/tty)" || break
        if [[ "$pw1" == "$pw2" ]]; then
          msg_info "Setting SSH Password for ${agy_user}"
          printf '%s:%s\n' "$agy_user" "$pw1" | pct exec "$CTID" -- chpasswd
          msg_ok "Set SSH Password for ${agy_user}"
          AGY_SSH_AUTH_CONFIGURED=1
          return 0
        else
          whiptail --backtitle "Proxmox VE Helper Scripts" --title "${APP} SSH Password" \
            --msgbox "Passwords did not match. Please try again." 8 56 </dev/tty >/dev/tty 2>&1 || true
        fi
      done
    fi
  else
    printf "Paste an SSH public key for '%s' (leave blank to skip): " "$agy_user" >/dev/tty
    IFS= read -r input_key </dev/tty || input_key=""
    input_key="${input_key#"${input_key%%[![:space:]]*}"}"
    input_key="${input_key%"${input_key##*[![:space:]]}"}"
    if [[ -n "$input_key" ]]; then
      if _is_valid_ssh_pubkey "$input_key"; then
        msg_info "Adding SSH Public Key for ${agy_user}"
        _ct_append_agy_keys "$input_key"
        msg_ok "Added SSH Public Key for ${agy_user}"
        AGY_SSH_AUTH_CONFIGURED=1
        return 0
      else
        msg_warn "Input did not look like a valid OpenSSH public key; skipping."
      fi
    fi

    local reply=""
    printf "No SSH key added. Set a password for '%s'? [y/N]: " "$agy_user" >/dev/tty
    IFS= read -r reply </dev/tty || reply="n"
    case "${reply,,}" in
    y | yes)
      local pw1="" pw2=""
      printf "Enter password for '%s': " "$agy_user" >/dev/tty
      IFS= read -rs pw1 </dev/tty || pw1=""
      printf '\n' >/dev/tty
      if [[ -n "$pw1" ]]; then
        printf "Confirm password for '%s': " "$agy_user" >/dev/tty
        IFS= read -rs pw2 </dev/tty || pw2=""
        printf '\n' >/dev/tty
        if [[ "$pw1" == "$pw2" ]]; then
          msg_info "Setting SSH Password for ${agy_user}"
          printf '%s:%s\n' "$agy_user" "$pw1" | pct exec "$CTID" -- chpasswd
          msg_ok "Set SSH Password for ${agy_user}"
          AGY_SSH_AUTH_CONFIGURED=1
          return 0
        else
          msg_warn "Passwords did not match; skipping password setup."
        fi
      fi
      ;;
    esac
  fi

  if ((AGY_SSH_AUTH_CONFIGURED == 0)); then
    msg_warn "No SSH public key or password configured for '${agy_user}'. Add a key or set a password before connecting via SSH."
  fi
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
      local prompt_msg="Enable the Proxmox VE firewall on CT ${CTID} to block outbound access to private LAN networks (RFC1918, IPv4 link-local, CGNAT, IPv6 ULA) while allowing inbound SSH (TCP/22), DHCP, and DNS?\n\nRecommended when running autonomous AI agents."
      if command -v whiptail >/dev/null 2>&1; then
        if whiptail --backtitle "Proxmox VE Helper Scripts" --title "${APP} Firewall" \
          --yesno "$prompt_msg" 13 74 </dev/tty >/dev/tty 2>&1; then
          block_lan="yes"
        else
          block_lan="no"
        fi
      else
        local reply=""
        printf 'Enable Proxmox LAN-isolation firewall on CT %s (keeping SSH port 22 open)? [Y/n]: ' "$CTID" >/dev/tty
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

  local net0_val updated_net0
  net0_val="$(pct config "$CTID" | sed -n 's/^net0:[[:space:]]*//p' | head -n 1)"
  local fw_file="/etc/pve/firewall/${CTID}.fw"
  local net0_fw_enabled=0
  if [[ ",${net0_val}," == *",firewall=1,"* ]]; then
    net0_fw_enabled=1
  fi
  local existing_fw_enabled=0
  if grep -Eq '^[[:space:]]*enable:[[:space:]]*1([[:space:]]|$)' "$fw_file" 2>/dev/null; then
    existing_fw_enabled=1
  fi

  if [[ "$block_lan" != "yes" ]] && ((net0_fw_enabled == 0 && existing_fw_enabled == 0)); then
    return 0
  fi

  if [[ "$block_lan" == "yes" && -z "$net0_val" ]]; then
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

  local -a ssh_rules=()
  local -a ssh_warns=()
  local allow_ssh_from="${ANTIGRAVITY_ALLOW_SSH_FROM:-}"
  case "${allow_ssh_from,,}" in
  none | no | 0 | false)
    ssh_rules=()
    ;;
  "")
    ssh_rules=("IN ACCEPT -p tcp -dport 22 # Allow SSH")
    ;;
  *)
    local entry
    local -a raw_entries=()
    IFS=',' read -r -a raw_entries <<<"$allow_ssh_from"
    for entry in "${raw_entries[@]}"; do
      entry="${entry#"${entry%%[![:space:]]*}"}"
      entry="${entry%"${entry##*[![:space:]]}"}"
      [[ -z "$entry" ]] && continue
      if _is_valid_cidr_or_ip "$entry"; then
        ssh_rules+=("IN ACCEPT -source ${entry} -p tcp -dport 22 # Allow SSH from allowed source")
      else
        ssh_warns+=("Invalid ANTIGRAVITY_ALLOW_SSH_FROM entry '${entry}'; skipping it.")
      fi
    done
    ;;
  esac

  mkdir -p /etc/pve/firewall

  if [[ "$block_lan" == "yes" ]]; then
    msg_info "Configuring Proxmox VE LAN-Isolation Firewall"
    if [[ ",${net0_val}," == *",firewall=0,"* ]]; then
      updated_net0="$(printf '%s' "$net0_val" | sed -E 's/(^|,)firewall=0(,|$)/\1firewall=1\2/')"
      pct set "$CTID" -net0 "$updated_net0" >/dev/null
    elif [[ ",${net0_val}," != *",firewall=1,"* ]]; then
      pct set "$CTID" -net0 "${net0_val},firewall=1" >/dev/null
    fi

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
      if ((${#ssh_rules[@]} > 0)); then
        printf '%s\n' "${ssh_rules[@]}"
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
  else
    # Proxmox firewall is already enabled on net0 or <CTID>.fw; ensure inbound SSH is allowed
    if ((${#ssh_rules[@]} > 0)); then
      if [[ ! -f "$fw_file" ]]; then
        msg_info "Allowing Inbound SSH in Proxmox VE Firewall"
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
          printf '%s\n' "${ssh_rules[@]}"
        } >"$fw_file"
        msg_ok "Allowed Inbound SSH in Proxmox VE Firewall (${fw_file})"
      elif ! grep -Eq '^[[:space:]]*IN[[:space:]]+(SSH\(ACCEPT\)|ACCEPT[^#]*-p[[:space:]]+tcp[^#]*-dport[[:space:]]+22([[:space:],]|$))' "$fw_file" 2>/dev/null; then
        msg_info "Adding Inbound SSH Rule to Existing Proxmox VE Firewall"
        if grep -Eq '^[[:space:]]*\[RULES\][[:space:]]*$' "$fw_file" 2>/dev/null; then
          local fw_tmp inserted=0 line
          fw_tmp="$(mktemp)"
          while IFS= read -r line || [[ -n "$line" ]]; do
            printf '%s\n' "$line"
            if ((inserted == 0)) && [[ "$line" =~ ^[[:space:]]*\[RULES\][[:space:]]*$ ]]; then
              printf '%s\n' "${ssh_rules[@]}"
              inserted=1
            fi
          done <"$fw_file" >"$fw_tmp"
          cat "$fw_tmp" >"$fw_file"
          rm -f "$fw_tmp"
        else
          {
            printf '\n[RULES]\n'
            printf '%s\n' "${ssh_rules[@]}"
          } >>"$fw_file"
        fi
        msg_ok "Added Inbound SSH Rule to Existing Proxmox VE Firewall (${fw_file})"
      fi
    fi
  fi

  local w
  for w in "${ssh_warns[@]}"; do
    msg_warn "$w"
  done

  if ! grep -Eq '^[[:space:]]*enable:[[:space:]]*1([[:space:]]|$)' /etc/pve/firewall/cluster.fw 2>/dev/null; then
    msg_warn "Proxmox Datacenter firewall is disabled. Set Firewall to Yes under Datacenter -> Firewall -> Options for CT ${CTID} rules to become active."
  fi
}

start
build_container
description
configure_antigravity_ssh
configure_lan_firewall

msg_ok "Completed Successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW}Container IP: ${BGN}${IP:-N/A}${CL}"
echo -e "${INFO}${YW}Connect via SSH as the antigravity user:${CL}"
echo -e "${INFO}${BGN}ssh antigravity@${IP:-<container-ip>}${CL}"
if ((${AGY_SSH_AUTH_CONFIGURED:-0} == 0)); then
  echo -e "${INFO}${YW}Authorize SSH access for antigravity from the Proxmox host first (key or password):${CL}"
  echo -e "${INFO}${BGN}pct exec ${CTID:-<CTID>} -- passwd antigravity${CL}"
fi
echo -e "${INFO}${YW}Complete first-run sign-in as the antigravity user (add SSH_TTY=\"\$(tty)\" if using the Proxmox console):${CL}"
echo -e "${INFO}${BGN}agy${CL}  ${YW}(sign in, then stop with /exit)${CL}"
echo -e "${INFO}${BGN}agy remote-control start --name \"${HN:-antigravity-remote-control}\"${CL}"
echo -e "${INFO}${YW}Access your instance from the Remote Control Dashboard:${CL}"
echo -e "${GATEWAY}${BGN}https://antigravity.google.com${CL}"
