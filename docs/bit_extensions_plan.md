# Bit Manipulation Extensions Implementation Plan

**Goal**: Implement the complete RISC-V bit-manipulation extensions
(Zba + Zbb + Zbc + Zbs) on the ntiny core, fix the MISA advertisement,
expose the extensions to OS/userspace via the device tree, and validate
against the official `riscv-arch-test` Zb* compliance suite (32 tests
already present in `verification/riscof/riscv-arch-test/.../rv32i_m/B/`).

Spec reference: `~/Downloads/riscv-unprivileged.pdf`, Chapter 30
("Bit Manipulation Extensions"), Version 20260120.

---

## 1. Current state inventory

### What's already implemented (Zba + Zbb)

`design/core/alu/src/zba_zbb.sv` — combinational module computing all
Zba/Zbb outputs in parallel.

`design/core/include/core_pkg.sv:66-89` — `bit_op_e` enum with 21 ops:
```
SH1ADD, SH2ADD, SH3ADD,           // Zba
ANDN, ORN, XNOR,                  // Zbb logical-with-negate
CLZ, CTZ, CPOP,                   // Zbb count
MAX, MAXU, MIN, MINU,             // Zbb min/max
SEXTB, SEXTH, ZEXTH,              // Zbb extend
ROL, ROR, RORI,                   // Zbb rotation
ORCB, REV8, NO_BIT_OP             // Zbb misc
```

`design/core/control_path/src/decoder.sv` — decodes Zba/Zbb instructions
under OP_R (lines 188-213) and OP_I (lines 144-163).

`design/core/alu/src/alu.sv` — instantiates `zba_zbb`, muxes its outputs
into `bit_result`, and produces final result via the bit_op path.

### What's broken or missing

1. **MISA bit 1 (B) is set** — `csr_unit.sv:441-443` returns
   `0x40141107` which advertises the deprecated unified "B" extension.
   Software may emit Zbc/Zbs instructions assuming they exist → illegal
   instruction trap on the post-Zbb instructions.

2. **Device tree doesn't list any Zb extensions** —
   `software/linux/ntiny.dts` has `riscv,isa-extensions` listing only
   `i, m, a, c, zicsr, zifencei, zkr`. Even Zba and Zbb (which ARE
   implemented) are invisible to the kernel.

3. **Zbc not implemented** — no carry-less multiply unit.
   Missing instructions: `clmul`, `clmulh`, `clmulr`.

4. **Zbs not implemented** — no single-bit operations.
   Missing instructions: `bclr`, `bclri`, `bext`, `bexti`,
   `binv`, `binvi`, `bset`, `bseti`.

---

## 2. RV32 instruction set to implement

### Zba (already implemented — RV32 has only 3 instructions)

| Mnemonic            | Encoding (funct7, funct3, opcode) | Operation                          |
|---------------------|-----------------------------------|------------------------------------|
| `sh1add rd,rs1,rs2` | `0010000 010 0110011`             | rd = rs2 + (rs1 << 1)              |
| `sh2add rd,rs1,rs2` | `0010000 100 0110011`             | rd = rs2 + (rs1 << 2)              |
| `sh3add rd,rs1,rs2` | `0010000 110 0110011`             | rd = rs2 + (rs1 << 3)              |

(`add.uw`, `sh*add.uw`, `slli.uw` are RV64-only.)

### Zbb (already implemented — but verify all RV32 cases)

