# Zybo Z7-10 constraints for ntiny.
#
# Pin assignments are from Digilent's Zybo Z7 master XDC. Banks /
# IOSTANDARDs are board-fixed (3.3 V LVCMOS). Same package
# (CLG400) and pin-out as Zybo Z7-20.

# ── 125 MHz on-board oscillator ───────────────────────────────
set_property -dict { PACKAGE_PIN K17 IOSTANDARD LVCMOS33 } [get_ports { sysclk_i }]
create_clock -period 8.000 -name sysclk -waveform {0.000 4.000} [get_ports { sysclk_i }]

# ── Buttons (BTN0 = reset) ────────────────────────────────────
set_property -dict { PACKAGE_PIN K18 IOSTANDARD LVCMOS33 } [get_ports { rst_btn_i }]

# ── LEDs (LD0..LD3) ───────────────────────────────────────────
set_property -dict { PACKAGE_PIN M14 IOSTANDARD LVCMOS33 } [get_ports { led_o[0] }]
set_property -dict { PACKAGE_PIN M15 IOSTANDARD LVCMOS33 } [get_ports { led_o[1] }]
set_property -dict { PACKAGE_PIN G14 IOSTANDARD LVCMOS33 } [get_ports { led_o[2] }]
set_property -dict { PACKAGE_PIN D18 IOSTANDARD LVCMOS33 } [get_ports { led_o[3] }]

# ── Slide switches (SW0..SW3) ─────────────────────────────────
set_property -dict { PACKAGE_PIN G15 IOSTANDARD LVCMOS33 } [get_ports { sw_i[0] }]
set_property -dict { PACKAGE_PIN P15 IOSTANDARD LVCMOS33 } [get_ports { sw_i[1] }]
set_property -dict { PACKAGE_PIN W13 IOSTANDARD LVCMOS33 } [get_ports { sw_i[2] }]
set_property -dict { PACKAGE_PIN T16 IOSTANDARD LVCMOS33 } [get_ports { sw_i[3] }]

# ── UART on Pmod JE (header pins 1 = TX out, 2 = RX in) ──────
# Pair with a Digilent Pmod USBUART or a 3.3 V FTDI cable.
set_property -dict { PACKAGE_PIN V12 IOSTANDARD LVCMOS33 } [get_ports { uart_tx_o }]
set_property -dict { PACKAGE_PIN W16 IOSTANDARD LVCMOS33 } [get_ports { uart_rx_i }]

# ── Bitstream config ──────────────────────────────────────────
set_property CFGBVS VCCO        [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
