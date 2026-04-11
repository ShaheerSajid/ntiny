# Bugs Found and Fixed During ntiny Development

Every significant bug encountered during ntiny core development, MMU bring-up,
and Linux boot, with root cause analysis and fix details. Ordered chronologically.

---

## Part A: Pre-Linux Bugs (MMU, FPU, Core Refactor)

---

## 0a. FPU Flag Accumulation During Multi-Cycle Operations

**Symptom**: Spurious FPU exception flags appearing in `fflags` CSR after
multi-cycle FPU operations (divide, sqrt).

**Root Cause**: `float_valid_i` was not gated by `!alu_stall`, so during
multi-cycle FPU operations the intermediate/stale flag outputs leaked into
the CSR accumulator on every cycle the FPU was busy.

**Fix**: Gate `float_valid_i` with `!alu_stall` so flags are only captured
once when the FPU completes.

**Commit**: `31a0261`

---

## 0b. FP f2i Conversion Clamping and Inexact Flag

**Symptom**: RISCOF F-extension `fcvt.w.s` / `fcvt.wu.s` tests failed for
NaN, overflow, and negative inputs.

**Root Cause**: `fp_f2i.sv` (PakFPU) had incorrect NaN/overflow/negative
clamping results and was missing the NX (inexact) flag on non-NV paths.

**Fix**: Corrected clamping values and added NX flag generation.

**Commit**: `31a0261`

---

## 0c. RS2 Forwarding Loss During DTLB Stall

**Symptom**: Store instructions wrote `0x00000000` instead of the correct rs2
value when a DTLB miss occurred. Broke `vm_A_and_D` RISCOF tests.

**Root Cause**: During a store DTLB miss, the IE stage stalls while the
forwarding sources (IMEM/IWB stages) continue advancing. When the rs2
producer completed IWB while the store was stuck in IE, the `FORWARD_IWB`
signal fired correctly but `ie_stall=1` prevented the IE register from
latching the forwarded value. By the time the DTLB resolved and the store
fired, the forwarding source had left the pipeline and `rs2_forwarded_ie`
held its original stale zero.

**Fix**: Added an else branch to the IE pipeline register `always_ff` that
captures forwarded operand values (rs1/rs2/rs3) during a stall, before the
forwarding source leaves the pipeline.

**Commit**: `d516da0`

---

## 0d. Sv32 MMU: SUM Bit Applied to Instruction Fetch

**Symptom**: `vm_sum_set_S_mode` RISCOF test failed — S-mode instruction
fetch from U-pages succeeded when it should have faulted.

**Root Cause**: The ITLB permission check used the SUM (Supervisor User
Memory access) bit for instruction fetches. Per RISC-V spec §3.1.6.3,
SUM only applies to data accesses. S-mode instruction fetch from U-pages
must ALWAYS fault, regardless of SUM.

**Fix**: Hardcoded the ITLB instruction permission check to reject U-pages
in S-mode unconditionally (no SUM check for instruction side).

**Commit**: `8721154`

---

## 0e. PTW Address Width Bug

**Symptom**: Page table walks produced wrong physical addresses for L1 PDE
lookups.

**Root Cause**: `ptw_l1_addr` computation used wrong bit width for
`satp_ppn` — needed `[19:0]` with 12-bit left shift, was using incorrect
width causing address truncation.

**Fix**: Corrected `ptw_l1_addr = {satp_ppn[19:0], 12'b0} + {20'b0, vaddr[31:22], 2'b00}`.

**Commit**: `8721154`

---

## 0f. Spurious Page Faults in Bare Mode

**Symptom**: Page fault exceptions fired when MMU was disabled (satp.MODE=0).

**Root Cause**: `i_fault_o` and `d_fault_o` from the MMU were not gated by
the translation-active signals (`i_translate`, `d_translate`). When the
MMU was disabled, internal fault logic could still produce spurious outputs.

**Fix**: Gated fault outputs with their respective translate-active signals.

**Commit**: `8721154`

---

## 0g. PTW Stale rvalid from L1 Read Corrupting L0

**Symptom**: L0 PTE read returned the L1 PDE value instead of the actual
L0 entry.

**Root Cause**: The PTW transitioned directly from L1 read to L0 read. The
L1 `rvalid` response arrived on the same cycle the L0 request was issued,
and the stale L1 data was captured as the L0 result.

