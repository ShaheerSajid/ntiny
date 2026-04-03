# Bugs Found and Fixed During Linux Boot Bring-up

Every issue encountered while booting OpenSBI + Linux on ntiny, with root cause
analysis and fix details. Ordered chronologically as discovered.

---

## 1. AMO Flush Bug (Pre-Linux, RISCOF testing)

**Symptom**: `amoswap`, `amoand`, `amoor` returned stale values when compiled
with `-O1` or higher. `amoadd` worked. Only manifested when the instruction
after the AMO was a branch reading the AMO result.

**Root Cause**: Combinational loop between `amo_stall`, `ie_flush`, and
`insert_bubble`. When an AMO instruction was in the IE stage and the next
instruction (in IF/ID) was a branch reading the AMO's destination register,
the stall_line's `insert_bubble` triggered `ie_flush`. This killed the AMO
FSM before it could leave IDLE. Verilator settled the combinational loop on
`ie_flush=1`, so the AMO never started and the stale result from the previous
operation was written to rd.

**Fix**: Disconnect `ie_flush` from the AMO unit's `flush_i` input. Only
`interrupt_valid` should abort an AMO start. The AMO unit's own `stall_o`
handles pipeline coordination.

**Commit**: `2c785f0`

---

## 2. CSR Invalid False Positive for SYSTEM Instructions

**Symptom**: OpenSBI printed "system_opcode_insn: Invalid opcode for CSR
read/write instruction" and hung. The kernel's first `wfi` or `sfence.vma`
instruction in S-mode was being trapped as an illegal CSR access.

**Root Cause**: The `csr_active` signal in `csr_unit.sv` matched the SYSTEM
opcode enum value (`csr_cmd_i != NO_CSR_OP`), which included `ecall`,
`ebreak`, `mret`, `sret`, `wfi`, and `sfence.vma` — none of which are CSR
operations. When one of these instructions reached the IE stage with an
unrecognized CSR address, the `csr_invalid` flag fired incorrectly.

**Fix**: Changed `csr_active` to only match actual CSR read/write operations:
`csr_cmd_i == WRITE_CSR || csr_cmd_i == SET_CSR || csr_cmd_i == CLEAR_CSR`.

**Commit**: `1ecee7c`

---

## 3. Missing CSRs: mhartid, mstatush, mvendorid, marchid, mimpid

**Symptom**: OpenSBI hung at `_start_hang` during early init. Traced to an
illegal instruction trap when reading `mhartid` (CSR 0xF14).

**Root Cause**: These CSRs were in the `csr_reg_e` enum but not in the CSR
read mux (`csr_value_o` case statement). Any read returned the default case
which triggered `csr_invalid`.

**Fix**: Added read cases for `MHARTID` (returns 0), `MSTATUSH` (returns 0,
RV32 little-endian), `MVENDORID`, `MARCHID`, `MIMPID` (all return 0).

**Commit**: `b6c9d4f`

---

## 4. Post-trap Stale NOP Injection

**Symptom**: OpenSBI's `_trap_handler` code used `auipc` as its first
instruction to compute the trap handler's address. This instruction was being
NOP'd, causing `mtvec` to be loaded with a garbage address (the global
pointer value from the previous `la gp, __global_pointer$`).

**Root Cause**: Two related bugs:

1. **`post_trap` persisted too long**: The `post_trap_o` flag was gated by
   `!if_id_stall_o`, meaning it stayed high as long as the pipeline was
   stalled. After a trap, `refetch_after_trap` held `if_id_stall=1` for one
   extra cycle, keeping `post_trap` set when the handler's first instruction
   arrived in ID.

2. **`stale_id` NOP injection**: The ID/IE register wall replaced the
   control bus with `CTRL_BUS_NOP()` when `stale_id` was set. This was
   intended to kill the leftover pre-trap instruction, but it also killed
   the handler's first instruction (which arrived while `stale_id` was
   still set due to bug #1).

**Fix**:
- `post_trap` clears unconditionally after 1 cycle (not gated by stall).
- Removed `stale_id ? CTRL_BUS_NOP() : ctrl_bus_if_id` from the IE reg wall.
  The IE flush on `interrupt_valid` already handles the leftover instruction.

**Commit**: `b6c9d4f`

---

