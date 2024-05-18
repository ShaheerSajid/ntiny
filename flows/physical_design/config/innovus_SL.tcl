##################################globals#################################
setMultiCpuUsage -localCpu 20 -cpuPerRemoteHost 1 -remoteHost 0 -keepLicense true
setDistributeHost -local

###############################load design################################

set defHierChar /
set init_gnd_net {VSS}
set init_io_file {../config/SD.io}
set init_lef_file {\
../../65GP_TT/lef/PRTF_EDI_N65_9M_6X1Z1U_RDL.24a.tlef \
../../65GP_TT/lef/tcbn65gplus_9lmT2.lef \
../../65GP_TT/lef/arm_imem.lef \
../../65GP_TT/lef/arm_dmem.lef \
../../65GP_TT/lef/arm_boot.lef \
../../65GP_TT/lef/tphn65gpgv2od3_sl_9lm.lef \
../../65GP_TT/lef/tpbn65v_9lm.lef \
../../65GP_TT/lef/tpbn65v_9lm.lef\
}
set init_mmmc_file {../config/top_65GP_SL.view}
set init_oa_search_lib {}
set init_original_verilog_files {../../synthesis/genus/netlist/top_netlist.v}
set init_pwr_net {VDD}
set init_top_cell {top}
set init_verilog {../../synthesis/genus/work/output/top_m.v}
init_design

setDesignMode -process 65 -flowEffort standard
################################floorplan#################################
#load fp
loadFPlan ../config/top.fp

#cut rows under macros
selectInst mem_inst/m1
selectInst mem_inst/m2
selectInst arm_boot_inst
cutRow -selected -halo 8

#add halos
addHaloToBlock {0.1 0.1 0.1 0.1} -allIOPad
addRoutingHalo -allBlocks -space 0.1 -bottom M1 -top AP

addRoutingHalo -block mem_inst/m1 -space 0.1 -bottom M1 -top M4
addRoutingHalo -block mem_inst/m2 -space 0.1 -bottom M1 -top M4
addRoutingHalo -block arm_boot_inst -space 0.1 -bottom M1 -top M4
addHaloToBlock {0.1 0.1 0.1 0.1} mem_inst/m1
addHaloToBlock {0.1 0.1 0.1 0.1} mem_inst/m2
addHaloToBlock {0.1 0.1 0.1 0.1} arm_boot_inst

#connect global PG nets
globalNetConnect VDD -type pgpin -pin VDD -instanceBasename *
globalNetConnect VDD -type pgpin -pin VDDPE -instanceBasename *
globalNetConnect VDD -type pgpin -pin VDDCE -instanceBasename *
globalNetConnect VSS -type pgpin -pin VSS -instanceBasename *
globalNetConnect VSS -type pgpin -pin VSSE -instanceBasename *
globalNetConnect VSS -type tielo -instanceBasename *
globalNetConnect VDD -type tiehi -instanceBasename *

#power mesh
setAddRingMode -ring_target default -extend_over_row 0 -ignore_rows 0 -avoid_short 0 -skip_crossing_trunks none -stacked_via_top_layer AP -stacked_via_bottom_layer M1 -via_using_exact_crossover_size 1 -orthogonal_only true -skip_via_on_pin {  standardcell } -skip_via_on_wire_shape {  noshape }

addRing -nets {VDD VSS} -type core_rings -follow core -layer {top M9 bottom M9 left M8 right M8} -width {top 4 bottom 4 left 4 right 4} -spacing {top 2 bottom 2 left 2 right 2} -offset {top 2 bottom 2 left 2 right 2} -center 0 -threshold 0 -jog_distance 0 -snap_wire_center_to_grid None

setAddRingMode -ring_target default -extend_over_row 0 -ignore_rows 0 -avoid_short 0 -skip_crossing_trunks none -stacked_via_top_layer AP -stacked_via_bottom_layer M1 -via_using_exact_crossover_size 1 -orthogonal_only true -skip_via_on_pin {  standardcell } -skip_via_on_wire_shape {  noshape }

addRing -nets {VDD VSS} -type block_rings -around each_block -layer {top M9 bottom M9 left M8 right M8} -width {top 2 bottom 2 left 2 right 2} -spacing {top 2 bottom 2 left 2 right 2} -offset {top 2 bottom 2 left 2 right 2} -center 0 -threshold 0 -jog_distance 0 -snap_wire_center_to_grid None

