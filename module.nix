# Loom — the OOTB experience module
#
# This module does NOT wrap nuketown options. It configures nuketown
# directly and adds the first-boot kiosk session where Ada guides
# the user through system setup via conversation.
{ config, lib, pkgs, ... }:

let
  cfg = config.loom;
  prompt = import ./prompt.nix { inherit lib; };
  inSetup = cfg.setupPhase != "complete";
  inKiosk = cfg.setupPhase == "kiosk";

  # Read our own flake.lock to pin nixpkgs in the bootstrap /etc/nixos
  # so builds inside the VM (or first boot) match the host's nix store.
  loomLock = builtins.fromJSON (builtins.readFile ./flake.lock);
  nixpkgsNodeName = loomLock.nodes.root.inputs.nixpkgs;
  nixpkgsLocked = loomLock.nodes.${nixpkgsNodeName}.locked;

  # URL handler for OOTB kiosk — pops a tmux split with QR code.
  # Runs as ada inside ada's tmux session.
  loom-open = pkgs.writeShellScriptBin "loom-open" ''
    URL="$1"
    if [ -z "$URL" ]; then
      exit 1
    fi

    # If we're inside tmux, open a split with the QR code
    if [ -n "$TMUX" ]; then
      ${pkgs.tmux}/bin/tmux split-window -v -l 45% \
        ${pkgs.bash}/bin/bash -c '
          echo ""
          echo "  Scan this QR code with your phone to sign in:"
          echo ""
          ${pkgs.qrencode}/bin/qrencode -t ANSIUTF8 -m 2 "$0"
          echo ""
          echo "  Or open this URL manually:"
          echo "  $0"
          echo ""
          echo "  Press any key to close this pane..."
          read -rsn1
        ' "$URL"
    else
      # Fallback: just print the URL
      echo "Open this URL to sign in:"
      echo "$URL"
    fi
  '';

  # xdg-open shim — claude-code may call xdg-open instead of $BROWSER
  loom-xdg-open = pkgs.writeShellScriptBin "xdg-open" ''
    exec ${loom-open}/bin/loom-open "$@"
  '';

  # HTTP auth server — serves a web form on the local network so the
  # user can paste Claude credentials from their phone.
  loom-auth-server = pkgs.writeScript "loom-auth-server" ''
    #!${pkgs.python3}/bin/python3
    import http.server, json, os, subprocess, sys, socket, threading
    from urllib.parse import parse_qs

    PORT = 9090
    CRED_FILE = os.path.expanduser("~/.claude/.credentials.json")

    HTML_FORM = r"""<!DOCTYPE html>
    <html><head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Loom Setup</title>
      <style>
        * { box-sizing: border-box; }
        body {
          font-family: -apple-system, system-ui, sans-serif;
          max-width: 520px; margin: 0 auto; padding: 24px;
          background: #0d1117; color: #e6edf3;
        }
        h1 { font-size: 1.5em; margin-bottom: 4px; }
        .subtitle { color: #7d8590; margin-bottom: 24px; }
        .step { margin: 16px 0; padding: 16px; border-radius: 8px; background: #161b22; }
        .step-num { color: #58a6ff; font-weight: bold; }
        a { color: #58a6ff; }
        textarea {
          width: 100%; height: 120px; margin: 8px 0; padding: 12px;
          background: #0d1117; color: #e6edf3; border: 1px solid #30363d;
          border-radius: 6px; font-family: monospace; font-size: 14px;
          resize: vertical;
        }
        button {
          width: 100%; padding: 12px; font-size: 16px; font-weight: 600;
          background: #238636; color: #fff; border: none; border-radius: 6px;
          cursor: pointer;
        }
        button:hover { background: #2ea043; }
        .or { text-align: center; color: #7d8590; margin: 12px 0; }
        details { margin-top: 8px; }
        details summary { color: #58a6ff; cursor: pointer; }
        details pre {
          background: #0d1117; padding: 12px; border-radius: 6px;
          overflow-x: auto; font-size: 13px;
        }
      </style>
    </head>
    <body>
      <h1>Welcome to Loom</h1>
      <p class="subtitle">Let's connect your Claude account so Ada can help set up your system.</p>

      <form method="POST">
        <div class="step">
          <p><span class="step-num">1.</span> On a device where you're logged into Claude Code, run:</p>
          <pre style="background:#0d1117;padding:8px;border-radius:4px;">claude setup-token</pre>
          <p style="margin-top:8px;color:#7d8590;font-size:0.9em;">This generates a token you can paste below.</p>
        </div>

        <div class="step">
          <p><span class="step-num">2.</span> Paste your token here:</p>
          <textarea name="credential" placeholder="Paste token, API key (sk-ant-...), or credentials JSON..." required></textarea>
          <button type="submit">Connect</button>
        </div>
      </form>

      <details>
        <summary>Other ways to connect</summary>
        <p><strong>API key:</strong> Paste an Anthropic API key (<code>sk-ant-...</code>).</p>
        <p><strong>Credentials JSON:</strong> Copy <code>~/.claude/.credentials.json</code> from an existing Claude Code installation.</p>
        <p><strong>New to Claude?</strong> Sign up at <a href="https://claude.ai" target="_blank">claude.ai</a>, install <a href="https://docs.anthropic.com/en/docs/claude-code" target="_blank">Claude Code</a> on any device, log in, then run <code>claude setup-token</code>.</p>
      </details>
    </body></html>"""

    HTML_SUCCESS = r"""<!DOCTYPE html>
    <html><head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Loom — Connected!</title>
      <style>
        body {
          font-family: -apple-system, system-ui, sans-serif;
          max-width: 520px; margin: 0 auto; padding: 24px;
          background: #0d1117; color: #e6edf3; text-align: center;
        }
        .check { font-size: 64px; margin: 40px 0 16px; }
        h1 { color: #3fb950; }
      </style>
    </head>
    <body>
      <div class="check">&#10003;</div>
      <h1>Connected!</h1>
      <p>You can close this page and return to your Loom screen.</p>
      <p style="color:#7d8590;">Ada is starting up...</p>
    </body></html>"""

    HTML_ERROR = r"""<!DOCTYPE html>
    <html><head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Loom — Error</title>
      <style>
        body {{
          font-family: -apple-system, system-ui, sans-serif;
          max-width: 520px; margin: 0 auto; padding: 24px;
          background: #0d1117; color: #e6edf3;
        }}
        h1 {{ color: #f85149; }}
        a {{ color: #58a6ff; }}
      </style>
    </head>
    <body>
      <h1>Something went wrong</h1>
      <p>{message}</p>
      <p><a href="/">Try again</a></p>
    </body></html>"""

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, format, *args):
            pass  # quiet

        def do_GET(self):
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.end_headers()
            self.wfile.write(HTML_FORM.encode())

        def do_POST(self):
            length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(length).decode()
            params = parse_qs(body)
            credential = params.get("credential", [""])[0].strip()

            if not credential:
                self._error("No credential provided.")
                return

            os.makedirs(os.path.dirname(CRED_FILE), exist_ok=True)

            # Detect format: setup token vs API key vs OAuth JSON vs raw token
            # Setup tokens from `claude setup-token` start with sk-ant-oat
            # API keys start with sk-ant-api
            if credential.startswith("sk-ant-api"):
                # Anthropic API key — write as env file for ada-claude to source
                env_file = os.path.expanduser("~/.claude/.api-key")
                with open(env_file, "w") as f:
                    f.write(credential)
                os.chmod(env_file, 0o600)
            elif credential.startswith("sk-ant-"):
                # OAuth setup token (e.g. sk-ant-oat01-...) — save for CLAUDE_CODE_OAUTH_TOKEN
                token_file = os.path.expanduser("~/.claude/.oauth-token")
                with open(token_file, "w") as f:
                    f.write(credential)
                os.chmod(token_file, 0o600)
            elif credential.startswith("{"):
                # Raw credentials JSON
                try:
                    json.loads(credential)
                except json.JSONDecodeError:
                    self._error("Invalid JSON. Please check and try again.")
                    return
                with open(CRED_FILE, "w") as f:
                    f.write(credential)
                os.chmod(CRED_FILE, 0o600)
            else:
                # Treat as a setup token — save for CLAUDE_CODE_OAUTH_TOKEN env var
                token_file = os.path.expanduser("~/.claude/.oauth-token")
                with open(token_file, "w") as f:
                    f.write(credential)
                os.chmod(token_file, 0o600)

            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.end_headers()
            self.wfile.write(HTML_SUCCESS.encode())

            # Signal the wrapper script that auth is done
            print("AUTH_COMPLETE", flush=True)
            # Shut down after the response is sent
            threading.Timer(1.0, lambda: os._exit(0)).start()

        def _error(self, message):
            self.send_response(400)
            self.send_header("Content-Type", "text/html")
            self.end_headers()
            self.wfile.write(HTML_ERROR.format(message=message).encode())

    # Find local IP
    def get_local_ip():
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.connect(("1.1.1.1", 80))
            ip = s.getsockname()[0]
            s.close()
            return ip
        except Exception:
            return "0.0.0.0"

    ip = get_local_ip()
    url = f"http://{ip}:{PORT}/"

    # Print QR code to terminal
    print()
    print("  \033[1mLoom Setup — Connect Your Claude Account\033[0m")
    print()
    print("  Scan this QR code with your phone:")
    print()
    subprocess.run(["${pkgs.qrencode}/bin/qrencode", "-t", "ANSIUTF8", "-m", "2", url])
    print()
    print(f"  Or open: \033[4m{url}\033[0m")
    print()
    print("  Waiting for credentials...")
    print()

    server = http.server.HTTPServer(("", PORT), Handler)
    server.serve_forever()
  '';

  # Wrapper that checks for credentials, runs auth server if needed,
  # then launches claude. Accepts "resume" argument to continue a session.
  loom-ada-claude = pkgs.writeShellScript "loom-ada-claude" ''
    CRED_FILE="$HOME/.claude/.credentials.json"
    API_KEY_FILE="$HOME/.claude/.api-key"
    OAUTH_TOKEN_FILE="$HOME/.claude/.oauth-token"

    # If no credentials exist, run the auth server first
    if [ ! -f "$CRED_FILE" ] && [ ! -f "$API_KEY_FILE" ] && [ ! -f "$OAUTH_TOKEN_FILE" ]; then
      ${loom-auth-server}
    fi

    # Source the appropriate credential
    if [ -f "$OAUTH_TOKEN_FILE" ]; then
      export CLAUDE_CODE_OAUTH_TOKEN="$(cat "$OAUTH_TOKEN_FILE")"
    elif [ -f "$API_KEY_FILE" ]; then
      export ANTHROPIC_API_KEY="$(cat "$API_KEY_FILE")"
    fi

    # Pre-seed claude-code config to skip onboarding and bypass permissions warning
    # The onboarding flow includes an auth step that conflicts with setup tokens.
    CONFIG_FILE="$HOME/.claude/.config.json"
    if [ ! -f "$CONFIG_FILE" ]; then
      mkdir -p "$(dirname "$CONFIG_FILE")"
      echo '{"hasCompletedOnboarding":true,"theme":"dark","bypassPermissionsModeAccepted":true}' > "$CONFIG_FILE"
    fi

    export BROWSER=${loom-open}/bin/loom-open
    cd ~/projects/system

    case "''${1:-initial}" in
      resume)
        exec claude --dangerously-skip-permissions --model claude-opus-4-6 --continue
        ;;
      *)
        exec claude --dangerously-skip-permissions --model claude-opus-4-6 "Hi! I just installed Loom and booted for the first time. Help me set up my system."
        ;;
    esac
  '';

  # Resume script — runs as the human user, sudos to ada, continues
  # the conversation. Used in compositor autostart rules after the
  # kiosk → desktop transition.
  loom-ada-resume = pkgs.writeShellScriptBin "loom-ada-resume" ''
    exec sudo -u ada ${pkgs.bash}/bin/bash -l -c "exec ${loom-ada-claude} resume"
  '';

