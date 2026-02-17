# Standalone installer builder
#
# Used by the flake to create installer ISOs.
# Can also be imported directly for custom installer builds.
#
# Usage from flake:
#   nix build .#nixosConfigurations.installer-x86_64.config.system.build.isoImage
{ nixpkgs, system ? "x86_64-linux", targetSystem }:

let
  pkgs = import nixpkgs { inherit system; };
  lib = pkgs.lib;
in
nixpkgs.lib.nixosSystem {
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
}
