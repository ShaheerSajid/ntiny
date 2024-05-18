##############################################################################
## Set Paths
##############################################################################
set LOCAL_DIR	"[exec pwd]/.."
set SYNTH_DIR	"${LOCAL_DIR}/work"
set TCL_PATH	"${LOCAL_DIR}/script $LOCAL_DIR/constraints"
set REPORTS_PATH	"${LOCAL_DIR}/work/reports" 
set LIB_PATH		"${LOCAL_DIR}/../../65GP_TT/lib"
set LEF_PATH		"${LOCAL_DIR}/../../65GP_TT/lef"	
set DESIGN_PATH		"$LOCAL_DIR/../../../design"
set RTL_PATH		\
"\
../../../../design/common \
../../../../design/debug/src/ \
../../../../design/core/include/ \
../../../../design/buses/src/ \
../../../../design/core/alu/src/ \
../../../../design/core/fpu/src/ \
../../../../design/core/branch/src/ \
../../../../design/core/control_path/src/ \
../../../../design/core/forwarding_unit/src/\
../../../../design/core/imm_gen/src/ \
../../../../design/core/program_counter/src/ \
../../../../design/core/regfile/src/\
../../../../design/core/stall_unit/src/ \
../../../../design/core/csr_unit/src/\
../../../../design/core/avalon_master/src/ \
../../../../design/core/c_ext/ \
../../../../design/core/core_top/src/ \
../../../../design/interconnect/src/ \
../../../../design/interconnect/axi \
../../../../design/interconnect/axi/include \
../../../../design/interconnect/axi/src \
../../../../design/uncore/gpio/src/\
../../../../design/uncore/timer/src/ \
../../../../design/uncore/uart/src/ \
../../../../design/uncore/i2c/src/ \
../../../../design/uncore/spi/src/ \
../../../../design/uncore/pwm/src/ \
../../../../design/uncore/plic/src/ \
../../../../design/uncore/crc/src/ \
../../../../design/core/interrupt/ \
../../../../design/soc_top/src/ \
../rtl \
"

set _OUTPUTS_PATH	"${LOCAL_DIR}/work/output"		
set SYN_GENERIC_EFFORT high
set SYN_MAP_EFFORT high
set SYN_OPT_EFFORT high

