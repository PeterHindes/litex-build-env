{
  description = "LiteX development environment";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  inputs.nixpkgs-darwin.url = "github:NixOS/nixpkgs/nixpkgs-26.05-darwin";
  inputs.openxc7.url = "github:openXC7/toolchain-nix";

  outputs = { nixpkgs, nixpkgs-darwin, openxc7, ... }:
    let
      systems = [ "aarch64-darwin" "x86_64-darwin" "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      devShells = forAllSystems (system:
        let
          pkgs = import (if nixpkgs.lib.hasSuffix "-darwin" system
            then nixpkgs-darwin
            else nixpkgs) { inherit system; };
          withOpenxc7 = system != "x86_64-darwin";
          riscv32 = pkgs.pkgsCross.riscv32-embedded.stdenv.cc;
          # verilator's flexfix rewrites LexerInput/LexerOutput to size_t on macOS >= 26,
          # but the FlexLexer.h of every flex nixpkgs ships declares them with int, so
          # the generated lexer stopped matching its own header.  Keep flex's types.
          verilator = if nixpkgs.lib.hasSuffix "-darwin" system
            then pkgs.verilator.overrideAttrs (old: {
              postPatch = (old.postPatch or "") + ''
                substituteInPlace src/flexfix \
                  --replace-fail 'if platform.system() == "Darwin":' 'if False:  # keep int, matches FlexLexer.h'
              '';
            })
            else pkgs.verilator;
          nextpnr = if withOpenxc7 then openxc7.packages.${system}.nextpnr.overrideAttrs (old: {
            buildInputs = old.buildInputs ++ [ pkgs.llvmPackages.openmp ];
          }) else null;
          fasm = if withOpenxc7 then openxc7.packages.${system}.fasm.overrideAttrs (old: {
            postInstall = (old.postInstall or "") + ''
              grammar="$(find "$src" -name fasm.tx -print -quit)"
              test -n "$grammar"
              cp "$grammar" "$out"/lib/python*/site-packages/fasm/parser/fasm.tx
            '';
          }) else null;
          pythonPackages = pkgs.python312Packages;
          # openXC7's python 3.12.13 links a libffi that aborts on any ctypes
          # callback on recent macOS, which kills fasm2frames/bit2fasm.  Run
          # those entry points with this flake's python instead.
          prjxray = if withOpenxc7 then pkgs.runCommand "prjxray-0.9.2" { } ''
            mkdir -p "$out"
            cp -r ${openxc7.packages.${system}.prjxray}/. "$out"/
            chmod -R u+w "$out"
            for script in fasm2frames bit2fasm; do
              sed -i "1s|.*|#!${pythonPackages.python.interpreter}|" "$out/bin/$script"
            done
          '' else null;
          pythonEnv = pkgs.python312.withPackages (ps: [
            ps.colorama
            ps.packaging
            ps.pyserial
            ps.requests
            ps.setuptools
            ps.pyyaml
            ps.numpy
            ps.scipy
            ps.meson
            ps.ninja
            ps.pytest
          ]);
          # The LiteX repositories are used from the workspace checkout, not installed:
          # LiteX's BIOS build writes into the sources it stages, which a read-only Nix
          # store copy cannot do, so they are only put on PYTHONPATH by the shellHook.
          workspaceModules = [
            "migen"
            "litex"
            "litex-boards"
            "litedram"
            "litedsp"
            "liteeth"
            "litei2c"
            "liteiclink"
            "litejesd204"
            "litepcie"
            "litesata"
            "litescope"
            "litesdcard"
            "litespi"
            "pythondata-cpu-lm32"
            "pythondata-cpu-minerva"
            "pythondata-cpu-mor1kx"
            "pythondata-cpu-naxriscv"
            "pythondata-cpu-sentinel"
            "pythondata-cpu-serv"
            "pythondata-cpu-veer_eh1"
            "pythondata-cpu-vexiiriscv"
            "pythondata-cpu-vexriscv"
            "pythondata-cpu-vexriscv-smp"
            "pythondata-misc-tapcfg"
            "pythondata-misc-usb_ohci"
            "pythondata-software-compiler_rt"
            "pythondata-software-picolibc"
          ];
          # `litex` is not installed, so recreate the console scripts it declares in
          # litex/setup.py (entry_points) as launchers for the workspace sources.
          litexTools = {
            litex_term            = "litex.tools.litex_term:main";
            litex_server          = "litex.tools.litex_server:main";
            litex_jtag            = "litex.tools.litex_jtag:main";
            litex_cli             = "litex.tools.litex_client:main";
            litex_soc_gen         = "litex.tools.litex_soc_gen:main";
            litex_periph_gen      = "litex.tools.litex_periph_gen:main";
            litex_sim             = "litex.tools.litex_sim:main";
            litex_bare_metal_demo = "litex.soc.software.demo.demo:main";
            litex_json2dts_linux  = "litex.tools.litex_json2dts_linux:main";
            litex_json2dts_zephyr = "litex.tools.litex_json2dts_zephyr:main";
            litex_json2renode     = "litex.tools.litex_json2renode:main";
            litex_read_verilog    = "litex.tools.litex_read_verilog:main";
            litex_contributors    = "litex.tools.litex_contributors:main";
            litex_build_bundle    = "litex.tools.litex_build_bundle:main";
            litex_remote_build    = "litex.tools.litex_remote_build:main";
          };
          litexScripts = pkgs.symlinkJoin {
            name = "litex-console-scripts";
            paths = pkgs.lib.mapAttrsToList (name: entryPoint:
              let
                module   = builtins.head (pkgs.lib.splitString ":" entryPoint);
                function = builtins.elemAt (pkgs.lib.splitString ":" entryPoint) 1;
              in
              pkgs.writeTextFile {
                name = name;
                destination = "/bin/${name}";
                executable = true;
                text = ''
                  #!${pythonEnv}/bin/python
                  import sys
                  from ${module} import ${function}
                  sys.exit(${function}())
                '';
              }) litexTools;
          };
          xilinxChipdb = if withOpenxc7 then pkgs.stdenv.mkDerivation {
            pname = "litex-artix7-chipdb";
            version = "1.0.0";
            dontUnpack = true;
            nativeBuildInputs = [ pkgs.python3 pkgs.coreutils ];
            buildInputs = [ nextpnr ];
            dontInstall = true;
            buildPhase = ''
              mkdir -p "$out"
              ${pkgs.python3}/bin/python3 \
                ${nextpnr}/share/nextpnr/himbaechel/uarch/xilinx/gen/xilinx_gen.py \
                --xray "${openxc7.packages.${system}.prjxray-db}/artix7" \
                --device xc7a100t --bba xc7a100t.bba
              ${nextpnr}/bin/bbasm -l xc7a100t.bba "$out/chipdb-xc7a100t.bin"
              ln -s chipdb-xc7a100t.bin "$out/xc7a100t-csg324.bin"
              ln -s chipdb-xc7a100t.bin "$out/xc7a100t.bin"
              ln -s chipdb-xc7a100t.bin "$out/xc7a100tcsg324.bin"
            '';
          } else null;
        in
        {
          default = pkgs.mkShell {
            packages = [
              pythonEnv
              litexScripts
            ] ++ pkgs.lib.optionals withOpenxc7 [
              pkgs.yosys
              pkgs.python312Packages.cython
              pkgs.python312Packages.pyyaml
              pkgs.python312Packages.simplejson
              pkgs.python312Packages.intervaltree
              verilator
              pkgs.openfpgaloader
              pkgs.openocd
              pkgs.llvmPackages.openmp
              riscv32
              nextpnr
              xilinxChipdb
              fasm
              prjxray
            ];

            shellHook = ''
              export LITEX_ROOT="''${LITEX_WORKSPACE:-$PWD}"
              export PYTHONPATH="''${LITEX_ROOT}/${pkgs.lib.concatStringsSep ":\${LITEX_ROOT}/" workspaceModules}''${PYTHONPATH:+:$PYTHONPATH}"
              if [ ! -f "$LITEX_ROOT/litex/pyproject.toml" ]; then
                echo "litex dev shell: no LiteX workspace at $LITEX_ROOT, start the shell in the" \
                     "workspace root or set LITEX_WORKSPACE" >&2
              fi
              ${pkgs.lib.optionalString withOpenxc7 ''
                export CHIPDB="${xilinxChipdb}"
                export NEXTPNR_XILINX_DIR="${nextpnr}"
                export NEXTPNR_XILINX_PYTHON_DIR="${nextpnr}/share/nextpnr"
                export PRJXRAY_DB_DIR="${nextpnr}/share/nextpnr/external/prjxray-db"
                export PRJXRAY_PYTHON_DIR="${prjxray}/usr/share/python3"
                export PYTHONPATH="$PRJXRAY_PYTHON_DIR''${PYTHONPATH:+:$PYTHONPATH}"
              ''}
            '';
          };
        });
    };
}
