# Version: 1.0 MMMC View Definition File
source vars.globals
# Create library set
create_library_set -name lib_tt -timing "$TimeLibTyp"
create_library_set -name lib_ff -timing "$TimeLibBest"
create_library_set -name lib_ss -timing "$TimeLibWorst"
# Create operating conditions
create_opcond -name op_cond_tt -process 1 -voltage 1.00 -temperature 25
create_opcond -name op_cond_ff -process 1 -voltage 1.10 -temperature -40
create_opcond -name op_cond_ss -process 1 -voltage 0.90 -temperature 125
#Create timing condition
create_timing_condition -name timing_cond_tt -opcond op_cond_tt -library_sets lib_tt
create_timing_condition -name timing_cond_ff -opcond op_cond_ff -library_sets lib_ff
create_timing_condition -name timing_cond_ss -opcond op_cond_ss -library_sets lib_ss
# Create RC corner
create_rc_corner -name rc_typ		-temperature "$TempTT" -qrc_tech "$qrcFileTyp"
create_rc_corner -name rc_cbest		-temperature "$TempFF" -qrc_tech "$qrcFileCbest"
create_rc_corner -name rc_cworst	-temperature "$TempSS" -qrc_tech "$qrcFileCworst"
create_rc_corner -name rc_rcbest	-temperature "$TempFF" -qrc_tech "$qrcFileRCbest"
create_rc_corner -name rc_rcworst	-temperature "$TempSS" -qrc_tech "$qrcFileRCworst"
# Create delay corner
create_delay_corner -name delay_typ	-timing_condition timing_cond_tt -rc_corner rc_typ
create_delay_corner -name delay_cbest 	-timing_condition timing_cond_ff -rc_corner rc_cbest
create_delay_corner -name delay_cworst 	-timing_condition timing_cond_ss -rc_corner rc_cworst
create_delay_corner -name delay_rcbest 	-timing_condition timing_cond_ff -rc_corner rc_rcbest
create_delay_corner -name delay_rcworst -timing_condition timing_cond_ss -rc_corner rc_rcworst
# Create constraint mode
create_constraint_mode -name cons_tt -sdc_files ../constraints/constraints_tt.sdc
create_constraint_mode -name cons_ff -sdc_files ../constraints/constraints_ff.sdc
create_constraint_mode -name cons_ss -sdc_files ../constraints/constraints_ss.sdc
# Create analysis view
create_analysis_view -name func_typ   	-constraint_mode cons_tt -delay_corner delay_typ
create_analysis_view -name func_cbest  	-constraint_mode cons_ff -delay_corner delay_cbest
create_analysis_view -name func_cworst  -constraint_mode cons_ss -delay_corner delay_cworst
create_analysis_view -name func_rcbest	-constraint_mode cons_ff -delay_corner delay_rcbest
create_analysis_view -name func_rcworst -constraint_mode cons_ss -delay_corner delay_rcworst
# Set analysis view
set_analysis_view -setup {func_rcworst func_cbest func_typ} -hold {func_rcworst func_cbest func_typ}
