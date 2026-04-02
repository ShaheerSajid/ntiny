# ntiny Privileged Architecture Reference

Exact hardware behavior as implemented in RTL. All bit positions, CSR addresses,
and sequences reflect the actual design.

---

## 1. Privilege Modes

| Level | Encoding | Name | When |
|-------|----------|------|------|
| 3 | `2'b11` | Machine (M) | Reset default, highest privilege |
| 1 | `2'b01` | Supervisor (S) | OS kernel |
| 0 | `2'b00` | User (U) | Application code |

**Stored in**: `priv_level` register in `csr_unit.sv`, 2 bits, reset to M-mode.

---

## 2. CSR Map

### Machine-Mode CSRs

| CSR | Addr | Reset | RW | Key Bits |
|-----|------|-------|----|----------|
| **mstatus** | 0x300 | 0 | RW | See below |
| **misa** | 0x301 | 0x40141127 | RO | RV32 IMAFCSU |
| **medeleg** | 0x302 | 0 | RW | Exception delegation bitmap |
| **mideleg** | 0x303 | 0 | RW | Interrupt delegation bitmap |
| **mie** | 0x304 | 0 | RW | Interrupt enable bits |
| **mtvec** | 0x305 | 0 | RW | Trap vector: `[31:2]=base, [1:0]=mode` |
| **mcounteren** | 0x306 | 0 | RW | Counter access enable |
| **mscratch** | 0x340 | 0 | RW | Scratch register |
| **mepc** | 0x341 | 0 | RW | Exception return PC |
| **mcause** | 0x342 | 0 | RW | `[31]=interrupt, [7:0]=code` |
| **mtval** | 0x343 | 0 | RW | Faulting address or value |
| **mip** | 0x344 | 0 | HW | Interrupt pending (mostly HW-driven) |
| **mcountinhibit** | 0x320 | 0 | RW | `[0]=mcycle, [2]=minstret` |
| **mcycle/h** | 0xB00/B80 | 0 | RW | 64-bit cycle counter |
| **minstret/h** | 0xB02/B82 | 0 | RW | 64-bit retired instruction counter |

### Supervisor-Mode CSRs

| CSR | Addr | Reset | RW | Notes |
|-----|------|-------|----|-------|
| **sstatus** | 0x100 | 0 | RW | View of mstatus subset |
| **sie** | 0x104 | 0 | RW | S-mode interrupt enables |
| **stvec** | 0x105 | 0 | RW | S-mode trap vector |
| **scounteren** | 0x106 | 0 | RW | U-mode counter access |
| **sscratch** | 0x140 | 0 | RW | Scratch register |
| **sepc** | 0x141 | 0 | RW | S-mode exception PC |
| **scause** | 0x142 | 0 | RW | S-mode cause |
| **stval** | 0x143 | 0 | RW | S-mode faulting address |
| **sip** | 0x144 | 0 | RW | S-mode pending (only SSIP[1] writable) |
| **satp** | 0x180 | 0 | RW | `[31]=MODE, [30:22]=ASID, [21:0]=PPN` |

### User-Mode CSRs (FPU)

| CSR | Addr | Notes |
|-----|------|-------|
| **fflags** | 0x001 | FP exception flags [4:0] |
| **frm** | 0x002 | FP rounding mode [2:0] |
| **fcsr** | 0x003 | Alias: `[7:5]=frm, [4:0]=fflags` |
| **cycle/h** | 0xC00/C80 | Alias to mcycle (gated by mcounteren) |
| **instret/h** | 0xC02/C82 | Alias to minstret (gated by mcounteren) |

---

## 3. mstatus Bit Map

