# litex-build-env

Containerised build environments for the [LiteX](https://github.com/enjoy-digital/litex)
workspace, providing two FPGA toolchains for the same design:

| Target | Toolchain | Artix-7 `xc7a100t` support |
|---|---|---|
| `openxc7` | Yosys + nextpnr-xilinx + Project X-Ray | free, open source |
| `vivado` | Vivado 2019.2 HL WebPACK | free, no license file |

Both accept the same board definition. `base.py` keeps the Vivado spelling and
the openXC7 backend normalises it at the command boundary:

```text
base.py: xc7a100t-csg324-1
  ├─ Vivado   → xc7a100t-csg324-1
  └─ openXC7  → xc7a100tcsg324-1   (openxc7_part())
```

## Placement

This directory lives inside a LiteX workspace created by `litex_setup.py`, next
to `litex/`, `migen/`, `litex-boards/`, `litedram/`, … because `flake.nix`
references those as `../litex`, `../migen`, and so on:

```text
workspace/
├── build-env/        <- this repository
├── litex/
├── migen/
├── litex-boards/
├── fpga_101/
└── ...
```

## openXC7

```bash
docker build --target openxc7 -t litex-openxc7 build-env

docker run --rm -it \
  -v "$PWD:/workspace" \
  -v litex-nix-store:/nix \
  -w /workspace/fpga_101/lab001 \
  litex-openxc7 \
  python3 base.py
```

The container entrypoint is
`nix develop --impure /workspace/build-env --accept-flake-config --command`, so
any command given to `docker run` executes inside the dev shell. `--impure` is
required because flake copies are evaluated from the Nix store and cannot reach
sibling repositories by relative path; `LITEX_WORKSPACE` (default `/workspace`)
locates `litex/`, `migen/`, `litex-boards/`, and the `pythondata-*` trees.

Run commands from the lab directory (`-w /workspace/fpga_101/lab001`) so the
generated `build/` lands next to the lab. The flake builds
the Artix-7 chip database and exports `CHIPDB`, `NEXTPNR_XILINX_*` and
`PRJXRAY_*` for the toolchain.

Keep the `litex-nix-store` volume: it caches the toolchain between runs.

## Vivado

Vivado is proprietary and is **not** redistributed here. Download the offline
installer (AMD/Xilinx account required) and place it in this directory:

```text
Xilinx_Vivado_2019.2_1106_2127.tar.gz    # "All OS installer Single-File Download"
```

Then build and run:

```bash
docker build --target vivado -t litex-vivado build-env \
  --build-arg VIVADO_TARBALL=Xilinx_Vivado_2019.2_1106_2127.tar.gz

docker run --rm -it \
  --platform linux/amd64 \
  --privileged \
  -v "$PWD:/workspace" \
  -w /workspace/fpga_101/lab001 \
  litex-vivado \
  python3 base.py
```

`LITEX_ENV_VIVADO` is preset to `/opt/Xilinx/Vivado/2019.2`, so LiteX finds the
toolchain without `settings64.sh`.

### Why 2019.2 HL WebPACK

- WebPACK enables Artix-7 `xc7a100t` with **no license file and no checkout**.
- It ships a self-contained offline installer (no auth token, no web download).
- Newer unified installers expose only `Vivado Design Suite`, whose license
  checkout performs VM detection and aborts inside `libudev` under emulation.

### Emulation notes (Apple Silicon)

Two workarounds are baked into the image/entrypoint because of Rosetta:

1. `config_webtalk -user off` — WebTalk is optional telemetry.
2. `mount -t tmpfs none /sys` in the entrypoint — WebTalk's host-info path
   enumerates udev devices and corrupts the heap (`realloc(): invalid pointer`)
   after routing succeeds. Hiding sysfs from that enumeration avoids it.

Point 2 requires `--privileged` (or `--cap-add SYS_ADMIN`). On native x86_64
hosts neither workaround is needed, and the mount failing is harmless.

Emulation is slow; expect several minutes for a small design.

## Validated results

| Flow | Target | Result |
|---|---|---|
| openXC7 | `fpga_101/lab001/base.py` | full build, `top.bit` 3.6 MB |
| Vivado 2019.2 WebPACK | `fpga_101/lab001/base.py` (`toolchain="vivado"`) | full build, `top.bit` 3.6 MB, WNS ≥ 0, DRC 0 errors |

Only these targets were exercised end to end; the remaining labs are unchanged.

## Files

| File | Purpose |
|---|---|
| `flake.nix`, `flake.lock` | Nix dev shell (openXC7), paths relative to the workspace |
| `Dockerfile` | `openxc7` and `vivado` build targets |
| `install_config.txt` | Non-interactive Vivado HL WebPACK install configuration |
| `vivado-entrypoint.sh` | Emulation workaround + environment defaults |

## License

The files here are provided as-is. The Vivado installer, Vivado itself, and the
AMD/Xilinx EULAs remain subject to AMD's terms; nothing proprietary is included.
