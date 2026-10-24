#!/usr/bin/env bash
# Container entrypoint for the Vivado build target.
#
# Apple Silicon / x86_64 emulation only:
#   Vivado's WebTalk host-info path calls libudev enumeration, which corrupts the
#   heap under Rosetta ("realloc(): invalid pointer") after routing completes.
#   WebTalk is disabled at image build time; hiding sysfs from libudev avoids the
#   enumeration. This needs --privileged (or --cap-add SYS_ADMIN). On native
#   x86_64 hosts the mount is unnecessary and its failure is harmless.
set -euo pipefail

if ! mount -t tmpfs none /sys 2>/dev/null; then
    echo "warning: could not hide /sys; not running privileged?" >&2
    echo "warning: expected only under x86_64 emulation (Rosetta/QEMU)." >&2
fi

export LANG="${LANG:-en_US.UTF-8}"
export LC_ALL="${LC_ALL:-en_US.UTF-8}"
export LITEX_ENV_VIVADO="${LITEX_ENV_VIVADO:-/opt/Xilinx/Vivado/2019.2}"

exec "$@"
