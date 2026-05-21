# FreeRTOS on ntiny — S-mode under OpenSBI

This doc describes the port that lives at [software/freertos/](../software/freertos/):
a stock **FreeRTOS-Kernel V11.1.0** running in **S-mode** as the OpenSBI
payload on ntiny, with a tiny in-tree RISC-V port. It also walks through
the three real bugs we hit during bring-up, why each one fired, and how
we fixed it — so the next person porting a different RTOS doesn't relearn
them the hard way.

---

## 1. Why "S-mode under OpenSBI"?

Three reasons drove the priv-mode choice:

1. **OpenSBI is already the firmware contract on this SoC.** Linux uses
   it, and the platform code in [software/linux/opensbi-platform/](../software/linux/opensbi-platform/)
   already initialises the UART, the ACLINT MTIMER / MSWI, the PLIC,
   and `menvcfgh` (Svadu + Sstc). Building a second M-mode firmware
   path just for FreeRTOS would duplicate all of that.

2. **S-mode is the natural place for OS workloads on a CPU with an
   MMU.** Even when the RTOS itself doesn't use the MMU, running it
   in S-mode keeps M-mode reserved for the firmware contract and
   leaves the door open for U-mode tasks later.

3. **Sstc gives us a cheap tick.** ntiny implements supervisor timer
   compare (`stimecmp` / `stimecmph`), so the scheduler tick is a
   single CSR write from S-mode — no SBI ecall per tick.

The trade-off: the upstream FreeRTOS RISC-V port at
`portable/GCC/RISC-V/` is hardwired to M-mode (`mret`, `mcause`,
`mscratch`, CLINT MTIME polling). We don't use it. Instead, we ship a
~300-line in-tree port that uses the S-mode CSR set throughout.

---

## 2. Architecture

```
        +-----------------------+   M-mode
        |   OpenSBI v1.8        |    @ 0x80000000
        |   - UART cold init    |
        |   - menvcfgh.STCE=1   |
        |   - PLIC, ACLINT      |
        |   - Default deleg.    |
        +-----------+-----------+
                    | sret, MPP=S, a0=hartid, a1=fdt
                    v
        +-----------------------+   S-mode
        |   FreeRTOS payload    |    @ 0x80400000
        |   - boot.S (stvec,sp) |
        |   - main()            |
        |   - vTaskStartScheduler
        |   - 2x task @ UART    |
        +-----------------------+
                ^      ^
                |      |
       Sstc tick      SSIP yield
       (stimecmp)     (csrsi sip,2)
```

* **Tick source:** Sstc. `port.c::write_stimecmp64` writes
  `mtime + (CPU_HZ / TICK_HZ)` into `stimecmp` after every tick. The
  hardware comparator drives `mip.STIP`, which surfaces as scause=5
  in S-mode.
* **Yield:** `portYIELD()` self-pends `sip.SSIP` (`csrsi sip, 2`). The
  trap handler clears it and calls `vTaskSwitchContext()`.
* **Console:** Direct MMIO to the sifive,uart0 at `0x10000000`.
  OpenSBI's `ntiny_early_init()` already programmed `UART_DIV`,
  `TXCTRL.txen`, and `RXCTRL.rxen` before the mode switch, so the
  payload only has to poll `TXDATA.full` and store bytes.
* **Trap path:** `stvec → freertos_risc_v_trap_handler` in
  [portASM.S](../software/freertos/port/portASM.S). 30 GP registers
  + `sepc` + `sstatus` are pushed to the task stack, control passes
  to `freertos_trap_dispatch` in C, which decodes `scause` and either
  re-arms `stimecmp` (timer) or clears SSIP (yield), then optionally
  calls `vTaskSwitchContext()`. The asm tail reloads `sp` from the
  (possibly new) `pxCurrentTCB->pxTopOfStack` and `sret`s.

The full file layout:

```
software/freertos/
├── Makefile                       # clone / build / run targets
├── README.md                      # quick start
├── port/
│   ├── FreeRTOSConfig.h           # tick rate, heap, static allocation
│   ├── portmacro.h                # types + yield / critical macros
│   ├── port.c                     # pxPortInitialiseStack, scheduler,
│   │                              #   trap dispatch (Sstc + SSIP)
│   ├── portASM.S                  # trap entry/exit + xPortStartFirstTask
│   ├── boot.S                     # S-mode _start after OpenSBI sret
│   ├── link.ld                    # payload at 0x80400000
│   ├── ntiny_uart.[ch]            # direct MMIO console
│   └── libstubs.c                 # memset / memcpy / strlen (no newlib)
└── app/
    └── main.c                     # two-task UART hello demo
```

