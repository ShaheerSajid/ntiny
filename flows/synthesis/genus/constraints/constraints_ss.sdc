##########################################
## Set the current design
##########################################
current_design top

set max_freq 40.0
set period [expr 1000.0/$max_freq]
set duty_cycle [expr $period/2]

set jtag_freq 20.0
set jtag_period [expr 1000.0/$jtag_freq]
set jtag_duty_cycle [expr $jtag_period/2]


##########################################
## primary clock of design
##########################################
create_clock -name "clk_pin" -period $period -waveform [list 0.0 $duty_cycle] [get_ports "clk_i"]
create_clock -name "tck_pin" -period $jtag_period -waveform [list 0.0 $jtag_duty_cycle] [get_ports "jtag_tck_i"]


set_clock_transition -rise 0.1 [get_clocks "clk_pin"]
set_clock_transition -fall 0.1 [get_clocks "clk_pin"]
set_clock_uncertainty 0.2 [get_clocks "clk_pin"]
set_clock_transition -rise 0.1 [get_clocks "tck_pin"]
set_clock_transition -fall 0.1 [get_clocks "tck_pin"]
set_clock_uncertainty 0.2 [get_clocks "tck_pin"]

##########################################
## generated clocks
##########################################
create_generated_clock -combinational -source [get_ports "clk_i"] -name "core_clk" [get_pins clk_cell/C]
create_generated_clock -combinational -source [get_ports "jtag_tck_i"] -name "jtag_clk" [get_pins tck_cell/C]

##########################################
## exceptions
##########################################


##########################################
## Design rule constraints
##########################################


##########################################
## input delays 
########################################## 
set_input_delay -clock [ get_clocks { jtag_clk } ] -add_delay .1 [ get_ports {  jtag_tdi_i } ]
set_input_delay -clock [ get_clocks { jtag_clk } ] -add_delay .1 [ get_ports {  jtag_tms_i } ]
set_input_delay -clock [ get_clocks { core_clk } ] -add_delay .1 [ get_ports {  reset_i } ]
set_input_delay -clock [ get_clocks { core_clk } ] -add_delay .1 [ get_ports {  spi_miso_i } ]
set_input_delay -clock [ get_clocks { core_clk } ] -add_delay .1 [ get_ports {  uart_rx_i } ]
set_input_delay -clock [ get_clocks { core_clk } ] -add_delay .1 [ get_ports {  gpio_io[0] } ]
set_input_delay -clock [ get_clocks { core_clk } ] -add_delay .1 [ get_ports {  gpio_io[1] } ]
set_input_delay -clock [ get_clocks { core_clk } ] -add_delay .1 [ get_ports {  gpio_io[2] } ]
set_input_delay -clock [ get_clocks { core_clk } ] -add_delay .1 [ get_ports {  gpio_io[3] } ]
set_input_delay -clock [ get_clocks { core_clk } ] -add_delay .1 [ get_ports {  gpio_io[4] } ]
set_input_delay -clock [ get_clocks { core_clk } ] -add_delay .1 [ get_ports {  gpio_io[5] } ]
set_input_delay -clock [ get_clocks { core_clk } ] -add_delay .1 [ get_ports {  gpio_io[6] } ]
set_input_delay -clock [ get_clocks { core_clk } ] -add_delay .1 [ get_ports {  gpio_io[7] } ]
set_input_delay -clock [ get_clocks { core_clk } ] -add_delay .1 [ get_ports {  gpio_io[8] } ]
set_input_delay -clock [ get_clocks { core_clk } ] -add_delay .1 [ get_ports {  gpio_io[9] } ]
set_input_delay -clock [ get_clocks { core_clk } ] -add_delay .1 [ get_ports {  gpio_io[10] } ]
set_input_delay -clock [ get_clocks { core_clk } ] -add_delay .1 [ get_ports {  gpio_io[11] } ]
set_input_delay -clock [ get_clocks { core_clk } ] -add_delay .1 [ get_ports {  gpio_io[12] } ]
set_input_delay -clock [ get_clocks { core_clk } ] -add_delay .1 [ get_ports {  gpio_io[13] } ]
set_input_delay -clock [ get_clocks { core_clk } ] -add_delay .1 [ get_ports {  gpio_io[14] } ]
set_input_delay -clock [ get_clocks { core_clk } ] -add_delay .1 [ get_ports {  gpio_io[15] } ]
set_input_delay -clock [ get_clocks { core_clk } ] -add_delay .1 [ get_ports {  i2c_scl_io } ]
set_input_delay -clock [ get_clocks { core_clk } ] -add_delay .1 [ get_ports {  i2c_sda_io } ]



