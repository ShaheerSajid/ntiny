#!/bin/bash
# ── riscv-dv: generate → compile → Spike → ntiny DUT → compare ──────────────
#
# Usage:
#   ./run_riscv_dv.sh                                    # run all tests
#   ./run_riscv_dv.sh -tn riscv_arithmetic_basic_test    # run one test
#   ./run_riscv_dv.sh -tn riscv_hazard_test --seed 42    # specific seed
#   ./run_riscv_dv.sh --list                             # list available tests
#
# Requirements:
#   - ~/Downloads/riscv-dv         (Google riscv-dv)
#   - ~/Software/python_env        (venv with pyvsc, bitstring, tabulate)
#   - /opt/riscv/bin/spike          (Spike ISS)
#   - /opt/riscv/bin/riscv64-unknown-elf-gcc
#   - Verilator model built by:  make -C verification/riscv-dv verilator

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RISCV_DV="${HOME}/Downloads/riscv-dv"
NTINY_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SIM_DIR="${NTINY_ROOT}/flows/simulation"
VENV="${HOME}/Software/python_env/bin/activate"
HEX_TOOL="${NTINY_ROOT}/software/tools/hex_text.py"
COMPARE="${SCRIPT_DIR}/compare_trace.py"
OUTPUT="${SCRIPT_DIR}/out"
DV_MODEL="${SCRIPT_DIR}/Vtb_soc_top"

GCC=riscv64-unknown-elf-gcc
OBJCOPY=riscv64-unknown-elf-objcopy
MARCH="rv32imafc_zicsr_zifencei"
MABI="ilp32"
SPIKE_ISA="rv32imafc_zicsr_zifencei"
SPIKE_PRIV="msu"
DUT_TIMEOUT=500000  # cycles
DUT_RAM_SIZE=1048576  # 1MB

# ── Argument parsing ─────────────────────────────────────────────────────────
TEST_NAME=""
SEED_ARG=""
LIST_ONLY=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        -tn|--test)   TEST_NAME="$2"; shift 2;;
        --seed)       SEED_ARG="--seed $2"; shift 2;;
        --list)       LIST_ONLY=1; shift;;
        -h|--help)
            echo "Usage: $0 [-tn <test>] [--seed <N>] [--list]"
            exit 0;;
        *) echo "Unknown arg: $1"; exit 1;;
    esac
done

# ── List tests ───────────────────────────────────────────────────────────────
if [[ $LIST_ONLY -eq 1 ]]; then
    echo "Available tests in testlist.yaml:"
    grep "^- test:" "$SCRIPT_DIR/testlist.yaml" | sed 's/^- test: /  /'
    exit 0
fi

# ── Determine test set ───────────────────────────────────────────────────────
if [[ -z "$TEST_NAME" ]]; then
    TESTS=$(grep "^- test:" "$SCRIPT_DIR/testlist.yaml" | sed 's/^- test: //')
else
    TESTS="$TEST_NAME"
fi

# ── Check prerequisites ─────────────────────────────────────────────────────
if [[ ! -f "$DV_MODEL" ]]; then
    echo "ERROR: Verilator model not found at $DV_MODEL"
    echo "Build it:  make -C verification/riscv-dv verilator"
    exit 1
fi

source "$VENV"

rm -rf "$OUTPUT"
mkdir -p "$OUTPUT"

PASS=0; FAIL=0; TOTAL=0

# ── Run each test ────────────────────────────────────────────────────────────
for TEST in $TESTS; do
    TOTAL=$((TOTAL + 1))
    TEST_DIR="$OUTPUT/$TEST"
    mkdir -p "$TEST_DIR"
    echo ""
    echo "━━━ [$TOTAL] $TEST ━━━"

    # Step 1: Generate assembly (timeout 120s per test)
    echo "  gen..."
    cd "$RISCV_DV"
    timeout 120 python3 run.py \
        --target rv32imc \
        -cs "$SCRIPT_DIR" \
        -o "$TEST_DIR" \
        -tl "$SCRIPT_DIR/testlist.yaml" \
        -tn "$TEST" \
        --isa rv32imafc --mabi "$MABI" \
        -i 1 -s gen --simulator pyflow \
        $SEED_ARG \
        > "$TEST_DIR/gen.log" 2>&1
    cd "$SCRIPT_DIR"

    ASM=$(find "$TEST_DIR" -name "*.S" | head -1)
    if [[ -z "$ASM" ]]; then
        echo "  FAIL: no assembly generated (see $TEST_DIR/gen.log)"
        FAIL=$((FAIL + 1))
        continue
    fi

    # Step 2: Compile (for Spike — tohost in .data at 0x80001000)
    echo "  compile..."
    $GCC -march=$MARCH -mabi=$MABI -nostdlib -nostartfiles \
        -I "$RISCV_DV/user_extension" \
        -T "$RISCV_DV/scripts/link.ld" \
        "$ASM" -o "$TEST_DIR/spike.elf" \
        > "$TEST_DIR/compile.log" 2>&1

    $OBJCOPY -O binary "$TEST_DIR/spike.elf" "$TEST_DIR/test.bin"

    # Step 3: Run on Spike
    echo "  spike..."
    timeout 30 spike --isa="$SPIKE_ISA" --priv="$SPIKE_PRIV" \
        -l --log-commits --log="$TEST_DIR/spike.log" \
        "$TEST_DIR/spike.elf" \
        > /dev/null 2>&1 || true

    if [[ ! -s "$TEST_DIR/spike.log" ]]; then
        echo "  FAIL: Spike produced no log"
        FAIL=$((FAIL + 1))
        continue
    fi

    # Step 4: Run on ntiny DUT
    echo "  dut..."
    WORK="$TEST_DIR/sim"
    mkdir -p "$WORK"
    python3 "$HEX_TOOL" "$TEST_DIR/test.bin" "$WORK/ram.hex"

    (cd "$WORK" && ln -sf "$DV_MODEL" Vtb_soc_top && \
     timeout 120 ./Vtb_soc_top --timeout "$DUT_TIMEOUT" > /dev/null 2>&1) || true

    DUT_TRACE="$WORK/trace_core_00000000.log"
    if [[ ! -s "$DUT_TRACE" ]]; then
        echo "  FAIL: DUT produced no trace"
        FAIL=$((FAIL + 1))
        continue
    fi

    # Step 5: Compare
    echo "  compare..."
    if python3 "$COMPARE" \
        --spike "$TEST_DIR/spike.log" \
        --dut "$DUT_TRACE" \
        > "$TEST_DIR/compare.log" 2>&1; then
        RESULT="PASS"
        PASS=$((PASS + 1))
    else
        RESULT="FAIL"
        FAIL=$((FAIL + 1))
    fi

    # Show result
    SUMMARY=$(tail -1 "$TEST_DIR/compare.log")
    echo "  $RESULT: $SUMMARY"
done

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  PASS: $PASS   FAIL: $FAIL   TOTAL: $TOTAL"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Results in: $OUTPUT"

exit $FAIL
