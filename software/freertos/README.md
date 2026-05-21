# FreeRTOS on NTiny

FreeRTOS kernel running in RISC-V S-mode on the NTiny SoC, launched as an
OpenSBI payload. This directory is self-contained: it clones its own
OpenSBI tree on first build and lands every artifact under `build/`.

---

## Quick start

```bash
cd software/freertos
make
```

On first invocation the Makefile clones OpenSBI v1.8 into
`external/opensbi/` and uses the shared NTiny platform code at
`../linux/opensbi-platform/`. Subsequent builds reuse both. The final
artifact is `../../flows/simulation/ram.hex`, ready for the testbench.

Targets:

| Target           | Effect                                                                   |
| ---------------- | ------------------------------------------------------------------------ |
| `make` / `build` | Compile FreeRTOS, embed it in OpenSBI fw_payload, emit `ram.hex`.        |
| `make clean`     | Remove `build/` (keeps the OpenSBI clone).                               |
| `make distclean` | Remove `build/` **and** `external/opensbi/`.                             |

Requirements: `riscv32-unknown-linux-gnu-gcc` (defaulted at
`/opt/riscv-linux/bin`, override with `TOOLCHAIN_BIN=...`), `dtc`,
`python3`, and a working git checkout.

---

## Directory layout

```
software/freertos/
├── Makefile                       # Build automation, all paths relative
├── README.md                      # This file
├── FreeRTOS/
│   ├── Demo/RISC-V-NTINY-GCC/     # NTiny-specific board port (authored)
│   │   ├── FreeRTOSConfig.h       # Kernel config (S-mode CSRs, tick rate, heap)
│   │   ├── init.c                 # Reset handler, S-mode trap vector, libc subset
│   │   ├── init.h                 # Reset/init prototypes
│   │   ├── csr.h                  # csr_read/write/set/clear macros
│   │   ├── link.ld                # Static-binary layout at 0x80400000
│   │   └── main.c                 # Hello-world demo task
│   ├── License/license.txt        # FreeRTOS MIT license
│   └── Source/                    # FreeRTOS kernel (pruned)
│       ├── include/               # Public kernel headers
│       ├── tasks.c, list.c,       # Kernel TUs that the demo links against
│       │   queue.c, timers.c
│       └── portable/
│           ├── GCC/RISCV/         # RISC-V S-mode port (authored)
│           │   ├── port.c         # Tick timer (Sstc), trap dispatch, stack init
│           │   ├── portasm.S      # Context save/restore, vPortYield, vectors
│           │   └── portmacro.h    # Critical section + ISR mask primitives
│           └── MemMang/heap_4.c   # Coalescing heap allocator
├── build/                         # Build artifacts (gitignored)
│   ├── freertos.elf, .bin, .map
│   ├── ntiny.dtb
│   └── opensbi/                   # OpenSBI out-of-tree build (O=…)
└── external/opensbi/              # OpenSBI source (gitignored, cloned on demand)
```

Pruned from upstream FreeRTOS: `FreeRTOS-Plus/`, `Test/`, all non-NTiny
demos, alternative `heap_{1,2,3,5}.c`, `croutine.c`, `event_groups.c`,
`stream_buffer.c`, and upstream submodule/CI metadata. The remaining tree
is ~1.2 MiB.

---

## Boot flow: how OpenSBI hands off to FreeRTOS

