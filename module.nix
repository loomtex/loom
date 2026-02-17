# Loom — the OOTB experience module
#
# This module does NOT wrap nuketown options. It configures nuketown
# directly and adds the first-boot kiosk session where Ada guides
# the user through system setup via conversation.
{ config, lib, pkgs, ... }:

let
  cfg = config.loom;
  prompt = import ./prompt.nix { inherit lib; };
in
{
  options.loom = {
    enable = lib.mkEnableOption "Loom — conversational system setup with Ada";

    setupComplete = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Set to true after first setup is complete.
        When false, the system boots into a kiosk session with Ada.
        When true, the system boots normally through the configured display manager.
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

        packages = [ pkgs.nvd ];

        claudeCode = {
          enable = true;
          settings = {
            permissions = {
              defaultMode = "bypassPermissions";
            };
          };
          extraPrompt =
            if cfg.setupComplete
            then prompt.normalMode
            else prompt.setupMode;
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

    # ── OOTB Kiosk Session (first boot) ──────────────────────────
    # When setup is not complete, boot into a cage kiosk running
    # a terminal with Ada (claude-code).
    #
    # After Ada configures a desktop, she sets loom.setupComplete = true
    # and the next boot goes through the normal display manager.

    services.cage = lib.mkIf (!cfg.setupComplete) {
      enable = true;
      user = cfg.humanUser;
      program = let
        ada-session = pkgs.writeShellScript "loom-ada-session" ''
          # Give networkmanager a moment to connect
          sleep 2

          # Launch Ada via machinectl shell (proper login environment)
          # Fall back to a plain shell if machinectl isn't available
          exec /run/current-system/sw/bin/machinectl shell ada@ \
            ${pkgs.bash}/bin/bash -l -c \
            "cd ~/projects && exec claude"
        '';
      in "${pkgs.foot}/bin/foot --fullscreen ${ada-session}";
    };

    # Auto-login for the kiosk session
    services.displayManager.autoLogin = lib.mkIf (!cfg.setupComplete) {
      enable = true;
      user = cfg.humanUser;
    };

    # Polkit for machinectl shell access
    security.polkit.enable = true;

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