```
Bit   Field    Description
──────────────────────────────────────────────
 [1]  SIE      S-mode global interrupt enable
 [3]  MIE      M-mode global interrupt enable
 [5]  SPIE     S-mode prior interrupt enable (saved SIE on S-trap)
 [7]  MPIE     M-mode prior interrupt enable (saved MIE on M-trap)
 [8]  SPP      S-mode prior privilege (0=U, 1=S)
[12:11] MPP    M-mode prior privilege (00=U, 01=S, 11=M)
[14:13] FS     FPU state (00=Off, 01=Initial, 10=Clean, 11=Dirty)
 [17] MPRV     Modify privilege for loads/stores
 [18] SUM      Supervisor User Memory access
 [19] MXR      Make eXecutable Readable
 [20] TVM      Trap Virtual Memory (S-mode SATP/SFENCE.VMA traps)
 [31] SD       State Dirty (read-only, = FS==11)
```

**Write masks:**
- mstatus (with FPU): `0x007E_79AA`
- mstatus (no FPU):   `0x007E_19AA`
- sstatus (view):     `0x800C_6122` (SD + SIE + SPIE + SPP + FS + SUM + MXR)

---

## 4. Trap Entry Sequence

### When a trap fires (synchronous exception or async interrupt):

**Step 1 — Route the trap:**
```
if (current_priv == M-mode)
    trap goes to M-mode                    (never delegated)
else if (interrupt)
    trap goes to S-mode if mideleg[cause] == 1, else M-mode
else (exception)
    trap goes to S-mode if medeleg[cause] == 1, else M-mode
```

### M-mode trap entry:

```
 CSR writes (all happen atomically on the clock edge):
 ─────────────────────────────────────────────────────
 mstatus.MPP   <-- current privilege        (save priv to MPP)
 mstatus.MPIE  <-- mstatus.MIE             (save interrupt enable)
 mstatus.MIE   <-- 0                       (disable interrupts)
 mepc           <-- exception PC            (faulting/interrupted instruction)
 mcause         <-- {is_interrupt, cause}   (bit 31 = interrupt flag)
 mtval          <-- faulting address or 0
 priv_level     <-- M (2'b11)

 Handler address:
 ────────────────
 if (mtvec[0] == 0)   // Direct mode
     PC <-- mtvec[31:2] << 2
 if (mtvec[0] == 1 && is_interrupt)   // Vectored mode
     PC <-- (mtvec[31:2] << 2) + (cause * 4)
 if (mtvec[0] == 1 && !is_interrupt)  // Vectored, but exception
     PC <-- mtvec[31:2] << 2          (exceptions always go to base)
```

### S-mode trap entry (delegated):

```
 mstatus.SPP   <-- current privilege[0]    (save priv bit 0 to SPP)
 mstatus.SPIE  <-- mstatus.SIE            (save S-mode interrupt enable)
 mstatus.SIE   <-- 0                      (disable S-mode interrupts)
 sepc           <-- exception PC
 scause         <-- {is_interrupt, cause}
 stval          <-- faulting address or 0
 priv_level     <-- S (2'b01)

 Handler: same vectored/direct logic using stvec instead of mtvec.
```

---

## 5. Trap Exit (MRET / SRET)

### MRET:

```
 mstatus.MIE   <-- mstatus.MPIE           (restore interrupt enable)
 mstatus.MPIE  <-- 1                      (set to 1 per spec)
 mstatus.MPP   <-- U (2'b00)             (clear to least privilege)
 mstatus.MPRV  <-- 0  (if MPP != M)      (clear memory privilege override)
 priv_level     <-- old mstatus.MPP       (restore saved privilege)
 PC             <-- mepc                   (return to interrupted code)
```

### SRET:

```
 mstatus.SIE   <-- mstatus.SPIE           (restore S-mode interrupt enable)
 mstatus.SPIE  <-- 1
 mstatus.SPP   <-- 0                      (clear to U-mode)
 priv_level     <-- {0, old SPP}          (S or U mode)
 PC             <-- sepc
```

**Guard rails:**
- MRET from non-M-mode: illegal instruction exception
- SRET from U-mode: illegal instruction exception
- SRET when mstatus.TVM=1 and in S-mode: illegal instruction

