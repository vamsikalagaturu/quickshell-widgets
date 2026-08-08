#!/usr/bin/env python3
"""nmcli-backed connection reader/writer + Cloudflare speedtest for the
quickshell network panel. Stdlib only. See the frozen CLI contract in
SPEC.md's "net.py CLI contract" section - both this file and the QML
frontend are written against that shape, so do not change any key name.
"""
import argparse
import ipaddress
import json
import os
import signal
import subprocess
import sys
import time

CACHE_FILE = os.path.expanduser("~/.cache/qs-speedtest.json")

# ---------------------------------------------------------------------------
# nmcli plumbing
# ---------------------------------------------------------------------------

TYPE_MAP = {"802-11-wireless": "wifi", "802-3-ethernet": "ethernet"}


def nmcli(args, timeout=15):
    """Run nmcli, return (returncode, stdout, stderr). Never raises."""
    try:
        r = subprocess.run(["nmcli"] + args, capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout, r.stderr
    except Exception as e:
        return 1, "", str(e)


def get_fields(uuid, fields, timeout=15):
    """nmcli -g <fields> connection show <uuid> for a SINGLE connection.

    nmcli's -g mode emits one line per requested field *only when every
    field belongs to a settings group that exists on this connection*. A
    whole group that doesn't apply to the connection's base type (e.g.
    asking for 802-3-ethernet.* on a wifi profile, or 802-1x.* on a
    profile with no 802.1x section) is dropped entirely rather than
    padded with blank lines - so a batch must only mix fields from
    groups guaranteed to be present. Callers are responsible for
    grouping fields that way; this just does strict index-based parsing
    of whatever comes back.
    """
    rc, out, err = nmcli(["-g", ",".join(fields), "connection", "show", uuid], timeout=timeout)
    if rc != 0:
        return None, err
    lines = out.split("\n")
    if lines and lines[-1] == "":
        lines = lines[:-1]
    return lines, err


def split_escaped(line, sep=":"):
    """Split an nmcli -t line on unescaped separators.

    nmcli -t escapes a literal separator inside a value as '\\:' -- BSSIDs
    come back as 'AA\\:BB\\:CC\\:DD\\:EE\\:FF'. A naive line.split(':')
    shreds them into six fields and desyncs every column after it.
    """
    out, cur, esc = [], [], False
    for ch in line:
        if esc:
            cur.append(ch)
            esc = False
        elif ch == "\\":
            esc = True
        elif ch == sep:
            out.append("".join(cur))
            cur = []
        else:
            cur.append(ch)
    out.append("".join(cur))
    return out


SCAN_FIELDS = ["IN-USE", "SSID", "BSSID", "SIGNAL", "SECURITY", "CHAN", "FREQ", "RATE", "MODE"]


def cmd_scan():
    """Per-AP detail for the wifi scan list.

    Quickshell's WifiNetwork only exposes name/signalStrength/security/
    known/connected -- there is no BSSID, channel, frequency or rate on
    the DBus side, so viewing an AP's details without connecting to it
    has to come from here.
    """
    rc, out, err = nmcli(["-t", "-f", ",".join(SCAN_FIELDS), "device", "wifi", "list"])
    if rc != 0:
        print(err.strip() or "wifi scan failed", file=sys.stderr)
        sys.exit(1)

    saved = {}
    rc2, out2, _ = nmcli(["-t", "-f", "NAME,UUID,TYPE", "connection", "show"])
    if rc2 == 0:
        for line in out2.splitlines():
            parts = split_escaped(line)
            if len(parts) >= 3 and parts[2] == "802-11-wireless":
                saved[parts[0]] = parts[1]

    nets = []
    for line in out.splitlines():
        p = split_escaped(line)
        if len(p) < len(SCAN_FIELDS):
            continue
        ssid = p[1]
        if not ssid:
            continue  # hidden AP, nothing to show or act on
        freq = p[6]
        try:
            band = "5 GHz" if int(freq.split()[0]) >= 4900 else "2.4 GHz"
        except (ValueError, IndexError):
            band = ""
        nets.append({
            "ssid": ssid,
            "bssid": p[2],
            "signal": to_int(p[3]),
            "security": p[4] or "Open",
            "secured": bool(p[4]),
            "chan": p[5],
            "freq": freq,
            "band": band,
            "rate": p[7],
            "mode": p[8],
            "active": p[0] == "*",
            "saved": ssid in saved,
            "uuid": saved.get(ssid, ""),
        })

    # strongest first, active pinned to top; dedupe SSIDs to their best AP
    best = {}
    for n in nets:
        cur = best.get(n["ssid"])
        if cur is None or n["signal"] > cur["signal"]:
            best[n["ssid"]] = n
    out_list = sorted(best.values(), key=lambda n: (-n["active"], -n["signal"]))
    print(json.dumps(out_list))


def cmd_active():
    """Live per-device connection info, keyed by interface name.

    `nmcli -t device show` prints FIELD:value one per line and, unlike
    `device wifi list`, does NOT escape the colons inside a HWADDR or an
    IPv6 address -- so split on the FIRST colon only and keep the rest
    verbatim. Indexed fields arrive as IP4.ADDRESS[1], IP4.DNS[1], ...
    """
    rc, out, err = nmcli(["-t", "device", "show"])
    if rc != 0:
        print(err.strip() or "device show failed", file=sys.stderr)
        sys.exit(1)

    devices = {}
    cur = None
    for line in out.splitlines():
        if ":" not in line:
            continue
        key, val = line.split(":", 1)
        key = key.strip()
        base = key.split("[")[0]
        if base == "GENERAL.DEVICE":
            cur = {"iface": val, "type": "", "mac": "", "conn": "", "state": "",
                   "ip4": [], "gw4": "", "dns": [], "ip6": []}
            devices[val] = cur
            continue
        if cur is None:
            continue
        if base == "GENERAL.TYPE":
            cur["type"] = val
        elif base == "GENERAL.HWADDR":
            cur["mac"] = val
        elif base == "GENERAL.CONNECTION":
            cur["conn"] = "" if val in ("--", "") else val
        elif base == "GENERAL.STATE":
            cur["state"] = val
        elif base == "IP4.ADDRESS":
            cur["ip4"].append(val)
        elif base == "IP4.GATEWAY":
            cur["gw4"] = "" if val == "--" else val
        elif base == "IP4.DNS":
            cur["dns"].append(val)
        elif base == "IP6.ADDRESS":
            cur["ip6"].append(val)

    # Only real wifi/ethernet devices. Docker's veth pairs are also typed
    # "ethernet" by NM, so type alone isn't enough -- they're all reported
    # unmanaged ("10 (unmanaged)"), which is the semantic filter rather
    # than pattern-matching interface names.
    out_map = {
        k: v for k, v in devices.items()
        if v["type"] in ("wifi", "ethernet") and "unmanaged" not in v["state"]
    }
    print(json.dumps(out_map))


def norm_bool(v, default=False):
    """Normalize nmcli's various boolean spellings to a real bool.

    nmcli accepts/reports: yes/no, true/false, on/off, 1/0, and "" or
    "-1"/"unknown"/"default" as NM's "unset, use default" sentinels.
    """
    if v is None:
        return default
    s = str(v).strip().lower()
    if s in ("yes", "true", "on", "1"):
        return True
    if s in ("no", "false", "off", "0"):
        return False
    return default


def norm_metered(v):
    v = (v or "").strip().lower()
    if v == "unknown" or v == "":
        return "auto"
    return v


def to_int(v, default=0):
    v = (v or "").strip()
    if v in ("", "auto", "default", "-1"):
        return default
    try:
        return int(v)
    except ValueError:
        return default


# ---------------------------------------------------------------------------
# conns
# ---------------------------------------------------------------------------

def cmd_conns():
    rc, out, err = nmcli(["-g", "NAME,UUID,TYPE,DEVICE,AUTOCONNECT,AUTOCONNECT-PRIORITY", "connection", "show"])
    if rc != 0:
        print(err or "nmcli connection show failed", file=sys.stderr)
        sys.exit(1)

    result = []
    for line in out.splitlines():
        parts = line.split(":")
        if len(parts) < 6:
            continue
        name, uuid, ctype, device, autoconnect, priority = parts[0], parts[1], parts[2], parts[3], parts[4], parts[5]
        if ctype not in TYPE_MAP:
            continue
        # metered + eap need a per-connection query; both live in groups
        # that always exist (connection.*) / may not (802-1x.*), but
        # 802-1x.eap alone is safe to batch here since a missing group
        # just makes the *whole* batch short one line, which we detect.
        lines, _ = get_fields(uuid, ["connection.metered", "802-1x.eap"])
        metered_raw = lines[0] if lines else ""
        eap_raw = lines[1] if lines and len(lines) > 1 else ""
        result.append({
            "uuid": uuid,
            "name": name,
            "type": TYPE_MAP[ctype],
            "device": device,
            "active": device != "",
            "autoconnect": norm_bool(autoconnect, True),
            "priority": to_int(priority, 0),
            "metered": norm_metered(metered_raw),
            "eap": bool(eap_raw),
        })
    print(json.dumps(result))


# ---------------------------------------------------------------------------
# show
# ---------------------------------------------------------------------------

def cmd_show(uuid):
    type_lines, err = get_fields(uuid, ["connection.type", "connection.id"])
    if type_lines is None or len(type_lines) < 2:
        print(f"unknown connection {uuid}: {err}".strip(), file=sys.stderr)
        sys.exit(1)
    ctype, name = type_lines[0], type_lines[1]
    if ctype not in TYPE_MAP:
        print(f"connection {uuid} is type {ctype!r}, not wifi/ethernet", file=sys.stderr)
        sys.exit(1)
    kind = TYPE_MAP[ctype]

    ipv4_lines, _ = get_fields(uuid, [
        "ipv4.method", "ipv4.addresses", "ipv4.gateway", "ipv4.dns",
        "ipv4.dns-search", "ipv4.ignore-auto-dns", "ipv4.route-metric", "ipv4.never-default",
    ])
    ipv4_lines = ipv4_lines or [""] * 8

    ipv6_lines, _ = get_fields(uuid, [
        "ipv6.method", "ipv6.addresses", "ipv6.gateway", "ipv6.dns",
        "ipv6.addr-gen-mode", "ipv6.ip6-privacy",
    ])
    ipv6_lines = ipv6_lines or [""] * 6

    conn_lines, _ = get_fields(uuid, [
        "connection.autoconnect", "connection.autoconnect-priority",
        "connection.metered", "connection.zone", "connection.interface-name",
    ])
    conn_lines = conn_lines or [""] * 5

    # link + wifi-only fields must be queried per-type: the *other*
    # type's settings group doesn't exist on this profile and nmcli
    # drops it silently rather than padding with blanks (see get_fields
    # docstring), which would desync a mixed batch.
    if kind == "wifi":
        wifi_group, _ = get_fields(uuid, [
            "802-11-wireless.mtu", "802-11-wireless.cloned-mac-address",
            "802-11-wireless.hidden", "802-11-wireless.bssid",
            "802-11-wireless.band", "802-11-wireless.channel", "802-11-wireless.powersave",
        ])
        wifi_group = wifi_group or [""] * 7
        mtu_raw, cloned_mac = wifi_group[0], wifi_group[1]
        wifi = {
            "hidden": norm_bool(wifi_group[2], False),
            "bssid": wifi_group[3],
            "band": wifi_group[4],
            "channel": to_int(wifi_group[5], 0),
            "powersave": wifi_group[6] or "default",
        }
    else:
        eth_group, _ = get_fields(uuid, ["802-3-ethernet.mtu", "802-3-ethernet.cloned-mac-address"])
        eth_group = eth_group or [""] * 2
        mtu_raw, cloned_mac = eth_group[0], eth_group[1]
        wifi = {"hidden": False, "bssid": "", "band": "", "channel": 0, "powersave": "default"}

    eap_lines, _ = get_fields(uuid, ["802-1x.eap"])
    eap_val = eap_lines[0] if eap_lines else ""
    eap = bool(eap_val)

    out = {
        "uuid": uuid,
        "name": name,
        "type": kind,
        "eap": eap,
        "ipv4": {
            "method": ipv4_lines[0] or "auto",
            "addresses": ipv4_lines[1],
            "gateway": ipv4_lines[2],
            "dns": ipv4_lines[3],
            "dns_search": ipv4_lines[4],
            "ignore_auto_dns": norm_bool(ipv4_lines[5], False),
            "route_metric": ipv4_lines[6],
            "never_default": norm_bool(ipv4_lines[7], False),
        },
        "ipv6": {
            "method": ipv6_lines[0] or "auto",
            "addresses": ipv6_lines[1],
            "gateway": ipv6_lines[2],
            "dns": ipv6_lines[3],
            "addr_gen_mode": ipv6_lines[4] or "stable-privacy",
            "ip6_privacy": ipv6_lines[5] or "-1",
        },
        "conn": {
            "autoconnect": norm_bool(conn_lines[0], True),
            "priority": to_int(conn_lines[1], 0),
            "metered": norm_metered(conn_lines[2]),
            "zone": conn_lines[3],
            "interface": conn_lines[4],
        },
        "link": {
            "mtu": to_int(mtu_raw, 0),
            "cloned_mac": cloned_mac,
        },
        "wifi": wifi,
    }

    if eap:
        rest, _ = get_fields(uuid, ["802-1x.identity", "802-1x.phase2-auth"])
        rest = rest or ["", ""]
        out["eap_info"] = {"eap": eap_val, "identity": rest[0], "phase2": rest[1]}

    print(json.dumps(out))


# ---------------------------------------------------------------------------
# apply
# ---------------------------------------------------------------------------

# flag -> (nmcli property, kind). "link" kinds get resolved to the
# profile's actual type-specific property at apply time.
FLAG_TABLE = {
    "ipv4-method": ("ipv4.method", "ipv4-method"),
    "ipv4-addresses": ("ipv4.addresses", "ipv4-cidr-list"),
    "ipv4-gateway": ("ipv4.gateway", "ipv4-addr"),
    "ipv4-dns": ("ipv4.dns", "ipv4-addr-list"),
    "ipv4-dns-search": ("ipv4.dns-search", "str"),
    "ipv4-ignore-auto-dns": ("ipv4.ignore-auto-dns", "bool"),
    "ipv4-route-metric": ("ipv4.route-metric", "int"),
    "ipv4-never-default": ("ipv4.never-default", "bool"),
    "ipv6-method": ("ipv6.method", "ipv6-method"),
    "ipv6-addresses": ("ipv6.addresses", "ipv6-cidr-list"),
    "ipv6-gateway": ("ipv6.gateway", "ipv6-addr"),
    "ipv6-dns": ("ipv6.dns", "ipv6-addr-list"),
    "ipv6-addr-gen-mode": ("ipv6.addr-gen-mode", "str"),
    "ipv6-privacy": ("ipv6.ip6-privacy", "str"),
    "autoconnect": ("connection.autoconnect", "bool"),
    "priority": ("connection.autoconnect-priority", "int"),
    "metered": ("connection.metered", "str"),
    "zone": ("connection.zone", "str"),
    "mtu": (None, "int"),          # resolved by type below
    "cloned-mac": (None, "str"),   # resolved by type below
    "hidden": ("802-11-wireless.hidden", "bool"),
    "bssid": ("802-11-wireless.bssid", "str"),
    "band": ("802-11-wireless.band", "str"),
    "channel": ("802-11-wireless.channel", "int"),
    "powersave": ("802-11-wireless.powersave", "str"),
}

IPV4_METHODS = {"auto", "manual", "disabled", "shared", "link-local"}
IPV6_METHODS = {"auto", "dhcp", "manual", "disabled", "ignore", "shared", "link-local"}


class ValidationError(Exception):
    pass


def _split_nonempty(s):
    return [p.strip() for p in s.split(",") if p.strip()]


def validate_int(flag, val):
    try:
        int(val)
    except (TypeError, ValueError):
        raise ValidationError(f"--{flag}: {val!r} is not an integer")


def validate_cidr_list(flag, val, want_version):
    for item in _split_nonempty(val):
        try:
            iface = ipaddress.ip_interface(item)
        except ValueError:
            raise ValidationError(f"--{flag}: {item!r} is not a valid CIDR address")
        if iface.version != want_version:
            raise ValidationError(f"--{flag}: {item!r} is IPv{iface.version}, expected IPv{want_version}")


def validate_addr(flag, val, want_version):
    if not val:
        return
    try:
        addr = ipaddress.ip_address(val)
    except ValueError:
        raise ValidationError(f"--{flag}: {val!r} is not a valid IP address")
    if addr.version != want_version:
        raise ValidationError(f"--{flag}: {val!r} is IPv{addr.version}, expected IPv{want_version}")


def validate_addr_list(flag, val, want_version):
    for item in _split_nonempty(val):
        validate_addr(flag, item, want_version)


def build_modify_args(uuid, flags, profile_type):
    """Validate `flags` (dict of flag-name -> raw string value, plus
    boolean presence for --reactivate) and return the nmcli
    `connection modify` property/value pairs to apply. Raises
    ValidationError on anything that looks unsafe; never touches
    802-1x.* (there is no flag that maps there).
    """
    reactivate = flags.pop("reactivate", False)

    unknown = set(flags) - set(FLAG_TABLE)
    if unknown:
        raise ValidationError("unknown flag(s): " + ", ".join(sorted("--" + u for u in unknown)))

    # mtu/cloned-mac live on different properties depending on the
    # profile's actual link type - resolve those two here.
    mtu_prop = ("802-11-wireless.mtu" if profile_type == "wifi" else "802-3-ethernet.mtu")
    mac_prop = ("802-11-wireless.cloned-mac-address" if profile_type == "wifi" else "802-3-ethernet.cloned-mac-address")

    if flags.get("ipv4-method") == "manual" and not flags.get("ipv4-addresses"):
        raise ValidationError("--ipv4-method manual requires --ipv4-addresses")
    if flags.get("ipv6-method") == "manual" and not flags.get("ipv6-addresses"):
        raise ValidationError("--ipv6-method manual requires --ipv6-addresses")

    pairs = []
    for flag, val in flags.items():
        prop, kind = FLAG_TABLE[flag]
        if flag == "mtu":
            prop = mtu_prop
        elif flag == "cloned-mac":
            prop = mac_prop

        if kind == "int":
            validate_int(flag, val)
            out_val = str(int(val))
        elif kind == "bool":
            out_val = "yes" if norm_bool(val, False) else "no"
        elif kind == "ipv4-method":
            if val not in IPV4_METHODS:
                raise ValidationError(f"--{flag}: {val!r} not one of {sorted(IPV4_METHODS)}")
            out_val = val
        elif kind == "ipv6-method":
            if val not in IPV6_METHODS:
                raise ValidationError(f"--{flag}: {val!r} not one of {sorted(IPV6_METHODS)}")
            out_val = val
        elif kind == "ipv4-cidr-list":
            validate_cidr_list(flag, val, 4)
            out_val = val
        elif kind == "ipv6-cidr-list":
            validate_cidr_list(flag, val, 6)
            out_val = val
        elif kind == "ipv4-addr":
            validate_addr(flag, val, 4)
            out_val = val
        elif kind == "ipv6-addr":
            validate_addr(flag, val, 6)
            out_val = val
        elif kind == "ipv4-addr-list":
            validate_addr_list(flag, val, 4)
            out_val = val
        elif kind == "ipv6-addr-list":
            validate_addr_list(flag, val, 6)
            out_val = val
        else:
            out_val = val

        pairs.append((prop, out_val))

    return pairs, reactivate


def cmd_apply(uuid, raw_flags):
    type_lines, err = get_fields(uuid, ["connection.type"])
    if not type_lines:
        print(f"unknown connection {uuid}: {err}".strip(), file=sys.stderr)
        sys.exit(1)
    ctype = type_lines[0]
    if ctype not in TYPE_MAP:
        print(f"connection {uuid} is type {ctype!r}, not wifi/ethernet", file=sys.stderr)
        sys.exit(1)
    profile_type = TYPE_MAP[ctype]

    try:
        pairs, reactivate = build_modify_args(uuid, dict(raw_flags), profile_type)
    except ValidationError as e:
        print(f"apply rejected: {e}", file=sys.stderr)
        sys.exit(1)

    if not pairs and not reactivate:
        print("apply: nothing to do", file=sys.stderr)
        sys.exit(1)

    if pairs:
        cmd = ["connection", "modify", uuid]
        for prop, val in pairs:
            cmd += [prop, val]
        rc, out, err = nmcli(cmd)
        if rc != 0:
            print(err.strip() or "nmcli connection modify failed", file=sys.stderr)
            sys.exit(1)

    if reactivate:
        rc, out, err = nmcli(["connection", "up", uuid], timeout=30)
        if rc != 0:
            print(err.strip() or "nmcli connection up failed", file=sys.stderr)
            sys.exit(1)

    sys.exit(0)


def parse_apply_argv(argv):
    """--flag value pairs (and the bare --reactivate flag) -> dict."""
    flags = {}
    i = 0
    while i < len(argv):
        tok = argv[i]
        if not tok.startswith("--"):
            raise ValidationError(f"unexpected argument {tok!r}")
        name = tok[2:]
        if name == "reactivate":
            flags["reactivate"] = True
            i += 1
            continue
        if i + 1 >= len(argv):
            raise ValidationError(f"--{name} requires a value")
        flags[name] = argv[i + 1]
        i += 2
    return flags


# ---------------------------------------------------------------------------
# speedtest
# ---------------------------------------------------------------------------

_STOP = False


def _handle_signal(signum, frame):
    global _STOP
    _STOP = True


def _emit(obj):
    print(json.dumps(obj), flush=True)


def _save_cache(result):
    items = []
    try:
        with open(CACHE_FILE) as f:
            items = json.load(f)
        if not isinstance(items, list):
            items = []
    except Exception:
        items = []
    items.append(result)
    items = items[-50:]
    try:
        os.makedirs(os.path.dirname(CACHE_FILE), exist_ok=True)
        with open(CACHE_FILE, "w") as f:
            json.dump(items, f)
    except Exception:
        pass  # cache is best-effort, never fail the run over it


def _run_speedtest(duration, do_upload):
    import http.client

    host = "speed.cloudflare.com"
    colo = ""

    # --- meta / colo (best effort only, never fatal) ---
    try:
        conn = http.client.HTTPSConnection(host, timeout=10)
        conn.request("GET", "/__down?bytes=0")
        resp = conn.getresponse()
        resp.read()
        # Spec says "cf-meta-colo"; live responses from this host currently
        # send a bare "colo" header instead (Cloudflare edge behavior can
        # drift) - try both, best-effort either way.
        colo = resp.getheader("cf-meta-colo", "") or resp.getheader("colo", "") or ""
        conn.close()
    except Exception:
        colo = ""
    _emit({"phase": "meta", "colo": colo, "ip": ""})

    if _STOP:
        return

    # --- latency: 20x GET /__down?bytes=0 on one kept-alive connection ---
    rtts = []
    try:
        conn = http.client.HTTPSConnection(host, timeout=10)
        n = 20
        for i in range(n):
            if _STOP:
                conn.close()
                return
            t0 = time.monotonic()
            conn.request("GET", "/__down?bytes=0")
            resp = conn.getresponse()
            resp.read()
            rtts.append((time.monotonic() - t0) * 1000.0)
            ms = min(rtts)
            jitter = _jitter(rtts)
            _emit({"phase": "latency", "pct": (i + 1) / n, "ms": ms, "jitter": jitter})
        conn.close()
    except Exception as e:
        _emit({"phase": "error", "msg": f"latency: {e}"})
        sys.exit(1)

    ping_ms = min(rtts) if rtts else 0.0
    jitter_ms = _jitter(rtts)

    if _STOP:
        return

    # --- download ramp ---
    down_mbps = 0.0
    try:
        down_mbps = _download(host, duration)
    except Exception as e:
        _emit({"phase": "error", "msg": f"download: {e}"})
        sys.exit(1)

    if _STOP:
        return

    # --- upload ramp ---
    up_mbps = 0.0
    if do_upload:
        try:
            up_mbps = _upload(host, duration)
        except Exception as e:
            _emit({"phase": "error", "msg": f"upload: {e}"})
            sys.exit(1)

    result = {
        "down": round(down_mbps, 2),
        "up": round(up_mbps, 2),
        "ping": round(ping_ms, 2),
        "jitter": round(jitter_ms, 2),
        "colo": colo,
        "ts": int(time.time()),
    }
    _emit({"phase": "done", **result})
    _save_cache(result)


def _jitter(rtts):
    if len(rtts) < 2:
        return 0.0
    diffs = [abs(rtts[i] - rtts[i - 1]) for i in range(1, len(rtts))]
    return sum(diffs) / len(diffs)


_SIZE_RAMP = [1_000_000, 10_000_000, 25_000_000, 100_000_000]
_UPLOAD_RAMP = [1_000_000, 10_000_000, 25_000_000]
_BLOCK = 64 * 1024
_PROGRESS_INTERVAL = 0.1  # ~10x/sec


def _download(host, duration):
    import http.client

    conn = http.client.HTTPSConnection(host, timeout=30)
    total_bytes = 0
    start = time.monotonic()
    last_emit = start
    try:
        for size in _SIZE_RAMP:
            elapsed = time.monotonic() - start
            if elapsed >= duration or _STOP:
                break
            conn.request("GET", f"/__down?bytes={size}")
            resp = conn.getresponse()
            while True:
                if _STOP:
                    resp.read()  # drain so the connection can close cleanly
                    break
                chunk = resp.read(_BLOCK)
                if not chunk:
                    break
                total_bytes += len(chunk)
                now = time.monotonic()
                if now - last_emit >= _PROGRESS_INTERVAL:
                    last_emit = now
                    elapsed = now - start
                    mbps = total_bytes * 8 / elapsed / 1e6 if elapsed > 0 else 0.0
                    _emit({"phase": "down", "pct": min(elapsed / duration, 1.0), "mbps": round(mbps, 2)})
                if now - start >= duration:
                    break
            if _STOP or time.monotonic() - start >= duration:
                break
    finally:
        conn.close()

    elapsed = max(time.monotonic() - start, 1e-6)
    mbps = total_bytes * 8 / elapsed / 1e6
    _emit({"phase": "down", "pct": 1.0, "mbps": round(mbps, 2), "done": True})
    return mbps


def _upload(host, duration):
    import http.client

    conn = http.client.HTTPSConnection(host, timeout=30)
    total_bytes = 0
    start = time.monotonic()
    last_emit = start
    try:
        for size in _UPLOAD_RAMP:
            elapsed = time.monotonic() - start
            if elapsed >= duration or _STOP:
                break
            body = os.urandom(min(size, 4 * 1024 * 1024))  # one block, resend/reuse below
            conn.putrequest("POST", "/__up")
            conn.putheader("Content-Type", "application/octet-stream")
            conn.putheader("Content-Length", str(size))
            conn.endheaders()

            # Once a request is started we must finish sending exactly
            # `size` bytes to honor the Content-Length we already sent -
            # stopping mid-body would leave the request framing broken
            # and a subsequent conn.getresponse() can hang/error. So the
            # time/_STOP budget is only checked at request boundaries;
            # a request in flight always runs to completion.
            sent = 0
            while sent < size:
                block = body if len(body) <= size - sent else body[:size - sent]
                conn.send(block)
                sent += len(block)
                total_bytes += len(block)
                now = time.monotonic()
                if now - last_emit >= _PROGRESS_INTERVAL:
                    last_emit = now
                    elapsed = now - start
                    mbps = total_bytes * 8 / elapsed / 1e6 if elapsed > 0 else 0.0
                    _emit({"phase": "up", "pct": min(elapsed / duration, 1.0), "mbps": round(mbps, 2)})
            resp = conn.getresponse()
            resp.read()
            if _STOP or time.monotonic() - start >= duration:
                break
    finally:
        conn.close()

    elapsed = max(time.monotonic() - start, 1e-6)
    mbps = total_bytes * 8 / elapsed / 1e6
    _emit({"phase": "up", "pct": 1.0, "mbps": round(mbps, 2), "done": True})
    return mbps


def cmd_speedtest(duration, do_upload):
    signal.signal(signal.SIGTERM, _handle_signal)
    signal.signal(signal.SIGINT, _handle_signal)
    try:
        _run_speedtest(duration, do_upload)
    except SystemExit:
        raise
    except Exception as e:
        _emit({"phase": "error", "msg": str(e)})
        sys.exit(1)
    sys.exit(0)


# ---------------------------------------------------------------------------
# selftest
# ---------------------------------------------------------------------------

def selftest():
    # -- split_escaped: a real nmcli -t scan line. The BSSID's escaped
    #    colons must NOT split, or every column after it shifts.
    line = r" :ExampleNet:AA\:BB\:CC\:DD\:EE\:FF:60:WPA2:52:5260 MHz:540 Mbit/s:Infra"
    p = split_escaped(line)
    assert len(p) == 9, p
    assert p[1] == "ExampleNet", p
    assert p[2] == "AA:BB:CC:DD:EE:FF", p[2]
    assert p[3] == "60" and p[4] == "WPA2" and p[5] == "52", p
    assert p[6] == "5260 MHz" and p[7] == "540 Mbit/s" and p[8] == "Infra", p
    assert p[0] == " ", repr(p[0])
    # naive split would have shredded it into far more fields
    assert len(line.split(":")) > 9
    # an SSID containing a literal escaped colon survives round-trip
    assert split_escaped(r"a\:b:c") == ["a:b", "c"]
    # empty trailing field is preserved, not dropped
    assert split_escaped("a:b:") == ["a", "b", ""]

    # -- get_fields index parsing: fabricate the raw '\n'-joined output
    #    nmcli would give us for a single connection, including an empty
    #    field and a value containing ':'.
    raw = "auto\n\n192.168.1.5/24\nAA:BB:CC:DD:EE:FF\n"
    lines = raw.split("\n")
    if lines and lines[-1] == "":
        lines = lines[:-1]
    assert lines == ["auto", "", "192.168.1.5/24", "AA:BB:CC:DD:EE:FF"], lines
    assert lines[1] == ""
    assert lines[3] == "AA:BB:CC:DD:EE:FF"  # ':' preserved, not split on

    # -- bool normalizer, every spelling nmcli uses --
    for v in ("yes", "true", "on", "1", "YES", "True"):
        assert norm_bool(v) is True, v
    for v in ("no", "false", "off", "0", "NO"):
        assert norm_bool(v) is False, v
    assert norm_bool("") is False
    assert norm_bool(None) is False
    assert norm_bool("", default=True) is True
    assert norm_bool("garbage", default=True) is True

    assert norm_metered("unknown") == "auto"
    assert norm_metered("") == "auto"
    assert norm_metered("yes") == "yes"
    assert norm_metered("no") == "no"

    assert to_int("auto", 0) == 0
    assert to_int("-1", 0) == 0
    assert to_int("1500", 0) == 1500
    assert to_int("", 7) == 7

    # -- apply flag -> property mapping table --
    assert FLAG_TABLE["ipv4-method"][0] == "ipv4.method"
    assert FLAG_TABLE["ipv4-addresses"][0] == "ipv4.addresses"
    assert FLAG_TABLE["priority"][0] == "connection.autoconnect-priority"
    assert FLAG_TABLE["metered"][0] == "connection.metered"
    assert FLAG_TABLE["hidden"][0] == "802-11-wireless.hidden"
    assert FLAG_TABLE["channel"][0] == "802-11-wireless.channel"
    # never a mapping into 802-1x.*
    for prop, _ in FLAG_TABLE.values():
        assert prop is None or not prop.startswith("802-1x"), prop
    assert "eap" not in FLAG_TABLE and "eap-identity" not in FLAG_TABLE

    # mtu/cloned-mac resolve by profile type
    pairs, reactivate = build_modify_args("u", {"mtu": "1500"}, "wifi")
    assert pairs == [("802-11-wireless.mtu", "1500")], pairs
    pairs, reactivate = build_modify_args("u", {"mtu": "1500"}, "ethernet")
    assert pairs == [("802-3-ethernet.mtu", "1500")], pairs
    pairs, reactivate = build_modify_args("u", {"cloned-mac": "random"}, "wifi")
    assert pairs == [("802-11-wireless.cloned-mac-address", "random")], pairs
    pairs, reactivate = build_modify_args("u", {"cloned-mac": "random"}, "ethernet")
    assert pairs == [("802-3-ethernet.cloned-mac-address", "random")], pairs

    # reactivate flag is stripped out of the property pairs
    pairs, reactivate = build_modify_args("u", {"autoconnect": "yes", "reactivate": True}, "wifi")
    assert reactivate is True
    assert pairs == [("connection.autoconnect", "yes")], pairs

    # -- validation rejections --
    def rejects(flags, ptype="wifi"):
        try:
            build_modify_args("u", dict(flags), ptype)
        except ValidationError:
            return True
        return False

    assert rejects({"ipv4-method": "manual"})  # manual needs addresses
    assert not rejects({"ipv4-method": "manual", "ipv4-addresses": "10.0.0.5/24"})
    assert rejects({"ipv4-addresses": "not-an-ip"})
    assert rejects({"ipv4-gateway": "not-an-ip"})
    assert rejects({"ipv4-dns": "10.0.0.1,garbage"})
    assert rejects({"ipv4-addresses": "fe80::1/64"})  # v6 in a v4 flag
    assert rejects({"ipv6-addresses": "10.0.0.5/24"})  # v4 in a v6 flag
    assert rejects({"ipv4-method": "bogus"})
    assert rejects({"ipv6-method": "bogus"})
    assert rejects({"mtu": "not-a-number"})
    assert rejects({"priority": "abc"})
    assert rejects({"channel": "abc"})
    assert rejects({"nonexistent-flag": "x"})
    assert not rejects({"ipv6-method": "manual", "ipv6-addresses": "fe80::5/64"})

    # ipaddress.ip_interface accepts a bare address (implicit /32), so
    # that alone should NOT be rejected.
    assert not rejects({"ipv4-addresses": "10.0.0.5"})

    # -- mbps arithmetic --
    mbps = 12_500_000 * 8 / 1.0 / 1e6
    assert abs(mbps - 100.0) < 1e-9

    # -- jitter calculation --
    assert _jitter([10.0]) == 0.0
    assert _jitter([]) == 0.0
    j = _jitter([10.0, 12.0, 11.0])
    assert abs(j - 1.5) < 1e-9  # |12-10|=2, |11-12|=1 -> mean 1.5

    print("selftest: OK")


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

def main():
    argv = sys.argv[1:]
    if not argv:
        print("usage: net.py {conns|scan|show <uuid>|apply <uuid> [--flag val ...]|speedtest [--duration N] [--no-upload]|selftest}", file=sys.stderr)
        sys.exit(1)

    cmd = argv[0]
    rest = argv[1:]

    if cmd == "conns":
        cmd_conns()
    elif cmd == "scan":
        cmd_scan()
    elif cmd == "active":
        cmd_active()
    elif cmd == "show":
        if not rest:
            print("show requires a <uuid>", file=sys.stderr)
            sys.exit(1)
        cmd_show(rest[0])
    elif cmd == "apply":
        if not rest:
            print("apply requires a <uuid>", file=sys.stderr)
            sys.exit(1)
        uuid, flag_argv = rest[0], rest[1:]
        try:
            flags = parse_apply_argv(flag_argv)
        except ValidationError as e:
            print(f"apply rejected: {e}", file=sys.stderr)
            sys.exit(1)
        cmd_apply(uuid, flags)
    elif cmd == "speedtest":
        p = argparse.ArgumentParser(prog="net.py speedtest")
        p.add_argument("--duration", type=float, default=8.0)
        p.add_argument("--no-upload", action="store_true")
        ns = p.parse_args(rest)
        cmd_speedtest(ns.duration, not ns.no_upload)
    elif cmd == "selftest":
        selftest()
        sys.exit(0)
    else:
        print(f"unknown command {cmd!r}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
