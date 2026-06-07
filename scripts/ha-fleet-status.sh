#!/usr/bin/env bash
# Fleet status reporter - returns JSON with all device statuses
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
  IFS=':' read -r ip name dtype <<< "$entry"
  ping -c1 -W1 "$ip" &>/dev/null && status="online" || status="offline"
  $FIRST || echo -n ','
  FIRST=false
  echo -n "{\"ip\":\"$ip\",\"name\":\"$name\",\"type\":\"$dtype\",\"status\":\"$status\"}"
done
echo ']}'