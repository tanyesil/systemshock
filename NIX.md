# Nix Flake & Packaging Guide

This repository packages **Shockolate** (`0.7.8`), a cross-platform source port of the 1994 classic *System Shock*, as a Nix package (`package.nix`) and `flake-parts`-based Nix Flake (`flake.nix`).

## Quick Start

Run directly from GitHub or a local checkout:

```bash
# Run from GitHub
nix run github:tanyesil/systemshock

# Build or run locally
nix build
nix run . -- -nosplash
```

Both `systemshock` and `shockolate` binaries are provided in `$out/bin`, along with a `.desktop` launcher entry on Linux.

## Supplying Game Assets (`res/data`)

Shockolate is an open-source engine (`GPL-3.0-or-later`) and requires the original **System Shock Classic CD-ROM** or **System Shock: Enhanced Edition** data files.

You can provide game assets in any of three ways:

### 1. XDG Data Directory (Default Runtime Lookup)

Place your `data` (and optional `sound` folder for XMI music) under `${XDG_DATA_HOME:-~/.local/share}/Interrupt/SystemShock/res/`:

```text
~/.local/share/Interrupt/SystemShock/
├── prefs.txt
├── keybinds.txt
├── savgam00.dat
└── res/
    ├── data/      # ARCHIVE.DAT, TEXTURE.RES, CITALOG.RES, ...
    └── sound/     # GENMIDI/, SBLASTER/, ... (optional)
```

If you have a **System Shock Classic CD-ROM `.iso`**, extract `CDROM/DATA`, `HD/DATA`, and `HD/SOUND` with `xorriso` (which handles both standard ISOs and the 1994 Electronic Arts / Origin `CD-Producer` mastering descriptors):

```bash
res_dir="${XDG_DATA_HOME:-$HOME/.local/share}/Interrupt/SystemShock/res"
tmp_dir="$(mktemp -d)"
nix shell nixpkgs#xorriso -c xorriso -osirrox on -indev "System Shock.iso" \
  -extract /CDROM/DATA "$tmp_dir/cdrom_data" \
  -extract /HD/DATA "$tmp_dir/hd_data" \
  -extract /HD/SOUND "$tmp_dir/hd_sound"
chmod -R u+rwX "$tmp_dir"
mkdir -p "$res_dir/data" "$res_dir/sound"
cp -rL "$tmp_dir/cdrom_data/." "$res_dir/data/"
chmod -R u+rwX "$res_dir/data"
cp -rLf "$tmp_dir/hd_data/." "$res_dir/data/"
cp -rL "$tmp_dir/hd_sound/." "$res_dir/sound/"
chmod -R u+rwX "$res_dir"
rm -rf "$tmp_dir"
```

### 2. Environment Variable or CLI Flag

Point Shockolate at an existing `res` directory (or its parent directory):

```bash
SHOCKOLATE_DATA_DIR=/path/to/res nix run .
# or
nix run . -- -data-dir /path/to/res
```

Save files (`CurrentGame.dat`, `savgam*.dat`) and preferences (`prefs.txt`, `keybinds.txt`) remain stored in `~/.local/share/Interrupt/SystemShock` even if the asset directory is read-only.

### 3. Declarative Nix Override (`withData` / `gameData`)

`package.nix` exposes `gameData` (and the `passthru.withData` helper), accepting **either a CD-ROM `.iso` archive or an extracted asset directory** (CD-ROM or Enhanced Edition layout):

```nix
# Using the helper method with an ISO or directory:
pkgs.shockolate.withData /path/to/SYSTEMSHOCK.ISO

# Or via standard .override:
pkgs.shockolate.override {
  gameData = /path/to/system-shock-enhanced-edition;
}
```

## MIDI Music & SoundFonts

By default, the package bundles `pkgs.soundfont-fluid` (`FluidR3_GM2-2.sf2`) and links it into the runtime `res/` directory so FluidSynth General MIDI music works out of the box.

To customize or disable the bundled SoundFont:

```nix
# Use a custom .sf2 file or another nixpkgs soundfont package:
pkgs.shockolate.override {
  soundfont = pkgs.soundfont-ydp-grand;
}

# Disable bundled SoundFont (e.g. if using ADLMIDI only):
pkgs.shockolate.override {
  soundfont = null;
}
```

## Using in NixOS or Home Manager (`overlays.default`)

Add the flake input and apply `overlays.default`:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    systemshock = {
      url = "github:tanyesil/systemshock";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, systemshock, ... }: {
    nixosConfigurations.my-host = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ({ pkgs, ... }: {
          nixpkgs.overlays = [ systemshock.overlays.default ];
          environment.systemPackages = [ pkgs.shockolate ];
        })
      ];
    };
  };
}
```

## Development Shell & Checks

```bash
# Enter development environment with CMake, Ninja, SDL2, SDL2_mixer, FluidSynth, OpenGL, ALSA
nix develop

# Run package build and wrapper smoke tests
nix flake check
```
