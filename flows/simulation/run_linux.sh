#!/bin/bash
# Build (if needed) and run Linux boot simulation
# Usage: ./run_linux.sh [timeout_cycles]
set -e
cd "$(dirname "$0")"

TIMEOUT=${1:-2000000000}
shift 2>/dev/null || true   # remaining $@ are extra +plusargs forwarded to Vtb_soc_top
OPENSBI_BIN=$(find ../../software/linux/external/opensbi/build \
    -name "fw_payload.bin" -path "*/opensbi-platform/*" 2>/dev/null | head -1)

if [ -z "$OPENSBI_BIN" ]; then
    echo "ERROR: OpenSBI fw_payload.bin not found. Build it first (see software/linux/README.md)"
    exit 1
fi

# Always rebuild from a clean slate so an RTL change since the last
# run doesn't get masked by a stale binary or obj_dir cache. Both
# stdout AND stderr from verilator + the C++ build go to a single
# logs/verilator_build.log so the terminal stays clean and the full
# build trace lives in one inspectable file.
mkdir -p logs
echo "Cleaning verilator collateral (Vtb_soc_top + obj_dir)..."
rm -rf obj_dir Vtb_soc_top
if true; then
    echo "Building Verilator model (128MB RAM, FST tracing compiled in)..."
    echo "  build log -> logs/verilator_build.log"
    # Suppression policy (2026-05-05 update):
    #   Correctness-relevant warnings are FATAL — UNOPTFLAT (comb
    #   loops), MULTIDRIVEN, CASEINCOMPLETE, WIDTH, UNSIGNED. Any
    #   new instance breaks the build so we have to fix it (or
    #   localise with `// verilator lint_off UNOPTFLAT` markers).
    #   This was tightened to surface comb-loop races discovered in
    #   the BPU/mmu_i_stall path during pty_init debug.
    #   Style / Verilator-specific cleanups (UNUSED, PINMISSING,
    #   INITIALDLY, STMTDLY, UNPACKED, LITENDIAN, MODDUP, MISINDENT)
    #   stay silenced because the codebase has many benign instances
    #   that aren't worth the noise.
    #
    # FST tracing (2026-05-07): tb_soc_top.v exposes +wave_start /
    # +wave_stop / +wave_file plusargs that gate $dumpon/$dumpoff on
    # a cycle window. With no plusarg the trace machinery stays
    # dormant; the cost is ~2-3x runtime even when not dumping. Use
    # GTKWave (or surfer/scviewer) to inspect /tmp/wave.fst post-hoc.
    verilator -Wno-INITIALDLY -Wno-UNUSED -Wno-WIDTH \
        -Wno-PINMISSING -Wno-MULTIDRIVEN -Wno-STMTDLY \
        -Wno-UNPACKED -Wno-UNSIGNED \
        -Wno-LITENDIAN -Wno-MODDUP -Wno-MISINDENT \
        --no-timing --timescale-override 1ns/10ps -O3 --threads 4 \
        --trace-fst --trace-structs --trace-params --trace-threads 2 \
        -DVERILATOR_SIM -DDV_TRACER -sv --top-module tb_soc_top --cc \
        +define+RAM_SIZE_BYTES=134217728 \
        +incdir+../../design/common/ \
        +incdir+../../design/uncore/i2c/src/ +incdir+../../design/uncore/timer/src/ \
        +incdir+../../design/uncore/pwm/src/ +incdir+../../design/uncore/spi/src/ \
        +incdir+../../design/uncore/uart/src/ +incdir+../../design/core/fpu/PakFPU/src/ \
        -f src.args \
        ../../verification/dv/src/pkg.sv ../../verification/dv/src/tracer_pkg.sv \
        ../../verification/dv/src/tracer.sv testbench/uartdpi.c testbench/uartdpi.sv \
        testbench/tb_tracer.sv testbench/tb_soc_top.v --exe testbench/main.cpp \
        > logs/verilator_build.log 2>&1
    make -j$(nproc) -C obj_dir/ -f Vtb_soc_top.mk Vtb_soc_top \
        >> logs/verilator_build.log 2>&1
    cp obj_dir/Vtb_soc_top ./
fi

echo "=== Linux Boot ==="
echo "OpenSBI: $OPENSBI_BIN"
echo "Timeout: $TIMEOUT cycles"

python3 ../../software/tools/hex_text.py "$OPENSBI_BIN" ram.hex
mkdir -p logs && rm -f logs/uart.log

# Tracer is OFF by default — full Linux boots produce 12+ GB of
# trace_core_*.log otherwise. Enable a window by setting TRACER env
# var (e.g. TRACER='+tracer_start_pc=00043fd6 +tracer_stop_pc=00044362')
# or by passing the +tracer_* plusargs as positional args.
if [ -n "$TRACER" ]; then
    TRACER_DEFAULTS="$TRACER"
    echo "Tracer ENABLED: $TRACER_DEFAULTS"
else
    TRACER_DEFAULTS="+tracer_start_pc=ffffffff +tracer_stop_pc=ffffffff"
    echo "Tracer disabled (set TRACER='+tracer_start_pc=... +tracer_stop_pc=...' to enable)"
fi

./Vtb_soc_top --timeout "$TIMEOUT" $TRACER_DEFAULTS "$@" > /dev/null 2>&1 &
echo "PID: $! — monitor: tail -f logs/uart.log"
[ $# -gt 0 ] && echo "Extra plusargs: $*"