---

## 3. Build pipeline

OpenSBI is re-used from `software/linux/opensbi-platform/`; only
`FW_PAYLOAD_PATH` differs. The full chain:

```
freertos.elf  ← gcc + portASM.S + port.c + tasks.c/queue.c/list.c/heap_4.c
freertos.bin  ← objcopy -O binary
fw_payload.bin← make -C opensbi PLATFORM_DIR=... FW_PAYLOAD_PATH=freertos.bin
ram.hex       ← hex_text.py fw_payload.bin
verilator run ← run_linux.sh now honours OPENSBI_BIN env override
```

Two toolchains are involved:

| Half        | Toolchain                                  | Why                                                                                       |
|-------------|--------------------------------------------|-------------------------------------------------------------------------------------------|
| FreeRTOS    | `/opt/riscv-elf/bin/riscv64-unknown-elf-`  | Bare-metal flat S-mode image, no PIE needed                                               |
| OpenSBI     | `/opt/riscv-linux-gnu/bin/riscv64-unknown-linux-gnu-` | OpenSBI's top-level Makefile requires `-pie`; the bundled `riscv-elf` ld doesn't support it |

This split mirrors what the Linux flow already does.

---

## 4. Bugs we hit (and what they taught us)

Three real bugs surfaced during bring-up. None were FreeRTOS-specific;
each is a generic gotcha for "OS in S-mode on a small RISC-V SoC."

### 4.1 `undefined reference to memset` at link time

**Symptom**

```
.../tasks.c:1287: undefined reference to `memset'
collect2: error: ld returned 1 exit status
```

**Cause**

We link with `-nostdlib` to avoid pulling newlib into a freestanding
kernel. FreeRTOS's `prvCreateStaticTask` (and other paths) call
`memset` / `memcpy` to zero TCBs and stacks; without `-lc` the symbols
don't resolve.

**Fix**

A tiny [`libstubs.c`](../software/freertos/port/libstubs.c) providing
`memset`, `memcpy`, `memmove`, `memcmp`, `strlen` — under 30 lines,
zero dependencies. Added to `PORT_SRCS` in the Makefile.

**Lesson**

`-nostdlib` is the right default for a kernel, but the moment kernel
code does field init via `memset(&tcb, 0, sizeof tcb)`, you owe the
toolchain a minimal libc surface. Don't reach for newlib — it pulls
in `_sbrk`, `_write`, and friends, and you'll spend longer stubbing
those out than just writing five mem ops.

### 4.2 OpenSBI fails to build: "linker does not support PIE"

**Symptom**

```
Makefile:213: *** Your linker does not support creating PIEs,
                  opensbi requires this..  Stop.
