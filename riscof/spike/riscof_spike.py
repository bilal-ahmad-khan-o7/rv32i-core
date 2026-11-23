"""RISCOF plugin for Spike, the reference model.

Started from the template that  riscof setup --dutname=spike  generates,
with three changes: a configurable toolchain prefix (riscv64-unknown-elf-),
"~" allowed in PATH, and a longer timeout. It compiles each test with
Spike's own env/ (tohost-based halt) and lets Spike write the signature.
"""
import logging
import os

import riscof.utils as utils
from riscof.pluginTemplate import pluginTemplate

logger = logging.getLogger()


class spike(pluginTemplate):
    __model__ = "spike"
    __version__ = "reference"

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        config = kwargs.get("config")
        if config is None:
            raise SystemExit("spike: missing [spike] section in config.ini")
        cfg_dir = kwargs.get("config_dir", os.getcwd())
        self.pluginpath = os.path.normpath(os.path.join(cfg_dir, config["pluginpath"]))
        self.spike_exe = os.path.join(os.path.expanduser(config.get("PATH", "")), "spike")
        self.prefix = config.get("prefix", "riscv64-unknown-elf-")
        self.num_jobs = str(config.get("jobs", 1))
        self.timeout = int(config.get("timeout", 3600))

    def initialise(self, suite, work_dir, archtest_env):
        self.work_dir = work_dir
        self.suite_dir = suite
        self.compile_cmd = (
            self.prefix + "gcc -march={0} -mabi=ilp32 -mno-relax"   # same binary as the DUT
            " -static -mcmodel=medany -fvisibility=hidden -nostdlib -nostartfiles -g"
            " -T " + os.path.join(self.pluginpath, "env", "link.ld") +
            " -I " + os.path.join(self.pluginpath, "env") +
            " -I " + archtest_env +
            " {1} -o {2} {3}")

    def build(self, isa_yaml, platform_yaml):
        # RISCOF passes the DUT's ISA file, so Spike models exactly what the DUT claims.
        ispec = utils.load_yaml(isa_yaml)["hart0"]
        self.isa = ispec["ISA"].lower()                  # "RV32I" -> "rv32i"

    def runTests(self, testList):
        makefile = os.path.join(self.work_dir, "Makefile." + self.name[:-1])
        if os.path.exists(makefile):
            os.remove(makefile)
        make = utils.makeUtil(makefilePath=makefile)
        make.makeCommand = "make -k -j" + self.num_jobs
        for testname, entry in testList.items():
            test_dir = entry["work_dir"]
            sig_file = os.path.join(test_dir, self.name[:-1] + ".signature")
            macros = " -D" + " -D".join(entry["macros"])
            compile_cmd = self.compile_cmd.format(
                entry["isa"].lower(), entry["test_path"], "ref.elf", macros)
            sim_cmd = "{0} --isa={1} +signature={2} +signature-granularity=4 ref.elf".format(
                self.spike_exe, self.isa, sig_file)
            make.add_target("@cd {0}; {1}; {2};".format(test_dir, compile_cmd, sim_cmd))
        make.execute_all(self.work_dir, timeout=self.timeout)
