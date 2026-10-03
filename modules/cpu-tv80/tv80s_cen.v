//------------------------------------------------------------------------------
// tv80s with a clock enable.
//
// Identical to modules/cpu-tv80/tv80s.v except that `cen` is a port instead of
// a constant 1, and the bus-strobe register is gated by it. Written for the
// Time Pilot core, where the Z80s run at 3.072 and 1.789772 MHz off a
// 49.152 MHz clock; here the Gaiapolis sound Z80 steps at 8 MHz off 96 MHz.
// Either way it is stepped rather than free-running.
//
// The vendored core is left untouched so it stays diffable against upstream.
//------------------------------------------------------------------------------
`define TV80DELAY

module tv80s_cen (
    input  wire        reset_n,
    input  wire        clk,
    input  wire        cen,
    input  wire        wait_n,
    input  wire        int_n,
    input  wire        nmi_n,
    input  wire        busrq_n,
    output wire        m1_n,
    output reg         mreq_n,
    output reg         iorq_n,
    output reg         rd_n,
    output reg         wr_n,
    output wire        rfsh_n,
    output wire        halt_n,
    output wire        busak_n,
    output wire [15:0] A,
    input  wire  [7:0] di,
    output wire  [7:0] dout
);
    parameter Mode    = 0;   // 0 => Z80
    parameter T2Write = 1;   // wr_n active in T2
    parameter IOWait  = 1;   // standard I/O cycle

    wire       intcycle_n;
    wire       no_read;
    wire       write;
    wire       iorq;
    reg  [7:0] di_reg;
    wire [6:0] mcycle;
    wire [6:0] tstate;

    tv80_core #(Mode, IOWait) i_tv80_core (
        .cen        (cen),
        .m1_n       (m1_n),
        .iorq       (iorq),
        .no_read    (no_read),
        .write      (write),
        .rfsh_n     (rfsh_n),
        .halt_n     (halt_n),
        .wait_n     (wait_n),
        .int_n      (int_n),
        .nmi_n      (nmi_n),
        .reset_n    (reset_n),
        .busrq_n    (busrq_n),
        .busak_n    (busak_n),
        .clk        (clk),
        .IntE       (),
        .stop       (),
        .A          (A),
        .dinst      (di),
        .di         (di_reg),
        .dout       (dout),
        .mc         (mcycle),
        .ts         (tstate),
        .intcycle_n (intcycle_n)
    );

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            rd_n   <= `TV80DELAY 1'b1;
            wr_n   <= `TV80DELAY 1'b1;
            iorq_n <= `TV80DELAY 1'b1;
            mreq_n <= `TV80DELAY 1'b1;
            di_reg <= `TV80DELAY 8'h00;
        end else if (cen) begin
            rd_n   <= `TV80DELAY 1'b1;
            wr_n   <= `TV80DELAY 1'b1;
            iorq_n <= `TV80DELAY 1'b1;
            mreq_n <= `TV80DELAY 1'b1;
            if (mcycle[0]) begin
                if (tstate[1] || (tstate[2] && wait_n == 1'b0)) begin
                    rd_n   <= `TV80DELAY ~intcycle_n;
                    mreq_n <= `TV80DELAY ~intcycle_n;
                    iorq_n <= `TV80DELAY  intcycle_n;
                end
            end else begin
                if ((tstate[1] || (tstate[2] && wait_n == 1'b0)) && !no_read && !write) begin
                    rd_n   <= `TV80DELAY 1'b0;
                    iorq_n <= `TV80DELAY ~iorq;
                    mreq_n <= `TV80DELAY  iorq;
                end
                if (T2Write == 0) begin
                    if (tstate[2] && write) begin
                        wr_n   <= `TV80DELAY 1'b0;
                        iorq_n <= `TV80DELAY ~iorq;
                        mreq_n <= `TV80DELAY  iorq;
                    end
                end else begin
                    if ((tstate[1] || (tstate[2] && wait_n == 1'b0)) && write) begin
                        wr_n   <= `TV80DELAY 1'b0;
                        iorq_n <= `TV80DELAY ~iorq;
                        mreq_n <= `TV80DELAY  iorq;
                    end
                end
            end
            if (tstate[2] && wait_n && !write && !no_read)
                di_reg <= `TV80DELAY di;
        end
    end
endmodule