```

after switching the OpenSBI build to `riscv64-unknown-elf-`.

**Cause**

OpenSBI must build as a position-independent executable (it relocates
itself based on where the bootloader loads it). The
`/opt/riscv-elf` ld in this environment doesn't advertise PIE
support; the `/opt/riscv-linux-gnu` ld does.

**Fix**

Keep `/opt/riscv-elf` for the FreeRTOS payload (flat link at
`0x80400000`, no relocation needed) and use `/opt/riscv-linux-gnu`
for OpenSBI — same as the Linux flow already does. The split is
explicit in the [Makefile](../software/freertos/Makefile):

```make
TOOLCHAIN_BIN ?= $(TOOLCHAIN_ELF)         # FreeRTOS itself
OPENSBI_CROSS := $(TOOLCHAIN_LINUX)/riscv64-unknown-linux-gnu-
```

**Lesson**

Toolchain capability is a function of how the toolchain was *built*,
not just the target triple. If you're consolidating to one toolchain
for cleanliness, check that it handles every link mode you need
(PIE, static-pie, relro) before flipping the switch.

### 4.3 First trap fired: `scause=2, sepc=0x80400b60, stval=0x14e79073`

**Symptom**

```
[FreeRTOS] starting scheduler
[FreeRTOS] unhandled S-mode trap: scause=0x00000002 sepc=0x80400b60 stval=0x14e79073
```

**Diagnosis**

`scause=2` is `Illegal instruction`. `stval` on an illegal-instruction
trap holds the offending instruction word. Decoding `0x14e79073`:

| Bits         | Value | Meaning              |
|--------------|-------|----------------------|
| `[6:0]`      | `0x73`| `SYSTEM` opcode      |
| `[14:12]`   | `0x1` | `CSRRW`              |
| `[19:15]`   | `0xF` | `rs1 = x15` (a5)     |
| `[31:20]`   | `0x14E`| CSR address          |
| `[11:7]`    | `0`   | `rd = x0` (discarded)|

So `csrw 0x14E, a5`. We were trying to write `stimecmph` to set up
the first scheduler tick.

The Sstc spec assigns:

* `stimecmp`  = `0x14D`
* `stimecmph` = **`0x15D`** (NOT `0x14E`)

The `0x14E` slot is unallocated — any write to it traps illegal-
instruction in any mode. The ntiny csr_unit comments confirm both
addresses ([csr_unit.sv:401](../design/core/csr_unit/src/csr_unit.sv#L401)).
The bug was a pure typo in `port.c::write_stimecmp64`.

For a moment we suspected the trap meant `menvcfg.STCE` wasn't set
and S-mode wasn't allowed to touch `stimecmp` at all. That hypothesis
turned out to be wrong — ntiny's csr_unit explicitly *doesn't* gate
S-mode `stimecmp` access on STCE (see the comment at
[csr_unit.sv:404-407](../design/core/csr_unit/src/csr_unit.sv#L404-L407)):

> Permission gate (menvcfg.STCE) is enforced at the kernel/SBI level —
> we don't trap S-mode access when STCE=0 (a benign deviation: software
> just sees the value it wrote, no IRQ until STCE flips).

So an illegal-instruction trap on `csrw 0x14X` here is *never* an
STCE issue — it's always a CSR-address-decoding miss.

**Fix**

Change the address in `write_stimecmp64`:

```diff
-__asm volatile ( "csrw 0x14E, %0" :: "r"( hi ) );
+__asm volatile ( "csrw 0x15D, %0" :: "r"( hi ) );
```

**Lesson**

When you get `scause=2` on a CSR access, decode `stval` first. The
instruction word tells you the exact CSR address that was rejected —
no need to guess between "wrong CSR" and "denied access" until you've
looked at the bits. And the `0x14X` / `0x15X` swap for the `*h`
high-half of every Sstc-family CSR is a classic transcription error.

### 4.4 Second trap fired: `scause=1, sepc=0x32, stval=0x32`

**Symptom**

After fixing 4.3:

```
[FreeRTOS] starting scheduler
[FreeRTOS] unhandled S-mode trap: scause=0x00000001 sepc=0x00000032 stval=0x00000032
```

**Diagnosis**

`scause=1` is `Instruction access fault`. `sepc=0x32` means the CPU
tried to fetch from low memory — well outside the FreeRTOS image
(which starts at `0x80400000`). The trap fired immediately after
`vTaskStartScheduler() → xPortStartScheduler() → xPortStartFirstTask()`
ran its `sret`.

That tells us `sret` loaded `sepc=0x32` from the initial task frame.
`pxPortInitialiseStack` is responsible for that frame. So the bug is
between `pxPortInitialiseStack` and the asm restore code: one of them
is reading from a different slot than the other writes to.

The frame defined in `portASM.S` is:

```
sp+0    x1  (ra)        sp+56   x18 (s2)
sp+4    x5  (t0)        ...
sp+8    x6  (t1)        sp+92   x27 (s11)
sp+12   x7  (t2)        sp+96   x28 (t3)
sp+16   x8  (s0/fp)     sp+100  x29 (t4)
sp+20   x9  (s1)        sp+104  x30 (t5)
sp+24   x10 (a0)        sp+108  x31 (t6)
sp+28   x11 (a1)        sp+112  sepc      <-- 28 words in
...                     sp+116  sstatus   <-- 29 words in
sp+52   x17 (a7)        sp+120  pad
                        sp+124  pad
