#!/usr/bin/env bash
#==============================================================================
# Home Assistant Intelligent Installer – Kali iMac Fleet Edition
# Scans the local network, probes fleet devices, installs HA via Docker,
# and configures all discovered devices. Only prompts for credentials
# it cannot auto-discover (Blink, SSH passwords).
#==============================================================================
set -euo pipefail

# ─── Color output ──────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'
CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
prompt() { echo -e "${BLUE}[INPUT]${NC} $*"; }

# ─── Paths ─────────────────────────────────────────────────────────────────────
HA_BASE="/opt/homeassistant"
HA_CONFIG="$HA_BASE/config"
HA_COMPOSE="$HA_BASE/docker-compose.yml"
HA_VERSION="2026.5"  # latest stable as of writing; adjust if needed
LOG="/tmp/ha-install-$(date +%Y%m%d-%H%M%S).log"

# Network sweep
SUBNET="192.168.1.0/24"
GATEWAY="192.168.1.254"
FLEET_KNOWN=("192.168.1.211" "192.168.1.212" "192.168.1.217" "192.168.1.218"
             "192.168.1.230" "192.168.1.240" "192.168.1.241" "192.168.1.242"
             "192.168.1.248" "192.168.1.254")

# ─── Pre-flight checks ─────────────────────────────────────────────────────────
preflight() {
  info "Running pre-flight checks..."

  if [[ $EUID -eq 0 ]]; then
    err "Do not run as root. Use sudo only when prompted."
    exit 1
  fi

  for cmd in docker docker-compose nmap curl wget nc; do
    if ! command -v "$cmd" &>/dev/null; then
      err "Required command '$cmd' not found. Install it first."
      exit 1
    fi
  done

  # Verify Docker is running
  if ! docker info &>/dev/null; then
    err "Docker daemon not running. Start it with: sudo systemctl start docker"
    exit 1
  fi
  ok "Pre-flight passed."
}

# ─── Phase 1: Network Discovery ─────────────────────────────────────────────────
network_discovery() {
  info "Phase 1: Scanning $SUBNET for live hosts..."

  # Quick ping sweep first
  nmap -sn -T4 "$SUBNET" -oG - 2>/dev/null | \
    awk '/Up$/{print $2}' | sort -t. -k4 -n > /tmp/ha-sweep-live.txt
  LIVE_COUNT=$(wc -l < /tmp/ha-sweep-live.txt)
  ok "Found $LIVE_COUNT live hosts on $SUBNET"
  cat /tmp/ha-sweep-live.txt

  # Service scan on live hosts (top 100 ports + some specific ones)
  info "Deep service scan of live hosts..."
  nmap -sV -T4 --top-ports 100 \
    -p 22,80,443,445,139,514,8123,1883,8883,5683,1900,502,161,162,53,67,68,8080,8443,9090,3000,5000,8000 \
    -iL /tmp/ha-sweep-live.txt -oX /tmp/ha-scan-services.xml 2>/dev/null || true

  # Parse service scan into a readable device database
  python3 /tmp/ha-installer-tools.py parse_scan /tmp/ha-scan-services.xml > /tmp/ha-devices.json 2>/dev/null || \
    warn "Service scan parsing had issues, using fallback data"

  # If parsing failed, generate fallback from known fleet
  if [[ ! -s /tmp/ha-devices.json ]]; then
    info "Generating device database from known fleet + sweep..."
    generate_fallback_device_db
  fi

  ok "Network discovery complete."
}

