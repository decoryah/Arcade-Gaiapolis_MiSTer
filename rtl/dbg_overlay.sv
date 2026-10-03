//------------------------------------------------------------------------------
// Diagnostic overlay (METHODOLOGY section 4): when enabled, the bottom 12
// visible lines show three rows of 32 squares (11 px wide so all 32 fit a
// 376-px line, 4 px tall). Bit set = green, clear = dark grey, so a hang can
// be read off the panel without a debugger. The rows' meaning is the
// platform's (target/pocket/core_top.sv).
//------------------------------------------------------------------------------
`default_nettype none

module dbg_overlay (
    input  logic        clk,
    input  logic        cen_pix,
    input  logic        enable,
    input  logic        de, vsync,
    input  logic [7:0]  r_in, g_in, b_in,
    input  logic [95:0] status,        // [95:64] row 0, [63:32] row 1, [31:0] row 2 (bit 31 leftmost)
    output logic [7:0]  r_out, g_out, b_out
);
    logic [3:0] sq;                   // pixel within the square, 0..10
    logic [5:0] col;                  // square within the line
    logic [8:0] y;
    logic       de_d, vs_d;
    logic [8:0] height;               // visible lines counted in the previous frame

    always_ff @(posedge clk) begin
        if (cen_pix) begin
            de_d <= de; vs_d <= vsync;
            if (vsync && !vs_d) begin height <= y; y <= 9'd0; end
            else if (de && !de_d) begin sq <= 4'd0; col <= 6'd0; end
            else if (de) begin
                if (sq == 4'd10) begin sq <= 4'd0; col <= col + 6'd1; end else sq <= sq + 4'd1;
            end
            if (!de && de_d) y <= y + 9'd1;            // end of a visible line
        end
    end

    wire [8:0]  y_from_bottom = height - y;             // 1 = last visible line
    wire        in_band = enable && de && (y_from_bottom <= 9'd12) && (y_from_bottom >= 9'd1);
    wire [1:0]  row  = (y_from_bottom > 9'd8) ? 2'd0 : (y_from_bottom > 9'd4) ? 2'd1 : 2'd2;
    wire [31:0] word = (row == 2'd0) ? status[95:64] : (row == 2'd1) ? status[63:32] : status[31:0];
    wire        bitv = word[5'd31 - col[4:0]];
    wire        gap  = (sq == 4'd10) || (y_from_bottom == 9'd12) || (y_from_bottom == 9'd8) || (y_from_bottom == 9'd4);

    always_comb begin
        if (in_band && col < 6'd32) begin
            if (gap)      {r_out, g_out, b_out} = 24'h000000;
            else if (bitv){r_out, g_out, b_out} = 24'h20e020;
            else          {r_out, g_out, b_out} = 24'h303030;
        end else begin
            {r_out, g_out, b_out} = {r_in, g_in, b_in};
        end
    end
endmodule
