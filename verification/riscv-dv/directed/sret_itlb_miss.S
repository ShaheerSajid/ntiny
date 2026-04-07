# ── SRET ITLB Miss + PTW Contention Test ─────────────────────────────────────
# Reproduces the SRET PC-latch deadlock under realistic Linux-like conditions:
#
#   1. M-mode sets up Sv32 with TWO separate page ranges:
#      - Megapage at VA 0x80000000 (S-mode, U=0)
#      - 4KB page at VA 0xC0000000 (U-mode, U=1) via two-level walk
#   2. MRET to S-mode
#   3. S-mode does SFENCE.VMA (flush all TLBs)
#   4. S-mode issues a STORE to a DIFFERENT page (triggers DTLB miss → PTW walk)
#   5. While the PTW is busy walking for the store, S-mode does SRET
#   6. SRET target VA 0xC0000000 needs ITLB walk — but PTW is busy with data
#   7. BUG: continuous MMU flush prevents the queued ITLB walk from ever starting
#
# Using 4KB pages (not megapage) for the U-mode mapping forces a TWO-LEVEL
# page walk, making the ITLB miss take longer to resolve — wider window for
# the bug to manifest.
#
# Page table layout:
#   Megapage: VPN1=0x200 → PA 0x80000000 (S-mode, U=0)
#   4KB page: VPN1=0x300, VPN0=0x000 → PA 0x80000000 (U-mode, U=1)
#             Requires: L1 PDE at page_dir[0x300] → page_table_l0
#                       L0 PTE at page_table_l0[0x000]
#
#   Data page: VPN1=0x201 → PA 0x80400000 (S-mode, U=0, separate 4MB region)
#              Used for the data store that creates PTW contention.

.globl _start
.globl tohost
.globl fromhost

.equ PTE_V,   0x001
.equ PTE_R,   0x002
.equ PTE_W,   0x004
.equ PTE_X,   0x008
.equ PTE_U,   0x010
.equ PTE_A,   0x040
.equ PTE_D,   0x080

# S-mode megapage: PPN1=0x200, V|R|W|X|A|D (no U)
.equ PTE_S_CODE, (0x200 << 20) | PTE_V | PTE_R | PTE_W | PTE_X | PTE_A | PTE_D
# S-mode data megapage: PPN1=0x200, V|R|W|A|D (no X, no U) — for data store contention
.equ PTE_S_DATA, (0x200 << 20) | PTE_V | PTE_R | PTE_W | PTE_A | PTE_D
# L1 PDE (pointer to L0 table): V only, PPN filled at runtime
# L0 U-mode 4KB page: PPN = 0x80000 (PA 0x80000000), V|R|W|X|U|A|D
.equ PTE_U_LEAF, (0x80000 << 10) | PTE_V | PTE_R | PTE_W | PTE_X | PTE_U | PTE_A | PTE_D

.section .text
_start:
    # ── Trap vectors ─────────────────────────────────────────────────────
    la   t0, m_trap_handler
    csrw mtvec, t0
    la   t0, s_trap_handler
    csrw stvec, t0

    # ── Build page table ─────────────────────────────────────────────────
    la   a0, page_dir
    la   a1, page_table_l0

    # page_dir[0x200]: megapage for S-mode code (VA 0x80000000)
    li   t1, PTE_S_CODE
    li   t2, (0x200 * 4)
    add  t3, a0, t2
    sw   t1, 0(t3)

    # page_dir[0x201]: megapage for data contention (VA 0x80400000)
    # Map to SAME physical memory 0x80000000 but as data-only page
    li   t1, PTE_S_DATA
    li   t2, (0x201 * 4)
    add  t3, a0, t2
    sw   t1, 0(t3)

    # page_dir[0x300]: L1 PDE pointing to page_table_l0 (VA 0xC0000000)
    # PDE = (page_table_l0 >> 12) << 10 | PTE_V
    srli t1, a1, 12
    slli t1, t1, 10
    ori  t1, t1, PTE_V
    li   t2, (0x300 * 4)
    add  t3, a0, t2
    sw   t1, 0(t3)

    # page_table_l0[0]: 4KB leaf for U-mode (VA 0xC0000000 → PA 0x80000000)
    li   t1, PTE_U_LEAF
    sw   t1, 0(a1)

    # ── Enable Sv32 ─────────────────────────────────────────────────────
    srli t0, a0, 12
    li   t1, 0x80000000
    or   t0, t0, t1
    csrw satp, t0
    sfence.vma
    fence.i

    # ── Delegate ecall-from-U to S-mode ──────────────────────────────────
    li   t0, (1 << 8)
    csrw medeleg, t0

    # ── MRET to S-mode ──────────────────────────────────────────────────
    li   t0, (1 << 11) | (1 << 7)   # MPP=S, MPIE=1
    csrw mstatus, t0
    la   t0, s_entry
    csrw mepc, t0
    fence.i
    mret

