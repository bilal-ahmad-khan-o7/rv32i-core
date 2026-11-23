"""RISCOF plugin for the RV32I cores (DUT = device under test).

core=single_cycle or core=pipelined in config.ini picks which one is compiled.

RISCOF imports this file as module "riscof_rv32i_core" and creates the class
"rv32i_core" (both names come from DUTPlugin=rv32i_core in config.ini).
It then calls, in order: __init__ -> initialise -> build -> runTests.
"""
import logging
import os
import subprocess

import riscof.utils as utils
from riscof.pluginTemplate import pluginTemplate

logger = logging.getLogger()


def config_path(config_dir, path):
    """A path from config.ini, taken relative to the folder holding config.ini."""
    return os.path.normpath(os.path.join(config_dir, os.path.expanduser(path)))


class rv32i_core(pluginTemplate):
    __model__ = "rv32i_core"
    __version__ = "1.0"

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)   # self.name becomes "DUT-rv32i_core:"
        config = kwargs.get("config")
        if config is None:
            raise SystemExit("rv32i_core: missing [rv32i_core] section in config.ini")
        cfg_dir = kwargs.get("config_dir", os.getcwd())

        # ---- paths -------------------------------------------------------
        self.pluginpath = config_path(cfg_dir, config["pluginpath"])
        self.isa_spec = config_path(cfg_dir, config["ispec"])
        self.platform_spec = config_path(cfg_dir, config["pspec"])
        # the repository root: the paths in rtl_<core>.f are relative to it
        self.core_root = config_path(cfg_dir, config.get("core_root", ".."))
        # this riscof/ folder: holds tb/, tools/ and the rtl_<core>.f file lists
        self.riscof_root = os.path.dirname(self.pluginpath)
        # which core to test: single_cycle or pipelined
        self.core = config.get("core", "single_cycle")
        if self.core not in ("single_cycle", "pipelined"):
            raise SystemExit("rv32i_core: core must be single_cycle or pipelined, not " + self.core)

        # ---- options -----------------------------------------------------
        self.prefix = config.get("prefix", "riscv64-unknown-elf-")
        self.num_jobs = str(config.get("jobs", 1))
        self.timeout = int(config.get("timeout", 3600))     # seconds, whole suite
        self.max_cycles = int(config.get("max_cycles", 2000000))
        self.target_run = config.get("target_run", "1") != "0"

    def initialise(self, suite, work_dir, archtest_env):
        self.work_dir = work_dir          # riscof_work/: everything this plugin creates goes here
        self.suite_dir = suite
        # {0}=march  {1}=test .S file  {2}=output ELF  {3}=-D macros
        # -mno-relax: the tests' LA() macro switches on ".option rvc" around an
        # .align; with linker relaxation, binutils 2.4x then pads with a 2-byte
        # c.nop, which an RV32I core cannot run. The Spike plugin uses it too,
        # so both run the same binary.
        self.compile_cmd = (
            self.prefix + "gcc -march={0} -mabi=ilp32 -mno-relax"
            " -static -mcmodel=medany -fvisibility=hidden -nostdlib -nostartfiles -g"
            " -T " + os.path.join(self.pluginpath, "env", "link.ld") +
            " -I " + os.path.join(self.pluginpath, "env") +
            " -I " + archtest_env +
            " {1} -o {2} {3}")

    def build(self, isa_yaml, platform_yaml):
        ispec = utils.load_yaml(isa_yaml)["hart0"]
        if 32 not in ispec["supported_xlen"]:
            raise SystemExit("rv32i_core: this core is RV32 only")

        # Compile the testbench ONCE; every test reuses the same tb_riscof.vvp.
        rtl_f = os.path.join(self.riscof_root, "rtl_" + self.core + ".f")
        if not os.path.isfile(rtl_f):
            raise SystemExit("rv32i_core: no file list " + rtl_f)
        with open(rtl_f) as f:
            rtl = [os.path.join(self.core_root, line.strip()) for line in f
                   if line.strip() and not line.lstrip().startswith(("#", "//"))]
        tb = os.path.join(self.riscof_root, "tb", "tb_riscof.sv")
        self.vvp = os.path.join(self.work_dir, "tb_riscof.vvp")
        defines = ["-DPIPELINED"] if self.core == "pipelined" else []
        cmd = ["iverilog", "-g2012"] + defines + ["-o", self.vvp] + rtl + [tb]
        logger.info("rv32i_core: compiling testbench for the %s core", self.core)
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode != 0:
            raise SystemExit("rv32i_core: iverilog failed\n" + result.stdout + result.stderr)

    def runTests(self, testList):
        makefile = os.path.join(self.work_dir, "Makefile." + self.name[:-1])
        if os.path.exists(makefile):
            os.remove(makefile)
        make = utils.makeUtil(makefilePath=makefile)
        make.makeCommand = "make -k -j" + self.num_jobs

        run_test = os.path.join(self.riscof_root, "tools", "run_test.py")
        for testname, entry in testList.items():
            test_dir = entry["work_dir"]                     # one folder per test
            sig_file = os.path.join(test_dir, self.name[:-1] + ".signature")
            macros = " -D" + " -D".join(entry["macros"])
            compile_cmd = self.compile_cmd.format(
                entry["isa"].lower(), entry["test_path"], "my.elf", macros)
            if self.target_run:
                sim_cmd = ("python3 {0} --elf my.elf --vvp {1} --sig {2}"
                           " --prefix {3} --max-cycles {4} > sim.log 2>&1").format(
                    run_test, self.vvp, sig_file, self.prefix, self.max_cycles)
            else:
                sim_cmd = 'echo "NO RUN"'
            make.add_target("@cd {0}; {1}; {2};".format(test_dir, compile_cmd, sim_cmd))

        make.execute_all(self.work_dir, timeout=self.timeout)
        if not self.target_run:
            raise SystemExit(0)
