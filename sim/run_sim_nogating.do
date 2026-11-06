# =============================================================================
# run_sim_nogating.do  —  SCENARIO A: clock gating DISABLED
# =============================================================================
# Same test as run_sim.do, BUT it forces the clock-enable signal HIGH for the
# whole run, so the fast clock NEVER stops (the power-saver is effectively
# turned off).  This is the "gating disabled" case the assignment asks for.
#
# It overwrites simulation_dump.vcd with the no-gating recording.
# (You already noted the gating-ON dynamic power = 8.07 mW, so overwriting
#  is fine — we just need the new number after this.)
#
# HOW TO RUN (in the ModelSim Transcript):
#   do <path-to-repo>/sim/run_sim_nogating.do
# =============================================================================

cd [file dirname [info script]]
vlib work
vlog +define+SIMULATION ../rtl/my_sys.v ../rtl/fir.v ../rtl/afifo.v ../rtl/uart.v ../rtl/power_ctrl.v ../tb/my_sys_tb.v
vsim -voptargs=+acc work.my_sys_tb

# >>> THE KEY LINE: hold clk_en = 1 for the entire simulation (no gating) <<<
force -freeze sim:/my_sys_tb/dut/clk_en 1 0

run -all

echo "================================================================"
echo "  NO-GATING (power-saver OFF) simulation FINISHED."
echo "  Recording overwrote simulation_dump.vcd"
echo "================================================================"
