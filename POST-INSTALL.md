# HomeLab Home Assistant - Post-Install Notes

## Access
- **HA UI:** http://192.168.1.230:8123
- **MQTT:** 192.168.1.230:1883 (anonymous, local only)
- **MQTT WS:** 192.168.1.230:9001

## First-Time Setup
1. Open http://192.168.1.230:8123 in a browser
2. Create your HA account (this is your admin account)
3. Name your home "HomeLab", set timezone America/Chicago
4. After onboarding, add integrations:

### Add via UI (Settings -> Devices & Services -> Add Integration):
| Integration       | Purpose                          |
|-------------------|----------------------------------|
| Ping (ICMP)       | Device presence detection        |
| System Monitor    | HA host CPU/RAM/disk             |
| Fast.com          | Internet speed testing           |
| Blink             | Camera system (email+password)   |

### Already configured (YAML):
| Feature           | Details                          |
|-------------------|----------------------------------|
| Command Line      | WiFi SSID, signal, fleet uptime  |
| MQTT              | Broker status + ESP32 support    |
| REST Command      | ESP32-CAM snapshot & IR control  |

## Fleet Scripts
- `ha-fleet-status.sh` - JSON status of all 9 key devices
- `ha-ssh-probe.sh` - SSH-based metrics from Kali Mini (.212)
- `ha-ssh-password-probe.sh` - (after `sudo apt install sshpass`) fleet SSH via password

## Tips
- Install HACS: Settings -> Add Integration -> search "HACS"
- Add entities to dashboard: Overview -> Edit Dashboard
- View all entities: Settings -> Devices & Services -> Entities

## ESP32-CAM MQTT
Configure garage cam firmware to publish to `mqtt://192.168.1.230:1883`
Topics:
- `esp32cam/garage/motion` - ON/OFF
- `esp32cam/garage/status` - heartbeat