---

## 6. Exception Causes & Priority

Priority order (highest first):

| Priority | Source | Cause | Code | mtval |
|----------|--------|-------|------|-------|
| 1 | IE-stage | Misaligned load | 4 | faulting address |
| 1 | IE-stage | Misaligned store/AMO | 6 | faulting address |
| 1 | IE-stage | Load page fault | 13 | faulting virtual address |
| 1 | IE-stage | Store page fault | 15 | faulting virtual address |
| 2 | ID-stage | Instruction page fault | 12 | faulting virtual address |
| 3 | ID-stage | Illegal instruction | 2 | faulting instruction word |
| 4 | ID-stage | ECALL from U-mode | 8 | 0 |
| 4 | ID-stage | ECALL from S-mode | 9 | 0 |
| 4 | ID-stage | ECALL from M-mode | 11 | 0 |
| 5 | ID-stage | EBREAK | 3 | 0 |
| 6 | Async | M-mode external interrupt | 11 | 0 |
| 6 | Async | M-mode software interrupt | 3 | 0 |
| 6 | Async | M-mode timer interrupt | 7 | 0 |
| 6 | Async | S-mode external interrupt | 9 | 0 |
| 6 | Async | S-mode software interrupt | 1 | 0 |
| 6 | Async | S-mode timer interrupt | 5 | 0 |

**IE-stage exceptions take priority** because they are from older (earlier) instructions.

---

## 7. Interrupt Handling

### Interrupt pending/enable bits (mip/mie):

```
Bit    Interrupt              Pending (mip)  Enable (mie)
─────────────────────────────────────────────────────────
 [1]   S-mode software (SSIP)  HW/SW         SSIE
 [3]   M-mode software (MSIP)  HW            MSIE
 [5]   S-mode timer   (STIP)   HW            STIE
 [7]   M-mode timer   (MTIP)   HW            MTIE
 [9]   S-mode external (SEIP)  HW            SEIE
[11]   M-mode external (MEIP)  HW            MEIE
```

### When does an interrupt fire?

```
M-mode interrupt fires when:
    mip[x] && mie[x] &&                     (pending AND enabled)
    (priv < M  ||  mstatus.MIE == 1)        (global enable check)

S-mode interrupt fires when:
    sip[x] && sie[x] &&                     (pending AND enabled)
    (priv < S  ||  (priv == S && mstatus.SIE == 1))

M-mode interrupts have higher priority than S-mode.
```

### Interrupt priority within a mode:

```
External (bit 11/9) > Software (bit 3/1) > Timer (bit 7/5)
```

### Delegation (mideleg):

Setting `mideleg[x] = 1` routes interrupt cause `x` to S-mode handler
(using stvec, sepc, scause) instead of M-mode.

---

## 8. Sv32 MMU

### When is translation active?

```
Translation ON when:
    satp.MODE == 1  (Sv32 enabled)
    AND privilege != M-mode

For data accesses with MPRV=1:
    effective_priv = mstatus.MPP  (instead of current priv)
    translation active if effective_priv != M-mode
```

### Address breakdown (32-bit virtual address):

```
[31:22]  VPN[1]  (10 bits) -- level-1 page table index
[21:12]  VPN[0]  (10 bits) -- level-0 page table index
[11:0]   offset  (12 bits) -- byte offset within 4KB page
```

### TLB structure:

- **8-entry ITLB** and **8-entry DTLB** (fully associative)
- Each entry: `{valid, asid[8:0], vpn1[9:0], vpn0[9:0], ppn1[11:0], ppn0[9:0], mega, d, a, g, u, x, w, r}`
- Replacement: FIFO (circular write pointer)
- Flush: SFENCE.VMA invalidates all entries in both TLBs

### TLB lookup (combinational, parallel):

