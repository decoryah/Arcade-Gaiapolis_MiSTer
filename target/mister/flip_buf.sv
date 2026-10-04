//------------------------------------------------------------------------------
// Flip Screen: the finished picture turned 180 degrees.
//
// The Pocket core's renderers have no global flip, so the flip is done on the
// picture after the mixer, for every output at once. Each frame's visible pixels
// are written into one of two frame buffers in the DDR3; the next frame is shown
// from the other one, read backwards: out(x, y) = in(W-1-x, H-1-y) of the frame
// before. Costs one frame of delay while it is on, and nothing when it is off
// (the output is then the input, unchanged).
//
// A frame buffer is 2 pixels (24 bit each, in 32) per 64-bit word, 256 words per
// line (188 used), so an address is just {frame, line, word}. Frames are written
// through the arbiter's write FIFO (one word per two pixels, never refused: the
// pending word waits while screen_rotate is writing in the same clock). Lines
// are read back a line ahead, in three bursts, into two line buffers in block
// RAM and played in reverse: the line read for output line y is input line
// H-1-y, and the pixels in a word come out in the opposite order.
//
// `fl` (flip this frame) and `wr_frame` (this frame is being written) are
// decided at the start of a frame, so switching the option on or off never
// shows half a frame: the first frame after switching on passes through, the
// second is the first flipped one.
//
// Timing contract with the video chain: `cen` is the pixel enable; `de_i`/`rgb_i`
// are valid at the clock `cen` is high (the downstream registers sample there),
// and rgb_o is valid at the same clock.
//------------------------------------------------------------------------------
`default_nettype none

module flip_buf #(
    parameter int  W = 376,                          // visible pixels per line (even, <= 376 per line buffer word index)
    parameter int  H = 224,                          // visible lines
    parameter [3:0]  CLIENT_BASE = 4'd3,             // the DDR3 client window (byte 0x30000000)
    parameter [24:0] BASE        = 25'h0080000       // word offset of the two frame buffers in that window
) (
    input  logic        clk,
    input  logic        cen,
    input  logic        flip_en,
    input  logic [23:0] rgb_i,
    input  logic        de_i,
    input  logic        vs_i,
    output logic [23:0] rgb_o,

    // frame writes: a one-clock pulse, only in a clock where wr_hold is low
    input  logic        wr_hold,
    output logic        wr_we,
    output logic [28:0] wr_addr,
    output logic [63:0] wr_din,

    // line reads: rd_req and the fields are held until a clock where rd_busy is low
    output logic        rd_req,
    output logic [24:0] rd_addr,
    output logic  [7:0] rd_burst,
    input  logic        rd_busy,
    input  logic [63:0] rd_data,
    input  logic        rd_ready,

    output logic        underrun                     // pulse: a line started before its data was in
);
    localparam int WW = W / 2;                       // words per line
    localparam [7:0] LAST_W = 8'(WW - 1);
    localparam [7:0] LAST_L = 8'(H - 1);

    // -------------------------------------------------------------- the raster
    logic        vs_d = 1'b0, de_d = 1'b0;
    logic  [8:0] nx = 9'd0;       // index of the pixel at this cen (counted while de)
    logic  [7:0] ly = 8'd0;       // lines completed in this frame
    logic        wk = 1'b0, rk = 1'b1;   // frame buffer being written / shown
    logic        wr_frame = 1'b0; // flip was on when this frame started: it is written whole
    logic        fl = 1'b0;       // this frame is shown flipped

    wire vs_rise  = vs_i && !vs_d;
    wire line_end = cen && !de_i && de_d;
    wire line_beg = cen && de_i && !de_d;

    logic  [1:0] ready = 2'b00;   // line buffer holds the line to show
    logic        pf_add;
    logic  [1:0] pf_pend = 2'd0;
    logic  [8:0] pf_next = 9'd0;
    logic        take;
    logic        fetch_done;      // the last beat of a line's last burst is in
    logic  [8:0] cur_line;

    always_ff @(posedge clk) begin
        vs_d <= vs_i;
        if (cen) begin
            de_d <= de_i;
            nx   <= de_i ? nx + 9'd1 : 9'd0;
        end
        if (line_end) ly <= ly + 8'd1;
        if (line_end) ready[ly[0]] <= 1'b0;
        if (fetch_done) ready[cur_line[0]] <= 1'b1;
        if (vs_rise) begin
            rk       <= wk;
            wk       <= ~wk;
            fl       <= flip_en && wr_frame;      // the frame that just ended was written whole
            wr_frame <= flip_en;
            ly       <= 8'd0;
            ready    <= 2'b00;
        end
    end

    // -------------------------------------------------------------- the writes
    logic [23:0] pe, po;
    logic        wp_v = 1'b0;
    logic [16:0] wp_a;
    always_ff @(posedge clk) begin
        if (cen && de_i && wr_frame) begin
            if (!nx[0]) pe <= rgb_i;
            else begin po <= rgb_i; wp_a <= {wk, ly, nx[8:1]}; end
        end
        if (wr_we) wp_v <= 1'b0;
        if (cen && de_i && wr_frame && nx[0]) wp_v <= 1'b1;
    end
    assign wr_we   = wp_v && !wr_hold;
    assign wr_addr = {CLIENT_BASE, BASE[24:17], wp_a};
    assign wr_din  = {8'h00, po, 8'h00, pe};

    // -------------------------------------------------------- the line buffers
    (* ramstyle = "no_rw_check" *) logic [63:0] lbuf [512];
    logic [63:0] lq;
    logic        lw_we;
    logic  [8:0] lw_a;
    wire   [8:0] ra = {ly[0], LAST_W - nx[8:1]};
    always_ff @(posedge clk) begin
        if (lw_we) lbuf[lw_a] <= rd_data;
        lq <= lbuf[ra];
    end

    // the pixel for the current cen: words hold the pair (even x, odd x) of the
    // input line, so the reversed read takes the odd one first
    wire [23:0] fpix = nx[0] ? lq[23:0] : lq[55:32];
    assign rgb_o = (fl && de_i) ? fpix : rgb_i;

    // ------------------------------------------------------------- the reader
    // a line becomes due when the line before it has been shown (lines 0 and 1
    // at the start of the frame), and is fetched into the buffer the shown line
    // does not use
    typedef enum logic [1:0] {F_IDLE, F_REQ, F_DATA} fstate_t;
    fstate_t     fst = F_IDLE;
    logic  [1:0] bi;
    logic  [6:0] remain;
    logic  [7:0] beat;

    assign pf_add = line_end && fl && ((9'(ly) + 9'd2) < 9'(H));
    assign take   = (fst == F_IDLE) && (pf_pend != 2'd0);

    wire [7:0] in_line = LAST_L - cur_line[7:0];
    assign rd_req   = (fst == F_REQ);
    assign rd_addr  = {BASE[24:17], rk, in_line, bi[1:0], 6'd0};
    assign rd_burst = (bi == 2'd2) ? 8'(WW - 128) : 8'd64;

    assign lw_we = (fst == F_DATA) && rd_ready;
    assign fetch_done = lw_we && (remain == 7'd1) && (bi == 2'd2);
    assign lw_a  = {cur_line[0], beat};

    always_ff @(posedge clk) begin
        pf_pend <= pf_pend + {1'b0, pf_add} - {1'b0, take};
        if (vs_rise) begin
            pf_next <= 9'd0;
            pf_pend <= (flip_en && wr_frame) ? 2'd2 : 2'd0;
        end
        case (fst)
            F_IDLE: if (take) begin
                cur_line <= pf_next; pf_next <= pf_next + 9'd1;
                bi <= 2'd0; beat <= 8'd0; fst <= F_REQ;
            end
            F_REQ: if (!rd_busy) begin
                remain <= (bi == 2'd2) ? 7'(WW - 128) : 7'd64; fst <= F_DATA;
            end
            F_DATA: if (rd_ready) begin
                beat <= beat + 8'd1; remain <= remain - 7'd1;
                if (remain == 7'd1) begin
                    if (bi == 2'd2) fst <= F_IDLE;
                    else begin bi <= bi + 2'd1; fst <= F_REQ; end
                end
            end
            default: fst <= F_IDLE;
        endcase
    end

    assign underrun = line_beg && fl && !ready[ly[0]];
endmodule
