//------------------------------------------------------------------------------
// K054000 hitbox / collision chip, as MAME's k054000.cpp (the mapped-register
// path gaiapolis uses) models it.
//
// Two boxes A and B, each a 24-bit centre per axis and an 8-bit half-extent;
// A's centres carry a fourth, signed delta byte. Status is 1 when the boxes
// do NOT overlap on either axis: MAME checks the difference's magnitude
// against +511/-1024 and then its low 9 bits against the summed extents,
// which is an odd pair of tests but is what the game was written against.
//
// Byte registers at word offsets (gaia_main passes A[5:1]):
//   01-04 Acx raw   06 Aax   07 Aay   09-0c Acy raw
//   0e Bax   0f Bay   11-13 Bcy raw   15-17 Bcx raw   18 status (read)
//------------------------------------------------------------------------------
`default_nettype none

module k054000 (
    input  logic       clk,
    input  logic       reset,
    input  logic       wr,
    input  logic [4:0] off,
    input  logic [7:0] wdata,
    output logic [7:0] rdata          // combinational on off, the result a cycle behind the registers
);
    logic [7:0] acx [4], acy [4], bcx [3], bcy [3];
    logic [7:0] aax, aay, bax, bay;

    always_ff @(posedge clk) begin
        if (reset) begin
            for (int i = 0; i < 4; i++) begin acx[i] <= '0; acy[i] <= '0; end
            for (int i = 0; i < 3; i++) begin bcx[i] <= '0; bcy[i] <= '0; end
            aax <= 8'd1; aay <= 8'd1; bax <= 8'd1; bay <= 8'd1;
        end else if (wr) begin
            case (off)
                5'h01, 5'h02, 5'h03, 5'h04: acx[2'(off - 5'h01)] <= wdata;
                5'h06: aax <= wdata;
                5'h07: aay <= wdata;
                5'h09, 5'h0a, 5'h0b, 5'h0c: acy[2'(off - 5'h09)] <= wdata;
                5'h0e: bax <= wdata;
                5'h0f: bay <= wdata;
                5'h11, 5'h12, 5'h13: bcy[2'(off - 5'h11)] <= wdata;
                5'h15, 5'h16, 5'h17: bcx[2'(off - 5'h15)] <= wdata;
                default: ;
            endcase
        end
    end

    // convert_raw_to_result_delta: 24-bit value plus a signed byte
    function automatic logic signed [31:0] with_delta(input logic [7:0] b [4]);
        logic signed [31:0] v;
        v = $signed({8'd0, b[0], b[1], b[2]});
        // res -= (0x100 - buf[3]) when the delta's sign bit is set
        return b[3][7] ? (v - $signed(32'd256 - {24'd0, b[3]}))
                       : (v + $signed({24'd0, b[3]}));
    endfunction
    function automatic logic signed [31:0] plain(input logic [7:0] b [3]);
        return $signed({8'd0, b[0], b[1], b[2]});
    endfunction

    // axis_check: the boxes are apart if the centre difference is far, or if
    // its low nine bits exceed the summed extents
    function automatic logic apart(input logic signed [31:0] sub, input logic [8:0] sum9);
        /* verilator lint_off UNUSEDSIGNAL */
        logic signed [31:0] mag;             // only mag[8:0] takes part in the test
        /* verilator lint_on UNUSEDSIGNAL */
        mag = sub[31] ? -sub : sub;          // abs(); only its low 9 bits matter
        return (sub > 32'sd511) || (sub <= -32'sd1024) || (mag[8:0] > sum9);
    endfunction

    // two registered steps -- the centre differences and summed extents, then
    // the compares -- since the whole chain was a -3.8 ns path into the CPU's
    // data register, and a read comes a bus cycle after the coordinate writes
    logic signed [31:0] sub_x, sub_y;
    logic         [8:0] sum_x, sum_y;
    logic status;
    always_ff @(posedge clk) begin
        sub_x <= with_delta(acx) - plain(bcx);
        sub_y <= with_delta(acy) - plain(bcy);
        sum_x <= 9'({1'b0, aax} + {1'b0, bax});
        sum_y <= 9'({1'b0, aay} + {1'b0, bay});
        status <= apart(sub_x, sum_x) | apart(sub_y, sum_y);
    end

    assign rdata = (off == 5'h18) ? {7'd0, status} : 8'h00;
endmodule