| Mnemonic              | Encoding                      | Operation                                |
|-----------------------|-------------------------------|------------------------------------------|
| `andn rd,rs1,rs2`     | `0100000 111 0110011`         | rd = rs1 & ~rs2                          |
| `orn rd,rs1,rs2`      | `0100000 110 0110011`         | rd = rs1 \| ~rs2                         |
| `xnor rd,rs1,rs2`     | `0100000 100 0110011`         | rd = ~(rs1 ^ rs2)                        |
| `clz rd,rs1`          | `0110000 00000 001 0010011`   | rd = leading zeros of rs1                |
| `ctz rd,rs1`          | `0110000 00001 001 0010011`   | rd = trailing zeros of rs1               |
| `cpop rd,rs1`         | `0110000 00010 001 0010011`   | rd = popcount(rs1)                       |
| `max rd,rs1,rs2`      | `0000101 110 0110011`         | rd = signed max                          |
| `maxu rd,rs1,rs2`     | `0000101 111 0110011`         | rd = unsigned max                        |
| `min rd,rs1,rs2`      | `0000101 100 0110011`         | rd = signed min                          |
| `minu rd,rs1,rs2`     | `0000101 101 0110011`         | rd = unsigned min                        |
| `sext.b rd,rs1`       | `0110000 00100 001 0010011`   | sign-extend byte                         |
| `sext.h rd,rs1`       | `0110000 00101 001 0010011`   | sign-extend halfword                     |
| `zext.h rd,rs1`       | `0000100 00000 100 0110011`   | zero-extend halfword (R-type, rs2=x0)    |
| `rol rd,rs1,rs2`      | `0110000 001 0110011`         | rotate left by rs2[4:0]                  |
| `ror rd,rs1,rs2`      | `0110000 101 0110011`         | rotate right by rs2[4:0]                 |
| `rori rd,rs1,shamt`   | `0110000 shamt 101 0010011`   | rotate right immediate                   |
| `orc.b rd,rs1`        | `0010100 00111 101 0010011`   | per-byte OR-combine                      |
| `rev8 rd,rs1`         | `0110100 11000 101 0010011`   | byte-reverse                             |

**Note**: Existing Zbb implementation looks complete for RV32. Plan
includes a verification pass against the 32 Zb* compliance tests.

### Zbc (NEW — 3 instructions)

| Mnemonic                | Encoding              | Operation                                  |
|-------------------------|-----------------------|--------------------------------------------|
| `clmul rd,rs1,rs2`      | `0000101 001 0110011` | low 32 bits of carry-less product          |
| `clmulh rd,rs1,rs2`     | `0000101 011 0110011` | high 32 bits of carry-less product         |
| `clmulr rd,rs1,rs2`     | `0000101 010 0110011` | bits [62:31] of carry-less product         |

Carry-less multiply = polynomial multiply over GF(2) — same as integer
multiply but using XOR instead of integer addition for the partial
product accumulation.

```
output = 0
for i in 0..XLEN-1:
    if rs2[i]: output ^= (rs1 << i)
clmul  = output[31:0]
clmulh = output[63:32]
clmulr = output[62:31]   // a.k.a. {output[62:32], output[31]}
```

### Zbs (NEW — 8 instructions: 4 reg + 4 imm)

| Mnemonic               | Encoding                      | Operation                              |
|------------------------|-------------------------------|----------------------------------------|
| `bclr rd,rs1,rs2`      | `0100100 001 0110011`         | rd = rs1 & ~(1 << (rs2 & 31))          |
| `bclri rd,rs1,shamt`   | `0100100 shamt 001 0010011`   | rd = rs1 & ~(1 << shamt)               |
| `bext rd,rs1,rs2`      | `0100100 101 0110011`         | rd = (rs1 >> (rs2 & 31)) & 1           |
| `bexti rd,rs1,shamt`   | `0100100 shamt 101 0010011`   | rd = (rs1 >> shamt) & 1                |
| `binv rd,rs1,rs2`      | `0110100 001 0110011`         | rd = rs1 ^ (1 << (rs2 & 31))           |
| `binvi rd,rs1,shamt`   | `0110100 shamt 001 0010011`   | rd = rs1 ^ (1 << shamt)                |
| `bset rd,rs1,rs2`      | `0010100 001 0110011`         | rd = rs1 \| (1 << (rs2 & 31))          |
| `bseti rd,rs1,shamt`   | `0010100 shamt 001 0010011`   | rd = rs1 \| (1 << shamt)               |

(In RV32, `shamt` is 5 bits — funct7 stays 7 bits, encodings above use
the standard "fixed funct7" form for Zbs immediates.)

---

## 3. Implementation tasks (in dependency order)

