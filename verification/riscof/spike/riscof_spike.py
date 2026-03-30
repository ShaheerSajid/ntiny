import os
import logging
import shutil

import riscof.utils as utils
from riscof.pluginTemplate import pluginTemplate

logger = logging.getLogger()

class spike(pluginTemplate):
    __model__ = "spike"
    __version__ = "1.1.1"

    def __init__(self, *args, **kwargs):
        sclass = super().__init__(*args, **kwargs)
        config = kwargs.get('config')

        self.ref_exe = os.path.join(config['PATH'] if 'PATH' in config else "", "spike")
        self.num_jobs = str(config['jobs'] if 'jobs' in config else 1)
        self.pluginpath = os.path.abspath(config['pluginpath'])
        self.isa_spec = os.path.abspath(config['ispec']) if 'ispec' in config else ''
        self.platform_spec = os.path.abspath(config['pspec']) if 'pspec' in config else ''
        self.make = config['make'] if 'make' in config else 'make'
        self.toolchain = config.get('toolchain', '/opt/riscv/bin')
        return sclass

    def initialise(self, suite, work_dir, archtest_env):
        self.suite = suite
        if shutil.which(self.ref_exe) is None:
            logger.error('Spike not found at %s. Please install or set PATH.', self.ref_exe)
            raise SystemExit(1)
        self.work_dir = work_dir

        gcc = os.path.join(self.toolchain, 'riscv64-unknown-elf-gcc')
        objdump = os.path.join(self.toolchain, 'riscv64-unknown-elf-objdump')

        self.compile_cmd = gcc + \
            ' -march={0} -mabi=ilp32' + \
            ' -static -mcmodel=medany -fvisibility=hidden -nostdlib -nostartfiles' + \
            ' -T ' + self.pluginpath + '/env/link.ld' + \
            ' -I ' + self.pluginpath + '/env/' + \
            ' -I ' + archtest_env
        self.objdump_cmd = objdump + ' -D {0} > {1};'

    def build(self, isa_yaml, platform_yaml):
        ispec = utils.load_yaml(isa_yaml)['hart0']
        self.xlen = '32'
        self.isa = 'rv32'
        if "I" in ispec["ISA"]:
            self.isa += 'i'
        if "M" in ispec["ISA"]:
            self.isa += 'm'
        if "A" in ispec["ISA"]:
            self.isa += 'a'
        if "F" in ispec["ISA"]:
            self.isa += 'f'
        if "C" in ispec["ISA"]:
            self.isa += 'c'
        if "Zba" in ispec["ISA"]:
            self.isa += '_zba'
        if "Zbb" in ispec["ISA"]:
            self.isa += '_zbb'

    def runTests(self, testList, cgf_file=None):
        if os.path.exists(self.work_dir + "/Makefile." + self.name[:-1]):
            os.remove(self.work_dir + "/Makefile." + self.name[:-1])
        make = utils.makeUtil(
            makefilePath=os.path.join(self.work_dir, "Makefile." + self.name[:-1]))
        make.makeCommand = self.make + ' -j' + self.num_jobs

        for file in testList:
            testentry = testList[file]
            test = testentry['test_path']
            test_dir = testentry['work_dir']

            elf = 'ref.elf'
            sig_file = os.path.join(test_dir, self.name[:-1] + ".signature")

            execute = "@cd " + test_dir + ";"

            march = testentry['isa'].lower()
            if '_zicsr' not in march and 'zicsr' not in march:
                march += '_zicsr'

            cmd = self.compile_cmd.format(march) + ' ' + test + ' -o ' + elf
            compile_cmd = cmd + ' -D' + " -D".join(testentry['macros'])
            execute += compile_cmd + ";"

            execute += self.objdump_cmd.format(elf, 'ref.disass')

            # Run spike with ISA string and signature extraction
            execute += self.ref_exe + ' --isa={0} +signature={1} +signature-granularity=4 {2};'.format(
                self.isa, sig_file, elf)

            make.add_target(execute)
        make.execute_all(self.work_dir)
