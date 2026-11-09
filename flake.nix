{
  description = "Report what a flake.lock change does to what a flake builds";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # The single source of truth for the version, written by
      # `make release-tag` in the release commit, so the tagged tree and the
      # tag agree.
      version = lib.fileContents ./VERSION;
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
          text = ''
            FLAKE_DIFF_VERSION=${version}
          '' + builtins.readFile ./flake-diff.sh;
        };
        flake-diff-comment = pkgs.writeShellApplication {
          name = "flake-diff-comment";
          runtimeInputs = with pkgs; [ coreutils curl gawk jq ];
          text = builtins.readFile ./comment.sh;
        };
        default = flake-diff;
      });

      devShells = forSystems (pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            gnumake
            shellcheck
            jq

            # Release tooling (see `make release` / `make release-tag`).
            # git-cliff renders the release notes (cliff.toml); gh publishes
            # them; gsemver computes the next version.
            git-cliff
            gh
            (pkgs.callPackage ./nix/gsemver.nix { })
          ];
        };
      });

      checks = forSystems (pkgs:
        let
          pkgs' = self.packages.${pkgs.stdenv.hostPlatform.system};
        in
        {
          inherit (pkgs') flake-diff flake-diff-comment;
          action = pkgs.runCommand "action-shellcheck" { nativeBuildInputs = [ pkgs.shellcheck ]; } ''
            shellcheck ${./action.sh}
            touch $out
          '';
          # The script unwrapped, with its tools on PATH but no curl: the
          # test puts a fake one first, which the wrapped binary's pinned
          # PATH would shadow.
          comment = pkgs.runCommand "comment" { nativeBuildInputs = with pkgs; [ gawk jq ]; } ''
            printf '#!${pkgs.runtimeShell}\nexec ${pkgs.bash}/bin/bash ${./comment.sh} "$@"\n' > flake-diff-comment
            chmod +x flake-diff-comment
            ${pkgs.bash}/bin/bash ${./tests/comment.sh} "$PWD/flake-diff-comment"
            touch $out
          '';
          version = pkgs.runCommand "version" { } ''
            [ "$(${pkgs'.flake-diff}/bin/flake-diff --version)" = "flake-diff ${version}" ]
            touch $out
          '';
        });
    };
}
