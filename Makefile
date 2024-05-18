.PHONY: help
help:
	@grep -E '^[a-zA-Z_-]+:.*?# .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?# "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

.PHONY: mem_init
mem_init: # Generate HEX for memory initialization -> argument: test=test_name (Available: baremetal dhrystone coremark)
	make -C software/mem_init/tests $(test)

.PHONY: simulation
simulation: # Run Simulation -> argument: sim=simulator_name (Available: questa incisive incisive_gate verilator)
	make -C flows/simulation $(sim)

.PHONY: synth_fpga
synth_fpga: # Run Synthesis FPGA -> argument: proj=board (Available: de1soc de10nano)
	make -C flows/synthesis/fpga/quartus compile proj=$(proj)

.PHONY: program_fpga
program_fpga: # Program FPGA -> argument: proj=board (Available: de1soc de10nano)
	make -C flows/synthesis/fpga/quartus program proj=$(proj)

.PHONY: update_fpga
update_fpga: # Update Memory Initialization FPGA -> argument: proj=board (Available: de1soc de10nano)
	make -C flows/synthesis/fpga/quartus update proj=$(proj)

.PHONY: synth
synth: # Run Synthesis -> argument: tool=synthesizer (Available: genus)
	make -C flows/synthesis/genus/script $(tool)

.PHONY: physical
physical: # Run Physical -> argument: tool=layout (Available: innovus)
	make -C flows/physical_design/config $(tool)

.PHON: clean
clean: 
	make -i -C software/mem_init/tests clean
	make -i -C flows/simulation clean
	make -i -C flows/synthesis/fpga/quartus clean proj=$(proj) 
	make -i -C flows/synthesis/genus/script clean
	make -i -C flows/physical_design/config clean