```
For each of 8 entries:
    match = entry.valid
         && (entry.vpn1 == addr.VPN[1])
         && (entry.mega || entry.vpn0 == addr.VPN[0])
         && (entry.g || entry.asid == satp.ASID)

If match found:
    HIT --> permission check --> output physical address
If no match:
    MISS --> trigger Page Table Walk (PTW)
```

### Physical address construction:

```
4KB page (mega=0):
    PA = { entry.ppn1, entry.ppn0, offset[11:0] }

4MB megapage (mega=1):
    PA = { entry.ppn1, VPN[0], offset[11:0] }
    (ppn0 is ignored; VPN[0] becomes part of the physical address)
```

### Page Table Walk (PTW) sequence:

```
                          ┌──────────┐
                    ┌────>│ PTW_IDLE │<──────────────────────┐
                    │     └────┬─────┘                       │
                    │          │ TLB miss (D-miss > I-miss)  │
                    │          v                             │
                    │     ┌──────────┐                       │
                    │     │  PTW_L1  │  Read level-1 PDE     │
                    │     │          │  addr = satp.PPN*4K   │
                    │     │          │       + VPN[1]*4      │
                    │     └────┬─────┘                       │
                    │          │                             │
                    │    ┌─────┴──────┐                      │
                    │    │            │                      │
                    │  invalid    leaf (R|X)?                │
                    │    │            │                      │
                    │    v       ┌────┴────┐                 │
                    │  FAULT   mega    misaligned?           │
                    │            │         │                 │
                    │            │ ok     FAULT              │
                    │            v                           │
                    │         PTW_FILL ──> perm check ──ok──>│ fill TLB
                    │            │                           │
                    │          pointer (not leaf)            │
                    │            │                           │
                    │            v                           │
                    │     ┌────────────┐                     │
                    │     │ PTW_L0_WAIT│ (drain stale rvalid)│
                    │     └────┬───────┘                     │
                    │          v                             │
                    │     ┌──────────┐                       │
                    │     │  PTW_L0  │  Read level-0 PTE     │
                    │     │          │  addr = L1.PPN*4K     │
                    │     │          │       + VPN[0]*4      │
                    │     └────┬─────┘                       │
                    │          │                             │
                    │    ┌─────┴──────┐                      │
                    │  invalid    leaf (R|X)?                │
                    │    │            │                      │
                    │  FAULT     PTW_FILL ──> perm check ───>│
                    │                   │                    │
                    │                 FAULT (if bad perms)   │
                    └────────────────────────────────────────┘
```

### PTE format (32 bits):

```
[31:20]  PPN[1]   (12 bits)  Physical page number, upper
[19:10]  PPN[0]   (10 bits)  Physical page number, lower
 [9:8]   RSW      (2 bits)   Reserved for software
  [7]    D        Dirty       (must be 1 for stores)
  [6]    A        Accessed    (must be 1 for any access)
  [5]    G        Global      (matches regardless of ASID)
  [4]    U        User        (accessible in U-mode)
  [3]    X        Executable
  [2]    W        Writable
  [1]    R        Readable
  [0]    V        Valid
```

**Leaf PTE**: `R=1` or `X=1` (has permissions, points to a page)
**Pointer PTE**: `R=0, W=0, X=0, V=1` (points to next-level table)
**Invalid**: `V=0` or `(W=1 && R=0)` (writable but not readable)

### Permission checks:

```
Instruction fetch:
    PASS if: X=1 AND A=1
    U-mode: also needs U=1
    S-mode: needs U=0 (S-mode cannot execute U pages, even with SUM)

Data load:
    PASS if: (R=1 OR (MXR=1 AND X=1)) AND A=1
    U-mode: also needs U=1
    S-mode: needs U=0, UNLESS SUM=1 (then U pages allowed)

Data store:
    PASS if: W=1 AND D=1 AND A=1
    Same U/S privilege checks as load
```

**A/D bit handling**: Hardware does NOT set A/D bits automatically.
If A=0 or (store and D=0), a page fault is raised. Software must update
the PTE and retry.

