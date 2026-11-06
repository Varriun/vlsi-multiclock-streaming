
// this module implements discrete convolution using the formula:
// y[n] = x[n]*1 + x[n-1]*2 + x[n-2]*3 + x[n-3]*4

// the coefficients used: h = [1, 2, 3, 4]

module fir (
    input  wire        clk,       // gated fast_clk from ALTCLKCTRL
    input  wire        rst_n,     // active-low asynchronous reset
    input  wire        in_valid,  // '1' means data_in holds a new sample
    input  wire [7:0]  data_in,   // unsigned 8-bit input sample

    output reg  [15:0] data_out,  // 16-bit FIR output (valid when out_valid=1)
    output reg         out_valid  // pulses high exactly 2 cycles after in_valid
);

    // STAGE 1 — 4-tap shift register
    // x0 = newest sample (from this cycle's data_in after capture)... x3 = oldest sample (3 cycles ago).
    reg [7:0]   x0, x1, x2, x3;
    reg         vld_s1;   // Stage-1 valid: in_valid delayed 1 cycle

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x0     <= 8'd0;
            x1     <= 8'd0;
            x2     <= 8'd0;
            x3     <= 8'd0;
            vld_s1 <= 1'b0;
        end else begin
            vld_s1 <= in_valid;   // always propagate valid, regardless of value
            if (in_valid) begin
                // Push new sample in at the head; 
                x0 <= data_in;
                x1 <= x0;
                x2 <= x1;
                x3 <= x2;
                //oldest falls off the tail.
            end
            // When in_valid=0: hold x0..x3 unchanged.
            // vld_s1 will be 0 next cycle, so Stage 2 won't register garbage.
        end
    end
    
    // STAGE 2 — Multiply-accumulate (registered output)
    // At the start of this stage, x0..x3 hold the values committed by S1 in the PREVIOUS cycle
    // So x0 = most recent data_in that was valid.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            data_out  <= 16'd0;
            out_valid <= 1'b0;
        end else begin
            out_valid <= vld_s1;   // Stage-2 valid = Stage-1 valid delayed 1 more cycle

            if (vld_s1) begin
                data_out <=   {8'd0, x0}                              // coeff 1: x*1
                            + ({8'd0, x1} << 1)                       // coeff 2: x*2
                            + ({8'd0, x2} + ({8'd0, x2} << 1))        // coeff 3: x*3
                            + ({8'd0, x3} << 2);                      // coeff 4: x*4
            end
            // When vld_s1=0: data_out holds its last value.
            // That is harmless because out_valid=0 tells the FIFO not to write.
        end
    end

endmodule