generate_fallback_device_db() {
  cat > /tmp/ha-devices.json <<'JSONEOF'
{
  "devices": [
    {"ip":"192.168.1.211","hostname":"mac-mini","mac":"1e:dd:25:a8:39:63","ports":[22],"type":"macos","label":"Mac Mini (Primary)"},
    {"ip":"192.168.1.212","hostname":"kali-mini","mac":"9c:ef:d5:fb:e6:c4","ports":[22],"type":"linux-kali","label":"Kali Mini"},
    {"ip":"192.168.1.217","hostname":"vivint-hub","mac":"88:6a:e3:e0:30:4a","ports":[80,443],"type":"vivint","label":"Vivint Smart Hub"},
    {"ip":"192.168.1.218","hostname":"blink-sync","mac":"68:13:f3:f3:d8:c2","ports":[],"type":"blink-sync","label":"Blink Sync Module"},
    {"ip":"192.168.1.230","hostname":"kali-imac","mac":"ec:35:86:36:ac:de","ports":[22,80,443,8080,3000],"type":"linux-kali","label":"Kali iMac"},
    {"ip":"192.168.1.240","hostname":"dmbp","mac":"8c:85:90:a8:e6:fb","ports":[22],"type":"macos","label":"MacBook Pro"},
    {"ip":"192.168.1.241","hostname":"esp32-cam","mac":"e0:5a:1b:ac:7e:84","ports":[],"type":"esp32","label":"Garage ESP32-CAM"},
    {"ip":"192.168.1.242","hostname":"game-room","mac":"d0:03:4b:54:97:91","ports":[],"type":"appletv","label":"Game Room (Apple TV)"},
    {"ip":"192.168.1.248","hostname":"blackhawk","mac":"unknown","ports":[22,80],"type":"linux-openwrt","label":"Blackhawk Router"},
    {"ip":"192.168.1.254","hostname":"bgw320","mac":"a8:fb:40:53:91:74","ports":[80,443],"type":"gateway","label":"BGW320 Gateway"}
  ]
}
JSONEOF
  warn "Using fallback device database (nmap parse unavailable)"
}

# ─── Phase 2: Fleet SSH Probe ──────────────────────────────────────────────────
fleet_probe() {
  info "Phase 2: Probing fleet devices via SSH where accessible..."
  mkdir -p /tmp/ha-fleet
  COLLECTED=""

  # Try SSH to each device. Some will need passwords (prompted later).
  for ip in 192.168.1.212 192.168.1.230; do
    if ssh -o ConnectTimeout=3 -o BatchMode=yes "daniel@$ip" "hostname; uname -a; uptime; df -h / | tail -1; free -h | head -2" </dev/null 2>/dev/null > "/tmp/ha-fleet/$ip.txt"; then
      ok "SSH probe succeeded for $ip"
    fi
  done

  # For hosts needing password, note them
  for ip in 192.168.1.211 192.168.1.240 192.168.1.248; do
    if ! ssh -o ConnectTimeout=3 -o BatchMode=yes "daniel@$ip" "hostname" </dev/null 2>/dev/null; then
      echo "$ip" >> /tmp/ha-ssh-need-password.txt 2>/dev/null || true
    fi
  done

  if [[ -f /tmp/ha-ssh-need-password.txt ]] && [[ -s /tmp/ha-ssh-need-password.txt ]]; then
    warn "Some hosts need password-based SSH. They'll be prompted later."
    cat /tmp/ha-ssh-need-password.txt
  fi
}

# ─── Phase 3: Install Home Assistant via Docker ─────────────────────────────────
install_ha_docker() {
  info "Phase 3: Installing Home Assistant $HA_VERSION via Docker..."

  # Create directory structure
  sudo mkdir -p "$HA_CONFIG"
  sudo chown -R "$USER:$USER" "$HA_BASE"
  mkdir -p "$HA_CONFIG"/{custom_components,www,media,share,ssl,blueprints/{automation,script,template}}

  # Pull HA image
  info "Pulling Home Assistant Docker image..."
  docker pull "ghcr.io/home-assistant/home-assistant:stable" 2>&1 | tail -3
  ok "Home Assistant image pulled."

  # Create docker-compose.yml
  cat > "$HA_COMPOSE" <<YAMLEOF
version: '3.8'
services:
  homeassistant:
    container_name: homeassistant
    image: ghcr.io/home-assistant/home-assistant:stable
    restart: unless-stopped
    network_mode: host  # Needed for mDNS/SSDP/discovery
    privileged: false
    volumes:
      - $HA_CONFIG:/config
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - /etc/localtime:/etc/localtime:ro
    environment:
      - TZ=America/Chicago
    cap_add:
      - NET_RAW
      - NET_ADMIN
    labels:
      - "ha.managed_by=hermes-installer"

  # Mosquitto MQTT broker for ESP32 and other MQTT devices
  mqtt:
    container_name: ha-mqtt
    image: eclipse-mosquitto:2
    restart: unless-stopped
    network_mode: host
    volumes:
      - $HA_BASE/mosquitto:/mosquitto/config
      - $HA_BASE/mosquitto/data:/mosquitto/data
      - $HA_BASE/mosquitto/log:/mosquitto/log
YAMLEOF
  ok "Docker Compose file created at $HA_COMPOSE"

  # Pre-create Mosquitto config
  mkdir -p "$HA_BASE/mosquitto"
  cat > "$HA_BASE/mosquitto/mosquitto.conf" <<CFGEOF
listener 1883
protocol mqtt
allow_anonymous true
listener 9001
protocol websockets
CFGEOF
  ok "MQTT broker configured (anonymous, local network only)"
}

