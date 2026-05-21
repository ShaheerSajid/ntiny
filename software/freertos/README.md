# ntiny FreeRTOS (S-mode under OpenSBI)

FreeRTOS V11.1.0 running in **S-mode** as the OpenSBI payload on
ntiny. OpenSBI stays in M-mode and provides delegation +
menvcfgh setup (Sstc, Svadu); FreeRTOS runs in S-mode and uses:

* **Sstc** (`stimecmp` CSR) for the scheduler tick — no SBI ecall
  per tick.
* **`sip.SSIP`** self-set for `portYIELD()`.
* **Direct MMIO** to the sifive,uart0 at `0x10000000` for `printf`
  output (OpenSBI's `ntiny_early_init` already configured div/txen).

## Quick start

```bash
cd software/freertos
make prepare      # one-time: clones FreeRTOS-Kernel + OpenSBI
make run          # build everything + launch verilator
tail -f ../../flows/simulation/logs/uart.log
```

Expected output:

```
[FreeRTOS] ntiny S-mode demo starting...
[FreeRTOS] starting scheduler
task A: tick 0
task B: tick 0
task A: tick 1
task B: tick 1
...
```

## Layout

```
software/freertos/
├── Makefile         # clone / build / run targets
├── port/
│   ├── FreeRTOSConfig.h           # tick rate, heap, static alloc
│   ├── portmacro.h                # types + yield / critical macros
│   ├── port.c                     # pxPortInitialiseStack, scheduler,
│   │                              # trap dispatch (Sstc + SSIP)
│   ├── portASM.S                  # trap entry/exit, xPortStartFirstTask
│   ├── boot.S                     # S-mode _start (from OpenSBI sret)
│   ├── link.ld                    # payload at 0x80400000
│   ├── ntiny_uart.h
│   └── ntiny_uart.c               # direct MMIO console
├── app/
│   └── main.c                     # two-task UART hello demo
└── external/                      # cloned FreeRTOS-Kernel + OpenSBI
```

The OpenSBI build reuses `software/linux/opensbi-platform/`; only
the `FW_PAYLOAD_PATH` changes (FreeRTOS bin instead of Linux Image).

## Toolchain

* FreeRTOS itself: `/opt/riscv-elf/bin/riscv64-unknown-elf-gcc`
  (`rv32imafc_zicsr_zaamo_zalrsc_zba_zbb_zbc_zbs`, `ilp32f`).
* OpenSBI: `/opt/riscv-linux-gnu/bin/riscv64-unknown-linux-gnu-gcc`
  (matches the Linux flow).

Both paths live in `.env`; override `TOOLCHAIN_BIN=...` on the
make line to point elsewhere.
