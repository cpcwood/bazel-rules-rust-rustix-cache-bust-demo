{
  description = "Repro: rules_rust build scripts emit path-dependent output, busting downstream Bazel cache keys";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs = inputs @ { flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "aarch64-darwin" "x86_64-linux" "aarch64-linux" ];

      perSystem = { pkgs, system, ... }: {
        devShells.default = pkgs.mkShellNoCC {
          buildInputs = with pkgs; [
            bash
            coreutils-full
            git
            jq
            python3
            bazel_8
            rustc
          ];
          shellHook = ''
            echo "bazel $(bazel --version 2>/dev/null | awk '{print $2}')  rustc $(rustc --version | awk '{print $2}')" >&2
          '';
        };
      };
    };
}