## 5. PLIC Multiple Critical Bugs (Pre-Linux)

**Symptom**: The original PLIC had 10+ issues found during code review.

**Root Causes**:
- Non-compliant register map (4 registers vs spec's full layout)
- Gateway FSM unconditional IDLE→INT_DETECTED transition
- Comparator tie-breaking logic reversed (selected highest ID instead of lowest)
- Claim/complete via combinational pulse signals instead of memory-mapped registers
- Source count mismatch (6 declared, wrong concatenation)
- Reset polarity confusion (`resetn_i` used as active-high)

**Fix**: Complete rewrite as `plic_rv.sv` with spec-compliant register map
(priority, pending, enable, threshold, claim/complete), proper memory-mapped
claim/complete, and correct gateway locking. Removed pulse-based
`plic_claim_o`/`plic_complete_o` from `privilege_unit.sv` and `core_top.sv`.

**Commit**: `3131a58`

---

## 6. CLINT/PLIC Read Data Returns Zero

**Symptom**: CLINT test showed `mtime` reads as 0 via MMIO, even though
the TIME CSR (which reads the same counter) returned correct values. Same
issue for `mtimecmp` and PLIC registers.

**Root Cause**: The `periph_bridge` uses registered chip-selects (`sel_r`)
for the read data mux — it latches which peripheral was selected, then
samples the read data ONE cycle later. But the CLINT/PLIC read outputs
were combinational and gated by `chipselect_i && read_i`. By the time
`sel_r` selected the CLINT output (next cycle), `read_i` was no longer
active, so `readdata_o` returned 0.

**Fix**: Changed CLINT and PLIC read outputs to registered (`always_ff`):
capture the read value on the request cycle, hold it stable for the
periph_bridge to sample on the next cycle.

**Commit**: `0917aff`

---

## 7. TIME/TIMEH CSRs Return Zero

**Symptom**: Linux kernel hung in `check_unaligned_access` function inside
a `while ((now = jiffies) == start_jiffies) cpu_relax();` spin loop. The
loop timeout used `rdtime`/`rdtimeh` which returned 0 forever.

**Root Cause**: The `TIME` CSR (0xC01) and `TIMEH` (0xC81) in `csr_unit.sv`
were hardcoded to return 0. Per RISC-V spec, these CSRs should shadow the
CLINT's `mtime` counter, providing S/U-mode access to the real-time clock.

**Fix**: Added `mtime_i[63:0]` input to `csr_unit.sv`, wired from the CLINT
module through `core_top` and `soc_top`. `TIME` returns `mtime_i[31:0]`,
`TIMEH` returns `mtime_i[63:32]`.

**Commit**: `0917aff`

---

## 8. No Hardware Misaligned Load/Store Support

**Symptom**: Linux kernel boot was extremely slow — millions of traps to
M-mode (OpenSBI) for misaligned store emulation. The kernel's `memcpy` and
`copy_to_user` functions used word stores to unaligned addresses, each one
trapping. After fixing TIME CSRs, the kernel got stuck in
`check_unaligned_access` which benchmarks misaligned access speed.

**Root Cause**: The core had no hardware support for misaligned HALF/WORD
loads/stores. Any misaligned access triggered an exception (cause 4 for
loads, cause 6 for stores), which was delegated to S-mode → trapped to
M-mode → OpenSBI emulated byte-by-byte → returned. Each emulation took
~20 cycles overhead.

**Fix**: Rewrote `core2avl.sv` (the load/store unit) with an FSM that
splits misaligned accesses into two aligned bus transactions:
- Detect misalignment from address LSBs and access width
- First transaction: aligned portion with correct byte enables
- Second transaction: remaining bytes at next word address
- Combine results for loads, split data for stores
- `misalign_stall_o` freezes IE stage during the 2-cycle operation
- AMO misalignment still traps (RV spec requires aligned AMOs)

Disabled misalign_load/misalign_store exception in `interrupt_ctrl.sv`.

**Commit**: `0917aff`

---

## 9. Kernel Stuck in Unaligned Access Check Spin Loop

**Symptom**: Even with hardware misaligned support and TIME CSR working,
the kernel hung in `check_unaligned_access` at a spin loop waiting for a
memory value to change.

**Root Cause**: The kernel v6.6 `check_unaligned_access` function benchmarks
misaligned access performance by copying data and timing with `rdtime`. It
uses a spin loop `while (jiffies == start_jiffies)` that waits for a jiffies
tick. On a single-hart system, a secondary polling loop
`while (a5 == s8) { div; pause; }` spins forever because no other hart
modifies the polled memory location.

**Fix**: Patched the kernel source to disable the unaligned access check:
```c
// arch_initcall(check_unaligned_access_boot_cpu);  // disabled for ntiny
```
This is safe because the hardware now handles misaligned accesses and the
kernel doesn't need to measure their speed.

**Commit**: Not committed (kernel source patch, external to ntiny repo)

---

## 10. UART TX Busy-Wait Stalls Simulation

**Symptom**: OpenSBI printed its banner but then the simulation appeared to
hang. The core was stuck polling the UART TX status register.

**Root Cause**: The OpenSBI platform's `ntiny_uart_putc()` polled the TXFULL
bit in the UART status register: `while (readl(UART_STATUS) & TXFULL)`.
The UART DPI module serializes characters at 115200 baud (one bit per
~434 cycles at 50MHz). Each character took ~4340 cycles to transmit, and
the TX FIFO filled immediately since OpenSBI prints ~2KB of banner text.

**Fix**: Removed the TXFULL polling from `ntiny_uart_putc` — just write
directly to the TX register. The UART DPI captures every write. For real
hardware, the polling should be re-enabled (or use a TX FIFO).

**Commit**: Not separately committed (part of platform.c iterations)

---

## 11. UART DPI vs Testbench Fast Console Conflict

**Symptom**: `uart.log` contained garbled/duplicate output — the UART DPI
and the testbench fast console monitor both wrote to `uart.log`.

**Root Cause**: Two independent mechanisms captured UART output:
1. UART DPI (`uartdpi.c`): opened `uart.log` and wrote characters received
   via bit-by-bit serial protocol (slow, but accurate)
2. Testbench fast console (`tb_soc_top.v`): snooped bus writes to UART TX
   register (instant, but could miss characters)

Both opened `uart.log` for writing, causing conflicts.

**Fix**: Disabled the UART DPI file logging (`obj->logfile = NULL`). The
testbench fast console is the primary output mechanism for simulation.

**Commit**: `0917aff`

---

## 12. No SBI Console Output from Kernel

**Symptom**: OpenSBI banner printed, kernel reached userspace (confirmed by
PC samples showing U-mode with user SATP), but no kernel boot messages.

**Root Cause**: The kernel config was missing the SBI console drivers:
- `CONFIG_HVC_RISCV_SBI` — the HVC (Hypervisor Virtual Console) driver for SBI
- `CONFIG_RISCV_SBI_V01` — legacy SBI v0.1 console putchar/getchar
- `CONFIG_SERIAL_EARLYCON_RISCV_SBI` — early console via SBI before full init

Without these, the kernel had no way to output text via the SBI ecall path.

**Fix**: Enabled all three config options and rebuilt the kernel.

**Commit**: `acc7a09`

---

## Summary Table

| # | Bug | Severity | Where | Root Cause Category |
|---|-----|----------|-------|-------------------|
| 1 | AMO flush | Critical | core_top | Pipeline hazard logic |
| 2 | CSR invalid | Critical | csr_unit | Overly broad condition |
| 3 | Missing CSRs | Critical | csr_unit | Incomplete implementation |
| 4 | Post-trap NOP | Critical | hazard_unit, core_top | Stall timing |
| 5 | PLIC bugs | Critical | plic.v | Design flaws (10+ issues) |
| 6 | CLINT/PLIC reads | Critical | clint.sv, plic_rv.sv | Bus timing mismatch |
| 7 | TIME CSR zero | Critical | csr_unit | Missing HW wiring |
| 8 | No misaligned HW | Major | core2avl, interrupt_ctrl | Missing feature |
| 9 | Kernel spin loop | Major | Linux kernel | Single-hart edge case |
| 10 | UART TX stall | Major | platform.c | Sim vs HW mismatch |
| 11 | UART log conflict | Minor | uartdpi.c, tb_soc_top.v | Dual writers |
| 12 | No kernel console | Config | Linux .config | Missing drivers |
