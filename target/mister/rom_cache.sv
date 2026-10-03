//------------------------------------------------------------------------------
// A read-only cache for a CPU's program ROM: direct mapped, 8-word (16-byte)
// lines, block RAM. The client side is the core's level request / one-cycle
// ack port; a miss asks the memory for the line with `fill_req` / `fill_addr`
// (the line number, word address >> 3) and the memory streams its eight words
// back on fill_wr / fill_idx / fill_data, then pulses fill_done.
//
// A hit costs two clocks: the tag and the word are read in the clock the
// request is seen, compared in the next, the ack follows. `reset` drops every
// line (a new image is loading) and a sweep rewrites the tags; `ready` rises
// when it is done.
//
// As everywhere in the core, the ack goes only to a request still standing
// with the same address, and the request that is being acked right now (it
// stays up for the clock the ack is visible) is not taken for a new one.
//------------------------------------------------------------------------------
`default_nettype none

module rom_cache #(
    parameter int AW  = 22,             // word-address bits of the client port
    parameter int IDX = 10              // lines: 2^IDX
) (
    input  logic          clk,
    input  logic          reset,
    output logic          ready,

    input  logic          req,
    input  logic [AW-1:0] addr,
    output logic          ack,
    output logic   [15:0] q,

    output logic          fill_req,
    output logic [AW-1:3] fill_addr,
    input  logic          fill_wr,
    input  logic    [2:0] fill_idx,
    input  logic   [15:0] fill_data,
    input  logic          fill_done
);
    localparam int TAGW = AW - 3 - IDX;

    typedef enum logic [2:0] { C_SWEEP, C_IDLE, C_RD, C_CMP, C_FILL } cst_t;
    cst_t st;

    logic [AW-1:0]    addr_l;
    logic [IDX-1:0]   sweep_i;
    logic             tw_en;
    logic [TAGW:0]    tw_d;
    logic [IDX-1:0]   tw_a;

    // read side: the live request's address while idle, the latched one otherwise
    wire [IDX-1:0] r_idx  = (st == C_IDLE) ? addr[IDX+2:3] : addr_l[IDX+2:3];
    wire     [2:0] r_word = (st == C_IDLE) ? addr[2:0]      : addr_l[2:0];

    (* ramstyle = "M10K,no_rw_check" *) logic [15:0]   dmem [1 << (IDX + 3)];
    (* ramstyle = "M10K,no_rw_check" *) logic [TAGW:0] tmem [1 << IDX];
    logic [15:0]   dat_q;
    logic [TAGW:0] tag_q;

    always_ff @(posedge clk) begin
        if (fill_wr) dmem[{addr_l[IDX+2:3], fill_idx}] <= fill_data;
        dat_q <= dmem[{r_idx, r_word}];
    end
    always_ff @(posedge clk) begin
        if (tw_en) tmem[tw_a] <= tw_d;
        tag_q <= tmem[r_idx];
    end

    // the tag write is combinational from the state: it lands at the end of
    // the clock fill_done is seen, so the lookup that follows reads the new tag
    always_comb begin
        tw_en = 1'b0; tw_a = sweep_i; tw_d = '0;
        if (!reset && st == C_SWEEP) tw_en = 1'b1;
        else if (!reset && st == C_FILL && fill_done) begin
            tw_en = 1'b1; tw_a = addr_l[IDX+2:3]; tw_d = {1'b1, addr_l[AW-1:IDX+3]};
        end
    end

    wire hit = tag_q[TAGW] && (tag_q[TAGW-1:0] == addr_l[AW-1:IDX+3]);

    always_ff @(posedge clk) begin
        ack   <= 1'b0;
        if (reset) begin
            st <= C_SWEEP; sweep_i <= '0; ready <= 1'b0; fill_req <= 1'b0;
        end else case (st)
            C_SWEEP: begin
                sweep_i <= sweep_i + 1'b1;
                if (sweep_i == {IDX{1'b1}}) begin st <= C_IDLE; ready <= 1'b1; end
            end
            C_IDLE: if (req && !ack) begin addr_l <= addr; st <= C_CMP; end
            C_RD:   st <= C_CMP;
            C_CMP: begin
                if (hit) begin
                    q <= dat_q;
                    if (req && addr == addr_l) ack <= 1'b1;
                    st <= C_IDLE;
                end else begin
                    fill_req <= 1'b1; fill_addr <= addr_l[AW-1:3]; st <= C_FILL;
                end
            end
            C_FILL: if (fill_done) begin
                fill_req <= 1'b0;
                st <= C_RD;
            end
            default: st <= C_IDLE;
        endcase
    end
endmodule
