//
// TARGET DEVICE: Altera Cyclone IV E, EP4CE115F29C7
// TOOL:          Quartus Prime Lite (synthesis + STA; no board required)
//
// =============================================================================
// SYSTEM DATAFLOW:
//
//   External             Fast domain (gated_clk)         Slow domain (slow_clk)
//   ─────────────────────────────────────────────────────────────────────────
//   data_in[7:0] ──► FIR ──► FIFO (write port)    FIFO (read port) ──► UART ──► tx
//   in_valid     ──► FIR     (winc = fir_valid)   (rinc = uart_rinc)
//                ──► power_ctrl
//
//   raw fast_clk ──► power_ctrl (clk_en) ──► ALTCLKCTRL ──► gated_clk ──► FIR, FIFO.wclk
//                                                                            │
//                                              ↑ Quartus clock network       │
//                                                glitch-free gating          │
//   slow_clk ─────────────────────────────────────────────────────────────► FIFO.rclk, UART
//
module my_sys (
    input  wire        fast_clk,   // 100 MHz, raw, always-on
    input  wire        slow_clk,   //  10 MHz
    input  wire        rst_n,      // active-low async reset (both domains)
    input  wire        in_valid,   // new input sample present
    input  wire [7:0]  data_in,    // unsigned 8-bit sample
    output wire        tx,         // UART TX serial output
    output wire        tx_busy     // UART status: 1 = transmitting, 0 = idle
);


    // Internal wires
    wire        gated_clk;     // fast_clk after ALTCLKCTRL gating
    wire        clk_en;        // gating control from power_ctrl (1=on, 0=off)
    // FIR → FIFO
    wire [15:0] fir_data;      // 16-bit FIR output
    wire        fir_valid;     // FIR output valid (2 cycles after in_valid)
    // FIFO → UART
    wire [15:0] fifo_rdata;    // current FIFO head word (combinational)
    wire        fifo_empty;    // FIFO empty flag (slow domain)
    wire        fifo_rinc;     // FIFO read-advance from UART
    wire        fifo_wfull;    // FIFO full flag (fast domain, unused back-pressure)
`ifdef SIMULATION
    //ALTCLKCTRL  vs  simulation stub
    // Behavioural AND-gate stub for simulation.
    // clk_en is driven synchronously by power_ctrl (posedge fast_clk),
    // so glitches on gated_clk occur only near a rising fast_clk edge.
    assign gated_clk = fast_clk & clk_en;

`else
    // Quartus-generated wrapper for the ALTCLKCTRL megafunction.
    // This places a glitch-free gate inside the Cyclone IV GCLK network.
    altclkctrl altclkctrl_inst (
        .inclk  (fast_clk),
        .ena    (clk_en),
        .outclk (gated_clk)
    );
`endif
    // NOTE: DELIBERATELY connected to raw fast_clk, NOT gated_clk.
    power_ctrl u_pwr (
        .clk      (fast_clk),   // raw clock — always on
        .rst_n    (rst_n),
        .in_valid (in_valid),
        .clk_en   (clk_en)
    );
    // FIR  —  4-tap filter  (gated_clk domain)
    fir u_fir (
        .clk      (gated_clk),
        .rst_n    (rst_n),
        .in_valid (in_valid),
        .data_in  (data_in),
        .data_out (fir_data),
        .out_valid(fir_valid)
    );
    
    // AFIFO  —  async FIFO, CDC crossing
    afifo #(
        .DATA_W (16),
        .ADDR_W (3)     // 8 entries; absorbs a full 8-sample burst from FIR
    ) u_fifo (
    //   Write port: gated_clk domain (FIR output)
        .wclk   (gated_clk),
        .wrst_n (rst_n),
        .winc   (fir_valid),     // push when FIR produces a valid result
        .wdata  (fir_data),
        .wfull  (fifo_wfull),    // monitored in testbench; not fed back here
    //   Read  port: slow_clk  domain (UART input)
        .rclk   (slow_clk),
        .rrst_n (rst_n),
        .rinc   (fifo_rinc),
        .rdata  (fifo_rdata),
        .rempty (fifo_empty)
    );

    // UART  —  TX only, 9600 baud  (slow_clk domain)
    uart u_uart (
        .clk        (slow_clk),
        .rst_n      (rst_n),
        .fifo_rdata (fifo_rdata),
        .fifo_empty (fifo_empty),
        .fifo_rinc  (fifo_rinc),
        .tx         (tx),
        .tx_busy    (tx_busy)
    );
endmodule
