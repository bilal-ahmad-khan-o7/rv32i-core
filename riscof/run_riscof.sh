#!/usr/bin/env bash
# run_riscof.sh - run the RV32I architectural tests on the core, compare with Spike.
#
#   ./run_riscof.sh            whole rv32i_m/I suite (38 tests)
#   ./run_riscof.sh add-01     only tests whose name contains "add-01"
#   SUITE=riscv-arch-test/riscv-test-suite/rv32i_m/M ./run_riscof.sh mul
#                              another suite folder (the ISA YAML must allow it)
#   CONFIG=config_mul.ini ./run_riscof.sh mul
#                              another config file (e.g. one naming rv32im_isa.yaml)
#
# Run from this folder (riscof/) with the Python venv active.
# Exit code: 0 only if every selected test passed.
set -euo pipefail
cd "$(dirname "$0")"

SUITE=${SUITE:-riscv-arch-test/riscv-test-suite/rv32i_m/I}   # override from outside
CONFIG=${CONFIG:-config.ini}
ENV=riscv-arch-test/riscv-test-suite/env
LOG=last_run.log

if [ $# -gt 0 ]; then                       # optional: a smaller test list
  riscof testlist --config="$CONFIG" --suite="$SUITE" --env="$ENV" > /dev/null
  python3 - "$1" <<'PY'
import sys, yaml
keep = sys.argv[1]
tests = yaml.safe_load(open("riscof_work/test_list.yaml"))
tests = {k: v for k, v in tests.items() if keep in k}
yaml.safe_dump(tests, open("selected_tests.yaml", "w"))
print(f"selected {len(tests)} test(s) matching '{keep}'")
PY
  EXTRA=(--testfile=selected_tests.yaml)
else
  EXTRA=()
fi

riscof run --config="$CONFIG" --suite="$SUITE" --env="$ENV" \
           --no-browser "${EXTRA[@]}" 2>&1 | tee "$LOG.tmp"
mv "$LOG.tmp" "$LOG"

# riscof itself exits 0 even when tests fail, so count the verdicts here.
passed=$(grep -c ": Passed" "$LOG" || true)
failed=$(grep -c ": Failed" "$LOG" || true)
echo
echo "RISCOF summary: $passed passed, $failed failed  (report: riscof_work/report.html)"
[ "$failed" -eq 0 ] && [ "$passed" -gt 0 ]
