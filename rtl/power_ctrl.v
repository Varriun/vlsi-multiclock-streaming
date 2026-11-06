
// WHY ALTCLKCTRL (not a plain AND gate)?
//
//   If you write:  assign gated_clk = fast_clk & clk_en;
//
//   The clk_en signal can change at any time, not necessarily synchronized
//   to a clock edge.  If clk_en falls while fast_clk is HIGH:
//       fast_clk:  ___/‾‾‾‾‾\_____
//       clk_en:    ‾‾‾‾‾\_________   ← changes mid-HIGH
//       gated_clk: ___/‾\___        ← GLITCH: spurious falling edge!

// TIMING TRACE (idle_cnt counts how many consecutive idle cycles seen):
//
//   fast_clk:  _/‾\_/‾\_/‾\_/‾\_/‾\_/‾\_/‾\_/‾\_/‾\_/‾\_/‾\_ ...
//   in_valid:  _________________________________/ ‾‾‾‾‾‾‾‾‾‾‾‾ ...
//              ← 10 cycles of in_valid=0 ─────→ wakeup
//   idle_cnt:  0→1→2→3→4→5→6→7→8→9 (held at 9 after threshold)
//   clk_en:    ‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾\___________/‾‾‾‾‾‾‾‾‾‾‾‾‾
//                                    ↑gate off   ↑immediate wake

module power_ctrl (
    input  wire clk,       // raw fast_clk — ALWAYS ON (never gated!)
    //   By running on raw fast_clk (always-on), power_ctrl stays alive even when the FIR is gated.  
    //	 It acts like a doorbell: always listening,waking the FIR when needed.
    input  wire rst_n,     // active-low async reset
    input  wire in_valid,  // activity signal (same signal fed to FIR data_in)
    output reg  clk_en     // to ALTCLKCTRL ena pin: 1=running, 0=gated off
);

    // 4 bits needed to count 0..10 (2^4 = 16 > 10)
    localparam [3:0] IDLE_CYCLES = 4'd10;

    reg [3:0] idle_cnt;   // counts consecutive cycles where in_valid=0

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            idle_cnt <= 4'd0;
            clk_en   <= 1'b1;   // clock starts enabled (FIR can run immediately)
        end else begin

            if (in_valid) begin
                // ACTIVE: data is arriving
                idle_cnt <= 4'd0;
                clk_en   <= 1'b1;

            end else if (idle_cnt < IDLE_CYCLES - 1) begin
                // IDLE, below threshold
                idle_cnt <= idle_cnt + 4'd1;
                // clk_en unchanged (stays 1)

            end else begin
                // IDLE, threshold reached (idle_cnt == 9)
                // can NOT let it roll over to 0,
                // which would re-enable the clock
                // idle_cnt stays at IDLE_CYCLES-1 (=9) until in_valid arrives.
                clk_en <= 1'b0;
            end

        end
    end

endmodule
