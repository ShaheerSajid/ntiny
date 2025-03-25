mem_init:
	./split ../../software/mem_init/tests/mem.text imem.text dmem.text
	cp ../../software/mem_init/tests/boot.text ./

questa_sim:
	if [ -d "work" ]; then  vdel -lib work -all; fi
	vlib work
	vlog -sv -work work ../../verification/dv/src/pkg.sv
	vlog -sv -work work ../../verification/dv/src/tracer_pkg.sv
	vlog -sv -work work ../../verification/dv/src/tracer.sv
	vlog -sv -work work \
	+define+BOOT \
	+incdir+../../design/uncore/i2c/src/ \
	+incdir+../../design/uncore/timer/src/ \
	+incdir+../../design/uncore/pwm/src/ \
	+incdir+../../design/uncore/spi/src/ \
	+incdir+../../design/uncore/uart/src/ \
	-f src.args
	vlog -sv -work work -dpiheader testbench/dpiheader.h testbench/SimJTAG.v
	vlog -sv -work work -dpiheader testbench/dpiheader.h testbench/uartdpi.sv
	vlog -64 -ccflags "-I./" testbench/remote_bitbang.cc
	vlog -64 -ccflags "-I./" testbench/SimJTAG.cc
	vlog -64 -ccflags "-I./" testbench/uartdpi.c
	vlog -sv -work work testbench/arm_boot_dummy.v
	vlog -sv -work work testbench/arm_imem_dummy.v
	vlog -sv -work work testbench/arm_dmem_dummy.v
	vlog -sv -work work testbench/mem.v
	if [ $# -eq 0 ]; then vlog -sv -work work testbench/tb_soc_top.v; else vlog -sv -work work +define+$(DPI) testbench/tb_soc_top.v; fi
	vsim -c -t 1ps -L work -voptargs="+acc" tb_soc_top  -do "run -all; exit"

incisive_sim:
	irun \
	-batch \
	-s \
	-sv \
	+linedebug \
	+access+rwc \
	+incdir+../../design/uncore/i2c/src/ \
	+incdir+../../design/uncore/timer/src/ \
	+incdir+../../design/uncore/pwm/src/ \
	+incdir+../../design/uncore/spi/src/ \
	+incdir+../../design/uncore/uart/src/ \
	+define+BOOT \
	-f src.args \
	testbench/arm_boot_dummy.v \
	testbench/arm_imem_dummy.v \
	testbench/arm_dmem_dummy.v \
	testbench/mem.v \
	testbench/tb_soc_top.v \
	-q \
	-timescale 1ns/10ps \
	-top tb_soc_top \
	-input "@run; exit"

incisive_sim_gate:
	irun \
	-gui \
	-s \
	+linedebug \
	+access+rwc \
    ../synthesis/genus/work/output/top_m.v \
	../65GP_TT/verilog/tcbn65gplus.v \
	../65GP_TT/verilog/tphn65gpgv2od3_sl.v \
	testbench/arm_boot_dummy.v \
	testbench/arm_imem_dummy.v \
	testbench/arm_dmem_dummy.v \
	testbench/tb_soc_top_gate.v \
	-q \
	-timescale 1ns/10ps \
	-top tb_top

verilator_sim:
	verilator \
	-Wno-UNOPTFLAT \
	-Wno-INITIALDLY \
	-Wno-UNUSED \
	-Wno-WIDTH \
	-Wno-CASEINCOMPLETE \
	-Wno-PINMISSING \
	-Wno-MULTIDRIVEN \
	-Wno-STMTDLY \
	-Wno-UNPACKED \
	-Wno-UNSIGNED \
	-Wno-LITENDIAN \
	-Wno-MODDUP \
	--no-timing \
	--timescale-override 1ns/10ps \
	-O3 \
	-DVERILATOR_SIM \
	--trace \
	-sv --top-module tb_soc_top \
	--cc \
	+incdir+../../design/uncore/i2c/src/ \
	+incdir+../../design/uncore/timer/src/ \
	+incdir+../../design/uncore/pwm/src/ \
	+incdir+../../design/uncore/spi/src/ \
	+incdir+../../design/uncore/uart/src/ \
	-f src.args \
	testbench/uartdpi.c \
	testbench/uartdpi.sv \
	testbench/arm_boot_dummy.v \
	testbench/arm_imem_dummy.v \
	testbench/arm_dmem_dummy.v \
	testbench/mem.v \
	testbench/bootmem.v \
	testbench/tb_soc_top.v \
	--exe testbench/main.cpp
	make -j -C obj_dir/ -f Vtb_soc_top.mk Vtb_soc_top
	mv obj_dir/Vtb_soc_top ./
	./Vtb_soc_top
	gtkwave --dump waveform.vcd
			
.PHONY: questa
questa: clean mem_init questa_sim

.PHONY: incisive
incisive: clean mem_init incisive_sim

.PHONY: incisive_gate
incisive_gate: clean mem_init incisive_sim_gate

.PHONY: verilator
verilator: clean mem_init verilator_sim

.PHONY: clean
clean:
	rm -f *.key *.log *.history transcript *.wlf *.text *.X *.svcf *.vcd
	if [ -d "work" ]; then rm -r work; fi
	if [ -d "obj_dir" ]; then rm -r obj_dir; fi
	if [ -f "Vtb_soc_top" ]; then rm Vtb_soc_top; fi
	if [ -d "INCA_libs" ]; then rm -r INCA_libs; fi
	if [ -d "waves.shm" ]; then rm -r waves.shm; fi
	if [ -d ".simvision" ]; then rm -r .simvision; fi
