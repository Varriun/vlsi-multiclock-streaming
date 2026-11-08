// my_sys_tb.v  —  Testbench for my_sys
// 1 ns resolution / 1 ps precision: adequate for 100 MHz (10 ns period).
`timescale 1ns/1ps

// Tell my_sys.v to use the AND-gate clock-gating stub instead of ALTCLKCTRL.
// This macro must be defined BEFORE my_sys.v is compiled.
// In Questa: vlog +define+SIMULATION my_sys.v my_sys_tb.v ...
// In VCS:    vcs +define+SIMULATION my_sys.v my_sys_tb.v ...
`define SIMULATION

// testbench overview:
//  two INDEPENDENT, asynchronous clocks:
//    fast_clk: 100 MHz  (half-period = 5 ns)
//    slow_clk:  10 MHz  (half-period = 50 ns)
//
//   test 1  —  Reset:           Hold rst_n low for 5+ fast_clk cycles.
//   test 2  —  First burst:     Stream 8 samples → fills FIFO, UART drains.
//   test 3  —  Idle / gating:   Hold in_valid=0 for 15 fast_clk cycles.
//                                 Expect clk_en to go LOW at cycle 10.
//   test 4  —  Wakeup burst:    Stream 8 more samples.
//                                 Expect clk_en to go HIGH immediately.
//   test 5  —  Drain:           Wait ~32 ms for UART to finish both bursts.
//   test 6  —  $finish.
//
//  timing notes:
//    FIR pipeline = 2 cycles → 8 input samples produce 8 valid outputs
//    starting 2 cycles after first in_valid.
//    Each UART frame = 1+16+1 = 18 bit-times @ 9600 baud ≈ 1.875 ms.
//    8 words × 1.875 ms = 15 ms per burst.
//    Two bursts + margin = 32 ms total simulation time.
//    At timescale 1ns/1ps, 32 ms = 32,000,000 ns — fast in simulation.
//
//  output:
//    "simulation_dump.vcd" captures all hierarchy signals.
//    Import into:
//      • GTKWave  (free): gtkwave simulation_dump.vcd
//      • Quartus Power Analyzer: File → Import VCD → run power report
//        (run once with clk_en stuck high, once with real power_ctrl,
//         compare dynamic power to show gating benefit).