**Fix**: Added `PTW_L0_WAIT` state — a dead cycle between L1 completion and
L0 request to drain the stale `rvalid`.

**Commit**: `8721154`

---

## 0h. c_controller SRET Bug (Used MEPC Instead of SEPC)

**Symptom**: `SRET` instruction returned to `mepc` instead of `sepc`.

**Root Cause**: The old c_controller had a duplicated PC source mux with
8 address inputs. The `RET` case always used `epc` (MEPC) regardless of
whether the instruction was MRET or SRET.

**Fix**: Refactored c_controller to use 3 signals (`redirect_i`,
`redirect_addr_i`, `interrupt_i`) instead of duplicating the PC mux.
The redirect address comes from core_top's `pc_in` which already
distinguishes MRET (uses mepc) vs SRET (uses sepc).

**Commit**: `3f01f53`

---

## 0i. mtvec Cleared to Zero on Boot

**Symptom**: Any exception during startup (including UART init) jumped to
address 0 and crashed silently.

**Root Cause**: `init.c` startup code had `csrrw x0, mtvec, x0` which
wrote zero to mtvec. If any exception fired before main() set mtvec
properly, the handler address was 0.

**Fix**: Changed startup to set mtvec to the vector table (`_init`) in
vectored mode: `la t0, _init; ori t0, t0, 1; csrw mtvec, t0`.
Also added FPU enable (`mstatus.FS = Initial`).

**Commit**: `104fc7e`

---

## Part B: Linux Boot Bugs

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

## 13. SRET Privilege Drop Mid-DTLB-Walk (csr branch hazard test)

**Symptom**: Directed `sret_itlb_miss.S` test (S→U SRET preceded by a store
that DTLB-misses) crashed with a store page fault on a kernel-only-mapped
page (PTE `0x201000eb`, R=W=0=X=1, U=0). DUT trapped at the wrong PC with
`mcause=15` (store page fault).

**Root Cause**: `privilege_unit.sv` `ret_fire`/`sret_fire` were not gated by
`!ie_stall`. When SRET decoded in ID while a preceding store was still
executing in IE with a pending DTLB walk, SRET fired its CSR side effects
(privilege drop S→U) on the same cycle. The store's PTW completed several
cycles later and re-checked permissions against the *current* (now U-mode)
`d_eff_priv`, which fails for U=0 pages → spurious page fault from kernel.

Additionally, `ret_side_effects_done_o` was latched whenever
`ret_valid_o && !csr_ret_hazard`, even if `ret_fire` itself was gated off.
This caused `mmu_priv_o` to flip back to `priv_level` (post-SRET U-mode)
mid-walk, masking the gating fix.

**Fix**: `design/core/privilege_unit/src/privilege_unit.sv`
- Added `ie_stall_i` input
- Gated `ret_fire_o` and `sret_fire_o` by `!ie_stall_i`
- Changed `ret_side_effects_done_o` latch to require `(ret_fire_o ||
  sret_fire_o)`, so it only marks "done" when the side effects actually fire

**Verified**: directed test passes; RISCOF still 191/198.

---

## 14. Trap-Entry Handler[0] Skipped (Linux deadlock at c0003076)

**Symptom**: Linux booted to `Run /init as init process` then PC stuck at
`c0002f48..c0002f64` forever (kernel sample showed `c0003076` because
the PC sampler is 1M-cycles coarse). Recursive trap loop on `sw ra, 4(sp)`
in `handle_exception`'s save-context prologue with `sp=0x9c781ab0` (a
*user* address). The kernel's per-cpu `TI_KERNEL_SP` slot at offset 8 was
corrupted with the user sp.

**Root Cause** (resolved 2026-04-06 after weeks of misdiagnosis): The
handler's first instruction was being **silently skipped** by the IF stage
on traps that fired while the user was running smoothly.

`hazard_unit.sv` line 151 (before fix):
```
refetch_after_trap_o <= interrupt_valid_i & if_id_stall_o;
```

`refetch_after_trap` is what tells `core_top.sv` to use `pc_out` (= the
trap target) for `i_vaddr` instead of `pc_in` (= `pc_out + 4`). Without it
asserting after a trap, the very first fetch goes to `handler_addr + 4`
and `handler_addr` itself is never fetched.

