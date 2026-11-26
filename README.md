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

1. Connect to the container via SSH as the `antigravity` user:

```bash
ssh antigravity@<container-ip>
```

> [!NOTE]
> If you prefer the Proxmox LXC console instead of SSH, switch to the `antigravity` user with `su --whitelist-environment=SSH_CONNECTION,SSH_CLIENT,SSH_TTY - antigravity` and run `SSH_TTY="$(tty)" agy` in the next step.

2. Start the Antigravity CLI:

```bash
agy
```

3. Copy the authorization URL from the terminal.
4. Open the authorization URL in a web browser on your local machine.
5. Sign in with your Google Account to get an authorization code.
6. Copy the authorization code and paste it into the container terminal.
7. Stop the Antigravity CLI with `/exit`.
8. Start the headless daemon for Remote Control:

```bash
agy remote-control start --name "antigravity-remote-control"
```

9. Do a check of the daemon status and instance name:

```bash
agy remote-control status
```

10. Open `https://antigravity.google.com` in a web browser.
11. Sign in with the same Google Account.
12. Select your instance name in the instance switcher.

## SSH Access

The install script always installs and enables `openssh-server`, unlocks the `antigravity` account for key-based SSH authentication, and writes `/etc/ssh/sshd_config.d/50-antigravity.conf` with `PubkeyAuthentication yes`, `AllowTcpForwarding yes`, and `UsePAM yes`. This supports both standard terminal SSH sessions and the Antigravity App **Connect over SSH** feature (`antigravity@<container-ip>`).

You can authorize SSH access for the `antigravity` user in any of these ways:

- Set an SSH public key in `community-scripts` Advanced Settings (`SSH_AUTHORIZED_KEY`); keys in `/root/.ssh/authorized_keys` are also copied to `/home/antigravity/.ssh/authorized_keys`.
- Pass `ANTIGRAVITY_SSH_AUTHORIZED_KEY` and/or `ANTIGRAVITY_SSH_PASSWORD` before running the CT script:

```bash
ANTIGRAVITY_SSH_AUTHORIZED_KEY="ssh-ed25519 AAAA... user@host" bash -c "$(curl -fsSL https://raw.githubusercontent.com/gskbyte/proxmox-lxc-antigravity-remote-control/main/ct/proxmox-lxc-antigravity-remote-control.sh)"
```

- Enter an SSH public key (or optional password) when prompted during interactive container creation if no key was already provided.
- Authorize a key or set a password after installation from the Proxmox VE host:

```bash
pct exec <CTID> -- bash -c 'cat >>/home/antigravity/.ssh/authorized_keys' < ~/.ssh/id_ed25519.pub
pct exec <CTID> -- passwd antigravity
```

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

When you make the container, the CT script asks if you want to activate a LAN-isolation firewall on the Proxmox VE host. When the firewall is active, it sets `firewall=1` on `net0` and writes rules to `/etc/pve/firewall/<CTID>.fw`. The rules allow inbound SSH (TCP port 22), DHCP, IPv6 NDP, and outbound DNS, and drop all other inbound traffic. They also drop new outbound connections to these private and IPv4 link-local networks: `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `169.254.0.0/16`, `100.64.0.0/10`, and `fc00::/7` (established SSH return traffic continues to work via Proxmox connection tracking). If you enable the Proxmox container firewall (`firewall=1` on `net0`) without LAN isolation, the script also ensures an inbound TCP port 22 rule exists in `/etc/pve/firewall/<CTID>.fw`. In unattended runs, `ANTIGRAVITY_BLOCK_LAN` defaults to `no`.

> [!NOTE]
> If the Datacenter firewall is off, set **Firewall** to **Yes** under **Datacenter > Firewall > Options** so the container rules become active.

To set the firewall option without a prompt, set `ANTIGRAVITY_BLOCK_LAN` (`yes` or `no`) before you run the install command:

```bash
ANTIGRAVITY_BLOCK_LAN=yes bash -c "$(curl -fsSL https://raw.githubusercontent.com/gskbyte/proxmox-lxc-antigravity-remote-control/main/ct/proxmox-lxc-antigravity-remote-control.sh)"
```

To limit inbound SSH to one or more IP addresses or subnets (comma-separated), set `ANTIGRAVITY_ALLOW_SSH_FROM`:

```bash
ANTIGRAVITY_BLOCK_LAN=yes ANTIGRAVITY_ALLOW_SSH_FROM="192.168.1.50/32" bash -c "$(curl -fsSL https://raw.githubusercontent.com/gskbyte/proxmox-lxc-antigravity-remote-control/main/ct/proxmox-lxc-antigravity-remote-control.sh)"
```

To block all inbound SSH even when SSH is active, set `ANTIGRAVITY_ALLOW_SSH_FROM=none`.

## Repository Files

- `ct/proxmox-lxc-antigravity-remote-control.sh`: This script makes the LXC container on a Proxmox VE host, provisions SSH credentials for `antigravity`, updates the Antigravity CLI inside the container, and configures the optional Proxmox VE firewall while keeping SSH port 22 reachable.
- `install/proxmox-lxc-antigravity-remote-control-install.sh`: This script installs the necessary packages (including `openssh-server`), makes the `antigravity` user, configures SSH access, enables systemd user lingering, installs the Antigravity CLI, and writes default sandbox settings.
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
| SSH daemon drop-in | `/etc/ssh/sshd_config.d/50-antigravity.conf` |
| SSH authorized keys | `/home/antigravity/.ssh/authorized_keys` |
| Binary | `/home/antigravity/.local/bin/agy` |
| CLI settings file | `/home/antigravity/.gemini/antigravity-cli/settings.json` |
| Daemon config file | `/home/antigravity/.gemini/config/config.json` (`cliRemoteControlHostname`) |
| Systemd environment file | `/home/antigravity/.config/environment.d/10-antigravity.conf` |
| Systemd user service | `antigravity-cli-daemon.service` |
| Linger marker | `/var/lib/systemd/linger/antigravity` |
| Optional firewall rules (host) | `/etc/pve/firewall/<CTID>.fw` |
| Remote Control Dashboard | `https://antigravity.google.com` |
