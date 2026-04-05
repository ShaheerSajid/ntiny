#!/bin/bash
# Build (if needed) and run Linux boot simulation
# Usage: ./run_linux.sh [timeout_cycles]
set -e
cd "$(dirname "$0")"

TIMEOUT=${1:-2000000000}
OPENSBI_BIN=$(find /home/shaheer/Downloads/opensbi/build -name "fw_payload.bin" -path "*/opensbi-platform/*" 2>/dev/null | head -1)

if [ -z "$OPENSBI_BIN" ]; then
    echo "ERROR: OpenSBI fw_payload.bin not found. Build it first (see software/linux/README.md)"
    exit 1
fi

# Build Verilator model if needed (128MB RAM, no traces)
if [ ! -f Vtb_soc_top ] || [ ! -d obj_dir ]; then
    echo "Building Verilator model (128MB RAM, no traces)..."
    rm -rf obj_dir Vtb_soc_top
    verilator -Wno-UNOPTFLAT -Wno-INITIALDLY -Wno-UNUSED -Wno-WIDTH \
        -Wno-CASEINCOMPLETE -Wno-PINMISSING -Wno-MULTIDRIVEN -Wno-STMTDLY \
        -Wno-UNPACKED -Wno-UNSIGNED -Wno-LITENDIAN -Wno-MODDUP -Wno-MISINDENT \
        --no-timing --timescale-override 1ns/10ps -O3 --threads 4 \
        -DVERILATOR_SIM -sv --top-module tb_soc_top --cc \
        +define+RAM_SIZE_BYTES=134217728 \
        +incdir+../../design/common/ \
        +incdir+../../design/uncore/i2c/src/ +incdir+../../design/uncore/timer/src/ \
        +incdir+../../design/uncore/pwm/src/ +incdir+../../design/uncore/spi/src/ \
        +incdir+../../design/uncore/uart/src/ +incdir+../../design/core/fpu/PakFPU/src/ \
        -f src.args \
        ../../verification/dv/src/pkg.sv ../../verification/dv/src/tracer_pkg.sv \
        ../../verification/dv/src/tracer.sv testbench/uartdpi.c testbench/uartdpi.sv \
        testbench/tb_soc_top.v --exe testbench/main.cpp
    make -j$(nproc) -C obj_dir/ -f Vtb_soc_top.mk Vtb_soc_top
    cp obj_dir/Vtb_soc_top ./
fi

echo "=== Linux Boot ==="
echo "OpenSBI: $OPENSBI_BIN"
echo "Timeout: $TIMEOUT cycles"

python3 ../../software/tools/hex_text.py "$OPENSBI_BIN" ram.hex
rm -f uart.log crash_trace.log mmu_trace.log diag_trace.log
./Vtb_soc_top --timeout "$TIMEOUT" > /dev/null 2>&1 &
echo "PID: $! — monitor: tail -f uart.log"
