// Behavioural SDR SDRAM (MT48LC32M16-ish, 4 banks) for simulation.
// Derived from the Punch-Out!! core's model; extended with four independent
// banks and reads without auto-precharge (open-row bursts). CL2 only.
//
// PHASE_LAG 1 models the chip clocked in phase with the controller (its edge
// just after ours): a command registered at edge N is sampled by the chip at
// N+1, and CL2 read data is on the bus during [N+3, N+4), so the controller's
// sample at N+4 is the good one.
`default_nettype none

module sdram_model #(parameter PHASE_LAG = 1, parameter AW = 22) (
    input  logic        clk,
    inout  wire  [15:0] dq,
    input  logic [12:0] a,
    input  logic [1:0]  ba,
    input  logic        dqml, dqmh,
    input  logic        cs_n, ras_n, cas_n, we_n,
    input  logic        cke
);
    logic [15:0] mem [0:(1<<AW)-1] /*verilator public_flat_rw*/;

    logic [12:0] row_open [0:3];
    logic        row_active [0:3];
    logic [15:0] pipe_q1, pipe_q2;
    logic        pipe_v1, pipe_v2;
    integer      errors /*verilator public_flat_rw*/;

    wire [3:0] cmd = {cs_n, ras_n, cas_n, we_n};
    localparam CMD_ACT = 4'b0011, CMD_READ = 4'b0101, CMD_WRIT = 4'b0100,
               CMD_PRE = 4'b0010;

    logic [15:0] dq_out;
    logic        dq_oe;
    assign dq = dq_oe ? dq_out : 16'hzzzz;

    // word index = {bank, row, col}: matches sdram_ctrl's a[24:23], a[22:10], a[9:1]
    wire [24:0] widx_full = {ba, row_open[ba], a[8:0]};
    wire [AW-1:0] widx = widx_full[AW-1:0];

    initial begin
        errors = 0;
        for (int i = 0; i < 4; i++) begin row_active[i] = 1'b0; row_open[i] = '0; end
    end

    always_ff @(posedge clk) begin
        pipe_q2 <= pipe_q1;
        pipe_v2 <= pipe_v1;
        dq_out  <= PHASE_LAG ? pipe_q2 : pipe_q1;
        dq_oe   <= PHASE_LAG ? pipe_v2 : pipe_v1;
        pipe_v1 <= 1'b0;

        case (cmd)
            CMD_ACT: begin
                if (row_active[ba]) begin
                    $display("SDRAM-PROTOCOL-ERROR: ACTIVATE bank %0d row %0d while row %0d open", ba, a, row_open[ba]);
                    errors++;
                end
                row_open[ba]   <= a;
                row_active[ba] <= 1'b1;
            end
            CMD_READ: begin
                if (!row_active[ba]) begin $display("SDRAM-PROTOCOL-ERROR: READ with no open row"); errors++; end
                pipe_q1 <= mem[widx];
                pipe_v1 <= 1'b1;
                if (a[10]) row_active[ba] <= 1'b0;
            end
            CMD_WRIT: begin
                if (!row_active[ba]) begin $display("SDRAM-PROTOCOL-ERROR: WRITE with no open row"); errors++; end
                if (!dqml) mem[widx][7:0]  <= dq[7:0];
                if (!dqmh) mem[widx][15:8] <= dq[15:8];
                if (a[10]) row_active[ba] <= 1'b0;
            end
            CMD_PRE: begin
                if (a[10]) for (int i = 0; i < 4; i++) row_active[i] <= 1'b0;
                else row_active[ba] <= 1'b0;
            end
            default: ;
        endcase
    end
endmodule
