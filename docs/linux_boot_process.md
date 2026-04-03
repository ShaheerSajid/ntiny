# ntiny Linux Boot Process

Complete boot chain from power-on reset to Linux userspace.

---

## 1. Reset & Hardware Initialization

```
PC = 0x80000000 (M-mode, MMU off)
```

The core resets in Machine mode with the program counter at `0x80000000` (the
start of RAM). The `satp` register is 0 (no address translation). All CSRs are
at their reset values: `mstatus=0`, `mtvec=0`, `mie=0`.

The RAM contains the OpenSBI firmware binary (`fw_payload.bin`) loaded at
`0x80000000` via `$readmemh` in the testbench. The Linux kernel Image is
embedded at offset `0x400000` (physical `0x80400000`) and the device tree blob
at offset `0x2200000` (physical `0x82200000`).

---

## 2. OpenSBI Early Init (M-mode)

OpenSBI is a Position-Independent Executable (PIE). Its `_start` entry point
runs the following sequence:

### 2a. Relocation (cycles 0–3000)

```
_start (0x80000000):
  ├── lottery: select boot hart (hart 0 wins)
  ├── relocate: apply R_RISCV_RELATIVE relocations
  │   (adjusts all absolute addresses from link-time VMA 0x0
  │    to load address 0x80000000)
  ├── set mtvec = _start_hang (crash handler for early traps)
  └── clear mstatush (RV32: test for endianness bits)
```

The relocation loop iterates ~550 entries from `.rela.dyn`, applying
`*(base + r_offset) += load_addr` for each `R_RISCV_RELATIVE` entry.

### 2b. CSR Probing (cycles 3000–12000)

OpenSBI probes for optional ISA extensions by attempting CSR accesses and
catching the resulting illegal-instruction traps:

```
For each extension (Zkr seed, Zicntr, Smstateen, ...):
  ├── csrr/csrw to the extension's CSR
  ├── If illegal insn trap → extension not present, skip mepc+4
  └── If no trap → extension present, record capability
```

The trap handler at `_trap_handler` (0x80000400) handles these probes by
advancing `mepc` past the faulting instruction and returning via `mret`.

### 2c. Platform Init (cycles 12000–50000)

```
sbi_init():
  ├── sbi_scratch_init()     — per-hart scratch space
  ├── sbi_domain_init()      — protection domains
  ├── sbi_hart_init()        — set mcounteren=-1, configure PMP
  ├── sbi_platform_early_init():
  │   ├── ntiny_uart_init()  — UART: reset TX/RX, set baud=115200
  │   │   (writes to 0x10000000+0x0C: control, 0x10000000+0x10: baudrate)
  │   └── aclint_mswi_cold_init() — register MSIP at CLINT+0x0000
  ├── sbi_irqchip_init():
  │   └── plic_cold_irqchip_init() — configure PLIC at 0x0C000000
  ├── sbi_timer_init():
  │   └── aclint_mtimer_cold_init() — register mtimer at CLINT+0x4000
  └── sbi_ecall_init()       — register SBI extension handlers
```

### 2d. Banner Print (cycles 50000–80000)

OpenSBI prints its full banner via `ntiny_uart_putc()`, which writes each
character directly to the UART TX register at `0x10000004`. The testbench fast
console monitor captures these writes to `uart.log`.

### 2e. Domain Setup & Handoff (cycles 80000–100000)

```
sbi_hart_switch_mode():
  ├── Set mepc = 0x80400000     (kernel entry, from FW_PAYLOAD_OFFSET)
  ├── Set mstatus.MPP = S-mode  (01)
  ├── Set a0 = hart_id (0)
  ├── Set a1 = dtb_addr (0x82200000)
  ├── Set mideleg = 0x222       (delegate SSIP, STIP, SEIP to S-mode)
  ├── Set medeleg = 0x4b109     (delegate page faults, ecall, etc.)
  └── mret                      → jumps to 0x80400000 in S-mode
```

---

## 3. Linux Kernel Early Boot (S-mode, MMU off)

```
PC = 0x80400000 (S-mode, MMU off, physical addresses)
```

