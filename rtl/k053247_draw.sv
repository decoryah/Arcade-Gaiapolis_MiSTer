//------------------------------------------------------------------------------
// K053247 sprite rasterizer for Gaiapolis.
//
// Walks the ordered object list from k053247_objlist once per display line and
// rasterizes whatever covers it into a line buffer with a per-pixel Z buffer,
// as zdrawgfxzoom32GP does. Semantics follow tools/render_model.py; the design
// notes are in docs/sprite-rasterizer.md.
//
// Only one output line is produced per pass, and tile rows tile the destination
// exactly, so at most one tile row of a sprite can cover a given line. That
// collapses the destination rectangle to a single scanline and keeps the
// per-tile cost to one ROM fetch plus a DDA.
//------------------------------------------------------------------------------
`default_nettype none

module k053247_draw #(
    parameter int VIS_W  = 376,
    parameter int VIS_X0 = 40,
    parameter int VIS_Y0 = 16,
    parameter int VIS_H  = 224,
    parameter int LB_AW  = 9,
    // k055673 set_config(K055673_LAYOUT_RNG, -61, -22) for gaiapolis
    parameter int DX = -61,
    parameter int DY = -22
) (
    input  logic        clk,
    input  logic        reset,

    input  logic        line_start,
    input  logic  [8:0] line,
    output logic        busy,

    // Only a few bits of each register matter here: k46r5[1:0] is screen flip,
    // opset[6] selects the wrap size, list_q[3:2] is unused drawmode padding.
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic  [7:0] k46r5,          // k053246 register 5: screen flip
    input  logic [15:0] k46_offx,       // (regs[0] << 8) | regs[1]
    input  logic [15:0] k46_offy,       // (regs[2] << 8) | regs[3]
    input  logic [15:0] opset,          // k053247 register 0x0c
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic  [7:0] colorbase,      // sprite colour base, pre-masked

    output logic  [9:0] list_idx,
    output logic  [7:0] yr_addr,        // the entry's line range from the list builder
    input  logic [21:0] yr_q,
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [31:0] list_q,
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic  [9:0] list_count,

    output logic [10:0] ram_addr,
    input  logic [15:0] ram_q,

    // sprite ROM: address is the 16-pixel row index, code*16 + row.
    // rom_q[63:56] is the lowest byte of the eight.
    output logic        rom_req,
    output logic [19:0] rom_addr,
    input  logic        rom_ack,
    input  logic [63:0] rom_q,

    output logic  [9:0] zoom_addr,
    input  logic [23:0] zoom_q,
    output logic [10:0] recip_addr,
    input  logic [23:0] recip_q,

    input  logic [LB_AW-1:0] px,
    output logic        out_opaque,
    output logic [11:0] out_pen,
    output logic  [7:0] out_pri,
    output logic        out_shadow,
    output logic  [1:0] out_shtab,
    output logic  [7:0] out_shpri,      // the shadow object's priority, for the mixer

    output logic        shadow_overlap,

    // diagnostics for the frozen-state bench
    output logic [31:0] dbg_objs, dbg_rows, dbg_cols, dbg_pxw
);
    // Nearly every value here is a field carved out of a 16-bit chip register
    // or a wide intermediate that is then truncated, so unused bits are the
    // normal case rather than a mistake. Waived once for the whole module
    // instead of nineteen times.
    /* verilator lint_off UNUSEDSIGNAL */

    localparam logic signed [17:0] DXS = 18'(DX);
    localparam logic signed [17:0] DYS = 18'(DY);
    localparam logic signed [17:0] CLS = 18'(VIS_X0);
    localparam logic signed [17:0] CRS = 18'(VIS_X0 + VIS_W - 1);
    localparam logic signed [17:0] CTS = 18'(VIS_Y0);
    localparam logic signed [17:0] CBS = 18'(VIS_Y0 + VIS_H - 1);

    // ------------------------------------------------------------ buffers
    logic        bank;
    logic [20:0] solid [2][VIS_W];      // {opaque, pen[11:0], pri[7:0]}
    logic [10:0] shade [2][VIS_W];      // {flag, table[1:0], priority[7:0]}
    logic  [7:0] zbuf  [VIS_W];
    logic [15:0] szbuf [VIS_W];         // {z, priority}

    logic [20:0] rd_solid;
    logic [10:0] rd_shade;
    always_ff @(posedge clk) begin
        rd_solid <= solid[~bank][px];
        rd_shade <= shade[~bank][px];
    end
    assign out_opaque = rd_solid[20];
    assign out_pen    = rd_solid[19:8];
    assign out_pri    = rd_solid[7:0];
    assign out_shadow = rd_shade[10];
    assign out_shtab  = rd_shade[9:8];
    assign out_shpri  = rd_shade[7:0];

    function automatic logic [5:0] xoffset(input logic [2:0] i);
        case (i)
            3'd0: return 6'd0;  3'd1: return 6'd1;  3'd2: return 6'd4;  3'd3: return 6'd5;
            3'd4: return 6'd16; 3'd5: return 6'd17; 3'd6: return 6'd20; default: return 6'd21;
        endcase
    endfunction
    function automatic logic [5:0] yoffset(input logic [2:0] i);
        case (i)
            3'd0: return 6'd0;  3'd1: return 6'd2;  3'd2: return 6'd8;  3'd3: return 6'd10;
            3'd4: return 6'd32; 3'd5: return 6'd34; 3'd6: return 6'd40; default: return 6'd42;
        endcase
    endfunction

    typedef enum logic [5:0] {
        D_IDLE, D_CLR, D_OBJ, D_OBJW,
        D_R0, D_R1, D_R2, D_R3, D_R4, D_R5, D_R6, D_LAT,
        D_ZY, D_ZYW, D_ZY2, D_ZXW, D_ZX2, D_GEOM, D_GEOM2,
        D_TY, D_TYC, D_SY1, D_SY2, D_SY3, D_SY4,
        D_TX, D_TXC, D_SX1, D_SX2, D_SX2B, D_SX3, D_ROWW, D_PIX,
        D_NEXTTX, D_NEXTOBJ
    } state_t;
    state_t st;

    logic  [9:0] obj_i;
    logic  [7:0] ent, zcode, opri;
    logic  [3:0] drawmode;
    logic  [1:0] shtab;
    logic [15:0] w0, w1, w2, w3, w4, w5, w6;
    logic [23:0] zoomx, zoomy;
    logic  [9:0] scalex, scaley;
    logic        nozoom;
    logic signed [17:0] ox, oy, sy, sx, pxl, pxr, cur_px;
    logic  [3:0] width, height;
    logic  [2:0] ty, tx, xa, ya;
    logic [23:0] yacc, xacc, stride_x, stride_y;
    logic [12:0] zh, zw;
    logic [31:0] ddax;
    logic  [7:0] color;
    logic        flipx, flipy, mirrorx, mirrory, fx, fy;
    logic [15:0] codebase, tempcode_y, tempcode;
    logic  [3:0] src_row, shdpen;
    logic [63:0] rowdata;
    logic [LB_AW-1:0] clr_i;

    wire tile_solid = (drawmode < 4'd4);

    // ------------------------------------------------------- geometry (comb)
    // Screen flip is wired through but unexercised: k053246 register 5 reads
    // 0x20 in every captured frame, so both flip bits are clear.
    wire [3:0] szc  = w0[11:8];
    wire [4:0] gwsh = 5'd13 - {3'd0, szc[1:0]};
    wire [4:0] ghsh = 5'd13 - {3'd0, szc[3:2]};
    wire [23:0] gwshift = zoomx >> gwsh;
    wire [23:0] ghshift = zoomy >> ghsh;

    wire [17:0] wrapsz  = opset[6] ? 18'd512 : 18'd1024;
    wire [17:0] wrapmsk = wrapsz - 18'd1;
    wire [17:0] xwlim   = opset[6] ? 18'd448 : 18'd640;
    wire [17:0] ywlim   = opset[6] ? 18'd384 : 18'd512;

    wire signed [17:0] oxr = $signed({8'd0, w3[9:0]});
    wire signed [17:0] oyr = $signed({8'd0, w2[9:0]});
    wire signed [17:0] ox1 = (k46r5[0] ? -oxr : oxr) + DXS;
    wire signed [17:0] oy1 = (k46r5[1] ? -oyr : oyr) - DYS;
    wire signed [17:0] ox2 = (ox1 - $signed({2'd0, k46_offx})) & $signed(wrapmsk);
    wire signed [17:0] oy2 = ((-oy1) - $signed({2'd0, k46_offy})) & $signed(wrapmsk);
    // registered half-way (D_GEOM), the wrap and the zoom offset follow (D_GEOM2):
    // the whole chain from the K053246 offset registers was a -1.6 ns path
    logic signed [17:0] ox2_r, oy2_r;
    wire signed [17:0] ox3 = (ox2_r >= $signed(xwlim)) ? ox2_r - $signed(wrapsz) : ox2_r;
    wire signed [17:0] oy3 = (oy2_r >= $signed(ywlim)) ? oy2_r - $signed(wrapsz) : oy2_r;
    wire signed [17:0] gox = ox3 - $signed({4'd0, gwshift[13:0]});
    wire signed [17:0] goy = oy3 - $signed({4'd0, ghshift[13:0]});

    // ------------------------------------------------------ tile row / column
    wire [23:0] ysum0 = yacc + 24'd2048;
    wire [23:0] ysum1 = yacc + zoomy + 24'd2048;
    wire signed [17:0] sy_c = oy + $signed({6'd0, ysum0[23:12]});
    wire [12:0] zh_c = nozoom ? 13'd16 : (ysum1[23:12] - ysum0[23:12]);

    wire [23:0] xsum0 = xacc + 24'd2048;
    wire [23:0] xsum1 = xacc + zoomx + 24'd2048;
    wire signed [17:0] sx_c = ox + $signed({6'd0, xsum0[23:12]});
    wire [12:0] zw_c = nozoom ? 13'd16 : (xsum1[23:12] - xsum0[23:12]);

    // mirroring, per k053247_draw_yxloop_gx
    wire [3:0] tx2 = {1'b0, tx} << 1;
    wire [3:0] ty2 = {1'b0, ty} << 1;
    wire xmir_alt = (~flipx) ^ (tx2 < width);
    wire ymir_alt = (~flipy) ^ (ty2 >= height);
    wire [2:0] xrev = width[2:0]  - 3'd1 - tx + xa;
    wire [2:0] xfwd = tx + xa;
    wire [2:0] yrev = height[2:0] - 3'd1 - ty + ya;
    wire [2:0] yfwd = ty + ya;
    wire [2:0] xsel = mirrorx ? (xmir_alt ? xrev : xfwd) : (flipx ? xrev : xfwd);
    // the same for the column after this one: its row is asked for as soon as
    // this column's arrives, so the burst runs under this column's pixel loop
    wire [2:0] tx_n = tx + 3'd1;
    wire [3:0] tx2_n = {1'b0, tx_n} << 1;
    wire xmir_alt_n = (~flipx) ^ (tx2_n < width);
    wire [2:0] xrev_n = width[2:0] - 3'd1 - tx_n + xa;
    wire [2:0] xfwd_n = tx_n + xa;
    wire [2:0] xsel_n = mirrorx ? (xmir_alt_n ? xrev_n : xfwd_n) : (flipx ? xrev_n : xfwd_n);
    wire has_next = ({1'b0, tx} + 4'd1) < width;
    logic        pf_valid, pf_have;     // a prefetch is out for the next column; its row has arrived
    logic [63:0] rowdata_pf;
    wire [2:0] ysel = mirrory ? (ymir_alt ? yrev : yfwd) : (flipy ? yrev : yfwd);
    wire fx_c = mirrorx ? xmir_alt : flipx;
    wire fy_c = mirrory ? ymir_alt : flipy;

    // this line's source row, and the clipped destination span for this tile
    // the source row: line - sy, times the row's reciprocal stride, in three
    // registered steps (as one clock the multiply missed the cold corner)
    wire signed [17:0] lsy = $signed({9'd0, line}) - sy;
    logic  [8:0] lsy_r;
    logic [32:0] ymul_r;
    wire  [3:0] yoff = ymul_r[22:19];

    wire signed [17:0] sxz    = sx + $signed({5'd0, zw}) - 18'sd1;
    wire signed [17:0] pxl_c  = (sx  > CLS) ? sx  : CLS;
    wire signed [17:0] pxr_c  = (sxz < CRS) ? sxz : CRS;
    // the first drawn pixel's offset into the column, then its source
    // position: a subtract and a multiply, one state each (together they
    // were a -2.2 ns path at 96 MHz)
    logic [9:0] pxoff;
    wire [33:0] xmul = {24'd0, pxoff} * {10'd0, stride_x};

    wire row_covers  = (zh != 13'd0) && (lsy >= 18'sd0) && (lsy < $signed({5'd0, zh}))
                    && (sy <= CBS) && ((sy + $signed({5'd0, zh}) - 18'sd1) >= CTS);
    wire col_visible = (zw != 13'd0) && (sx <= CRS) && (sxz >= CLS);

    // ---- pixel extraction from the fetched 16-pixel row ----
    wire [3:0] x_off  = ddax[22:19];
    wire [3:0] srccol = fx ? (~x_off) : x_off;
    // Plane p of pixel c sits at bit planeoffset[p] + xoffset[c], and
    // xoffset jumps from 7 to 32 at pixel 8 -- so the upper half's planes run
    // through bytes 7,6,5,4 while the lower half's run through 3,2,1,0. The
    // byte order reverses across the halves; it does not simply shift.
    wire [7:0] pl0 = srccol[3] ? rowdata[ 7: 0] : rowdata[39:32];   // MSB plane
    wire [7:0] pl1 = srccol[3] ? rowdata[15: 8] : rowdata[47:40];
    wire [7:0] pl2 = srccol[3] ? rowdata[23:16] : rowdata[55:48];
    wire [7:0] pl3 = srccol[3] ? rowdata[31:24] : rowdata[63:56];   // LSB plane
    wire [2:0] plb = 3'd7 - srccol[2:0];
    wire [3:0] pen = {pl0[plb], pl1[plb], pl2[plb], pl3[plb]};

    wire signed [17:0] lbis = cur_px - CLS;
    wire [LB_AW-1:0] lbi = lbis[LB_AW-1:0];

    // The Z buffers and the shadow flag are block RAM read a pixel ahead: the
    // word for the pixel being decided was addressed the cycle before -- the
    // row's first pixel while its ROM row is fetched, then each next pixel as
    // the previous one is written. Consecutive pixels of a row have distinct
    // x and rows are several states apart, so a read never meets a write to
    // the same address. (As registers with per-pixel muxes these three were
    // 16K ALUTs, most of the device.)
    wire signed [17:0] lbis_next  = cur_px + 18'sd1 - CLS;
    wire signed [17:0] lbis_first = pxl - CLS;
    wire [LB_AW-1:0]   rd_lbi = (st == D_PIX) ? lbis_next[LB_AW-1:0] : lbis_first[LB_AW-1:0];
    logic  [7:0] zb_q;
    logic [15:0] szb_q;
    logic [10:0] sh_q;
    always_ff @(posedge clk) begin
        zb_q  <= zbuf[rd_lbi];
        szb_q <= szbuf[rd_lbi];
        sh_q  <= shade[bank][rd_lbi];
    end
    wire [7:0] szb_z = szb_q[15:8];
    wire [7:0] szb_p = szb_q[7:0];
    // the decided pixel, one cycle ahead of its write
    logic            px_valid_a, solid_a, shade_a, ovl_a;
    logic [LB_AW-1:0] lbi_a;
    logic      [3:0] pen_a;

    /* verilator lint_on UNUSEDSIGNAL */

    // -------------------------------------------------------------------- FSM
    always_ff @(posedge clk) begin
        px_valid_a <= 1'b0;
        if (reset) begin
            st <= D_IDLE; busy <= 1'b0; bank <= 1'b0;
            rom_req <= 1'b0; shadow_overlap <= 1'b0; pf_valid <= 1'b0; pf_have <= 1'b0;
            dbg_objs <= '0; dbg_rows <= '0; dbg_cols <= '0; dbg_pxw <= '0;
        end else if (line_start && st != D_IDLE) begin
            // the previous line overran its budget: abandon it and start this
            // one, as the hardware would -- whatever was drawn is what shows
            bank <= ~bank; busy <= 1'b1;
            rom_req <= 1'b0; pf_valid <= 1'b0; pf_have <= 1'b0; clr_i <= '0; st <= D_CLR;
        end else begin
            // a prefetched row arriving while the pixel loop runs
            if (pf_valid && !pf_have && rom_ack && st != D_ROWW) begin
                rowdata_pf <= rom_q; rom_req <= 1'b0; pf_have <= 1'b1;
            end
            case (st)
                D_IDLE: begin
                    busy <= 1'b0;
                    if (line_start) begin
                        bank <= ~bank; busy <= 1'b1; clr_i <= '0; st <= D_CLR;
                    end
                end

                D_CLR: begin
                    // clear the bank we are about to render into, not the one
                    // being scanned out (the writes are in the chain below)
                    if (clr_i == LB_AW'(VIS_W - 1)) begin
                        obj_i <= '0;
                        if (list_count == 10'd0) begin st <= D_IDLE; busy <= 1'b0; end
                        else st <= D_OBJ;
                    end else clr_i <= clr_i + 1'd1;
                end

                D_OBJ:  begin list_idx <= obj_i; dbg_objs <= dbg_objs + 1'd1; st <= D_OBJW; end
                D_OBJW: st <= D_R0;

                D_R0: begin
                    ent      <= list_q[15:8];
                    yr_addr  <= list_q[15:8];
                    zcode    <= list_q[23:16];
                    opri     <= list_q[31:24];
                    drawmode <= list_q[7:4];
                    shtab    <= list_q[1:0];
                    shdpen   <= (list_q[7:4] == 4'd5) ? 4'd1 : 4'd15;
                    ram_addr <= {list_q[15:8], 3'd0};
                    st <= D_R1;
                end
                // The address register and the RAM read are both registered, so
                // ram_q lags the address by two states: word 0 arrives in D_R2.
                D_R1:  begin ram_addr <= {ent, 3'd1};                st <= D_R2;  end
                // the builder's line range for this entry (asked for in D_R0) is
                // here now: an object that misses the line costs five clocks
                D_R2:  begin
                    ram_addr <= {ent, 3'd2}; w0 <= ram_q;
                    if ($signed({9'd0, line}) < $signed({{7{yr_q[21]}}, yr_q[21:11]}) ||
                        $signed({9'd0, line}) > $signed({{7{yr_q[10]}}, yr_q[10:0]})) st <= D_NEXTOBJ;
                    else st <= D_R3;
                end
                D_R3:  begin ram_addr <= {ent, 3'd3}; w1 <= ram_q;   st <= D_R4;  end
                D_R4:  begin ram_addr <= {ent, 3'd4}; w2 <= ram_q;   st <= D_R5;  end
                D_R5:  begin ram_addr <= {ent, 3'd5}; w3 <= ram_q;   st <= D_R6;  end
                D_R6:  begin ram_addr <= {ent, 3'd6}; w4 <= ram_q;   st <= D_LAT; end
                D_LAT: begin w5 <= ram_q;                            st <= D_ZY;  end

                D_ZY: begin
                    w6 <= ram_q;
                    scaley <= w4[9:0]; zoom_addr <= w4[9:0];
                    st <= D_ZYW;
                end
                D_ZYW: st <= D_ZY2;
                D_ZY2: begin
                    zoomy     <= zoom_q;
                    scalex    <= w0[14] ? scaley : w5[9:0];
                    zoom_addr <= w0[14] ? scaley : w5[9:0];
                    st <= D_ZXW;
                end
                D_ZXW: st <= D_ZX2;
                D_ZX2: begin zoomx <= zoom_q; st <= D_GEOM; end

                D_GEOM: begin
                    nozoom  <= (scalex == 10'h40) && (scaley == 10'h40);
                    mirrorx <= w6[14];
                    mirrory <= w6[15];
                    flipx   <= w6[14] ? 1'b0    : (w0[12] ^ k46r5[0]);
                    flipy   <= w6[15] ? w0[13]  : (w0[13] ^ k46r5[1]);
                    // gaiapols_sprite_callback
                    color   <= colorbase | {2'd0, w6[9], 5'd0} | {3'd0, w6[4:0]};
                    width   <= 4'd1 << szc[1:0];
                    height  <= 4'd1 << szc[3:2];
                    xa <= {2'd0, w1[0]} + {1'd0, w1[2], 1'b0} + {w1[4], 2'd0};
                    ya <= {2'd0, w1[1]} + {1'd0, w1[3], 1'b0} + {w1[5], 2'd0};
                    codebase <= w1 & ~16'h003f;
                    ox2_r <= ox2;
                    oy2_r <= oy2;
                    st <= D_GEOM2;
                end
                D_GEOM2: begin
                    ox <= gox;
                    oy <= goy;
                    ty <= 3'd0; yacc <= '0;
                    st <= D_TY;
                end

                // ---- find the tile row covering this line ----
                D_TY:  begin sy <= sy_c; zh <= zh_c; st <= D_TYC; end
                D_TYC: begin
                    if (row_covers) begin
                        dbg_rows <= dbg_rows + 1'd1;
                        recip_addr <= zh[10:0];
                        fy         <= fy_c;
                        tempcode_y <= codebase + {10'd0, yoffset(ysel)};
                        st <= D_SY1;
                    end else if (ty == height[2:0] - 3'd1) begin
                        st <= D_NEXTOBJ;
                    end else begin
                        ty <= ty + 3'd1; yacc <= yacc + zoomy; st <= D_TY;
                    end
                end
                D_SY1: begin lsy_r <= lsy[8:0]; st <= D_SY2; end
                D_SY2: begin stride_y <= recip_q; st <= D_SY3; end
                D_SY3: begin ymul_r <= {24'd0, lsy_r} * {9'd0, stride_y}; st <= D_SY4; end
                D_SY4: begin
                    src_row <= fy ? (~yoff) : yoff;
                    tx <= 3'd0; xacc <= '0;
                    st <= D_TX;
                end

                // ---- walk the tiles across that row ----
                D_TX:  begin sx <= sx_c; zw <= zw_c; st <= D_TXC; end
                D_TXC: begin
                    if (col_visible) begin
                        dbg_cols <= dbg_cols + 1'd1;
                        recip_addr <= zw[10:0];
                        fx         <= fx_c;
                        tempcode   <= tempcode_y + {10'd0, xoffset(xsel)};
                        st <= D_SX1;
                    end else begin
                        if (pf_valid) begin rom_req <= 1'b0; pf_valid <= 1'b0; pf_have <= 1'b0; end   // not wanted after all
                        st <= D_NEXTTX;
                    end
                end
                D_SX1: st <= D_SX2;
                D_SX2: begin
                    stride_x <= recip_q;
                    pxl <= pxl_c; pxr <= pxr_c;
                    st <= D_SX2B;
                end
                D_SX2B: begin
                    pxoff <= 10'(pxl - sx);      // at most a tile column's width
                    st <= D_SX3;
                end
                D_SX3: begin
                    ddax     <= xmul[31:0];
                    cur_px   <= pxl;
                    if (pf_valid && pf_have) begin              // this column's row came early
                        rowdata <= rowdata_pf; pf_have <= 1'b0;
                        if (has_next) begin rom_addr <= {tempcode_y + {10'd0, xoffset(xsel_n)}, src_row}; rom_req <= 1'b1; end
                        else pf_valid <= 1'b0;
                        st <= D_PIX;
                    end else if (pf_valid) begin                // still on its way
                        st <= D_ROWW;
                    end else begin
                        rom_addr <= {tempcode, src_row};
                        rom_req  <= 1'b1;
                        st <= D_ROWW;
                    end
                end
                // (a prefetched row can land on the clock the wait begins: then it
                // is already in rowdata_pf)
                D_ROWW: if (rom_ack || (pf_valid && pf_have)) begin
                    rowdata <= (pf_valid && pf_have) ? rowdata_pf : rom_q;
                    if (has_next) begin                         // ask for the next column's row now
                        rom_addr <= {tempcode_y + {10'd0, xoffset(xsel_n)}, src_row}; rom_req <= 1'b1;
                        pf_valid <= 1'b1; pf_have <= 1'b0;
                    end else begin rom_req <= 1'b0; pf_valid <= 1'b0; end
                    st <= D_PIX;
                end

                // The pixel loop is two stages: this state decides pixel n
                // (its pen, the Z and shadow compares) into registers while
                // the block below writes pixel n-1 -- the decision straight
                // into the line-buffer write enables was the design's tightest
                // path. A row's last write lands in the D_NEXTTX cycle.
                D_PIX: begin
                    px_valid_a <= 1'b1;
                    lbi_a <= lbi; pen_a <= pen; ovl_a <= sh_q[10];
                    // drawmode 1 also rejects the shadow pen
                    solid_a <= tile_solid && (pen != 4'd0)
                            && !(drawmode[1:0] != 2'd0 && pen >= shdpen)
                            && (zb_q >= zcode);
                    shade_a <= !tile_solid && (pen >= shdpen) && (szb_z >= zcode) && (szb_p > opri);
                    ddax <= ddax + {8'd0, stride_x};
                    if (cur_px >= pxr) st <= D_NEXTTX;
                    else cur_px <= cur_px + 18'sd1;
                end

                D_NEXTTX: begin
                    if (tx == width[2:0] - 3'd1) st <= D_NEXTOBJ;
                    else begin tx <= tx + 3'd1; xacc <= xacc + zoomx; st <= D_TX; end
                end

                D_NEXTOBJ: begin
                    if (obj_i + 10'd1 == list_count) begin st <= D_IDLE; busy <= 1'b0; end
                    else begin obj_i <= obj_i + 10'd1; st <= D_OBJ; end
                end

                default: st <= D_IDLE;
            endcase

            // ---- one write per buffer per cycle: the pixel decided last
            // cycle, else the line clear. One statement chain per RAM, so
            // Quartus sees one write port (two, and every buffer became
            // registers: 25K ALUTs)
            if (px_valid_a && solid_a) begin
                dbg_pxw <= dbg_pxw + 1'd1;
                zbuf[lbi_a]         <= zcode;
                solid[bank][lbi_a]  <= {1'b1, color, pen_a, opri};
                shade[bank][lbi_a]  <= 11'd0;  // a later solid clears the shadow
            end else if (px_valid_a && shade_a) begin
                szbuf[lbi_a]        <= {zcode, opri};
                shade[bank][lbi_a]  <= {1'b1, shtab, opri};
                if (ovl_a) shadow_overlap <= 1'b1;
            end else if (st == D_CLR) begin
                solid[bank][clr_i] <= '0;
                shade[bank][clr_i] <= '0;
                zbuf[clr_i]  <= 8'hff;
                szbuf[clr_i] <= 16'hffff;
            end
        end
    end
endmodule
