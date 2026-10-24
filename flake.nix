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
          workspace = let ws = builtins.getEnv "LITEX_WORKSPACE"; in
            if ws == "" then "/workspace" else ws;
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
          migen = pythonPackages.buildPythonPackage {
            pname = "migen";
            version = "0.9.2";
            src = workspace + "/migen";
            pyproject = true;
            build-system = [ pythonPackages.setuptools ];
            propagatedBuildInputs = [ pythonPackages.colorama ];
          };
          litex = pythonPackages.buildPythonPackage {
            pname = "litex";
            version = "2026.08";
            src = workspace + "/litex";
            pyproject = true;
            build-system = [ pythonPackages.setuptools pythonPackages.wheel ];
            propagatedBuildInputs = [
              migen
              pythonPackages.packaging
              pythonPackages.pyserial
              pythonPackages.requests
            ];
          };
          litexBoards = pythonPackages.buildPythonPackage {
            pname = "litex-boards";
            version = "2026.08";
            src = workspace + "/litex-boards";
            pyproject = true;
            build-system = [ pythonPackages.setuptools pythonPackages.wheel ];
            propagatedBuildInputs = [ litex ];
          };
          pythonEnv = pkgs.python312.withPackages (ps: [
            migen
            litex
            litexBoards
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
          localPythonPaths = [
            (workspace + "/litedram")
            (workspace + "/litedsp")
            (workspace + "/liteeth")
            (workspace + "/litei2c")
            (workspace + "/liteiclink")
            (workspace + "/litejesd204")
            (workspace + "/litepcie")
            (workspace + "/litesata")
            (workspace + "/litescope")
            (workspace + "/litesdcard")
            (workspace + "/litespi")
            (workspace + "/pythondata-cpu-lm32")
            (workspace + "/pythondata-cpu-minerva")
            (workspace + "/pythondata-cpu-mor1kx")
            (workspace + "/pythondata-cpu-naxriscv")
            (workspace + "/pythondata-cpu-sentinel")
            (workspace + "/pythondata-cpu-serv")
            (workspace + "/pythondata-cpu-veer_eh1")
            (workspace + "/pythondata-cpu-vexiiriscv")
            (workspace + "/pythondata-cpu-vexriscv")
            (workspace + "/pythondata-cpu-vexriscv-smp")
            (workspace + "/pythondata-misc-tapcfg")
            (workspace + "/pythondata-misc-usb_ohci")
            (workspace + "/pythondata-software-compiler_rt")
            (workspace + "/pythondata-software-picolibc")
          ];
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
              export LITEX_ROOT="$PWD"
              export PYTHONPATH="${pkgs.lib.concatStringsSep ":" localPythonPaths}''${PYTHONPATH:+:$PYTHONPATH}"
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
