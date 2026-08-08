#!/usr/bin/env python3
import json
import subprocess
import sys


def run(cmd, timeout=15):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except Exception:
        return None


def wifi_state():
    r = run(["nmcli", "-t", "radio"])
    enabled = bool(r) and bool(r.stdout.splitlines()) and r.stdout.splitlines()[0].split(":")[0] == "enabled"

    active_ssid = None
    r = run(["nmcli", "-t", "-f", "DEVICE,TYPE,STATE,CONNECTION", "device", "status"])
    if r:
        for line in r.stdout.splitlines():
            parts = line.split(":")
            if len(parts) >= 4 and parts[1] == "wifi" and parts[2].startswith("connected"):
                active_ssid = parts[3]

    nets = {}
    saved = set()
    r = run(["nmcli", "-t", "-f", "NAME,TYPE", "connection", "show"])
    if r and r.returncode == 0:
        for line in r.stdout.splitlines():
            parts = line.split(":")
            if len(parts) == 2 and parts[1] == "802-11-wireless":
                saved.add(parts[0])

    r = run(["nmcli", "-t", "-f", "SSID,SIGNAL,SECURITY,CHAN,FREQ,RATE", "device", "wifi", "list"])
    if r and r.returncode == 0:
        for line in r.stdout.splitlines():
            parts = line.split(":")
            if len(parts) < 6:
                continue
            ssid, signal, sec = parts[0], parts[1], parts[2]
            if not ssid:
                continue
            signal = int(signal)
            if ssid not in nets or signal > nets[ssid]["signal"]:
                nets[ssid] = {"ssid": ssid, "signal": signal, "secured": sec != "", "security": sec, "active": ssid == active_ssid, "saved": ssid in saved, "chan": parts[3], "freq": parts[4], "rate": parts[5]}

    out = list(nets.values())
    out.sort(key=lambda n: (-n["active"], -n["signal"]))
    active = next((n for n in out if n["active"]), None)
    if active:
        active["ip"] = None
        active["gateway"] = None
        r = run(["nmcli", "-g", "IP4.ADDRESS,IP4.GATEWAY", "connection", "show", active["ssid"]])
        if r and r.returncode == 0:
            lines = r.stdout.strip().splitlines()
            active["ip"] = lines[0] if lines else None
            active["gateway"] = lines[1] if len(lines) > 1 else None
    return {"enabled": enabled, "active": active, "networks": out}


def wifi_iface():
    r = run(["nmcli", "-t", "-f", "DEVICE,TYPE,STATE", "device", "status"])
    if not r:
        return None
    for line in r.stdout.splitlines():
        parts = line.split(":")
        if len(parts) >= 3 and parts[1] == "wifi":
            return parts[0]
    return None


def lan_state():
    r = run(["nmcli", "-t", "-f", "DEVICE,TYPE,STATE,CONNECTION", "device", "status"])
    if not r:
        return {"connected": False, "speed": 0, "ip": None, "gateway": None}
    for line in r.stdout.splitlines():
        parts = line.split(":")
        if len(parts) >= 4 and parts[1] == "ethernet":
            if parts[2] == "connected":
                speed = 0
                s = run(["cat", f"/sys/class/net/{parts[0]}/speed"])
                if s and s.returncode == 0:
                    try:
                        speed = int(s.stdout.strip())
                    except ValueError:
                        speed = 0
                ip = gw = None
                s = run(["nmcli", "-g", "IP4.ADDRESS,IP4.GATEWAY", "connection", "show", parts[3]])
                if s and s.returncode == 0:
                    lines = s.stdout.strip().splitlines()
                    ip = lines[0] if lines else None
                    gw = lines[1] if len(lines) > 1 else None
                return {"connected": True, "speed": speed, "ip": ip, "gateway": gw, "iface": parts[0]}
            return {"connected": False, "speed": 0, "ip": None, "gateway": None}
    return {"connected": False, "speed": 0, "ip": None, "gateway": None}


