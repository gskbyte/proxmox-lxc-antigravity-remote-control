# Proxmox LXC Antigravity Remote Control

This repository contains helper scripts for Proxmox VE and Google Antigravity Remote Control. Each file follows the `community-scripts/DevScripts` format. The CT script makes an unprivileged LXC container with Debian 13 and installs the Antigravity CLI (`agy`) for the `antigravity` user. The script enables systemd user lingering so the headless daemon for Remote Control remains active after logout and reboot.

## Install

Run this command in the shell of the Proxmox VE host:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/gskbyte/proxmox-lxc-antigravity-remote-control/main/ct/proxmox-lxc-antigravity-remote-control.sh)"
```

If you install from another branch or fork, set `ANTIGRAVITY_REMOTE_CONTROL_REPO_URL` before the command:

```bash
ANTIGRAVITY_REMOTE_CONTROL_REPO_URL="https://raw.githubusercontent.com/gskbyte/proxmox-lxc-antigravity-remote-control/<branch>" bash -c "$(curl -fsSL https://raw.githubusercontent.com/gskbyte/proxmox-lxc-antigravity-remote-control/<branch>/ct/proxmox-lxc-antigravity-remote-control.sh)"
```

## Complete the First-Run Setup

Antigravity Remote Control uses your Google Account credentials from the Antigravity CLI. Before you start the background daemon, you must sign in one time inside the container. In this headless container, sign-in uses the manual authorization URL and code flow in both the console and SSH.

> [!NOTE]
> If you want direct SSH access to the container, enable Root SSH in Advanced Settings. You can also add an SSH public key there.

1. Open the LXC container console or an SSH session.
2. Change to the `antigravity` user:

```bash
su --whitelist-environment=SSH_CONNECTION,SSH_CLIENT,SSH_TTY - antigravity
```

3. Start the Antigravity CLI in remote sign-in mode:

```bash
SSH_TTY="$(tty)" agy
```

4. Copy the authorization URL from the terminal.
5. Open the authorization URL in a web browser on your local machine.
6. Sign in with your Google Account to get an authorization code.
7. Copy the authorization code and paste it into the container terminal.
8. Stop the Antigravity CLI with `/exit`.
9. Start the headless daemon for Remote Control:

```bash
agy remote-control start --name "proxmox-lxc-antigravity-remote-control"
```

10. Do a check of the daemon status and instance name:

```bash
agy remote-control status
```

11. Open `https://antigravity.google.com` in a web browser.
12. Sign in with the same Google Account.
13. Select your instance name in the instance switcher.

## Manage the Daemon

Run these commands as the `antigravity` user to start, stop, or do a check of the background daemon:

```bash
agy remote-control status
agy remote-control start --name "<new-name>"
agy remote-control stop
```

To read the logs of the systemd user service, run this command:

```bash
journalctl --user -u antigravity-cli-daemon -n 50
```

## Update Antigravity CLI

The `update` command runs `agy update` as the `antigravity` user. If the active daemon uses an old binary after the update, the command starts `antigravity-cli-daemon.service` again. The `update` command updates only the Antigravity CLI binary, not the Debian OS packages.

1. Open the LXC container console.
2. Run the `update` command:

```bash
update
```

To update the Antigravity CLI inside the container without the interactive menu, run this command:

```bash
PHS_SILENT=1 update
```

To update the Antigravity CLI from the Proxmox VE host without the interactive menu, run this command:

```bash
pct exec <CTID> -- env PHS_SILENT=1 update
```

## Security and Firewall

The install script makes `/home/antigravity/.gemini/antigravity-cli/settings.json` with the terminal sandbox active. This file sets `enableTerminalSandbox` to `true`, `toolPermission` to `proceed-in-sandbox`, and `allowNonWorkspaceAccess` to `false`. You can edit this file directly or use `/config` inside the Antigravity CLI when the OS sandbox is available.