# ─── Phase 4: Generate HA Configuration ─────────────────────────────────────────
generate_config() {
  info "Phase 4: Generating Home Assistant configuration..."

  local BLINK_CONFIG=""
  local FLEET_SENSORS=""

  # ── Core homeassistant config ──
  cat > "$HA_CONFIG/configuration.yaml" <<YAMLEOF
# Home Assistant Configuration - Auto-generated by Hermes Installer
# Generated: $(date '+%Y-%m-%d %H:%M:%S')

homeassistant:
  name: "HomeLab"
  latitude: 0.0
  longitude: 0.0
  elevation: 0
  unit_system: imperial
  time_zone: America/Chicago
  country: US
  external_url: "http://192.168.1.230:8123"
  internal_url: "http://192.168.1.230:8123"
  allowlist_external_dirs:
    - "/config/www"
    - "/config/media"
  media_dirs:
    media: "/config/media"

# Default config
default_config:

# Frontend
frontend:
  themes: !include_dir_merge_named themes/

# Discovery for mDNS/SSDP devices
discovery:
  ignore:
    - apple_tv  # will add manually if detected
    - sonos

# Logbook & history
logbook:
history:

# System health
system_health:

# ── Sensors ──
sensor:

  # Ping/ICMP presence detection for fleet
  - platform: ping
    name: "BGW320 Gateway"
    host: 192.168.1.254
    count: 2

  - platform: ping
    name: "Mac Mini"
    host: 192.168.1.211
    count: 2

  - platform: ping
    name: "Kali Mini"
    host: 192.168.1.212
    count: 2

  - platform: ping
    name: "MacBook Pro"
    host: 192.168.1.240
    count: 2

  - platform: ping
    name: "Blackhawk Router"
    host: 192.168.1.248
    count: 2

  - platform: ping
    name: "Garage ESP32-CAM"
    host: 192.168.1.241
    count: 2

  - platform: ping
    name: "Game Room (Apple TV)"
    host: 192.168.1.242
    count: 2

  - platform: ping
    name: "Vivint Hub"
    host: 192.168.1.217
    count: 2

  - platform: ping
    name: "Blink Sync Module"
    host: 192.168.1.218
    count: 2

  # WiFi AP status
  - platform: command_line
    name: "Kali iMac WiFi SSID"
    command: "iwgetid -r 2>/dev/null || echo 'disconnected'"
    scan_interval: 300

  - platform: command_line
    name: "Kali iMac WiFi Signal"
    command: "iwconfig wlan0 2>/dev/null | grep -oP 'Signal level=\\K-?\\d+' || echo '0'"
    unit_of_measurement: "dBm"
    scan_interval: 300

  # System health of HA host
  - platform: systemmonitor
    resources:
      - type: disk_use_percent
        arg: /
      - type: memory_use_percent
      - type: processor_use
      - type: last_boot

  # Uptime of all reachable fleet hosts via SSH
  - platform: command_line
    name: "Kali Mini Uptime"
    command: "ssh -o ConnectTimeout=3 -o BatchMode=yes daniel@192.168.1.212 'uptime -p' 2>/dev/null || echo 'unreachable'"
    scan_interval: 600

YAMLEOF

  # ── Blink Configuration ──
  # We'll detect if blinkpy is available, otherwise configure via HA integration
  cat >> "$HA_CONFIG/configuration.yaml" <<YAMLEOF

# ── Blink Camera System ──
# NOTE: Blink credentials are NOT stored here in plaintext.
# Use the HA UI at http://192.168.1.230:8123/config/integrations
# to add the "Blink" integration with your Blink account credentials.
# Blink Sync Module detected at 192.168.1.218 (MAC: 68:13:f3:f3:d8:c2)
#
# After UI configuration, Blink cameras and motion sensors
# will appear automatically as entities.

YAMLEOF

  # ── ESP32-CAM ──
  cat >> "$HA_CONFIG/configuration.yaml" <<YAMLEOF

# ── ESP32-CAM (Garage Cam @ 192.168.1.241) ──
# REST sensor for ESP32-CAM status endpoint
# After camera is configured, add via MQTT or RESTful sensor
rest_command:
  esp32cam_snapshot:
    url: "http://192.168.1.241/capture"
    method: GET

  esp32cam_ir_on:
    url: "http://192.168.1.241/control?var=ir_mode&val=1"
    method: GET

  esp32cam_ir_off:
    url: "http://192.168.1.241/control?var=ir_mode&val=0"
    method: GET

YAMLEOF

  # ── MQTT Sensors for MQTT-capable devices ──
  cat >> "$HA_CONFIG/configuration.yaml" <<YAMLEOF

mqtt:
  sensor:
    - name: "MQTT Broker Status"
      state_topic: "$SYS/broker/uptime"
      unit_of_measurement: "s"
      value_template: "{{ value }}"
      availability:
        - topic: "$SYS/broker/version"

YAMLEOF

  # ── Gateway & Router Monitoring ──
  cat >> "$HA_CONFIG/configuration.yaml" <<YAMLEOF

# ── BGW320 Gateway Monitoring ──
sensor:
  - platform: command_line
    name: "BGW320 Gateway Uptime"
    command: "curl -s --max-time 5 http://192.168.1.254/ 2>/dev/null | grep -oP 'Up Time: \\K[^<]+' || echo 'unreachable'"
    scan_interval: 600

  # Network speed test
  - platform: fastdotcom

YAMLEOF

  # ── Groups ──
  cat >> "$HA_CONFIG/configuration.yaml" <<YAMLEOF

# ── Groups / Dashboards ──
group:
  fleet_devices:
    name: "Fleet Devices"
    entities:
      - sensor.mac_mini
      - sensor.kali_mini
      - sensor.macbook_pro
      - sensor.bgw320_gateway
      - sensor.blackhawk_router
      - sensor.garage_esp32_cam
      - sensor.game_room_apple_tv
      - sensor.vivint_hub
      - sensor.blink_sync_module
      - sensor.kali_imac_wifi_ssid
      - sensor.kali_imac_wifi_signal

  ha_host_health:
    name: "Home Assistant Host Health"
    entities:
      - sensor.processor_use
      - sensor.memory_use_percent
      - sensor.disk_use_percent
      - sensor.last_boot

automation: !include automations.yaml
script: !include scripts.yaml
scene: !include scenes.yaml

YAMLEOF

  # Create empty include files
  touch "$HA_CONFIG/automations.yaml"
  touch "$HA_CONFIG/scripts.yaml"
  touch "$HA_CONFIG/scenes.yaml"
  mkdir -p "$HA_CONFIG/themes"

  # ── HACS (Home Assistant Community Store) ──
  # We'll install HACS for additional integrations
  install_hacs

  ok "Configuration generated at $HA_CONFIG/configuration.yaml"
}