# ═════════════════════════════════════════════════════════════════════════════
# S-MODE
# ═════════════════════════════════════════════════════════════════════════════
    .align 2
s_entry:
    # ── Flush ALL TLBs ── makes both ITLB and DTLB cold ─────────────────
    sfence.vma

    # ── Compute U-mode target VA ─────────────────────────────────────────
    la   t0, u_entry           # physical/S-mode VA
    li   t1, 0x40000000        # offset to U-mode alias
    add  t0, t0, t1            # VA 0xC0000000 + offset
    csrw sepc, t0

    # Set SPP=0 (U-mode), SPIE=1
    li   t0, (1 << 5)
    csrw sstatus, t0

    # ── PTW contention: issue a STORE to the data page ───────────────────
    # VA 0x80400000 maps to PA 0x80000000 (data megapage at VPN1=0x201).
    # After sfence.vma, the DTLB is cold → this store triggers a DTLB miss
    # → PTW starts walking L1 for the data page.
    # SRET follows immediately: the ITLB miss for 0xC0000000 is queued
    # behind the data PTW walk. The continuous MMU flush (from ret_valid
    # staying HIGH during the stall) prevents the instruction PTW walk
    # from ever starting.
    li   t0, 0x80400000
    li   t1, 0xDEADBEEF
    sw   t1, 0(t0)            # ← DTLB miss → PTW busy

    # ── SRET ── immediate after store, while PTW may still be walking ────
    sret

# ═════════════════════════════════════════════════════════════════════════════
# U-MODE (runs at VA 0xC0000000 + offset)
# ═════════════════════════════════════════════════════════════════════════════
    .align 2
u_entry:
    nop
    nop
    li   gp, 1
    ecall
1:  j    1b

# ═════════════════════════════════════════════════════════════════════════════
# TRAP HANDLERS
# ═════════════════════════════════════════════════════════════════════════════

    .align 2
m_trap_handler:
    csrr t0, mcause
    li   t1, 9               # ecall from S
    beq  t0, t1, test_pass
    li   t1, 8               # ecall from U
    beq  t0, t1, test_pass
    # unexpected: store cause
    csrr gp, mcause
    j    test_fail

    .align 2
s_trap_handler:
    csrr t0, scause
    li   t1, 8               # ecall from U
    beq  t0, t1, s_forward
    csrr gp, scause
    j    test_fail
s_forward:
    ecall                    # forward to M-mode

test_pass:
    li   gp, 1
    j    write_tohost
test_fail:
    slli gp, gp, 1
    ori  gp, gp, 1
    j    write_tohost

write_tohost:
    la   t0, tohost
    sw   gp, 0(t0)
    j    write_tohost

# ═════════════════════════════════════════════════════════════════════════════
# PAGE TABLES
# ═════════════════════════════════════════════════════════════════════════════

    .section .page_table, "aw", @progbits
    .align 12
page_dir:
    .fill 1024, 4, 0         # L1 page directory (4KB)

    .align 12
page_table_l0:
    .fill 1024, 4, 0         # L0 page table for U-mode mapping (4KB)

# ═════════════════════════════════════════════════════════════════════════════
# DATA
# ═════════════════════════════════════════════════════════════════════════════

    .section .data
    .align 6
tohost:    .word 0
    .align 6
fromhost:  .word 0

    .section .kernel_stack, "aw", @progbits
    .align 4
    .fill 256, 4, 0
kernel_stack_end:
