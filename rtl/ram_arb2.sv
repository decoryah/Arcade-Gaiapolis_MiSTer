//------------------------------------------------------------------------------
// Two-client arbiter for a request/ack RAM port with byte-enabled writes:
// rom_arb2 with the write side carried through. Client 0 has priority (the
// tilemap renderer, which has a line deadline); client 1 (the CPU's tile RAM
// window) waits. A grant is held until its ack, or until the granted client
// withdraws its request.
//------------------------------------------------------------------------------
`default_nettype none

module ram_arb2 #(parameter int AW = 16, parameter int DW = 16) (
    input  logic          clk,
    input  logic          reset,
    input  logic          c0_req,
    input  logic          c0_we,
    input  logic [AW-1:0] c0_addr,
    input  logic    [1:0] c0_be,
    input  logic [DW-1:0] c0_wdata,
    output logic          c0_ack,
    input  logic          c1_req,
    input  logic          c1_we,
    input  logic [AW-1:0] c1_addr,
    input  logic    [1:0] c1_be,
    input  logic [DW-1:0] c1_wdata,
    output logic          c1_ack,
    output logic          m_req,
    output logic          m_we,
    output logic [AW-1:0] m_addr,
    output logic    [1:0] m_be,
    output logic [DW-1:0] m_wdata,
    input  logic          m_ack
);
    logic busy, sel;                      // sel: 0 = client 0 owns the port
    always_ff @(posedge clk) begin
        if (reset) begin busy <= 1'b0; sel <= 1'b0; end
        else if (!busy) begin
            if (c0_req)      begin busy <= 1'b1; sel <= 1'b0; end
            else if (c1_req) begin busy <= 1'b1; sel <= 1'b1; end
        end else if (m_ack || !(sel ? c1_req : c0_req)) busy <= 1'b0;
    end
    assign m_req   = busy && (sel ? c1_req : c0_req);
    assign m_we    = sel ? c1_we    : c0_we;
    assign m_addr  = sel ? c1_addr  : c0_addr;
    assign m_be    = sel ? c1_be    : c0_be;
    assign m_wdata = sel ? c1_wdata : c0_wdata;
    assign c0_ack  = busy && !sel && m_ack;
    assign c1_ack  = busy &&  sel && m_ack;
endmodule