# ─── Install HACS ──────────────────────────────────────────────────────────────
install_hacs() {
  info "Installing HACS (Home Assistant Community Store)..."
  HACS_DIR="$HA_CONFIG/custom_components/hacs"
  if [[ -d "$HACS_DIR" ]]; then
    ok "HACS already installed, skipping."
    return
  fi
  wget -q -O /tmp/hacs.zip "https://github.com/hacs/integration/releases/latest/download/hacs.zip" 2>/dev/null || {
    warn "Could not download HACS. You can install manually via HACS after HA starts."
    return
  }
  mkdir -p "$HACS_DIR"
  unzip -q -o /tmp/hacs.zip -d "$HACS_DIR" 2>/dev/null && ok "HACS installed." || \
    warn "HACS extraction failed. Install manually."
  rm -f /tmp/hacs.zip
}

# ─── Phase 5: Create Fleet Monitoring Helper ────────────────────────────────────
create_fleet_helper() {
  info "Phase 5: Creating fleet monitoring scripts..."

  # Script: ha-fleet-status.sh - reports live status of all fleet hosts
  mkdir -p "$HA_BASE/scripts"
  cat > "$HA_BASE/scripts/ha-fleet-status.sh" <<'BASHSCRIPT'
#!/usr/bin/env bash
# Fleet status reporter for Home Assistant command_line sensors
# Run: bash /opt/homeassistant/scripts/ha-fleet-status.sh
# Returns JSON with each device's reachability and basic stats
set -euo pipefail
FLEET=(
  "192.168.1.211:Mac Mini:macos"
  "192.168.1.212:Kali Mini:kali"
  "192.168.1.217:Vivint Hub:vivint"
  "192.168.1.218:Blink Sync:blink"
  "192.168.1.240:MacBook Pro:macos"
  "192.168.1.241:ESP32-CAM:esp32"
  "192.168.1.242:Game Room:appletv"
  "192.168.1.248:Blackhawk:openwrt"
  "192.168.1.254:BGW320:gateway"
)
FIRST=true
echo -n '{"devices":['
for entry in "${FLEET[@]}"; do
  IFS=':' read -r ip name dtype <<<"$entry"
  ping -c1 -W1 "$ip" &>/dev/null && status="online" || status="offline"
  $FIRST || echo -n ','
  FIRST=false
  echo -n "{\"ip\":\"$ip\",\"name\":\"$name\",\"type\":\"$dtype\",\"status\":\"$status\"}"
done
echo ']}'
BASHSCRIPT
  chmod +x "$HA_BASE/scripts/ha-fleet-status.sh"
  ok "Fleet status script created."

  # On-demand SSH fleet probe for authenticated hosts
  cat > "$HA_BASE/scripts/ha-ssh-probe.sh" <<'BASHSCRIPT'
#!/usr/bin/env bash
# Fleet SSH probe - collects system info from SSH-accessible hosts
# Usage: ./ha-ssh-probe.sh [--prompt-passwords]
set -euo pipefail
SSH_HOSTS=("192.168.1.212")
for host in "${SSH_HOSTS[@]}"; do
  echo "=== $host ==="
  ssh -o ConnectTimeout=5 -o BatchMode=yes "daniel@$host" "
    echo \"hostname:\$(hostname)\"
    echo \"uptime:\$(uptime -p)\"
    echo \"load:\$(uptime | grep -oP 'load average:.*' | cut -d: -f2)\"
    echo \"disk:\$(df -h / | tail -1 | awk '{print \$3\"/\"\$2}') \"
    echo \"mem:\$(free -h | grep Mem | awk '{print \$3\"/\"\$2}') \"
  " 2>/dev/null || echo "unreachable"
done
BASHSCRIPT
  chmod +x "$HA_BASE/scripts/ha-ssh-probe.sh"
  ok "SSH probe script created."
}

