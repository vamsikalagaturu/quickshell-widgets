# Quickshell Widgets

Hyprland/Quickshell widgets, all loaded by one quickshell process from the root `shell.qml`:

| Widget | Key | What |
|---|---|---|
| `usage/` | SUPER + ; | Codex (weekly) and Claude Code (5-hour + weekly) usage bars; shows for 5s on startup |
| `launcher/` | SUPER + D | app launcher (replaces walker) |
| `clipboard/` | SUPER + C | clipboard history picker |
| `connectivity/` | SUPER + S | Wi-Fi, wired and Bluetooth panel |
| `github/` | SUPER + G | GitHub dashboard |
| `powermenu/` | SUPER + Escape | power menu |
| `volume/` | SUPER + M | output/input devices and per-app levels |
| `osd/` | media keys | volume / mic / brightness on-screen display |
| `ports/` | SUPER + P | dev servers listening on your ports |

`common/` holds what they share: `Theme` (Nord Polar Night palette and the `s()` scale), `Popup` (a focusable panel toggled by a global shortcut; widgets override `open()`/`close()`), `Card`, `Toggle`, `ScrollTrack` and `Paths.local()` for scripts next to a QML file. Every widget file imports it with `import "../common"`.

## Dependencies

- [Quickshell](https://quickshell.org) 0.3.0+ (Wayland shell framework)
- `python3`
- no extra deps for Claude — uses the OAuth token already in `~/.claude/.credentials.json`
- [JetBrainsMono Nerd Font](https://github.com/ryanoasis/nerd-fonts) (falls back to monospace if missing)
- Hyprland (for the global keybind) — or any compositor with the GlobalShortcuts portal

> On NVIDIA + nixpkgs, Qt fails to init GL against the proprietary EGL driver; run quickshell with `QT_QUICK_BACKEND=software`.

## Setup

### 1. Install

Clone the repo and link the root `shell.qml` and every folder into the quickshell config dir (linked individually because widgets keep state files such as `network.json` in that dir):

```sh
git clone https://github.com/vamsikalagaturu/quickshell-widgets ~/quickshell-widgets
mkdir -p ~/.config/quickshell
ln -s ~/quickshell-widgets/shell.qml ~/.config/quickshell/shell.qml
for d in common usage launcher clipboard connectivity github powermenu volume osd ports; do
  ln -s ~/quickshell-widgets/$d ~/.config/quickshell/$d
done
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

Requires a Claude.ai Pro/Max subscription. Responses are cached 5 min in `~/.cache/claude_usage.json` because the endpoint rate-limits aggressive polling; the cache is dropped early once a window's reset time has passed, so a rolled-over window never shows stale numbers.

Endpoint details (undocumented API, reverse-engineered): [gist.github.com/jtbr/4f99671d1cee06b44106456958caba8b](https://gist.github.com/jtbr/4f99671d1cee06b44106456958caba8b)

### 4. Autostart + keybind (Hyprland)

One line in `~/.config/hypr/startup.conf` starts every widget:

```
exec-once = env QT_QUICK_BACKEND=software quickshell -p ~/.config/quickshell
```

In `~/.config/hypr/keybinds.conf`, bind each widget's global shortcut (`quickshell:toggle-<widget>`; the osd owns `quickshell:volume-*`, `mic-mute` and `brightness-*`), e.g.:

```
bindd = SUPER, semicolon, toggle usage widget, global, quickshell:toggle-usage
bindd = SUPER, D, app launcher, global, quickshell:toggle-launcher
```

Reload: `hyprctl reload`. Verify registration: `hyprctl globalshortcuts`.

## Notes

- Data is fetched on startup and every time you toggle the widget (**SUPER + ;**); `--fresh` bypasses the Codex 5-min cache in `~/.cache/codex_usage.json`.

## `github/` — GitHub dashboard

Unread notifications, review requests, your open pull requests (with check state), assigned issues, a repository list (owned + org membership), and your starred repositories. Toggle with **SUPER + G**.

`j`/`k` move a cursor across every row (sections, repos, starred, and each section's footer buttons), `Enter` opens/activates the selected one, `m` marks the selected notification read, `M` arms then confirms "mark all read", `/` focuses the always-visible bottom search bar (matches issues/PRs/repos/starred by title or `owner/repo`), `,` or the Settings button opens org-exclusion settings (`Tab` focuses it, `Enter` activates), `r` refreshes, `Esc` closes (or backs out of settings first).

Reopening within 60s of the last successful load shows what's already cached instead of refetching. Actions scanning is off by default (it's the majority of a fetch's cost); repositories are ordered by most recently updated with no user-facing sort. Excluded orgs (Settings) persist to `~/.config/quickshell/github-excluded-orgs.json`, alongside connectivity's `network.json`.

Dependencies: [`gh`](https://cli.github.com/) (authenticated — `gh auth login`, plus `gh auth refresh -h github.com -s notifications -s repo` for notifications/private repos) and `jq`.

Keybind:

```
bindd = $mainMod, G, toggle github widget, global, quickshell:toggle-github
```

### Attribution

`Service.qml` and `github-fetch` are ported near-verbatim from [robzolkos/omarchy-github](https://github.com/robzolkos/omarchy-github) (MIT License, Copyright (c) 2026 Rob Zolkos) — a plugin for [Omarchy Quattro](https://github.com/basecamp/omarchy)'s Quickshell bar. That data layer had no Omarchy-specific coupling to begin with. `Github.qml` (the UI) is a fresh implementation against this repo's own `Popup`/`Theme` conventions rather than Omarchy's `qs.Commons`/`qs.Ui` component library, which this repo doesn't have — it ports the original panel's feature set, cursor/filter/sort logic, and mark-as-read flow.

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

Keybind:

```
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
repo open URLs with. `Ports.qml` (the UI) is a fresh implementation against this
repo's own `Popup`/`Theme` conventions rather than Omarchy's `qs.Commons`/`qs.Ui`
component library, which this repo doesn't have — it carries over the original
panel's cursor model, the browsable/exposed distinctions and the two-step stop flow.
