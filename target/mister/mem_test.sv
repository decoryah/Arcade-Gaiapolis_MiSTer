`default_nettype none
//------------------------------------------------------------------------------
// The built-in memory test. Every byte of the image is summed per region as
// it streams in; on `start` (the core held in reset) each region is read
// back through the core's own port and summed again -- twice -- so a region
// reports "ok" (read back what was loaded) and "stable" (the two passes
// agreed), which separates a wrong write from a marginal read. The tile RAM
// is then written with a pattern, read back counting bad words, and
// cleared. About 2.5 s at 96 MHz; the results sit on the diagnostic overlay.
//------------------------------------------------------------------------------
module mem_test #(
    parameter int SHRINK = 0
) (
    input  logic        clk,
    input  logic        init,
    input  logic        ready,
    input  logic        start,
    output logic        run, done,
    output logic  [6:0] ok, stable,
    output logic        vram_ok,
    output logic  [3:0] vram_bad,       // bad words on a log scale: 0 none, n = 2^(n-1) .. 2^n - 1, 15 = 16384 or more
    input  logic        dl_we, input logic [24:0] dl_addr, input logic [7:0] dl_data,
    output logic        prog_req, output logic [22:1] prog_addr, input logic prog_ack, input logic [15:0] prog_q,
    output logic        snd_req,  output logic [17:0] snd_addr,  input logic snd_ack,  input logic  [7:0] snd_q,
    output logic        tile_req, output logic [18:0] tile_addr, input logic tile_ack, input logic [31:0] tile_q,
    output logic        blk_req,  output logic [15:0] blk_addr,  input logic blk_wr,   input logic [15:0] blk_data, input logic blk_ack,
    output logic        map_req,  output logic [19:0] map_addr,  input logic map_ack,  input logic [15:0] map_q,
    output logic        pcm_req,  output logic [21:0] pcm_addr,  input logic pcm_ack,  input logic  [7:0] pcm_q,
    output logic        spr_req,  output logic [19:0] spr_addr,  input logic spr_ack,  input logic [63:0] spr_q,
    output logic        vram_req, output logic vram_we, output logic [15:0] vram_addr, output logic [15:0] vram_wdata,
    input  logic        vram_ack, input logic [15:0] vram_q
);
    localparam [24:0] IMG_SND  = 25'h0300000, IMG_TILE = 25'h0340000;
    localparam [24:0] IMG_CHR  = 25'h0540000, IMG_MAP  = 25'h06C0000, IMG_PCM  = 25'h0760000;
    localparam [24:0] IMG_SPR  = 25'h0B60000, IMG_EEP  = 25'h1360000;
    // accesses per region, in each port's unit
    localparam [22:0] N_PROG = 23'h180000, N_SND = 23'h040000, N_TILE = 23'h080000, N_CHR = 23'h003000;   // chr: 64-word tiles
    localparam [22:0] N_MAP  = 23'h050000, N_PCM = 23'h400000, N_SPR  = 23'h100000;

    // the sums as the image arrives (a new image restarts them), in three
    // stages -- the byte, its region as a one-hot, the add -- since bytes
    // come at least eight clocks apart and the region compares plus the
    // add missed 96 MHz as one path from the loader's registers
    logic [23:0] lsum [7];
    logic        b1_we, b1_first, b2_we, b2_first;
    logic [24:0] b1_addr;
    logic  [7:0] b1_data, b2_data;
    logic  [6:0] b2_sel;
    always_ff @(posedge clk) begin
        b1_we <= dl_we; b1_addr <= dl_addr; b1_data <= dl_data;
        b1_first <= dl_we && (dl_addr == 25'd0);
        b2_we <= b1_we; b2_data <= b1_data; b2_first <= b1_first;
        b2_sel[0] <= (b1_addr < IMG_SND);
        b2_sel[1] <= (b1_addr >= IMG_SND)  && (b1_addr < IMG_TILE);
        b2_sel[2] <= (b1_addr >= IMG_TILE) && (b1_addr < IMG_CHR);
        b2_sel[3] <= (b1_addr >= IMG_CHR)  && (b1_addr < IMG_MAP);
        b2_sel[4] <= (b1_addr >= IMG_MAP)  && (b1_addr < IMG_PCM);
        b2_sel[5] <= (b1_addr >= IMG_PCM)  && (b1_addr < IMG_SPR);
        b2_sel[6] <= (b1_addr >= IMG_SPR)  && (b1_addr < IMG_EEP);
        for (int i = 0; i < 7; i++) begin
            if (init || b2_first) lsum[i] <= (i == 0 && b2_first) ? 24'(b2_data) : '0;
            else if (b2_we && b2_sel[i]) lsum[i] <= lsum[i] + 24'(b2_data);
        end
    end

    // the read-back
    typedef enum logic [3:0] { T_IDLE, T_REQ, T_SUM, T_NEXT, T_VW, T_VR, T_VZ, T_DONE } tst_t;
    tst_t        st;
    logic  [2:0] region;
    logic        pass;
    logic [22:0] idx, n_end;
    logic [23:0] acc;
    logic [23:0] asum [7];              // the first pass's sums
    logic        start_d;
    logic [16:0] vbad;                  // bad tile RAM words, counted in full
    logic [10:0] bytes;                 // the bytes of one access, summed
    logic [10:0] bytes_r;               // ... taken into a register, added the clock after (an eight-byte
    logic        add_pend;              //     sum and the 24-bit add in one clock missed 96 MHz)
    logic        ack;
    always_comb begin
        case (region)
            3'd0: begin ack = prog_ack; bytes = 11'(prog_q[15:8]) + 11'(prog_q[7:0]); n_end = N_PROG >> SHRINK; end
            3'd1: begin ack = snd_ack;  bytes = 11'(snd_q); n_end = N_SND >> SHRINK; end
            3'd2: begin ack = tile_ack; bytes = 11'(tile_q[31:24]) + 11'(tile_q[23:16]) + 11'(tile_q[15:8]) + 11'(tile_q[7:0]); n_end = N_TILE >> SHRINK; end
            3'd3: begin ack = blk_ack;  bytes = 11'd0; n_end = N_CHR >> SHRINK; end   // summed per streamed word below
            3'd4: begin ack = map_ack;  bytes = 11'(map_q[15:8]) + 11'(map_q[7:0]); n_end = N_MAP >> SHRINK; end
            3'd5: begin ack = pcm_ack;  bytes = 11'(pcm_q); n_end = N_PCM >> SHRINK; end
            default: begin ack = spr_ack;
                bytes = 11'(spr_q[63:56]) + 11'(spr_q[55:48]) + 11'(spr_q[47:40]) + 11'(spr_q[39:32])
                      + 11'(spr_q[31:24]) + 11'(spr_q[23:16]) + 11'(spr_q[15:8]) + 11'(spr_q[7:0]);
                n_end = N_SPR >> SHRINK; end
        endcase
    end
    assign prog_req = run && st == T_REQ && region == 3'd0;  assign prog_addr = idx[21:0];
    assign snd_req  = run && st == T_REQ && region == 3'd1;  assign snd_addr  = idx[17:0];
    assign tile_req = run && st == T_REQ && region == 3'd2;  assign tile_addr = idx[18:0];
    assign blk_req  = run && st == T_REQ && region == 3'd3;  assign blk_addr  = idx[15:0];
    assign map_req  = run && st == T_REQ && region == 3'd4;  assign map_addr  = {idx[18:0], 1'b0};
    assign pcm_req  = run && st == T_REQ && region == 3'd5;  assign pcm_addr  = idx[21:0];
    assign spr_req  = run && st == T_REQ && region == 3'd6;  assign spr_addr  = idx[19:0];
    // the tile RAM pattern: every address bit in both bytes
    wire [15:0] vpat = idx[15:0] ^ {idx[10:0], 5'b10110} ^ 16'hA55A;
    assign vram_req   = run && (st == T_VW || st == T_VR || st == T_VZ);
    assign vram_we    = st == T_VW || st == T_VZ;
    assign vram_addr  = idx[15:0];
    assign vram_wdata = (st == T_VZ) ? 16'd0 : vpat;

    always_ff @(posedge clk) begin
        start_d <= start;
        if (init) begin st <= T_IDLE; run <= 1'b0; done <= 1'b0; ok <= '0; stable <= '0; vram_ok <= 1'b0; vram_bad <= '0; vbad <= '0; end
        else case (st)
            T_IDLE: if (start && !start_d && ready) begin
                run <= 1'b1; done <= 1'b0; region <= 3'd0; pass <= 1'b0; idx <= '0; acc <= '0; add_pend <= 1'b0; st <= T_REQ;
            end
            T_REQ: begin
                if (region == 3'd3) begin       // blocks: a word a clock as it streams
                    add_pend <= blk_wr; bytes_r <= 11'(blk_data[15:8]) + 11'(blk_data[7:0]);
                end else begin
                    add_pend <= ack; bytes_r <= bytes;
                end
                if (add_pend) acc <= acc + 24'(bytes_r);
                if (ack) begin
                    if (idx == n_end - 23'd1) st <= T_SUM; else idx <= idx + 23'd1;
                end
            end
            T_SUM: begin                        // the last add lands
                if (add_pend) acc <= acc + 24'(bytes_r);
                add_pend <= 1'b0; st <= T_NEXT;
            end
            T_NEXT: begin
                if (!pass) begin asum[region] <= acc; ok[region] <= (acc == lsum[region]); end
                else stable[region] <= (acc == asum[region]);
                acc <= '0; idx <= '0; st <= T_REQ;
                if (region != 3'd6) region <= region + 3'd1;
                else if (!pass) begin pass <= 1'b1; region <= 3'd0; end
                else begin vbad <= '0; st <= T_VW; end
            end
            T_VW: if (vram_ack) begin
                if (idx[15:0] == 16'hffff) begin idx <= '0; st <= T_VR; end else idx <= idx + 23'd1;
            end
            T_VR: if (vram_ack) begin
                if (vram_q != vpat) vbad <= vbad + 17'd1;
                if (idx[15:0] == 16'hffff) begin idx <= '0; st <= T_VZ; end else idx <= idx + 23'd1;
            end
            T_VZ: if (vram_ack) begin       // leave the tile RAM clear, as the game expects
                if (idx[15:0] == 16'hffff) st <= T_DONE; else idx <= idx + 23'd1;
            end
            T_DONE: begin
                vram_ok  <= (vbad == 17'd0);
                vram_bad <= (vbad == 17'd0) ? 4'd0 : (vbad[16:14] != 3'd0) ? 4'd15 :
                            vbad[13] ? 4'd14 : vbad[12] ? 4'd13 : vbad[11] ? 4'd12 : vbad[10] ? 4'd11 : vbad[9] ? 4'd10 :
                            vbad[8] ? 4'd9 : vbad[7] ? 4'd8 : vbad[6] ? 4'd7 : vbad[5] ? 4'd6 : vbad[4] ? 4'd5 :
                            vbad[3] ? 4'd4 : vbad[2] ? 4'd3 : vbad[1] ? 4'd2 : 4'd1;
                run <= 1'b0; done <= 1'b1; st <= T_IDLE;
            end
            default: st <= T_IDLE;
        endcase
    end
    /* verilator lint_off UNUSEDSIGNAL */
    wire unused = ^{idx[22:16]};
    /* verilator lint_on UNUSEDSIGNAL */
endmodule