##############################################################################
## Preset global variables and attributes
##############################################################################
set DESIGN top
###############################################################
## seting lib, tcl and hdl search path in genus
###############################################################
set_db hdl_track_filename_row_col true 
set_db lp_power_unit mW 
set_db / .init_lib_search_path $LIB_PATH
set_db / .script_search_path $TCL_PATH
set_db / .init_hdl_search_path $RTL_PATH
set_db / .max_cpus_per_server 8
set_db / .pbs_mmmc_flow true
set_db error_on_lib_lef_pin_inconsistency true
#set_db hdl_parameter_naming_style ""
#set_db bit_blasted_port_style %s_%d
#set_db hdl_array_naming_style %s_%d
#set_db hdl_flatten_complex_port true
#set_db hdl_generate_index_style %s_%d_
#set_db hdl_generate_separator _
#set_db hdl_record_naming_style  %s_%s
set_db auto_ungroup none
###############################################################
## setting lib, lef and hdl files list
###############################################################
# Baseline Libraries
set LEF_LIST_GP {\
../../../65GP_TT/lef/tcbn65gplus_9lmT2.lef \
../../../65GP_TT/lef/arm_imem.lef \
../../../65GP_TT/lef/arm_dmem.lef \
../../../65GP_TT/lef/arm_boot.lef \
../../../65GP_TT/lef/tphn65gpgv2od3_sl_9lm.lef \
../../../65GP_TT/lef/tpbn65v_9lm.lef \
../../../65GP_TT/lef/tpbn65v_9lm.lef \
}
# Baseline RTL
set RTL_LIST { \
common_pkg.sv \
debug_pkg.sv \
core_pkg.sv \
dtm.sv \
dm.sv \
debug_top.sv \
buses.sv \
alu.sv \
divider.sv \
zba_zbb.sv \
fpnew_top_gate.v \
branch_target_address.sv \
branch_comp.sv \
decoder.sv \
forwarding_logic.sv \
imm_gen.sv \
program_counter.sv \
reg_file.sv \
stall_line.sv \
csr_unit.sv \
core2avl.sv \
c_dec.sv \
c_controller.sv \
core_top.sv \
avalon_interconnect.sv \
gpio_top.sv \
pkg_timer_decodes.sv \
timer_top.sv \
uart_defs.sv \
uart_top.sv \
i2c_master_defines.sv \
i2c_master_bit_ctrl.sv \
i2c_master_byte_ctrl.sv \
i2c.sv \
spi_defs.sv \
spi.sv \
pkg_pwm_decodes.sv \
pwm_top.sv \
interrupt_ctrl.sv \
plic.v \
PLIC_TOP.v \
IP_Handling.v \
gateway.v \
comparator.v \
clic.v \
crc_avalon_wrap.v \
lfsr.v \
lfsr_crc.v \
soc_top.sv \
mem.v \
top_65GP_SL.sv \
}
###############################################################
## Library setup
###############################################################
read_mmmc mmc.tcl
read_physical -lef $LEF_LIST_GP										
####################################################################
## Load Design
####################################################################
read_hdl -define BOOT -sv $RTL_LIST
elaborate $DESIGN	
puts "Runtime & Memory after 'read_hdl'"
time_info Elaboration
init_design
puts "checking unresolbed issues after elaboration"
check_design -unresolved
puts "The number of exceptions is [llength [vfind "design:$DESIGN" -exception *]]"
check_timing_intent 
####################################################################################################
## Synthesizing to generic 
####################################################################################################
set_db / .syn_generic_effort $SYN_GENERIC_EFFORT
syn_generic
puts "Runtime & Memory after 'syn_generic'"
time_info GENERIC
report_dp > $REPORTS_PATH/generic/${DESIGN}_datapath.rpt
write_snapshot -outdir $REPORTS_PATH -tag generic
report_summary -directory $REPORTS_PATH
####################################################################################################
## Synthesizing to gates
####################################################################################################
set_db / .syn_map_effort $SYN_MAP_EFFORT
syn_map
#ungroup -all -exclude mem_inst
puts "Runtime & Memory after 'syn_map'"
time_info MAPPED
write_snapshot -outdir $REPORTS_PATH -tag map
report_summary -directory $REPORTS_PATH
report_dp > $REPORTS_PATH/map/${DESIGN}_datapath.rpt
#######################################################################################################
## Optimize Netlist
#######################################################################################################
## Uncomment to remove assigns & insert tiehilo cells during Incremental synthesis
##set_db / .remove_assigns true 
##set_remove_assign_options -buffer_or_inverter <libcell> -design <design|subdesign> 
##set_db / .use_tiehilo_for_const <none|duplicate|unique> 
set_db / .syn_opt_effort $SYN_OPT_EFFORT
syn_opt
write_snapshot -outdir $REPORTS_PATH -tag syn_opt
report_summary -directory $REPORTS_PATH
puts "Runtime & Memory after 'syn_opt'"
time_info OPT
write_snapshot -outdir $REPORTS_PATH -tag final
report_summary -directory $REPORTS_PATH
write_hdl  > ${_OUTPUTS_PATH}/${DESIGN}_m.v
write_script > ${_OUTPUTS_PATH}/${DESIGN}_m.script
write_sdc -view func_typ > ${_OUTPUTS_PATH}/${DESIGN}_m_typ.sdc
write_sdc -view func_cworst > ${_OUTPUTS_PATH}/${DESIGN}_m_cworst.sdc
write_sdc -view func_cbest > ${_OUTPUTS_PATH}/${DESIGN}_m_cbest.sdc
write_sdc -view func_rcworst > ${_OUTPUTS_PATH}/${DESIGN}_m_rcworst.sdc
write_sdc -view func_rcbest > ${_OUTPUTS_PATH}/${DESIGN}_m_rcbest.sdc
write_sdf -timescale ns -nonegchecks -recrem split -edges check_edge  -setuphold split > ${_OUTPUTS_PATH}/${DESIGN}_m.sdf
#################################
### End
#################################
puts "Final Runtime & Memory."
time_info FINAL
puts "============================"
puts "Synthesis Finished ........."
puts "============================"
##quit