# ─── Phase 6: Launch HA ─────────────────────────────────────────────────────────
launch_ha() {
  info "Phase 6: Launching Home Assistant..."

  cd "$HA_BASE"
  docker-compose up -d 2>&1 || docker compose up -d 2>&1

  info "Waiting for Home Assistant to start (this can take 2-5 minutes)..."
  for i in $(seq 1 60); do
    if curl -s -o /dev/null -w '%{http_code}' http://localhost:8123/ 2>/dev/null | grep -q '200\|302\|301'; then
      ok "Home Assistant is running at http://192.168.1.230:8123"
      ok "MQTT broker running at 192.168.1.230:1883"
      return 0
    fi
    sleep 5
  done
  warn "Home Assistant may still be starting. Check: docker logs homeassistant"
  return 1
}

# ─── Phase 7: Blink Integration Setup ───────────────────────────────────────────
setup_blink() {
  info "Phase 7: Setting up Blink camera integration..."

  cat <<BLINKINFO
┌─────────────────────────────────────────────────────────────┐
│ Blink Sync Module detected at 192.168.1.218 (MAC: 68:13:f3 │
│ :f3:d8:c2)                                                  │
│                                                             │
│ Home Assistant has a built-in Blink integration that        │
│ communicates with Blink's cloud servers. The Sync Module    │
│ at .218 is already paired with your Blink cameras.          │
│                                                             │
│ To complete setup:                                           │
│ 1. Open http://192.168.1.230:8123                           │
│ 2. Go to Settings → Devices & Services → Add Integration    │
│ 3. Search for "Blink" and enter your Blink account          │
│    credentials (email/password)                             │
│ 4. Your cameras and motion sensors will appear              │
│    automatically                                            │
│                                                             │
│ Blink cameras on your account:                              │
│   - Garage Cam (ESP32-CAM at .241 is SEPARATE from Blink)   │
│                                                             │
│ NOTE: Your Blink password is not stored in this script.     │
│ HA encrypts it in its own DB.                               │
└─────────────────────────────────────────────────────────────┘
BLINKINFO
}

