# Quickshell Usage Widget

A small Hyprland/Quickshell widget showing live usage for **Codex** (weekly) and **Claude Code** (5-hour + weekly) as progress bars with reset times. Shows on startup for 5s, then hides; toggle with **SUPER + ;**.

## Dependencies

- [Quickshell](https://quickshell.org) 0.3.0+ (Wayland shell framework)
- `python3`
- no extra deps for Claude — uses the OAuth token already in `~/.claude/.credentials.json`
- [JetBrainsMono Nerd Font](https://github.com/ryanoasis/nerd-fonts) (falls back to monospace if missing)
- Hyprland (for the global keybind) — or any compositor with the GlobalShortcuts portal

> On NVIDIA + nixpkgs, Qt fails to init GL against the proprietary EGL driver; run quickshell with `QT_QUICK_BACKEND=software`.

## Setup

### 1. Install

Clone the repo and link it into the quickshell config dir:

```sh
git clone https://github.com/vamsikalagaturu/quickshell-widgets ~/quickshell-widgets
mkdir -p ~/.config/quickshell
ln -s ~/quickshell-widgets/shell.qml ~/.config/quickshell/shell.qml
ln -s ~/quickshell-widgets/usage.py ~/.config/quickshell/usage.py
```

Test it:

```sh
QT_QUICK_BACKEND=software quickshell -p ~/.config/quickshell
```

### 2. Codex usage

`usage.py` calls `https://chatgpt.com/backend-api/codex/usage` directly with your Codex auth tokens. Put them in `~/.codex/auth.json` (your existing Codex login already has these):

```json
{ "tokens": { "access_token": "...", "account_id": "..." } }
```

Requires a ChatGPT Plus/Pro subscription that includes Codex.

### 3. Claude Code usage

`usage.py` queries `https://api.anthropic.com/api/oauth/usage` directly using the OAuth access token Claude Code already stores in `~/.claude/.credentials.json` (same token Claude Code uses). No extra setup needed — Claude Code refreshes the token on every run.

Requires a Claude.ai Pro/Max subscription. Responses are cached 5 min in `~/.cache/claude_usage.json` because the endpoint rate-limits aggressive polling.

Endpoint details (undocumented API, reverse-engineered): [gist.github.com/jtbr/4f99671d1cee06b44106456958caba8b](https://gist.github.com/jtbr/4f99671d1cee06b44106456958caba8b)

### 4. Autostart + keybind (Hyprland)

In `~/.config/hypr/startup.conf`:

```
exec-once = env QT_QUICK_BACKEND=software quickshell -p ~/.config/quickshell
```

In `~/.config/hypr/keybinds.conf` (change the key if taken):

```
bindd = SUPER, semicolon, toggle usage widget, global, quickshell:toggle-usage
```

Reload: `hyprctl reload`. Verify registration: `hyprctl globalshortcuts`.

## Notes

- Data is fetched on startup and every time you toggle the widget (**SUPER + ;**); `--fresh` bypasses the Codex 5-min cache in `~/.cache/codex_usage.json`.
