//------------------------------------------------------------------------------
// K055555 priority encoder + K054338 colour stage for Gaiapolis.
//
// Built the way the silicon works -- every input compared per pixel -- rather
// than as MAME's sort-and-paint. tools/mixer_experiment.py shows the two agree
// on every frozen-state frame, shadows included, under these rules:
//
//   * the visible pixel is the enabled, opaque input with the smallest
//     priority; among equal layer priorities the lower layer index wins
//     (A over B over C over D over SUB1), and a sprite loses a tie to a layer
//     -- both derived from konamigx_mixer's sort order and checked by brute
//     force over 40,186 random priority sets;
//   * a shadow marked on the sprite line buffer darkens the visible pixel
//     unless a layer won with priority <= the shadow's, i.e. was painted after
//     it. When the sprite itself wins, the flag alone is proof the shadow was
//     painted after the solid pixel.
//
// Not modelled, because nothing in the corpus exercises it: per-layer alpha
// (V_INMIX / OS_INMIX are 0 in every frame) and brightness (V_BRI only ever
// selects the 0xff level). See docs/hardware.md section 11.
//
// Timing: the inputs change once per pixel, at the clock after cen_pix; the
// palette address latches at phase 5 of the 12-clock pixel and the colour at
// phase 9, so each stage has three or more clocks to settle (the encoder
// alone was a 17 ns path) and the registers only ever hold a settled value.
// gaia_video presents the colour at the next cen_pix.
//------------------------------------------------------------------------------
`default_nettype none

module k055555_mixer (
    input  logic        clk,
    input  logic        reset,
    input  logic        cen_pix,        // the pixel tick the phases count from

    // per-pixel inputs, all valid together
    input  logic [11:0] tm_pen [4],
    input  logic  [3:0] tm_opq,
    input  logic [11:0] roz_pen,
    input  logic        roz_opq,
    input  logic        spr_opq,
    input  logic [11:0] spr_pen,
    input  logic  [7:0] spr_pri,
    input  logic        spr_shadow,
    input  logic  [1:0] spr_shtab,
    input  logic  [7:0] spr_shpri,

    // chip registers
    input  logic  [7:0] k55regs [48],
    input  logic [15:0] k38regs [16],
    input  logic        roz_enable,

    // palette: 2048 x xRGB888, registered read
    output logic [10:0] pal_addr,
    input  logic [23:0] pal_q,

    output logic [23:0] rgb
);
    // K055555 register map (k055555.h). SUB2/SUB3 enables are not wired on
    // this board; pens are 11-bit into the 2048-entry palette; shadow deltas
    // occupy the low 9 bits of their registers.
    /* verilator lint_off UNUSEDSIGNAL */
    wire [7:0] enables = k55regs[45];
    wire [7:0] pri_lyr [5];
    assign pri_lyr[0] = k55regs[7];      // A
    assign pri_lyr[1] = k55regs[10];     // B
    assign pri_lyr[2] = k55regs[13];     // C
    assign pri_lyr[3] = k55regs[14];     // D
    assign pri_lyr[4] = k55regs[16];     // SUB1

    wire [4:0] lyr_opq = {roz_opq & roz_enable & enables[5], tm_opq & enables[3:0]};
    wire [11:0] lyr_pen [5];
    assign lyr_pen[0] = tm_pen[0];
    assign lyr_pen[1] = tm_pen[1];
    assign lyr_pen[2] = tm_pen[2];
    assign lyr_pen[3] = tm_pen[3];
    assign lyr_pen[4] = roz_pen;

    // ------------------------------------------------------ stage 0: select
    logic        have_lyr;
    logic  [7:0] best_pri;
    logic [11:0] best_pen;
    /* verilator lint_on UNUSEDSIGNAL */
    logic        win_spr, win_any, darken;
    always_comb begin
        have_lyr = 1'b0; best_pri = 8'hff; best_pen = '0;
        // strict less-than in index order: the lowest index keeps a tie
        for (int l = 0; l < 5; l++) begin
            if (lyr_opq[l] && (!have_lyr || pri_lyr[l] < best_pri)) begin
                have_lyr = 1'b1; best_pri = pri_lyr[l]; best_pen = lyr_pen[l];
            end
        end
        // a sprite only beats a layer outright, never on a tie
        win_spr = spr_opq & enables[4] & (!have_lyr || (spr_pri < best_pri));
        win_any = have_lyr | win_spr;
        if (win_spr) best_pen = spr_pen;
        // shadow painted after the winner?  layer winner: only if its priority
        // is strictly above the shadow's.  sprite winner or nothing: always.
        darken = spr_shadow & enables[4]
               & !(have_lyr & !win_spr & (spr_shpri >= best_pri));
    end

    // the phase inside the pixel: 0 is the cen_pix clock, 1 the clock the
    // new px is seen, 2 the first with the line-buffer reads for it
    logic [3:0] phase;
    always_ff @(posedge clk) phase <= cen_pix ? 4'd0 : (phase == 4'd15 ? 4'd15 : phase + 4'd1);
    wire cen_mix = (phase == 4'd5);
    wire cen_rgb = (phase == 4'd9);

    // ------------------------------------------- stage 1: palette address
    logic        s1_any, s1_darken, s2_any, s2_darken;
    logic  [1:0] s1_tab, s2_tab;
    always_ff @(posedge clk) begin
        if (cen_mix) begin
            pal_addr  <= best_pen[10:0];
            s1_any    <= win_any;  s1_darken <= darken;  s1_tab <= spr_shtab;
        end
        s2_any    <= s1_any;   s2_darken <= s1_darken; s2_tab <= s1_tab;
    end

    // ---------------------------------------------- stage 3: shadow / bg
    wire [23:0] backdrop = {k38regs[0][7:0], k38regs[1]};
    wire        noclip   = k38regs[15][5];

    /* verilator lint_off UNUSEDSIGNAL */
    function automatic logic signed [9:0] shd_delta(input logic [15:0] r);
        // 9-bit two's complement in the register's low bits
        return r[8] ? $signed({1'b1, r[8:0]}) : $signed({1'b0, r[8:0]});
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */
    logic signed [9:0] dr, dg, db;
    always_comb begin
        case (s2_tab)
            2'd3: begin dr = -10'sd80; dg = -10'sd80; db = -10'sd80; end
            default: begin
                dr = shd_delta(k38regs[2 + {2'd0, s2_tab} * 3]);
                dg = shd_delta(k38regs[3 + {2'd0, s2_tab} * 3]);
                db = shd_delta(k38regs[4 + {2'd0, s2_tab} * 3]);
            end
        endcase
    end

    function automatic logic [7:0] pal5(input logic [4:0] v);
        return {v, v[4:2]};
    endfunction
    function automatic logic [7:0] clampd(input logic signed [9:0] v, input logic nc);
        if (nc) return v[7:0];
        return (v < 0) ? 8'd0 : (v > 10'sd255 ? 8'd255 : v[7:0]);
    endfunction

    wire [23:0] base = s2_any ? pal_q : backdrop;
    wire signed [9:0] r5 = $signed({2'd0, pal5(base[23:19])}) + dr;
    wire signed [9:0] g5 = $signed({2'd0, pal5(base[15:11])}) + dg;
    wire signed [9:0] b5 = $signed({2'd0, pal5(base[7:3])})   + db;

    always_ff @(posedge clk) begin
        if (reset) rgb <= '0;
        else if (cen_rgb) rgb <= s2_darken ? {clampd(r5, noclip), clampd(g5, noclip), clampd(b5, noclip)}
                                           : base;
    end
endmodule