```

30 GPRs (skipping x0/x2/x3/x4 — sp is implicit, gp/tp aren't saved)
plus `sepc` and `sstatus` = 32 words of slot space; only the first
30 are populated. Frame is 128 bytes (16-byte aligned).

The C side had:

```c
#define FRAME_WORDS 32
...
sp[ 30 ] = ( StackType_t ) pxCode;   /* sepc — WRONG */
sp[ 31 ] = ( StackType_t )( SSTATUS_SPP | SSTATUS_SPIE );
```

The asm reads `sepc` from `sp+112` = word index 28. The C wrote
`pxCode` into word index 30 = `sp+120`, which the asm never reads.
So `sret` loaded sepc from a zero-initialised slot, jumped to 0,
fetched instruction at PC=0 (or, after IALIGN, 0x32 — the first
valid instruction the imem returned).

**Fix**

Replace the hardcoded indices with named constants that match the
asm:

```c
#define FRAME_IDX_A0        6
#define FRAME_IDX_SEPC      28
#define FRAME_IDX_SSTATUS   29

sp[ 0 ]                  = ( StackType_t ) portTaskExitError;
sp[ FRAME_IDX_A0 ]       = ( StackType_t ) pvParameters;
sp[ FRAME_IDX_SEPC ]     = ( StackType_t ) pxCode;
sp[ FRAME_IDX_SSTATUS ]  = ( StackType_t )( SSTATUS_SPP | SSTATUS_SPIE );
```

**Lesson**

The trap-frame layout is a contract between two files written in
different languages (asm + C). If you can't make one the
single-source-of-truth, at *least* express the offsets in both files
in terms of named constants — never hardcoded literals — so a
mismatch shows up at compile time, not as a mysterious jump to
`sepc=0x32`.

---

## 5. Verification

With both fixes in place, the boot log shows:

```
OpenSBI v1.8
  ...
Domain0 Next Address        : 0x80400000
Domain0 Next Mode           : S-mode
Boot HART ISA Extensions    : sstc,zicntr,sdtrig
Boot HART MIDELEG           : 0x00000222
Boot HART MEDELEG           : 0x0004b109

[FreeRTOS] ntiny S-mode demo starting...
[FreeRTOS] starting scheduler
task B: tick 0
task A: tick 0
task B: tick 1
task A: tick 1
...
```

The fact that we get `tick 1` from both tasks proves end-to-end
correctness:

* `xPortStartFirstTask` correctly `sret`-ed into the first task.
* The first task ran, called `vTaskDelay`, which suspended it via
  `portYIELD` (SSIP self-pend).
* The trap handler entered, decoded `scause=1` (S-mode software),
  cleared `sip.SSIP`, picked the other task via `vTaskSwitchContext`,
  and `sret`-ed cleanly.
* `stimecmp` re-arm worked; the supervisor timer interrupt
  (`scause=5`) fired on the next tick window, `xTaskIncrementTick`
  ran, the delay queue released the original task, and round-robin
  resumed.

---

## 6. What we did *not* do

A few deliberate non-features worth flagging:

* **No PLIC handling in FreeRTOS.** The trap dispatch treats `scause=9`
  (S-mode external) as a spurious wake-up. Adding it is a one-liner if
  you wire a real peripheral interrupt later — read `plic.claim`,
  dispatch by source ID, write `plic.complete`.
* **No FP state in the trap frame.** We compile with `-mabi=ilp32f`
  to match the elf multilib, but the demo doesn't touch FP and we
  don't save/restore `f0..f31` / `fcsr` across context switches. If a
  task uses floats, FP state will leak between tasks. Add it
  conditionally on `configUSE_TASK_FPU_SUPPORT` if needed.
* **No FreeRTOS-Kernel patches.** The kernel sources are used
  verbatim; everything S-mode-specific lives in `port/`. This keeps
  re-clones / version bumps trivial — just bump `FREERTOS_TAG` in
  the Makefile.

---

## 7. Reproducing the build

```bash
cd software/freertos
make prepare    # one-time: clones FreeRTOS-Kernel V11.1.0 + OpenSBI v1.8
make run        # builds freertos.bin + fw_payload.bin + ram.hex, launches sim
tail -f ../../flows/simulation/logs/uart.log
```

If the demo ever stops printing past `tick 0`, the first thing to
check is whether the *next* `stimecmp` re-arm happened: temporarily
add a UART putc in `freertos_trap_dispatch` on the timer path.