The gate `& if_id_stall_o` meant this only fired when a pre-existing stall
was active when the trap fired. For traps from the kernel (which often
have hazard stalls in flight) it worked. For traps from a smoothly-running
user process (no stall), `if_id_stall=0`, the refetch never happened, and
**handler[0] was skipped on every user-mode trap**.

For Linux's `handle_exception` at `c0002f48`:
- `c0002f48: csrrw tp, sscratch, tp` ← **SKIPPED**
- `c0002f4c: bnez tp, _save_context` ← first executed instruction
- bnez sees stale `tp = 0` (user's value, never swapped) → branch NOT taken
- Falls through to `_restore_kernel_tpsp` → `sw sp, 8(tp)` corrupts
  `TI_KERNEL_SP` with the user sp
- Next trap loads the corrupted user-sp and stores via it → store fault
  → recursive trap → infinite loop

**Why this looked like an SRET bug**: The deadlock only manifested after
SRET to user (init), so the symptom pointed at the SRET path. Five
previous fix attempts patched the c_controller and SRET handling — none
worked because the actual bug was one cycle earlier in the IF stage.

**How it was found**: Captured a 1M-cycle VCD around the PC sample of the
deadlock. Walked through `instruction_pipe`, `i_vaddr`, `i_paddr` cycle by
cycle and saw that `i_vaddr` advanced from `c0002f48` to `c0002f4c` on the
cycle after the trap, before the fetch for `c0002f48` ever issued.
`i_paddr` skipped from `0x00000f4c` (bogus during ITLB miss) directly to
`0x80402f4c` — never landing on `0x80402f48`.

**Fix**: `design/core/hazard_unit/src/hazard_unit.sv`
```diff
- refetch_after_trap_o <= interrupt_valid_i & if_id_stall_o;
+ refetch_after_trap_o <= interrupt_valid_i;
```

**Verified**: RISCOF still 191/198 (no regressions). Linux re-run VCD shows
csrrw is now correctly decoded at trap entry (`instruction_pipe = 0x14021273`
appearing on every trap, matching `interrupt_valid` and `refetch_after_trap`
pulse counts) and the recursive trap loop on `c0002f64` is gone. Kernel
successfully reaches U-mode (priv 01 → 00 transition).

**Next bug exposed**: After SRET to U-mode, `c_controller`'s `apc` is frozen
at `c0003072` (the SRET instruction's address). Privilege drops to U-mode
(SRET CSR side-effects committed) but the IF stage never fetches the user
instruction at sepc — see bug #15.

---

## 15. c_controller apc Not Latching sepc on SRET-to-U-with-ITLB-Stall

**Symptom**: After bug #14 fix, Linux reaches U-mode successfully, but the
c_controller's `apc_out` (= `pc_id`) freezes at `0xc0003072` (the SRET
instruction's address) for the rest of the trace. `instruction_pipe` shows
no further transitions. CPU effectively halted in U-mode.

**Root Cause**: The c_controller's `program_counter` `stall_i` only bypassed
for `interrupt_i`, not for `xRET`. When SRET fires while ITLB misses for the
U-mode sepc target, the apc held at the SRET instruction's address instead
of latching sepc. The same problem applied to the main `pc_out` register in
core_top.sv, which was stalled by `if_id_stall | c_stall` and never
captured the SRET target.

This is the ORIGINAL "SRET PC latch bug" we documented but never fixed —
all five previous fix attempts were for separate issues (which all turned
out to be bugs #13 and #14).

**Fix**:
- `design/core/core_top/src/core_top.sv`: derive a one-cycle
  `ret_pulse = ret_fire | sret_fire` (now properly gated by `!ie_stall` from
  bug #13's fix) and bypass *both* the main `pc_out` register stall and the
  c_controller's `apc` stall on `(interrupt_valid | ret_pulse)`.
- `design/core/c_ext/src/c_controller.sv`: add a `ret_pulse_i` input port
  and OR it into the existing `interrupt_i` PC bypass term.

The fix is intentionally minimal: it only bypasses the program counter
register, not the alignment FSM. The earlier-attempted aggressive variants
(forcing the FSM into ALIGN, clearing `ins_buffer` on `ret_pulse`) broke
OpenSBI's warm-M-mode SRET path by causing duplicate fetches and stale
ins_buffer decodes — see commit history.

**Verified**: Linux SRETs cleanly to user mode. RISCOF still 191/198.

---

## 16. trap_sequencer SRET_WAIT Suppresses Legitimate User-Mode Page Fault

**Symptom**: After bug #15 fix, the first user-mode instruction at sepc
(typically inside ld-linux's `_start` or busybox `_init`) takes a legitimate
ITLB miss, the PTW resolves it, and the resulting i-fault for the cold
mapping never reaches the trap unit. The fetch is silently swallowed and
the kernel deadlocks at the same `c_controller.apc` value.

**Root Cause**: `trap_sequencer.sv` uses an `IDLE → SRET_WAIT → IDLE` FSM to
suppress *stale* `ifault_i` pulses that arrive in the same window as an
SRET (e.g. an in-flight fetch that pre-dates the SRET commit). The original
design exited `SRET_WAIT` when `branch_taken_i | ret_valid_i` cleared, which
*permanently* held off ifault delivery if the PTW for the new mapping took
longer than the SRET window — i.e. it could not distinguish "stale fault
from before SRET" from "real fault for the SRET target itself".

In addition, the `clear_ifault` term in IDLE included a `sret_start =
ret_valid_i && sret_i` condition that fired *before* the SRET CSR side
effects committed, swallowing the very i-fault we wanted to deliver.

**Fix**: `design/core/trap_sequencer/src/trap_sequencer.sv`
- Added a new `ret_side_effects_done_i` input (driven by privilege_unit's
  `ret_side_effects_done_o` from bug #13) so the FSM has a precise marker
  for "SRET has actually committed".
- Changed the `SRET_WAIT → IDLE` exit condition to fire on
  `ret_side_effects_done_i`, not on the redirect signals dropping. This
  releases the suppression at exactly the right cycle.
- Defined `wire sret_pre_commit = ret_valid_i && sret_i &&
  !ret_side_effects_done_i;` and gated all three `clear_ifault` sources by
  `!ret_side_effects_done_i`, so the legitimate post-SRET i-fault is no
  longer suppressed.

Wired `ret_side_effects_done` from privilege_unit to trap_sequencer in
`design/core/core_top/src/core_top.sv`.

**Verified**: Kernel reaches `handle_exception` for the first user-mode
ITLB miss (instead of deadlocking). This exposes bug #18.

---

## 17. privilege_unit `ie_stall_i` Port Unwired in core_top

**Symptom**: Bug #13 added an `ie_stall_i` port to `privilege_unit.sv` and
gated `ret_fire_o`/`sret_fire_o` by it. The directed test passed because the
test happened to run with `ie_stall=0` for the relevant cycles. But the
full Linux build still showed bug #13's symptom (SRET committing during a
DTLB walk) intermittently.

**Root Cause**: The `ie_stall_i` port was declared on the privilege_unit
module but the corresponding wire was *not connected* in the
`privilege_unit_inst` instantiation in `core_top.sv`. The Verilator default
for an unconnected input is 0, so `!ie_stall_i` was always true and the
gate was a no-op.

**Fix**: `design/core/core_top/src/core_top.sv` — add `.ie_stall_i (ie_stall)`
to the `privilege_unit_inst` port map.

This is a "found-it-by-grep" bug: the only reason the test passed for bug #13
was that the test never ran in IE-stall conditions. Lesson: every new port
on a refactored module needs an explicit grep in core_top to confirm it's
wired.

---

## 18. IE Register Wall Latches Stale Decode at Trap Entry (Bug #14 Reborn)

**Symptom**: After bugs #13–17 are fixed, Linux still deadlocks on the
first user-mode trap. PC enters `handle_exception` at `c000240c`,
`tp` doesn't get swapped with sscratch, `bnez tp` falls through to
`_restore_kernel_tpsp`, `sw sp, 8(tp)` overwrites `TI_KERNEL_SP` with the
user `sp`, and the next trap recursively explodes — same surface symptom as
bug #14, but for a different reason.

**Root Cause** (confirmed via `no_c.vcd` cycle 158868725): When
`interrupt_valid` fires, the trap-target redirect bypasses both `pc_out`
and the c_controller's `apc` to `c000240c` — but `imem_port` is a
1-cycle-latency interface, so the *fetch* for `c000240c` hasn't returned
yet on the same cycle the redirect commits. The c_controller's
`instruction_pipe` is computed combinationally from `imem_port.rdata`, so
on that cycle it decodes whatever stale data was sitting on the bus from
the pre-trap fetch (`2cf6eee3` etc, which decodes to `csr_op = NO_CSR_OP`).

When `if_id_stall` drops a few cycles later, the IE register wall latches
that stale (NOP) `ctrl_bus_if_id`. The **csrrw at handler[0] is silently
dropped**, even though the c_controller eventually decodes it correctly
once the real fetch returns — by then the IE wall has already moved past it.

This is **bug #14 reborn at the IE-wall layer**. Bug #14 was "fetch never
issued for handler[0]" (handler_addr+4 was first fetch); bug #18 is "fetch
issued at the right address but data hasn't returned yet when the IE wall
latches the combinational decode."

**Attempted bandaid (FAILED 2026-04-07)**: Added a 1-bit
`imem_pending_post_trap` register (set on `interrupt_valid`, clear on
`imem_port.rvalid`), wired to `hazard_unit_inst.icache_stall_i`. The
intent was to hold `if_id_stall` across the trap-target round trip so
the IE wall latches the real csrrw. With-MMU Linux re-run produced the
*same* recursive trap loop:
```
PC: c000240c → c000241c → c0002428 → c000240c → ...
```

**Why the bandaid was wrong**: ntiny has **no IF/ID pipeline register** for
the instruction word. The imem SRAM's output register is absorbed into the
pipeline as the IF/ID stage register, so `imem_port.rdata` feeds the
c_controller and decoder *combinationally*. Stalling `if_id_stall` only
delays the IE register wall — it does NOT hold the instruction word.
Meanwhile rdata changes underneath each cycle as the SRAM presents new
data. By the time the stall releases, rdata is whatever the bus happens
to be carrying — not the trap-target instruction.

The bandaid was reverted. The proper fix requires architectural changes:
either adding a real IF/ID register (paying +1 branch penalty), adding a
fetch buffer that decouples imem from the c_controller, or implementing
the Fetch Issue Unit FSM with explicit fetch-in-flight tracking that gates
the c_controller's clock enable (not just the IE register wall). See
`docs/fetch_revamp_plan.md` for the full design.

**Status**: OPEN — fix deferred to the fetch/c_controller revamp.

---

## 19. Duplicate fb_push During Deferred-Redirect (sp drift in setup_arch)

**Symptom**: Linux runs through ~450 SBI ecalls during early boot,
then `setup_arch`'s epilogue reads `ra` from a local-variable spill
slot, jumps to a garbage VA `0xc7b06c40`, and traps with "Unable to
handle kernel paging request". sp had drifted by 64 bytes per
deferred-redirect during boot (e.g., once per `_printk` call).

**Root Cause**: When `arb_redirect_valid & mmu_i_stall`
(`redirect_deferred`), the producer latches `pending_target_q` and
holds `pc_out` so `i_vaddr` stays at the deferred target. But there
was **no gate against duplicate issue** — `imem_port.req` fired every
cycle that `~fetch_producer_stall`. Each cycle's identical fetch
returned a separate rvalid, both pushed identical entries into the
fetch_buffer, the compressed_aligner emitted the same compressed
instructions twice, and IE re-ran them with `rs1` *forwarded* from the
first commit (so `c.addi16sp sp,-64` decremented sp twice, etc.).

**Fix** (Phase 4.13, commit `3d8c004`): vaddr-based fb_push dedup.
Track the previous successful push's vaddr (`last_pushed_vaddr_q`) and
drop a new push that matches it. Reset on `fetch_flush` so post-redirect
re-pushes are not falsely dropped.

**Why earlier producer-side FSM attempts (FSM v1/v2/Phase 4.11/4.12)
all deadlocked**: Phase 4.13b below.

---

## 20. Straddled-Instruction Deadlock at Half-Aligned Deferred Targets

**Symptom**: After Phase 4.13 (fb_push dedup), Linux hangs in
`paging_init` at `c04046f6` (`lui a0, 0x9dbfe`) — the instruction
right after `local_flush_tlb_page`'s `sfence.vma`. PC sampler shows
`pc_out` stuck at the same address for tens of millions of cycles.

**Root Cause**: `c04046f6` is a 4-byte instruction at a half-aligned
VA. It straddles two 4-byte icache words: bytes from word `c04046f4`
+ bytes from word `c04046f8`. The `sfence.vma` flushes the ITLB; the
next fetch faults; `arb_redirect_valid & mmu_i_stall` fires
`redirect_deferred` with `pending_target_q = c04046f6`. Pending then
holds `pc_out = c04046f6` and drives `i_vaddr` from
`pending_target_q`, so the producer can only fetch the **first** word.
The second word never enters the buffer, the aligner can't assemble
the straddled instruction, `pc_ie` never reaches the target, pending
never clears.

**Fix** (Phase 4.13b, commit `3d8c004`): track whether the target's
first push has happened (`pending_first_push_done_q`). For
**half-aligned** pending targets *only*, release `pc_out` after the
first push so the producer can advance to fetch the next word.
Word-aligned targets keep the original behaviour (hold until
`pc_ie==target`) — that path is still needed by `vm_VA_all_ones`.

Also added: `pending_target_v_q` clears on non-deferred
`arb_redirect_valid` so an abandoned target can no longer block
subsequent fetches.

---

## 21. Post-xret Async-Interrupt mepc=0

**Symptom**: After Linux boots through `setup_arch` and into late
initcalls, kernel oops with `epc=0`, `cause=0xc` (S-mode insn page
fault). dump shows the prior trap had `cause=0x80000007` (M-mode
timer) with `epc=0` saved.

**Trace evidence** (cycle 10664685):
```
XRET @10664684 pc=8000052a priv=3 satp=80081880      ← mret to S-mode
TRAP @10664685 pc=c000501c cause=80000007 epc=00000000
XRET @10665010 pc=8000052a priv=3 satp=80081880      ← mret back to mepc=0
TRAP @10665016 pc=00000000 cause=0000000c epc=00000000  ← S-mode fetch fault @ 0
```

**Root Cause**: The cycle right after `wb_xret_fire`, both `pc_id_i`
and `pc_ie_i` are 0 — the pipeline is freshly starting to fetch the
post-xret target and no instruction has reached IE yet. Phase 4.10b's
fix `pc_for_async = (pc_id_i != 0) ? pc_id_i : pc_ie_i` had a hole
for this exact case: both are 0, so `pc_for_async = 0` and `mepc`
gets latched as 0. The M-mode handler returns to PC=0 and S-mode then
faults on the fetch.

**Fix** (Phase 4.13c, commit `0816f0f`): extend the fallback chain to
`pc_out_i` (which holds the xret target latched into program_counter
on the xret commit cycle):
```verilog
wire [31:0] pc_for_async = (pc_id_i != 32'h0) ? pc_id_i :
                           (pc_ie_i != 32'h0) ? pc_ie_i :
                                                pc_out_i;
```
`pc_out_i` was already plumbed into `interrupt_ctrl` as part of
Phase 4.10b ("for future use") — now consumed.

---

## 22. Kernel head.S Missing Early TASK_TI_KERNEL_SP Init

**Symptom**: Linux's first S-mode trap during early boot corrupts the
saved register frame. `_save_context` reads `lw sp, 8(tp)`
(TASK_TI_KERNEL_SP), gets a stale value (whatever happened to be at
`init_task->thread_info.kernel_sp`), and writes the trap frame on top
of the live kernel stack — clobbering saved regs.

**Root Cause**: Linux's normal context-switch path writes
`TASK_TI_KERNEL_SP` on every switch, but **before any switch ever
happens** (during early boot from start_kernel through setup_arch),
the slot was never initialized. Most cores never trip this because
they don't take an S-mode trap before `init_task`'s first
`switch_to()`. ntiny does (early SBI ecalls during bringup).

**Fix** (kernel patch in
`software/linux/patches/0001-ntiny-kernel-required.patch`):
```asm
# arch/riscv/kernel/head.S, after the second `addi sp, sp, -PT_SIZE_ON_STACK`
REG_S sp, TASK_TI_KERNEL_SP(tp)
```
6 lines including a comment. **The single most important kernel
patch**: without it, every other Linux fix is moot.

---

## 23. cpufeature.c check_unaligned_access Busy-Loops on jiffies

**Symptom**: After 23M cycles of progress through early boot Linux
hangs at `c0002b90..c0002b9c`, a 16-byte loop. Function:
`check_unaligned_access` (cpufeature.c). Loop:
```c
preempt_disable();
start_jiffies = jiffies;
while ((now = jiffies) == start_jiffies)
    cpu_relax();
```

**Root Cause**: At this `arch_initcall` stage on ntiny the SBI timer
chain doesn't service the kernel side predictably enough — the loop's
`READ_ONCE(jiffies)` never observes an update. The kernel makes
progress through other initcalls fine (timer IRQs *do* fire), so the
window is specific to this very early initcall. Under deep
investigation the root cause is one of:
1. SBI set_timer not yet armed at this initcall stage
2. STIP→sip→sstatus.SIE delivery race specific to this preempt_disable+pause loop
3. D-cache returning a stale `jiffies` line (less likely on a single-hart)

**Fix** (kernel patch — `cpufeature.c` 1-line disable):
```diff
-arch_initcall(check_unaligned_access_boot_cpu);
+//arch_initcall(check_unaligned_access_boot_cpu);
```
Loses the per-cpu unaligned-access-speed hwcap, which is only used by
`hwprobe(2)` syscall consumers. ntiny doesn't query it. **Workaround,
not root-cause fix.** Real fix path is in `docs/post_linux_roadmap.md`.

---

## 24. cpio Missing /dev/console Causes Init to Run with Closed FDs

**Symptom**: First time running with the mini initramfs, kernel reaches
`Run /init as init process`, then immediately panics with
`Kernel panic - not syncing: Attempted to kill init! exitcode=0x00000100`.
Just before that: `Warning: unable to open an initial console.`

**Root Cause**: The cpio archive was created from a directory tree
without root, so `/dev` ended up empty (no `/dev/console` device node).
The kernel runs `/init` with `fd 0/1/2` not connected, init's printf
goes nowhere, init tries `execve("/bin/sh")` which fails, init returns
1, kernel panics because init can never exit.

**Fix**: Use `usr/gen_init_cpio` (Linux source-tree host tool) with a
spec file that explicitly creates `/dev/console`:
```
dir  /dev      0755 0 0
nod  /dev/console 0600 0 0 c 5 1
file /init     /path/to/init 0755 0 0
```
gen_init_cpio can create device nodes from the spec without needing
root, unlike `cpio -i`. Also documented in
`software/linux/initramfs_src/cpio_list`.

---

## 25. CONFIG_INITRAMFS_COMPRESSION_GZIP Re-Gzips an Already-Uncompressed cpio

**Symptom**: After fixing #24 and switching to a 4MB busybox cpio, boot
spends ~30M cycles in `inflate_fast` (`c010cce4..c010cf38`) before
actually starting the rootfs. PC sampler shows `pc_out` confined to a
few hundred bytes for tens of millions of cycles.

**Root Cause**: `CONFIG_INITRAMFS_COMPRESSION_GZIP=y` is the default
for arm/x86/risc-v defconfigs. `usr/Makefile` re-gzips whatever
`CONFIG_INITRAMFS_SOURCE=` points at, even if it's already an
uncompressed `.cpio`. So even when we feed in raw bytes the kernel
embeds the gzipped form and decompresses it at boot.

**Fix**: Switch to `CONFIG_INITRAMFS_COMPRESSION_NONE=y` (commit
`daaf7b7`). The `usr/initramfs_inc_data` blob then matches the source
cpio bit-for-bit. Boot skips inflate entirely.

---

## 26. uartdpi Mirroring to stderr Garbles the Verilator Console

**Symptom**: Running `Vtb_soc_top` directly in a terminal produces
random-looking character soup like `nIexS otSeneBEice:tro'pbo0eeIuO`.
`uart.log` is clean, but the terminal where verilator runs is garbled.

**Root Cause**: `uartdpi.c::uartdpi_write()` did
`fputc(data, stderr)` for every byte that came out of the bit-by-bit
serializer, on top of forwarding it to the PTY. That stderr mirror
leaked the slow serialized stream into the terminal where Vtb_soc_top
runs (verilator inherits the user's stderr), interleaving with the
testbench's fast bus capture and producing per-character noise.

**Fix** (commit `d227741`): drop the `fputc(stderr)`. The clean copy
already lives in `uart.log` via the testbench's fast UART TX bus
monitor; the PTY is still available for interactive sessions via
`/dev/pts/N`. Recommended workflow:
```
# Terminal 1
./Vtb_soc_top --timeout 1000000000
# Terminal 2
tail -f uart.log
```

---

## Summary Table

### Pre-Linux (MMU, FPU, Core)

| # | Bug | Severity | Where | Root Cause Category |
|---|-----|----------|-------|-------------------|
| 0a | FPU flag leak | Medium | csr_unit | Missing stall gate |
| 0b | f2i clamping | Medium | fp_f2i.sv | Incorrect logic |
| 0c | rs2 forwarding loss | Critical | core_top IE reg wall | Stall vs forwarding race |
| 0d | SUM on insn fetch | Medium | mmu_sv32 | Spec misread |
| 0e | PTW address width | Critical | mmu_sv32 | Bit-width error |
| 0f | Bare-mode faults | Medium | mmu_sv32 | Missing gate |
| 0g | PTW L1→L0 stale data | Critical | mmu_sv32 | Pipeline timing |
| 0h | SRET uses MEPC | Critical | c_controller | Duplicated mux logic |
| 0i | mtvec cleared to 0 | Major | init.c | Boot code error |

### Linux Boot

| # | Bug | Severity | Where | Root Cause Category |
|---|-----|----------|-------|-------------------|
| 1 | AMO flush | Critical | core_top | Pipeline hazard loop |
| 2 | CSR invalid | Critical | csr_unit | Overly broad condition |
| 3 | Missing CSRs | Critical | csr_unit | Incomplete implementation |
| 4 | Post-trap NOP | Critical | hazard_unit, core_top | Stall timing |
| 5 | PLIC bugs (10+) | Critical | plic.v | Design flaws |
| 6 | CLINT/PLIC reads | Critical | clint.sv, plic_rv.sv | Bus timing mismatch |
| 7 | TIME CSR zero | Critical | csr_unit | Missing HW wiring |
| 8 | No misaligned HW | Major | core2avl, interrupt_ctrl | Missing feature |
| 9 | Kernel spin loop (SRET) | Major | Linux kernel | Single-hart edge case |
| 10 | UART TX stall | Major | platform.c | Sim vs HW mismatch |
| 11 | UART log conflict | Minor | uartdpi.c, tb_soc_top.v | Dual writers |
| 12 | No kernel console | Config | Linux .config | Missing drivers |
| 13 | SRET drops priv mid-DTLB walk | Critical | privilege_unit | Side-effect timing |
| 14 | Trap-entry handler[0] skipped | Critical | hazard_unit | refetch_after_trap gating |
| 15 | c_controller apc not latching sepc on SRET | Critical | c_controller, core_top | PC stall bypass missing for xRET |
| 16 | trap_seq SRET_WAIT suppresses real i-fault | Critical | trap_sequencer | FSM exit on wrong condition |
| 17 | privilege_unit ie_stall_i unwired | Critical | core_top | Port instantiation gap |
| 18 | IE wall latches stale decode at trap entry | Critical | core_top, hazard_unit | Combinational decode of in-flight fetch |
| 19 | Duplicate fb_push (sp drift in setup_arch) | Critical | core_top fetch path | Producer issues duplicate reqs while pc_out is held |
| 20 | Straddled-insn deadlock at half-aligned target | Critical | core_top pending logic | pc_out hold prevents 2nd word fetch |
| 21 | Post-xret async mepc=0 | Critical | interrupt_ctrl | pc_for_async fallback missed pc_out |
| 22 | head.S missing early kernel_sp init | Critical | Linux kernel | Untested code path on slow cores |
| 23 | check_unaligned_access spin (jiffies) | Major | Linux kernel | initcall ordering / SBI timer race |
| 24 | cpio missing /dev/console | Major | initramfs | mknod-needs-root limitation |
| 25 | INITRAMFS_COMPRESSION_GZIP re-gzips | Major | Linux kernel build | Misleading defconfig default |
| 26 | uartdpi stderr mirror garbles terminal | Minor | uartdpi.c | Dual writers (stderr + uart.log) |

**Total: 35 bugs found and fixed across 5 development phases.**
**Linux fully boots to busybox userspace as of fetch-revamp Phase 4.13c.**
