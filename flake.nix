{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    utils.url = "github:numtide/flake-utils";
  };
  outputs = { self, nixpkgs, utils }: utils.lib.eachDefaultSystem (system:
    let
      pkgs = nixpkgs.legacyPackages.${system};
    in
    rec {
      packages.default = packages.windscribe;
      packages.windscribe = pkgs.callPackage ./windscribe.nix {};
      apps.windscribe_helper = {
        type = "app";
        program = "${packages.windscribe}/opt/windscribe/helper";
      };
      apps.windscribe_cli = {
        type = "app";
        program = "${packages.windscribe}/opt/windscribe/windscribe-cli";
      };
      apps.windscribe_custom_openvpn = {
        type = "app";
        program = "${packages.windscribe}/opt/windscribe/windscribeopenvpn";
      };
    }
  );
}