#core stripes
setAddStripeMode -ignore_block_check false -break_at {  block_ring  } -route_over_rows_only false -rows_without_stripes_only false -extend_to_closest_target none -stop_at_last_wire_for_area false -partial_set_thru_domain false -ignore_nondefault_domains false -trim_antenna_back_to_shape none -spacing_type edge_to_edge -spacing_from_block 0 -stripe_min_length stripe_width -stacked_via_top_layer AP -stacked_via_bottom_layer M1 -via_using_exact_crossover_size false -split_vias false -orthogonal_only true -allow_jog { padcore_ring  block_ring } -skip_via_on_pin {  standardcell } -skip_via_on_wire_shape {  noshape   }
addStripe -nets {VDD VSS} -layer M9 -direction horizontal -width 4 -spacing 2 -set_to_set_distance 85 -start_from bottom -start_offset 20 -switch_layer_over_obs false -max_same_layer_jog_length 2 -padcore_ring_top_layer_limit AP -padcore_ring_bottom_layer_limit M1 -block_ring_top_layer_limit AP -block_ring_bottom_layer_limit M1 -use_wire_group 0 -snap_wire_center_to_grid None

setAddStripeMode -ignore_block_check false -break_at {  block_ring  } -route_over_rows_only false -rows_without_stripes_only false -extend_to_closest_target none -stop_at_last_wire_for_area false -partial_set_thru_domain false -ignore_nondefault_domains false -trim_antenna_back_to_shape none -spacing_type edge_to_edge -spacing_from_block 0 -stripe_min_length stripe_width -stacked_via_top_layer AP -stacked_via_bottom_layer M1 -via_using_exact_crossover_size false -split_vias false -orthogonal_only true -allow_jog { padcore_ring  block_ring } -skip_via_on_pin {  standardcell } -skip_via_on_wire_shape {  noshape   }
addStripe -nets {VDD VSS} -layer M8 -direction vertical -width 4 -spacing 2 -set_to_set_distance 85 -start_from left -start_offset 20 -switch_layer_over_obs false -max_same_layer_jog_length 2 -padcore_ring_top_layer_limit AP -padcore_ring_bottom_layer_limit M1 -block_ring_top_layer_limit AP -block_ring_bottom_layer_limit M1 -use_wire_group 0 -snap_wire_center_to_grid None

#block stripes
setAddStripeMode -ignore_block_check false -break_at none -route_over_rows_only false -rows_without_stripes_only false -extend_to_closest_target ring -stop_at_last_wire_for_area false -partial_set_thru_domain false -ignore_nondefault_domains false -trim_antenna_back_to_shape none -spacing_type edge_to_edge -spacing_from_block 0 -stripe_min_length stripe_width -stacked_via_top_layer AP -stacked_via_bottom_layer M1 -via_using_exact_crossover_size false -split_vias false -orthogonal_only true -allow_jog { padcore_ring  block_ring } -skip_via_on_pin {  standardcell } -skip_via_on_wire_shape {  noshape   }

addStripe -nets {VDD VSS} -layer M6 -direction vertical -width 4 -spacing 2 -set_to_set_distance 60 -over_power_domain 1 -start_from left -switch_layer_over_obs false -max_same_layer_jog_length 2 -padcore_ring_top_layer_limit AP -padcore_ring_bottom_layer_limit M1 -block_ring_top_layer_limit AP -block_ring_bottom_layer_limit M1 -use_wire_group 0 -snap_wire_center_to_grid None
setLayerPreference pinObj -isVisible 1

#power routing
setSrouteMode -viaConnectToShape { stripe }
sroute -connect { padPin padRing corePin } -layerChangeRange { M1(1) AP(10) } -blockPinTarget { nearestTarget } -padPinPortConnect { allPort allGeom } -padPinTarget { nearestTarget } -corePinTarget { firstAfterRowEnd } -floatingStripeTarget { blockring padring ring stripe ringpin blockpin followpin } -allowJogging 1 -crossoverViaLayerRange { M1(1) AP(10) } -nets { VDD VSS } -allowLayerChange 1 -blockPin useLef -targetViaLayerRange { M1(1) AP(10) }
#############################place design###############################
#specifyCellPad * 1

