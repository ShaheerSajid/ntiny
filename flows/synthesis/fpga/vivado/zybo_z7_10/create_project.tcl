# Vivado 2020.1 project generator for ntiny on Zybo Z7-10.
#
# Usage from the fpga/zybo_z7_10/ directory:
#   /tools/xilinx/Vivado/2020.1/bin/vivado -mode batch -source create_project.tcl
#
# Re-runs are idempotent: deletes any existing project_dir/ first.
# The RTL list is sourced from flows/simulation/src.args (the same
# canonical list Verilator uses) so peripheral / core changes pick
# up automatically.

set proj_name "ntiny_zybo_z7_10"
set part      "xc7z010clg400-1"

set script_dir [file normalize [file dirname [info script]]]
set repo_root  [file normalize "$script_dir/../../../../.."]
set proj_dir   "$script_dir/project_dir"

# ── Fresh project ─────────────────────────────────────────────
if { [file exists $proj_dir] } { file delete -force $proj_dir }
create_project $proj_name $proj_dir -part $part -force

set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]
set_property default_lib xil_defaultlib [current_project]

# ── RTL: read flows/simulation/src.args ──────────────────────
set src_args_path "$repo_root/flows/simulation/src.args"
set f  [open $src_args_path r]
set rtl_files {}
while { [gets $f line] >= 0 } {
    set line [string trim $line]
    if { $line eq "" }                      { continue }
    if { [string match "//*" $line] }       { continue }
    if { [string match "#*" $line] }        { continue }
    set abs [file normalize "$repo_root/flows/simulation/$line"]
    lappend rtl_files $abs
}
close $f

# ── FPGA wrapper top ──────────────────────────────────────────
lappend rtl_files "$script_dir/top/ntiny_zybo_top.sv"

add_files -norecurse -fileset sources_1 $rtl_files

# ── Mark SystemVerilog files explicitly ──────────────────────
foreach f [get_files -of_objects [get_filesets sources_1]] {
    if { [string match "*.sv" $f] || [string match "*.svh" $f] } {
        set_property file_type {SystemVerilog} [get_files $f]
    }
}

# ── Include directories (mirror Verilator +incdir paths) ─────
set incdirs [list \
    "$repo_root/design/common" \
    "$repo_root/design/uncore/i2c/src" \
    "$repo_root/design/uncore/timer/src" \
    "$repo_root/design/uncore/pwm/src" \
    "$repo_root/design/uncore/spi/src" \
    "$repo_root/design/uncore/uart/src" \
    "$repo_root/design/core/include" \
    "$repo_root/design/core/fpu/PakFPU/src" \
]
set_property include_dirs $incdirs [get_filesets sources_1]
set_property include_dirs $incdirs [get_filesets sim_1]

# ── Constraints ───────────────────────────────────────────────
add_files -norecurse -fileset constrs_1 \
    "$script_dir/constraints/zybo_z7_10.xdc"

# ── Top module ────────────────────────────────────────────────
set_property top ntiny_zybo_top [current_fileset]
update_compile_order -fileset sources_1

# ── ram.hex location ─────────────────────────────────────────
# ram_dp.sv reads its init image relative to the synth working
# directory. Drop a baremetal ram.hex into firmware/ and Vivado
# will pick it up via the path below.
set hex_dir "$script_dir/firmware"
if { ![file exists $hex_dir] } { file mkdir $hex_dir }
set_property -name {STEPS.SYNTH_DESIGN.ARGS.MORE OPTIONS} \
             -value "-include_dirs \"$hex_dir\"" \
             -objects [get_runs synth_1]

puts ""
puts "================================================================"
puts " Project created: $proj_dir/$proj_name.xpr"
puts " Part:            $part"
puts " Top:             ntiny_zybo_top"
puts ""
puts " Next: drop a baremetal ram.hex into:"
puts "   $hex_dir/ram.hex"
puts " then 'launch_runs synth_1 -to_step write_bitstream'."
puts "================================================================"
