# =============================================================================
# run_baud_check.do  —  show the UART output to verify 9600 baud
# =============================================================================
# Runs a short 4 ms slice (enough to capture the first couple of UART frames),
# and puts tx / tx_busy / state on the waveform so you can measure one bit.
#
# HOW TO RUN (in the ModelSim Transcript):
#   do <path-to-repo>/sim/run_baud_check.do
# =============================================================================

cd [file dirname [info script]]
vlib work
vlog +define+SIMULATION ../rtl/my_sys.v ../rtl/fir.v ../rtl/afifo.v ../rtl/uart.v ../rtl/power_ctrl.v ../tb/my_sys_tb.v
vsim -voptargs=+acc work.my_sys_tb

# Put the useful signals on the wave window
add wave -divider "UART output"
add wave sim:/my_sys_tb/tx
add wave sim:/my_sys_tb/dut/u_uart/tx_busy
add wave sim:/my_sys_tb/dut/u_uart/state

# 4 ms is enough for ~2 full UART frames (each frame = 18 bits x 104 us = 1.875 ms)
run 4ms

# Fit everything in the wave window
wave zoom full
echo "=== Done. Now zoom into a frame and measure one bit (~104 us). ==="
