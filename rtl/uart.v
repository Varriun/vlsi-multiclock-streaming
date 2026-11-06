
// FRAME FORMAT  (non-standard 16-bit extension of standard UART):
//   ┌───────┬───────────────────────────┬──────────┐
//   │ START │  16 data bits (LSB first) │  STOP    │
//   │   0   │  D0 D1 D2 ... D14 D15     │    1     │
//   └───────┴───────────────────────────┴──────────┘
//   Total: 18 bit-times per word.
//   We opted using a non standard 16 bit UART instead of breaking it down to 2-8 bit UART frames
//   in order to keep the hardware simple
//
// FSM STATE DIAGRAM:
//
//     fifo not empty             baud_ctr == BIT_TIME-1
//   ┌───────────────────┐        ┌─────────────────────┐
//   │                   ▼        │                     ▼
//  IDLE ──────────────► START ──────────────────────► DATA
//                                 (start bit = '0')    │  16 bit-times, LSB first
//                                                      │
//                       IDLE ◄── STOP ◄───────────────┘
//                    (tx='1')  (stop bit='1')   bit_cnt == 15
// calculate the baud rate:
//   slow_clk frequency = 10 MHz = 10,000,000 Hz
//   target baud rate = 9600 baud
//   bit period = 1 / 9600 ≈ 104.167 µs
//   clock cycles/bit = 10,000,000 / 9600 = 1041.67  →  round to 1042
//   actual baud rate = 10,000,000 / 1042 = 9596.9 baud
//   error = (9600 - 9596.9) / 9600 × 100% ≈ 0.032%
//   spec limit = ±2%  →  well within tolerance.
//
module uart (
    input  wire        clk,          // slow_clk (10 MHz)
    input  wire        rst_n,        // active-low async reset

    // FIFO read interface (this module is the FIFO's read-port master)
    input  wire [15:0] fifo_rdata,   // current FIFO head word (combinational)
    input  wire        fifo_empty,   // '1' = nothing to transmit
    output reg         fifo_rinc,    // pulse '1' for one cycle to consume a word

    // UART serial output.
    output reg         tx,           // TX line: idle=1, start=0, data=bit, stop=1
    output reg         tx_busy       // Status flag 1 = mid-transmission (not idle), 0 = idle
);

    // Baud rate timing. 11 bits: 1041 (2^10 = 1024 < 1042 ≤ 2^11 = 2048)
    // The params for the 16 bit frame
    localparam [10:0] CLKS_PER_BIT = 11'd1042;
    localparam [4:0]  DATA_BITS    = 5'd16;

    // FSM state encoding
    // NOTE: Using 2-bit one-hot-ish encoding. typically it's 1 bit.
    // All outputs are registered so the encoding choice doesn't affect glitch risk on tx.
    localparam [1:0]
        ST_IDLE  = 2'd0,
        ST_START = 2'd1,
        ST_DATA  = 2'd2,
        ST_STOP  = 2'd3;

    // Internal registers
    reg [1:0]  state;
    reg [10:0] baud_ctr;    // counts slow_clk ticks within one bit-time (0..1041)
    reg [4:0]  bit_cnt;     // tracks how many data bits have been sent (0..15)
    reg [15:0] shift_reg;   // holds the word being serialised; MSB is discarded
                            //   after each shift; tx <= shift_reg[0]


    // FSM + datapath  (single always block: fully synchronous outputs)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= ST_IDLE;
            tx        <= 1'b1;       // UART idle line is logic HIGH ("mark")
            baud_ctr  <= 11'd0;
            bit_cnt   <= 5'd0;
            shift_reg <= 16'd0;
            fifo_rinc <= 1'b0;
            tx_busy   <= 1'b0;       // not transmitting after reset
        end else begin

            // Default: no FIFO read pulse this cycle.
            // Individual state handlers override this when needed.
            fifo_rinc <= 1'b0;

            case (state)
				// ST_IDLE - if the FIFO's EMPTY flag stops (meaning the data is ready for the SLOW_CLK to be read and pulled), it does 3 things simoltaniously:
				// 1. grabs the 16 bits into a shift register
				// 2. send a command telling the FIFO to increment its read pointer 
				// 3. changes it's state to ST_START

				// If it captures the data and sends the increment command in the exact same moment, the pointer wont advance, only on the next clock cycle. The shift register securely holds the data from the non-incremented pointer before the next clock edge, where the pointer updated and points to the next data.
                ST_IDLE: begin
                    tx      <= 1'b1;   // hold line idle
                    tx_busy <= 1'b0;   // idle = not transmitting

                    if (!fifo_empty) begin
                        // A word is waiting.  Latch it and advance FIFO pointer.
                        //
                        // IMPORTANT: fifo_rdata is combinational (async read).
                        // shift_reg captures it here via non-blocking assignment.
                        // fifo_rinc is also set via non-blocking assignment.
                        // On the NEXT posedge, the FIFO sees rinc=1 and advances
                        // rptr — but shift_reg already has the current data.
                        shift_reg <= fifo_rdata;
                        fifo_rinc <= 1'b1;     // one-cycle pulse
                        baud_ctr  <= 11'd0;
                        state     <= ST_START;
                        tx_busy   <= 1'b1;     // transmission begins
                    end
                end

				// ST_START - hold the line LOW for 10042 cycles
                ST_START: begin
                    tx      <= 1'b0;   // drive the start bit (space = logic 0)
                    tx_busy <= 1'b1;

                    if (baud_ctr == CLKS_PER_BIT - 1) begin
                        baud_ctr <= 11'd0;
                        bit_cnt  <= 5'd0;     // reset data bit counter
                        state    <= ST_DATA;
                    end else begin
                        baud_ctr <= baud_ctr + 1'b1;
                    end
                end

				// ST_DATA - ships out 1 bit every 10042 cycles until all 16 are gone
                ST_DATA: begin
                    tx      <= shift_reg[0];   // LSB first (standard UART bit order)
                    tx_busy <= 1'b1;

                    if (baud_ctr == CLKS_PER_BIT - 1) begin
                        baud_ctr  <= 11'd0;

                        // Logical right-shift: next bit to send moves to [0]
                        //building the 16bit frame in one send
                        shift_reg <= {1'b0, shift_reg[15:1]};

                        if (bit_cnt == DATA_BITS - 1) begin
                            // All 16 data bits sent — go to stop bit
                            state <= ST_STOP;
                        end else begin
                            bit_cnt <= bit_cnt + 1'b1;
                        end
                    end else begin
                        baud_ctr <= baud_ctr + 1'b1;
                    end
                end

				// ST_STOP - hold the line HIGH, to finish the frame
                ST_STOP: begin
                    tx      <= 1'b1;   // stop bit = mark (logic 1)
                    tx_busy <= 1'b1;   // still busy until the stop bit completes

                    if (baud_ctr == CLKS_PER_BIT - 1) begin
                        baud_ctr <= 11'd0;
                        state    <= ST_IDLE;
                        tx_busy  <= 1'b0;   // frame finished -> back to idle
                        // NOTE: returning to IDLE for at least 1 slow_clk cycle
                        // before checking fifo_empty again adds ~100 ns inter-
                        // frame gap.  At 9600 baud that is negligible (< 0.1%
                        // of a bit time) and ensures the stop bit is held for
                        // a full bit-time before transitioning.
                    end else begin
                        baud_ctr <= baud_ctr + 1'b1;
                    end
                end

            endcase
        end
    end

endmodule