setUsefulSkewMode -maxSkew false -noBoundary false -useCells {CKBD8 CKBD6 CKBD4 CKBD3 CKBD24 CKBD20 CKBD2 CKBD16 CKBD12 CKBD1 CKBD0 CKND8 CKND6 CKND4 CKND3 CKND24 CKND20 CKND2 CKND16 CKND12 CKND1 CKND0} -maxAllowedDelay 1
setPlaceMode -reset
setPlaceMode -congEffort high -timingDriven 1 -clkGateAware 1 -powerDriven 0 -ignoreScan 1 -reorderScan 0 -ignoreSpare 0 -placeIOPins 1 -moduleAwareSpare 0 -preserveRouting 1 -rmAffectedRouting 0 -checkRoute 0 -swapEEQ 0
setPlaceMode -fp false
setPlaceMode -place_global_uniform_density true
place_opt_design

#tie high low
addTieHiLo -cell {TIEL TIEH} -prefix LTIE
########################pre cts opt design#############################
optDesign -expandedViews -preCTS -setup
################################cts#####################################
#clock attributes
add_ndr -name CTS_2W2S -spacing {M1:M7 0.2} -width {M1:M7 0.2}
create_route_type -name cts_trunk -non_default_rule CTS_2W2S -top_preferred_layer M7 -bottom_preferred_layer M6 -shield_net VSS -prefer_multi_cut_via -preferred_routing_layer_effort medium
#setAttribute -net {clk_i} -top_preferred_routing_layer 7
#setAttribute -net {clk_i} -bottom_preferred_routing_layer 6
#create_route_type -name cts_trunk -top_preferred_layer M7 -bottom_preferred_layer M6 -shield_net VSS -shield_side one_side
#set cts
set_ccopt_property -net_type trunk route_type cts_trunk
set_ccopt_property inverter_cells {CKND8 CKND6 CKND4 CKND3 CKND24 CKND20 CKND2 CKND16 CKND12 CKND1 CKND0}
set_ccopt_property use_inverters true
create_ccopt_clock_tree_spec
ccopt_design -expandedViews
set_interactive_constraint_modes {cons_typ cons_cbest cons_rcworst}
set_propagated_clock [all_clocks]
########################post cts opt design#############################
optDesign -expandedViews -postCTS -setup
optDesign -expandedViews -postCTS -hold
################################route###################################
#route
setNanoRouteMode -routeWithTimingDriven 1
setNanoRouteMode -routeWithSiDriven 1
setNanoRouteMode -routeTopRoutingLayer 9
setNanoRouteMode -routeBottomRoutingLayer 1
setNanoRouteMode -drouteEndIteration 20
setNanoRouteMode -droutePostRouteSwapVia multiCut
setNanoRouteMode -drouteUseMultiCutViaEffort high
routeDesign -globalDetail -viaOpt -wireOpt
########################post route opt design###########################
setAnalysisMode -analysisType onChipVariation -cppr both
optDesign -expandedViews -postRoute -hold -setup
############################fillers#####################################
#cells
addDeCapCellCandidates DCAP 1.172
addDeCapCellCandidates DCAP4 2.392
addDeCapCellCandidates DCAP8 11.971
addDeCapCellCandidates DCAP16 26.947
addDeCap -totCap 5000 -cells DCAP DCAP4 DCAP8 DCAP16
addFiller -cell FILL1 FILL16 FILL2 FILL32 FILL4 FILL64 FILL8 -prefix FILLER -doDRC

############################report gen#################################
verify_drc -report top.drc.rpt
verify_connectivity -type all -report top.conn.rpt
verifyProcessAntenna -report top.ant.rpt
############################save design################################
saveNetlist top.v -topcell top
#saveNetlist -onlyStdCell -phys stdCell.v
#defOut -floorplan -netlist -routing top.def
saveDesign top.enc
#stream out
streamOut top.gds \
-mapFile ../../65GP_TT/map/PRTF_EDI_N65_gdsout_6X1Z1U.24a.map \
-libName DesignLib \
-merge { \
../../65GP_TT/gds/arm_dmem.gds2 \
../../65GP_TT/gds/arm_imem.gds2 \
../../65GP_TT/gds/arm_boot.gds2 \
../../65GP_TT/gds/tcbn65gplus.gds \
../../65GP_TT/gds/tpbn65v.gds \
../../65GP_TT/gds/tphn65gpgv2od3_sl.gds\
} -units 1000 \
-outputMacros \
-dieAreaAsBoundary \
-uniquifyCellNames -mode ALL

source ../config/ir_analysis.tcl