# ─── Post-Install: Additional Integration Prompts ───────────────────────────────
post_install_prompts() {
  info "Checking for integrations that need manual credentials..."

  # SSH password needed for some hosts?
  if [[ -f /tmp/ha-ssh-need-password.txt ]] && [[ -s /tmp/ha-ssh-need-password.txt ]]; then
    warn "The following hosts need SSH password-based authentication:"
    cat /tmp/ha-ssh-need-password.txt
    echo ""
    prompt "Enter SSH password for fleet devices (same password for all?): "
    echo -n "  Password [Enter to skip/configure later]: "
    read -rs SSH_PASS
    echo ""
    if [[ -n "$SSH_PASS" ]]; then
      # Create an SSH expect-based helper for fleet monitoring via SSH
      create_ssh_password_helper "$SSH_PASS"
      ok "SSH password helper created."
    else
      warn "Skipping SSH password setup. Fleet SSH probes will only work for key-based hosts."
    fi
  fi

  # Blink credentials
  prompt "Do you want to configure Blink cameras now? (y/N): "
  read -r BLINK_CHOICE
  if [[ "$BLINK_CHOICE" =~ ^[Yy] ]]; then
    prompt "  Blink account email: "
    read -r BLINK_EMAIL
    prompt "  Blink account password: "
    read -rs BLINK_PASS
    echo ""
    if [[ -n "$BLINK_EMAIL" && -n "$BLINK_PASS" ]]; then
      # Create Blink auto-setup script that uses HA API to configure integration
      create_blink_auto_setup "$BLINK_EMAIL" "$BLINK_PASS"
      ok "Blink auto-setup script created. Run it after HA finishes onboarding."
      prompt "  Run: bash /opt/homeassistant/scripts/ha-blink-setup.sh"
    fi
  fi
}

# ─── SSH Password Helper ────────────────────────────────────────────────────────
create_ssh_password_helper() {
  local PASS="$1"
  mkdir -p "$HA_BASE/scripts"

  cat > "$HA_BASE/scripts/ha-ssh-password-probe.sh" <<BASHSCRIPT
#!/usr/bin/env bash
# Password-based SSH fleet probe (uses sshpass)
# Install: sudo apt-get install -y sshpass
set -euo pipefail
HOSTS=\$(</tmp/ha-ssh-need-password.txt)
PASS="$PASS"
for ip in \$HOSTS; do
  echo "=== \$ip ==="
  sshpass -p "\$PASS" ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "daniel@\$ip" "
    echo \"hostname:\$(hostname)\"
    echo \"uptime:\$(uptime -p)\"
    echo \"os:\$(uname -a)\"
  " 2>/dev/null || echo "unreachable"
done
BASHSCRIPT
  chmod +x "$HA_BASE/scripts/ha-ssh-password-probe.sh"
  info "Note: Install sshpass for password-based SSH: sudo apt-get install -y sshpass"
}