module my_sys_tb;

    // dut port signals
    reg        fast_clk;
    reg        slow_clk;
    reg        rst_n;
    reg        in_valid;
    reg  [7:0] data_in;
    wire       tx;
    wire       tx_busy;

    // dut instantiation
    my_sys dut (
        .fast_clk (fast_clk),
        .slow_clk (slow_clk),
        .rst_n    (rst_n),
        .in_valid (in_valid),
        .data_in  (data_in),
        .tx       (tx),
        .tx_busy  (tx_busy)
    );

    // clock generation
    // fast_clk starts LOW at t=0.
    initial fast_clk = 1'b0;
    always  #5  fast_clk = ~fast_clk;   // 100 MHz: 5 ns half-period

    // slow_clk starts HIGH at t=0 (deliberate test offset vs fast_clk).
    // why test offset? Exposes metastability windows in the FIFO synchronisers
    // that would be hidden if the clocks were perfectly aligned.
    initial slow_clk = 1'b1;
    always  #50 slow_clk = ~slow_clk;   // 10 MHz: 50 ns half-period

    // vcd dump  — required by the project spec
    // $dumpvars(0, dut) dumps the DUT and everything below it (depth 0 = all
    // levels). TB-only variables (e.g. the activity counters, which change
    // every cycle) are left out: they bloat the file and Quartus power
    // analysis only uses design nets. All DUT ports are still visible.
    // The VCD file is large (~100 MB for a 32 ms simulation), so it is only
    // written when the run is started with the +vcd plusarg
    // (the ModelSim .do scripts pass it; run_tests.sh does not).
    initial begin
        if ($test$plusargs("vcd")) begin
            $dumpfile("simulation_dump.vcd");
            $dumpvars(0, dut);
        end
    end

    // clock-gating switch: +nogating forces the gate permanently open
    // (same effect as the force in sim/run_sim_nogating.do).
    initial begin
        if ($test$plusargs("nogating")) begin
            force dut.clk_en = 1'b1;
            $display(" +nogating: clk_en forced to 1 (clock gating disabled)");
        end
    end

    // switching-activity counters (power proxy, no Quartus needed)
    // Dynamic power ~ toggle rate, and the clock net toggles every cycle,
    // so counting gated_clk rising edges vs raw fast_clk rising edges after
    // reset shows how much clock activity the gating removes.
    integer fast_edges  = 0;
    integer gated_edges = 0;
    always @(posedge fast_clk)      if (rst_n) fast_edges  = fast_edges  + 1;
    always @(posedge dut.gated_clk) if (rst_n) gated_edges = gated_edges + 1;

    task print_activity;
        begin
            $display("ACTIVITY: fast_clk edges = %0d  gated_clk edges = %0d  (%0.4f%% of fast_clk)",
                     fast_edges, gated_edges,
                     (fast_edges > 0) ? (100.0 * gated_edges) / fast_edges : 0.0);
        end
    endtask

    reg [7:0]   his      [3:0];
    reg [15:0]  exp_next;
    reg [15:0]  exp_q    [$];
    integer     passes      = 0;
    integer     fails       = 0;
    always @(posedge fast_clk or negedge rst_n) begin 
        if(!rst_n) begin 
            for (integer i=0;i<4;i++) begin
                his[i] = 8'b0;
            end
        end else if(in_valid) begin 
            for (integer i=3;i>0;i--) begin
                his[i] = his[i-1];
            end
            his[0]  =   data_in;
            exp_next = (1*his[0])+(2*his[1])+(3*his[2])+(4*his[3]);
            exp_q.push_back(exp_next);
            $display("[%t] MODEL expected: %h",$time,exp_next);
        end
    end 

    // tx serial output monitor
    // watches the tx line and prints a message on every edge.
    // this lets you verify 9600-baud framing in the transcript.

    // note: The nominal rate is 9600 baud.
    // The actual time of the slow_clk is 1042 cycles, which is roughly 104,200ns.
    // So edges are spaced by multiples of 104,200 ns. 
    // The baud rate is closer to 9596.9 baud, which is around the 0.03% error.
    initial begin
        $timeformat(-9,0," ns",0);
        $display(" my_sys_tb: simulation start");
        $display(" fast_clk: 100 MHz   slow_clk: 10 MHz   baud: 9600");
        forever begin
            @(tx);   // wait for any change on tx
            $display("[%t]  tx edge → %b", $time, tx);
        end
    end

    // UART receiver model (testbench only)
    localparam integer BIT_NS = 1042 * 100;   // one bit-time in ns
    // end-of-test drain: 16 frames x 18 bits x 104.2 us = 30 ms, plus margin
    localparam integer DRAIN_TIMEOUT_NS = 40_000_000;
    localparam integer POLL_NS          = 10_000;     // check every 10 us
    reg [15:0]  exp_word;
    reg [15:0]  rx_word;
    integer     b;

    initial begin
        forever begin
            // 1. wait for the start of a frame: tx goes from 1 to 0
            //    (hint: the same @(...) style as the tx monitor, but one edge type only)
            @(negedge tx);    
            // 2. wait half a bit, so you sample in the MIDDLE of each bit
            #(BIT_NS/2);
            // 3. check tx is still 0 there; if not, it was a glitch:
            //    print a warning (and 'disable' or just carry on, your call)
            if(tx) begin 
                $display("[%t] Warning: tx is still on low", $time);
            end
            // 4. loop b = 0..15:
            //       wait one full bit
            //       store tx into rx_word[b]        (LSB arrives first)
            for (b = 0; b < 16; b = b + 1) begin
                // wait one full bit   ← same kind of line as your step 5 delay
                #(BIT_NS);
                // rx_word[b] = ...    ← what's on the wire right now?
                rx_word[b] = tx; 
            end
            // 5. wait one more bit and check the stop bit is 1; warn if not
            #(BIT_NS);
            if(tx==0) begin
                $display("[%t] Warning: stop bit is not 1", $time);
            end
            // 6. Prints the recieved data on burst and comapres with expected, verified data will be accounted as PASS
            if(exp_q.size()==0) begin 
                fails = fails+1;
                $display("[%t] FAIL unexpected frame %h (no predictions left)",$time, rx_word);
            end else begin 
                exp_word = exp_q.pop_front();
                if (rx_word === exp_word) begin 
                    passes = passes+1;
                    $display("[%t] PASS got %h",$time, rx_word);
                end else begin 
                    fails = fails+1;
                    $display("[%t] FAIL got %h. Expected %h",$time, rx_word, exp_word);
                end
            end
        end
    end

    // sample data arrays
    // block 1: ascending values 10, 20, ... 80
    // block 2: descending values 245, 235, ... 175  (tests different code paths)
    reg [7:0] block1 [0:7];
    reg [7:0] block2 [0:7];

    integer i;

    initial begin
        block1[0]=8'd10; block1[1]=8'd20; block1[2]=8'd30; block1[3]=8'd40;
        block1[4]=8'd50; block1[5]=8'd60; block1[6]=8'd70; block1[7]=8'd80;

        block2[0]=8'd245; block2[1]=8'd235; block2[2]=8'd225; block2[3]=8'd215;
        block2[4]=8'd205; block2[5]=8'd195; block2[6]=8'd185; block2[7]=8'd175;
    end

    // main stimulus
    initial begin

        // test 1 — reset
        // drive all inputs to safe defaults first.
        rst_n    = 1'b0;
        in_valid = 1'b0;
        data_in  = 8'd0;

        // hold reset for 6 fast_clk cycles so all flip-flops see reset.
        // why also wait for a slow_clk edge?  The FIFO has separate reset
        // domains.  We must ensure at least one slow_clk posedge sees
        // rst_n=0 so the read-domain pointers reset correctly.
        repeat (6)  @(posedge fast_clk);
        @(posedge slow_clk);
        #2;   // small skew so stimulus change is not coincident with a clock edge

        rst_n = 1'b1;
        $display("[%t] ── test 1 done: reset released ──", $time);

        // test 2 — FIRST DATA BURST  (8 samples)
        // NOTE: in_valid=1 for exactly one fast_clk cycle per sample.
        // The FIR shift register updates on each such cycle.
        // FIR output appears 2 cycles later (pipeline) and winc=fir_valid
        // pushes each result into the FIFO.
        // UART starts draining the FIFO as soon as the first word is there.
        $display("[%t] ── test 2 start: streaming block 1 ──", $time);

        for (i = 0; i < 8; i = i + 1) begin
            @(posedge fast_clk); #2;
            in_valid = 1'b1;
            data_in  = block1[i];
        end
        // De-assert after the 8th sample
        @(posedge fast_clk); #2;
        in_valid = 1'b0;
        data_in  = 8'd0;

        $display("[%t] ── test 2 done: 8 samples sent ──", $time);

        // test 3 — IDLE  (trigger clock gating)
        // Keep in_valid=0 for 15 fast_clk cycles.
        // power_ctrl should assert clk_en=0 after exactly 10 idle cycles.
        //
        // note: The FIR pipeline still has 2 valid outputs in-flight from
        // the last two input samples.  Those will be written to the FIFO
        // on the next 2 gated_clk edges BEFORE the gate takes effect
        // (clk_en=0 is produced by power_ctrl on its 10th idle posedge,
        // which is after the FIFO writes complete since the FIFO runs on
        // gated_clk which is still running during those 10 cycles).

        repeat (15) @(posedge fast_clk);

        $display("[%t] ── test 3: after 15 idle cycles, clk_en = %b (expect 0) ──",
                 $time, dut.clk_en);

        // check: gating must have triggered (skipped under +nogating, where
        // clk_en is forced high on purpose)
        if (!$test$plusargs("nogating")) begin
            if (dut.clk_en === 1'b0) begin
                passes = passes + 1;
                $display("[%t] PASS clk_en low after idle", $time);
            end else begin
                fails = fails + 1;
                $display("[%t] FAIL clk_en expected 0 after idle, got %b", $time, dut.clk_en);
            end
        end

        // test 4 — wakeup  (second data burst)
        // The first in_valid=1 should immediately re-enable clk_en.
        $display("[%t] ── test 4 start: streaming block 2 (wakeup test) ──", $time);

        for (i = 0; i < 8; i = i + 1) begin
            @(posedge fast_clk); #2;
            in_valid = 1'b1;
            data_in  = block2[i];
        end
        @(posedge fast_clk); #2;
        in_valid = 1'b0;

        $display("[%t] ── test 4 done: clk_en = %b (expect 1) ──",
                 $time, dut.clk_en);

        // check: the clock must be running again after wake-up
        if (dut.clk_en === 1'b1) begin
            passes = passes + 1;
            $display("[%t] PASS clk_en high after wake-up", $time);
        end else begin
            fails = fails + 1;
            $display("[%t] FAIL clk_en expected 1 after wake-up, got %b", $time, dut.clk_en);
        end

        // test 5 — DRAIN
        // Wait until the UART has delivered everything: no predictions left,
        // nothing left in the FIFO, and the UART idle. If frames were lost,
        // predictions never run out, so a timeout ends the wait instead.
        // (tx_busy drops for one slow_clk cycle between back-to-back frames;
        //  the fifo_empty term keeps that gap from ending the wait early.)
        $display("[%t] ── test 5: draining UART (timeout %0d ms) ──",
                 $time, DRAIN_TIMEOUT_NS / 1_000_000);
        begin : drain
            integer waited;
            waited = 0;
            while ((exp_q.size() != 0 || !dut.fifo_empty || tx_busy)
                   && waited < DRAIN_TIMEOUT_NS) begin
                #(POLL_NS);
                waited = waited + POLL_NS;
            end
            if (waited >= DRAIN_TIMEOUT_NS)
                $display("[%t] drain timeout: %0d prediction(s) never arrived",
                         $time, exp_q.size());
        end

        // test 6 — END-OF-TEST CHECKS AND VERDICT
        // Every prediction still queued is a frame the DUT never sent.
        while (exp_q.size() > 0) begin
            fails = fails + 1;
            $display("[%t] FAIL missing frame: expected %h never received",
                     $time, exp_q.pop_front());
        end

        $display("[%t] ── Simulation complete ──", $time);
        print_activity;
        $display("CHECKS: %0d   PASS: %0d   FAIL: %0d", passes + fails, passes, fails);
        // "0 fails out of 0 checks" must not count as a pass
        if (fails == 0 && passes > 0) $display("TEST PASSED");
        else                          $display("TEST FAILED");
        $finish;
    end

    // Overflow watchdog
    // Alert if the FIFO fills up — this would mean the FIR is producing data
    // faster than the UART can drain it during continuous streaming.
    // At these test rates it should never trigger.
    initial begin
        forever begin
            @(posedge fast_clk);
            if (dut.fifo_wfull)
                $display("[%t]  WARNING: FIFO FULL — data may be lost!", $time);
        end
    end

endmodule
