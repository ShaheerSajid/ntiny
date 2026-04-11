# ntiny Linux

Linux fully boots on the ntiny RV32IMAC SoC (Sv32 MMU, single hart, custom UART).
Toolchain: OpenSBI v1.8 → Linux v6.6 → Buildroot busybox initramfs → Verilator sim.

## Quick start

```bash
cd software/linux
make prepare      # one-time: clone Linux/OpenSBI, apply ntiny patches
make build        # rebuild kernel + opensbi + ram.hex (run after RTL changes)
make run          # launch the verilator sim and stream uart.log
```

`make run` expects `flows/simulation/Vtb_soc_top` to exist (built separately by
the verilator flow). Output goes to `flows/simulation/uart.log`.

## Repos and versions

The Linux build pulls in three external repos. They live in `~/Downloads/`
by default; override with `LINUX_DIR=` / `OPENSBI_DIR=` / `BUILDROOT_DIR=`.

| Repo       | Version  | URL                                                | Required for       |
| ---        | ---      | ---                                                | ---                |
| Linux      | v6.6     | https://github.com/torvalds/linux                  | kernel image       |
| OpenSBI    | v1.8     | https://github.com/riscv-software-src/opensbi      | M-mode firmware    |
| Buildroot  | 2024.02  | https://gitlab.com/buildroot.org/buildroot         | initramfs (one-off)|

`make prepare` clones all three at the right tags, copies the ntiny
device tree into the kernel, and applies `patches/0001-ntiny-kernel-required.patch`.

You also need the `riscv32-unknown-linux-gnu-` toolchain at
`/opt/riscv-linux/bin` (or set `CROSS_COMPILE=` and `PATH` accordingly).

## What's in this directory

```
ntiny.dts                       device tree source for the ntiny SoC
ntiny.dtb                       compiled DTB (rebuilt by `make`)
ntiny_defconfig                 18-line minimal kernel config diff (saved
                                via `make savedefconfig`)
initramfs.cpio                  uncompressed buildroot rootfs (busybox
                                + /dev/console). Used directly by the
                                kernel build to skip gzip decompression
                                at boot (millions of sim cycles saved).
initramfs.cpio.gz               gzipped fallback (kept for reference)
initramfs_src/                  example: minimal hand-built init.c +
                                cpio_list spec for `gen_init_cpio`,
                                used during the bring-up
opensbi-platform/               ntiny platform stub for OpenSBI
                                (UART driver + addresses)
patches/                        kernel patches applied by `make prepare`
Makefile                        clone-and-build automation
README.md                       this file
```

## What the kernel patches do

There are exactly **two** required hunks (`patches/0001-ntiny-kernel-required.patch`),
totalling 7 lines of kernel changes:

1. `arch/riscv/boot/dts/Makefile` — adds `subdir-y += ntiny` so the build
   picks up our DTS subdir.
2. `arch/riscv/kernel/head.S` — initializes `kernel_sp` (the
   `TASK_TI_KERNEL_SP` slot in `init_task`'s thread_info) at the very
   start of the boot path.

The kernel_sp init is critical: without it, the very first S-mode trap
handler runs `lw sp, 8(tp)`, gets a stale value, and writes the trap
frame on top of the live kernel stack — corrupting saved registers
before the first context switch.

In addition, `make prepare` copies `arch/riscv/boot/dts/ntiny/ntiny.dts`
+ `Makefile` into the kernel tree (these are untracked files in the
upstream tree, not patches).

## Hardware configuration the kernel sees

| Resource | Address                  | Notes                          |
| ---      | ---                      | ---                            |
| RAM      | `0x80000000` × 128 MiB   | flat physical memory           |
| CLINT    | `0x02000000`             | mtime @ 50 MHz, MSIP, MTIP     |
| PLIC     | `0x0C000000`             | 6 external IRQ sources         |
| UART     | `0x10000000`             | custom `ntiny,uart` (TX @ +4)  |
| Boot     | OpenSBI @ 0x80000000     | M-mode, jumps to S-mode        |
| Kernel   | linked at 0x80400000     | OpenSBI `FW_PAYLOAD_OFFSET`    |
| FDT      | embedded via `BUILTIN_DTB` | RV32 sv32 fixmap fallback    |
| Console  | `earlycon=sbi console=hvc0` | both routed via SBI putc    |

## Boot expected output

After `make run`, you should see:

```
OpenSBI v1.8.1-...
   ____                    _____ ____ _____
  / __ \                  / ____|  _ \_   _|
 ...
Boot HART Base ISA          : rv32imac
Boot HART ISA Extensions    : zicntr
...
Linux version 6.6.0-... (...) #N
OF: fdt: Ignoring memory range 0x80000000 - 0x80400000
Machine model: ntiny RISC-V SoC
Forcing kernel command line to: earlycon=sbi console=hvc0
SBI specification v3.0 detected
...
Run /init as init process
Starting syslogd: OK
Starting klogd: OK
Welcome to Buildroot
buildroot login:
```

After login (root, no password), you have a busybox shell on the SoC.

## Faster bring-up: minimal init

For quick boot smoke tests (no shell, no buildroot), point
`CONFIG_INITRAMFS_SOURCE` at `initramfs_src/` after building it via
`gen_init_cpio` — the binary is 1.5KB and the cpio is 2.5KB. See
`initramfs_src/cpio_list` and `initramfs_src/init.c`. The kernel boot
path is identical, just no userspace beyond an `nanosleep` loop.

## Troubleshooting

- **`Warning: unable to open an initial console.`** — your initramfs
  doesn't have a `/dev/console` character device node (mode 0600,
  major 5, minor 1). Either rebuild the cpio with `gen_init_cpio`
  (which can create device nodes from a spec file even without root)
  or use the prebuilt `initramfs.cpio`.
- **kernel hangs at `paging_init`** — make sure your core has the
  fetch-revamp Phase 4.13 + 4.13b commits. Earlier RTL deadlocks when
  the producer is held at a half-aligned deferred-redirect target
  (e.g., the `lui a0, 0x9dbfe` after `local_flush_tlb_page`).
- **`Run /init as init process`** then `Kernel panic: Attempted to kill
  init!`** — the cpio's `/init` exited. Either it's the minimal stub
  (which `exit(1)`s) or it tried to exec a missing shell. Use the
  buildroot `initramfs.cpio` instead.

## See also

- `flows/simulation/testbench/tb_soc_top.v` — TB UART capture (writes
  TX bytes both to `uart.log` and to stdout for live boot watching).
- `opensbi-platform/platform.c` — ntiny SBI platform driver.
