# ntiny Linux

Linux v6.6 boots on ntiny RV32IMAC (Sv32 MMU, single hart).
Chain: OpenSBI v1.8 → Linux 6.6 → busybox initramfs → Verilator sim.

## Quick start

```bash
make prepare      # one-time: clones Linux + OpenSBI into ./external/, applies patches
make build        # rebuild kernel + opensbi + ram.hex (force-fresh, see below)
make run          # launch sim; tail flows/simulation/uart.log
```

`make build` always force-removes the kernel `Image` and OpenSBI `fw_payload.bin`
before rebuilding. This is intentional — kbuild's own dependency tracking does
**not** see `initramfs.cpio` as a kernel input, so without the force-rm a
changed cpio won't be re-embedded. Costs ~30 s on incremental rebuilds.

## Layout

```
software/linux/
├── Makefile                          build automation (start here)
├── README.md
├── ntiny.dts                         device tree source
├── ntiny_defconfig                   kernel config (~20 lines, the rest defaults)
├── initramfs.cpio                    busybox rootfs (uncompressed cpio newc)
├── patches/
│   ├── 0001-ntiny-kernel-required.patch    (3 files, 14 lines — required for boot)
│   └── ntiny-dts-Makefile                  (DTS subdir Makefile)
├── opensbi-platform/                 ntiny SBI platform stub
└── external/                         (gitignored) Linux + OpenSBI clones
    ├── linux/
    └── opensbi/
```

Override clone locations via env if you want to share trees across projects:

```bash
make LINUX_DIR=/path/to/linux OPENSBI_DIR=/path/to/opensbi prepare
```

## Required toolchain

`riscv32-unknown-linux-gnu-*` at `/opt/riscv-linux/bin` (override with
`TOOLCHAIN_BIN=/...`). Anything bunldled with `glibc` or `musl` ABI works,
must be `ilp32` (not `ilp32f`).

## Kernel patches

`patches/0001-ntiny-kernel-required.patch` (3 files, 14 lines):

| File | Change | Why |
|------|--------|-----|
| `arch/riscv/boot/dts/Makefile` | `subdir-y += ntiny` | wire DTS into kbuild |
| `arch/riscv/kernel/head.S` | `REG_S sp, TASK_TI_KERNEL_SP(tp)` after early stack setup | early-boot S-mode trap handler reads stale `kernel_sp` and corrupts the trap frame; this initializes it before any trap can fire |
| `arch/riscv/kernel/cpufeature.c` | comment out `arch_initcall(check_unaligned_access_boot_cpu)` | the per-cpu probe spins on a jiffies tick that's not yet reliably serviced by our SBI timer chain at this initcall stage |

These are compiled-in (no module support); `make apply-patches` applies them
idempotently and is also re-runnable any time you suspect `.config` got reset.

## Hardware map (must match `ntiny.dts`)

| Resource | Address | Notes |
|----------|---------|-------|
| RAM | `0x80000000` × 128 MiB | OpenSBI at `0x80000000`, kernel at `0x80400000` |
| CLINT | `0x02000000` | mtime @ 50 MHz |
| PLIC | `0x0c000000` | 6 sources |
| UART | `0x10000000` | TX at `+0x4` |
| Console | `earlycon=sbi console=hvc0` | from kernel cmdline |

## Make targets

| Target | Action |
|--------|--------|
| `prepare` | clone Linux + OpenSBI under `external/`, apply patches, install defconfig |
| `build` (= `rebuild`) | force-rebuild kernel + opensbi + `ram.hex` |
| `run` | launch verilator sim and tail `uart.log` |
| `apply-patches` | re-run patch + defconfig install (use if `.config` looks wrong) |
| `clean` | remove `ntiny.dtb` and `flows/simulation/ram.hex` |
| `distclean` | also `mrproper` Linux and `make clean` OpenSBI |
| `wipe` | nuke the entire `external/` tree |

## Troubleshooting

The build picked up a few foot-guns over time. If something's off, try in order:

1. **Linux banner shows but kernel hangs immediately, or Image is suspiciously
   large (~21 MiB) yet nothing boots.** Likely `.config` got reset to RV64
   defaults. Re-run `make apply-patches` then `make build`. Verify with
   `file external/linux/vmlinux` — must say `ELF 32-bit LSB executable, UCB RISC-V`.

2. **`undefined reference to __initramfs_size` during link.**
   `external/linux/usr/initramfs_data.S` got nuked by an over-zealous clean.
   `make apply-patches` restores it from git automatically; if you skipped
   that, run `cd external/linux && git checkout HEAD -- usr/initramfs_data.S`.

3. **Boot is silent — no initcall lines, no debug output.** The cmdline in
   `ntiny_defconfig` should include `loglevel=8 ignore_loglevel debug
   initcall_debug`. Confirm with `grep CMDLINE external/linux/.config`.

4. **You changed `initramfs.cpio` but the new cpio isn't in the boot.**
   Always use `make build` (it force-rms the Image first). A bare `make`
   inside `external/linux` won't know the cpio changed and will keep the
   stale embedded copy.

5. **CRLF noise in `uart.log` (`^M` at line ends).** OpenSBI/Linux emit
   `\r\n` for terminal-friendly output; the testbench logs every TX byte
   raw. Run `dos2unix uart.log` or `tr -d '\r' < uart.log` to strip.

6. **Stale config after pulling new ntiny commits.** If `ntiny_defconfig`
   changed, `make apply-patches && make build` re-installs it.

## Known userspace issue (not a HW bug)

`busybox-1.37.0` ash hits "/init: line 14: bad for loop variable" when
parsing the buildroot stock `/init` script. Diagnosed to a parser-state
corruption inside ash (lasttoken=TFOR set spuriously) — see
`memory/project_busybox_ash_parse_error.md` in the auto-memory store.
Workaround: write a C-binary `/init` and pack a custom cpio.