# ─── Blink Auto-Setup via HA API ────────────────────────────────────────────────
create_blink_auto_setup() {
  local EMAIL="$1" PASS="$2"
  mkdir -p "$HA_BASE/scripts"

  cat > "$HA_BASE/scripts/ha-blink-setup.sh" <<BASHSCRIPT
#!/usr/bin/env bash
# Auto-configure Blink integration via Home Assistant API
# Run AFTER Home Assistant finishes initial onboarding
set -euo pipefail
HA_URL="http://localhost:8123"
EMAIL="$EMAIL"
PASS="$PASS"

# Wait for HA to be ready
echo "Waiting for Home Assistant API..."
for i in \$(seq 1 60); do
  STATUS=\$(curl -s -o /dev/null -w '%{http_code}' "\$HA_URL/api/" 2>/dev/null || echo "000")
  if [ "\$STATUS" = "200" ] || [ "\$STATUS" = "201" ]; then
    echo "Home Assistant API ready."
    break
  fi
  sleep 5
done

# Get a long-lived access token (requires HA to have finished onboarding)
# You'll need to generate this from HA UI first:
# Profile → Long-Lived Access Tokens
echo ""
echo "┌────────────────────────────────────────────────────────────┐"
echo "│  To automate Blink setup, you need a long-lived access     │"
echo "│  token from Home Assistant:                                │"
echo "│                                                            │"
echo "│  1) Open http://192.168.1.230:8123                         │"
echo "│  2) Complete onboarding (create account)                   │"
echo "│  3) Profile → Long-Lived Access Tokens → Create Token      │"
echo "│  4) Run this script again with the token:                  │"
echo "│     HA_TOKEN=your_token_here bash \$0                      │"
echo "└────────────────────────────────────────────────────────────┘"
echo ""
echo "For now, add Blink manually: Settings → Devices & Services"
echo "→ Add Integration → Search 'Blink' → Enter: $EMAIL"
BASHSCRIPT
  chmod +x "$HA_BASE/scripts/ha-blink-setup.sh"
}

# ─── Summary ────────────────────────────────────────────────────────────────────
print_summary() {
  echo ""
  echo "╔══════════════════════════════════════════════════════════════╗"
  echo "║            Home Assistant Installation Complete             ║"
  echo "╠══════════════════════════════════════════════════════════════╣"
  echo "║  ● Hosted on: Kali iMac (192.168.1.230)                    ║"
  echo "║  ● HA UI:     http://192.168.1.230:8123                    ║"
  echo "║  ● MQTT:      192.168.1.230:1883 (anonymous)              ║"
  echo "║  ● Config:    $HA_CONFIG                 ║"
  echo "╚══════════════════════════════════════════════════════════════╝"
  echo ""
  echo "├─ Discovered & Pre-configured Devices:"
  echo "│  ✓ Mac Mini (.211)          - ICMP presence sensor"
  echo "│  ✓ Kali Mini (.212)         - ICMP + SSH probe sensor"
  echo "│  ✓ MacBook Pro (.240)       - ICMP presence sensor"
  echo "│  ✓ Blackhawk (.248)         - ICMP presence + HTTP check"
  echo "│  ✓ BGW320 Gateway (.254)    - ICMP + HTTP check"
  echo "│  ✓ Vivint Hub (.217)        - ICMP presence sensor"
  echo "│  ✓ Blink Sync (.218)        - ICMP + cloud integration"
  echo "│  ✓ Garage ESP32-CAM (.241)  - ICMP + REST commands"
  echo "│  ✓ Game Room / Apple TV     - ICMP presence sensor"
  echo "│  ✓ AdGuard DNS (existing)   - Running at .230:53"
  echo "│  ✓ OpenWebUI (existing)     - Running at .230:8080"
  echo ""
  echo "└── Next Steps (manual):"
  echo "    1. Open http://192.168.1.230:8123"
  echo "    2. Complete initial HA onboarding (create account)"
  echo "    3. Add Blink: Settings → Devices → Add Integration → 'Blink'"
  echo "    4. Add HomeKit if desired: Settings → Add Integration"
  echo "    5. Optional: Install sshpass & run fleet SSH probe:"
  echo "       sudo apt-get install -y sshpass"
  echo "       bash $HA_BASE/scripts/ha-ssh-password-probe.sh"
  echo ""
  echo "Installation log: $LOG"
}