```
 reset
   │
   ▼
 0x80000000  OpenSBI fw_payload (M-mode)
   │  - Initialises CLINT/PLIC, sets menvcfg.STCE (Sstc), menvcfg.ADUE
   │  - Delegates standard exceptions/interrupts to S-mode (medeleg/mideleg)
   │  - Embedded payload (FreeRTOS) lives at the next 4 MiB boundary
   │  - mret to S-mode with:
   │      pc = 0x80400000   a0 = hartid   a1 = fdt
   ▼
 0x80400000  .init  →  j RESET_HANDLER          (init.c: _init)
   │
   ▼
   RESET_HANDLER (init.c, naked)
   │  1. stvec ← &freertos_vector_table | 1   (vectored mode)
   │  2. sstatus.FS ← Initial (FPU contexts allowed, even though our ISA has no F)
   │  3. gp  ← __global_pointer$
   │  4. sp  ← _stack_top                     (16 KiB boot stack)
   │  5. clear .bss
   │  6. call c_startup → main()
   ▼
   main() in main.c
   │  xTaskCreate(vHelloWorldTask, …)
   │  vTaskStartScheduler()
   ▼
   xPortStartScheduler (portasm.S)
   │  jal  vPortSetupTimer       (programs stimecmp via Sstc)
   │  portRESTORE_CONTEXT        (loads first task, sret to S-mode user code)
   ▼
   running tasks ─── periodic Supervisor Timer Interrupt (cause 5)
                     ↓
                     freertos_vector_table[5]
                     ↓
                     freertos_risc_v_mtimer_interrupt_handler (portasm.S)
                     ↓ portSAVE_CONTEXT
                     ↓ vPortSysTickHandler  → reprograms stimecmp,
                     ↓                       calls vTaskIncrementTick +
                     ↓                       vTaskSwitchContext
                     ↓ portRESTORE_CONTEXT (sret back into next task)
```

Notes:
* OpenSBI is built with the platform code at `../linux/opensbi-platform/`
  which already enables `menvcfg.STCE` so S-mode can write `stimecmp`
  directly (no SBI ecall per tick).
* The vector table is 128-byte aligned with `.option norvc` so each entry
  is exactly a 4-byte uncompressed `j`. In vectored mode interrupts go to
  `BASE + 4*cause`; exceptions still go to `BASE + 0`.
* The exception slot (offset 0) lands in
  `freertos_risc_v_exception_handler`, which resets `sp` to `_stack_top`,
  captures `scause/sepc/stval/s0`, and calls `exception_panic` to dump a
  short backtrace over UART before halting.

---

## UART path: how prints reach the host

FreeRTOS runs in S-mode and **does not touch the SiFive UART MMIO
directly**. Instead, `uart_putc` in `software/drivers/uart/uart.c` invokes
the SBI Console Putchar legacy extension:

```c
int uart_putc(char c) {
    register unsigned long a0 asm("a0") = (unsigned long)c;
    register unsigned long a7 asm("a7") = 0x01;  // SBI extension ID
    asm volatile ("ecall" : "+r"(a0) : "r"(a7) : "memory");
    return 0;
}
```

Each character traps from S-mode into OpenSBI's M-mode ecall handler,
which forwards the byte to the platform UART driver registered at OpenSBI
init time (`ntiny_uart_init` in `../linux/opensbi-platform/platform.c`).
The same code is reused unchanged from the Linux deployment — the SBI
contract abstracts away whether the supervisor is Linux or FreeRTOS.

The legacy direct-MMIO driver (sifive,uart0 register layout: `txdata`,
`rxdata`, `txctrl`, `rxctrl`, `div`) is preserved as comments at the top
of `uart.c` for reference if you ever need an M-mode bring-up path.

---

## Porting notes: what made this work on NTiny

The port targets RISC-V **S-mode** (most upstream FreeRTOS RISC-V ports
assume M-mode), uses the **Sstc** extension for tick scheduling, and
relies on OpenSBI for early delegation. Key decisions and gotchas:

1. **CSR aliases.** Everywhere upstream M-mode code uses `mstatus`,
   `mie`, `mip`, `mtvec`, `mepc`, `mcause`, this port uses the
   corresponding `s*` CSRs. Bit positions differ:
   * `mstatus.MIE` is bit 3 (mask `0x8`).
   * `sstatus.SIE` is bit **1** (mask `0x2`). The same value 8 in
     `sstatus` lands on a reserved bit — a copy-paste of the M-mode
     macros silently disables nothing. See `portmacro.h`.
2. **Tick source.** No M-mode CLINT writes; instead `port.c`
   programs `stimecmp/stimecmph` (Sstc CSRs `0x14D/0x15D`) directly,
   reading time from `time/timeh` (`0xC01/0xC81`). This needs
   `menvcfg.STCE=1` which OpenSBI sets at `final_init`.
