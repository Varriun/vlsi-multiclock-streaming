# Multi-Clock-Domain Streaming System (Verilog, Cyclone IV E)

> TODO (you): 2–3 sentences — what this system does and why it's interesting. Write it yourself.

8-bit samples → FIR filter (100 MHz) → async FIFO (CDC) → UART TX @ 9600 baud (10 MHz), with clock gating on the fast domain when idle.

## Block diagram

TODO (you): add `docs/block_diagram.png` (draw.io / hand-drawn scan is fine).

## Modules

| Module | File | Clock domain | Notes |
|---|---|---|---|
| `my_sys` | `rtl/my_sys.v` | both | Top level |
| `fir` | `rtl/fir.v` | fast_clk (100 MHz) | TODO: taps / structure, 2-cycle latency |
| `afifo` | `rtl/afifo.v` | fast → slow | 16-bit × 8 deep, Gray-coded 4-bit pointers, 2-FF synchronizers |
| `uart` | `rtl/uart.v` | slow_clk (10 MHz) | 1042 clk/bit → 9600 baud, 16 data bits |
| `power_ctrl` | `rtl/power_ctrl.v` | fast_clk | Gates fast clock after 10 idle cycles (ALTCLKCTRL in synth, AND-gate stub in sim) |

## Timing constraints

`constraints/my_sys.sdc`: 100 MHz / 10 MHz clocks declared asynchronous, I/O delays, false paths into the first synchronizer stage.

TODO (you): Fmax and worst-case slack per clock from TimeQuest.

## Results

TODO (you):
- Waveform screenshot: FIFO crossing and one UART frame (`docs/waveform.png`)
- Power with vs. without clock gating (`sim/run_sim.do` vs `sim/run_sim_nogating.do` → Quartus Power Analyzer)
- Resource usage (LEs, registers)

## Running

**ModelSim:** in the Transcript window, `do <path-to-repo>/sim/run_sim.do` (writes `sim/simulation_dump.vcd`).
Other scripts: `run_sim_nogating.do` (clock gating forced off), `run_baud_check.do` (UART bit-timing view).

**Icarus Verilog:**
```
iverilog -g2012 -DSIMULATION -o sim.out rtl/*.v tb/my_sys_tb.v && vvp sim.out
```

**Quartus:** open `quartus/vlsi.qpf` (Quartus Prime Lite 19.1, EP4CE115F29C7). Power analysis reads `sim/simulation_dump.vcd`, so run the sim first.

## Credits

VLSI course final project, team of 2: Omri Ben Ami and Tal-Shalom Ben Ovadia.
TODO (you): who did what.
