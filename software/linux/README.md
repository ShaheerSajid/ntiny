# ntiny Linux Boot

Build chain: Buildroot rootfs → Linux kernel → OpenSBI (FW_PAYLOAD) → ram.hex → Verilator sim.

## Prerequisites

- **riscv32-unknown-linux-gnu-** toolchain at `/opt/riscv-linux/bin`
- **OpenSBI v1.8.1** source at `~/Downloads/opensbi`
- **Linux v6.6** source at `~/Downloads/linux`
- **Buildroot** rootfs: `initramfs.cpio.gz` (pre-built, checked in)

## 1. Build Linux Kernel

```bash
cd ~/Downloads/linux
cp /path/to/ntiny/software/linux/ntiny_defconfig .config
export PATH=/opt/riscv-linux/bin:$PATH
make ARCH=riscv CROSS_COMPILE=riscv32-unknown-linux-gnu- olddefconfig
make ARCH=riscv CROSS_COMPILE=riscv32-unknown-linux-gnu- -j$(nproc)
```

Output: `arch/riscv/boot/Image`

## 2. Build Device Tree

```bash
dtc -I dts -O dtb -o ntiny.dtb ntiny.dts
```

## 3. Build OpenSBI (with ntiny platform + kernel payload)

```bash
cd ~/Downloads/opensbi
make clean
export PATH=/opt/riscv-linux/bin:$PATH
make CROSS_COMPILE=riscv32-unknown-linux-gnu- \
     PLATFORM_DIR=/path/to/ntiny/software/linux/opensbi-platform \
     PLATFORM_RISCV_XLEN=32 \
     PLATFORM_RISCV_ISA=rv32imac_zicsr_zifencei \
     PLATFORM_RISCV_ABI=ilp32 \
     FW_PAYLOAD_PATH=~/Downloads/linux/arch/riscv/boot/Image \
     FW_FDT_PATH=/path/to/ntiny/software/linux/ntiny.dtb \
     -j$(nproc)
```

Output: `build/platform/opensbi-platform/firmware/fw_payload.bin`

**Important:** Use `PLATFORM_DIR=` pointing to our custom ntiny platform, NOT `PLATFORM=generic`. The generic platform doesn't recognize our custom UART (`ntiny,uart`).

## 4. Generate ram.hex and Simulate

```bash
cd /path/to/ntiny/flows/simulation
python3 ../../software/tools/hex_text.py \
    ~/Downloads/opensbi/build/platform/opensbi-platform/firmware/fw_payload.bin ram.hex

# Build Verilator model (128MB RAM for Linux)
verilator [flags] +define+RAM_SIZE_BYTES=134217728 ...
make -j$(nproc) -C obj_dir/ -f Vtb_soc_top.mk Vtb_soc_top
cp obj_dir/Vtb_soc_top ./

# Run
./Vtb_soc_top --timeout 500000000
# Monitor: tail -f uart.log
```

## Hardware Configuration

- **RAM**: 128MB at 0x80000000 (mem_map.json `linux` profile)
- **CLINT**: 0x02000000 (mtime @ 50MHz)
- **PLIC**: 0x0C000000 (6 sources)
- **UART**: 0x10000000 (custom ntiny UART)
- **Boot**: OpenSBI at 0x80000000 (M-mode) → Linux at 0x80400000 (S-mode)
- **Console**: `earlycon=sbi console=hvc0`

## Kernel Config Notes

Disable expensive debug options for faster simulation:
- `CONFIG_DEBUG_VM_PGTABLE=n` (SHA3 crypto at boot, millions of cycles)
- `CONFIG_DEBUG_PAGEALLOC=n`
- `CONFIG_SLUB_DEBUG=n`
