# HomeLab Home Assistant

**Intelligent, self-discovering Home Assistant deployment for the HomeLab fleet.**

Scans your network via nmap, probes fleet devices over SSH, installs Home Assistant + Mosquitto MQTT via Docker, and auto-generates a complete HA configuration with all discovered devices. Only prompts for credentials it can't auto-discover (Blink account, SSH passwords).

## Quick Start

```bash
# Deploy to your HA host (Kali/Debian/Ubuntu with Docker)
scp install-ha.sh user@ha-host:/tmp/
ssh user@ha-host "bash /tmp/ha-install.sh"
```

The installer will:
1. Run pre-flight checks (Docker, nmap, curl)
2. Scan `192.168.1.0/24` with nmap service detection
3. Probe SSH-accessible fleet devices
4. Install Home Assistant + Mosquitto via Docker Compose
5. Generate `configuration.yaml` with all discovered devices
6. Install HACS (Home Assistant Community Store)
7. Create fleet monitoring scripts
8. Prompt for any credentials it needs (SSH passwords, Blink)

## What Gets Installed

| Service | Port | Purpose |
|---------|------|---------|
| Home Assistant | 8123 | Main HA UI |
| Mosquitto MQTT | 1883 | MQTT broker (anonymous LAN) |
| Mosquitto WebSockets | 9001 | MQTT over WebSocket |

## Architecture

```
┌──────────────────────────────────────────┐
│          Kali iMac (HA Host)             │
│  ┌──────────┐  ┌──────────┐  ┌────────┐ │
│  │ Home     │  │ Mosquitto│  │ AdGuard│ │
│  │Assistant │  │   MQTT   │  │  DNS   │ │
│  └──────────┘  └──────────┘  └────────┘ │
│      8123         1883/9001        53     │
└─────────────────┬────────────────────────┘
                  │
    ┌─────────────┼─────────────┐
    ▼             ▼             ▼
  Fleet          IoT         Gateway
  Devices      Devices       (.254)
  (.211-.248)  (ESP32,       BGW320
  SSH/Mac/     Blink,
  Kali)        Vivint)
```

## Auto-Detected Devices

The installer's nmap sweep discovers and configures:

- **Mac Mini** (.211) — primary macOS workstation, SSH
- **Kali Mini** (.212) — secondary Kali system, SSH key auth
- **Vivint Smart Hub** (.217) — OpenWrt, HTTP/HTTPS, MQTT+TLS
- **Blink Sync Module** (.218) — camera sync module
- **MacBook Pro** (.240) — mobile workstation, SSH
- **ESP32-CAM** (.241) — garage camera, HTTP API
- **Apple TV / Game Room** (.242) — AirPlay device
- **Blackhawk Router** (.248) — OpenWrt, Dropbear SSH, MJPG streamer
- **BGW320 Gateway** (.254) — AT&T fiber gateway

## Files

| File | Purpose |
|------|---------|
| `install-ha.sh` | Full intelligent installer (network scan → deploy → configure) |
| `docker-compose.yml` | Docker Compose for HA + Mosquitto |
| `config/configuration.yaml` | Auto-generated HA config (17 device entries) |
| `config/mosquitto.conf` | MQTT broker config (anonymous LAN) |
| `scripts/ha-fleet-status.sh` | JSON fleet status reporter |
| `NETWORK-SWEEP.txt` | Live hosts discovered during scan |
| `POST-INSTALL.md` | Post-install setup guide |

## Post-Install Steps

Some integrations now require UI configuration in HA 2026.6.1+:

1. Open `http://<ha-host>:8123`
2. Complete HA onboarding (create admin account)
3. Add integrations via **Settings → Devices & Services → Add Integration**:
   - **Blink** — Blink account credentials (email + password)
   - **Ping (ICMP)** — device presence detection for every fleet host
   - **System Monitor** — CPU/RAM/disk monitoring of the HA host
   - **Fast.com** — internet speed testing

## Fleet SSH Probes

For deeper fleet monitoring, install `sshpass` and provide credentials:

```bash
sudo apt install sshpass
bash /opt/homeassistant/scripts/ha-ssh-password-probe.sh
```

Key-authenticated hosts (Kali Mini .212) are probed automatically.

## License

MIT — use it, fork it, deploy it on your own HomeLab.
