"""RISCOF DUT plugin for the ntiny OoO core.

Mirrors the in-order plugin (verification/riscof/ntiny/) but points
at the OoO core's standalone Verilator build under
flows/simulation_ooo/. The OoO core supports RV32IM only at M3-A
(no Zicsr/no privilege/no compressed/no Zba_Zbb_Zbc_Zbs/no F),
which limits the meaningful suite to rv32i_m/I and rv32i_m/M.
"""
import os
import logging

import riscof.utils as utils
from riscof.pluginTemplate import pluginTemplate

logger = logging.getLogger()


class ntiny_ooo(pluginTemplate):
    __model__ = "ntiny_ooo"
    __version__ = "1.0"

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        config = kwargs.get('config')
        if config is None:
            print("Please enter input file paths in configuration.")
            raise SystemExit(1)

        self.num_jobs = str(config['jobs'] if 'jobs' in config else 1)
        self.pluginpath = os.path.abspath(config['pluginpath'])
        self.isa_spec = os.path.abspath(config['ispec'])
        self.platform_spec = os.path.abspath(config['pspec'])
        self.target_run = config.get('target_run', '1') != '0'

        # Repo root: pluginpath = .../verification/riscof_ooo/ntiny_ooo
        self.repo_root = os.path.abspath(os.path.join(
            self.pluginpath, '..', '..', '..'))
        self.sim_dir = os.path.join(self.repo_root, 'flows', 'simulation_ooo')
        self.verilator_bin = os.path.join(self.sim_dir, 'obj_dir', 'Vtb_ooo')
        self.hex_text_tool = os.path.join(self.repo_root,
            'software', 'tools', 'hex_text.py')
        self.run_script = os.path.join(self.pluginpath, 'run_test.sh')
        self.toolchain = config.get('toolchain', '/opt/riscv-elf/bin')

    def initialise(self, suite, work_dir, archtest_env):
        self.work_dir = work_dir
        self.suite_dir = suite

        if not os.path.isfile(self.verilator_bin):
            logger.warning(
                'OoO Verilator binary not found at %s. (--no-dut-run is OK; '
                'DUT-side run will fail until you build it.)',
                self.verilator_bin)

        gcc = os.path.join(self.toolchain, 'riscv64-unknown-elf-gcc')
        # No -Zicsr in the OoO ISA, but the env headers still emit
        # CSR ops in the trap-prolog macros — we let them assemble
        # (the OoO decoder marks them illegal+nop, so they silently
        # commit without writing a CSR file we don't have).
        self.compile_cmd = gcc + \
            ' -march={0} -mabi=ilp32' + \
            ' -static -mcmodel=medany -fvisibility=hidden -nostdlib -nostartfiles -g' + \
            ' -T ' + self.pluginpath + '/env/link.ld' + \
            ' -I ' + self.pluginpath + '/env/' + \
            ' -I ' + archtest_env + \
            ' {1} -o {2} {3}'

    def build(self, isa_yaml, platform_yaml):
        utils.load_yaml(isa_yaml)['hart0']
        self.xlen = '32'

    def runTests(self, testList):
        if os.path.exists(self.work_dir + "/Makefile." + self.name[:-1]):
            os.remove(self.work_dir + "/Makefile." + self.name[:-1])
        make = utils.makeUtil(
            makefilePath=os.path.join(self.work_dir, "Makefile." + self.name[:-1]))
        make.makeCommand = 'make -k -j' + self.num_jobs

        # Optional comma-separated path-substring skip filter.
        # Used to bring up the suite category by category — e.g.
        # `RISCOF_SKIP=privilege,vm_sv32,vm_pmp` skips the parts the
        # OoO core can't handle yet.
        skip_env = os.environ.get('RISCOF_SKIP', '').strip()
        skip_substrs = [s for s in skip_env.split(',') if s]

        for testname in testList:
            testentry = testList[testname]
            test = testentry['test_path']
            if any(sub in test for sub in skip_substrs):
                logger.info('RISCOF_SKIP: dropping %s', testname)
                continue
            test_dir = testentry['work_dir']
            elf = 'my.elf'
            sig_file = os.path.join(test_dir, self.name[:-1] + ".signature")
            compile_macros = ' -D' + " -D".join(testentry['macros'])

            march = testentry['isa'].lower()
            # Always include _zicsr — the env headers reference CSR
            # ops in their boilerplate and the assembler refuses to
            # encode them otherwise. The OoO decoder treats CSR
            # opcodes as illegal-but-silently-committing nops, so
            # the test still runs.
            if '_zicsr' not in march and 'zicsr' not in march:
                march += '_zicsr'

            compile_cmd = self.compile_cmd.format(march, test, elf, compile_macros)

            if self.target_run:
                simcmd = '{script} {elf} {sig} {tc} {vbin} {ht}'.format(
                    script=self.run_script,
                    elf=elf,
                    sig=sig_file,
                    tc=self.toolchain,
                    vbin=self.verilator_bin,
                    ht=self.hex_text_tool
                )
            else:
                simcmd = 'echo "NO RUN"'

            execute = '@cd {dir}; {compile}; {sim};'.format(
                dir=test_dir, compile=compile_cmd, sim=simcmd)
            make.add_target(execute)

        make.execute_all(self.work_dir)

        if not self.target_run:
            raise SystemExit(0)
