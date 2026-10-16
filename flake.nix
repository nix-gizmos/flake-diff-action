{
  description = "Report what a flake.lock change does to what a flake builds";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      # writeShellApplication runs shellcheck at build time, and pins the
      # tools on PATH: GNU date/awk/sed even on macOS. `nix` itself is left
      # to the caller, so the report uses the same Nix, store and settings
      # as the rest of the job.
      packages = forSystems (pkgs: rec {
        flake-diff = pkgs.writeShellApplication {
          name = "flake-diff";
          runtimeInputs = with pkgs; [ coreutils diffutils gawk gnugrep gnused git ];
          text = builtins.readFile ./flake-diff.sh;
        };
        flake-diff-comment = pkgs.writeShellApplication {
          name = "flake-diff-comment";
          runtimeInputs = with pkgs; [ coreutils curl gawk jq ];
          text = builtins.readFile ./comment.sh;
        };
        default = flake-diff;
      });

      checks = forSystems (pkgs: {
        inherit (self.packages.${pkgs.stdenv.hostPlatform.system}) flake-diff flake-diff-comment;
        action = pkgs.runCommand "action-shellcheck" { nativeBuildInputs = [ pkgs.shellcheck ]; } ''
          shellcheck ${./action.sh}
          touch $out
        '';
      });
    };
}
