
// this module is responsible of transferring the data from the fast_clk (100MHz) to the slow_clk (10MHz) domain
// we use gray code (000 -> 001 -> 011 -> 010 ....) in order to avoid metastability on multiple bits
// we use a synchronous 2 back to back FF in order to avoid metastability on that single bit change
// we use 1 extra lap bit for the pointer (4 bits instead of 3) - to check if the write pointer has lapped over the read pointer
// POINTER AIRLOCK (write pointer crossing wclk -> rclk domain):
//
//   wclk domain (100MHz)     |  rclk domain (10MHz)
//                            |
//   wptr_bin ──► Gray encode |
//                   │        |
//                   ▼        |
//              wptr_gray ────┼──► sync1 ──► sync2 ──► compared
//              (1 bit        |   (maybe    (stable)   vs rptr_gray
//               changes      |  metastable)           -> rempty
//               at a time)   |
//                            |
//   mem[wptr] data word  -- NEVER crosses, only the pointer does --
//
//   FF1 (sync1) may catch a mid-transition value = metastable.
//   FF2 (sync2) has a full clk period to let it settle = safe.
//   Gray code guarantees only 1 bit flips per increment, so even
//   a "wrong" snapshot is off by at most one count, never garbage.
//
module afifo #(
    parameter DATA_W = 16,   // data width: must match FIR data_out width
    parameter ADDR_W = 3     // address bits: depth = 2^ADDR_W = 8 entries
) (
    // write port (controller by the fast / gated clock domain)
    input  wire              wclk,    // gated_clk from ALTCLKCTRL
    input  wire              wrst_n,  // active-low async reset (write domain)
    input  wire              winc,    // write-enable (driven by fir.out_valid)
    input  wire [DATA_W-1:0] wdata,   // data from FIR
    output wire              wfull,   // FIFO is full — back-pressure to FIR

    // read port (controlled by the slow clock domain)
    input  wire              rclk,    // slow_clk (10 MHz)
    input  wire              rrst_n,  // active-low async reset (read domain)
    input  wire              rinc,    // read-enable (driven by UART FSM)
    output wire [DATA_W-1:0] rdata,   // data to UART (combinational / async)
    output wire              rempty   // FIFO is empty — stalls UART
);

    localparam DEPTH = 1 << ADDR_W;   // 8 entries
    localparam PTR_W = ADDR_W + 1;    // 4-bit pointers (3 addr + 1 lap bit)

    reg [DATA_W-1:0] mem [0:DEPTH-1];
    reg [PTR_W-1:0] wptr_bin;   // write pointer, wclk domain
    reg [PTR_W-1:0] rptr_bin;   // read  pointer, rclk domain
    reg [PTR_W-1:0] wptr_gray;   // wclk domain  →  sent TO rclk domain
    reg [PTR_W-1:0] rptr_gray;   // rclk domain  →  sent TO wclk domain


    // 2-FF SYNCHRONISERS
    // Each set of FFs belongs to the DESTINATION clock domain.
    // FF1 (_sync1) may be metastable; FF2 (_sync2) is considered stable.
    reg [PTR_W-1:0] wptr_sync1_r, wptr_sync2_r;
    reg [PTR_W-1:0] rptr_sync1_w, rptr_sync2_w;



    // WRITE DOMAIN
    always @(posedge wclk or negedge wrst_n) begin
        if (!wrst_n) begin
            wptr_bin  <= {PTR_W{1'b0}};
            wptr_gray <= {PTR_W{1'b0}};
        end else if (winc && !wfull) begin
            mem[wptr_bin[ADDR_W-1:0]] <= wdata;
            wptr_bin <= wptr_bin + 1'b1;
            // NOTE: We compute the Gray code of (wptr_bin+1), not of
            // the registered wptr_bin, because the non-blocking assignment
            // for wptr_bin won't settle until end of the time step.
            // Formula: Gray = Binary XOR (Binary >> 1)
            wptr_gray <= (wptr_bin + 1'b1) ^ ((wptr_bin + 1'b1) >> 1);
        end
    end

    // 2-FF synchroniser: rptr_gray → wclk domain
    // NOTE: Place DONT_TOUCH / ASYNC_REG constraints on these FFs in SDC
    // to prevent the synthesiser from optimising them away or merging them.
    always @(posedge wclk or negedge wrst_n) begin
        if (!wrst_n) begin
            rptr_sync1_w <= {PTR_W{1'b0}};
            rptr_sync2_w <= {PTR_W{1'b0}};
        end else begin
            rptr_sync1_w <= rptr_gray;      // potentially metastable FF
            rptr_sync2_w <= rptr_sync1_w;   // resolved, stable output
        end
    end
    assign wfull = ({~wptr_gray[PTR_W-1],
                     wptr_gray[PTR_W-2],
                     wptr_gray[PTR_W-3:0]}   // lower (PTR_W-2) bits unchanged
                     == rptr_sync2_w);
    
    // READ DOMAIN 
    always @(posedge rclk or negedge rrst_n) begin
        if (!rrst_n) begin
            rptr_bin  <= {PTR_W{1'b0}};
            rptr_gray <= {PTR_W{1'b0}};
        end else if (rinc && !rempty) begin
            rptr_bin  <= rptr_bin + 1'b1;
            rptr_gray <= (rptr_bin + 1'b1) ^ ((rptr_bin + 1'b1) >> 1);
        end
    end

    // 2-FF synchroniser: wptr_gray → rclk domain
    always @(posedge rclk or negedge rrst_n) begin
        if (!rrst_n) begin
            wptr_sync1_r <= {PTR_W{1'b0}};
            wptr_sync2_r <= {PTR_W{1'b0}};
        end else begin
            wptr_sync1_r <= wptr_gray;      // potentially metastable FF
            wptr_sync2_r <= wptr_sync1_r;   // resolved, stable output
        end
    end
    // ASYNC read: rdata is combinationally available from current rptr_bin.
    assign rdata  = mem[rptr_bin[ADDR_W-1:0]];
    // EMPTY flag — evaluated in rclk domain using wptr_sync2_r
    assign rempty = (rptr_gray == wptr_sync2_r);

endmodule
