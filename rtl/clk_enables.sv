//------------------------------------------------------------------------------
// Clock enables from the 96 MHz system clock (docs/rtl-conventions.md).
//   cen_16m : 96 / 6   68000
//   cen_8m  : 96 / 12  Z80, and the pixel clock (512 clocks per 64 us line)
//   cen_48k : 96 / 2000 K054539 sample rate (18.432 MHz / 384)
//
// pix_sync pins the pixel phase to the platform's 8 MHz video clock: a pulse
// in the clock after that clock's edge is seen (core_top's synchroniser)
// restarts the divider so cen_8m falls one clock before the next such edge
// and the colour stage (k055555_mixer, phase 9) lands two clocks before the
// video clock samples it. Tied low, the divider free-runs (the benches).
//------------------------------------------------------------------------------
`default_nettype none

module clk_enables (
    input  logic clk,
    input  logic reset,
    input  logic pix_sync,
    output logic cen_16m,
    output logic cen_8m,
    output logic cen_48k
);
    logic [3:0] div;
    logic [10:0] sdiv;
    always_ff @(posedge clk) begin
        if (reset) begin div <= '0; sdiv <= '0; cen_16m <= 1'b0; cen_8m <= 1'b0; cen_48k <= 1'b0; end
        else begin
            sdiv    <= (sdiv == 11'd1999) ? 11'd0 : sdiv + 11'd1;
            cen_48k <= (sdiv == 11'd1999);
            div     <= pix_sync ? 4'd3 : (div == 4'd11) ? 4'd0 : div + 4'd1;
            cen_16m <= (div == 4'd11) || (div == 4'd5);
            cen_8m  <= (div == 4'd11);
        end
    end
endmodule