When you make the container, the CT script asks if you want to activate a LAN-isolation firewall on the Proxmox VE host. When the firewall is active, it sets `firewall=1` on `net0` and writes rules to `/etc/pve/firewall/<CTID>.fw`. The rules allow DHCP, IPv6 NDP, and outbound DNS, and drop all inbound traffic. They also drop outbound traffic to these private and IPv4 link-local networks: `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `169.254.0.0/16`, `100.64.0.0/10`, and `fc00::/7`. If SSH access is active, the script adds an inbound rule for TCP port 22. In unattended runs, `ANTIGRAVITY_BLOCK_LAN` defaults to `no`.

> [!NOTE]
> If the Datacenter firewall is off, set **Firewall** to **Yes** under **Datacenter > Firewall > Options** so the container rules become active.

To set the firewall option without a prompt, set `ANTIGRAVITY_BLOCK_LAN` (`yes` or `no`) before you run the install command:

```bash
ANTIGRAVITY_BLOCK_LAN=yes bash -c "$(curl -fsSL https://raw.githubusercontent.com/gskbyte/proxmox-lxc-antigravity-remote-control/main/ct/proxmox-lxc-antigravity-remote-control.sh)"
```

To limit inbound SSH to one IP address or subnet, set `ANTIGRAVITY_ALLOW_SSH_FROM`:

```bash
ANTIGRAVITY_BLOCK_LAN=yes ANTIGRAVITY_ALLOW_SSH_FROM="192.168.1.50/32" bash -c "$(curl -fsSL https://raw.githubusercontent.com/gskbyte/proxmox-lxc-antigravity-remote-control/main/ct/proxmox-lxc-antigravity-remote-control.sh)"
```

To block all inbound SSH even when SSH is active, set `ANTIGRAVITY_ALLOW_SSH_FROM=none`.

## Repository Files

- `ct/proxmox-lxc-antigravity-remote-control.sh`: This script makes the LXC container on a Proxmox VE host and updates the Antigravity CLI inside the container. It can also add the LAN-isolation firewall.
- `install/proxmox-lxc-antigravity-remote-control-install.sh`: This script installs the necessary packages, makes the `antigravity` user, enables systemd user lingering, installs the Antigravity CLI, and writes default sandbox settings.
- `json/proxmox-lxc-antigravity-remote-control.json`: This file contains the catalog metadata for the container.

## Test Local Changes

If you test local changes on a Proxmox VE host, run the CT script from the repository directory:

```bash
bash ct/proxmox-lxc-antigravity-remote-control.sh
```

> [!NOTE]
> When you run `ct/proxmox-lxc-antigravity-remote-control.sh` from a local copy of this repository, the script loads `install/proxmox-lxc-antigravity-remote-control-install.sh` from the same directory.

If you test an update with local changes, run these commands on the Proxmox VE host:

```bash
pct push <CTID> ct/proxmox-lxc-antigravity-remote-control.sh /tmp/proxmox-lxc-antigravity-remote-control.sh
pct exec <CTID> -- env PHS_SILENT=1 bash /tmp/proxmox-lxc-antigravity-remote-control.sh
```

## Paths and Service

| Item | Path or Address |
| --- | --- |
| User account | `antigravity` (`/home/antigravity`) |
| Binary | `/home/antigravity/.local/bin/agy` |
| CLI settings file | `/home/antigravity/.gemini/antigravity-cli/settings.json` |
| Daemon config file | `/home/antigravity/.gemini/config/config.json` (`cliRemoteControlHostname`) |
| Systemd environment file | `/home/antigravity/.config/environment.d/10-antigravity.conf` |
| Systemd user service | `antigravity-cli-daemon.service` |
| Linger marker | `/var/lib/systemd/linger/antigravity` |
| Optional firewall rules (host) | `/etc/pve/firewall/<CTID>.fw` |
| Remote Control Dashboard | `https://antigravity.google.com` |
