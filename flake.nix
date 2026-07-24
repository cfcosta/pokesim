{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    pre-commit-hooks = {
      url = "github:cachix/pre-commit-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      nixpkgs,
      flake-utils,
      pre-commit-hooks,
      rust-overlay,
      treefmt-nix,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ (import rust-overlay) ];
        };
        inherit (pkgs) mkShell;

        rgbds-1_0_2-hotfix = pkgs.callPackage ./nix/rgbds-1.0.2-hotfix.nix { };

        formatter =
          (treefmt-nix.lib.evalModule pkgs {
            projectRootFile = "flake.nix";

            settings = {
              allow-missing-formatter = true;
              verbose = 0;
              global.excludes = [ "*.lock" ];

              formatter.nixfmt.options = [ "--strict" ];
            };

            programs.nixfmt.enable = true;
          }).config.build.wrapper;

        pre-commit-check = pre-commit-hooks.lib.${system}.run {
          src = ./.;

          hooks = {
            deadnix.enable = true;
            nixfmt-rfc-style.enable = true;
            treefmt = {
              enable = true;
              package = formatter;
            };
          };
        };
      in
      {
        checks = {
          inherit pre-commit-check;
          rgbds = rgbds-1_0_2-hotfix;
        };

        packages = {
          rgbds = rgbds-1_0_2-hotfix;
          default = rgbds-1_0_2-hotfix;
        };

        devShells.default = mkShell {
          name = "pokegame";

          buildInputs = with pkgs; [
            formatter
            gnumake
            lean4
            rgbds-1_0_2-hotfix
          ];
        };

        formatter = formatter;
      }
    );
}
