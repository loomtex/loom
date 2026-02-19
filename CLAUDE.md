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
   - SSH authorized keys are in the VM's flake.nix config but NOT in the bootstrap `/etc/nixos/` config. After Ada does `nixos-rebuild switch --flake /etc/nixos`, SSH key auth will be lost. Either have Ada add keys to the config, or log in as `user` with password `loom` on tty.

4. **HTTP auth server**: `http://localhost:9090/` (port forwarded from guest via SLIRP)
   - The NixOS firewall must allow port 9090 — this is handled by `networking.firewall.allowedTCPPorts` in the module during kiosk phase

5. **Reset**: Kill QEMU, delete disk, relaunch:
   ```
   sudo kill <pid>
   sudo rm -f /agents/ada/projects/loom/loom.qcow2
   ```
   - Must delete disk to clear persisted credentials from `.claude` directory
   - Kill and rm must be separate commands — chaining with `;` after `sudo kill` can fail (exit 144 from signal)

6. **Grab transcripts** before killing the VM:
   ```
   scp -P 2222 ada@localhost:~/.claude/projects/-agents-ada-projects/*.jsonl ./transcripts/
   scp -P 2222 ada@localhost:/etc/nixos/configuration.nix ./transcripts/final-configuration.nix
   ```

## VM Nix Store

The VM mounts the host's `/nix/store` read-only via 9p, with an overlayfs for writes:
- **Lower layer**: host store via 9p (instant access to everything already built)
- **Upper layer**: VM's disk image (`writableStoreUseTmpfs = false`)

This means packages already in the host store are instantly available in the VM. Only new packages need to be fetched/built. To pre-warm the host store after a test session:
```
nix copy --from ssh-ng://ada@localhost ...  # doesn't work yet, needs investigation
```
In practice, most packages are fetched from cache.nixos.org and end up in both stores.

### Boot Loader

The VM uses `useBootLoader = true` + `useEFIBoot = true`, so it boots from a real UEFI bootloader (systemd-boot via OVMF) on the virtual disk. `nixos-rebuild switch` inside the VM updates the bootloader, and reboots boot the new system. This allows full testing of the kiosk → desktop → complete → reboot → greeter cycle.

### Local Module Changes vs VM Rebuilds

**CRITICAL**: The VM's initial boot uses the local loom module (baked into the
VM image via `nix build .#vm`). But when Ada runs `nixos-rebuild switch --flake
/etc/nixos` inside the VM, the bootstrap flake fetches `github:loomtex/loom` —
the **published** version. Local changes to `module.nix`, `prompt.nix`, etc.
are NOT in that build.

To test local module changes end-to-end (including the desktop switch), the
bootstrap flake must reference the local loom source, not GitHub. The VM shares
the loom source via 9p at `/tmp/loom-src` — the bootstrap flake uses
`loom.url = "path:/tmp/loom-src"`.

### Super Key in QEMU

The host window manager intercepts Super before it reaches the VM. Press **Ctrl+Alt+G** in the QEMU window to grab all keyboard input. Same combo to release.

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

### Model Selection

OAuth tokens (including setup tokens) default to Sonnet regardless of subscription tier. The wrapper passes `--model claude-opus-4-6` explicitly to ensure Opus is used. This is hardcoded in `loom-ada-claude`.

## Setup Flow — Three Phases

The setup is a three-phase process. One ISO, cage as the universal
launchpad, any desktop as the destination.

### Phase 1: Kiosk (`loom.setupPhase = "kiosk"`)

First boot. Cage (Wayland kiosk compositor) runs fullscreen foot terminal
with Ada. The system has nothing but this terminal.

```
cage → foot → sudo -u ada → tmux → loom-ada-claude
                                     ├─ auth server (if no creds)
                                     └─ claude --model claude-opus-4-6 "Hi! I just installed..."
```

Ada greets the user and asks what they want to use the computer for.
Based on the conversation, Ada configures a desktop environment by
editing `/etc/nixos/configuration.nix`:

- Enables compositor/WM (Hyprland, Sway, GNOME, i3, etc.)
- Configures the appropriate display manager with auto-login (greetd for Hyprland/Sway, gdm for GNOME, sddm for KDE)
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

| Phase     | Cage | Auto-login | user→ada sudo | Firewall 9090 | Bootstrap /etc/nixos | Mock approval |
|-----------|------|------------|---------------|---------------|---------------------|---------------|
| kiosk     | yes  | N/A (cage) | yes           | yes           | yes                 | yes           |
| desktop   | no   | Ada config | yes           | no            | no                  | yes           |
| complete  | no   | no         | no            | no            | no                  | no            |

