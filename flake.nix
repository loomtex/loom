{
  description = "Loom — a Linux distribution you set up by talking to it";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager/release-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    disko = {
      url = "github:nix-community/disko/latest";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    impermanence.url = "github:nix-community/impermanence";

    nuketown = {
      url = "github:joshperry/nuketown";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
      inputs.impermanence.follows = "impermanence";
    };

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs@{ self, nixpkgs, nixpkgs-unstable, home-manager, disko, impermanence, nuketown, sops-nix, ... }:
  let
    systems = [ "x86_64-linux" "aarch64-linux" ];
    forAllSystems = nixpkgs.lib.genAttrs systems;

    # Common modules shared between installer target, VM, and real installs
    loomModules = system: [
      ./module.nix
      nuketown.nixosModules.default
      home-manager.nixosModules.home-manager
      impermanence.nixosModules.impermanence
      sops-nix.nixosModules.sops
      ({ config, pkgs, ... }: {
        nixpkgs.overlays = [
          (final: prev: {
            unstable = import nixpkgs-unstable {
              inherit system;
              config.allowUnfree = true;
            };
          })
        ];
      })
    ];

    # Build an installer ISO for a given system architecture
    mkInstaller = { system }:
    let
      pkgs = import nixpkgs { inherit system; };
      lib = pkgs.lib;

      targetSystem = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = (loomModules system) ++ [
          disko.nixosModules.disko
          ({ pkgs, ... }: {
            system.stateVersion = "25.11";
            nixpkgs.config.allowUnfreePredicate = pkg:
              builtins.elem (lib.getName pkg) [ "claude-code" ];

            boot.loader.systemd-boot.enable = true;
            boot.loader.efi.canTouchEfiVariables = true;
            fileSystems."/" = { device = "/dev/disk/by-label/nixos"; fsType = "ext4"; };
            fileSystems."/boot" = { device = "/dev/disk/by-label/boot"; fsType = "vfat"; };

            networking.hostName = "loom";
            loom.enable = true;
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
          })
        ];
      };

      installerSystem = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          "${nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix"
          ({ pkgs, lib, ... }: {
            nix.settings.experimental-features = [ "nix-command" "flakes" ];

            services.openssh.settings.PermitRootLogin = lib.mkForce "yes";

            boot = {
              kernelPackages = pkgs.linuxPackages_latest;
              supportedFilesystems = lib.mkForce [ "btrfs" "vfat" "f2fs" "xfs" "ntfs" "ext4" ];
            };

            networking.hostName = "loom-installer";

            systemd = {
              services.sshd.wantedBy = lib.mkForce [ "multi-user.target" ];
              targets = {
                sleep.enable = false;
                suspend.enable = false;
                hibernate.enable = false;
                hybrid-sleep.enable = false;
              };
            };

            environment.systemPackages = with pkgs; [
              (writeShellScriptBin "install-system" ''
                set -e
                echo "=== Loom Installer ==="
                echo ""
                echo "This will install Loom to your disk."
                echo "Ada will help you set up your system after the first boot."
                echo ""

                echo "Available disks:"
                ${pkgs.util-linux}/bin/lsblk -d -o NAME,SIZE,MODEL | grep -v loop
                echo ""

                read -p "Install to which disk? (e.g. /dev/sda): " DISK

                if [[ ! -b "$DISK" ]]; then
                  echo "Error: $DISK is not a block device"
                  exit 1
                fi

                echo ""
                echo "WARNING: This will ERASE ALL DATA on $DISK"
                read -p "Continue? [y/N] " confirm
                [[ "''${confirm,,}" != y* ]] && exit 1

                echo ""
                echo "Partitioning $DISK..."

                ${pkgs.parted}/bin/parted -s "$DISK" -- \
                  mklabel gpt \
                  mkpart boot fat32 1MiB 512MiB \
                  set 1 esp on \
                  mkpart nixos ext4 512MiB 100%

                PART1="''${DISK}1"
                PART2="''${DISK}2"
                if [[ "$DISK" == *nvme* ]] || [[ "$DISK" == *mmcblk* ]]; then
                  PART1="''${DISK}p1"
                  PART2="''${DISK}p2"
                fi

                echo "Formatting..."
                mkfs.vfat -F 32 -n boot "$PART1"
                mkfs.ext4 -L nixos "$PART2"

                echo "Mounting..."
                mount "$PART2" /mnt
                mkdir -p /mnt/boot
                mount "$PART1" /mnt/boot

                echo "Installing NixOS..."
                nixos-install --system "${targetSystem.config.system.build.toplevel}" --no-root-passwd

                echo ""
                echo "=== Installation complete! ==="
                echo "Remove the installer media and reboot."
                echo "Ada will greet you on first boot."
              '')
            ];

            environment.shellInit = ''
              echo ""
              echo "=== Loom Installer ==="
              echo "Run: install-system"
              echo ""
            '';
          })
        ];
      };
    in
    installerSystem;

    # VM for testing the first-boot experience
    # Build: nix build .#vm
    # Run:   ./result/bin/run-loom-vm
    mkVM = { system ? "x86_64-linux" }:
    let
      vmSystem = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = (loomModules system) ++ [
          ({ config, pkgs, lib, ... }: {
            system.stateVersion = "25.11";
            nixpkgs.config.allowUnfreePredicate = pkg:
              builtins.elem (lib.getName pkg) [ "claude-code" ];

            boot.loader.grub.device = "/dev/vda";
            fileSystems."/" = {
              device = "/dev/vda1";
              fsType = "ext4";
            };

            networking.hostName = "loom";

            loom.enable = true;

            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;

            # SSH access for debugging — ada's key authorized on both users
            users.users.user.openssh.authorizedKeys.keys = [
              "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH4wKwiX1fnwB/U4Mc7JT4ddMExopexk0DUSd7Du12Sp"
            ];
            users.users.ada = {
              openssh.authorizedKeys.keys = [
                "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH4wKwiX1fnwB/U4Mc7JT4ddMExopexk0DUSd7Du12Sp"
              ];
            };

            # VM resources and display
            virtualisation.vmVariant = {
              virtualisation = {
                memorySize = 4096;
                cores = 4;
                diskSize = 20480;
                graphics = true;
                qemu.options = [
                  "-vga virtio"
                  "-display gtk,gl=on"
                ];
                forwardPorts = [
                  { from = "host"; host.port = 2222; guest.port = 22; }
                  { from = "host"; host.port = 9090; guest.port = 9090; }
                ];
              };
            };
          })
        ];
      };
    in
    vmSystem.config.virtualisation.vmVariant.system.build.vm;

  in {
    # The loom NixOS module — import this in your configuration
    nixosModules.default = { ... }: {
      imports = [
        nuketown.nixosModules.default
        ./module.nix
      ];
    };

    # Installer ISOs
    nixosConfigurations = {
      installer-x86_64 = mkInstaller { system = "x86_64-linux"; };
      installer-aarch64 = mkInstaller { system = "aarch64-linux"; };
    };

    # Template for manual setup on existing NixOS
    templates.default = {
      path = ./templates/default;
      description = "Loom — conversational NixOS setup with Ada";
    };

    # Test VM — build and run:
    #   nix build .#vm
    #   ./result/bin/run-loom-vm
    packages.x86_64-linux.vm = mkVM {};
    packages.aarch64-linux.vm = mkVM { system = "aarch64-linux"; };

    # Development shell
    devShells = forAllSystems (system:
      let pkgs = import nixpkgs { inherit system; };
      in {
        default = pkgs.mkShell {
          packages = with pkgs; [ nvd nixos-rebuild ];
          shellHook = ''
            echo "Loom development shell"
            echo ""
            echo "Build VM:       nix build .#vm"
            echo "Build installer: nix build .#nixosConfigurations.installer-x86_64.config.system.build.isoImage"
            echo ""
          '';
        };
      }
    );
  };
}
