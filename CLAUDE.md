# CLAUDE.md — Loom Development Notes

## VM Testing Workflow

Build, launch, test, reset cycle for the first-boot kiosk experience:

1. **Build**: `nix build .#vm`
   - Stage changes first (`git add`) — nix flakes only see staged files

2. **Launch** (must run as josh for DISPLAY access):
   ```
   sudo -u josh bash -c 'DISPLAY=:0 NIX_DISK_IMAGE=/agents/ada/projects/loom/loom.qcow2 /agents/ada/projects/loom/result/bin/run-loom-vm'
   ```
   - Do NOT set `QEMU_NET_OPTS` — port forwarding (SSH:2222, HTTP:9090) is already in the flake config; duplicates cause QEMU to fail
   - `/agents/ada` and `/agents/ada/projects` need `o+x` for josh to traverse; `/agents/ada/projects/loom` needs `o+rwx` for disk image creation

3. **SSH in**: `ssh -p 2222 ada@localhost`

4. **HTTP auth server**: `http://localhost:9090/` (port forwarded from guest via SLIRP)
   - The NixOS firewall must allow port 9090 — this is handled by `networking.firewall.allowedTCPPorts` in the module when `!setupComplete`

5. **Reset**: `sudo kill <pid> && sudo rm -f /agents/ada/projects/loom/loom.qcow2`
   - Must delete disk to clear persisted credentials from `.claude` directory

## Auth Flow

The kiosk boots into: cage → foot → sudo -u ada → tmux (as ada) → loom-ada-claude wrapper.

The wrapper checks for credentials in order:
1. `.claude/.credentials.json` — full OAuth credentials JSON
2. `.claude/.api-key` — Anthropic API key (`sk-ant-api*`)
3. `.claude/.oauth-token` — setup token from `claude setup-token` (`sk-ant-oat*`)

If none exist, it runs the HTTP auth server on port 9090 (QR code + web form).
After credentials are submitted, wrapper exports the appropriate env var and launches claude.

Token detection:
- `sk-ant-api*` → API key → `.api-key` → `ANTHROPIC_API_KEY`
- `sk-ant-oat*` (or any other `sk-ant-*`) → OAuth token → `.oauth-token` → `CLAUDE_CODE_OAUTH_TOKEN`
- `{*` → credentials JSON → `.credentials.json`
- anything else → treated as OAuth token → `.oauth-token` → `CLAUDE_CODE_OAUTH_TOKEN`

## Setup Flow — Three Phases

The setup is a three-phase process. One ISO, cage as the universal
launchpad, any desktop as the destination.

### Phase 1: Kiosk (`loom.setupPhase = "kiosk"`)

First boot. Cage (Wayland kiosk compositor) runs fullscreen foot terminal
with Ada. The system has nothing but this terminal.

```
cage → foot → sudo -u ada → tmux → loom-ada-claude
                                     ├─ auth server (if no creds)
                                     └─ claude "Hi! I just installed..."
```

Ada greets the user and asks what they want to use the computer for.
Based on the conversation, Ada configures a desktop environment by
editing `/etc/nixos/configuration.nix`:

- Enables compositor/WM (Hyprland, Sway, GNOME, i3, etc.)
- Adds auto-login so the user doesn't hit a login screen yet
- Adds autostart rule for the compositor: open a terminal running
  `loom-ada-resume` (which sudos to ada and runs `claude --continue`)
- Changes `loom.setupPhase` from `"kiosk"` to `"desktop"`

Then `nixos-rebuild switch`. The switch atomically:
- Stops cage (no longer configured in `desktop` phase)
- Starts the new desktop with auto-login
- Autostart opens a terminal with Ada resuming the conversation

The screen flickers briefly. Ada warns the user before switching:
"I'm applying your desktop now — the screen will flicker and your
new desktop will appear. I'll be right there in a terminal window."

### Phase 2: Desktop (`loom.setupPhase = "desktop"`)

Ada resumes inside the real desktop via `claude --continue`. The user
can see their new compositor running. Ada orients them:

- "Welcome to your new desktop! Try pressing Super..."
- Installs apps one at a time (browser, editor, etc.)
- Customizes theme, fonts, keybindings, status bar
- Each change: edit config → build → switch → "It's in your app menu"

When the user is happy:
- Ada helps set a proper password
- Configures a login screen (greetd, sddm, gdm)
- Removes auto-login from the config
- Removes the Ada autostart terminal
- Changes `loom.setupPhase` to `"complete"`
- Final switch, then suggests reboot

"Everything's set. Next time you boot, you'll see a login screen.
You can always find me through the terminal — just run `portal-ada`."

### Phase 3: Complete (`loom.setupPhase = "complete"`)

Normal operation. The loom module adds nothing special — no cage, no
auto-login, no passwordless sudo user→ada. Ada is available through
the nuketown portal. Sudo goes through the approval daemon.

### Why One ISO / Cage as Universal Launchpad

The compositor/display server is the one thing Ada can't hot-swap —
it's the floor everything stands on. Packages, services, apps, themes,
keybindings all apply live via `nixos-rebuild switch`. But switching
from "no compositor" to "Hyprland" requires a session transition.

Cage solves this: it's a minimal Wayland kiosk that runs on virtually
any hardware (just needs a framebuffer). Ada runs inside cage, configures
the real desktop, then the switch replaces cage with whatever the user
chose — Wayland or X11, doesn't matter. One ISO covers everything.

### State Model

```nix
loom.setupPhase = "kiosk" | "desktop" | "complete";
```

| Phase     | Cage | Auto-login | user→ada sudo | Firewall 9090 | Bootstrap /etc/nixos |
|-----------|------|------------|---------------|---------------|---------------------|
| kiosk     | yes  | yes        | yes           | yes           | yes                 |
| desktop   | no   | yes        | yes           | no            | no                  |
| complete  | no   | no         | no            | no            | no                  |

### Scripts

- **`loom-ada-claude`**: Runs as ada. Handles auth, config pre-seed, launches
  `claude` with initial greeting (kiosk) or `--continue` (resume).
  Accepts a mode argument: `loom-ada-claude` (initial) or `loom-ada-claude resume`.

- **`loom-ada-resume`**: Runs as the human user. Sudos to ada, launches
  `loom-ada-claude resume`. Used in desktop compositor autostart rules.

## Key Architecture Decisions

- **tmux runs as ada** — not as the kiosk user. This keeps TMUX socket, BROWSER env, and loom-open all within ada's session boundary.
- **loom-open** splits tmux to show QR codes — claude-code calls $BROWSER or xdg-open, both routed to loom-open.
- **xdg-open shim** is only installed when not in `complete` phase to avoid conflicting with real xdg-open after desktop setup.
- **Cage as universal launchpad** — one ISO, any destination. Cage is minimal Wayland that works on any hardware. The real compositor is chosen in conversation and applied via switch.
- **Auto-login persists through compositor switch** — only removed when Ada configures the greeter in the final phase.
- **`claude --continue`** resumes the setup conversation after the compositor switch so Ada can orient the user in the new desktop.
