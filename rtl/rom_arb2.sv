//------------------------------------------------------------------------------
// Two-client arbiter for a request/ack ROM port. Client 0 has priority (the
// renderer, which has a line deadline); client 1 (the CPU's readback window)
// waits. A grant is held until its ack, or until the granted client
// withdraws its request (a renderer restarting on a new line does that).
//------------------------------------------------------------------------------
`default_nettype none

module rom_arb2 #(parameter int AW = 20, parameter int DW = 16) (
    input  logic          clk,
    input  logic          reset,
    input  logic          c0_req,
    input  logic [AW-1:0] c0_addr,
    output logic          c0_ack,
    input  logic          c1_req,
    input  logic [AW-1:0] c1_addr,
    output logic          c1_ack,
    output logic          m_req,
    output logic [AW-1:0] m_addr,
    input  logic          m_ack,
    input  logic [DW-1:0] m_q,
    output logic [DW-1:0] q
);
    logic busy, sel;                      // sel: 0 = client 0 owns the port
    always_ff @(posedge clk) begin
        if (reset) begin busy <= 1'b0; sel <= 1'b0; end
        else if (!busy) begin
            if (c0_req)      begin busy <= 1'b1; sel <= 1'b0; end
            else if (c1_req) begin busy <= 1'b1; sel <= 1'b1; end
        end else if (m_ack || !(sel ? c1_req : c0_req)) busy <= 1'b0;
    end
    assign m_req  = busy && (sel ? c1_req : c0_req);
    assign m_addr = sel ? c1_addr : c0_addr;
    assign c0_ack = busy && !sel && m_ack;
    assign c1_ack = busy &&  sel && m_ack;
    assign q = m_q;
endmodule
