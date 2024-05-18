onerror {resume}
quietly WaveActivateNextPane {} 0
add wave -noupdate /tb_soc_top/soc_top_inst/core_top_inst/clk_i
add wave -noupdate /tb_soc_top/soc_top_inst/core_top_inst/reset_i
add wave -noupdate -divider Ibus
add wave -noupdate /tb_soc_top/soc_top_inst/ibus/instruction
add wave -noupdate /tb_soc_top/soc_top_inst/ibus/address
add wave -noupdate /tb_soc_top/soc_top_inst/ibus/enable
add wave -noupdate /tb_soc_top/soc_top_inst/ibus/stall
add wave -noupdate /tb_soc_top/soc_top_inst/core_top_inst/ext_itr_i
add wave -noupdate /tb_soc_top/soc_top_inst/core_top_inst/timer_itr_i
add wave -noupdate /tb_soc_top/soc_top_inst/core_top_inst/soft_itr_i
add wave -noupdate -divider Core
add wave -noupdate /tb_soc_top/soc_top_inst/core_top_inst/pc_id
add wave -noupdate /tb_soc_top/soc_top_inst/core_top_inst/branch_taken
add wave -noupdate /tb_soc_top/soc_top_inst/core_top_inst/interrupt_valid
add wave -noupdate /tb_soc_top/soc_top_inst/core_top_inst/ret_valid
add wave -noupdate /tb_soc_top/soc_top_inst/core_top_inst/ctrl_bus_if_id
add wave -noupdate /tb_soc_top/soc_top_inst/core_top_inst/ctrl_bus_ie
add wave -noupdate /tb_soc_top/soc_top_inst/core_top_inst/ctrl_bus_imem
add wave -noupdate /tb_soc_top/soc_top_inst/core_top_inst/ctrl_bus_iwb
add wave -noupdate /tb_soc_top/soc_top_inst/core_top_inst/if_id_stall
add wave -noupdate /tb_soc_top/soc_top_inst/core_top_inst/ie_stall
add wave -noupdate /tb_soc_top/soc_top_inst/core_top_inst/imem_stall
add wave -noupdate /tb_soc_top/soc_top_inst/core_top_inst/iwb_stall
add wave -noupdate /tb_soc_top/soc_top_inst/core_top_inst/ie_flush
add wave -noupdate /tb_soc_top/soc_top_inst/core_top_inst/imem_flush
add wave -noupdate /tb_soc_top/soc_top_inst/core_top_inst/iwb_flush
add wave -noupdate /tb_soc_top/soc_top_inst/core_top_inst/insert_bubble
add wave -noupdate /tb_soc_top/soc_top_inst/core_top_inst/instruction_pipe
add wave -noupdate -divider Dbus
add wave -noupdate /tb_soc_top/soc_top_inst/dbus/address
add wave -noupdate /tb_soc_top/soc_top_inst/dbus/byteenable
add wave -noupdate /tb_soc_top/soc_top_inst/dbus/read
add wave -noupdate /tb_soc_top/soc_top_inst/dbus/readdata
add wave -noupdate /tb_soc_top/soc_top_inst/dbus/write
add wave -noupdate /tb_soc_top/soc_top_inst/dbus/writedata
add wave -noupdate /tb_soc_top/soc_top_inst/dbus/stall
add wave -noupdate -divider PLIC
add wave -noupdate /tb_soc_top/soc_top_inst/plic_inst/clk_i
add wave -noupdate /tb_soc_top/soc_top_inst/plic_inst/resetn_i
add wave -noupdate /tb_soc_top/soc_top_inst/plic_inst/write_i
add wave -noupdate /tb_soc_top/soc_top_inst/plic_inst/read_i
add wave -noupdate /tb_soc_top/soc_top_inst/plic_inst/chipselect_i
add wave -noupdate /tb_soc_top/soc_top_inst/plic_inst/writedata_i
add wave -noupdate /tb_soc_top/soc_top_inst/plic_inst/address_i
add wave -noupdate /tb_soc_top/soc_top_inst/plic_inst/Interrupt
add wave -noupdate /tb_soc_top/soc_top_inst/plic_inst/ED
add wave -noupdate /tb_soc_top/soc_top_inst/plic_inst/Interrupt_Claim
add wave -noupdate /tb_soc_top/soc_top_inst/plic_inst/Interrupt_Complete
add wave -noupdate /tb_soc_top/soc_top_inst/plic_inst/Interrupt_Notification
add wave -noupdate /tb_soc_top/soc_top_inst/plic_inst/readdata_o
add wave -noupdate /tb_soc_top/soc_top_inst/plic_inst/IE_interrupt
add wave -noupdate /tb_soc_top/soc_top_inst/plic_inst/Threshold
add wave -noupdate /tb_soc_top/soc_top_inst/plic_inst/Priority
add wave -noupdate /tb_soc_top/soc_top_inst/plic_inst/Interrupt_ID_r
add wave -noupdate /tb_soc_top/soc_top_inst/plic_inst/Interrupt_ID
add wave -noupdate /tb_soc_top/soc_top_inst/plic_inst/ID
add wave -noupdate -divider Timer
add wave -noupdate /tb_soc_top/soc_top_inst/timer_inst/stall_i
add wave -noupdate /tb_soc_top/soc_top_inst/timer_inst/write
add wave -noupdate /tb_soc_top/soc_top_inst/timer_inst/read
add wave -noupdate /tb_soc_top/soc_top_inst/timer_inst/chipselect
add wave -noupdate /tb_soc_top/soc_top_inst/timer_inst/writedata
add wave -noupdate /tb_soc_top/soc_top_inst/timer_inst/address
add wave -noupdate /tb_soc_top/soc_top_inst/timer_inst/readdata
add wave -noupdate /tb_soc_top/soc_top_inst/timer_inst/count
add wave -noupdate /tb_soc_top/soc_top_inst/timer_inst/compare
add wave -noupdate /tb_soc_top/soc_top_inst/timer_inst/intr_o
add wave -noupdate -divider {Interrupt CTRL}
add wave -noupdate /tb_soc_top/soc_top_inst/core_top_inst/interrupt_ctrl_inst/ext_itr_i
add wave -noupdate /tb_soc_top/soc_top_inst/core_top_inst/interrupt_ctrl_inst/timer_itr_i
add wave -noupdate /tb_soc_top/soc_top_inst/core_top_inst/interrupt_ctrl_inst/soft_itr_i
add wave -noupdate /tb_soc_top/soc_top_inst/core_top_inst/interrupt_ctrl_inst/ip_i
add wave -noupdate /tb_soc_top/soc_top_inst/core_top_inst/interrupt_ctrl_inst/ie_i
add wave -noupdate /tb_soc_top/soc_top_inst/core_top_inst/interrupt_ctrl_inst/vec_i
add wave -noupdate /tb_soc_top/soc_top_inst/core_top_inst/interrupt_ctrl_inst/status_i
add wave -noupdate /tb_soc_top/soc_top_inst/core_top_inst/interrupt_ctrl_inst/pc_i
add wave -noupdate /tb_soc_top/soc_top_inst/core_top_inst/interrupt_ctrl_inst/interrupt_valid_o
add wave -noupdate /tb_soc_top/soc_top_inst/core_top_inst/interrupt_ctrl_inst/handler_addr_o
add wave -noupdate /tb_soc_top/soc_top_inst/core_top_inst/interrupt_ctrl_inst/ecause_o
add wave -noupdate /tb_soc_top/soc_top_inst/core_top_inst/interrupt_ctrl_inst/epc_o
add wave -noupdate /tb_soc_top/soc_top_inst/core_top_inst/interrupt_ctrl_inst/interrupt_src_o
add wave -noupdate /tb_soc_top/soc_top_inst/core_top_inst/interrupt_ctrl_inst/excpetion_code
add wave -noupdate /tb_soc_top/soc_top_inst/core_top_inst/interrupt_ctrl_inst/external_valid
add wave -noupdate /tb_soc_top/soc_top_inst/core_top_inst/interrupt_ctrl_inst/software_valid
add wave -noupdate /tb_soc_top/soc_top_inst/core_top_inst/interrupt_ctrl_inst/timer_valid
add wave -noupdate -divider CSR
add wave -noupdate /tb_soc_top/soc_top_inst/core_top_inst/csr_unit_inst/interrupt_valid_i
add wave -noupdate /tb_soc_top/soc_top_inst/core_top_inst/csr_unit_inst/ecause_i
add wave -noupdate /tb_soc_top/soc_top_inst/core_top_inst/csr_unit_inst/epc_i
add wave -noupdate /tb_soc_top/soc_top_inst/core_top_inst/csr_unit_inst/interrupt_src_i
add wave -noupdate /tb_soc_top/soc_top_inst/core_top_inst/csr_unit_inst/ret_i
add wave -noupdate /tb_soc_top/soc_top_inst/core_top_inst/csr_unit_inst/ip_o
add wave -noupdate /tb_soc_top/soc_top_inst/core_top_inst/csr_unit_inst/ie_o
add wave -noupdate /tb_soc_top/soc_top_inst/core_top_inst/csr_unit_inst/vec_o
add wave -noupdate /tb_soc_top/soc_top_inst/core_top_inst/csr_unit_inst/status_o
add wave -noupdate /tb_soc_top/soc_top_inst/core_top_inst/csr_unit_inst/epc_o
add wave -noupdate /tb_soc_top/soc_top_inst/core_top_inst/csr_unit_inst/csr_value_o
add wave -noupdate /tb_soc_top/soc_top_inst/core_top_inst/csr_unit_inst/_MSTATUS
add wave -noupdate /tb_soc_top/soc_top_inst/core_top_inst/csr_unit_inst/_MIE
add wave -noupdate /tb_soc_top/soc_top_inst/core_top_inst/csr_unit_inst/_MTVEC
add wave -noupdate /tb_soc_top/soc_top_inst/core_top_inst/csr_unit_inst/_MEPC
add wave -noupdate /tb_soc_top/soc_top_inst/core_top_inst/csr_unit_inst/_MCAUSE
add wave -noupdate /tb_soc_top/soc_top_inst/core_top_inst/csr_unit_inst/_MIP
TreeUpdate [SetDefaultTree]
WaveRestoreCursors {{Cursor 1} {11035299813 ps} 0}
quietly wave cursor active 1
configure wave -namecolwidth 402
configure wave -valuecolwidth 100
configure wave -justifyvalue left
configure wave -signalnamewidth 0
configure wave -snapdistance 10
configure wave -datasetprefix 0
configure wave -rowmargin 4
configure wave -childrowmargin 2
configure wave -gridoffset 0
configure wave -gridperiod 1
configure wave -griddelta 40
configure wave -timeline 0
configure wave -timelineunits ns
update
WaveRestoreZoom {11035103552 ps} {11035562971 ps}