The kernel Image starts with a PE/COFF header. The first instruction is
`j _start_kernel` (PC-relative), which jumps to the real entry point.

### 3a. BSS Clear & Initial Setup

```
_start_kernel (physical ~0x80401084):
  ├── csrw sie, 0              — disable S-mode interrupts
  ├── csrw sip, 0              — clear pending
  ├── Clear BSS section        — zero ~275KB of uninitialized data
  ├── Store boot hart ID       — a0 → boot_cpu_hartid
  ├── Set up tp (thread pointer) = init_task
  └── Set up sp (stack pointer) = init thread stack
```

All code runs at physical addresses using PC-relative (`auipc`) instructions.
The compiler's `cmodel=medany` ensures no absolute addresses are used.

### 3b. Page Table Setup (`setup_vm`)

```
setup_vm():
  ├── Compute kernel_map:
  │   phys_addr = 0x80400000 (detected from PC)
  │   virt_addr = 0xC0000000 (CONFIG_PAGE_OFFSET)
  │   va_pa_offset = 0x3FC00000
  ├── Create trampoline_pg_dir:
  │   └── Megapage PDE: VPN[1]=0x300 → PPN=0x80400000 (RWXGAD)
  │       (maps 0xC0000000 → 0x80400000, 4MB megapage)
  ├── Create early_pg_dir:
  │   └── Same virtual→physical mapping for early kernel use
  └── Return to _start_kernel
```

The trampoline page directory gets ONE megapage entry mapping the kernel's
virtual range. There is NO identity map — the transition from physical to
virtual addresses uses a clever stvec trick (see below).

### 3c. MMU Enable (`relocate_enable_mmu`)

This is the most delicate part of the boot:

```
relocate_enable_mmu():
  ├── Compute stvec target = virtual addr of step 4 below
  ├── csrw stvec, <virtual_addr>     ← trap handler in virtual space
  ├── sfence.vma                      ← flush TLBs
  ├── csrw satp, trampoline_pg_dir   ← ENABLE MMU
  │   (next fetch at physical PC will page-fault because
  │    trampoline has no identity map for 0x804xxxxx)
  │
  │   ═══ PAGE FAULT ═══
  │   The CPU traps to stvec (virtual address 0xC000xxxx)
  │   which IS mapped in the trampoline → continues in virtual space
  │
  ├── csrw stvec, <new_handler>       ← set proper trap vector
  ├── Relocate gp, ra to virtual addresses
  ├── csrw satp, early_pg_dir         ← switch to full page table
  ├── sfence.vma                      ← flush TLBs
  └── ret (to virtual _start_kernel)
```

After this point, ALL code runs at virtual addresses (0xC0xxxxxx).

### 3d. Trap Vector & Continuation

```
_start_kernel (continued, now virtual):
  ├── setup_trap_vector()
  │   └── csrw stvec, handle_exception  (0xC0002bcc)
  ├── setup_vm_final()           — set up swapper_pg_dir with full mappings
  ├── Call start_kernel()        — C entry point
```

---

## 4. Linux Kernel Main Init (S-mode, MMU on)

```
PC = 0xC0xxxxxx (S-mode, Sv32 active, virtual addresses)
```

### 4a. start_kernel() Sequence

```
start_kernel():
  ├── setup_arch()
  │   ├── Parse device tree (ntiny.dts)
  │   ├── Detect: Machine model = "ntiny RISC-V SoC"
  │   ├── Detect: rv32imac ISA, Sv32 MMU
  │   ├── Memory: 60MB at 0x80400000-0x83FFFFFF
  │   └── SBI: v3.0, TIME/IPI/RFENCE extensions
  ├── mm_init()               — memory allocator, page tables
  ├── sched_init()            — scheduler
  ├── irq_init()
  │   ├── riscv-intc: 32 local interrupts mapped
  │   └── plic: 6 interrupts, 1 context
  ├── time_init()
  │   └── clocksource: riscv_clocksource @ 50MHz, 20ns resolution
  ├── console_init()
  │   ├── earlycon: sbi0 (early boot console via SBI putchar)
  │   └── hvc0 (HVC RISC-V SBI console, persistent)
  ├── calibrate_delay()       — 100.00 BogoMIPS (calculated, not measured)
  ├── Driver initialization   — USB, DMA, PCI, thermal, cpuidle, ...
  └── rest_init()
      └── kernel_thread(kernel_init)
```