### Task 1 — Fix MISA advertisement (cleanup, no HW change)

**File**: `design/core/csr_unit/src/csr_unit.sv` lines 441-443.

```diff
-MISA: csr_value_o = 32'h40141107; // RV32IMAFCSU + B
+MISA: csr_value_o = 32'h40141105; // RV32IMACSU
-MISA: csr_value_o = 32'h40141127; // RV32IMACSU + B
+MISA: csr_value_o = 32'h40141125; // RV32IMAFCSU
```

(Bit 1 = B, cleared. Bits 8/12/2/0/18/20/30 = I/M/C/A/S/U/MXL[1].)

**Why first**: removes the misleading advertisement so software stops
emitting Zbc/Zbs instructions before we have HW for them. After this
fix, any executed Zbc/Zbs becomes a clean illegal-instruction trap
instead of a silent wrong result.

**Validation**: rebuild OpenSBI, check banner shows `rv32imacsu`
without `b`.

### Task 2 — Extend `bit_op_e` enum

**File**: `design/core/include/core_pkg.sv` lines 66-89.

Add 11 new entries (3 Zbc + 8 Zbs):

```systemverilog
typedef enum logic[5:0] {     // widen from [4:0] to [5:0] (32 → 64 cap)
    SH1ADD, SH2ADD, SH3ADD,
    ANDN, ORN, XNOR,
    CLZ, CTZ, CPOP,
    MAX, MAXU, MIN, MINU,
    SEXTB, SEXTH, ZEXTH,
    ROL, ROR, RORI,
    ORCB, REV8,
    // Zbc — carry-less multiply
    CLMUL, CLMULH, CLMULR,
    // Zbs — single-bit
    BCLR, BCLRI, BEXT, BEXTI,
    BINV, BINVI, BSET, BSETI,
    NO_BIT_OP
} bit_op_e;
```

(BCLR/BCLRI etc. share the same datapath but distinguishing them in
the enum keeps the decoder symmetric — could merge to BCLR/BEXT/BINV/BSET
since the immediate is already broken out by the decoder elsewhere.)

### Task 3 — Add Zbs datapath

**New file**: `design/core/alu/src/zbs.sv` (or extend `zba_zbb.sv` →
rename to `zbb_zbs.sv` since they share the unit).

Pure combinational, ~50 gates total:

```systemverilog
module zbs (
    input  logic [31:0] in1_i,    // rs1
    input  logic [4:0]  shamt_i,  // rs2[4:0] for reg, imm[4:0] for imm
    output logic [31:0] bclr_o,
    output logic [31:0] bext_o,
    output logic [31:0] binv_o,
    output logic [31:0] bset_o
);
    wire [31:0] mask = 32'd1 << shamt_i;
    assign bclr_o = in1_i & ~mask;
    assign bext_o = {31'd0, in1_i[shamt_i]};   // or (in1 >> shamt) & 1
    assign binv_o = in1_i ^ mask;
    assign bset_o = in1_i | mask;
endmodule
```

That's it — 4 outputs, 1 shifter, basic boolean ops. The shifter can
be reused with the existing rol/ror barrel shifter if synthesis area
matters.

### Task 4 — Add Zbc datapath (CLMUL)

**New file**: `design/core/alu/src/clmul.sv`.

Two implementation choices, pick based on area/timing budget:

#### Option A — Single-cycle parallel CLMUL (~32 XOR gates wide × 32 deep)

```systemverilog
module clmul (
    input  logic [31:0] in1_i,    // rs1
    input  logic [31:0] in2_i,    // rs2
    output logic [63:0] result_o  // full 64-bit carry-less product
);
    logic [63:0] partial [32];
    always_comb begin
        for (int i = 0; i < 32; i++)
            partial[i] = in2_i[i] ? ({32'd0, in1_i} << i) : 64'd0;
    end

    // XOR reduction (carry-less sum)
    always_comb begin
        result_o = 64'd0;
        for (int i = 0; i < 32; i++)
            result_o ^= partial[i];
    end
endmodule
```

