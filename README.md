# Multi-Clock-Domain Streaming System (Verilog, Cyclone IV E)

A small streaming datapath that filters 8-bit samples in a 100 MHz domain, carries the results across an asynchronous FIFO into a 10 MHz domain, and sends them out over a UART. The fast domain clock-gates itself when there is no input, so the design covers the three things that usually break first in multi-clock hardware: clock-domain crossing, clock gating, and timing constraints for unrelated clocks.

```
data_in[7:0] ─► FIR (4-tap) ─► async FIFO ─► UART TX ─► tx
in_valid        gated_clk      gated_clk │ slow_clk     slow_clk
                (100 MHz)          CDC ──┘  (10 MHz)
fast_clk ─► power_ctrl ─► clk_en ─► clock gate ─► gated_clk
```

## Block diagram

> TODO: add `docs/block_diagram.png`.

## Modules

| Module | File | Clock domain | Notes |
|---|---|---|---|
| `my_sys` | `rtl/my_sys.v` | both | Top level. Selects the clock-gate implementation (`SIMULATION` → AND-gate stub, otherwise ALTCLKCTRL). |
| `fir` | `rtl/fir.v` | gated_clk (100 MHz) | 4-tap FIR, h = [1, 2, 3, 4], unsigned 8-bit in → 16-bit out. Two-stage pipeline (shift register, then shift-and-add MAC with no multipliers). Output 2 cycles after `in_valid`. |
| `afifo` | `rtl/afifo.v` | gated_clk → slow_clk | 16-bit × 8 deep. Gray-coded 4-bit pointers (3 address + 1 wrap bit), 2-FF synchronizers in each direction. Writes are ignored while `wfull`. |
| `uart` | `rtl/uart.v` | slow_clk (10 MHz) | TX only. 1042 clocks/bit = 104.2 µs (9596.9 baud, 0.03 % from 9600). Frame: start + 16 data bits LSB-first + stop = 18 bit-times ≈ 1.876 ms per word. |
| `power_ctrl` | `rtl/power_ctrl.v` | fast_clk (never gated) | Drops `clk_en` after 10 consecutive idle cycles, raises it again on the next `in_valid`. |

## Design decisions and known limitations

- **Clock gating: the sim and the hardware use different gates.** Synthesis uses the Cyclone IV ALTCLKCTRL block, which gates glitch-free on the global clock network. Simulation uses `fast_clk & clk_en`, which is not glitch-free. That's acceptable only because `clk_en` is registered on the same `fast_clk` edge. The stub is a simulation model, not a design pattern.
- **16-bit UART frame.** Each FIR result goes out as one non-standard 18-bit frame, not as two standard 8N1 bytes. This keeps the TX FSM simple, but an off-the-shelf UART receiver can't decode it.
- **No back-pressure.** `wfull` isn't connected to anything upstream. If input arrives faster than the UART drains (one word per ~1.876 ms), the FIFO fills and later writes are **dropped silently**. A real system needs `in_ready`/flow control or a deeper FIFO sized for the worst-case burst.
- **Throughput mismatch by design.** The fast side can produce a word every 10 ns. The slow side consumes one every ~1.876 ms. The FIFO absorbs one 8-sample burst, and no more than that.

## Timing constraints

`constraints/my_sys.sdc`:
- `fast_clk` 10 ns and `slow_clk` 100 ns, declared asynchronous with `set_clock_groups`.
- I/O delays on `data_in`/`in_valid` (fast_clk) and `tx`/`tx_busy` (slow_clk).
- `rst_n` false path.
- False paths into the first synchronizer stage (`*_sync1_*`).

Results (Quartus Prime Lite 25.1std, Slow 1200 mV 85 °C model; full report in `report.pdf`):

| Clock | Period | Worst-case setup slack | Implied Fmax |
|---|---|---|---|
| `fast_clk` | 10 ns | +3.77 ns | ≈ 160 MHz |
| `slow_clk` | 100 ns | +89.37 ns | — |

The Unconstrained Paths report shows zero unconstrained endpoints. The critical path is the FIR shift-and-add datapath. The Fmax value is derived as 1 / (10 − 3.77 ns), not read from the Fmax report.
## Verification

`tb/my_sys_tb.v` is self-checking. It drives two independent clocks (100 MHz and 10 MHz, deliberately phase-offset) through:
1. Reset.
2. An 8-sample burst.
3. An idle period long enough to trigger clock gating (checks `clk_en` drops).
4. A wait until the FIFO has drained, then a wake-up burst (checks `clk_en` rises).
5. A drain: wait until every predicted word has arrived and the UART is idle, with a timeout.

Testbench structure:
- **Reference model:** samples `in_valid`/`data_in` at the DUT pins on the raw `fast_clk` and pushes the expected FIR output into a queue.
- **Output monitor:** a UART receiver model that decodes frames from `tx` by sampling mid-bit and checks start and stop bits.
- **Scoreboard:** pops the oldest prediction for each received frame and compares, so wrong values, missing, extra, duplicated and reordered words all fail. Predictions left over at the end are reported as missing frames. The test passes only with zero failures *and* at least one check.

**Result:** `./run_tests.sh` → `ALL 2 RUNS PASSED`. 18/18 checks with clock gating (16 frames + 2 `clk_en` checks), 17/17 with `+nogating` (the idle-gating check is skipped).

