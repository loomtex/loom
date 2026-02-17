{
  description = "My Loom system";

  inputs = {
    loom.url = "github:loomtex/loom";
    nixpkgs.follows = "loom/nixpkgs";
  };

  outputs = { self, loom, nixpkgs, ... }: {
    nixosConfigurations.default = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        loom.nixosModules.default
        ./configuration.nix
      ];
    };
  };
}