Synthesizes to a 32-deep XOR tree. Single-cycle but ~1k gates and
potentially long combinational delay. Acceptable for ntiny's clock
target (~50-100 MHz on FPGA, lower on TSMC65).

#### Option B — Iterative CLMUL (32 cycles, tiny area)

A 32-cycle FSM that accumulates one partial per cycle. Reuses the
existing `divider`-style multi-cycle FSM pattern in `alu.sv`.

Pros: ~50 gates of state, no critical path stress.
Cons: 32-cycle stall on every CLMUL, requires hooking into
`alu_stall_o` (similar to how `divider` does it today).

**Recommendation**: start with Option A (single-cycle). If timing
fails, drop to Option B. Either way the public interface from `alu.sv`
is the same.

#### Output mux

```systemverilog
case (bit_op_i)
    CLMUL:  bit_result = clmul_result[31:0];
    CLMULH: bit_result = clmul_result[63:32];
    CLMULR: bit_result = clmul_result[62:31];   // bits 62..31, MSB→LSB
    ...
endcase
```

### Task 5 — Wire new units into `alu.sv`

In `design/core/alu/src/alu.sv`:

1. Add wire declarations for `bclr_o, bext_o, binv_o, bset_o,
   clmul_result[63:0]`.
2. Instantiate `zbs zbs_inst (...)` with `shamt_i = b_i[4:0]`.
3. Instantiate `clmul clmul_inst (...)`.
4. Extend the `bit_result` mux with the 11 new ops.
5. (No change needed to the result_o mux at line 290 — `bit_op_i !=
   NO_BIT_OP` already routes everything through `bit_result`.)

### Task 6 — Extend the decoder

**File**: `design/core/control_path/src/decoder.sv` lines 144-213.

Under OP_R (line 173): add cases for funct7 values used by new
instructions:

```systemverilog
7'b0000101: case(funct3)         // existing min/max + new clmul
    3'b001: bit_op = CLMUL;      // NEW
    3'b010: bit_op = CLMULR;     // NEW
    3'b011: bit_op = CLMULH;     // NEW
    3'b100: bit_op = MIN;        // existing
    3'b101: bit_op = MINU;       // existing
    3'b110: bit_op = MAX;        // existing
    3'b111: bit_op = MAXU;       // existing
endcase

7'b0100100: case(funct3)         // NEW — bclr/bext
    3'b001: bit_op = BCLR;
    3'b101: bit_op = BEXT;
endcase

7'b0110100: case(funct3)         // NEW — binv
    3'b001: bit_op = BINV;
endcase

7'b0010100: case(funct3)         // NEW — bset
    3'b001: bit_op = BSET;
endcase
```

Under OP_I (line 138): add the immediate-form Zbs:

```systemverilog
3'b001: case(funct7)
    7'b0000000: alu_op = SLL;
    7'b0010100: bit_op = BSETI;        // NEW
    7'b0100100: bit_op = BCLRI;        // NEW
    7'b0110100: bit_op = BINVI;        // NEW
    7'b0110000: case(funct5) ... endcase  // existing clz/ctz/cpop/sext
endcase

3'b101: casez({funct7,funct5})
    {7'b0000000,5'b?????}: alu_op = SRL;
    {7'b0100000,5'b?????}: alu_op = SRA;
    {7'b0100100,5'b?????}: bit_op = BEXTI;     // NEW
    {7'b0110000,5'b?????}: bit_op = RORI;
    {7'b0010100,5'b00111}: bit_op = ORCB;
    {7'b0110100,5'b11000}: bit_op = REV8;
endcase
```

### Task 7 — Update device tree advertisement

**File**: `software/linux/ntiny.dts`:

```diff
-riscv,isa = "rv32imac_zicsr_zifencei_zkr";
-riscv,isa-extensions = "i", "m", "a", "c", "zicsr", "zifencei", "zkr";
+riscv,isa = "rv32imac_zicsr_zifencei_zba_zbb_zbc_zbs_zkr";
+riscv,isa-extensions = "i", "m", "a", "c", "zicsr", "zifencei",
+                       "zba", "zbb", "zbc", "zbs", "zkr";
```