---

## 9. CSR Read/Write Sequences

### CSR instructions:

| Instruction | Operation | CSR update |
|-------------|-----------|------------|
| CSRRW rd, csr, rs1 | rd = CSR; CSR = rs1 | Always writes |
| CSRRS rd, csr, rs1 | rd = CSR; CSR = CSR \| rs1 | Sets bits |
| CSRRC rd, csr, rs1 | rd = CSR; CSR = CSR & ~rs1 | Clears bits |
| CSRRWI rd, csr, imm | rd = CSR; CSR = zimm | Immediate variant |
| CSRRSI rd, csr, imm | rd = CSR; CSR = CSR \| zimm | Immediate variant |
| CSRRCI rd, csr, imm | rd = CSR; CSR = CSR & ~zimm | Immediate variant |

### Access control:

```
CSR address [11:10] = read-only if 2'b11
CSR address [9:8]   = minimum privilege level required

If current_priv < required_priv:
    Illegal instruction exception (cause 2)
If write to read-only CSR:
    Illegal instruction exception (cause 2)
```

### mstatus read/write example:

```
CSRRS x1, mstatus, x0     // Read mstatus into x1 (rs1=x0, no bits set)

Step 1: Privilege check -- mstatus is 0x300, addr[9:8]=2'b11 → needs M-mode
Step 2: Read old value  -- x1 = mstatus (all 32 bits)
Step 3: Write new value -- mstatus = mstatus | 0 (no change, since rs1=x0)
Step 4: Apply mask      -- only bits in MSTATUS_WMASK are actually updated
```

### satp write sequence (enables MMU):

```
# In M-mode:
li   t0, 0x80000001        # MODE=1 (Sv32), ASID=0, PPN=1 (page table at 0x1000)
csrw satp, t0              # Write satp -- MMU now active for S/U mode
sfence.vma                 # Flush TLBs to pick up new page table
```

### Interrupt enable sequence:

```
# Enable M-mode timer interrupt:
li   t0, (1 << 7)          # MTIE bit
csrs mie, t0               # Set bit 7 in mie

# Enable global M-mode interrupts:
csrsi mstatus, (1 << 3)    # Set MIE bit in mstatus

# Now: if mip[7] (MTIP) goes high, timer interrupt fires
```

### Delegation sequence (route interrupts to S-mode):

```
# Delegate S-mode interrupts to S-mode handler:
li   t0, 0x222             # SSIP[1] + STIP[5] + SEIP[9]
csrw mideleg, t0           # S-mode interrupts handled by stvec

# Delegate common exceptions to S-mode:
li   t0, 0xB35D            # Bits for causes 0,2,3,4,6,8,9,12,13,15
csrw medeleg, t0           # These exceptions go to S-mode handler
```

---

## 10. Quick Reference: Common Sequences

### Context switch (M-mode trap handler entry):

```asm
# Hardware has already saved: mepc, mcause, mtval, mstatus.MPP/MPIE
# Software must save registers:
csrrw sp, mscratch, sp     # Swap sp with mscratch (get M-mode stack)
sw    ra, 0(sp)            # Save caller-saved registers
sw    t0, 4(sp)
...
csrr  t0, mcause           # Read cause
bltz  t0, handle_interrupt  # Bit 31 set = interrupt
# else: handle exception
```

### Return from trap:

```asm
# Restore registers...
lw    ra, 0(sp)
lw    t0, 4(sp)
...
csrrw sp, mscratch, sp     # Restore original sp
mret                        # Return: restores priv, MIE from MPIE, PC from mepc
```

### Enable Sv32 paging:

```asm
# Assume page table root at physical address 0x80010000
# PPN = 0x80010000 >> 12 = 0x80010
li    t0, (1 << 31) | 0x80010   # MODE=Sv32, PPN
csrw  satp, t0
sfence.vma                       # Flush stale TLB entries
# From now on, S-mode and U-mode use virtual addresses
```
