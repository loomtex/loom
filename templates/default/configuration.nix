# Loom system configuration
#
# Ada will help you customize this through conversation.
# You can also edit it directly if you prefer.
{ config, pkgs, ... }:

{
  # Enable Loom — Ada will guide you through setup on first boot
  loom.enable = true;

  # After setup, Ada sets this to true so your desktop loads directly
  # loom.setupComplete = true;

  # Your machine's hostname
  networking.hostName = "loom";

  # Hardware configuration — generate with:
  #   nixos-generate-config --show-hardware-config
  # Then paste or import the result here.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Filesystem — adjust to match your disk layout
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };
  fileSystems."/boot" = {
    device = "/dev/disk/by-label/boot";
    fsType = "vfat";
  };

  system.stateVersion = "25.11";
}
