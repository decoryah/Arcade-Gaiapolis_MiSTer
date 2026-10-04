// Flip Screen gate: target/mister/flip_buf.sv behind ddr_arb and a behavioural DDR3,
// with a synthetic raster (512 clocks-of-12 per line, 264 lines, 376 x 224 visible),
// the framework's rotate writes (one per 12 clocks, at their own phase) and the core's
// memory client (random read bursts and writes) as competing traffic.
//
// Checks, every visible pixel of every frame:
//   * Flip off, or the first frame after it is switched on: the output is the input.
//   * Otherwise out(x, y) = in(375-x, 223-y) of the frame before, exactly.
//   * The client's read data always matches what it should (the flip reader's beats are
//     never delivered to it), the DDR model sees no protocol error, no line underruns.
// Flip is switched on and off at random points inside frames.
`default_nettype none

module tb_flip_top #(
    parameter int LAT      = 24,
    parameter int BUSY_PCT = 20,
    parameter int FRAMES   = 40,
    parameter int CL_MASK  = 9,         // the client starts an operation on 1 of 2^CL_MASK idle clocks
    parameter int FLIP_ON  = 1          // 0: flip never switched on (the traffic baseline)
) (
    input  logic clk,
    output logic done,
    output logic fail
);
    localparam int W = 376, H = 224, VY0 = 16, LINES = 264;

    // ------------------------------------------------------------ the raster
    logic [3:0] div = 0;
    wire        cen = (div == 4'd0);
    logic [8:0] hx = 0;
    logic [8:0] vy = 0;
    int         fr = 0;                             // frames ended so far (vsync rises)
    always_ff @(posedge clk) begin
        div <= (div == 4'd11) ? 4'd0 : div + 4'd1;
        if (cen) begin
            if (hx == 9'd511) begin hx <= 0; vy <= (vy == 9'(LINES - 1)) ? 9'd0 : vy + 9'd1; end
            else hx <= hx + 9'd1;
        end
    end
    wire de_i = (hx < 9'(W)) && (vy >= 9'(VY0)) && (vy < 9'(VY0 + H));
    wire vs_i = (vy >= 9'd245) && (vy <= 9'd247);

    function automatic [23:0] pix(input int x, input int y, input int f);
        logic [31:0] h;
        h = 32'(x) * 32'd7919 + 32'(y) * 32'd104729 + 32'(f) * 32'd1299709 + 32'h1234567;
        h = h ^ (h >> 15); h = h * 32'h2c1b3c6d; h = h ^ (h >> 12);
        return h[23:0];
    endfunction
    wire [23:0] rgb_i = de_i ? pix(int'(hx), int'(vy) - VY0, fr) : 24'd0;

    // ------------------------------------------------------------- flip_en
    logic [31:0] lf = 32'hC0FFEE01;
    always_ff @(posedge clk) lf <= {lf[30:0], lf[31] ^ lf[21] ^ lf[1] ^ lf[0]};
    logic        flip_en = 0;
    int          flip_cnt = 100000;
    int          toggles = 0;
    always_ff @(posedge clk) begin
        flip_cnt <= flip_cnt - 1;
        if (flip_cnt == 0) begin
            flip_en  <= (FLIP_ON != 0) && ~flip_en;
            toggles  <= toggles + 1;
            flip_cnt <= 400000 + int'(lf[22:0]) * 2;           // 0.25 .. 1.5 frames
        end
    end

    // ---------------------------------------------------------------- the DUT
    wire [23:0] rgb_o;
    wire        fb_we, fb_underrun;
    wire [28:0] fb_addr;
    wire [63:0] fb_din;
    logic       rot_we = 0;
    logic [28:0] rot_addr = 0;
    logic [63:0] rot_din = 0;
    wire        fl_rd, fl_busy, fl_dready;
    wire [24:0] fl_addr;
    wire  [7:0] fl_burst;
    wire [63:0] ddr_dout;

    flip_buf u_flip (
        .clk(clk), .cen(cen), .flip_en(flip_en), .rgb_i(rgb_i), .de_i(de_i), .vs_i(vs_i), .rgb_o(rgb_o),
        .wr_hold(rot_we), .wr_we(fb_we), .wr_addr(fb_addr), .wr_din(fb_din),
        .rd_req(fl_rd), .rd_addr(fl_addr), .rd_burst(fl_burst), .rd_busy(fl_busy), .rd_data(ddr_dout), .rd_ready(fl_dready),
        .underrun(fb_underrun)
    );

    logic        c_rd = 0, c_we = 0;
    logic [24:0] c_addr = 0;
    logic  [7:0] c_burst = 1;
    logic [63:0] c_din = 0;
    wire         c_busy, c_dready;
    wire         DDRAM_BUSY, DDRAM_DOUT_READY, DDRAM_RD, DDRAM_WE;
    wire   [7:0] DDRAM_BURSTCNT, DDRAM_BE;
    wire  [28:0] DDRAM_ADDR;
    wire  [63:0] DDRAM_DOUT, DDRAM_DIN;
    wire         ovf;

    ddr_arb u_arb (
        .clk(clk), .reset(1'b0),
        .c_rd(c_rd), .c_we(c_we), .c_addr(c_addr), .c_burst(c_burst), .c_din(c_din), .c_be(8'hFF),
        .c_busy(c_busy), .c_dout(ddr_dout), .c_dready(c_dready),
        .r_we(rot_we | fb_we), .r_addr(fb_we ? fb_addr : rot_addr), .r_din(fb_we ? fb_din : rot_din), .r_be(fb_we ? 8'hFF : 8'h0f),
        .f_rd(fl_rd), .f_addr(fl_addr), .f_burst(fl_burst), .f_busy(fl_busy), .f_dready(fl_dready),
        .DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(DDRAM_BURSTCNT), .DDRAM_ADDR(DDRAM_ADDR),
        .DDRAM_DOUT(DDRAM_DOUT), .DDRAM_DOUT_READY(DDRAM_DOUT_READY),
        .DDRAM_RD(DDRAM_RD), .DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE), .DDRAM_WE(DDRAM_WE),
        .overflow(ovf)
    );
    ddr_model #(.AW(20), .LAT(LAT), .BUSY_PCT(BUSY_PCT)) ddr (
        .clk(clk), .DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(DDRAM_BURSTCNT), .DDRAM_ADDR(DDRAM_ADDR),
        .DDRAM_DOUT(DDRAM_DOUT), .DDRAM_DOUT_READY(DDRAM_DOUT_READY),
        .DDRAM_RD(DDRAM_RD), .DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE), .DDRAM_WE(DDRAM_WE)
    );

    function automatic [63:0] hmem(input [19:0] a);
        return {a, a ^ 20'hABCDE, ~a, 4'hC};
    endfunction
    initial for (int i = 0; i < 20'h50000; i++) ddr.mem[i] = hmem(20'(i));

    // screen_rotate's stand-in: a write every 12 clocks, at its own phase
    logic [3:0] rdiv = 4'd5;
    logic [19:0] rcnt = 0;
    always_ff @(posedge clk) begin
        rot_we <= 1'b0;
        rdiv <= (rdiv == 4'd11) ? 4'd0 : rdiv + 4'd1;
        if (rdiv == 4'd0) begin
            rot_we <= 1'b1; rot_addr <= {7'b0010010, 2'b01, rcnt}; rot_din <= {44'd0, rcnt}; rcnt <= rcnt + 20'd1;
        end
    end

    // ------------------------------------------------- the core's memory client
    typedef enum logic [1:0] {C_IDLE, C_PRES, C_WAIT} cst_t;
    cst_t        cst = C_IDLE;
    logic        is_wr;
    logic [19:0] cbase;
    int          cnt, clen;
    int          c_reads = 0, c_writes = 0, c_beats = 0, c_bad = 0, c_stray = 0;
    always_ff @(posedge clk) begin
        case (cst)
            C_IDLE: if ((lf[15:0] & 16'((1 << CL_MASK) - 1)) == 16'd0) begin
                cbase <= {2'b00, lf[25:8]};
                c_addr <= {7'd0, 2'b00, lf[25:8]};
                if (lf[27]) begin
                    c_we <= 1'b1; c_din <= hmem({2'b00, lf[25:8]}); is_wr <= 1'b1; cst <= C_PRES;
                end else begin
                    c_rd <= 1'b1; c_burst <= 8'd1 + {4'd0, lf[31:28]}; clen <= 1 + int'(lf[31:28]); cnt <= 0;
                    is_wr <= 1'b0; cst <= C_PRES;
                end
            end
            C_PRES: if (!c_busy) begin
                c_rd <= 1'b0; c_we <= 1'b0;
                if (is_wr) begin c_writes <= c_writes + 1; cst <= C_IDLE; end else cst <= C_WAIT;
            end
            default: ;
        endcase
        if (c_dready) begin
            if (cst != C_WAIT) c_stray <= c_stray + 1;
            else begin
                if (ddr_dout !== hmem(cbase + 20'(cnt))) c_bad <= c_bad + 1;
                c_beats <= c_beats + 1;
                cnt <= cnt + 1;
                if (cnt == clen - 1) begin c_reads <= c_reads + 1; cst <= C_IDLE; end
            end
        end
    end

    // ------------------------------------------------------------ the checker
    logic [23:0] cap [2][H][W];
    logic        vs_d = 0, fl_exp = 0, wr_exp = 0;
    int          x_chk, y_chk;
    int          n_flip = 0, n_pass = 0, n_bad = 0, n_under = 0, first_bad = 1;
    always_ff @(posedge clk) begin
        vs_d <= vs_i;
        if (vs_i && !vs_d) begin
            fr     <= fr + 1;
            fl_exp <= flip_en && wr_exp;
            wr_exp <= flip_en;
        end
        if (cen && de_i) begin
            cap[fr & 1][int'(vy) - VY0][int'(hx)] <= rgb_i;
            if (fl_exp) begin
                n_flip <= n_flip + 1;
                if (rgb_o !== cap[(fr + 1) & 1][H - 1 - (int'(vy) - VY0)][W - 1 - int'(hx)]) begin
                    n_bad <= n_bad + 1;
                    if (first_bad != 0) begin
                        first_bad <= 0;
                        $display("MISMATCH frame %0d x=%0d y=%0d: got %06x want %06x", fr, int'(hx), int'(vy) - VY0, rgb_o,
                                 cap[(fr + 1) & 1][H - 1 - (int'(vy) - VY0)][W - 1 - int'(hx)]);
                    end
                end
            end else begin
                n_pass <= n_pass + 1;
                if (rgb_o !== rgb_i) n_bad <= n_bad + 1;
            end
        end
        if (fb_underrun) n_under <= n_under + 1;
    end

    // the arbiter's write FIFO
    int max_fill = 0;
    always_ff @(posedge clk) if (int'(u_arb.wp - u_arb.rp) > max_fill) max_fill <= int'(u_arb.wp - u_arb.rp);

    // --------------------------------------------------------------- the end
    always_ff @(posedge clk) begin
        if (!done && fr >= FRAMES) begin
            done <= 1'b1;
            fail <= (n_bad != 0) || (c_bad != 0) || (c_stray != 0) || (n_under != 0) || (ddr.protocol_errors != 0)
                    || (FLIP_ON != 0 && n_flip == 0) || (n_pass == 0) || (c_reads == 0) || ovf;
            $display("flip bench: %0d frames, flip toggled %0d times; pixels flipped %0d (bad %0d), passed %0d; underruns %0d",
                     fr, toggles, n_flip, n_bad, n_pass, n_under);
            $display("  write FIFO: deepest %0d of %0d", max_fill, 1 << u_arb.FIFO_AW);
            $display("  client: %0d reads (%0d beats, %0d wrong, %0d stray), %0d writes; DDR: %0d reads, %0d writes, %0d protocol errors; fifo overflow %0d",
                     c_reads, c_beats, c_bad, c_stray, c_writes, ddr.rd_cmds, ddr.wr_cmds, ddr.protocol_errors, ovf);
        end
    end
    initial begin done = 0; fail = 0; end
endmodule
