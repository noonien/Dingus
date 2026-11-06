{
  description = "Tests and packaging for Dingus";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    packager = {
      url = "github:BigWigsMods/packager/v2";
      flake = false;
    };
  };

  outputs = { nixpkgs, packager, ... }:
    let
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
    in
    {
      packages.x86_64-linux = {
        # Both run from the addon folder: nix run .#test, nix run .#package
        test = pkgs.writeShellScriptBin "test" ''
          export PATH=${pkgs.lua5_1}/bin:$PATH
          lua tests/run.lua && lua tests/smoke.lua
        '';

        package = pkgs.writeShellScriptBin "package" ''
          export PATH=${pkgs.lib.makeBinPath (with pkgs; [
            coreutils curl findutils gawk git gnugrep gnused jq unzip zip
          ])}:$PATH
          exec ${pkgs.bash}/bin/bash ${packager}/release.sh "$@"
        '';
      };
    };
}