3. **Trap delegation.** Set up by OpenSBI defaults — Supervisor Timer
   Interrupt (cause 5), Supervisor External Interrupt (cause 9, from
   PLIC context 1), and the standard exception set all reach S-mode.
4. **PLIC context.** Hart 0 S-mode context is **1** (M-mode is 0). The
   claim/complete register the FreeRTOS dispatcher uses is
   `0x0C201004`.
5. **Bare-metal toolchain.** The default Linux toolchain links `libc.so.6`
   dynamically; on bare metal the PLT/GOT is never resolved and
   `memset`/`memcpy` calls jump into garbage (PC ≈ `0x32` was our
   observed symptom). Cure: `-static -nostdlib -nostartfiles -lgcc` in
   LDFLAGS, no `GROUP(-lc -lgcc -lm)` in the linker script, and ship a
   minimal `memset`/`memcpy` in `init.c`.
6. **Context frame.** Single 32-slot frame: slots 0–30 hold `x1`–`x31`,
   slot 31 holds `sepc`. Save and restore must allocate/deallocate the
   *same* amount; the earlier two-frame allocate-but-only-pop-one variant
   leaked 128 bytes of task stack per tick.
7. **Critical sections.** `portDISABLE_INTERRUPTS`/`portENABLE_INTERRUPTS`
   gate `sstatus.SIE` (bit 1, mask `0x2`). `vPortSetInterruptMask` does
   `csrrw rd, sie, zero` to clear *all* S-mode interrupt enables.
8. **Stack handoff for new tasks.** `pxPortInitialiseStack` seeds slot 31
   with `pxCode` (the task entry sret-target), slot 9 with `pvParameters`
   (lands in `a0`), slot 0 with `prvTaskExitError` (a return-from-task
   trap), and slot 2 with the current `gp` so the new task starts with
   the same global pointer the boot code set up.

---

## Porting to a new board

The board-specific surface is small. Replicate
`FreeRTOS/Demo/RISC-V-NTINY-GCC/` and edit:

| File                | What to change                                                                                                                              |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| `link.ld`           | `MEMORY` ORIGIN/LENGTH for your DRAM and the offset above the OpenSBI payload (NTiny: `0x80400000`, 124 MiB).                                |
| `FreeRTOSConfig.h`  | `configCPU_CLOCK_HZ`, `configTICK_RATE_HZ`, `configTOTAL_HEAP_SIZE`. Update the CLINT base if you still expose it. Verify `configMAX_PRIORITIES` matches the demo. |
| `init.c`            | If the new SoC lacks Sstc, fall back to SBI `sbi_set_timer` ecalls (a7=0x00) in `port.c` and re-route timer interrupts through OpenSBI's emulation. |
| `port.c`            | PLIC base + S-mode claim/complete address (`PLIC_S_CLAIM_COMPLETE`). Update `external_interrupt_dispatcher` for your IRQ sources.            |
| `Makefile`          | `ISA`, `ABI`, `CROSS_COMPILE` if your toolchain triple differs. `OPENSBI_PLATFORM_DIR` if your board lives elsewhere.                       |
| OpenSBI platform    | Provide a `platform_ops` struct that sets `menvcfg.STCE` in `final_init` if you want Sstc; register your UART so SBI Console Putchar works. |
| Drivers             | Reuse `software/drivers/uart/uart.c` (SBI ecall) unmodified, or write a direct-MMIO UART if running without OpenSBI.                         |

Sanity checklist for a brand-new SoC:
1. Confirm DTS exposes `riscv,isa-extensions = "…sstc"` if you intend to
   use the Sstc path; otherwise switch the timer to ecall.
2. Confirm OpenSBI delegates supervisor exceptions/interrupts to S-mode
   (defaults already do; custom medeleg/mideleg overrides need review).
3. Confirm the testbench `priv_level` check for `tohost` matches where
   the test code actually runs — NTiny's testbench accepts S-mode
   (`priv_level == 2'b01`) writes for FreeRTOS termination.
4. Build with `make distclean && make`; if symbols like `memset@GLIBC`
   appear in `nm -u build/freertos.elf`, your LDFLAGS aren't forcing
   `-static -nostdlib` properly.
