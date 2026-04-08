import os
import logging

import riscof.utils as utils
from riscof.pluginTemplate import pluginTemplate

logger = logging.getLogger()

class ntiny(pluginTemplate):
    __model__ = "ntiny"
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

        if 'target_run' in config and config['target_run'] == '0':
            self.target_run = False
        else:
            self.target_run = True

        # Resolve paths
        self.repo_root = os.path.abspath(os.path.join(self.pluginpath, '..', '..', '..'))
        self.sim_dir = os.path.join(self.repo_root, 'flows', 'simulation')
        self.verilator_bin = os.path.join(self.sim_dir, 'Vtb_soc_top')
        self.hex_text_tool = os.path.join(self.repo_root,
            'software', 'tools', 'hex_text.py')
        self.run_script = os.path.join(self.pluginpath, 'run_test.sh')
        self.toolchain = config.get('toolchain', '/opt/riscv/bin')

    def initialise(self, suite, work_dir, archtest_env):
        self.work_dir = work_dir
        self.suite_dir = suite

        # Soft check: warn if Vtb_soc_top is missing, but don't abort.
        # We don't abort here because (a) `riscof run --no-dut-run` only
        # needs the plugin to load (not actually run), and (b) the
        # `make gen_refs` workflow generates spike refs first, then the
        # user iterates on the DUT separately. If the user calls a
        # `riscof run` that DOES need the binary, it will fail in
        # run_test.sh anyway with a clear error.
        if not os.path.isfile(self.verilator_bin):
            logger.warning(
                'Verilator binary not found at %s. (Reference-only run is OK; '
                'DUT-side run will fail until you build it.)',
                self.verilator_bin)

        gcc = os.path.join(self.toolchain, 'riscv64-unknown-elf-gcc')
        self.compile_cmd = gcc + \
            ' -march={0} -mabi=ilp32' + \
            ' -static -mcmodel=medany -fvisibility=hidden -nostdlib -nostartfiles -g' + \
            ' -T ' + self.pluginpath + '/env/link.ld' + \
            ' -I ' + self.pluginpath + '/env/' + \
            ' -I ' + archtest_env + \
            ' {1} -o {2} {3}'

    def build(self, isa_yaml, platform_yaml):
        ispec = utils.load_yaml(isa_yaml)['hart0']
        self.xlen = '32'

    def runTests(self, testList):
        if os.path.exists(self.work_dir + "/Makefile." + self.name[:-1]):
            os.remove(self.work_dir + "/Makefile." + self.name[:-1])
        make = utils.makeUtil(
            makefilePath=os.path.join(self.work_dir, "Makefile." + self.name[:-1]))
        make.makeCommand = 'make -k -j' + self.num_jobs

        for testname in testList:
            testentry = testList[testname]
            test = testentry['test_path']
            test_dir = testentry['work_dir']
            elf = 'my.elf'
            sig_file = os.path.join(test_dir, self.name[:-1] + ".signature")
            compile_macros = ' -D' + " -D".join(testentry['macros'])

            # Build march string, ensure _zicsr is present
            march = testentry['isa'].lower()
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
