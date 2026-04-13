# ntiny Linux

Linux v6.6 boots on ntiny RV32IMAC (Sv32 MMU, single hart).
Chain: OpenSBI v1.8 → Linux → busybox initramfs → Verilator sim.

## Quick start

```bash
make prepare      # clone Linux/OpenSBI, apply patches, install defconfig
make build        # kernel + opensbi + ram.hex
make run          # launch sim; watch with: tail -f flows/simulation/uart.log
```

## Repos

| Repo | Version | Purpose |
|------|---------|---------|
| Linux | v6.6 | kernel (~/Downloads/linux) |
| OpenSBI | v1.8 | M-mode firmware (~/Downloads/opensbi) |

Toolchain: `riscv32-unknown-linux-gnu-*` at `/opt/riscv-linux/bin`.

## Kernel patches (14 lines, 3 files)

`patches/0001-ntiny-kernel-required.patch`:
1. `arch/riscv/boot/dts/Makefile` — add ntiny subdir
2. `arch/riscv/kernel/head.S` — init `TASK_TI_KERNEL_SP` for early-boot traps
3. `arch/riscv/kernel/cpufeature.c` — disable `check_unaligned_access` (jiffies timing issue)

## Hardware map

| Resource | Address | Notes |
|----------|---------|-------|
| RAM | 0x80000000 × 128 MiB | |
| CLINT | 0x02000000 | mtime @ 50 MHz |
| PLIC | 0x0C000000 | 6 sources |
| UART | 0x10000000 | TX @ +4 |
| Console | earlycon=sbi console=hvc0 | |

## Files

```
ntiny.dts / ntiny.dtb          device tree
ntiny_defconfig                 18-line kernel config
initramfs.cpio                  uncompressed busybox rootfs
initramfs_src/                  minimal hand-built init (for quick tests)
opensbi-platform/               ntiny SBI platform stub
patches/                        kernel patches
Makefile                        build automation
```
