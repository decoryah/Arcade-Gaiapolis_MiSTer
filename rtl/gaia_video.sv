//------------------------------------------------------------------------------
// Raster timing for Gaiapolis: the K053252's job, at this board's settings.
//
// 8 MHz pixel clock, visible 376 x 224 at origin (40, 16). The cabinet is
// ROT90; the Pocket rotates the output, so this scans the raster natively --
// one raster line per output line. Two sets of totals, chosen by `timing_mame`
// (taken at the start of a frame):
//   board (0): 508 x 263, 15.748 kHz, 59.88 Hz -- what the K053252 produces from
//              the values the game writes to it (H max 0x1FB, V max 0x106, hsync
//              48 pixels, vsync 8 lines) at its 8 MHz pixel clock (the board
//              feeds it 32 MHz and divides by 4). The visible area and the
//              picture's origin are the same; only the blanking around it shrinks.
//   MAME  (1): 512 x 264, 15.625 kHz, 59.1856 Hz -- MAME's fixed driver timing,
//              which ignores the chip's registers (docs/hardware.md section 1).
//
// Each visible line is rendered into the line buffers during the line before
// it: at the start of raster line r this pulses `line_start` for line r+1,
// and the renderers have the full 512-pixel line (6,144 clocks) to finish.
// If any is still busy at the next pulse, `overrun` pulses for that line -- that is the
// budget in docs/hardware.md section 11 being exceeded, and it must never be
// silent.
//
// Scan-out is pipelined by one pixel: the line buffers and mixer need four
// clocks after `px` changes, so the colour presented at a cen_pix tick belongs
// to the previous px, and de/hs/vs are delayed to match.
//------------------------------------------------------------------------------
`default_nettype none

module gaia_video #(
    parameter int HTOTAL = 512,       // MAME timing
    parameter int VTOTAL = 264,
    parameter int HS_START = 448,     // hsync window inside hblank
    parameter int HS_LEN   = 32,
    parameter int VS_START = 248,     // vsync window inside vblank
    parameter int VS_LEN   = 3,
    parameter int HTOTAL_B = 508,     // board timing (the K053252's, from the game's registers)
    parameter int VTOTAL_B = 263,
    parameter int HS_START_B = 444,   // 18 pixels after the chip's hblank start, 48 wide
    parameter int HS_LEN_B   = 48,
    parameter int VS_START_B = 255,   // 15 lines after vblank start, 8 lines (the window cannot wrap the frame)
    parameter int VS_LEN_B   = 8,
    parameter int VIS_W  = 376,
    parameter int VIS_H  = 224,
    parameter int VIS_X0 = 40,
    parameter int VIS_Y0 = 16
) (
    input  logic        clk,
    input  logic        reset,
    input  logic        cen_pix,        // 8 MHz
    input  logic        timing_mame,    // 0: board timing, 1: MAME's (read at the start of each frame)

    // to the renderers
    output logic        line_start,
    output logic  [8:0] render_line,
    output logic        prestart,       // one pulse a few raster lines before the visible area (the ROZ plane pre-renders)
    input  logic  [2:0] renderers_busy, // {tilemap, ROZ, sprites}
    output logic        overrun,
    output logic  [2:0] overrun_src,    // which of them, with the pulse

    // scan-out
    output logic  [8:0] px,             // visible pixel index, valid with px_valid
    output logic        px_valid,
    output logic  [8:0] hcount,
    output logic  [8:0] vcount,

    // timing, one pixel behind px (aligned with the mixer's rgb)
    output logic        hsync,
    output logic        vsync,
    output logic        de,
    output logic        vblank,
    output logic        vblank_rise     // one clk pulse at the start of vblank
);
    logic in_active_x, in_active_y;
    assign in_active_x = (hcount >= 9'(VIS_X0)) && (hcount < 9'(VIS_X0 + VIS_W));
    assign in_active_y = (vcount >= 9'(VIS_Y0)) && (vcount < 9'(VIS_Y0 + VIS_H));

    logic hs_r, vs_r, de_r, vb_r;
    logic vb_prev;

    // the totals in force for this frame
    logic       mame_l;
    wire  [8:0] ht       = mame_l ? 9'(HTOTAL)   : 9'(HTOTAL_B);
    wire  [8:0] vt       = mame_l ? 9'(VTOTAL)   : 9'(VTOTAL_B);
    wire  [8:0] hs_start = mame_l ? 9'(HS_START) : 9'(HS_START_B);
    wire  [8:0] hs_end   = hs_start + (mame_l ? 9'(HS_LEN) : 9'(HS_LEN_B));
    wire  [8:0] vs_start = mame_l ? 9'(VS_START) : 9'(VS_START_B);
    wire  [8:0] vs_end   = vs_start + (mame_l ? 9'(VS_LEN) : 9'(VS_LEN_B));

    always_ff @(posedge clk) begin
        line_start  <= 1'b0;
        prestart    <= 1'b0;
        vblank_rise <= 1'b0;
        if (reset) begin
            mame_l <= timing_mame;
            hcount <= '0; vcount <= '0; overrun <= 1'b0; overrun_src <= '0;
            hsync <= 1'b0; vsync <= 1'b0; de <= 1'b0; vblank <= 1'b1; vb_prev <= 1'b1;
            px <= '0; px_valid <= 1'b0; render_line <= '0;
        end else if (cen_pix) begin
            // raster counters
            if (hcount == ht - 9'd1) begin
                hcount <= '0;
                vcount <= (vcount == vt - 9'd1) ? 9'd0 : vcount + 9'd1;
                if (vcount == vt - 9'd1) mame_l <= timing_mame;     // a new frame: take the option
            end else hcount <= hcount + 9'd1;

            // start rendering the next line as this one begins
            if (hcount == 9'd0) begin
                logic [8:0] nxt;
                nxt = (vcount == vt - 9'd1) ? 9'd0 : vcount + 9'd1;
                // ... including the pulse after the last visible line, so the
                // renderers hand over their last buffer as they do every other
                if (nxt >= 9'(VIS_Y0) && nxt <= 9'(VIS_Y0 + VIS_H)) begin
                    line_start  <= 1'b1;
                    render_line <= nxt;
                    overrun <= |renderers_busy;     // one pulse per overrunning line
                    overrun_src <= renderers_busy;
                end
                if (vcount == 9'(VIS_Y0 - 6)) prestart <= 1'b1;
            end

            // scan-out address for this pixel
            px       <= hcount - 9'(VIS_X0);
            px_valid <= in_active_x && in_active_y;

            // timing outputs, delayed one pixel to line up with rgb
            de_r <= in_active_x && in_active_y;
            hs_r <= (hcount >= hs_start) && (hcount < hs_end);
            vs_r <= (vcount >= vs_start) && (vcount < vs_end);
            vb_r <= !in_active_y;
            de <= de_r; hsync <= hs_r; vsync <= vs_r; vblank <= vb_r;

            vb_prev <= vb_r;
            if (vb_r && !vb_prev) vblank_rise <= 1'b1;
        end
    end
endmodule
