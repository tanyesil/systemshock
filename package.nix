let
  mkShockolate =
    {
      lib,
      stdenv,
      cmake,
      ninja,
      pkg-config,
      copyDesktopItems,
      makeDesktopItem,
      runCommand,
      runtimeShell,
      coreutils,
      findutils,
      libarchive,
      SDL2,
      SDL2_mixer,
      fluidsynth,
      libGL,
      alsa-lib,
      soundfont-fluid,
      soundfont ? soundfont-fluid,
      gameData ? null,
    }@args:

let
  # Normalize optional user-supplied gameData (either an archive/ISO like SYSTEMSHOCK.ISO
  # or an extracted directory from CD-ROM / Enhanced Edition) into $out/res/{data,sound}.
  normalizedGameData =
    if gameData == null then
      null
    else
      runCommand "shockolate-gamedata"
        {
          src = gameData;
          nativeBuildInputs = [ libarchive ];
        }
        ''
          set -euo pipefail

          work="$TMPDIR/work"
          mkdir -p "$work" "$out/res"

          if [ -f "$src" ]; then
            bsdtar -xf "$src" -C "$work"
            chmod -R u+rwX "$work"
            root="$work"
          elif [ -d "$src" ]; then
            root="$src"
          else
            echo "shockolate-gamedata: unsupported gameData input: $src" >&2
            exit 1
          fi

          find_dir_ci() {
            local base="$1"
            local rel="$2"
            find "$base" -maxdepth 3 -type d -ipath "$base/$rel" | head -n 1
          }

          cdrom_data="$(find_dir_ci "$root" "cdrom/data")"
          hd_data="$(find_dir_ci "$root" "hd/data")"
          hd_sound="$(find_dir_ci "$root" "hd/sound")"
          res_data="$(find_dir_ci "$root" "res/data")"
          top_data="$(find_dir_ci "$root" "data")"
          top_sound="$(find_dir_ci "$root" "sound")"

          if [ -n "$cdrom_data" ] || [ -n "$hd_data" ]; then
            # System Shock Classic CD-ROM / ISO layout:
            # Copy CDROM/DATA first, then overlay HD/DATA (matching DOS install search order).
            mkdir -p "$out/res/data"
            if [ -n "$cdrom_data" ]; then
              cp -rL "$cdrom_data/." "$out/res/data/"
              chmod -R u+rwX "$out/res/data"
            fi
            if [ -n "$hd_data" ]; then
              cp -rLf "$hd_data/." "$out/res/data/"
              chmod -R u+rwX "$out/res/data"
            fi
            if [ -n "$hd_sound" ]; then
              mkdir -p "$out/res/sound"
              cp -rL "$hd_sound/." "$out/res/sound/"
              chmod -R u+rwX "$out/res/sound"
            fi
          elif [ -n "$res_data" ]; then
            # Enhanced Edition or pre-structured res/ parent directory
            res_parent="$(dirname "$res_data")"
            cp -rL "$res_parent/." "$out/res/"
            chmod -R u+rwX "$out/res"
          elif [ -n "$top_data" ]; then
            # Directory containing data/ (and optionally sound/) directly, e.g. a res/ dir
            mkdir -p "$out/res/data"
            cp -rL "$top_data/." "$out/res/data/"
            if [ -n "$top_sound" ]; then
              mkdir -p "$out/res/sound"
              cp -rL "$top_sound/." "$out/res/sound/"
            fi
            chmod -R u+rwX "$out/res"
          else
            # Flat folder containing ARCHIVE.DAT / *.RES directly
            mkdir -p "$out/res/data"
            cp -rL "$root/." "$out/res/data/"
            chmod -R u+rwX "$out/res/data"
          fi

          if [ -z "$(find "$out/res" -maxdepth 3 -type f \( -iname 'archive.dat' -o -iname 'texture.res' \))" ]; then
            echo "shockolate-gamedata: could not find System Shock data files (ARCHIVE.DAT / TEXTURE.RES) in $src" >&2
            exit 1
          fi
        '';

  runtimeBinPath = lib.makeBinPath [
    coreutils
    findutils
  ];

  bundledSoundfontPath = if soundfont != null then "${soundfont}" else "";
  bundledGameDataRes = if normalizedGameData != null then "${normalizedGameData}/res" else "";
