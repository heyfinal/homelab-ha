#!/usr/bin/env python3
"""HA Admin Configurator v3 - final round of fixes."""
import requests, json, sys

with open("/tmp/ha-api-token.txt") as f:
    TOKEN = f.read().strip()
HA = "http://localhost:8123"
CE = "/api/config/config_entries"
H = {"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json"}

def api(m, path, d=None):
    r = requests.request(m, f"{HA}{path}", headers=H, json=d, timeout=10)
    try:
        return r.status_code, r.json() if r.text else {}
    except:
        return r.status_code, str(r.text)[:200]

def log(lbl, s, d=""):
    print(f"  {'✅' if s in(200,201) else '⚠️' if s<400 else '❌'} [{s}] {lbl} {str(d)[:80]}")

def flow(handler, step1=None, step2=None):
    c, r = api("POST", f"{CE}/flow", {"handler": handler})
    if c in (404, 409):
        return c==409, r.get("reason","")
    if r.get("type") in ("create_entry","abort"):
        return True, r.get("reason","ok")
    fid = r.get("flow_id")
    if step1:
        c, r = api("POST", f"{CE}/flow/{fid}", step1)
        if r.get("type")=="create_entry":
            return True, "created"
        if step2:
            fid2 = r.get("flow_id")
            c, r = api("POST", f"{CE}/flow/{fid2}", step2)
            return c in(200,201), r.get("reason","ok")
        return c in(200,201), r.get("reason","ok")
    return True, r.get("reason","ok")

print("═══ HomeLab HA - Final Configuration ═══\n")

# 1. Location
print("📍 Setting Austin, TX location...")
c, r = api("POST", "/api/config", {
    "latitude": 30.2672, "longitude": -97.7431, "elevation": 183,
    "unit_system": "metric", "time_zone": "America/Chicago", "country": "US", "name": "HomeLab"
})
log("Location", c)

# 2. Ping - host only (no name param)
print("\n📡 Adding Ping sensors (17 devices)...")
DEVS = ["192.168.1.211","192.168.1.212","192.168.1.216","192.168.1.217",
        "192.168.1.218","192.168.1.224","192.168.1.225","192.168.1.226",
        "192.168.1.227","192.168.1.240","192.168.1.241","192.168.1.242",
        "192.168.1.244","192.168.1.247","192.168.1.248","192.168.1.250","192.168.1.254"]
for ip in DEVS:
    ok, m = flow("ping", {"host": ip})
    log(f"Ping {ip}", 200 if ok else 400, m)

# 3. HomeKit (no filter)
print("\n🏠 Adding HomeKit Bridge...")
ok, m = flow("homekit")
log("HomeKit", 200 if ok else 400, m)

# 4. MQTT (broker + port only)
print("\n🔌 Configuring MQTT...")
c, entries = api("GET", f"{CE}/entry")
if any(e.get("domain")=="mqtt" for e in entries):
    log("MQTT", 200, "already done")
else:
    ok, m = flow("mqtt", {"broker":"127.0.0.1","port":1883})
    log("MQTT", 200 if ok else 400, m)

# 5. Scan for any remaining discoverable integrations
print("\n🔍 Scanning for additional integrations...")
for handler in ["apple_tv","roku","blink","hue","sonos"]:
    c, r = api("POST", f"{CE}/flow", {"handler": handler})
    if c == 200 and r.get("type") != "abort":
        log(f"Discovery: {handler}", 200)
    elif c == 409:
        pass  # already configured

# Report final state
print("\n" + "="*50)
c, entries = api("GET", f"{CE}/entry")
print(f"Final integrations: {len(entries)}")
for e in entries:
    state = "✅" if e.get("state")=="loaded" else "⏳"
    print(f"  {state} {e.get('domain')}: {e.get('title')}")

print("\n── Remaining Manual ──")
print("• Blink: Settings → Add Integration → 'Blink' → email + password")
print("• Apple TV / Fire TV: check Devices & Services after discovery scan")
print("• ESP32-CAM: point MQTT firmware at 192.168.1.230:1883")