### 4b. Kernel Console Output

The kernel uses two console mechanisms:

1. **earlycon=sbi** (bootconsole): Available from very early boot. Each
   character triggers an SBI ecall:
   ```
   S-mode: ecall (a7=1, a0=char)  →  M-mode trap  →
   OpenSBI: sbi_console_putchar()  →  ntiny_uart_putc()  →
   Store to UART TX (0x10000004)  →  testbench captures to uart.log
   ```

2. **hvc0** (HVC SBI console): Takes over after console_init(). Uses the
   same SBI path but with buffering and proper tty layer.

### 4c. Timer Interrupts

The kernel requests periodic timer interrupts via SBI:

```
S-mode: ecall sbi_set_timer(mtime + interval)
  → M-mode: OpenSBI writes mtimecmp = requested_value
  → CLINT: when mtime >= mtimecmp, assert MTIP
  → OpenSBI: inject STIP into S-mode (set mip.STIP)
  → S-mode timer handler: update jiffies, schedule, request next tick
```

Timer tick rate: HZ=250 → interrupt every 200,000 cycles (4ms at 50MHz).

---

## 5. Userspace Init (U-mode)

```
PC = 0x0001xxxx (U-mode, user page tables, virtual addresses)
```

### 5a. Transition to Userspace

```
kernel_init():
  ├── Populate rootfs from initramfs (embedded cpio)
  ├── do_execve("/init")
  │   ├── Set up user page tables (satp changes)
  │   ├── Map init binary at user virtual address
  │   └── sret → U-mode at init entry point
```

### 5b. Init Process

Our minimal init binary:
```c
void _start(void) {
    sys_write(1, "ntiny Linux booted!\n", 20);  // ecall __NR_write
    for (;;) __asm__("wfi");                     // halt
}
```

The `sys_write` ecall goes:
```
U-mode ecall → S-mode syscall handler → kernel write() → SBI putchar → UART
```

---

## Memory Map During Boot

```
Physical Memory (64MB):
  0x80000000 ┌─────────────────────┐
             │ OpenSBI (180KB)     │  M-mode firmware
  0x80030000 ├─────────────────────┤
             │ (gap)               │
  0x80400000 ├─────────────────────┤
             │ Linux kernel Image  │  ~26MB (includes padding)
             │ .text, .rodata,     │
             │ .data, .bss         │
  0x82200000 ├─────────────────────┤
             │ Device tree blob    │  ~1.2KB
  0x82201000 ├─────────────────────┤
             │ (free RAM)          │  for kernel heap, user pages
  0x83FFFFFF └─────────────────────┘

Virtual Memory (Sv32, after MMU enable):
  0x00000000 ┌─────────────────────┐
             │ User space          │  0-3GB
  0xC0000000 ├─────────────────────┤
             │ Kernel direct map   │  lowmem (60MB)
  0xC3C00000 ├─────────────────────┤
             │ vmalloc             │  512MB
  0x9E000000 ├─────────────────────┤  (below kernel)
             │ vmemmap, PCI I/O    │
  0x9C800000 ├─────────────────────┤
             │ fixmap              │  8MB
  0xFFFFFFFF └─────────────────────┘

Peripheral MMIO (uncached, identity mapped by kernel):
  0x02000000  CLINT (mtime, mtimecmp, msip)
  0x0C000000  PLIC (priorities, enables, claim/complete)
  0x10000000  UART (TX, RX, status, control, baudrate)
```

---

## Timing (Verilator Simulation)

| Phase | Cycles | Wall Time (50MHz) | Sim Time |
|-------|--------|--------------------|----------|
| OpenSBI init | ~100K | 2ms | ~1s |
| OpenSBI banner | ~80K | 1.6ms | ~1s |
| Kernel early boot | ~2M | 40ms | ~10s |
| MM init | ~50M | 1s | ~3min |
| Driver init | ~100M | 2s | ~5min |
| Total to userspace | ~160M | 3.2s | ~10min |
