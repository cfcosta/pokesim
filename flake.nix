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
    pyproject-nix = {
      url = "github:pyproject-nix/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    uv2nix = {
      url = "github:pyproject-nix/uv2nix";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    pyproject-build-systems = {
      url = "github:pyproject-nix/build-system-pkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.uv2nix.follows = "uv2nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      nixpkgs,
      flake-utils,
      pre-commit-hooks,
      pyproject-build-systems,
      pyproject-nix,
      rust-overlay,
      treefmt-nix,
      uv2nix,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
          overlays = [ (import rust-overlay) ];
        };
        inherit (pkgs) lib mkShell;

        rgbds-1_0_2-hotfix = pkgs.callPackage ./nix/rgbds-1.0.2-hotfix.nix { };

        trainingWorkspace = uv2nix.lib.workspace.loadWorkspace {
          workspaceRoot = ./packages/battle-training;
        };
        trainingOverlay = trainingWorkspace.mkPyprojectOverlay { sourcePreference = "wheel"; };
        trainingEditableOverlay = trainingWorkspace.mkEditablePyprojectOverlay {
          root = "$REPO_ROOT/packages/battle-training";
        };
        trainingCudaOverlay =
          final: prev:
          lib.optionalAttrs pkgs.stdenv.isLinux {
            nvidia-cufile = prev.nvidia-cufile.overrideAttrs (old: {
              buildInputs = (old.buildInputs or [ ]) ++ [ pkgs.rdma-core ];
            });
            nvidia-cusparse = prev.nvidia-cusparse.overrideAttrs (old: {
              buildInputs = (old.buildInputs or [ ]) ++ [ final.nvidia-nvjitlink ];
              postFixup = (old.postFixup or "") + ''
                addAutoPatchelfSearchPath "${final.nvidia-nvjitlink}/${pkgs.python312.sitePackages}/nvidia/cu13/lib"
              '';
            });
            nvidia-cusolver = prev.nvidia-cusolver.overrideAttrs (old: {
              buildInputs = (old.buildInputs or [ ]) ++ [
                final.nvidia-cublas
                final.nvidia-cusparse
                final.nvidia-nvjitlink
              ];
              postFixup = (old.postFixup or "") + ''
                addAutoPatchelfSearchPath "${final.nvidia-cublas}/${pkgs.python312.sitePackages}/nvidia/cu13/lib"
                addAutoPatchelfSearchPath "${final.nvidia-cusparse}/${pkgs.python312.sitePackages}/nvidia/cu13/lib"
                addAutoPatchelfSearchPath "${final.nvidia-nvjitlink}/${pkgs.python312.sitePackages}/nvidia/cu13/lib"
              '';
            });
            nvidia-nvshmem-cu13 = prev.nvidia-nvshmem-cu13.overrideAttrs (old: {
              buildInputs = (old.buildInputs or [ ]) ++ [
                pkgs.rdma-core
                pkgs.libfabric
                pkgs.mpi
              ];
            });
            torch = prev.torch.overrideAttrs (old: {
              buildInputs = (old.buildInputs or [ ]) ++ [
                final.nvidia-cublas
                final.nvidia-cuda-cupti
                final.nvidia-cuda-nvrtc
                final.nvidia-cuda-runtime
                final.nvidia-cudnn-cu13
                final.nvidia-cufft
                final.nvidia-cufile
                final.nvidia-curand
                final.nvidia-cusolver
                final.nvidia-cusparse
                final.nvidia-cusparselt-cu13
                final.nvidia-nccl-cu13
                final.nvidia-nvjitlink
                final.nvidia-nvshmem-cu13
              ];
              postFixup = (old.postFixup or "") + ''
                addAutoPatchelfSearchPath "${final.nvidia-cublas}/${pkgs.python312.sitePackages}/nvidia/cu13/lib"
                addAutoPatchelfSearchPath "${final.nvidia-cuda-cupti}/${pkgs.python312.sitePackages}/nvidia/cu13/lib"
                addAutoPatchelfSearchPath "${final.nvidia-cuda-nvrtc}/${pkgs.python312.sitePackages}/nvidia/cu13/lib"
                addAutoPatchelfSearchPath "${final.nvidia-cuda-runtime}/${pkgs.python312.sitePackages}/nvidia/cu13/lib"
                addAutoPatchelfSearchPath "${final.nvidia-cudnn-cu13}/${pkgs.python312.sitePackages}/nvidia/cudnn/lib"
                addAutoPatchelfSearchPath "${final.nvidia-cufft}/${pkgs.python312.sitePackages}/nvidia/cu13/lib"
                addAutoPatchelfSearchPath "${final.nvidia-cufile}/${pkgs.python312.sitePackages}/nvidia/cu13/lib"
                addAutoPatchelfSearchPath "${final.nvidia-curand}/${pkgs.python312.sitePackages}/nvidia/cu13/lib"
                addAutoPatchelfSearchPath "${final.nvidia-cusolver}/${pkgs.python312.sitePackages}/nvidia/cu13/lib"
                addAutoPatchelfSearchPath "${final.nvidia-cusparse}/${pkgs.python312.sitePackages}/nvidia/cu13/lib"
                addAutoPatchelfSearchPath "${final.nvidia-cusparselt-cu13}/${pkgs.python312.sitePackages}/nvidia/cusparselt/lib"
                addAutoPatchelfSearchPath "${final.nvidia-nccl-cu13}/${pkgs.python312.sitePackages}/nvidia/nccl/lib"
                addAutoPatchelfSearchPath "${final.nvidia-nvjitlink}/${pkgs.python312.sitePackages}/nvidia/cu13/lib"
                addAutoPatchelfSearchPath "${final.nvidia-nvshmem-cu13}/${pkgs.python312.sitePackages}/nvidia/nvshmem/lib"
              '';
              autoPatchelfIgnoreMissingDeps = (old.autoPatchelfIgnoreMissingDeps or [ ]) ++ [
                "libcuda.so.1"
                "libnvidia-ml.so.1"
              ];
            });
          };
        trainingPythonBase = pkgs.callPackage pyproject-nix.build.packages { python = pkgs.python312; };
        trainingPythonSet = trainingPythonBase.overrideScope (
          lib.composeManyExtensions [
            trainingOverlay
            pyproject-build-systems.overlays.wheel
            trainingCudaOverlay
          ]
        );
        trainingEditablePythonSet = trainingPythonSet.overrideScope trainingEditableOverlay;
        trainingVirtualenv = trainingEditablePythonSet.mkVirtualEnv "battle-training-dev-env" trainingWorkspace.deps.all;
        trainingEnvironment = trainingPythonSet.mkVirtualEnv "battle-training-env" trainingWorkspace.deps.default;
        cuda = pkgs.symlinkJoin {
          name = "cuda-redist";
          paths = with pkgs.cudaPackages; [
            cuda_cudart
            cuda_nvcc
            cudnn
            pkgs.cudatoolkit
          ];
        };

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
          battle-training = trainingEnvironment;
          default = rgbds-1_0_2-hotfix;
        };

        devShells.default = mkShell {
          name = "pokegame";

          buildInputs = with pkgs; [
            formatter
            gnumake
            lean4
            rgbds-1_0_2-hotfix
            trainingVirtualenv
            uv
          ];
          env = {
            UV_NO_SYNC = "1";
            UV_PYTHON = trainingEditablePythonSet.python.interpreter;
            UV_PYTHON_DOWNLOADS = "never";
            CUDA_HOME = if pkgs.stdenv.isLinux then "${cuda}" else "";
            CUDA_PATH = if pkgs.stdenv.isLinux then "${cuda}" else "";
            LD_LIBRARY_PATH =
              lib.makeLibraryPath [
                pkgs.stdenv.cc.cc
                pkgs.zlib
                pkgs.xorg.libxcb
                pkgs.libGL
                pkgs.glib
              ]
              + ":/run/opengl-driver/lib:/usr/lib64:/usr/lib";
          };
          shellHook = ''
            unset PYTHONPATH
            export REPO_ROOT=$(git rev-parse --show-toplevel)
          '';
        };

        formatter = formatter;
      }
    );
}
