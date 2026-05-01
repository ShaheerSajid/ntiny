# ntiny — top-level dispatch Makefile.
#
# All real work lives in the subdirectory Makefiles:
#   flows/simulation/          Verilator / Questa / Incisive sim drivers
#   software/mem_init/tests/   bare-metal hex generation
#   software/linux/            Linux kernel + OpenSBI + ram.hex
#   verification/riscof/       RISCOF compliance suite
#   verification/riscv-dv/     riscv-dv random instruction tests
#   flows/synthesis/{fpga,genus}/   FPGA + ASIC synthesis
#   flows/physical_design/     PnR
#
# Quickstart:
#   make help                  list targets
#   make sim sim=verilator     bare-metal sim (default test=baremetal)
#   make linux                 boot Linux on the Verilator model
#   make riscof                RISCOF compliance + summary
#   make dv                    riscv-dv random regression

.PHONY: help
help:
	@grep -E '^[a-zA-Z_-]+:.*?# .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?# "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

# ── Simulation ───────────────────────────────────────────────────────────────

.PHONY: mem_init
mem_init: # Generate ram.hex for bare-metal sim — arg: test=<name> (baremetal|dhrystone|coremark)
	make -C software/mem_init/tests $(test)

.PHONY: sim
sim: # Run bare-metal sim — arg: sim=<verilator|verilator_trace|verilator_test|questa|incisive>
	make -C flows/simulation $(sim)

.PHONY: linux
linux: # Boot Linux on Verilator (logs in flows/simulation/logs/) — arg: TO=<cycles>
	make -C flows/simulation linux $(if $(TO),TO=$(TO))

# ── Verification ─────────────────────────────────────────────────────────────

.PHONY: riscof
riscof: # RISCOF compliance suite (build + run + summary)
	make -C verification/riscof run

.PHONY: riscof_fpu
riscof_fpu: # RISCOF F-extension compliance suite
	make -C verification/riscof run_fpu

.PHONY: riscof_summary
riscof_summary: # Print RISCOF pass/fail summary (no rerun)
	make -C verification/riscof summary

.PHONY: dv
dv: # riscv-dv random regression (build + gen + spike + dut + compare)
	make -C verification/riscv-dv verilator
	make -C verification/riscv-dv run

.PHONY: dv_test
dv_test: # Run one riscv-dv test — arg: TEST=<name> [SEED=<n>]
	make -C verification/riscv-dv verilator
	make -C verification/riscv-dv run TEST=$(TEST) $(if $(SEED),SEED=$(SEED))

.PHONY: dv_list
dv_list: # List available riscv-dv tests
	make -C verification/riscv-dv list

# ── Synthesis / PnR ──────────────────────────────────────────────────────────

.PHONY: synth_fpga
synth_fpga: # FPGA synthesis (Quartus) — arg: proj=<de1soc|de10nano>
	make -C flows/synthesis/fpga/quartus compile proj=$(proj)

.PHONY: program_fpga
program_fpga: # Program FPGA — arg: proj=<de1soc|de10nano>
	make -C flows/synthesis/fpga/quartus program proj=$(proj)

.PHONY: update_fpga
update_fpga: # Update FPGA mem-init — arg: proj=<de1soc|de10nano>
	make -C flows/synthesis/fpga/quartus update proj=$(proj)

.PHONY: synth
synth: # ASIC synthesis — arg: tool=<genus>
	make -C flows/synthesis/genus/script $(tool)

.PHONY: physical
physical: # Place-and-route — arg: tool=<innovus>
	make -C flows/physical_design/config $(tool)

# ── Cleanup ──────────────────────────────────────────────────────────────────

.PHONY: clean
clean: # Clean software + sim + synth + PD artifacts
	make -i -C software/mem_init/tests clean
	make -i -C flows/simulation clean
	make -i -C flows/synthesis/fpga/quartus clean proj=$(proj)
	make -i -C flows/synthesis/genus/script clean
	make -i -C flows/physical_design/config clean

.PHONY: clean_verif
clean_verif: # Clean all verification artifacts
	make -C verification/riscof clean
	make -C verification/riscv-dv clean
