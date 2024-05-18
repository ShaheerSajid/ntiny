compile_proj:
	quartus_sh --flow compile $(proj)/$(proj)
	
update_memory:
	quartus_cdb --update_mif $(proj)/$(proj)
	quartus_asm $(proj)/$(proj)
	
program_fpga:
	quartus_pgm "$(proj)/$(proj).cdf" -m jtag -o "p;$(proj).sof"
	
	
.PHONY: compile
compile: compile_proj

.PHONY: update
update: update_memory

.PHONY: program
program: program_fpga

.PHONY: clean
clean:
	rm -r -d $(proj)/db
	rm -r -d $(proj)/incremental_db
	rm -r -d $(proj)/output_files
	rm -f $(proj)/*.txt $(proj)/*.text
