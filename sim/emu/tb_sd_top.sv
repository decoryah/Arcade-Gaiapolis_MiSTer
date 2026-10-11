// The raster of this core (rtl/gaia_video.sv, as the machine drives it: one pixel every 12 clocks) into the
// framework's arcade_video, with Scandoubler Fx / forced_scandoubler selectable, and nothing else: a fast way
// to see what the scandoubled output (31 kHz) does.
`default_nettype none
module tb_sd_top #(parameter bit HONLY = 1) (
    input  wire        clk,
    input  wire        reset,
    input  wire  [2:0] fx,
    input  wire        fsd,
    input  wire        timing_mame,
    output wire        CE_PIXEL,
    output wire  [7:0] VGA_R, VGA_G, VGA_B,
    output wire        VGA_HS, VGA_VS, VGA_DE
);
    reg [3:0] div = 4'd0;
    always @(posedge clk) div <= (div == 4'd11) ? 4'd0 : div + 4'd1;
    wire cen = (div == 4'd0);

    wire        hsync, vsync, de, hde, vblank;
    wire  [8:0] px, hcount, vcount;
    gaia_video v (
        .clk(clk), .reset(reset), .cen_pix(cen), .timing_mame(timing_mame),
        .line_start(), .render_line(), .prestart(), .renderers_busy(3'd0), .overrun(), .overrun_src(),
        .px(px), .px_valid(), .hcount(hcount), .vcount(vcount),
        .hsync(hsync), .vsync(vsync), .de(de), .hde(hde), .vblank(vblank), .vblank_rise()
    );
    // a picture that shows where it is: red = pixel index, green = line, blue fixed
    wire [23:0] rgb = de ? {px[7:0], vcount[7:0], 8'h80} : 24'd0;

    wire [21:0] gamma_bus;
    assign gamma_bus[20:0] = {clk, 20'd0};
    wire [1:0] sl;
    arcade_video #(.WIDTH(376), .DW(24), .GAMMA(1)) av (
        .clk_video(clk), .ce_pix(cen), .RGB_in(rgb),
        .HBlank((HONLY ? ~hde : ~de)), .VBlank(vblank), .HSync(hsync), .VSync(vsync),
        .CLK_VIDEO(), .CE_PIXEL(CE_PIXEL), .VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B),
        .VGA_HS(VGA_HS), .VGA_VS(VGA_VS), .VGA_DE(VGA_DE), .VGA_SL(sl),
        .fx(fx), .forced_scandoubler(fsd), .gamma_bus(gamma_bus)
    );
endmodule
