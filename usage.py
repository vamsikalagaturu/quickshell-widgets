#!/usr/bin/env python3
import os, sys, json, datetime, urllib.request

URL = "https://chatgpt.com/backend-api/codex/usage"
CLAUDE_URL = "https://api.anthropic.com/api/oauth/usage"
CACHE = os.path.expanduser("~/.cache/codex_usage.json")
CLAUDE_CACHE = os.path.expanduser("~/.cache/claude_usage.json")
FRESH = "--fresh" in sys.argv[1:]


def iso_epoch(s):
    return datetime.datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()


def fetch():
    auth = json.load(open(os.path.expanduser("~/.codex/auth.json")))
    t = auth.get("tokens", {})
    req = urllib.request.Request(URL, headers={
        "Authorization": f"Bearer {t['access_token']}",
        "chatgpt-account-id": t["account_id"],
        "User-Agent": "Mozilla/5.0 (X11; Linux x86_64; rv:128.0) Gecko/20100101 Firefox/128.0",
        "Accept": "application/json",
    })
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.load(r)


def fetch_claude():
    cred = json.load(open(os.path.expanduser("~/.claude/.credentials.json")))
    req = urllib.request.Request(CLAUDE_URL, headers={
        "Authorization": f"Bearer {cred['claudeAiOauth']['accessToken']}",
        "anthropic-beta": "oauth-2025-04-20",
        "Content-Type": "application/json",
    })
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.load(r)


def fetch_cached(fetch_fn, cache, now, ttl=300):
    data = None
    try:
        if not FRESH and os.path.getmtime(cache) > now - ttl:
            data = json.load(open(cache))
    except Exception:
        pass
    if data is None:
        try:
            data = fetch_fn()
            os.makedirs(os.path.dirname(cache), exist_ok=True)
            json.dump(data, open(cache, "w"))
        except Exception:
            if data is None:
                raise
    return data
def fmt_reset(ts):
    reset = datetime.datetime.fromtimestamp(ts, datetime.timezone.utc).astimezone()
    secs = int((reset - datetime.datetime.now(datetime.timezone.utc)).total_seconds())
    if secs > 86400:
        return reset.strftime("%b %d %H:%M")
    if secs <= 0:
        return "now"
    d, s = divmod(secs, 86400)
    h, m = divmod(s, 3600)
    m //= 60
    if d > 0:
        return f"{d}d {h}h"
    if h > 0:
        return f"{h}h {m}m"
    return f"{m}m"


def row(label, pct, resets_at=None):
    r = {"label": label, "pct": int(pct)}
    if resets_at:
        r["reset"] = fmt_reset(resets_at)
    return r


def fetch():
    auth = json.load(open(os.path.expanduser("~/.codex/auth.json")))
    t = auth.get("tokens", {})
    req = urllib.request.Request(URL, headers={
        "Authorization": f"Bearer {t['access_token']}",
        "chatgpt-account-id": t["account_id"],
        "User-Agent": "Mozilla/5.0 (X11; Linux x86_64; rv:128.0) Gecko/20100101 Firefox/128.0",
        "Accept": "application/json",
    })
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.load(r)


groups = []

try:
    now = datetime.datetime.now().timestamp()
    data = fetch_cached(fetch, CACHE, now)
    win = data.get("rate_limit", {}).get("primary_window") or data.get("rate_limit", {}).get("secondary_window") or {}
    if win.get("used_percent") is not None:
        groups.append({"title": "codex", "rows": [row("7d", win["used_percent"], win.get("reset_at"))]})
except Exception:
    pass

try:
    now = datetime.datetime.now().timestamp()
    data = fetch_cached(fetch_claude, CLAUDE_CACHE, now)
    claude_rows = []
    for label, key in (("5h", "five_hour"), ("7d", "seven_day")):
        w = data.get(key) or {}
        if w.get("utilization") is not None:
            claude_rows.append(row(label, w["utilization"], iso_epoch(w["resets_at"]) if w.get("resets_at") else None))
    if claude_rows:
        groups.append({"title": "claude", "rows": claude_rows})
except Exception:
    try:
        d = json.load(open(os.path.expanduser("~/.claude/usage-limits.json")))
        rl = d.get("rate_limits") or {}
        claude_rows = []
        for label, key in (("5h", "five_hour"), ("7d", "seven_day")):
            w = rl.get(key) or {}
            if w.get("used_percentage") is not None:
                claude_rows.append(row(label, w["used_percentage"], w.get("resets_at")))
        if claude_rows:
            groups.append({"title": "claude", "rows": claude_rows})
    except Exception:
        pass

print(json.dumps(groups))
