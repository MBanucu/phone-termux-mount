{
  description = "Mount an adb-connected Android phone's Termux home on NixOS, over sshfs";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      nixosModules.default = ./module.nix;
      nixosModules.phone-termux-mount = ./module.nix;

      # The pre-mount helper on its own, for running by hand:
      #   nix run .#phone-termux-link
      # Override with PHONE_PORT / PHONE_HOST / PHONE_USER / PHONE_KEY.
      packages = forAllSystems (pkgs: {
        phone-termux-link = import ./lib/ensure-link.nix { inherit pkgs; };
        # Establishes the Wi-Fi transport on its own:
        #   PHONE_HOST=10.223.158.226 nix run .#phone-connect
        phone-connect = import ./lib/connect.nix { inherit pkgs; };
        default = self.packages.${pkgs.stdenv.hostPlatform.system}.phone-termux-link;
      });

      apps = forAllSystems (pkgs: {
        default = self.apps.${pkgs.stdenv.hostPlatform.system}.phone-connect;
        phone-connect = {
          type = "app";
          # writeShellScript makes the store path the executable itself.
          program = "${self.packages.${pkgs.stdenv.hostPlatform.system}.phone-connect}";
        };
      });

      # The self-heal logic, exercised with stubbed commands so it needs no
      # phone, FUSE mount, systemd or root: nix flake check
      checks = forAllSystems (pkgs: {
        self-heal = import ./checks.nix { inherit pkgs; };
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt);
    };
}