in
stdenv.mkDerivation (finalAttrs: {
  pname = "shockolate";
  version = "0.7.8";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./CMakeLists.txt
      ./cmake
      ./externals
      ./shaders
      ./src
      ./README.md
      ./LICENSE
      ./COPYING.txt
    ];
  };

  nativeBuildInputs = [
    cmake
    ninja
    pkg-config
  ] ++ lib.optionals stdenv.hostPlatform.isLinux [
    copyDesktopItems
  ];

  buildInputs = [
    SDL2
    SDL2_mixer
    fluidsynth
  ] ++ lib.optionals stdenv.hostPlatform.isLinux [
    libGL
    alsa-lib
  ];

  cmakeFlags = [
    (lib.cmakeFeature "ENABLE_SDL2" "ON")
    (lib.cmakeFeature "ENABLE_SOUND" "ON")
    (lib.cmakeFeature "ENABLE_FLUIDSYNTH" "ON")
    (lib.cmakeBool "ENABLE_OPENGL" true)
  ];

  # Upstream Shock.c passes `char full[1024]` to `realpath()`, whereas glibc's
  # fortified `__realpath_chk` requires at least `PATH_MAX` (4096) bytes and
  # aborts unconditionally under Nix's default `_FORTIFY_SOURCE=3`.
  hardeningDisable = [ "fortify" ];

  installPhase = ''
    runHook preInstall

    install -Dm755 systemshock "$out/libexec/shockolate/systemshock"
    cp -r "$src/shaders" "$out/libexec/shockolate/shaders"
    install -Dm644 "$src/README.md" "$out/share/doc/shockolate/README.md"

    mkdir -p "$out/bin"
    cat > "$out/bin/systemshock" <<'EOF'
    #!${runtimeShell}
    set -euo pipefail

    export PATH="${runtimeBinPath}:''${PATH:-}"

    bundled_gamedata_res="${bundledGameDataRes}"
    bundled_soundfont="${bundledSoundfontPath}"
    default_state_dir="''${XDG_DATA_HOME:-$HOME/.local/share}/Interrupt/SystemShock"

    print_help() {
      cat <<HELP
    Shockolate (System Shock source port) - Nix wrapper

    Usage:
      systemshock [options] [mod-file-or-dir ...]
      shockolate  [options] [mod-file-or-dir ...]

    Options:
      -nosplash           Skip intro splash screens and go straight to main menu
      -data-dir <path>    Path to game 'res' directory (or parent containing 'res')
      -h, --help          Show this help message

    Game Data Lookup Order:
      1. -data-dir <path> command-line flag
      2. \$SHOCKOLATE_DATA_DIR environment variable
      3. Nix 'gameData' package override (if built with shockolate.withData)
      4. ''${default_state_dir}/res/data (and optional res/sound)

    Saves, keybinds, and preferences are stored in:
      ''${default_state_dir}
    HELP
    }

    cli_data_dir=""
    flag_args=()
    mod_args=()

    while [ "$#" -gt 0 ]; do
      case "$1" in
        -h|--help)
          print_help
          exit 0
          ;;
        -data-dir)
          if [ "$#" -lt 2 ]; then
            echo "systemshock: -data-dir requires a path argument" >&2
            exit 1
          fi
          cli_data_dir="$2"
          shift 2
          ;;
        -*)
          flag_args+=("$1")
          shift
          ;;
        *)
          if [ -e "$1" ]; then
            mod_args+=("$(realpath "$1")")
          else
            mod_args+=("$1")
          fi
          shift
          ;;
      esac
    done

    mkdir -p "$default_state_dir"

    source_res=""
    if [ -n "$cli_data_dir" ]; then
      source_res="$cli_data_dir"
    elif [ -n "''${SHOCKOLATE_DATA_DIR:-}" ]; then
      source_res="$SHOCKOLATE_DATA_DIR"
    elif [ -n "$bundled_gamedata_res" ]; then
      source_res="$bundled_gamedata_res"
    fi

    if [ -n "$source_res" ]; then
      if [ ! -d "$source_res" ]; then
        echo "systemshock: data directory does not exist: $source_res" >&2
        exit 1
      fi
      source_res="$(realpath "$source_res")"
      base_lower="$(basename "$source_res" | tr '[:upper:]' '[:lower:]')"
      if [ "$base_lower" != "res" ] && [ -d "$source_res/res" ]; then
        source_res="$(realpath "$source_res/res")"
      fi
    fi

    # Shockolate's -data-dir calls realpath() on the 'res' folder and chdir()s into its
    # parent directory, writing CurrentGame.dat and savgam*.dat to CWD on Linux.
    # Ensure 'runtime_res' is always a real directory named 'res' inside a writable parent.
    default_res="$(realpath -m "$default_state_dir/res")"
    if [ -z "$source_res" ] || [ "$source_res" = "$default_res" ]; then
      runtime_res="$default_state_dir/res"
      mkdir -p "$runtime_res"
    elif [ -z "$cli_data_dir" ] && { [ ! -e "$default_state_dir/res/data" ] || [ -L "$default_state_dir/res/data" ]; } && [ ! -e "$default_state_dir/res/DATA" ]; then
      runtime_res="$default_state_dir/res"
      mkdir -p "$runtime_res"
      for entry in "$source_res"/*; do
        [ -e "$entry" ] || continue
        name="$(basename "$entry")"
        target="$runtime_res/$name"
        if [ ! -e "$target" ] || [ -L "$target" ]; then
          ln -sfn "$entry" "$target"
        fi
      done
    else
      runtime_res="$default_state_dir/.nix-runtime/res"
      mkdir -p "$runtime_res"
      find "$runtime_res" -mindepth 1 -maxdepth 1 -type l -delete
      for entry in "$source_res"/*; do
        [ -e "$entry" ] || continue
        ln -sfn "$entry" "$runtime_res/$(basename "$entry")"
      done
    fi

    # Prune stale Nix store SoundFont symlinks (e.g. after nix-collect-garbage)
    while IFS= read -r -d ''' link; do
      target="$(readlink "$link" || true)"
      case "$target" in
        /nix/store/*)
          if [ ! -e "$link" ]; then
            rm -f "$link"
          fi
          ;;
      esac
    done < <(find "$runtime_res" -maxdepth 1 -type l -iname '*.sf2' -print0)

    # Link default SoundFont(s) so FluidSynth MIDI works out of the box
    if [ -n "$bundled_soundfont" ] && [ -e "$bundled_soundfont" ]; then
      if [ -f "$bundled_soundfont" ]; then
        sf_name="$(basename "$bundled_soundfont")"
        if [ ! -e "$runtime_res/$sf_name" ] || [ -L "$runtime_res/$sf_name" ]; then
          ln -sfn "$bundled_soundfont" "$runtime_res/$sf_name"
        fi
      elif [ -d "$bundled_soundfont" ]; then
        while IFS= read -r -d ''' sf_file; do
          sf_name="$(basename "$sf_file")"
          if [ ! -e "$runtime_res/$sf_name" ] || [ -L "$runtime_res/$sf_name" ]; then
            ln -sfn "$sf_file" "$runtime_res/$sf_name"
          fi
        done < <(find -L "$bundled_soundfont" -type f -iname '*.sf2' -print0)
      fi
    fi

    if [ -z "$(find -L "$runtime_res" -maxdepth 2 -type f \( -iname 'archive.dat' -o -iname 'texture.res' \) -print -quit)" ]; then
      cat >&2 <<ERR
    systemshock: System Shock game assets were not found in:
      $runtime_res/data

    To play, supply the original System Shock (Classic CD-ROM or Enhanced Edition) assets using one of:
      1. Copy 'data' (and optionally 'sound') into:
           $default_state_dir/res/
      2. Run with an environment variable or flag:
           SHOCKOLATE_DATA_DIR=/path/to/res systemshock
           systemshock -data-dir /path/to/res
      3. Override the Nix package with a directory or CD-ROM ISO:
           shockolate.withData /path/to/SYSTEMSHOCK.ISO
    ERR
      exit 1
    fi

    exec "@out@/libexec/shockolate/systemshock" -data-dir "$runtime_res" "''${flag_args[@]}" "''${mod_args[@]}"
    EOF

    substituteInPlace "$out/bin/systemshock" \
      --replace-fail "@out@" "$out"
    chmod +x "$out/bin/systemshock"
    ln -s systemshock "$out/bin/shockolate"

    runHook postInstall
  '';

  desktopItems = lib.optionals stdenv.hostPlatform.isLinux [
    (makeDesktopItem {
      name = "shockolate";
      desktopName = "System Shock (Shockolate)";
      genericName = "First-Person Action RPG";
      comment = "Cross-platform source port of the 1994 classic System Shock";
      exec = "systemshock";
      terminal = false;
      categories = [
        "Game"
        "ActionGame"
        "RolePlaying"
      ];
      keywords = [
        "system shock"
        "shockolate"
        "looking glass"
        "immersive sim"
      ];
    })
  ];

  passthru = {
    withData = data: (lib.makeOverridable mkShockolate args).override { gameData = data; };
  };

  meta = {
    description = "Cross-platform System Shock source port";
    longDescription = ''
      Shockolate is a cross-platform source port of the original 1994 System Shock,
      built on the PowerPC Mac source code released by Night Dive Studios using SDL2,
      OpenGL, SDL2_mixer, and FluidSynth. Requires original System Shock CD-ROM or
      Enhanced Edition game data.
    '';
    homepage = "https://github.com/Interrupt/systemshock";
    license = lib.licenses.gpl3Plus;
    mainProgram = "systemshock";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
});
in
mkShockolate
