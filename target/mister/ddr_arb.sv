//------------------------------------------------------------------------------
// DDR3 arbiter: one Avalon-MM master port (the MiSTer framework's DDRAM_*) shared
// by the core's memory client (ROZ map and characters, the loader's writes), the
// framework's screen_rotate, which writes the rotated frame buffer, and the Flip
// Screen buffer's line reads (flip_buf.sv; its writes go through the same FIFO as
// screen_rotate's).
//
// screen_rotate raises DDRAM_WE for one clock per pixel and never looks at
// DDRAM_BUSY, so its writes cannot be refused: they go into a FIFO and are
// written out whenever the bus is free. The client speaks plain Avalon-MM
// master protocol -- it holds rd/we and the fields until a clock where
// `c_busy` is low -- and receives every read beat on c_dready/c_dout.
//
// Policy: a queued rotate write goes first (they are one per 12 clocks at most
// and take a clock or two each); the client's commands wait while one is
// presented, and the FIFO's writes wait for outstanding read data. A flip read
// goes last: only when nothing else is presented, the FIFO is empty and no read data is owed, and
// while its burst is coming back the client waits (the beats are the flip
// reader's). The selection never changes while a command is presented and
// stalled by DDRAM_BUSY.
//------------------------------------------------------------------------------
`default_nettype none

module ddr_arb #(
    parameter int FIFO_AW = 6,                  // 64 queued rotate / flip writes
    parameter [3:0] CLIENT_BASE = 4'd3          // the client's 256 MB window: byte 0x30000000
) (
    input  logic        clk,
    input  logic        reset,

    // the core's client
    input  logic        c_rd,
    input  logic        c_we,
    input  logic [24:0] c_addr,                 // 64-bit word address within the window
    input  logic  [7:0] c_burst,
    input  logic [63:0] c_din,
    input  logic  [7:0] c_be,
    output logic        c_busy,
    output logic [63:0] c_dout,
    output logic        c_dready,

    // screen_rotate's write channel
    input  logic        r_we,
    input  logic [28:0] r_addr,
    input  logic [63:0] r_din,
    input  logic  [7:0] r_be,

    // the flip buffer's line reads (a burst per request; its beats come back on f_dready, data on c_dout)
    input  logic        f_rd,
    input  logic [24:0] f_addr,                 // 64-bit word address within the client's window
    input  logic  [7:0] f_burst,
    output logic        f_busy,
    output logic        f_dready,

    // the framework
    input  logic        DDRAM_BUSY,
    output logic  [7:0] DDRAM_BURSTCNT,
    output logic [28:0] DDRAM_ADDR,
    input  logic [63:0] DDRAM_DOUT,
    input  logic        DDRAM_DOUT_READY,
    output logic        DDRAM_RD,
    output logic [63:0] DDRAM_DIN,
    output logic  [7:0] DDRAM_BE,
    output logic        DDRAM_WE,

    output logic        overflow                // sticky: a rotate write was dropped
);
    // ---------------------------------------------------------------- FIFO
    // a RAM with a registered head: `hv` says `head` holds the oldest write
    localparam int FW = 29 + 64 + 8;
    (* ramstyle = "no_rw_check" *) logic [FW-1:0] fifo [1 << FIFO_AW];
    logic [FIFO_AW:0] wp, rp;
    logic [FW-1:0]    rq, head;
    logic             hv, rd_pend;
    wire              f_full  = (wp[FIFO_AW-1:0] == rp[FIFO_AW-1:0]) && (wp[FIFO_AW] != rp[FIFO_AW]);
    wire              f_empty = (wp == rp);
    wire              head_done;                // the head's write was accepted

    always_ff @(posedge clk) begin
        rq <= fifo[rp[FIFO_AW-1:0]];
        if (r_we && !f_full) fifo[wp[FIFO_AW-1:0]] <= {r_addr, r_din, r_be};
    end
    always_ff @(posedge clk) begin
        if (reset) begin wp <= '0; rp <= '0; hv <= 1'b0; rd_pend <= 1'b0; overflow <= 1'b0; end
        else begin
            if (r_we) begin
                if (f_full) overflow <= 1'b1; else wp <= wp + 1'b1;
            end
            if (head_done) hv <= 1'b0;
            // load the head: the RAM is read at rp one clock, captured the next
            if (!hv && !rd_pend && !f_empty) rd_pend <= 1'b1;
            else if (rd_pend) begin head <= rq; hv <= 1'b1; rp <= rp + 1'b1; rd_pend <= 1'b0; end
        end
    end

    // ------------------------------------------------------- read tracking
    // beats still owed to the client; no rotate write is presented until the
    // last one is back
    logic [8:0] owed;
    wire        rd_acc = DDRAM_RD && !DDRAM_BUSY;
    always_ff @(posedge clk) begin
        if (reset) owed <= '0;
        else owed <= owed + (rd_acc ? 9'(DDRAM_BURSTCNT) : 9'd0) - (DDRAM_DOUT_READY ? 9'd1 : 9'd0);
    end
    wire reads_out = (owed != 9'd0);

    // ------------------------------------------------------ the selection
    // `held`: a command was presented last clock and DDRAM_BUSY refused it, so
    // the same source must present it again
    logic held, held_rot, held_flip;
    wire  want_rot  = hv && !reads_out;
    // only with the write FIFO completely drained (head reload included): the two clocks
    // between one write and the next must not let a burst in, or the FIFO fills
    wire  fifo_idle = f_empty && !hv && !rd_pend;
    wire  want_flip = f_rd && fifo_idle && !reads_out && !c_rd && !c_we;
    wire  use_rot   = held ? held_rot : want_rot;
    wire  use_flip  = held ? held_flip : want_flip;
    always_ff @(posedge clk) begin
        if (reset) begin held <= 1'b0; held_rot <= 1'b0; held_flip <= 1'b0; end
        else begin
            held      <= (DDRAM_RD | DDRAM_WE) && DDRAM_BUSY;
            held_rot  <= use_rot;
            held_flip <= use_flip;
        end
    end

    // a flip burst in flight: its beats belong to the flip reader, and nothing
    // else is issued until the last one is back (flip reads start only with no
    // read data owed, so every beat while this is set is the flip reader's)
    logic fown;
    wire  f_acc = DDRAM_RD && !DDRAM_BUSY && use_flip;
    always_ff @(posedge clk) begin
        if (reset) fown <= 1'b0;
        else if (f_acc) fown <= 1'b1;
        else if (fown && DDRAM_DOUT_READY && owed == 9'd1) fown <= 1'b0;
    end

    // a client write never passes read data still on its way (reads may queue
    // behind reads: Avalon returns the data in order)
    wire cl_ok = !use_rot && !use_flip && !fown && !(c_we && reads_out);

    assign DDRAM_RD       = (cl_ok && c_rd) || (use_flip && f_rd);
    assign DDRAM_WE       = use_rot || (cl_ok && c_we);
    assign DDRAM_ADDR     = use_rot ? head[FW-1 -: 29] : use_flip ? {CLIENT_BASE, f_addr} : {CLIENT_BASE, c_addr};
    assign DDRAM_DIN      = use_rot ? head[71:8] : c_din;
    assign DDRAM_BE       = use_rot ? head[7:0]  : c_be;
    assign DDRAM_BURSTCNT = use_rot ? 8'd1 : use_flip ? f_burst : c_we ? 8'd1 : c_burst;
    assign head_done      = use_rot && !DDRAM_BUSY;     // only while a head is presented

    assign c_busy   = DDRAM_BUSY || !cl_ok;
    assign c_dout   = DDRAM_DOUT;
    assign c_dready = DDRAM_DOUT_READY && !fown;
    assign f_busy   = DDRAM_BUSY || !use_flip;
    assign f_dready = DDRAM_DOUT_READY && fown;
endmodule
