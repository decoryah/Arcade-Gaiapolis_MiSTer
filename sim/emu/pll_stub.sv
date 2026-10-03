// Bench stand-in for the Altera PLL wrapper: both outputs are the reference clock (the
// bench is single-clock), locked after a few clocks.
`default_nettype none
module pll (
    input  wire refclk,
    input  wire rst,
    output wire outclk_0,
    output wire outclk_1,
    output reg  locked
);
    assign outclk_0 = refclk;
    assign outclk_1 = refclk;
    reg [4:0] n = 5'd0;
    always @(posedge refclk) begin
        if (rst) begin n <= 5'd0; locked <= 1'b0; end
        else if (n != 5'd31) n <= n + 5'd1;
        else locked <= 1'b1;
    end
endmodule
