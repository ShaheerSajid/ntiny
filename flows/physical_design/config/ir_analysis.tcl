############################IR####################################
set_pg_library_mode \
-celltype techonly \
-default_area_cap 0.5 \
-filler_cells {FILL1 FILL16 FILL2 FILL32 FILL4 FILL64 FILL8} \
-decap_cells {DECAP DECAP4 DECAP8 DECAP16} \
-extraction_tech_file ../../65GP_TT/qrc/qrcTechFile_rcworst \
-power_pins {VDD 0.9 VDDCE 0.9 VDDPE 0.9} \
-ground_pins {VSS VSSE}

generate_pg_library -output ./pg_lib


set_power_analysis_mode \
-method static \
-analysis_view func_rcworst \
-corner max \
-create_binary_db true \
-write_static_currents true

set_default_switching_activity \
-input_activity 0.2 \
-period 10.0

set_power_output_dir ./static_pwr

report_power -rail_analysis_format VS -outfile ./static_pwr/top.rpt


set_rail_analysis_mode \
-method era_static \
-accuracy xd \
-analysis_view func_rcworst \
-power_grid_library pg_lib/techonly.cl

create_power_pads -net VDD -auto_fetch
create_power_pads -net VDD -vsrc_file top.pp
set_pg_nets -net VDD -voltage 1.0 -threshold 0.9

set_power_data -format current -scale 1 static_pwr/static_VDD.ptiavg
set_power_pads -net VDD -format xy -file top.pp
analyze_rail -type net -results_directory ./static_rail VDD

