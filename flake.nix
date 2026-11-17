{
  description = "Shockolate - Cross-platform System Shock source port";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "i686-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      flake = {
        overlays.default = final: _prev: {
          shockolate = final.callPackage ./package.nix { };
          systemshock = final.shockolate;
        };
      };

      perSystem =
        {
          self',
          pkgs,
          lib,
          ...
        }:
        let
          shockolate = pkgs.callPackage ./package.nix { };
        in
        {
          packages = {
            inherit shockolate;
            systemshock = shockolate;
            default = shockolate;
          };

          apps = {
            default = {
              type = "app";
              program = lib.getExe shockolate;
              meta = shockolate.meta;
            };
            shockolate = self'.apps.default;
            systemshock = self'.apps.default;
          };

          devShells.default = pkgs.mkShell {
            inputsFrom = [ shockolate ];
            packages =
              with pkgs;
              [
                clang-tools
              ]
              ++ lib.optionals stdenv.hostPlatform.isLinux [
                gdb
              ];

            shellHook = ''
              echo "Shockolate Nix devShell ready."
              echo "Configure: cmake -B build -G Ninja -DENABLE_SDL2=ON -DENABLE_SOUND=ON -DENABLE_FLUIDSYNTH=ON -DENABLE_OPENGL=ON"
              echo "Build:     cmake --build build"
            '';
          };

          checks = {
            inherit shockolate;

            wrapper-smoke =
              pkgs.runCommand "shockolate-wrapper-smoke"
                {
                  nativeBuildInputs = [ shockolate ];
                }
                ''
                  set -euo pipefail

                  export HOME="$TMPDIR/home"
                  export XDG_DATA_HOME="$TMPDIR/xdg-data"
                  mkdir -p "$HOME" "$XDG_DATA_HOME"

                  # Verify unwrapped binary and shaders are installed
                  test -x "${shockolate}/libexec/shockolate/systemshock"
                  test -f "${shockolate}/libexec/shockolate/shaders/main.vert"

                  # Verify both CLI entrypoints respond to --help
                  systemshock --help | grep -q "Shockolate"
                  shockolate --help | grep -q "Shockolate"

                  # Verify pre-flight asset check fails cleanly (no segfault) when assets are absent
                  # and links the bundled FluidSynth SoundFont into XDG_DATA_HOME.
                  if output="$(systemshock 2>&1)"; then
                    echo "Expected systemshock without game data to exit non-zero" >&2
                    exit 1
                  else
                    echo "$output" | grep -q "System Shock game assets were not found"
                  fi

                  test -L "$XDG_DATA_HOME/Interrupt/SystemShock/res/FluidR3_GM2-2.sf2"

                  touch "$out"
                '';
          };
        };
    };
}
