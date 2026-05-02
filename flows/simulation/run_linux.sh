#!/bin/bash
# Build (if needed) and run Linux boot simulation
# Usage: ./run_linux.sh [timeout_cycles]
set -e
cd "$(dirname "$0")"

TIMEOUT=${1:-2000000000}
shift 2>/dev/null || true   # remaining $@ are extra +plusargs forwarded to Vtb_soc_top
# Search the in-repo external/ tree first, then fall back to the legacy
# ~/Downloads location for users who haven't migrated yet.
OPENSBI_BIN=$(find ../../software/linux/external/opensbi/build /home/shaheer/Downloads/opensbi/build \
    -name "fw_payload.bin" -path "*/opensbi-platform/*" 2>/dev/null | head -1)

if [ -z "$OPENSBI_BIN" ]; then
    echo "ERROR: OpenSBI fw_payload.bin not found. Build it first (see software/linux/README.md)"
    exit 1
fi

# Build Verilator model if needed (128MB RAM, no traces)
if [ ! -f Vtb_soc_top ] || [ ! -d obj_dir ]; then
    echo "Building Verilator model (128MB RAM, no traces)..."
    rm -rf obj_dir Vtb_soc_top
    # Suppression policy:
    #   Correctness-relevant warnings are NOT silenced — UNOPTFLAT
    #   (combinational loops), MULTIDRIVEN, CASEINCOMPLETE, WIDTH,
    #   UNSIGNED. A real instance of any of these is almost always a
    #   bug. Style / Verilator-specific cleanups (UNUSED, PINMISSING,
    #   INITIALDLY, STMTDLY, UNPACKED, LITENDIAN, MODDUP, MISINDENT)
    #   stay silenced because the codebase has many benign instances
    #   that aren't worth the noise.
    #
    #   --Wno-fatal makes warnings visible but non-fatal: a new
    #   UNOPTFLAT is reported but doesn't break the build, while still
    #   being noticeable in the elaboration log. The pre-existing
    #   loops (interrupt_ctrl ecall_valid / ebreak_valid /
    #   illegal_valid) and CASEINCOMPLETE warnings stay informational.
    verilator --Wno-fatal -Wno-INITIALDLY -Wno-UNUSED \
        -Wno-PINMISSING -Wno-STMTDLY \
        -Wno-UNPACKED -Wno-LITENDIAN -Wno-MODDUP -Wno-MISINDENT \
        --no-timing --timescale-override 1ns/10ps -O3 --threads 4 \
        -DVERILATOR_SIM -DDV_TRACER -sv --top-module tb_soc_top --cc \
        +define+RAM_SIZE_BYTES=134217728 \
        +incdir+../../design/common/ \
        +incdir+../../design/uncore/i2c/src/ +incdir+../../design/uncore/timer/src/ \
        +incdir+../../design/uncore/pwm/src/ +incdir+../../design/uncore/spi/src/ \
        +incdir+../../design/uncore/uart/src/ +incdir+../../design/core/fpu/PakFPU/src/ \
        -f src.args \
        ../../verification/dv/src/pkg.sv ../../verification/dv/src/tracer_pkg.sv \
        ../../verification/dv/src/tracer.sv testbench/uartdpi.c testbench/uartdpi.sv \
        testbench/tb_tracer.sv testbench/tb_soc_top.v --exe testbench/main.cpp
    make -j$(nproc) -C obj_dir/ -f Vtb_soc_top.mk Vtb_soc_top
    cp obj_dir/Vtb_soc_top ./
fi

echo "=== Linux Boot ==="
echo "OpenSBI: $OPENSBI_BIN"
echo "Timeout: $TIMEOUT cycles"

python3 ../../software/tools/hex_text.py "$OPENSBI_BIN" ram.hex
mkdir -p logs && rm -f logs/uart.log

# Default tracer window: arm at user PC = ash readtoken keyword-conv
# store (just before lasttoken gets set) and disarm at the parser-error
# raise PC, so the trace captures only the ~few-thousand cycles around
# the ash failure instead of the full ~12 GB boot trace. Override by
# passing your own +tracer_start_pc / +tracer_stop_pc on the cmdline.
if [ -n "$NO_TRACER" ]; then
    TRACER_DEFAULTS="+tracer_start_pc=ffffffff +tracer_stop_pc=ffffffff"
    echo "Tracer DISABLED (NO_TRACER set)"
else
    TRACER_DEFAULTS="+tracer_start_pc=00043fd6 +tracer_stop_pc=00044362"
    echo "Tracer window: $TRACER_DEFAULTS (override via positional args)"
fi

./Vtb_soc_top --timeout "$TIMEOUT" $TRACER_DEFAULTS "$@" > /dev/null 2>&1 &
echo "PID: $! — monitor: tail -f logs/uart.log"
[ $# -gt 0 ] && echo "Extra plusargs: $*"