Then rebuild OpenSBI fw_payload.bin so the embedded DTB picks it up.

### Task 8 — Validate against riscv-arch-test Zb* suite

The 32 compliance tests are already in
`verification/riscof/riscv-arch-test/riscv-test-suite/rv32i_m/B/src/`.

The current RISCOF config (`verification/riscof/ntiny/ntiny_isa.yaml`)
needs to be updated to advertise the new Z* extensions, otherwise
RISCOF skips them.

```yaml
hart0:
  ISA: RV32IMACZba_Zbb_Zbc_Zbs_Zicsr_Zifencei
  ...
```

Then `make -C verification/riscof run` and check for new tests in the
summary. The 32 Zb tests should all PASS.

### Task 9 — Add directed unit tests (optional, for coverage)

Write a small assembly test that exercises edge cases for each new
instruction:
- `bclri x1, x2, 0` and `bclri x1, x2, 31` (boundaries)
- `clmul` with random patterns + known answers
- Mixed Zbs/Zbc sequences

Place under `software/tests/zb_extensions/` and run via the existing
baremetal test infrastructure.

---

## 4. Risk register

| Risk                                          | Mitigation                                                       |
|-----------------------------------------------|------------------------------------------------------------------|
| CLMUL critical path too long for 65nm timing  | Drop to iterative Option B (32-cycle FSM)                        |
| Decoder funct7 collisions with future M ext   | Verify funct7 = 7'b0000101 only used by min/max + clmul (it is)  |
| Compliance test failures due to encoding bugs | Each instr has its own `*-01.S` test → easy to localize          |
| Linux requires zext.h via different encoding  | Existing zext.h decode is correct (`0000100 00000 100 0110011`)  |

---

## 5. Estimated work

| Task                              | Files touched | New LoC | Notes                       |
|-----------------------------------|---------------|---------|-----------------------------|
| 1. MISA fix                       | 1             | 0 (edit)| 5-min change                |
| 2. `bit_op_e` extension           | 1             | ~12     | Trivial                     |
| 3. Zbs datapath                   | 1 new         | ~30     | Pure combinational          |
| 4. Zbc datapath                   | 1 new         | ~50     | Single-cycle XOR tree       |
| 5. ALU integration                | 1             | ~20     | Wires + mux extension       |
| 6. Decoder extension              | 1             | ~30     | New funct7 cases            |
| 7. DT advertisement               | 1             | ~3      | + OpenSBI rebuild           |
| 8. RISCOF validation              | 1 (yaml)      | ~3      | Run + debug failures        |
| 9. Directed tests                 | several .S    | ~200    | Optional but recommended    |

**Total**: ~150 lines of RTL, ~3 lines of YAML, ~3 lines of DT.
~1 day of focused implementation + ~1 day of validation/debug.

---

## 6. Acceptance criteria

- [ ] MISA returns `0x40141105` (no B bit)
- [ ] All 32 `rv32i_m/B/src/*.S` RISCOF tests PASS
- [ ] Linux boot log shows `riscv: ELF capabilities` includes new
      extensions (or `riscv: ISA extensions ... zba zbb zbc zbs`)
- [ ] No regression in existing 191 RISCOF tests
- [ ] No regression in `make dv` (riscv-dv random tests)
- [ ] Linux still boots to `Run /init` past the SRET deadlock

---

## 7. Long-term: Zbk* (cryptography variants)

Out of scope for this plan but worth noting — the spec also has Zbkb,
Zbkc, Zbkx for cryptography. They mostly overlap with Zbb/Zbc, so once
the regular Zb* set is in place, declaring Zbk* support is largely a
matter of advertising in MISA/DT (most instructions are already there).

The only NEW Zbk* instructions over what we'll have are:
- `pack`, `packh` (Zbkb) — not implemented
- `brev8` (Zbkb) — bit-reverse each byte (~30 gates)
- `xperm4`, `xperm8` (Zbkx) — crossbar permute (more involved)

Defer until cryptography workloads become a priority.