##########################################
## output delays
##########################################


set_output_delay -clock [ get_clocks { jtag_clk } ] -add_delay .1 [ get_ports {  jtag_tdo_o } ]
set_output_delay -clock [ get_clocks { core_clk } ] -add_delay .1 [ get_ports {  pwm0_o } ]
set_output_delay -clock [ get_clocks { core_clk } ] -add_delay .1 [ get_ports {  pwm1_o } ]
set_output_delay -clock [ get_clocks { core_clk } ] -add_delay .1 [ get_ports {  spi_mosi_o } ]
set_output_delay -clock [ get_clocks { core_clk } ] -add_delay .1 [ get_ports {  spi_sck_o } ]
set_output_delay -clock [ get_clocks { core_clk } ] -add_delay .1 [ get_ports {  spi_ss_o } ]
set_output_delay -clock [ get_clocks { core_clk } ] -add_delay .1 [ get_ports {  uart_tx_o } ]

set_output_delay -clock [ get_clocks { core_clk } ] -add_delay .1 [ get_ports {  gpio_io[0] } ]
set_output_delay -clock [ get_clocks { core_clk } ] -add_delay .1 [ get_ports {  gpio_io[1] } ]
set_output_delay -clock [ get_clocks { core_clk } ] -add_delay .1 [ get_ports {  gpio_io[2] } ]
set_output_delay -clock [ get_clocks { core_clk } ] -add_delay .1 [ get_ports {  gpio_io[3] } ]
set_output_delay -clock [ get_clocks { core_clk } ] -add_delay .1 [ get_ports {  gpio_io[4] } ]
set_output_delay -clock [ get_clocks { core_clk } ] -add_delay .1 [ get_ports {  gpio_io[5] } ]
set_output_delay -clock [ get_clocks { core_clk } ] -add_delay .1 [ get_ports {  gpio_io[6] } ]
set_output_delay -clock [ get_clocks { core_clk } ] -add_delay .1 [ get_ports {  gpio_io[7] } ]
set_output_delay -clock [ get_clocks { core_clk } ] -add_delay .1 [ get_ports {  gpio_io[8] } ]
set_output_delay -clock [ get_clocks { core_clk } ] -add_delay .1 [ get_ports {  gpio_io[9] } ]
set_output_delay -clock [ get_clocks { core_clk } ] -add_delay .1 [ get_ports {  gpio_io[10] } ]
set_output_delay -clock [ get_clocks { core_clk } ] -add_delay .1 [ get_ports {  gpio_io[11] } ]
set_output_delay -clock [ get_clocks { core_clk } ] -add_delay .1 [ get_ports {  gpio_io[12] } ]
set_output_delay -clock [ get_clocks { core_clk } ] -add_delay .1 [ get_ports {  gpio_io[13] } ]
set_output_delay -clock [ get_clocks { core_clk } ] -add_delay .1 [ get_ports {  gpio_io[14] } ]
set_output_delay -clock [ get_clocks { core_clk } ] -add_delay .1 [ get_ports {  gpio_io[15] } ]
set_output_delay -clock [ get_clocks { core_clk } ] -add_delay .1 [ get_ports {  i2c_scl_io } ]
set_output_delay -clock [ get_clocks { core_clk } ] -add_delay .1 [ get_ports {  i2c_sda_io } ]




##########################################
## wire load model
##########################################
##########################################
## operating condition constraints
##########################################
##########################################
## power constriants
##########################################





