# syntax=docker/dockerfile:1
#
# Build targets for the LiteX workspace in this repository's parent directory:
#
#   openxc7 : Nix dev shell with yosys/nextpnr-xilinx/prjxray + generated Artix-7 chipdb
#   vivado  : Vivado 2019.2 HL WebPACK (no license file needed for xc7a100t)
#
# Examples:
#   docker build --target openxc7 -t litex-openxc7 build-env
#   docker build --target vivado  -t litex-vivado  build-env \
#       --build-arg VIVADO_TARBALL=Xilinx_Vivado_2019.2_1106_2127.tar.gz
#
# The Vivado installer is proprietary and is NOT redistributed here; place the
# offline installer in this directory before building that target.

# ------------------------------------------------------------------------------
# openXC7
# ------------------------------------------------------------------------------
FROM nixos/nix:latest AS openxc7

ENV NIX_CONFIG="experimental-features = nix-command flakes" \
    LITEX_WORKSPACE=/workspace

WORKDIR /workspace

ENTRYPOINT ["nix", "develop", "--impure", "/workspace/build-env", "--accept-flake-config", "--command"]
CMD ["python3", "--version"]

# ------------------------------------------------------------------------------
# Vivado 2019.2 HL WebPACK
# ------------------------------------------------------------------------------
FROM ubuntu:22.04 AS vivado

ARG VIVADO_TARBALL=Xilinx_Vivado_2019.2_1106_2127.tar.gz
ARG DEBIAN_FRONTEND=noninteractive

ENV LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    LITEX_ENV_VIVADO=/opt/Xilinx/Vivado/2019.2

SHELL ["/bin/bash", "-c"]

RUN apt-get update && apt-get install -y --no-install-recommends \
        bash ca-certificates coreutils curl gawk gcc git graphviz locales \
        net-tools perl procps python3 unzip \
        libncurses5 libtinfo5 zlib1g libuuid1 \
        libxext6 libx11-6 libxrender1 libxtst6 libxi6 libxft2 libxcb1 \
        libfreetype6 libfontconfig1 libglib2.0-0 libgtk2.0-0 libgtk-3.0-0 \
    && rm -rf /var/lib/apt/lists/* \
    && localedef -i en_US -f UTF-8 en_US.UTF-8

COPY install_config.txt /tmp/install_config.txt
COPY ${VIVADO_TARBALL} /tmp/${VIVADO_TARBALL}

RUN mkdir -p /opt/vivado-src \
    && tar -xzf "/tmp/${VIVADO_TARBALL}" -C /opt/vivado-src \
    && cd "/opt/vivado-src/$(basename "${VIVADO_TARBALL}" .tar.gz)" \
    && ./xsetup -a XilinxEULA,3rdPartyEULA,WebTalkTerms \
         -b Install -c /tmp/install_config.txt \
    && rm -rf /opt/vivado-src "/tmp/${VIVADO_TARBALL}"

# The guide's libtinfo.so.5 workaround: Vivado does not search the system paths
# for it and fails to load librdi_commontasks.so without this symlink.
RUN ln -sf /lib/x86_64-linux-gnu/libtinfo.so.5 \
        /opt/Xilinx/Vivado/2019.2/lib/lnx64.o/libtinfo.so.5

# WebTalk is optional telemetry; disabling it also skips the host-info path that
# aborts under x86_64 emulation on Apple Silicon.
RUN source /opt/Xilinx/Vivado/2019.2/settings64.sh \
    && printf 'config_webtalk -user off\n' > /tmp/webtalk.tcl \
    && vivado -mode batch -nojournal -nolog -source /tmp/webtalk.tcl \
    && rm -f /tmp/webtalk.tcl

RUN command -v vivado && vivado -version | head -1

COPY vivado-entrypoint.sh /usr/local/bin/vivado-entrypoint
RUN chmod +x /usr/local/bin/vivado-entrypoint

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/vivado-entrypoint"]
CMD ["bash"]
