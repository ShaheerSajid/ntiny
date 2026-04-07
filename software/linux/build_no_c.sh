#!/bin/bash
# Build the rv32ima (no compressed) Linux kernel + OpenSBI payload and run
# the Verilator sim. Uses ntiny_no_c_defconfig for the kernel and
# PLATFORM_RISCV_ISA=rv32ima_zicsr_zifencei for OpenSBI so the firmware and
# kernel are both compressed-free.
#
# Usage:  ./build_no_c.sh [timeout_seconds] [skip_verilator]
#   skip_verilator=1 → skip Verilator rebuild (use existing Vtb_soc_top)
#
# Hardware still has the C extension; this only sidesteps c_controller
# alignment edge cases on the kernel-side fetch path while the fetch revamp
# is in progress (see docs/fetch_revamp_plan.md §4).
set -e
export PATH=/opt/riscv-linux/bin:$PATH

NTINY=/home/shaheer/Documents/github/ntiny
LINUX=/home/shaheer/Downloads/linux
OPENSBI=/home/shaheer/Downloads/opensbi
TIMEOUT=${1:-200}
SKIP_VERILATOR=${2:-0}

# ── 0. Verilator (rebuild if RTL changed) ──────────────────────
if [ "$SKIP_VERILATOR" != "1" ]; then
    cd $NTINY/flows/simulation
    echo "--- 0/5 Verilator rebuild (--trace) ---"
    rm -rf obj_dir Vtb_soc_top
    verilator -Wno-UNOPTFLAT -Wno-INITIALDLY -Wno-UNUSED -Wno-WIDTH \
        -Wno-CASEINCOMPLETE -Wno-PINMISSING -Wno-MULTIDRIVEN -Wno-STMTDLY \
        -Wno-UNPACKED -Wno-UNSIGNED -Wno-LITENDIAN -Wno-MODDUP -Wno-MISINDENT \
        --no-timing --timescale-override 1ns/10ps -O3 --threads 4 --trace \
        -DVERILATOR_SIM -sv --top-module tb_soc_top --cc \
        +define+RAM_SIZE_BYTES=134217728 \
        +incdir+../../design/common/ \
        +incdir+../../design/uncore/i2c/src/ +incdir+../../design/uncore/timer/src/ \
        +incdir+../../design/uncore/pwm/src/ +incdir+../../design/uncore/spi/src/ \
        +incdir+../../design/uncore/uart/src/ +incdir+../../design/core/fpu/PakFPU/src/ \
        -f src.args \
        ../../verification/dv/src/pkg.sv ../../verification/dv/src/tracer_pkg.sv \
        ../../verification/dv/src/tracer.sv testbench/uartdpi.c testbench/uartdpi.sv \
        testbench/tb_soc_top.v --exe testbench/main.cpp 2>&1 | tail -3
    make -j$(nproc) -C obj_dir/ -f Vtb_soc_top.mk Vtb_soc_top 2>&1 | tail -3
    cp obj_dir/Vtb_soc_top ./
    ls -la Vtb_soc_top
fi

# ── 1. DTB ──────────────────────────────────────────────────────
cd $NTINY/software/linux
echo "--- 1/5 dtc → ntiny.dtb ---"
dtc -I dts -O dtb -o ntiny.dtb ntiny.dts 2>&1

# ── 2. Kernel (ntiny_no_c_defconfig) ────────────────────────────
cd $LINUX
cp $NTINY/software/linux/ntiny_no_c_defconfig .config
echo "--- 2/5 kernel olddefconfig ---"
make ARCH=riscv CROSS_COMPILE=riscv32-unknown-linux-gnu- olddefconfig 2>&1 | tail -3
# Sanity-check: kernel must really have C disabled. The defconfig already has
# the right `# is not set` lines, but verify in case Kconfig dependencies
# silently flipped them back (this is what bug #12 looked like — symptoms
# look like a cpu hang).
if grep -q "^CONFIG_RISCV_ISA_C=y" .config; then
    echo "FAIL: CONFIG_RISCV_ISA_C is still =y after olddefconfig — check Kconfig deps"
    grep "RISCV_ISA_C\|EFI" .config
    exit 1
fi
echo "  ✓ RISCV_ISA_C disabled"
grep -q "^CONFIG_HVC_RISCV_SBI=y" .config || { echo "FAIL: HVC_RISCV_SBI dropped — kernel will be silent"; exit 1; }
echo "  ✓ HVC_RISCV_SBI enabled"

echo "--- 2/5 kernel build (-j$(nproc)) ---"
make ARCH=riscv CROSS_COMPILE=riscv32-unknown-linux-gnu- -j$(nproc) 2>&1 | tail -5

# ── 3. OpenSBI with rv32ima ────────────────────────────────────
cd $OPENSBI
make clean >/dev/null 2>&1
echo "--- 3/5 OpenSBI build ---"
make CROSS_COMPILE=riscv32-unknown-linux-gnu- \
     PLATFORM_DIR=$NTINY/software/linux/opensbi-platform \
     PLATFORM_RISCV_XLEN=32 \
     PLATFORM_RISCV_ISA=rv32ima_zicsr_zifencei \
     PLATFORM_RISCV_ABI=ilp32 \
     FW_PAYLOAD_PATH=$LINUX/arch/riscv/boot/Image \
     FW_FDT_PATH=$NTINY/software/linux/ntiny.dtb \
     -j$(nproc) 2>&1 | tail -5

OPENSBI_BIN=$OPENSBI/build/platform/opensbi-platform/firmware/fw_payload.bin
ls -la $OPENSBI_BIN

# ── 4. Run Linux ───────────────────────────────────────────────
cd $NTINY/flows/simulation
python3 ../../software/tools/hex_text.py "$OPENSBI_BIN" ram.hex
rm -f uart.log
echo "--- 4/5 sim (${TIMEOUT}s wall, 500M cycles) ---"
timeout $TIMEOUT ./Vtb_soc_top --timeout 500000000 > /dev/null 2>&1 &
PID=$!
echo "PID $PID — monitor: tail -f $NTINY/flows/simulation/uart.log"

INTERVAL=10
N=$((TIMEOUT / INTERVAL))
for ((i=1; i<=N; i++)); do
    sleep $INTERVAL
    if ! kill -0 $PID 2>/dev/null; then echo "done at t=$((i*INTERVAL))s"; break; fi
    LAST=$(tail -1 uart.log 2>/dev/null || echo "?")
    echo "  t=$((i*INTERVAL))s  $LAST"
done

kill $PID 2>/dev/null || true
wait $PID 2>/dev/null || true

echo ""
echo "--- uart.log: $(wc -l < uart.log) lines ---"
echo "--- last 30 lines ---"
tail -30 uart.log
