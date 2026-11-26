#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Author: Jose Alcalá Correa
# License: MIT | https://github.com/community-scripts/DevScripts/raw/main/LICENSE
# Source: https://antigravity.google/docs/remote-control

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

msg_info "Installing Dependencies"
$STD apt-get install -y \
  ca-certificates \
  curl \
  dbus-user-session \
  git \
  libpam-systemd \
  openssh-client
msg_ok "Installed Dependencies"

AGY_USER="antigravity"
AGY_HOME="/home/${AGY_USER}"

msg_info "Creating ${AGY_USER} User"
if ! id -u "$AGY_USER" &>/dev/null; then
  useradd -m -s /bin/bash "$AGY_USER"
fi
AGY_UID="$(id -u "$AGY_USER")"
msg_ok "Created ${AGY_USER} User"

msg_info "Configuring User Environment"
cat <<'EOF' >/etc/profile.d/proxmox-lxc-antigravity-remote-control.sh
# __proxmox_lxc_antigravity_remote_control_env__: PATH, container marker, and systemd user bus for antigravity
if [ "$(id -un)" = "antigravity" ]; then
  case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) export PATH="$HOME/.local/bin:$PATH" ;;
  esac
  export container="${container:-lxc}"
  _agy_uid="$(id -u)"
  if [ -d "/run/user/${_agy_uid}" ] && [ "${XDG_RUNTIME_DIR:-}" != "/run/user/${_agy_uid}" ]; then
    export XDG_RUNTIME_DIR="/run/user/${_agy_uid}"
  fi
  if [ -S "/run/user/${_agy_uid}/bus" ] && [ "${DBUS_SESSION_BUS_ADDRESS:-}" != "unix:path=/run/user/${_agy_uid}/bus" ]; then
    export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${_agy_uid}/bus"
  fi
  unset _agy_uid
fi
EOF
chmod 755 /etc/profile.d/proxmox-lxc-antigravity-remote-control.sh

install -d -m 755 -o "$AGY_USER" -g "$AGY_USER" "${AGY_HOME}/.config" "${AGY_HOME}/.config/environment.d"
cat <<EOF >"${AGY_HOME}/.config/environment.d/10-antigravity.conf"
PATH=${AGY_HOME}/.local/bin:\${PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}
container=lxc
EOF
chown "${AGY_USER}:${AGY_USER}" "${AGY_HOME}/.config/environment.d/10-antigravity.conf"
chmod 644 "${AGY_HOME}/.config/environment.d/10-antigravity.conf"

if [[ -n "${SSH_AUTHORIZED_KEY:-}" ]]; then
  if [[ ! -f /etc/ssh/sshd_config ]]; then
    $STD apt-get install -y openssh-server
  fi
  systemctl enable -q --now ssh 2>/dev/null || systemctl enable -q --now sshd 2>/dev/null || true
  install -d -m 700 -o "$AGY_USER" -g "$AGY_USER" "${AGY_HOME}/.ssh"
  install -m 600 -o "$AGY_USER" -g "$AGY_USER" /dev/null "${AGY_HOME}/.ssh/authorized_keys"
  printf '%s\n' "${SSH_AUTHORIZED_KEY}" >"${AGY_HOME}/.ssh/authorized_keys"
fi
msg_ok "Configured User Environment"

msg_info "Enabling Systemd User Lingering"
systemctl start dbus.socket &>/dev/null || true
systemctl start dbus.service &>/dev/null || true
systemctl reset-failed systemd-logind.service &>/dev/null || true
if ! $STD systemctl start systemd-logind.service; then
  msg_error "Failed to start systemd-logind.service. Make sure LXC Nesting (nesting=1) is enabled for this container."
  exit 1
fi
$STD loginctl enable-linger "$AGY_USER"
$STD systemctl start "user@${AGY_UID}.service"
msg_ok "Enabled Systemd User Lingering"

msg_info "Installing Antigravity CLI"
AGY_INSTALLER="$(mktemp /tmp/agy-install.XXXXXX.sh)"
if ! curl -fsSL --retry 3 --retry-delay 1 --retry-connrefused --connect-timeout 10 \
  https://antigravity.google/cli/install.sh -o "$AGY_INSTALLER"; then
  rm -f "$AGY_INSTALLER"
  msg_error "Failed to download Antigravity CLI installer"
  exit 1
fi
chmod 644 "$AGY_INSTALLER"
if ! $STD runuser -u "$AGY_USER" -- env \
  -C "$AGY_HOME" \
  -u TMPDIR \
  HOME="$AGY_HOME" \
  USER="$AGY_USER" \
  LOGNAME="$AGY_USER" \
  PATH="${AGY_HOME}/.local/bin:/usr/local/bin:/usr/bin:/bin" \
  bash "$AGY_INSTALLER" </dev/null; then
  rm -f "$AGY_INSTALLER"
  msg_error "Failed to install Antigravity CLI"
  exit 1
fi
rm -f "$AGY_INSTALLER"
if [[ ! -x "${AGY_HOME}/.local/bin/agy" ]]; then
  msg_error "Antigravity CLI binary not found at ${AGY_HOME}/.local/bin/agy"
  exit 1
fi
AGY_VERSION="$(runuser -u "$AGY_USER" -- env -C "$AGY_HOME" -u TMPDIR HOME="$AGY_HOME" "${AGY_HOME}/.local/bin/agy" --version 2>/dev/null | head -n 1 || true)"
msg_ok "Installed Antigravity CLI${AGY_VERSION:+ (${AGY_VERSION})}"

# Prepend loader above Debian's non-interactive return guard so remote agent tool shells also inherit PATH
if ! grep -q '__proxmox_lxc_antigravity_remote_control_env__' "${AGY_HOME}/.bashrc" 2>/dev/null; then
  AGY_BASHRC_TMP="$(mktemp)"
  cat <<'EOF' >"$AGY_BASHRC_TMP"
# __proxmox_lxc_antigravity_remote_control_env__: load environment before Debian's non-interactive return guard
if [ -r /etc/profile.d/proxmox-lxc-antigravity-remote-control.sh ]; then
  . /etc/profile.d/proxmox-lxc-antigravity-remote-control.sh
fi

EOF
  if [[ -f "${AGY_HOME}/.bashrc" ]]; then
    cat "${AGY_HOME}/.bashrc" >>"$AGY_BASHRC_TMP"
  fi
  install -m 644 -o "$AGY_USER" -g "$AGY_USER" "$AGY_BASHRC_TMP" "${AGY_HOME}/.bashrc"
  rm -f "$AGY_BASHRC_TMP"
fi

msg_info "Configuring Antigravity CLI Sandbox Settings"
AGY_SETTINGS_DIR="${AGY_HOME}/.gemini/antigravity-cli"
AGY_SETTINGS_FILE="${AGY_SETTINGS_DIR}/settings.json"
install -d -m 700 -o "$AGY_USER" -g "$AGY_USER" "${AGY_HOME}/.gemini" "$AGY_SETTINGS_DIR"
if [[ ! -f "$AGY_SETTINGS_FILE" ]]; then
  install -m 600 -o "$AGY_USER" -g "$AGY_USER" /dev/null "$AGY_SETTINGS_FILE"
  cat <<'EOF' >"$AGY_SETTINGS_FILE"
{
  "$schema": "https://antigravity.google/schemas/v1/settings.json",
  "enableTerminalSandbox": true,
  "toolPermission": "proceed-in-sandbox",
  "allowNonWorkspaceAccess": false
}
EOF
fi
msg_ok "Configured Antigravity CLI Sandbox Settings"

motd_ssh
customize
cleanup_lxc
