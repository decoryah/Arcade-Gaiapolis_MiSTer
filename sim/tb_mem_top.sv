// Bench wrapper for target/mister/gaia_mem.sv: the MiSTer memory subsystem with
// a behavioural SDRAM and Avalon DDR3 behind it, and a stand-in for the
// rotated frame buffer's write traffic. The C++ side loads bytes through the
// download port and reads them back through every core port (sim/tb_mem.cpp).
`default_nettype none
module tb_mem_top #(
    parameter int TEST_SHRINK = 6,
    parameter int DDR_LAT     = 24,
    parameter int DDR_BUSY_PCT = 20
) (
    input  logic        clk,
    input  logic        init,
    input  logic        dl_start,
    output logic        ready,
    input  logic        rot_en,             // the frame buffer's stand-in writes a pixel every 12 clocks
    input  logic        test_start, output logic test_run, test_done,
    output logic  [6:0] test_ok, test_stable, output logic vram_ok, output logic [3:0] vram_bad,
    input  logic        dl_we, input logic [24:0] dl_addr, input logic [7:0] dl_data, output logic dl_wait,
    input  logic        prog_req, input  logic [22:1] prog_addr, output logic prog_ack, output logic [15:0] prog_q,
    input  logic        tile_req, input  logic [18:0] tile_addr, output logic tile_ack, output logic [31:0] tile_q,
    input  logic        map_req,  input  logic [19:0] map_addr,  output logic map_ack,  output logic [15:0] map_q,
    input  logic        blk_req,  input  logic [15:0] blk_addr,  output logic blk_wr,   output logic  [5:0] blk_idx,
    output logic [15:0] blk_data, output logic        blk_ack,
    input  logic        spr_req,  input  logic [19:0] spr_addr,  output logic spr_ack,  output logic [63:0] spr_q,
    input  logic        snd_req,  input  logic [17:0] snd_addr,  output logic snd_ack,  output logic  [7:0] snd_q,
    input  logic        pcm_req,  input  logic [21:0] pcm_addr,  output logic pcm_ack,  output logic  [7:0] pcm_q,
    input  logic        vram_req, input  logic        vram_we,   input  logic [15:0] vram_addr,
    input  logic  [1:0] vram_be,  input  logic [15:0] vram_wdata, output logic vram_ack, output logic [15:0] vram_q,
    output logic        ddr_overflow
);
    wire  [15:0] dram_dq; wire [12:0] dram_a; wire [1:0] dram_ba, dram_dqm;
    wire         dram_clk, dram_cke, dram_ras_n, dram_cas_n, dram_we_n;

    wire         ddr_rd, ddr_we, ddr_busy, ddr_dready;
    wire  [24:0] ddr_addr; wire [7:0] ddr_burst, ddr_be; wire [63:0] ddr_din, ddr_dout;
    logic        rot_we; logic [28:0] rot_addr; logic [63:0] rot_din; logic [7:0] rot_be;
    wire         DDRAM_BUSY, DDRAM_DOUT_READY, DDRAM_RD, DDRAM_WE;
    wire  [7:0]  DDRAM_BURSTCNT, DDRAM_BE;
    wire  [28:0] DDRAM_ADDR;
    wire  [63:0] DDRAM_DIN, DDRAM_DOUT;

    gaia_mem #(.TEST_SHRINK(TEST_SHRINK)) dut (
        .clk(clk), .clk_sdram(clk), .init(init), .dl_start(dl_start), .ready(ready), .rd_late(1'b0), .burst_slow(1'b0),
        .test_start(test_start), .test_run(test_run), .test_done(test_done), .test_ok(test_ok), .test_stable(test_stable),
        .vram_ok(vram_ok), .vram_bad(vram_bad),
        .dl_we(dl_we), .dl_addr(dl_addr), .dl_data(dl_data), .dl_wait(dl_wait),
        .prog_req(prog_req), .prog_addr(prog_addr), .prog_ack(prog_ack), .prog_q(prog_q),
        .tile_req(tile_req), .tile_addr(tile_addr), .tile_ack(tile_ack), .tile_q(tile_q),
        .map_req(map_req), .map_addr(map_addr), .map_ack(map_ack), .map_q(map_q),
        .blk_req(blk_req), .blk_addr(blk_addr), .blk_wr(blk_wr), .blk_idx(blk_idx), .blk_data(blk_data), .blk_ack(blk_ack), .roz_lead(4'd0),
        .spr_req(spr_req), .spr_addr(spr_addr), .spr_ack(spr_ack), .spr_q(spr_q),
        .snd_req(snd_req), .snd_addr(snd_addr), .snd_ack(snd_ack), .snd_q(snd_q),
        .pcm_req(pcm_req), .pcm_addr(pcm_addr), .pcm_ack(pcm_ack), .pcm_q(pcm_q),
        .vram_req(vram_req), .vram_we(vram_we), .vram_addr(vram_addr), .vram_be(vram_be), .vram_wdata(vram_wdata),
        .vram_ack(vram_ack), .vram_q(vram_q),
        .dram_dq(dram_dq), .dram_a(dram_a), .dram_ba(dram_ba), .dram_dqm(dram_dqm),
        .dram_clk(dram_clk), .dram_cke(dram_cke), .dram_ras_n(dram_ras_n), .dram_cas_n(dram_cas_n), .dram_we_n(dram_we_n),
        .ddr_rd(ddr_rd), .ddr_we(ddr_we), .ddr_addr(ddr_addr), .ddr_burst(ddr_burst), .ddr_din(ddr_din), .ddr_be(ddr_be),
        .ddr_busy(ddr_busy), .ddr_dout(ddr_dout), .ddr_dready(ddr_dready)
    );
    sdram_model #(.PHASE_LAG(0), .AW(24)) chip (
        .clk(clk), .dq(dram_dq), .a(dram_a), .ba(dram_ba), .dqml(dram_dqm[0]), .dqmh(dram_dqm[1]),
        .cs_n(1'b0), .ras_n(dram_ras_n), .cas_n(dram_cas_n), .we_n(dram_we_n), .cke(dram_cke)
    );
    ddr_arb u_arb (
        .clk(clk), .reset(init),
        .c_rd(ddr_rd), .c_we(ddr_we), .c_addr(ddr_addr), .c_burst(ddr_burst), .c_din(ddr_din), .c_be(ddr_be),
        .c_busy(ddr_busy), .c_dout(ddr_dout), .c_dready(ddr_dready),
        .r_we(rot_we), .r_addr(rot_addr), .r_din(rot_din), .r_be(rot_be),
        .f_rd(1'b0), .f_addr(25'd0), .f_burst(8'd0), .f_busy(), .f_dready(),
        .DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(DDRAM_BURSTCNT), .DDRAM_ADDR(DDRAM_ADDR),
        .DDRAM_DOUT(DDRAM_DOUT), .DDRAM_DOUT_READY(DDRAM_DOUT_READY),
        .DDRAM_RD(DDRAM_RD), .DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE), .DDRAM_WE(DDRAM_WE),
        .overflow(ddr_overflow)
    );
    ddr_model #(.AW(20), .LAT(DDR_LAT), .BUSY_PCT(DDR_BUSY_PCT)) ddr (
        .clk(clk), .DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(DDRAM_BURSTCNT), .DDRAM_ADDR(DDRAM_ADDR),
        .DDRAM_DOUT(DDRAM_DOUT), .DDRAM_DOUT_READY(DDRAM_DOUT_READY),
        .DDRAM_RD(DDRAM_RD), .DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE), .DDRAM_WE(DDRAM_WE)
    );
    logic [3:0]  rot_div;
    logic [19:0] rot_cnt;
    always_ff @(posedge clk) begin
        rot_we <= 1'b0;
        rot_div <= (rot_div == 4'd11) ? 4'd0 : rot_div + 4'd1;
        if (rot_div == 4'd0 && rot_en) begin
            rot_we <= 1'b1; rot_addr <= {7'b0010010, 2'b01, rot_cnt}; rot_din <= {44'd0, rot_cnt}; rot_be <= 8'h0f;
            rot_cnt <= rot_cnt + 20'd1;
        end
    end
    /* verilator lint_off UNUSEDSIGNAL */
    wire unused = ^{dram_clk};
    /* verilator lint_on UNUSEDSIGNAL */
endmodule
