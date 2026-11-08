#!/usr/bin/env bash
# Regression for my_sys: compile once, run with and without clock gating,
# pass only if every run prints "TEST PASSED".
#
# Usage (from anywhere, Linux/WSL with Icarus Verilog):
#   ./run_tests.sh            run the regression
#   ./run_tests.sh --vcd      also write build/<run>/simulation_dump.vcd (~100 MB each)
#
# Note: vvp exits 0 even when the testbench reports failures, so the
# verdict comes from the log, not from vvp's exit code. A log with no
# PASSED/FAILED line at all (crash, hang, missing check) counts as a failure.
set -u
cd "$(dirname "$0")"

EXTRA=()
[ "${1:-}" = "--vcd" ] && EXTRA+=(+vcd)

BUILD=build
mkdir -p "$BUILD"

echo "── compile"
if ! iverilog -g2012 -DSIMULATION -o "$BUILD/my_sys_tb.vvp" rtl/*.v tb/my_sys_tb.v; then
  echo "  COMPILE ERROR"; exit 1
fi

# run name : plusargs
declare -A RUNS=(
  [gating]=""
  [nogating]="+nogating"
)
ORDER=(gating nogating)

failed=()
for r in "${ORDER[@]}"; do
  echo "── $r"
  mkdir -p "$BUILD/$r"
  # run inside build/<run>/ so each variant gets its own VCD
  # shellcheck disable=SC2086
  ( cd "$BUILD/$r" && vvp -n ../my_sys_tb.vvp ${RUNS[$r]} "${EXTRA[@]}" > sim.log 2>&1 )
  log="$BUILD/$r/sim.log"
  grep -E '(^|] )FAIL|WARNING|CHECKS|ACTIVITY|TEST (PASSED|FAILED)' "$log"
  if ! grep -q 'TEST PASSED' "$log" || grep -q 'TEST FAILED' "$log"; then
    failed+=("$r")
  fi
  echo "   full log: $log"
done

echo
if [ ${#failed[@]} -eq 0 ]; then
  echo "ALL ${#ORDER[@]} RUNS PASSED"
else
  echo "FAILED: ${failed[*]}"; exit 1
fi