Note: Auto-login in the desktop phase is NOT handled by the loom module. Ada configures
the appropriate display manager (greetd, gdm, sddm) with auto-login as part of the
desktop setup. The module stays out of display manager business.

### Scripts

- **`loom-ada-claude`**: Runs as ada. Handles auth, config pre-seed, launches
  `claude` with initial greeting (kiosk) or `--continue` (resume).
  Accepts a mode argument: `loom-ada-claude` (initial) or `loom-ada-claude resume`.

- **`loom-ada-resume`**: Runs as the human user. Sudos to ada, launches
  `loom-ada-claude resume`. Used in desktop compositor autostart rules.

## Bootstrap `/etc/nixos/`

On first boot (kiosk phase), an activation script seeds `/etc/nixos/` with:

- **`flake.nix`**: Imports `loom.nixosModules.default` (which transitively includes
  nuketown, home-manager, impermanence, sops-nix, and the nixpkgs-unstable overlay).
  The user's flake only needs `nixpkgs` and `loom` as inputs.

- **`configuration.nix`**: Starter config with `loom.enable = true`, `allowUnfreePredicate`
  for claude-code, stub boot loader (`grub.device = mkDefault "nodev"`), empty
  `environment.systemPackages`, and a bare `home-manager.users.user` section.

- **`hardware-configuration.nix`**: Auto-generated via `nixos-generate-config`.

All files are owned by `ada:ada` so Ada can edit them directly.

### `nixosModules.default` Bundles Everything

The loom NixOS module (`loom.nixosModules.default`) includes all transitive dependencies:
- `nuketown.nixosModules.default`
- `home-manager.nixosModules.home-manager`
- `impermanence.nixosModules.impermanence`
- `sops-nix.nixosModules.sops`
- nixpkgs-unstable overlay (provides `pkgs.unstable.*`)

Downstream flakes should NOT need to import these separately. If Ada needs an external
flake input (e.g. zen-browser), she adds it to `/etc/nixos/flake.nix`.

## Key Architecture Decisions

- **tmux runs as ada** — not as the kiosk user. This keeps TMUX socket, BROWSER env, and loom-open all within ada's session boundary.
- **loom-open** splits tmux to show QR codes — claude-code calls $BROWSER or xdg-open, both routed to loom-open.
- **xdg-open shim** is only installed when not in `complete` phase to avoid conflicting with real xdg-open after desktop setup.
- **Cage as universal launchpad** — one ISO, any destination. Cage is minimal Wayland that works on any hardware. The real compositor is chosen in conversation and applied via switch.
- **`claude --continue`** resumes the setup conversation after the compositor switch so Ada can orient the user in the new desktop.
- **Module doesn't manage display managers** — Ada configures the appropriate display manager (greetd, gdm, sddm) as part of desktop setup. The module only handles cage in kiosk phase. This keeps the module generic across all desktop environments (Wayland and X11).
- **Mock approval during setup** — `/run/nuketown-broker/mode` is set to `MOCK_APPROVED` via tmpfiles during kiosk and desktop phases. No GUI session exists for the approval daemon, so sudo auto-approves. Removed in complete phase when the approval daemon runs normally.
- **Human user password** — `initialPassword = "loom"` (configurable via `loom.humanPassword`). Ada helps change it during setup. Needed for tty login if the display manager isn't working.

## Lessons Learned

- **OAuth tokens default to Sonnet** regardless of Max subscription. Must pass `--model claude-opus-4-6` explicitly.
- **`sudo kill` + chained commands** can fail silently — the signal from kill can propagate to the shell, preventing subsequent commands (like `rm`) from running. Always use separate commands.
- **Prompt engineering matters** — Ada spent 5+ minutes exploring the loom module source until the prompt explicitly said "Do NOT read module source code" and described the `/etc/nixos/` file structure. Being specific about what files to edit and what's already in them saves significant time.
- **The module should not mislead** — setting `services.displayManager.autoLogin` without enabling a display manager confused Ada into thinking auto-login was handled. Removed; Ada now configures the full display manager stack herself.
- **Nix store overlay**: `writableStoreUseTmpfs = false` keeps the 9p host store as the read layer while putting writes on the 20GB disk. Best of both worlds for VM testing — host store dedup + sufficient write space.
- **Ada handles complex configs well** — given "I like to code and I like omarchy's vibe", she produced a complete Tokyo Night Hyprland rice (waybar, fuzzel, foot, blur, animations, vim keybinds, screenshots, GTK dark theme) and correctly set up greetd with auto-login. She also pulled in zen-browser from a third-party flake, configured neovim with treesitter, created a shared workshop directory with proper Unix group permissions, and set a wallpaper.