**Finding: async FIFO full-flag bug (fixed).** A UART receiver model added to the testbench decoded 15 frames where 8 were expected: 7 words of burst 2, then burst 1's last word, then the same 7 words again. Burst 1's first 7 results were gone.

The cause was `wfull` in `rtl/afifo.v`. It compared the Gray-coded write pointer against the synchronized read pointer with only the MSB inverted, which is the full test for *binary* pointers. For Gray pointers, being exactly one lap ahead flips the top **two** bits (e.g. gray(0) = `0000`, gray(8) = `1100`). With the wrong test the FIFO never reported full, so write #9 overwrote unread data, and the read side then read past valid entries and sent words twice. After the one-bit fix, the decoder receives exactly the eight expected block-1 results (`000a 0028 0064 00c8 012c 0190 01f4 0258`). The original testbench only printed `tx` edges, so the bug had passed simulation and synthesis unnoticed.

**Finding: original stimulus overflowed the FIFO.** With the scoreboard in, the original test reported all 8 burst-2 words missing, with or without clock gating. Burst 2 started ~150 ns after burst 1, before the UART had taken a single word, so the FIFO was genuinely full and the writes were refused (the design has no back-pressure). The stimulus now waits for the FIFO to drain before burst 2.

**Finding: stale full flag while the clock is gated.** The write side's copy of the read pointer is synchronized on `gated_clk`, so it stops updating while the clock is gated. In the gating run, `wfull` is set at 205 ns when burst 1 fills the FIFO and stays set for the whole ~13 ms idle period, even though the UART empties the FIFO during that time. It clears 25 ns after burst 2 starts, once the synchronizer has seen two `gated_clk` edges, which is before the FIR's first output (two edges of pipeline latency) reaches the FIFO. The first word after wake-up (`0357`) arrives correctly, so no data is lost. The design is safe only because the FIR latency is at least as long as the synchronizer depth: a shorter pipeline, or a deeper synchronizer, would risk dropping the first word. Clocking the write-side synchronizer from the ungated `fast_clk` would remove that dependency.

## Results

### Resource usage (EP4CE115F29C7)

| Module | LEs | Registers | Memory bits | DSP |
|---|---|---|---|---|
| `fir` | 58 | 46 | 0 | 0 |
| `afifo` | 164 | 128 | 0 | 0 |
| `uart` | 50 | 34 | 0 | 0 |
| `power_ctrl` | 7 | 5 | 0 | 0 |
| **`my_sys` total** | **277** | **213** | **0** | **0** |

That's under 1 % of the device. The FIFO's 8 × 16-bit storage is built from registers, not M9K block RAM. The FIR uses no DSP blocks, because its constant coefficients reduce to shifts and adds.

### Power

Clock-gating benefit, measured as switching activity in simulation. Dynamic power scales with toggle rate, and a clock net toggles every cycle. The testbench counts rising edges of the raw `fast_clk` and of `gated_clk` after reset, once with gating and once with `+nogating`:

| Run | `fast_clk` edges | `gated_clk` edges | Fast-domain clock activity |
|---|---|---|---|
| Gating on | 3,002,039 | 37 | 0.0012 % |
| Gating off (`+nogating`) | 3,002,039 | 3,002,039 | 100 % |

The fast domain's clock runs only while samples are arriving plus the 10-cycle idle timeout. Through the ~30 ms of UART transmission it is stopped. The saving is in the clock network: the FIR and FIFO data registers already hold their value when idle because of their enables. The saving grows with the fraction of time the input is idle.

No milliwatt figure is given. That needs a VCD-driven Power Analyzer run in Quartus (`sim/run_sim.do` vs `sim/run_sim_nogating.do`, import each `simulation_dump.vcd`), which wasn't done. `report.pdf` contains an earlier *vectorless* estimate: 9.80 mW core dynamic at the default 12.5 % toggle rate vs. 9.65 mW at 1 %. That estimate lowers activity on every net instead of stopping `gated_clk`, so it doesn't isolate the effect of clock gating.

> TODO: waveform screenshot of the FIFO crossing and one UART frame (`docs/waveform.png`).

## Running

**Regression** (Linux or WSL, Icarus Verilog 12.0):
```
./run_tests.sh          # gating + no-gating runs; exits non-zero unless both print TEST PASSED
./run_tests.sh --vcd    # same, plus build/<run>/simulation_dump.vcd (~100 MB each)
```
The script compiles once into `build/` and runs the testbench twice. The verdict comes from the log, because `vvp` exits 0 even when checks fail. It takes about 6 s.

**Testbench plusargs:** `+vcd` dumps the DUT to `simulation_dump.vcd`. `+nogating` forces `clk_en` high.

**ModelSim:** in the Transcript window, run `do <path-to-repo>/sim/run_sim.do` (writes `sim/simulation_dump.vcd`).
Other scripts: `run_sim_nogating.do` (clock gating forced off) and `run_baud_check.do` (UART bit-timing view).

**Quartus:** open `quartus/vlsi.qpf` (EP4CE115F29C7; results above are from Quartus Prime Lite 25.1std). Power analysis reads `sim/simulation_dump.vcd`, so run the simulation first.

## Credits

VLSI course final project, team of 2: Omri Ben Ami and Tal-Shalom Ben Ovadia.