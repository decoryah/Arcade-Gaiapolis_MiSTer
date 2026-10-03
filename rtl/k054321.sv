//------------------------------------------------------------------------------
// K054321 main/sound CPU latch and volume manager.
//
// Three 8-bit latches: two from the 68000 to the Z80, one back. The volume
// is a counter -- one address resets it, another increments it by one -- and
// `active` gates the left/right outputs. MAME models the gain as
// 2^((volume - 40) / 10) with 40 as "normal"; gaia_core applies it.
// busy_r always reads 0 on the real chip as far as anyone knows.
//
// Main side (byte register at word offset, high byte of the bus):
//   0 active   2 volume reset   3 volume up   4 dummy (0x4a)
//   6 latch0   7 latch1         8 busy        a latch2
// Sound side: 0 latch2 write, 2 latch0 read, 3 latch1 read.
//------------------------------------------------------------------------------
`default_nettype none

module k054321 (
    input  logic       clk,
    input  logic       reset,

    // main CPU side
    input  logic       m_wr,
    input  logic       m_rd,
    input  logic [3:0] m_off,
    input  logic [7:0] m_wdata,
    output logic [7:0] m_rdata,

    // sound CPU side
    input  logic       s_wr,
    input  logic [1:0] s_off,
    input  logic [7:0] s_wdata,
    output logic [7:0] s_rdata,       // combinational on s_off

    // to the audio stage
    output logic [6:0] volume,        // 0..64
    output logic [1:0] active         // bit1 left, bit0 right
);
    logic [7:0] latch0, latch1, latch2;

    always_ff @(posedge clk) begin
        if (reset) begin
            latch0 <= '0; latch1 <= '0; latch2 <= '0;
            volume <= '0; active <= '0;
        end else begin
            if (m_wr) begin
                case (m_off)
                    4'h0: active <= m_wdata[1:0];
                    4'h2: volume <= '0;
                    4'h3: if (m_wdata != 8'd0 && volume < 7'd64) volume <= volume + 7'd1;
                    4'h6: latch0 <= m_wdata;
                    4'h7: latch1 <= m_wdata;
                    default: ;
                endcase
            end
            if (s_wr && s_off == 2'd0) latch2 <= s_wdata;
        end
    end

    always_comb begin
        case (m_off)
            4'h8:    m_rdata = 8'h00;          // busy: never
            4'ha:    m_rdata = latch2;
            default: m_rdata = 8'h00;
        endcase
        case (s_off)
            2'd2:    s_rdata = latch0;
            2'd3:    s_rdata = latch1;
            default: s_rdata = 8'h00;
        endcase
    end
    /* verilator lint_off UNUSEDSIGNAL */
    wire unused_rd = m_rd;                  // reads have no side effects here
    /* verilator lint_on UNUSEDSIGNAL */
endmodule