def bt_state():
    enabled = False
    r = run(["bluetoothctl", "show"])
    if r and r.returncode == 0:
        for line in r.stdout.splitlines():
            if "Powered:" in line:
                enabled = "yes" in line
    devices = {}
    r = run(["bluetoothctl", "devices"])
    if r and r.returncode == 0:
        for line in r.stdout.splitlines():
            parts = line.split(" ", 2)
            if len(parts) == 3 and parts[0] == "Device":
                devices[parts[1]] = {"name": parts[2], "mac": parts[1], "connected": False}
    connected = set()
    r = run(["bluetoothctl", "devices", "Connected"])
    if r and r.returncode == 0:
        for line in r.stdout.splitlines():
            parts = line.split(" ", 2)
            if len(parts) == 3 and parts[0] == "Device":
                connected.add(parts[1])
    for mac, d in devices.items():
        d["connected"] = mac in connected
        d["battery"] = None
        if d["connected"]:
            r = run(["bluetoothctl", "info", mac], timeout=6)
            if r and r.returncode == 0:
                for line in r.stdout.splitlines():
                    if "Battery Percentage" in line:
                        try:
                            d["battery"] = int(line.split("(")[1].rstrip(")").strip())
                        except Exception:
                            d["battery"] = None
    return {"enabled": enabled, "devices": list(devices.values())}


def action(cmd, timeout=15):
    result = run(cmd, timeout=timeout)
    sys.exit(0 if result and result.returncode == 0 else 1)


def saved_state():
    r = run(["nmcli", "-t", "-f", "NAME,TYPE,DEVICE", "connection", "show"])
    if not r or r.returncode != 0:
        return []
    out = []
    for line in r.stdout.splitlines():
        parts = line.split(":")
        if len(parts) < 3:
            continue
        name, typ, dev = parts[0], parts[1], parts[2]
        if typ not in ("802-11-wireless", "802-3-ethernet"):
            continue
        method = ip = gw = dns = ""
        s = run(["nmcli", "-g", "ipv4.method,ipv4.addresses,ipv4.gateway,ipv4.dns", "connection", "show", name])
        if s and s.returncode == 0:
            lines = s.stdout.strip().splitlines()
            method = lines[0] if lines else ""
            ip = lines[1] if len(lines) > 1 else ""
            gw = lines[2] if len(lines) > 2 else ""
            dns = lines[3] if len(lines) > 3 else ""
        out.append({"name": name, "type": "wifi" if typ == "802-11-wireless" else "ethernet",
                    "active": dev != "", "method": method, "ip": ip, "gw": gw, "dns": dns})
    return out


def main():
    args = sys.argv[1:]
    if not args:
        print(json.dumps({"wifi": wifi_state(), "lan": lan_state(), "bt": bt_state(), "saved": saved_state()}))
        return
    a = args[0]
    if a == "--wifi-on":
        action(["nmcli", "radio", "wifi", "on"])
    elif a == "--wifi-off":
        action(["nmcli", "radio", "wifi", "off"])
    elif a == "--wifi-connect":
        iface = wifi_iface()
        if not iface:
            sys.exit(1)
        cmd = ["nmcli", "device", "wifi", "connect", args[1]]
        if "--psk" in args:
            cmd += ["password", args[args.index("--psk") + 1]]
        if "--ip" in args:
            cmd += ["ip4", args[args.index("--ip") + 1]]
        if "--gw" in args:
            cmd += ["gw4", args[args.index("--gw") + 1]]
        action(cmd)
    elif a == "--wifi-disconnect":
        iface = wifi_iface()
        if not iface:
            sys.exit(1)
        action(["nmcli", "device", "disconnect", iface])
    elif a == "--bt-scan":
        action(["bluetoothctl", "--timeout", "12", "scan", "on"], timeout=20)
    elif a == "--bt-on":
        action(["bluetoothctl", "power", "on"])
    elif a == "--bt-off":
        action(["bluetoothctl", "power", "off"])
    elif a == "--bt-connect":
        action(["bluetoothctl", "connect", args[1]])
    elif a == "--bt-disconnect":
        action(["bluetoothctl", "disconnect", args[1]])
    elif a == "--edit-conn":
        cmd = ["nmcli", "connection", "modify", args[1], "ipv4.method", args[args.index("--method") + 1]]
        if "--ip" in args:
            cmd += ["ipv4.addresses", args[args.index("--ip") + 1]]
        if "--gw" in args:
            cmd += ["ipv4.gateway", args[args.index("--gw") + 1]]
        if "--dns" in args:
            cmd += ["ipv4.dns", args[args.index("--dns") + 1]]
        result = run(cmd)
        if result and result.returncode == 0 and "--up" in args:
            result = run(["nmcli", "connection", "up", args[1]])
        sys.exit(0 if result and result.returncode == 0 else 1)
    elif a == "--conn-delete":
        action(["nmcli", "connection", "delete", args[1]])
    else:
        sys.exit(1)


if __name__ == "__main__":
    main()
