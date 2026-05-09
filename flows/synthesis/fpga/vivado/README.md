# ntiny Vivado flows

Vivado projects for putting ntiny on Xilinx silicon. One subdir
per target board. Lives next to the Quartus tree at
`flows/synthesis/fpga/quartus/`.

## Targets

| Dir                 | Board       | Part              | Vivado  | Status   |
|---------------------|-------------|-------------------|---------|----------|
| `zybo_z7_10/`       | Zybo Z7-10  | XC7Z010-1CLG400C  | 2020.1  | skeleton |

## Zybo Z7-10 — quick start

PL-only skeleton: ntiny core + on-chip BRAM (`ram_dp.sv` infers as
BRAM). No PS, no DDR — bare-metal demos only. Linux-on-FPGA needs
the AXI4 master from bus revamp Phase 3 to talk to PS DDR via
AXI HP, and is parked until that lands.

```
cd flows/synthesis/fpga/vivado/zybo_z7_10
/tools/xilinx/Vivado/2020.1/bin/vivado -mode batch -source create_project.tcl
```

Then either open `project_dir/ntiny_zybo_z7_10.xpr` in the GUI, or
keep running headless:

```
/tools/xilinx/Vivado/2020.1/bin/vivado -mode batch \
    -source - <<'EOF'
open_project project_dir/ntiny_zybo_z7_10.xpr
launch_runs synth_1 -to_step write_bitstream -jobs 8
wait_on_run synth_1
EOF
```

### Firmware

`ram_dp.sv` initialises BRAM from `ram.hex` at synth time. Drop a
baremetal image at `zybo_z7_10/firmware/ram.hex` before launching
synth — same hex format that the simulator's `ram.hex`
uses (see `software/tools/hex_text.py`).

The default `RAM_SIZE_BYTES` in `design/common/mem_map.svh`
(32 KB) fits comfortably in Z7-10 BRAM. Larger images need a
matching `RAM_SIZE_BYTES` override and enough BRAM tiles —
Z7-10 has ~270 KB total.

### Board IO

| Signal      | Pin  | Function                          |
|-------------|------|-----------------------------------|
| sysclk_i    | K17  | 125 MHz on-board oscillator       |
| rst_btn_i   | K18  | BTN0, active-high reset           |
| led_o[3:0]  | M14/M15/G14/D18 | gpio_o[3:0] → LD0..3   |
| sw_i[3:0]   | G15/P15/W13/T16 | gpio_i[3:0] ← SW0..3   |
| uart_tx_o   | V12  | Pmod JE pin 1                     |
| uart_rx_i   | W16  | Pmod JE pin 2                     |

Pmod JE is the UART header — pair with a Digilent Pmod USBUART
or a 3.3 V FTDI cable. SPI / I2C / PWM / JTAG TAP are tied off
in the wrapper; expose them by adding ports + XDC entries.
