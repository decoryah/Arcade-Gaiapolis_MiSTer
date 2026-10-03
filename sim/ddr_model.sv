// Behavioural Avalon-MM DDR3 slave, as the MiSTer framework presents it
// (DDRAM_*): a command (RD or WE, with address, burst count, data, byte
// enables) is accepted at a clock edge where it is presented and BUSY is low;
// read data comes back DOUT_READY beats at a time, in order, a fixed latency
// after the command and then one beat a clock. BUSY is held high for a
// pseudo-random share of the clocks to exercise the master's hold-until-accepted
// handling. Only the client's window (address bits 28:25 == 3, byte 0x30000000)
// is stored; writes elsewhere (screen_rotate's frame buffer) are counted.
`default_nettype none

module ddr_model #(
    parameter int AW       = 20,        // beats stored: 2^AW
    parameter int LAT      = 24,        // clocks from a read command to its first beat
    parameter int BUSY_PCT = 0,         // % of clocks with BUSY high
    parameter bit FB_STORE = 0          // keep screen_rotate's frame buffer writes (byte 0x24000000.., 3 x 8 MB)
) (
    input  logic        clk,
    output logic        DDRAM_BUSY,
    input  logic  [7:0] DDRAM_BURSTCNT,
    input  logic [28:0] DDRAM_ADDR,
    output logic [63:0] DDRAM_DOUT,
    output logic        DDRAM_DOUT_READY,
    input  logic        DDRAM_RD,
    input  logic [63:0] DDRAM_DIN,
    input  logic  [7:0] DDRAM_BE,
    input  logic        DDRAM_WE
);
    logic [63:0] mem [0:(1<<AW)-1] /*verilator public_flat_rw*/;
    logic [63:0] fb [0:(FB_STORE ? (1<<22) : 1)-1] /*verilator public_flat_rw*/;
    integer      rot_writes /*verilator public_flat_rw*/;
    integer      rd_cmds    /*verilator public_flat_rw*/;
    integer      wr_cmds    /*verilator public_flat_rw*/;
    integer      protocol_errors /*verilator public_flat_rw*/;

    // read data in flight: a ring of {ready_time, data}
    logic [63:0] rq_data [0:255];
    longint      rq_time [0:255];
    int          rq_head, rq_tail;
    longint      now, last_ready;
    logic [31:0] lfsr;

    // BUSY: from the pseudo-random stream, decided a clock ahead so the DUT sees a plain registered signal
    always_ff @(posedge clk) begin
        lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
        DDRAM_BUSY <= (BUSY_PCT != 0) && ((lfsr[15:8] % 100) < BUSY_PCT);
    end

    // a command presented and then changed before being accepted breaks the Avalon rule
    logic        pend_cmd, pend_rd, pend_we;
    logic [28:0] pend_addr;
    logic  [7:0] pend_bc;

    initial begin
        rot_writes = 0; rd_cmds = 0; wr_cmds = 0; protocol_errors = 0;
        rq_head = 0; rq_tail = 0; now = 0; last_ready = 0; lfsr = 32'hACE1_2345; pend_cmd = 0;
        DDRAM_BUSY = 0;
    end

    wire cmd = DDRAM_RD | DDRAM_WE;

    always_ff @(posedge clk) begin
        now <= now + 1;
        DDRAM_DOUT_READY <= 1'b0;

        // hold-until-accepted
        if (pend_cmd && cmd && (DDRAM_RD != pend_rd || DDRAM_WE != pend_we || DDRAM_ADDR != pend_addr || (DDRAM_RD && DDRAM_BURSTCNT != pend_bc))) begin
            $display("DDR-PROTOCOL-ERROR: command changed while BUSY");
            protocol_errors++;
        end
        if (pend_cmd && !cmd) begin
            $display("DDR-PROTOCOL-ERROR: command withdrawn while BUSY");
            protocol_errors++;
        end
        pend_cmd <= cmd && DDRAM_BUSY;
        pend_rd <= DDRAM_RD; pend_we <= DDRAM_WE; pend_addr <= DDRAM_ADDR; pend_bc <= DDRAM_BURSTCNT;

        if (cmd && DDRAM_RD && DDRAM_WE) begin $display("DDR-PROTOCOL-ERROR: RD and WE together"); protocol_errors++; end

        if (cmd && !DDRAM_BUSY) begin
            if (DDRAM_WE) begin
                wr_cmds++;
                if (DDRAM_ADDR[28:25] == 4'd3) begin
                    for (int b = 0; b < 8; b++)
                        if (DDRAM_BE[b]) mem[DDRAM_ADDR[AW-1:0]][8*b +: 8] <= DDRAM_DIN[8*b +: 8];
                end else begin
                    rot_writes++;
                    if (FB_STORE && DDRAM_ADDR[28:22] == 7'b0010010)
                        for (int b = 0; b < 8; b++)
                            if (DDRAM_BE[b]) fb[DDRAM_ADDR[21:0]][8*b +: 8] <= DDRAM_DIN[8*b +: 8];
                end
            end else if (DDRAM_RD) begin
                rd_cmds++;
                for (int i = 0; i < int'(DDRAM_BURSTCNT); i++) begin
                    longint t;
                    t = now + LAT + i;
                    if (t <= last_ready) t = last_ready + 1;
                    last_ready = t;
                    rq_data[rq_tail] <= mem[DDRAM_ADDR[AW-1:0] + AW'(i)];
                    rq_time[rq_tail] = t;
                    rq_tail = (rq_tail + 1) & 255;
                end
            end
        end

        // deliver the next beat when its time has come
        if (rq_head != rq_tail && rq_time[rq_head] <= now) begin
            DDRAM_DOUT <= rq_data[rq_head];
            DDRAM_DOUT_READY <= 1'b1;
            rq_head = (rq_head + 1) & 255;
        end
    end
endmodule