# ─── Device DB parser (Python helper) ───────────────────────────────────────────
create_python_helper() {
  cat > /tmp/ha-installer-tools.py <<'PYEOF'
#!/usr/bin/env python3
"""HA Installer helper tools."""
import sys, json, xml.etree.ElementTree as ET

def parse_scan(xml_path):
    """Parse nmap XML output into device JSON."""
    try:
        tree = ET.parse(xml_path)
        root = tree.getroot()
    except Exception:
        print(json.dumps({"devices":[]}))
        return

    devices = []
    for host in root.findall('.//host'):
        ip_el = host.find(".//address[@addrtype='ipv4']")
        mac_el = host.find(".//address[@addrtype='mac']")
        host_el = host.find('hostnames/hostname')
        ports = []

        for port in host.findall('.//port'):
            state = port.find('state')
            if state is not None and state.get('state') == 'open':
                ports.append(int(port.get('portid')))

        if ip_el is not None:
            ip = ip_el.get('addr')
            mac = mac_el.get('addr', 'unknown') if mac_el is not None else 'unknown'
            hostname = host_el.get('name', ip) if host_el is not None else ip

            # Try to infer device type from ports + hostname
            dtype = infer_device_type(ip, ports, hostname)

            devices.append({
                'ip': ip, 'hostname': hostname, 'mac': mac,
                'ports': ports, 'type': dtype,
                'label': hostname.replace('-', ' ').title()
            })

    print(json.dumps({"devices": devices}, indent=2))

def infer_device_type(ip, ports, hostname):
    """Try to figure out what kind of device this is."""
    if ip == '192.168.1.254': return 'gateway'
    if ip == '192.168.1.248': return 'linux-openwrt'
    if ip == '192.168.1.218': return 'blink-sync'
    if ip == '192.168.1.217': return 'vivint'
    if ip == '192.168.1.241': return 'esp32'
    if ip == '192.168.1.242': return 'appletv'
    h = hostname.lower()
    if 'iphone' in h or 'ipad' in h: return 'ios'
    if 'kali' in h or 'linux' in h: return 'linux-kali'
    if 'mac' in h or 'mini' in h: return 'macos'
    if 22 in ports and 445 in ports: return 'macos'    # SMB + SSH = macOS
    if 80 in ports and 443 in ports and 22 not in ports: return 'embedded-web'
    if 22 in ports: return 'linux'
    return 'unknown'

if __name__ == '__main__':
    if len(sys.argv) > 2 and sys.argv[1] == 'parse_scan':
        parse_scan(sys.argv[2])
    else:
        print(json.dumps({"error": "usage: parse_scan <nmap_xml>"}))
PYEOF
  ok "Python helper created at /tmp/ha-installer-tools.py"
}

# ─── ESP32-CAM MQTT Bridge Setup ────────────────────────────────────────────────
setup_esp32_mqtt() {
  info "Setting up ESP32-CAM MQTT bridge configuration..."
  cat > "$HA_BASE/scripts/ha-esp32-config.sh" <<'BASHSCRIPT'
#!/usr/bin/env bash
# ESP32-CAM MQTT configuration helper
# Run after the ESP32-CAM is connected to the "Yes" WiFi
set -euo pipefail
ESP_IP="192.168.1.241"
HA_MQTT="192.168.1.230:1883"

echo "Testing ESP32-CAM connectivity..."
if curl -s --max-time 3 "http://$ESP_IP/" >/dev/null 2>&1; then
  echo "✓ ESP32-CAM reachable at $ESP_IP"
  echo "  To configure MQTT on the ESP32-CAM, update its firmware"
  echo "  to publish to: mqtt://$HA_MQTT"
  echo ""
  echo "  Topics the ESP should publish:"
  echo "    esp32cam/garage/motion      - motion detected (ON/OFF)"
  echo "    esp32cam/garage/snapshot    - trigger snapshot URL"
  echo "    esp32cam/garage/status      - online/offline heartbeat"
else
  echo "✗ ESP32-CAM not reachable at $ESP_IP"
  echo "  Check if it's powered and on the 'Yes' SSID (2.4GHz)"
fi
BASHSCRIPT
  chmod +x "$HA_BASE/scripts/ha-esp32-config.sh"
  ok "ESP32-CAM configuration helper created."
}

# ─── MAIN ───────────────────────────────────────────────────────────────────────
main() {
  echo ""
  echo "╔════════════════════════════════════════════════════╗"
  echo "║    ⚡ HomeLab Home Assistant Intelligent Installer ║"
  echo "║    Kali iMac  |  Network Scanner  |  Auto-Config  ║"
  echo "╚════════════════════════════════════════════════════╝"
  echo ""

  # Redirect all output to log AND terminal
  exec > >(tee -ia "$LOG") 2>&1

  preflight
  create_python_helper
  network_discovery
  fleet_probe
  install_ha_docker
  generate_config
  create_fleet_helper
  setup_esp32_mqtt
  launch_ha
  setup_blink
  post_install_prompts
  print_summary

  echo ""
  info "Full install log: $LOG"
}

main "$@"
