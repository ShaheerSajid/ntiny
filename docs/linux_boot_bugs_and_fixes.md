# ntiny Bug Catalog

39 bugs found and fixed during core development, MMU bring-up, and Linux boot.

## Pre-Linux (MMU, FPU, Core Refactor)

| # | Bug | Where | Fix |
|---|-----|-------|-----|
| 0a | FPU flag leak during multi-cycle ops | csr_unit | Gate float_valid by !alu_stall |
| 0b | f2i conversion clamping + inexact flag | fp_f2i | Fix clamping logic |
| 0c | rs2 forwarding loss during DTLB stall | core_top IE wall | Capture forwarded value during stall |
| 0d | SUM applied to insn fetch (spec: data only) | mmu_sv32 | Remove SUM check from i-side |
| 0e | PTW address width bug | mmu_sv32 | Fix bit-width |
| 0f | Spurious page faults in bare mode | mmu_sv32 | Gate fault by translate enable |
| 0g | PTW L1→L0 stale rvalid corrupts PTE | mmu_sv32 | Add L0_WAIT state |
| 0h | SRET uses MEPC instead of SEPC | c_controller | Fix mux select |
| 0i | mtvec cleared to zero on boot | init.c | Set mtvec in startup |

## Linux Boot (Bugs 1–18, pre-fetch-revamp)

| # | Bug | Where | Fix |
|---|-----|-------|-----|
| 1 | AMO flush combinational loop | core_top | Break loop with insert_bubble gate |
| 2 | CSR invalid false positive for SYSTEM insns | csr_unit | Narrow condition |
| 3 | Missing CSRs (mhartid, mstatush, etc.) | csr_unit | Implement |
| 4 | Post-trap stale NOP injection | hazard_unit | Fix stall timing |
| 5 | PLIC 10+ critical bugs | plic.v | Rewrite |
| 6 | CLINT/PLIC read data returns zero | clint, plic | Fix bus timing |
| 7 | TIME/TIMEH CSRs return zero | csr_unit | Wire to CLINT |
| 8 | No hardware misaligned load/store | core2avl | Implement split FSM |
| 9 | Kernel stuck in unaligned access check | kernel | Disable initcall |
| 10 | UART TX busy-wait stalls sim | platform.c | Remove polling |
| 11 | UART DPI vs TB fast console conflict | uartdpi, tb | Remove stderr mirror |
| 12 | No SBI console output from kernel | .config | Enable HVC_RISCV_SBI + RISCV_SBI_V01 |
| 13 | SRET drops priv mid-DTLB walk | privilege_unit | Latch priv at walk start |
| 14 | Trap-entry handler[0] skipped | hazard_unit | Fix refetch_after_trap gating |
| 15 | c_controller apc not latching sepc on SRET | c_controller | Add stall bypass for xRET |
| 16 | trap_seq SRET_WAIT suppresses real i-fault | trap_sequencer | Fix FSM exit condition |
| 17 | privilege_unit ie_stall_i unwired | core_top | Connect port |
| 18 | IE wall latches stale decode at trap entry | core_top | NOP injection on bubble |

## Fetch Revamp (Phase 4.13 series, Bugs 19–26)

| # | Bug | Where | Fix | Commit |
|---|-----|-------|-----|--------|
| 19 | Duplicate fb_push → sp drift in setup_arch | core_top fetch | vaddr-based fb_push dedup | `3d8c004` |
| 20 | Straddled-insn deadlock at half-aligned target | core_top pending | Release pc_out after first push for half-aligned | `3d8c004` |
| 21 | Post-xret async interrupt mepc=0 | interrupt_ctrl | pc_for_async fallback to pc_out | `0816f0f` |
| 22 | head.S missing early kernel_sp init | kernel patch | `REG_S sp, TASK_TI_KERNEL_SP(tp)` | kernel |
| 23 | check_unaligned_access busy-loops on jiffies | kernel patch | Disable initcall | kernel |
| 24 | cpio missing /dev/console | initramfs | Rebuild with gen_init_cpio | `3792693` |
| 25 | INITRAMFS_COMPRESSION re-gzips uncompressed cpio | defconfig | CONFIG_INITRAMFS_COMPRESSION_NONE=y | `daaf7b7` |
| 26 | uartdpi stderr mirror garbles terminal | uartdpi.c | Remove fputc(stderr) | `d227741` |

## ITLB/Trap Bugs (Bugs 27–30, busybox dynamic linker)

| # | Bug | Where | Fix | Commit |
|---|-----|-------|-----|--------|
| 27 | refetch_after_trap sends req with garbage PA on ITLB miss | core_top | Gate `refetch_after_trap & ~mmu_i_stall` | `a71b35f` |
| 28 | Refetch pulse consumed during PTW → csrrw skipped | core_top | `refetch_pending_q` extends until first req | `9ca7811` |
| 29b | Sync data fault epc=0 (pc_ie cleared on flush) | interrupt_ctrl | `pc_ie_saved_q` registered fallback | `6670820` |
| 30 | Store fault reported as cause=13 (load) → infinite loop | trap_sequencer | Registered `d_fault_is_store_r` | `7aef77b` |
| — | PTW not aborted on sfence.vma (defense-in-depth) | mmu_sv32 | Add `sfence_i` to PTW abort | `fff07dc` |