in
{
  options.loom = {
    enable = lib.mkEnableOption "Loom — conversational system setup with Ada";

    setupPhase = lib.mkOption {
      type = lib.types.enum [ "kiosk" "desktop" "complete" ];
      default = "kiosk";
      description = ''
        Current setup phase:
        - "kiosk": First boot. Cage kiosk with Ada. User chooses a desktop.
        - "desktop": Desktop configured. Ada resumes in the new environment.
          Auto-login and user→ada sudo still active.
        - "complete": Setup done. Normal operation with greeter and approval daemon.
      '';
    };

    humanUser = lib.mkOption {
      type = lib.types.str;
      default = "user";
      description = "Username for the human operator";
    };

    humanPassword = lib.mkOption {
      type = lib.types.str;
      default = "loom";
      description = ''
        Initial password for the human user.
        Ada will help change this during setup.
      '';
    };
  };

  config = lib.mkIf cfg.enable {

    # ── Base System ──────────────────────────────────────────────
    nix.settings.experimental-features = [ "nix-command" "flakes" ];

    networking.networkmanager.enable = true;

    # Open the auth server port during kiosk phase so the user can paste
    # credentials from their phone via the local network
    networking.firewall.allowedTCPPorts = lib.mkIf inKiosk [ 9090 ];
    time.timeZone = lib.mkDefault "UTC";
    i18n.defaultLocale = lib.mkDefault "en_US.UTF-8";

    # ── Human User ───────────────────────────────────────────────
    users.mutableUsers = lib.mkDefault false;
    users.users.${cfg.humanUser} = {
      isNormalUser = true;
      initialPassword = cfg.humanPassword;
      extraGroups = [ "wheel" "networkmanager" "video" "audio" ];
      uid = lib.mkDefault 1000;
    };
    users.users.root.hashedPassword = lib.mkDefault "!";

    # Let the human sudo without a password during setup
    security.sudo.wheelNeedsPassword = lib.mkDefault false;

    # ── Nuketown: Ada as the system agent ────────────────────────
    nuketown = {
      enable = true;
      humanUser = cfg.humanUser;

      agents.ada = {
        enable = true;
        uid = 1100;
        role = "system";
        description = ''
          System setup and management agent for Loom.
          Helps the user configure their NixOS system through conversation.
        '';

        git = {
          name = "Ada";
          email = "ada@loom.local";
          signing = false; # No GPG keys in default loom install
        };

        persist = [ "projects" ".claude" ];
        sudo.enable = true;
        portal.enable = true;

        packages = [ pkgs.nvd ]
          ++ lib.optionals inSetup [ loom-xdg-open ];

        claudeCode = {
          enable = true;
          settings = {
            permissions = {
              defaultMode = "bypassPermissions";
            };
            spinnerTipsEnabled = false;
          };
          extraPrompt =
            if inSetup
            then prompt.setupMode
            else prompt.normalMode;
        };

        extraHomeConfig = {
          home.stateVersion = "25.11";
          programs.neovim = {
            enable = true;
            vimAlias = true;
            defaultEditor = true;
          };
        };
      };
    };

    # ── Home-manager for human user ──────────────────────────────
    home-manager.users.${cfg.humanUser} = { ... }: {
      home.stateVersion = "25.11";
    };

    # ── OOTB Kiosk Session (kiosk phase only) ────────────────────
    # Cage runs a fullscreen terminal with Ada. After Ada configures
    # a desktop and switches to "desktop" phase, cage is no longer
    # configured and the real compositor takes over.

    services.cage = lib.mkIf inKiosk {
      enable = true;
      user = cfg.humanUser;
      program = let
        # Starts tmux as ada — runs auth flow if needed, then claude
        ada-tmux = pkgs.writeShellScript "loom-ada-tmux" ''
          exec ${pkgs.tmux}/bin/tmux new-session -s loom "${loom-ada-claude}" \; \
            set status off
        '';

        # Entry point: wait for network, then sudo into ada and start tmux
        ada-session = pkgs.writeShellScript "loom-ada-session" ''
          # Give networkmanager a moment to connect
          sleep 2

          # sudo into ada, run tmux as ada — keeps TMUX, BROWSER, and
          # the tmux socket all within ada's session boundary
          exec sudo -u ada ${pkgs.bash}/bin/bash -l ${ada-tmux}
        '';
      in "${pkgs.foot}/bin/foot --fullscreen ${ada-session}";
    };

    # No display manager configured here — Ada sets up the appropriate
    # display manager + auto-login as part of desktop configuration.
    # (GNOME → gdm, Hyprland/Sway → greetd, KDE → sddm, etc.)

    # Let the human user sudo to ada without a password (for kiosk and desktop phases)
    # In kiosk: the cage → foot → sudo -u ada chain
    # In desktop: the loom-ada-resume autostart script
    security.sudo.extraRules = lib.mkIf inSetup [
      {
        users = [ cfg.humanUser ];
        runAs = "ada:ada";
        commands = [
          { command = "ALL"; options = [ "NOPASSWD" "SETENV" ]; }
        ];
      }
    ];

    security.polkit.enable = true;

    # Auto-approve sudo during setup — no human GUI session for the
    # approval daemon, so Ada needs auto-approval to nixos-rebuild.
    # Removed when setup is complete and the approval daemon runs normally.
    systemd.tmpfiles.rules = lib.mkIf inSetup [
      "d /run/nuketown-broker 2750 ${cfg.humanUser} nuketown-broker -"
      "f /run/nuketown-broker/mode 0644 ${cfg.humanUser} users - MOCK_APPROVED"
    ];

    # Ensure home-manager has activated the user's profile before the
    # display manager starts — otherwise auto-login can launch the
    # compositor before ~/.config exists (no HM-managed config).
    systemd.services.display-manager = lib.mkIf inSetup {
      after = [ "home-manager-${cfg.humanUser}.service" ];
      wants = [ "home-manager-${cfg.humanUser}.service" ];
    };

    # Make loom-ada-resume available in the human user's PATH during setup
    # (used in compositor autostart rules after the kiosk → desktop switch)
    environment.systemPackages = lib.mkIf inSetup [ loom-ada-resume ];

    # ── Bootstrap /etc/nixos ─────────────────────────────────────
    # Seed an editable NixOS flake configuration so Ada has something
    # to modify during setup. Runs as a systemd service (not activation
    # script) so it executes AFTER impermanence bind mounts are up.
    systemd.services.loom-bootstrap = lib.mkIf inKiosk (let
      sysDir = "${config.nuketown.agentsDir}/ada/projects/system";
    in {
      description = "Bootstrap Loom system configuration";
      wantedBy = [ "multi-user.target" ];
      after = [ "local-fs.target" ];
      before = [ "cage-tty1.service" ];
      unitConfig.ConditionPathExists = "!${sysDir}/flake.nix";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        mkdir -p ${sysDir}

        cat > ${sysDir}/flake.nix << 'FLAKE'
      {
        description = "Loom system configuration";

        inputs = {
          nixpkgs.url = "github:nixos/nixpkgs/${nixpkgsLocked.rev}";
          loom.url = "github:loomtex/loom";
          loom.inputs.nixpkgs.follows = "nixpkgs";
        };

        outputs = { nixpkgs, loom, ... }: {
          nixosConfigurations.loom = nixpkgs.lib.nixosSystem {
            system = "${pkgs.stdenv.hostPlatform.system}";
            modules = [
              loom.nixosModules.default
              ./hardware-configuration.nix
              ./configuration.nix
            ];
          };
        };
      }
      FLAKE

        # Detect boot firmware and set the right bootloader
        if [ -d /sys/firmware/efi ]; then
          BOOT_CONFIG='boot.loader.systemd-boot.enable = true;
        boot.loader.efi.canTouchEfiVariables = true;'
        else
          BOOT_CONFIG='# Ada configures grub.device for the target disk
        boot.loader.grub.device = lib.mkDefault "nodev";'
        fi

        cat > ${sysDir}/configuration.nix << CONFIG
      { config, pkgs, lib, ... }:
      {
        system.stateVersion = "25.11";

        # ── Boot ──
        $BOOT_CONFIG

        loom.enable = true;
        # loom.setupPhase = "desktop";   # Ada changes this during setup
        # loom.setupPhase = "complete";  # Ada sets this when fully done

        nixpkgs.config.allowUnfreePredicate = pkg:
          builtins.elem (lib.getName pkg) [ "claude-code" ];

        # ── System Packages ──
        # Ada adds packages here during setup
        environment.systemPackages = with pkgs; [
        ];

        # ── Desktop ──
        # Ada configures the desktop environment here

        # ── User Environment ──
        home-manager.useGlobalPkgs = true;
        home-manager.useUserPackages = true;
        home-manager.users.${cfg.humanUser} = { pkgs, ... }: {
          home.stateVersion = "25.11";

          # Ada configures user programs and dotfiles here
        };
      }
      CONFIG

        cat > ${sysDir}/CLAUDE.md << 'CLAUDEMD'
      # System Configuration

      This is the NixOS system configuration flake. Edit `configuration.nix`
      for system and user changes. The flake provides nixpkgs, home-manager,
      impermanence, sops-nix, and a `pkgs.unstable` overlay.

      ## NixOS 25.11 Gotchas

      ### Display Manager Options
      - `services.xserver.displayManager.autoLogin` is deprecated
      - Use `services.displayManager.autoLogin` (top-level, not under xserver)

      ### Home-Manager Neovim
      - **Treesitter**: Use `programs.neovim.plugins` with
        `pkgs.vimPlugins.nvim-treesitter.withPlugins (p: [ p.nix p.lua ... ])`
        Do NOT use the old `configure.packages` or `configure.customRC` approach.
      - **LSP**: Use `pkgs.vimPlugins.nvim-lspconfig` as a plugin and configure
        servers in `extraLuaConfig`. There is no `programs.neovim.lsp` option.
      - **Plugin config**: Use `extraLuaConfig` for Lua or `extraConfig` for
        vimscript. Prefer Lua for modern plugins.

      ### Hyprland
      - System-level: `programs.hyprland.enable = true;`
      - User-level config via home-manager: `wayland.windowManager.hyprland`
      - Both are needed — system-level provides the binary and session,
        user-level provides the config file.

      ### Packages
      - Use `pkgs.unstable.<pkg>` for packages that need a newer version
        than the 25.11 release branch provides.
      CLAUDEMD

        # Generate hardware-configuration.nix from the running system
        ${pkgs.nixos-install-tools}/bin/nixos-generate-config --show-hardware-config > ${sysDir}/hardware-configuration.nix 2>/dev/null || true

        # Make it writable by ada for editing
        chown -R ada:ada ${sysDir}

        # Symlink /etc/nixos so standard NixOS tools work
        rm -rf /etc/nixos
        ln -s ${sysDir} /etc/nixos
      '';
    });

    # Ensure /etc/nixos symlink exists (runs every activation, even after
    # bootstrap has already created the project dir on a previous boot).
    system.activationScripts.loom-etcnixos-symlink = lib.mkIf inKiosk (let
      sysDir = "${config.nuketown.agentsDir}/ada/projects/system";
    in ''
      if [ -d ${sysDir} ] && { [ ! -L /etc/nixos ] || [ "$(readlink /etc/nixos)" != "${sysDir}" ]; }; then
        rm -rf /etc/nixos
        ln -s ${sysDir} /etc/nixos
      fi
    '');

    # If local loom source is available via 9p (VM testing), patch the
    # bootstrap flake to use it instead of the GitHub URL. Runs after
    # loom-bootstrap so the files exist.
    systemd.services.loom-dev-source = lib.mkIf inKiosk (let
      sysDir = "${config.nuketown.agentsDir}/ada/projects/system";
    in {
      description = "Patch Loom config for local development source";
      wantedBy = [ "multi-user.target" ];
      after = [ "local-fs.target" "loom-bootstrap.service" ];
      before = [ "cage-tty1.service" ];
      unitConfig.ConditionPathExists = "/tmp/loom-src/module.nix";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        if [ -f ${sysDir}/flake.nix ]; then
          ${pkgs.gnused}/bin/sed -i 's|loom.url = "github:loomtex/loom"|loom.url = "path:/tmp/loom-src"|' ${sysDir}/flake.nix

          # Regenerate hardware-configuration.nix so it gets the base
          # hardware right (disk UUIDs, qemu-guest profile, etc).
          ${pkgs.nixos-install-tools}/bin/nixos-generate-config --show-hardware-config > ${sysDir}/hardware-configuration.nix 2>/dev/null || true

          # nixos-generate-config detects the 9p/overlay mounts but produces
          # broken entries (missing mount options). Remove them — we provide
          # correct entries in vm-store.nix instead.
          ${pkgs.gnused}/bin/sed -i '/fileSystems."\/nix\/.ro-store"/,/};/d' ${sysDir}/hardware-configuration.nix
          ${pkgs.gnused}/bin/sed -i '/fileSystems."\/nix\/store"/,/};/d' ${sysDir}/hardware-configuration.nix
          ${pkgs.gnused}/bin/sed -i '/fileSystems."\/tmp\/loom-src"/,/};/d' ${sysDir}/hardware-configuration.nix
          ${pkgs.gnused}/bin/sed -i '/fileSystems."\/tmp\/shared"/,/};/d' ${sysDir}/hardware-configuration.nix
          ${pkgs.gnused}/bin/sed -i '/fileSystems."\/tmp\/xchg"/,/};/d' ${sysDir}/hardware-configuration.nix

          # Add import for vm-store.nix
          ${pkgs.gnused}/bin/sed -i 's|imports =|imports = [ ./vm-store.nix ]  ++|' ${sysDir}/hardware-configuration.nix

          # Write proper VM store mounts with correct options
          cat > ${sysDir}/vm-store.nix << 'VMSTORE'
        # VM-specific nix store mounts (9p host store + overlayfs).
        # Auto-generated by loom-dev-source — only present in VM testing.
        {
          boot.initrd.availableKernelModules = [ "9p" "9pnet_virtio" "overlay" ];

          fileSystems."/nix/.ro-store" = {
            device = "nix-store";
            fsType = "9p";
            options = [ "trans=virtio" "version=9p2000.L" "cache=loose" ];
            neededForBoot = true;
          };

          fileSystems."/nix/store" = {
            overlay = {
              lowerdir = [ "/nix/.ro-store" ];
              upperdir = "/nix/.rw-store/upper";
              workdir = "/nix/.rw-store/work";
            };
            neededForBoot = true;
          };

          fileSystems."/tmp/loom-src" = {
            device = "loom-src";
            fsType = "9p";
            options = [ "trans=virtio" "version=9p2000.L" ];
          };
        }
        VMSTORE

          chown ada:ada ${sysDir}/hardware-configuration.nix ${sysDir}/vm-store.nix
        fi
      '';
    });

    # ── Audio/Video Basics ───────────────────────────────────────
    security.rtkit.enable = true;
    services.pipewire = {
      enable = lib.mkDefault true;
      alsa.enable = true;
      pulse.enable = true;
    };

    # ── Fonts ────────────────────────────────────────────────────
    fonts = {
      enableDefaultPackages = true;
      packages = with pkgs; [
        nerd-fonts.sauce-code-pro
      ];
    };

    # ── SSH for remote access ────────────────────────────────────
    services.openssh = {
      enable = lib.mkDefault true;
      settings.PermitRootLogin = "no";
    };
  };
}
