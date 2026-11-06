# =============================================================================
# run_sim.do  —  one-click ModelSim script for the VLSI project
# =============================================================================
# WHAT IT DOES:
#   1. Moves into the project folder.
#   2. Compiles all the Verilog files (in SIMULATION mode, so it uses the
#      simple clock-gating stub instead of the ALTCLKCTRL hardware IP, which
#      needs special Altera libraries that plain ModelSim does not have).
#   3. Loads the testbench and runs it to the end.
#   4. The testbench automatically writes the recording file
#      "simulation_dump.vcd" into this same folder.
#
# HOW TO RUN (in the ModelSim Transcript window, type exactly this):
#   do <path-to-repo>/sim/run_sim.do
# =============================================================================

# 1. Work in the project folder
cd [file dirname [info script]]

# 2. Create the compile library (harmless warning if it already exists)
vlib work

# 3. Compile design + testbench.  +define+SIMULATION selects the AND-gate
#    clock stub so no Altera simulation library is required.
vlog +define+SIMULATION ../rtl/my_sys.v ../rtl/fir.v ../rtl/afifo.v ../rtl/uart.v ../rtl/power_ctrl.v ../tb/my_sys_tb.v

# 4. Load the top-level testbench (-voptargs=+acc keeps all signals visible
#    so they get recorded into the VCD)
vsim -voptargs=+acc work.my_sys_tb +vcd

# 5. Run until the testbench finishes ($finish)
run -all

# 6. Done
echo "================================================================"
echo "  SIMULATION FINISHED."
echo "  Recording saved as: simulation_dump.vcd (in the project folder)"
echo "================================================================"
