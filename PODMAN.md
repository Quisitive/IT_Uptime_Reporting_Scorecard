# Running the IT Uptime & Security Scorecard Collector with Podman

This guide covers deploying the collector container with **Podman** in a typical IT
environment: a single Linux host (RHEL/Rocky/Alma/Fedora/Ubuntu) that runs the appliance
as an always-on service, persists its data, and receives syslog from your fleet.

Podman is a drop-in, daemonless alternative to Docker. The provided
[`Dockerfile`](Dockerfile) and [`docker-compose.yml`](docker-compose.yml) work unchanged —
Podman reads standard OCI images and Compose files.

---

## Contents
1. [Prerequisites](#1-prerequisites)
2. [Rootful vs. rootless (choosing a mode)](#2-rootful-vs-rootless)
3. [Quick start with Compose](#3-quick-start-with-compose)
4. [Quick start with plain `podman run`](#4-quick-start-with-plain-podman-run)
5. [Persistent data & config](#5-persistent-data--config)
6. [SELinux notes](#6-selinux-notes)
7. [Firewall](#7-firewall)
8. [Run as a systemd service (Quadlet)](#8-run-as-a-systemd-service-quadlet)
9. [Environment variables & secrets](#9-environment-variables--secrets)
10. [Updating the image](#10-updating-the-image)
11. [Logs & troubleshooting](#11-logs--troubleshooting)

---

## 1. Prerequisites

Install Podman (and the Compose front-end if you want to use the Compose file):

```bash
# RHEL / Rocky / Alma / Fedora
sudo dnf install -y podman podman-compose

# Ubuntu / Debian
sudo apt-get update && sudo apt-get install -y podman podman-compose
```

Verify:

```bash
podman --version
podman info | grep -i rootless
```

The collector needs three ports:

| Port | Proto | Purpose |
|---|---|---|
| `8080` | TCP | Scorecard UI + REST API (put a TLS reverse proxy in front to expose off-LAN) |
| `514`  | UDP | syslog from Linux hosts, SANs, network gear, WEF forwarders |
| `514`  | TCP | syslog (TCP) |

---

## 2. Rootful vs. rootless

Port `514` is a **privileged port (< 1024)**. This is the main decision point:

- **Rootful (recommended for the appliance).** Run Podman as root so the container can bind
  `514/udp` and `514/tcp` directly, matching what your syslog forwarders expect. Prefix the
  commands below with `sudo`.

- **Rootless.** Run as an unprivileged user for better isolation, but you must either:
  - map syslog to a high port and forward `514 → 5514` at the host/firewall, **or**
  - lower the unprivileged port floor once on the host:
    ```bash
    echo 'net.ipv4.ip_unprivileged_port_start=514' | sudo tee /etc/sysctl.d/99-podman-syslog.conf
    sudo sysctl --system
    ```

If you don't need syslog on `514` (UI/API only), rootless works out of the box.

---

## 3. Quick start with Compose

From the repo root (where `docker-compose.yml` lives):

```bash
# rootful (binds 514 directly)
sudo podman-compose up -d --build
```

- UI: `http://<server>:8080` → redirects to a login page.
- The first-run **admin password** is printed once in the logs unless you set
  `ADMIN_PASSWORD` in `docker-compose.yml`:
  ```bash
  sudo podman-compose logs collector
  ```
- Change it immediately under **Setup → Change password**.

Stop / restart:

```bash
sudo podman-compose restart collector
sudo podman-compose down
```

> `podman-compose` shells out to `podman`. If your distro ships Podman ≥ 4.x you can also use
> the built-in `podman compose` subcommand (note the space) with the same file.

---

## 4. Quick start with plain `podman run`

No Compose needed — build the image and run the container directly:

```bash
# 1. Build the image from the repo root
sudo podman build -t scorecard-collector:latest .

# 2. Create host directories for persistence
mkdir -p ./data

# 3. Run it (rootful; binds privileged 514)
sudo podman run -d \
  --name scorecard-collector \
  --restart unless-stopped \
  -p 8080:8080 \
  -p 514:514/udp \
  -p 514:514/tcp \
  -v ./data:/data:Z \
  -v ./config:/app/config:ro,Z \
  -e AUTH_ENABLED=true \
  scorecard-collector:latest
```

The `:Z` suffix relabels the volumes for SELinux (see §6). Omit it on non-SELinux hosts.

---

## 5. Persistent data & config

Everything that must survive a restart or upgrade lives in two bind mounts:

| Host path | Container path | Contents |
|---|---|---|
| `./data`   | `/data`        | SQLite DB (`scorecard.db`), `secrets.json`, generated reports |
| `./config` | `/app/config`  | `collector.json` — targets, SLAs, SANs (mounted read-only) |

- **Back up `./data`** on your normal schedule. It holds all history and stored credentials.
- Edit `config/collector.json` on the host, then restart the container to apply:
  ```bash
  sudo podman restart scorecard-collector
  ```

---

## 6. SELinux notes

On RHEL/Rocky/Alma/Fedora with SELinux enforcing, bind mounts are blocked unless relabeled.
Add `:Z` (private, per-container) to each volume, as shown above:

```bash
-v ./data:/data:Z -v ./config:/app/config:ro,Z
```

For the Compose file, add the label to each volume line, e.g. `./data:/data:Z`.

Check for denials if a mount appears empty inside the container:

```bash
sudo ausearch -m avc -ts recent
```

---

## 7. Firewall

Open the ports on the host firewall (adjust if you remapped syslog to a high port):

```bash
sudo firewall-cmd --permanent --add-port=8080/tcp
sudo firewall-cmd --permanent --add-port=514/udp
sudo firewall-cmd --permanent --add-port=514/tcp
sudo firewall-cmd --reload
```

> Only expose `8080` beyond the LAN through a **TLS reverse proxy** (nginx, HAProxy, Caddy).
> The app serves plain HTTP by design and expects TLS termination in front of it.

---

## 8. Run as a systemd service (Quadlet)

For an always-on appliance, let systemd manage the container so it starts at boot and
restarts on failure. Podman's **Quadlet** is the modern approach (Podman ≥ 4.4).

Create `/etc/containers/systemd/scorecard.container` (rootful, system-wide):

```ini
[Unit]
Description=IT Uptime & Security Scorecard Collector
After=network-online.target
Wants=network-online.target

[Container]
Image=scorecard-collector:latest
ContainerName=scorecard-collector
PublishPort=8080:8080
PublishPort=514:514/udp
PublishPort=514:514/tcp
Volume=/opt/scorecard/data:/data:Z
Volume=/opt/scorecard/config:/app/config:ro,Z
Environment=AUTH_ENABLED=true

[Service]
Restart=always

[Install]
WantedBy=multi-user.target default.target
```

Then reload and start:

```bash
# put your built image and host dirs in place first
sudo mkdir -p /opt/scorecard/data /opt/scorecard/config
sudo cp config/collector.json /opt/scorecard/config/

sudo systemctl daemon-reload
sudo systemctl start scorecard.service
sudo systemctl status scorecard.service
```

The service is named after the file (`scorecard.container` → `scorecard.service`). Manage it
like any unit: `systemctl restart|stop|status scorecard`.

> **Rootless service.** Place the file in `~/.config/containers/systemd/` instead, run
> `systemctl --user daemon-reload && systemctl --user start scorecard`, and enable
> `loginctl enable-linger $USER` so it survives logout. Remember the privileged-port
> caveat from §2 for syslog.

> **Older Podman (< 4.4)** without Quadlet: generate a unit from a running container with
> `podman generate systemd --new --name scorecard-collector` and install it under
> `/etc/systemd/system/`.

---

## 9. Environment variables & secrets

The same variables documented in [`docker-compose.yml`](docker-compose.yml) apply. Pass them
with `-e` on `podman run`, in the Compose `environment:` block, or as `Environment=` lines in
the Quadlet file. Common ones:

| Variable | Purpose |
|---|---|
| `ADMIN_PASSWORD` | Set the first-run admin password (else printed once to logs) |
| `AUTH_ENABLED` | `true` to require login (default) |
| `SYSLOG_UDP_PORT` / `SYSLOG_TCP_PORT` | Move syslog off 514 (e.g. `5514`) for rootless |
| `CONNECTOR_DEFENDER_ENABLED`, `GRAPH_*` | Microsoft Defender via Graph Security API |
| `CONNECTOR_AZUREMONITOR_ENABLED`, `AZURE_*` | Azure Monitor / Log Analytics |
| `SMTP_PASSWORD` | SMTP relay for reports & alerts |

For sensitive values, prefer **Podman secrets** over plain env vars:

```bash
printf '%s' 'super-secret' | sudo podman secret create graph_client_secret -
# then reference at run time
sudo podman run ... --secret graph_client_secret,type=env,target=GRAPH_CLIENT_SECRET ...
```

Connector credentials entered through the in-app wizards are stored in
`data/secrets.json` (mode 600) and take a back seat to matching env vars.

---

## 10. Updating the image

```bash
# rebuild from updated source
sudo podman build -t scorecard-collector:latest .

# recreate the container (data/config persist in the bind mounts)
sudo podman rm -f scorecard-collector
sudo podman run -d --name scorecard-collector ... scorecard-collector:latest
# or, under systemd:
sudo systemctl restart scorecard.service
```

Your `./data` and `./config` are untouched by rebuilds.

---

## 11. Logs & troubleshooting

```bash
# container logs (first-run admin password appears here)
sudo podman logs -f scorecard-collector

# is it running? which ports?
sudo podman ps

# exec a shell inside for inspection
sudo podman exec -it scorecard-collector sh

# systemd-managed logs
sudo journalctl -u scorecard.service -f
```

Common issues:

| Symptom | Fix |
|---|---|
| `bind: permission denied` on 514 | Run rootful, or lower `ip_unprivileged_port_start` / remap to 5514 (§2) |
| Empty `/data` or config inside container | Add SELinux `:Z` to the volumes (§6) |
| No syslog arriving | Open the host firewall for 514 udp/tcp (§7); confirm forwarders point at this host |
| Can't reach UI off-LAN | Front `8080` with a TLS reverse proxy (§7) |
| Container not starting at boot | Use the Quadlet/systemd service (§8), not just `--restart` |
