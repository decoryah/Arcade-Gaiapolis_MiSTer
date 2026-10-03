//------------------------------------------------------------------------------
// MiSTer memory subsystem for the Gaiapolis core: the ROM image behind the
// core's request/ack ports (docs/hardware.md section 11 describes the ports;
// docs/mister-memory.md this partition).
//
//   SDRAM  (32 MB, 16 bit)   tiles     2 MB   2-word bursts
//                            sprites   8 MB   4-word bursts
//                            PCM       4 MB   single words
//                            68000 program 3 MB and Z80 program 256 KB:
//                                      behind a cache each, filled by 8-word
//                                      bursts on the same burst port
//   DDR3   (the HPS's, 64 bit) ROZ characters 1.5 MB (a tile: 16 beats) and
//                            ROZ map 640 KB (a 3-beat prefetch per tile miss)
//   block RAM                K056832 tile RAM, 64K x 16, byte-enabled
//
// The Pocket core had the programs and the ROZ map in PSRAM, the ROZ
// characters on the SDRAM, and the tile RAM in SRAM. MiSTer has neither PSRAM
// nor SRAM, so the programs move to the SDRAM behind caches (the 68000 wants a
// word every 24 clocks but fetches mostly in straight lines) and the ROZ
// plane -- which took 1,400-3,200 of the SDRAM's 6,144 clocks a line -- moves
// to the DDR3, which is otherwise idle.
//
// Every memory holds big-endian 16-bit words: image byte 2k is the high byte
// of word k, byte 2k+1 the low byte (the packing sim/tb_system.cpp uses).
//
// The core's ports are level requests with a one-cycle ack that carries the
// data; a client may withdraw a request before its ack (a renderer restarting
// on a new line does), so every port here finishes the access it started and
// acks only if the same request is still standing.
//------------------------------------------------------------------------------
`default_nettype none

module gaia_mem #(
    parameter int TEST_SHRINK = 0       // the memory test reads 1/2^n of each region (benches)
) (
    input  logic        clk,            // 96 MHz
    input  logic        clk_sdram,      // 96 MHz, phase-shifted: drives the SDRAM clock pin
    input  logic        init,           // hardware reset: re-initialise the SDRAM
    input  logic        dl_start,       // an image is about to load: drop the caches
    output logic        ready,
    // the built-in memory test (mem_test): started by test_start while the
    // core is in reset; the platform keeps the core there while test_run
    input  logic        test_start,
    output logic        test_run, test_done,
    output logic  [6:0] test_ok,        // per region: prog, snd, tile, chr, map, pcm, spr -- read back == loaded
    output logic  [6:0] test_stable,    // per region: the second pass read the same as the first
    output logic        vram_ok,
    output logic  [3:0] vram_bad,       // tile RAM words that read back wrong, saturating
    input  logic        rd_late,        // SDRAM read capture one clock later (OSD diagnostic)
    input  logic        burst_slow,     // SDRAM bursts at the slow spacing (OSD diagnostic)

    // the ROM image arriving from the HPS, a byte at an image offset
    input  logic        dl_we,          // one clock per byte
    input  logic [24:0] dl_addr,
    input  logic  [7:0] dl_data,
    output logic        dl_wait,        // hold the next byte

    // core ports
    input  logic        prog_req,  input  logic [22:1] prog_addr, output logic prog_ack, output logic [15:0] prog_q,
    input  logic        tile_req,  input  logic [18:0] tile_addr, output logic tile_ack, output logic [31:0] tile_q,
    input  logic        map_req,   input  logic [19:0] map_addr,  output logic map_ack,  output logic [15:0] map_q,
    input  logic        blk_req,   input  logic [15:0] blk_addr,  output logic blk_wr,   output logic  [5:0] blk_idx,
    output logic [15:0] blk_data,  output logic        blk_ack,
    input  logic  [3:0] roz_lead,       // lines the ROZ plane has in hand: no longer used here (the ROZ no longer shares the SDRAM)
    input  logic        spr_req,   input  logic [19:0] spr_addr,  output logic spr_ack,  output logic [63:0] spr_q,
    input  logic        snd_req,   input  logic [17:0] snd_addr,  output logic snd_ack,  output logic  [7:0] snd_q,
    input  logic        pcm_req,   input  logic [21:0] pcm_addr,  output logic pcm_ack,  output logic  [7:0] pcm_q,
    // the tile RAM: the core's request/ack port, byte-enabled writes
    input  logic        vram_req,  input  logic        vram_we,   input  logic [15:0] vram_addr,
    input  logic  [1:0] vram_be,   input  logic [15:0] vram_wdata, output logic vram_ack, output logic [15:0] vram_q,

    // SDRAM pins
    inout  wire  [15:0] dram_dq,
    output logic [12:0] dram_a,
    output logic  [1:0] dram_ba,
    output logic  [1:0] dram_dqm,
    output logic        dram_clk, dram_cke, dram_ras_n, dram_cas_n, dram_we_n,

    // DDR3 (Avalon-MM master protocol, through ddr_arb)
    output logic        ddr_rd,
    output logic        ddr_we,
    output logic [24:0] ddr_addr,
    output logic  [7:0] ddr_burst,
    output logic [63:0] ddr_din,
    output logic  [7:0] ddr_be,
    input  logic        ddr_busy,
    input  logic [63:0] ddr_dout,
    input  logic        ddr_dready
);
    // image layout (byte offsets), mra/*.mra
    localparam [24:0] IMG_PROG = 25'h0000000, IMG_SND  = 25'h0300000, IMG_TILE = 25'h0340000;
    localparam [24:0] IMG_CHR  = 25'h0540000, IMG_MAP  = 25'h06C0000, IMG_PCM  = 25'h0760000;
    localparam [24:0] IMG_SPR  = 25'h0B60000, IMG_END  = 25'h1360000;
    // SDRAM word addresses
    localparam [24:1] SD_TILE = 24'h000000, SD_PCM = 24'h100000, SD_SPR = 24'h300000, SD_PROG = 24'h700000, SD_SND = 24'h880000;
    // DDR3 beats (64-bit words) in the client's window
    localparam [24:0] DD_MAP = 25'h0000000, DD_CHR = 25'h0020000;

    // the caches are cleared by a hardware reset and whenever an image loads
    wire cinv = init | dl_start;

    // ------------------------------------------------------------ download
    // The HPS delivers a byte at a time, at most one every few clocks. A
    // consecutive even/odd pair is merged into one 16-bit word before a small
    // FIFO; the dispatcher behind it routes each entry to its memory as a
    // byte-enabled word write. A lone even byte waits for its partner (the
    // next byte) and is flushed alone if none arrives.
    logic        pend_v;
    logic [24:0] pend_a;
    logic  [7:0] pend_d, pend_age;
    wire         nb = dl_we;                                // a new byte this clock
    logic        wf_push;
    logic [41:0] wf_in;                                     // {word addr[24:1], be[1:0], data[15:0]}
    always_comb begin
        wf_push = 1'b0; wf_in = '0;
        if (nb && pend_v && dl_addr == {pend_a[24:1], 1'b1}) begin
            wf_push = 1'b1; wf_in = {pend_a[24:1], 2'b11, pend_d, dl_data};
        end else if (pend_v && (nb || pend_age == 8'hff)) begin
            wf_push = 1'b1; wf_in = {pend_a[24:1], pend_a[0] ? 2'b01 : 2'b10, pend_d, pend_d};
        end
    end

    (* ramstyle = "no_rw_check" *) logic [41:0] wfifo [64];   // the head is never the entry being written
    logic  [6:0] wf_wp, wf_rp;
    wire         wf_empty = (wf_wp == wf_rp);
    wire [41:0]  wf_head  = wfifo[wf_rp[5:0]];
    assign dl_wait = ((wf_wp - wf_rp) >= 7'd32);
    // the head is taken into a register before it is decoded
    logic [41:0] hd;
    wire [24:1]  wa       = hd[41:18];
    wire [19:0]  wchr     = 20'(wa - IMG_CHR[24:1]);   // word within the character region
    wire [18:0]  wmap     = 19'(wa - IMG_MAP[24:1]);   // word within the map region
    wire  [1:0]  wbe      = hd[17:16];
    wire [15:0]  wd       = hd[15:0];
    // a character word's place in its tile: stored column-major, 64 words a tile
    wire [19:0]  chr_w16  = {wchr[19:6], wchr[1:0], wchr[5:2]};

    typedef enum logic [2:0] { W_IDLE, W_DEC, W_SDRAM, W_DDR } wst_t;
    wst_t wst;

    // SDRAM write client (client 1) and the DDR3 writer
    logic        sd_wr_req, sd_wr_ack;
    logic [24:1] sd_wr_addr;
    logic        ddr_wr_req, ddr_wr_ack;
    logic [24:0] ddr_wr_beat;
    logic  [1:0] ddr_wr_lane;

    always_ff @(posedge clk) begin
        if (init) begin
            wf_wp <= '0; wf_rp <= '0; wst <= W_IDLE; pend_v <= 1'b0; pend_age <= '0;
            sd_wr_req <= 1'b0; ddr_wr_req <= 1'b0;
        end else begin
            // pairing stage
            if (nb) begin
                if (pend_v && dl_addr == {pend_a[24:1], 1'b1}) pend_v <= 1'b0;
                else begin pend_v <= 1'b1; pend_a <= dl_addr; pend_d <= dl_data; pend_age <= '0; end
            end else if (pend_v) begin
                if (pend_age == 8'hff) pend_v <= 1'b0; else pend_age <= pend_age + 8'd1;
            end
            if (wf_push) begin              // not full: the HPS stops at dl_wait with 32 queued
                wfifo[wf_wp[5:0]] <= wf_in;
                wf_wp <= wf_wp + 7'd1;
            end
            case (wst)
                W_IDLE: if (!wf_empty) begin hd <= wf_head; wst <= W_DEC; end
                W_DEC: begin
                    if (wa < IMG_SND[24:1]) begin                 // 68000 program
                        sd_wr_addr <= SD_PROG + wa; sd_wr_req <= 1'b1; wst <= W_SDRAM;
                    end else if (wa < IMG_TILE[24:1]) begin       // Z80 program
                        sd_wr_addr <= SD_SND + (wa - IMG_SND[24:1]); sd_wr_req <= 1'b1; wst <= W_SDRAM;
                    end else if (wa < IMG_CHR[24:1]) begin        // tiles
                        sd_wr_addr <= SD_TILE + (wa - IMG_TILE[24:1]); sd_wr_req <= 1'b1; wst <= W_SDRAM;
                    end else if (wa < IMG_MAP[24:1]) begin        // ROZ characters -> DDR3, column-major within the tile
                        ddr_wr_beat <= DD_CHR + 25'(chr_w16[19:2]); ddr_wr_lane <= chr_w16[1:0];
                        ddr_wr_req <= 1'b1; wst <= W_DDR;
                    end else if (wa < IMG_PCM[24:1]) begin        // ROZ map -> DDR3
                        ddr_wr_beat <= DD_MAP + 25'(wmap[18:2]); ddr_wr_lane <= wmap[1:0];
                        ddr_wr_req <= 1'b1; wst <= W_DDR;
                    end else if (wa < IMG_SPR[24:1]) begin        // PCM
                        sd_wr_addr <= SD_PCM + (wa - IMG_PCM[24:1]); sd_wr_req <= 1'b1; wst <= W_SDRAM;
                    end else if (wa < IMG_END[24:1]) begin        // sprites
                        sd_wr_addr <= SD_SPR + (wa - IMG_SPR[24:1]); sd_wr_req <= 1'b1; wst <= W_SDRAM;
                    end else begin wf_rp <= wf_rp + 7'd1; wst <= W_IDLE; end   // beyond the image: dropped
                end
                // the acks pop the entry
                W_SDRAM: if (sd_wr_ack)  begin sd_wr_req  <= 1'b0; wf_rp <= wf_rp + 7'd1; wst <= W_IDLE; end
                W_DDR:   if (ddr_wr_ack) begin ddr_wr_req <= 1'b0; wf_rp <= wf_rp + 7'd1; wst <= W_IDLE; end
                default: wst <= W_IDLE;
            endcase
        end
    end

    // ---------------------------------------------- the test drives the ports
    logic        t_prog_req, t_snd_req, t_tile_req, t_blk_req, t_map_req, t_pcm_req, t_spr_req;
    logic [22:1] t_prog_addr; logic [17:0] t_snd_addr; logic [18:0] t_tile_addr; logic [15:0] t_blk_addr;
    logic [19:0] t_map_addr;  logic [21:0] t_pcm_addr; logic [19:0] t_spr_addr;
    logic        t_vram_req, t_vram_we; logic [15:0] t_vram_addr, t_vram_wdata;
    wire         prog_req_i  = test_run ? t_prog_req  : prog_req;
    wire [22:1]  prog_addr_i = test_run ? t_prog_addr : prog_addr;
    wire         snd_req_i   = test_run ? t_snd_req   : snd_req;
    wire [17:0]  snd_addr_i  = test_run ? t_snd_addr  : snd_addr;
    wire         tile_req_i  = test_run ? t_tile_req  : tile_req;
    wire [18:0]  tile_addr_i = test_run ? t_tile_addr : tile_addr;
    wire         blk_req_i   = test_run ? t_blk_req   : blk_req;
    wire [15:0]  blk_addr_i  = test_run ? t_blk_addr  : blk_addr;
    wire         map_req_i   = test_run ? t_map_req   : map_req;
    wire [19:0]  map_addr_i  = test_run ? t_map_addr  : map_addr;
    wire         pcm_req_i   = test_run ? t_pcm_req   : pcm_req;
    wire [21:0]  pcm_addr_i  = test_run ? t_pcm_addr  : pcm_addr;
    wire         spr_req_i   = test_run ? t_spr_req   : spr_req;
    wire [19:0]  spr_addr_i  = test_run ? t_spr_addr  : spr_addr;
    wire         vram_req_i  = test_run ? t_vram_req  : vram_req;
    wire         vram_we_i   = test_run ? t_vram_we   : vram_we;
    wire [15:0]  vram_addr_i = test_run ? t_vram_addr : vram_addr;
    wire  [1:0]  vram_be_i   = test_run ? 2'b11       : vram_be;
    wire [15:0]  vram_wdata_i = test_run ? t_vram_wdata : vram_wdata;

    logic        mem_ready;
    mem_test #(.SHRINK(TEST_SHRINK)) u_test (
        .clk(clk), .init(init), .ready(mem_ready), .start(test_start), .run(test_run), .done(test_done),
        .ok(test_ok), .stable(test_stable), .vram_ok(vram_ok), .vram_bad(vram_bad),
        .dl_we(dl_we), .dl_addr(dl_addr), .dl_data(dl_data),
        .prog_req(t_prog_req), .prog_addr(t_prog_addr), .prog_ack(prog_ack), .prog_q(prog_q),
        .snd_req(t_snd_req), .snd_addr(t_snd_addr), .snd_ack(snd_ack), .snd_q(snd_q),
        .tile_req(t_tile_req), .tile_addr(t_tile_addr), .tile_ack(tile_ack), .tile_q(tile_q),
        .blk_req(t_blk_req), .blk_addr(t_blk_addr), .blk_wr(blk_wr), .blk_data(blk_data), .blk_ack(blk_ack),
        .map_req(t_map_req), .map_addr(t_map_addr), .map_ack(map_ack), .map_q(map_q),
        .pcm_req(t_pcm_req), .pcm_addr(t_pcm_addr), .pcm_ack(pcm_ack), .pcm_q(pcm_q),
        .spr_req(t_spr_req), .spr_addr(t_spr_addr), .spr_ack(spr_ack), .spr_q(spr_q),
        .vram_req(t_vram_req), .vram_we(t_vram_we), .vram_addr(t_vram_addr), .vram_wdata(t_vram_wdata),
        .vram_ack(vram_ack), .vram_q(vram_q)
    );

    // --------------------------------------------------------------- SDRAM
    logic [24:1] c_addr  [2];
    logic        c_req   [2];
    logic        c_we    [2];
    logic [15:0] c_wdata [2];
    logic  [1:0] c_be    [2];
    logic        c_ack   [2];
    logic [15:0] sd_rdata;
    logic [24:1] b_addr;
    logic  [9:0] b_len, b_idx;
    logic        b_req, b_done;
    logic        b_wr;
    logic [15:0] b_data;
    logic  [9:0] b_widx;
    logic        sd_ready;

    // client 0: PCM byte reads, behind a registered stage: the request comes
    // from the K054539s through two arbiters, and the stage acks only a
    // request still standing with the same address.
    typedef enum logic [1:0] { Q_IDLE, Q_BUSY, Q_ACK } qst_t;
    qst_t        qst;
    logic [21:0] pcm_addr_l;
    logic [15:0] pcm_word;
    always_ff @(posedge clk) begin
        pcm_ack <= 1'b0;
        if (init) begin qst <= Q_IDLE; c_req[0] <= 1'b0; end
        else case (qst)
            Q_IDLE: if (pcm_req_i && !pcm_ack) begin
                pcm_addr_l <= pcm_addr_i; c_addr[0] <= SD_PCM + 24'(pcm_addr_i[21:1]); c_req[0] <= 1'b1; qst <= Q_BUSY;
            end
            Q_BUSY: if (c_ack[0]) begin pcm_word <= sd_rdata; c_req[0] <= 1'b0; qst <= Q_ACK; end
            Q_ACK: begin
                if (pcm_req_i && pcm_addr_i == pcm_addr_l) pcm_ack <= 1'b1;
                qst <= Q_IDLE;
            end
            default: qst <= Q_IDLE;
        endcase
    end
    assign c_we[0]   = 1'b0; assign c_wdata[0] = '0; assign c_be[0] = 2'b11;
    assign pcm_q     = pcm_addr_l[0] ? pcm_word[7:0] : pcm_word[15:8];
    // client 1: the loader
    assign c_addr[1] = sd_wr_addr;
    assign c_req[1]  = sd_wr_req;
    assign c_we[1]   = 1'b1; assign c_wdata[1] = wd; assign c_be[1] = wbe;
    assign sd_wr_ack = c_ack[1];

    // The burst port serves the tilemap's 2-word and the sprite renderer's
    // 4-word fetches (both have a line to finish) and the two program caches'
    // 8-word line fills. A fill that has waited long enough goes first, so
    // the 68000 and the Z80 are never starved by the renderers' back-to-back
    // requests: the renderers use about half of the port, so the interruptions
    // cost them nothing the line budget does not have.
    localparam int PW_URG = 40, SW_URG = 120;
    typedef enum logic [1:0] { B_IDLE, B_RUN, B_ACK } bst_t;
    bst_t  bst;
    logic  [1:0] bsel;                  // 0 tiles, 1 sprites, 2 68000 program fill, 3 Z80 program fill
    logic [18:0] tile_addr_l;
    logic [19:0] spr_addr_l;
    logic [15:0] bw [4];
    logic        pf_req, sf_req;        // the caches' fill requests
    logic [21:3] pf_addr;
    logic [16:3] sf_addr;
    logic  [7:0] pw, sw;                // clocks a fill has waited
    always_ff @(posedge clk) begin
        pw <= (pf_req && !(bst == B_RUN && bsel == 2'd2)) ? ((pw == 8'hff) ? pw : pw + 8'd1) : 8'd0;
        sw <= (sf_req && !(bst == B_RUN && bsel == 2'd3)) ? ((sw == 8'hff) ? sw : sw + 8'd1) : 8'd0;
    end
    wire pf_go = pf_req && (pw >= 8'(PW_URG));
    wire sf_go = sf_req && (sw >= 8'(SW_URG));
    always_ff @(posedge clk) begin
        if (init) begin bst <= B_IDLE; b_req <= 1'b0; tile_ack <= 1'b0; spr_ack <= 1'b0; end
        else begin
            tile_ack <= 1'b0; spr_ack <= 1'b0;
            case (bst)
                B_IDLE: begin               // not a request being acked right now
                    if (pf_go) begin
                        bsel <= 2'd2; b_addr <= SD_PROG + {2'd0, pf_addr, 3'd0}; b_len <= 10'd8; b_req <= 1'b1; bst <= B_RUN;
                    end else if (sf_go) begin
                        bsel <= 2'd3; b_addr <= SD_SND + {7'd0, sf_addr, 3'd0}; b_len <= 10'd8; b_req <= 1'b1; bst <= B_RUN;
                    end else if (tile_req_i && !tile_ack) begin
                        bsel <= 2'd0; tile_addr_l <= tile_addr_i;
                        b_addr <= SD_TILE + {4'd0, tile_addr_i, 1'b0}; b_len <= 10'd2; b_req <= 1'b1; bst <= B_RUN;
                    end else if (spr_req_i && !spr_ack) begin
                        bsel <= 2'd1; spr_addr_l <= spr_addr_i;
                        b_addr <= SD_SPR + {2'd0, spr_addr_i, 2'b00}; b_len <= 10'd4; b_req <= 1'b1; bst <= B_RUN;
                    end else if (pf_req) begin
                        bsel <= 2'd2; b_addr <= SD_PROG + {2'd0, pf_addr, 3'd0}; b_len <= 10'd8; b_req <= 1'b1; bst <= B_RUN;
                    end else if (sf_req) begin
                        bsel <= 2'd3; b_addr <= SD_SND + {7'd0, sf_addr, 3'd0}; b_len <= 10'd8; b_req <= 1'b1; bst <= B_RUN;
                    end
                end
                B_RUN: begin
                    if (b_wr) bw[b_idx[1:0]] <= b_data;
                    if (b_done) begin b_req <= 1'b0; bst <= B_ACK; end
                end
                B_ACK: begin
                    // ack only the request that is still standing
                    if (bsel == 2'd0 && tile_req_i && tile_addr_i == tile_addr_l) tile_ack <= 1'b1;
                    if (bsel == 2'd1 && spr_req_i  && spr_addr_i  == spr_addr_l)  spr_ack  <= 1'b1;
                    bst <= B_IDLE;
                end
                default: bst <= B_IDLE;
            endcase
        end
    end
    assign tile_q = {bw[0], bw[1]};
    assign spr_q  = {bw[0], bw[1], bw[2], bw[3]};

    // the caches: 68000 program 16 KB, Z80 program 4 KB; direct mapped, 16-byte lines
    logic        pc_ready, sc_ready;
    logic [15:0] snd_word;
    rom_cache #(.AW(22), .IDX(10)) u_pcache (
        .clk(clk), .reset(cinv), .ready(pc_ready),
        .req(prog_req_i), .addr(prog_addr_i), .ack(prog_ack), .q(prog_q),
        .fill_req(pf_req), .fill_addr(pf_addr),
        .fill_wr(b_wr && bst == B_RUN && bsel == 2'd2), .fill_idx(b_idx[2:0]), .fill_data(b_data),
        .fill_done(bst == B_ACK && bsel == 2'd2)
    );
    rom_cache #(.AW(17), .IDX(8)) u_scache (
        .clk(clk), .reset(cinv), .ready(sc_ready),
        .req(snd_req_i), .addr(snd_addr_i[17:1]), .ack(snd_ack), .q(snd_word),
        .fill_req(sf_req), .fill_addr(sf_addr),
        .fill_wr(b_wr && bst == B_RUN && bsel == 2'd3), .fill_idx(b_idx[2:0]), .fill_data(b_data),
        .fill_done(bst == B_ACK && bsel == 2'd3)
    );
    assign snd_q = snd_addr_i[0] ? snd_word[7:0] : snd_word[15:8];
    assign mem_ready = sd_ready && pc_ready && sc_ready;
    assign ready     = mem_ready;

    sdram_ctrl #(.NCLI(2)) u_sdram (
        .clk(clk), .clk_pin(clk_sdram), .init(init), .rd_late(rd_late), .burst_slow(burst_slow), .ready(sd_ready),
        .SDRAM_DQ(dram_dq), .SDRAM_A(dram_a), .SDRAM_DQML(dram_dqm[0]), .SDRAM_DQMH(dram_dqm[1]), .SDRAM_BA(dram_ba),
        .SDRAM_nCS(), .SDRAM_nWE(dram_we_n), .SDRAM_nRAS(dram_ras_n), .SDRAM_nCAS(dram_cas_n),
        .SDRAM_CKE(dram_cke), .SDRAM_CLK(dram_clk),
        .c_addr(c_addr), .c_req(c_req), .c_we(c_we), .c_wdata(c_wdata), .c_be(c_be), .c_ack(c_ack), .rdata(sd_rdata),
        .b_addr(b_addr), .b_len(b_len), .b_req(b_req), .b_abort(1'b0), .b_wr(b_wr), .b_idx(b_idx), .b_data(b_data), .b_done(b_done),
        .b_we(1'b0), .b_wdata(16'd0), .b_be(2'b00), .b_widx(b_widx)
    );

    // ---------------------------------------------------------------- DDR3
    // The ROZ plane's map and characters. A miss in the plane's tile cache
    // costs three map reads (colour nibbles, then two attribute bytes) and a
    // 64-word character block. The map's three bytes of one tile are in three
    // far-apart regions but all derive from the first read's address, so one
    // miss on the first prefetches the other two beats together; each region
    // keeps its last beat (8 bytes = 8 neighbouring tiles' bytes) for the
    // next misses along the walk. The character block is 16 beats, buffered
    // whole and streamed to the renderer a word a clock.
    logic [63:0] mc_d   [3];
    logic [16:0] mc_tag [3];
    logic  [2:0] mc_v;
    logic [16:0] mb     [3];
    logic  [1:0] mslot  [3];
    logic  [1:0] mn, mi, mcn;
    logic [19:0] map_addr_l;
    logic [15:0] blk_addr_l;
    logic [63:0] bbuf   [16];
    logic  [4:0] bn;
    logic  [6:0] bo;
    logic        map_ack_d, blk_ack_d;

    function automatic logic [1:0] mregion(input logic [19:0] a);
        return (a < 20'h20000) ? 2'd0 : (a < 20'h60000) ? 2'd1 : 2'd2;
    endfunction
    wire  [1:0]  mr_l   = mregion(map_addr_l);
    wire         mc_hit = mc_v[mr_l] && (mc_tag[mr_l] == map_addr_l[19:3]);

    typedef enum logic [3:0] { D_IDLE, D_MC, D_MS, D_MA, D_BS, D_BO, D_BA, D_WR } dst_t;
    dst_t dst;

    always_ff @(posedge clk) begin
        map_ack <= 1'b0; blk_ack <= 1'b0; blk_wr <= 1'b0; ddr_wr_ack <= 1'b0;
        map_ack_d <= map_ack; blk_ack_d <= blk_ack;
        if (ddr_rd && !ddr_busy) ddr_rd <= 1'b0;            // taken (cleared first: a state may present the next command below)
        if (ddr_we && !ddr_busy) ddr_we <= 1'b0;
        if (cinv) begin
            mc_v <= '0; dst <= D_IDLE; ddr_rd <= 1'b0; ddr_we <= 1'b0;
        end else case (dst)
            D_IDLE: begin
                if (ddr_wr_req && !ddr_wr_ack) begin                    // the loader's write
                    ddr_we <= 1'b1; ddr_addr <= ddr_wr_beat; ddr_burst <= 8'd1;
                    ddr_din <= {4{wd}}; ddr_be <= 8'b11 << {ddr_wr_lane, 1'b0};
                    dst <= D_WR;
                end else if (map_req_i && !map_ack && !map_ack_d) begin
                    map_addr_l <= map_addr_i;               // the lookup works from this register, next clock
                    dst <= D_MC;
                end else if (blk_req_i && !blk_ack && !blk_ack_d) begin
                    blk_addr_l <= blk_addr_i;
                    ddr_rd <= 1'b1; ddr_addr <= DD_CHR + {7'd0, blk_addr_i[13:0], 4'd0}; ddr_burst <= 8'd16;
                    bn <= '0;
                    dst <= D_BS;
                end
            end

            // the map lookup: a hit answers from the slot, a miss sets up its fetches
            D_MC: begin
                if (mc_hit) begin
                    map_q <= mc_d[mr_l][16 * map_addr_l[2:1] +: 16];
                    if (map_req_i && map_addr_i == map_addr_l) map_ack <= 1'b1;
                    dst <= D_IDLE;
                end else begin
                    mb[0] <= map_addr_l[19:3];
                    if (mr_l == 2'd0) begin             // the colour nibbles: fetch the tile's other two bytes too
                        mb[1] <= 17'h04000 + {2'd0, map_addr_l[16:2]};
                        mb[2] <= 17'h0C000 + {2'd0, map_addr_l[16:2]};
                        mslot[0] <= 2'd0; mslot[1] <= 2'd1; mslot[2] <= 2'd2; mn <= 2'd3;
                        mc_v <= '0;
                    end else begin
                        mslot[0] <= mr_l; mn <= 2'd1;
                        mc_v[mr_l] <= 1'b0;
                    end
                    mi <= '0; mcn <= '0;
                    dst <= D_MS;
                end
            end

            // map miss: issue the commands one after another, collect the beats in order
            D_MS: begin
                if (!ddr_rd && mi != mn) begin
                    ddr_rd <= 1'b1; ddr_addr <= DD_MAP + {8'd0, mb[mi]}; ddr_burst <= 8'd1; mi <= mi + 2'd1;
                end
                if (ddr_dready) begin
                    mc_d[mslot[mcn]] <= ddr_dout; mc_tag[mslot[mcn]] <= mb[mcn]; mc_v[mslot[mcn]] <= 1'b1;
                    mcn <= mcn + 2'd1;
                    if (mcn + 2'd1 == mn) dst <= D_MA;
                end
            end
            D_MA: begin
                if (map_req_i && map_addr_i == map_addr_l) begin
                    map_q <= mc_d[mr_l][16 * map_addr_l[2:1] +: 16]; map_ack <= 1'b1;
                end
                dst <= D_IDLE;
            end

            // character block: 16 beats in, 64 words out
            D_BS: if (ddr_dready) begin
                bbuf[bn[3:0]] <= ddr_dout; bn <= bn + 5'd1;
                if (bn == 5'd15) begin bo <= '0; dst <= D_BO; end
            end
            D_BO: begin
                blk_wr <= 1'b1; blk_idx <= bo[5:0]; blk_data <= bbuf[bo[5:2]][16 * bo[1:0] +: 16];
                bo <= bo + 7'd1;
                if (bo == 7'd63) dst <= D_BA;
            end
            D_BA: begin
                if (blk_req_i && blk_addr_i == blk_addr_l) blk_ack <= 1'b1;
                dst <= D_IDLE;
            end

            D_WR: if (ddr_we && !ddr_busy) begin ddr_wr_ack <= 1'b1; dst <= D_IDLE; end
            default: dst <= D_IDLE;
        endcase
    end

    // ---------------------------------------------------------- tile RAM
    vram_bram u_vram (
        .clk(clk),
        .req(vram_req_i), .we(vram_we_i), .addr(vram_addr_i), .be(vram_be_i), .wdata(vram_wdata_i),
        .ack(vram_ack), .q(vram_q)
    );

    /* verilator lint_off UNUSEDSIGNAL */
    wire unused = ^{b_widx, b_idx[9:3], roz_lead, wbe[0], IMG_PROG, dl_addr[0]};
    /* verilator lint_on UNUSEDSIGNAL */
endmodule


//------------------------------------------------------------------------------
// The K056832's tile RAM, 64K x 16 with byte enables, in block RAM behind one
// request/ack port (the Pocket's SRAM took this job there). The address and
// write data go to the RAM in the clock the request is seen; the read data is
// back a clock later and is acked then, if the same request is still standing
// (a renderer withdraws at line start). A write is performed whether or not
// the client is still there to hear the ack.
//------------------------------------------------------------------------------
module vram_bram (
    input  logic        clk,
    input  logic        req,
    input  logic        we,
    input  logic [15:0] addr,
    input  logic  [1:0] be,
    input  logic [15:0] wdata,
    output logic        ack,
    output logic [15:0] q
);
    (* ramstyle = "M10K,no_rw_check" *) logic [7:0] ram_lo [65536];
    (* ramstyle = "M10K,no_rw_check" *) logic [7:0] ram_hi [65536];
    logic        busy, busy_d, we_l;
    logic [15:0] addr_l;
    logic  [7:0] rq_lo, rq_hi;
    wire         take = req && !busy && !busy_d && !ack;     // not the request being acked right now

    always_ff @(posedge clk) begin
        if (take && we && be[0]) ram_lo[addr] <= wdata[7:0];
        if (take && we && be[1]) ram_hi[addr] <= wdata[15:8];
        rq_lo <= ram_lo[addr];
        rq_hi <= ram_hi[addr];
    end
    always_ff @(posedge clk) begin
        ack <= 1'b0;
        busy_d <= busy;
        if (take) begin busy <= 1'b1; addr_l <= addr; we_l <= we; end
        else if (busy) begin
            busy <= 1'b0;
            q <= {rq_hi, rq_lo};
            if (req && addr == addr_l && we == we_l) ack <= 1'b1;
        end
    end
endmodule
