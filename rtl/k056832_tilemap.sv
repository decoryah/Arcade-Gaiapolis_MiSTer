//------------------------------------------------------------------------------
// K056832 tilemap layers for Gaiapolis (Konami pre-GX / GX123).
//
// Four layers of 8x8 4bpp tiles, each selecting a rectangle of pages from a
// 4x4 grid of 64x32-tile pages held in 128 KB of tile RAM. Semantics follow
// tools/render_model.py, which is pixel-exact against MAME across the
// frozen-state corpus; see docs/hardware.md section 6.
//
// Each display line is rendered into line buffers during the previous line and
// then scanned out, which decouples fetch scheduling from the pixel clock. One
// tile-row fetch serves 8 pixels. The fetch is a three-stage pipeline -- tile
// RAM (attribute and code), tile ROM (the 8-pixel row), emit -- so the two
// memories' latencies overlap each other and the emit; on the Pocket the tile
// RAM is the external SRAM and the ROM an SDRAM burst, ~5 and ~12 clocks. A
// layer then costs about max(RAM, ROM, 8) clocks per group, near 2,500
// clocks for four layers of the 6,144 a 64 us line gives at 96 MHz
// (docs/hardware.md section 11).
//
// Scroll modes: 3 (xy scroll) is what every captured frame uses and is gated;
// 0 (line scroll) and 2 (row scroll) read the per-line/per-8-line X scroll
// from the scroll page in tile RAM exactly as the model does, but no state in
// the corpus exercises them -- they are here because the chip comes out of
// reset in mode 0 and flagging that as unsupported was a false alarm.
//
// `unsupported` is raised for configurations the model has not been checked
// against, rather than rendering something plausible and wrong:
//   * global screen flip
//   * a page span of 3 (not a power of two, so the wrap cannot be a mask)
//------------------------------------------------------------------------------
`default_nettype none

module k056832_tilemap #(
    parameter int VIS_W  = 376,      // visible pixels per line
    parameter int VIS_X0 = 40,       // raster x of the first visible pixel
    parameter int LB_AW  = 9         // ceil(log2(VIS_W))
) (
    input  logic        clk,
    input  logic        reset,

    // Begin rendering the line that is displayed next. `line` is its raster y.
    input  logic        line_start,
    input  logic [ 8:0] line,
    output logic        busy,

    // K056832 VACSET registers and the K055555 per-layer palette bases
    input  logic [15:0] regs      [32],
    input  logic [ 7:0] colorbase [4],

    // Tile RAM: 16 pages x 4096 words. Request/ack: level request, one-cycle
    // ack with the word; a request withdrawn at line_start is dropped.
    output logic        vram_req,
    output logic [15:0] vram_addr,
    input  logic        vram_ack,
    input  logic [15:0] vram_q,

    // Tile ROM: 2 MB seen as 512K x 32. rom_q[31:24] is the lowest byte of the
    // four, so pixel n of the row is rom_q[31-4n -: 4]. Request/ack so this can
    // sit behind the memory arbiter.
    output logic        rom_req,
    output logic [18:0] rom_addr,
    input  logic        rom_ack,
    input  logic [31:0] rom_q,

    // Scan-out of the completed line.
    input  logic [LB_AW-1:0] px,
    output logic [11:0] pix    [4],
    output logic  [3:0] opaque,

    output logic        unsupported
);
    // ------------------------------------------------------------- registers
    // flip/palette bit split, k056832_device::get_tile_info
    wire [1:0] fbits = regs[3][7:6];
    logic [2:0] sm_flips;
    logic [5:0] sm_palm1, sm_palm2;
    logic [1:0] sm_pals2;
    always_comb begin
        case (fbits)
            2'd0: begin sm_flips = 3'd6; sm_palm1 = 6'h3f; sm_pals2 = 2'd0; sm_palm2 = 6'h00; end
            2'd1: begin sm_flips = 3'd4; sm_palm1 = 6'h0f; sm_pals2 = 2'd2; sm_palm2 = 6'h30; end
            2'd2: begin sm_flips = 3'd2; sm_palm1 = 6'h03; sm_pals2 = 2'd2; sm_palm2 = 6'h3c; end
            2'd3: begin sm_flips = 3'd0; sm_palm1 = 6'h00; sm_pals2 = 2'd2; sm_palm2 = 6'h3f; end
        endcase
    end

    // gaiapolis per-layer pixel offsets (mystwarr_v.cpp, VIDEO_START gaiapols)
    localparam logic signed [9:0] OFFS_X [4] = '{ -10'sd1, 10'sd2, 10'sd4, 10'sd5 };
    localparam logic signed [9:0] OFFS_Y [4] = '{ -10'sd1, 10'sd0, 10'sd0, 10'sd0 };

    wire flip_global = |regs[0][5:4];

    // ---------------------------------------------------------- line buffers
    // bit 12 marks an opaque pixel; two banks, render one while scanning out
    logic bank;
    logic [12:0] lbuf0 [2][VIS_W];
    logic [12:0] lbuf1 [2][VIS_W];
    logic [12:0] lbuf2 [2][VIS_W];
    logic [12:0] lbuf3 [2][VIS_W];

    logic [12:0] rd0, rd1, rd2, rd3;
    always_ff @(posedge clk) begin
        rd0 <= lbuf0[~bank][px];
        rd1 <= lbuf1[~bank][px];
        rd2 <= lbuf2[~bank][px];
        rd3 <= lbuf3[~bank][px];
    end
    assign pix[0] = rd0[11:0];
    assign pix[1] = rd1[11:0];
    assign pix[2] = rd2[11:0];
    assign pix[3] = rd3[11:0];
    assign opaque = {rd3[12], rd2[12], rd1[12], rd0[12]};

    // ------------------------------------------------------------------- FSM
    // Layer sequencing (st) wraps three stages that run together:
    //   V  reads the group's attribute and code words from tile RAM,
    //   R  fetches the tile row from ROM,
    //   E  writes the group's pixels into the line buffer.
    // A stage hands its group on when the next one is free, in order, so the
    // line buffer sees exactly the pixel sequence a serial fetch would write.
    typedef enum logic [2:0] { S_IDLE, S_SETUP, S_SCRL, S_SCRL2, S_RUN } state_t;
    state_t st;

    logic  [1:0] cur_l;
    logic [LB_AW-1:0] cur_x;         // E: next line-buffer x
    logic [11:0] vx;                 // E: source x of the pixel being emitted
    logic [10:0] vy;                 // source y, fixed for the line
    logic [11:0] fvx;                // V: source x of the group being fetched
    logic [LB_AW:0] fpx;             // V: first output x of that group
    logic        v_done;             // V: the layer's last group has been fetched

    typedef enum logic [2:0] { V_IDLE, V_ATTR, V_ATTRW, V_CODE, V_CODEW, V_HOLD } vst_t;
    typedef enum logic [1:0] { R_IDLE, R_REQ, R_WAIT, R_HOLD } rst_t;
    vst_t vst;
    rst_t rst;
    logic [15:0] attr_v, code_v;     // V's result
    logic  [3:0] npx_v;
    logic [15:0] attr, code;         // R's copy; attr feeds the decode below
    logic  [3:0] npx_r;
    logic [31:0] rowdata_r;
    logic  [7:0] color_r;
    logic        flipx_r;
    logic        e_busy;             // E
    logic  [3:0] e_cnt;
    logic [31:0] rowdata;
    logic  [7:0] color;
    logic        flipx;   // flipy is applied at fetch time via attr_fy

    wire [4:0] ly       = 5'd8  + {3'd0, cur_l};
    wire [4:0] lx       = 5'd12 + {3'd0, cur_l};
    wire [1:0] rowstart = regs[ly][4:3];
    wire [1:0] rowspan  = regs[ly][1:0];
    wire [1:0] colstart = regs[lx][4:3];
    wire [1:0] colspan  = regs[lx][1:0];

    // page index inside the 4x4 grid, wrapping on the layer's span
    wire [1:0] page_r = rowstart + vy[10:9] + {1'b0, vy[8]};
    wire [1:0] page_c = colstart + fvx[11:10] + {1'b0, fvx[9]};
    wire [3:0] page   = {page_r, page_c};
    // word address: page * 4096 + (ty*64 + tx) * 2
    wire [15:0] vram_base = {page, vy[7:3], fvx[8:3], 1'b0};

    // decoded from the latched attribute word, used by R
    wire [3:0] flips4    = {1'b0, sm_flips};
    wire       attr_flip = attr[flips4];        // x flip; y flip feeds attr_fy
    wire [3:0] fliprsel  = {2'd0, cur_l} << 1;   // regs[1] bit pair for this layer
    /* verilator lint_off UNUSEDSIGNAL */
    // NB: the shift is taken on the whole attribute word, not the low six
    // bits -- for every fbits setting except 0 the palette field pulls in
    // attr[7:6], and masking first silently drops them.
    wire [15:0] attr_shifted = attr >> sm_pals2;
    wire [5:0] attr_col6 = (attr[5:0] & sm_palm1) | (attr_shifted[5:0] & sm_palm2);
    /* verilator lint_on UNUSEDSIGNAL */
    wire [3:0] attr_color = attr_col6[5:2];   // the game's 4bpp tile callback drops bits 1:0
    wire [2:0] attr_fy   = attr[flips4 + 4'd1] ? ~vy[2:0] : vy[2:0];

    wire [2:0] fx = flipx ? ~vx[2:0] : vx[2:0];
    wire [3:0] pixel = rowdata[31 - {fx, 2'b00} -: 4];

    // scroll for the layer being set up. Only the low bits survive the page
    // wrap, so the sum is taken at the width the wrap mask needs.
    // Modes 0/2 replace the register X scroll with a word from the scroll
    // page: page regs[0x18] (bits {4:3,1:0}), word (layer << 11 >> 1) +
    // line*2 + 1 for line scroll, + (line >> 3)*16 + 1 for row scroll.
    wire  [3:0] smsel      = {2'd0, cur_l} << 1;
    wire  [1:0] scrollmode = regs[5][smsel +: 2];
    wire  [3:0] scrollbank = {regs[24][4:3], regs[24][1:0]};
    // word index inside the scroll page: layer*1024, then line*2+1 (mode 0)
    // or (line/8)*16+1 (mode 2)
    wire [11:0] ls_word = {cur_l, 10'd0}
                        + (scrollmode[1] ? {2'd0, line[8:3], 4'd1} : {2'd0, line, 1'b1});
    wire [15:0] scroll_vram_addr = {scrollbank, ls_word};
    logic [15:0] scroll_word;
    wire  [15:0] scroll_reg = (scrollmode == 2'd3) ? regs[sx_i] : scroll_word;
    /* verilator lint_off UNUSEDSIGNAL */
    wire [4:0] sx_i = 5'd20 + {3'd0, cur_l};
    wire [4:0] sy_i = 5'd16 + {3'd0, cur_l};
    wire signed [16:0] scroll_x = $signed({scroll_reg[15], scroll_reg})
                                - $signed({{7{OFFS_X[cur_l][9]}}, OFFS_X[cur_l]});
    wire signed [16:0] scroll_y = $signed({regs[sy_i][15], regs[sy_i]})
                                - $signed({{7{OFFS_Y[cur_l][9]}}, OFFS_Y[cur_l]});
    wire [11:0] wrap_x = ({10'd0, colspan} + 12'd1) << 9;
    wire [10:0] wrap_y = ({ 9'd0, rowspan} + 11'd1) << 8;
    /* verilator lint_on UNUSEDSIGNAL */
    wire [11:0] vx0 = $unsigned(scroll_x[11:0]) + 12'(VIS_X0);
    wire [10:0] vy0 = $unsigned(scroll_y[10:0]) + {2'd0, line};

    // pixels the group at fvx contributes: to the end of its tile, or of the line
    wire [LB_AW:0] left    = (LB_AW+1)'(VIS_W) - fpx;
    wire [3:0]     to_tile = 4'd8 - {1'b0, fvx[2:0]};
    wire [3:0]     npx_now = (left < (LB_AW+1)'(to_tile)) ? left[3:0] : to_tile;
    wire [LB_AW:0] fpx_next = fpx + (LB_AW+1)'(npx_now);

    // stage handovers
    wire v_to_r = (vst == V_HOLD) && (rst == R_IDLE);
    wire r_to_e = (rst == R_HOLD) && !e_busy;
    wire layer_done = v_done && (vst == V_IDLE) && (rst == R_IDLE) && !e_busy;

    always_ff @(posedge clk) begin
        if (reset) begin
            st <= S_IDLE; busy <= 1'b0; bank <= 1'b0;
            rom_req <= 1'b0; vram_req <= 1'b0; unsupported <= 1'b0; cur_l <= 2'd0;
            vst <= V_IDLE; rst <= R_IDLE; e_busy <= 1'b0; v_done <= 1'b0;
        end else if (line_start && st != S_IDLE) begin
            // the previous line overran its budget: abandon it and start this
            // one, as the hardware would -- whatever was drawn is what shows
            bank <= ~bank; busy <= 1'b1;
            rom_req <= 1'b0; vram_req <= 1'b0; cur_l <= 2'd0; st <= S_SETUP;
            vst <= V_IDLE; rst <= R_IDLE; e_busy <= 1'b0; v_done <= 1'b0;
        end else begin
            case (st)
                S_IDLE: begin
                    busy <= 1'b0;
                    if (line_start) begin
                        bank  <= ~bank;
                        busy  <= 1'b1;
                        cur_l <= 2'd0;
                        st    <= S_SETUP;
                        if (flip_global) unsupported <= 1'b1;
                    end
                end

                S_SETUP: begin
                    cur_x <= '0;
                    if (colspan == 2'd2 || rowspan == 2'd2) unsupported <= 1'b1;
                    if (scrollmode == 2'd3) begin
                        vx  <= vx0 & (wrap_x - 12'd1);
                        fvx <= vx0 & (wrap_x - 12'd1);
                        vy  <= vy0 & (wrap_y - 11'd1);
                        fpx <= '0; v_done <= 1'b0; vst <= V_ATTR;
                        st  <= S_RUN;
                    end else begin
                        vram_addr <= scroll_vram_addr;   // line/row scroll word
                        vram_req  <= 1'b1;
                        st <= S_SCRL;
                    end
                end
                S_SCRL: if (vram_ack) begin
                    scroll_word <= vram_q; vram_req <= 1'b0; st <= S_SCRL2;
                end
                S_SCRL2: begin
                    vx  <= vx0 & (wrap_x - 12'd1);
                    fvx <= vx0 & (wrap_x - 12'd1);
                    vy  <= vy0 & (wrap_y - 11'd1);
                    fpx <= '0; v_done <= 1'b0; vst <= V_ATTR;
                    st  <= S_RUN;
                end

                S_RUN: begin
                    // ---- V: tile RAM, attribute then code
                    case (vst)
                        V_ATTR:  begin vram_addr <= vram_base;          vram_req <= 1'b1; vst <= V_ATTRW; end
                        V_ATTRW: if (vram_ack) begin attr_v <= vram_q;  vram_req <= 1'b0; vst <= V_CODE;  end
                        V_CODE:  begin vram_addr <= vram_base | 16'd1;  vram_req <= 1'b1; vst <= V_CODEW; end
                        V_CODEW: if (vram_ack) begin
                            code_v <= vram_q; vram_req <= 1'b0; npx_v <= npx_now; vst <= V_HOLD;
                        end
                        V_HOLD: if (v_to_r) begin
                            fpx <= fpx_next;
                            fvx <= ((fvx | 12'd7) + 12'd1) & (wrap_x - 12'd1);
                            if (fpx_next >= (LB_AW+1)'(VIS_W)) begin v_done <= 1'b1; vst <= V_IDLE; end
                            else vst <= V_ATTR;
                        end
                        default: ;
                    endcase

                    // ---- R: tile ROM row
                    case (rst)
                        R_IDLE: if (v_to_r) begin attr <= attr_v; code <= code_v; npx_r <= npx_v; rst <= R_REQ; end
                        R_REQ: begin
                            flipx_r  <= regs[1][fliprsel] & attr_flip;
                            color_r  <= colorbase[cur_l] | {4'd0, attr_color};
                            rom_addr <= {code, 3'd0} + {16'd0, attr_fy};
                            rom_req  <= 1'b1;
                            rst <= R_WAIT;
                        end
                        R_WAIT: if (rom_ack) begin rowdata_r <= rom_q; rom_req <= 1'b0; rst <= R_HOLD; end
                        R_HOLD: if (r_to_e) rst <= R_IDLE;
                        default: rst <= R_IDLE;
                    endcase

                    // ---- E: the group's pixels into the line buffer
                    if (r_to_e) begin
                        rowdata <= rowdata_r; color <= color_r; flipx <= flipx_r;
                        e_cnt <= npx_r; e_busy <= (npx_r != 4'd0);
                    end else if (e_busy) begin
                        case (cur_l)
                            2'd0: lbuf0[bank][cur_x] <= {|pixel, color, pixel};
                            2'd1: lbuf1[bank][cur_x] <= {|pixel, color, pixel};
                            2'd2: lbuf2[bank][cur_x] <= {|pixel, color, pixel};
                            2'd3: lbuf3[bank][cur_x] <= {|pixel, color, pixel};
                        endcase
                        vx    <= (vx + 12'd1) & (wrap_x - 12'd1);
                        cur_x <= cur_x + 1'd1;
                        e_cnt <= e_cnt - 4'd1;
                        if (e_cnt == 4'd1) e_busy <= 1'b0;
                    end

                    // ---- the layer is done when every stage has drained
                    if (layer_done) begin
                        if (cur_l == 2'd3) begin st <= S_IDLE; busy <= 1'b0; end
                        else begin cur_l <= cur_l + 2'd1; st <= S_SETUP; end
                    end
                end
                default: st <= S_IDLE;
            endcase
        end
    end
endmodule
