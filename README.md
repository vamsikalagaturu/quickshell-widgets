# Quickshell Usage Widget

A small Hyprland/Quickshell widget showing live usage for **Codex** (weekly) and **Claude Code** (5-hour + weekly) as progress bars with reset times, plus a **Quickshell app launcher** that replaces walker. Widget shows on startup for 5s, then hides; toggle with **SUPER + ;**. Launcher opens with **SUPER + D**.

This repo also has standalone widgets in their own subdirectories, each with its own `qmldir`/`shell.qml`, launched separately via `quickshell-intel -p ~/.config/quickshell/<name>` in `hypr/startup.conf`: `connectivity`, `launcher`, `clipboard`, `powermenu`, `github`, `ports`.

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

## `github/` — GitHub dashboard

Unread notifications, review requests, your open pull requests (with check state), assigned issues, a repository list (owned + org membership), and your starred repositories. Toggle with **SUPER + G**.

`j`/`k` move a cursor across every row (sections, repos, starred, and each section's footer buttons), `Enter` opens/activates the selected one, `m` marks the selected notification read, `M` arms then confirms "mark all read", `/` focuses the always-visible bottom search bar (matches issues/PRs/repos/starred by title or `owner/repo`), `,` or the Settings button opens org-exclusion settings (`Tab` focuses it, `Enter` activates), `r` refreshes, `Esc` closes (or backs out of settings first).

Reopening within 60s of the last successful load shows what's already cached instead of refetching. Actions scanning is off by default (it's the majority of a fetch's cost); repositories are ordered by most recently updated with no user-facing sort. Excluded orgs (Settings) persist to `~/.config/quickshell/github-excluded-orgs.json`, alongside connectivity's `network.json`.

Dependencies: [`gh`](https://cli.github.com/) (authenticated — `gh auth login`, plus `gh auth refresh -h github.com -s notifications -s repo` for notifications/private repos) and `jq`.

Autostart + keybind, same pattern as the other widgets:

```
# hypr/startup.conf
exec-once = $HOME/.local/bin/quickshell-intel -p $HOME/.config/quickshell/github

# hypr/keybinds.conf
bindd = $mainMod, G, toggle github widget, global, quickshell:toggle-github
```

### Attribution

`Service.qml` and `github-fetch` are ported near-verbatim from [robzolkos/omarchy-github](https://github.com/robzolkos/omarchy-github) (MIT License, Copyright (c) 2026 Rob Zolkos) — a plugin for [Omarchy Quattro](https://github.com/basecamp/omarchy)'s Quickshell bar. That data layer had no Omarchy-specific coupling to begin with. `shell.qml` (the UI) is a fresh implementation against this repo's own `PanelWindow`/`Theme` conventions rather than Omarchy's `qs.Commons`/`qs.Ui` component library, which this repo doesn't have — it ports the original panel's feature set, cursor/filter/sort logic, and mark-as-read flow.

## `ports/` — dev servers

Every TCP socket you have in `LISTEN` state, one row per **process** rather than
per port, labelled with the git project it was started in. Toggle with **SUPER + P**.

`j`/`k` or the arrows move the cursor, `Enter` opens a row that speaks HTTP (or
copies the URL of one that doesn't), `o` opens, `c` copies `http://localhost:PORT`,
`x` stops, `r` rescans, `Esc` closes.

Only sockets whose owning process the kernel reveals are listed, which is exactly
your own processes — the DNS resolver and the print spooler never show up. A Godot
editor holding two ports is one row; a pre-forking server's master and workers are
one row marked `+ workers`. A row bound past loopback is marked `exposed`.

The globe glyph appears only on rows that answered an HTTP `HEAD`, so a database or
debug port never sends you to a browser tab that spins forever. Each socket is asked
once, when it first appears, and the answer is dropped when that socket goes away.

Stopping is two separate decisions, and neither signal is aimed at a remembered pid.
Confirming sends `SIGTERM` via `ports-stop`, which first re-derives the pid, the
start time in `/proc/<pid>/stat` that a recycled pid cannot match, and the sockets
the row was built from — and refuses, saying why, if any of it moved. If the server
is still listening five seconds later the panel reopens to ask a second, separate
question before anything sends `SIGKILL`. Nothing escalates on its own.

The panel scans every 2s while open and every 30s while closed; the slow scan is
what keeps the five-second `SIGKILL` check honest if you closed the panel after
confirming a stop.

Dependencies: `ss` (iproute2), `jq`, `curl`, `wl-copy`, `xdg-open`.

Autostart + keybind, same pattern as the other widgets:

```
# hypr/startup.conf
exec-once = $HOME/.local/bin/quickshell-intel -p $HOME/.config/quickshell/ports

# hypr/keybinds.conf
bindd = $mainMod, P, toggle dev servers panel, global, quickshell:toggle-ports
```

### Attribution

The idea, `ports-scan`, `ports-stop` and `Scanner.qml` come from
[rubenmeza/omarchy-ports](https://github.com/rubenmeza/omarchy-ports) (MIT License,
Copyright (c) 2026 Ruben Meza) — a plugin for [Omarchy
Quattro](https://github.com/basecamp/omarchy)'s Quickshell bar. The two bash helpers
are vendored unmodified apart from an attribution header: they are plain `ss`/`/proc`
scripts with no Omarchy coupling, and the pid-identity check in `ports-stop` is the
most careful part of the original. `Scanner.qml` is a light port — the plugin
settings object became plain properties, the helper paths point here, and
`omarchy-launch-browser` became `xdg-open`, which is what the other widgets in this
repo open URLs with. `shell.qml` (the UI) is a fresh implementation against this
repo's own `PanelWindow`/`Theme` conventions rather than Omarchy's `qs.Commons`/`qs.Ui`
component library, which this repo doesn't have — it carries over the original
panel's cursor model, the browsable/exposed distinctions and the two-step stop flow.
