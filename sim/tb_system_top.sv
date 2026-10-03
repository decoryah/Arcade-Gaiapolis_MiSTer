// Full-system bench wrapper: gaia_core with ideal memories behind every ROM
// port, loadable from the C++ driver. The ROM models answer in one cycle.
`default_nettype none

module tb_system_top #(
    parameter int STEP_COST_BUS = 16,   // 68000 pacing, overridable with -G for calibration
    parameter int STEP_COST_INT = 8
) (
    input  logic        clk,
    input  logic        reset,

    // loads
    input  logic        prog_we, input logic [21:0] prog_waddr, input logic [15:0] prog_wdata,
    input  logic        tile_we, input logic [18:0] tile_waddr, input logic [31:0] tile_wdata,
    input  logic        map_we,  input logic [18:0] map_waddr,  input logic [15:0] map_wdata,
    input  logic        chr_we,  input logic [19:0] chr_waddr,  input logic [15:0] chr_wdata,
    input  logic        spr_we,  input logic [19:0] spr_waddr,  input logic [63:0] spr_wdata,
    input  logic        eep_we,  input logic  [6:0] eep_waddr,  input logic  [7:0] eep_wdata,
    input  logic        srom_we, input logic [17:0] srom_waddr, input logic  [7:0] srom_wdata,
    input  logic        pcm_we,  input logic [21:0] pcm_waddr,  input logic  [7:0] pcm_wdata,

    input  logic [15:0] in0_p1,
    input  logic  [7:0] in1,
    input  logic  [7:0] p2,

    output logic        cen_pix,
    output logic [23:0] rgb,
    output logic        hsync, vsync, de, vblank,
    output logic [23:0] dbg_addr,
    output logic [15:0] dbg_data,
    output logic  [1:0] dbg_busstate,
    output logic        dbg_step, dbg_irq5, dbg_overrun, dbg_unsupported, dbg_shadow_overlap,
    output logic  [2:0] dbg_overrun_src,
    output logic [31:0] dbg_draw_objs, dbg_draw_rows, dbg_draw_cols, dbg_draw_pxw,
    output logic        dbg_spr_we,
    output logic          dbg_roz_en,
    output logic [127:0]  dbg_rozctrl,
    output logic  [31:0]  dbg_rozclip,
    output logic [383:0]  dbg_k55,
    output logic  [9:0] dbg_objcount,
    output logic  [8:0] dbg_vcount,
    output logic [15:0] dbg_zpc,
    output logic        dbg_zstep, dbg_zwait, dbg_zwr, dbg_zrd,
    output logic  [7:0] dbg_zwdata,
    output logic [15:0] snd_l, snd_r,
    output logic        snd_valid
);
    logic [15:0] prog [4194304];      // 22-bit word address; 3 MB used
    logic [31:0] tile [524288];
    logic [15:0] mapr [327680];
    logic [15:0] chr  [786432];
    logic [63:0] spr  [1048576];
    logic  [7:0] srom [262144];
    logic  [7:0] pcm  [4194304];
    logic        srom_req, srom_ack, pcmr_req, pcmr_ack;
    logic [17:0] srom_addr; logic [21:0] pcmr_addr;
    logic  [7:0] srom_q, pcmr_q;

    logic        prog_req, prog_ack, tile_req, tile_ack, map_req, map_ack, spr_req, spr_ack;
    logic [22:1] prog_addr; logic [18:0] tile_addr; logic [19:0] map_addr; logic [19:0] spr_addr;
    logic [15:0] prog_q, map_q; logic [31:0] tile_q; logic [63:0] spr_q;
    // the ROZ character blocks: LAT_BLK clocks after the request the tile's 64
    // words follow, one a clock, in {column, row} order out of the image-layout
    // array (word tile*64 + row*4 + column); a withdrawn request is dropped
    logic        blk_req, blk_wr, blk_ack;
    logic [15:0] blk_addr, blk_data;
    logic  [5:0] blk_idx;
    int lat_blk, cnt_blk;
    logic  [6:0] blk_n;
    logic        blk_run;
    logic [15:0] blk_addr_l;
    initial if (!$value$plusargs("LAT_BLK=%d", lat_blk)) lat_blk = 0;
    always_ff @(posedge clk) begin
        blk_wr <= 1'b0; blk_ack <= 1'b0;
        if (!blk_run) begin
            cnt_blk <= 0; blk_n <= 7'd0;
            if (blk_req && !blk_ack) begin blk_run <= 1'b1; blk_addr_l <= blk_addr; end
        end else if (cnt_blk < lat_blk) cnt_blk <= cnt_blk + 1;
        else if (blk_n != 7'd64) begin
            blk_wr <= 1'b1; blk_idx <= blk_n[5:0];
            blk_data <= chr[{blk_addr_l[13:0], blk_n[3:0], blk_n[5:4]}];
            blk_n <= blk_n + 7'd1;
        end else begin
            blk_run <= 1'b0;
            if (blk_req && blk_addr == blk_addr_l) blk_ack <= 1'b1;
        end
    end


    // Each ROM answers LAT_* clocks after the request (+LAT_PROG=n etc. on the
    // command line; 0 = the cycle after, the ideal). A request withdrawn
    // before its ack is dropped, as the Pocket memory ports do.
    int lat_prog, lat_tile, lat_map, lat_spr, lat_srom, lat_pcm;
    initial begin
        if (!$value$plusargs("LAT_PROG=%d", lat_prog)) lat_prog = 0;
        if (!$value$plusargs("LAT_TILE=%d", lat_tile)) lat_tile = 0;
        if (!$value$plusargs("LAT_MAP=%d",  lat_map))  lat_map  = 0;
        if (!$value$plusargs("LAT_SPR=%d",  lat_spr))  lat_spr  = 0;
        if (!$value$plusargs("LAT_SROM=%d", lat_srom)) lat_srom = 0;
        if (!$value$plusargs("LAT_PCM=%d",  lat_pcm))  lat_pcm  = 0;
    end
    int cnt_prog, cnt_tile, cnt_map, cnt_spr, cnt_srom, cnt_pcm;
    `define ROM_PORT(req, ack, cnt, lat) \
        if (!req) begin cnt <= 0; ack <= 1'b0; end \
        else if (ack) begin ack <= 1'b0; cnt <= 0; end \
        else if (cnt >= lat) begin ack <= 1'b1; cnt <= 0; end \
        else begin cnt <= cnt + 1; ack <= 1'b0; end

    always_ff @(posedge clk) begin
        if (prog_we) prog[prog_waddr] <= prog_wdata;
        if (tile_we) tile[tile_waddr] <= tile_wdata;
        if (map_we)  mapr[map_waddr]  <= map_wdata;
        if (chr_we)  chr[chr_waddr]   <= chr_wdata;
        if (spr_we)  spr[spr_waddr]   <= spr_wdata;
        if (srom_we) srom[srom_waddr] <= srom_wdata;
        if (pcm_we)  pcm[pcm_waddr]   <= pcm_wdata;
        srom_q <= srom[srom_addr];       `ROM_PORT(srom_req, srom_ack, cnt_srom, lat_srom)
        pcmr_q <= pcm[pcmr_addr];        `ROM_PORT(pcmr_req, pcmr_ack, cnt_pcm,  lat_pcm)
        prog_q <= prog[prog_addr];       `ROM_PORT(prog_req, prog_ack, cnt_prog, lat_prog)
        tile_q <= tile[tile_addr];       `ROM_PORT(tile_req, tile_ack, cnt_tile, lat_tile)
        map_q  <= mapr[map_addr[19:1]];  `ROM_PORT(map_req,  map_ack,  cnt_map,  lat_map)
        spr_q  <= spr[spr_addr];         `ROM_PORT(spr_req,  spr_ack,  cnt_spr,  lat_spr)
    end

    logic [7:0] eep_q; logic eep_dirty;

    // tile RAM: 64K x 16 behind the request/ack port, byte-enabled writes,
    // LAT_VRAM clocks to answer (the Pocket's SRAM port: ~5)
    logic [7:0]  vram_lo [65536];
    logic [7:0]  vram_hi [65536];
    logic        vram_req, vram_we, vram_ack;
    logic [15:0] vram_addr, vram_wdata, vram_q;
    logic  [1:0] vram_be;
    int lat_vram, cnt_vram;
    initial if (!$value$plusargs("LAT_VRAM=%d", lat_vram)) lat_vram = 0;
    always_ff @(posedge clk) begin
        if (vram_req && vram_we && !vram_ack && cnt_vram >= lat_vram) begin
            if (vram_be[0]) vram_lo[vram_addr] <= vram_wdata[7:0];
            if (vram_be[1]) vram_hi[vram_addr] <= vram_wdata[15:8];
        end
        vram_q <= {vram_hi[vram_addr], vram_lo[vram_addr]};
        `ROM_PORT(vram_req, vram_ack, cnt_vram, lat_vram)
    end

    gaia_core #(.HEXDIR("../rtl/data"), .STEP_COST_BUS(STEP_COST_BUS), .STEP_COST_INT(STEP_COST_INT)) u_core (
        .clk(clk), .reset(reset), .pix_sync(1'b0), .vid_reset(reset),
        .prog_req(prog_req), .prog_addr(prog_addr), .prog_ack(prog_ack), .prog_q(prog_q),
        .tile_req(tile_req), .tile_addr(tile_addr), .tile_ack(tile_ack), .tile_q(tile_q),
        .map_req(map_req), .map_addr(map_addr), .map_ack(map_ack), .map_q(map_q),
        .blk_req(blk_req), .blk_addr(blk_addr), .blk_wr(blk_wr), .blk_idx(blk_idx), .blk_data(blk_data), .blk_ack(blk_ack), .roz_lead(),
        .spr_req(spr_req), .spr_addr(spr_addr), .spr_ack(spr_ack), .spr_q(spr_q),
        .vram_req(vram_req), .vram_we(vram_we), .vram_addr(vram_addr), .vram_be(vram_be), .vram_wdata(vram_wdata),
        .vram_ack(vram_ack), .vram_q(vram_q),
        .snd_rom_req(srom_req), .snd_rom_addr(srom_addr), .snd_rom_ack(srom_ack), .snd_rom_q(srom_q),
        .pcm_req(pcmr_req), .pcm_addr(pcmr_addr), .pcm_ack(pcmr_ack), .pcm_q(pcmr_q),
        .eep_ld_we(eep_we), .eep_ld_addr(eep_waddr), .eep_ld_wdata(eep_wdata), .eep_ld_q(eep_q), .eep_dirty(eep_dirty),
        .in0_p1(in0_p1), .in1(in1), .p2(p2),
        .cen_pix(cen_pix), .rgb(rgb), .hsync(hsync), .vsync(vsync), .de(de), .vblank(vblank),
        .snd_l(snd_l), .snd_r(snd_r), .snd_valid(snd_valid),
        .dbg_addr(dbg_addr), .dbg_data(dbg_data), .dbg_busstate(dbg_busstate), .dbg_step(dbg_step), .dbg_irq5(dbg_irq5),
        .dbg_overrun(dbg_overrun), .dbg_overrun_src(dbg_overrun_src), .dbg_draw_objs(dbg_draw_objs), .dbg_draw_rows(dbg_draw_rows), .dbg_draw_cols(dbg_draw_cols), .dbg_draw_pxw(dbg_draw_pxw), .dbg_spr_we(dbg_spr_we), .dbg_roz_en(dbg_roz_en), .dbg_rozctrl(dbg_rozctrl), .dbg_rozclip(dbg_rozclip), .dbg_k55(dbg_k55), .dbg_unsupported(dbg_unsupported), .dbg_shadow_overlap(dbg_shadow_overlap),
        .dbg_objcount(dbg_objcount), .dbg_vcount(dbg_vcount), .dbg_zpc(dbg_zpc), .dbg_zstep(dbg_zstep), .dbg_zwait(dbg_zwait),
        .dbg_zwr(dbg_zwr), .dbg_zrd(dbg_zrd), .dbg_zwdata(dbg_zwdata)
    );
    /* verilator lint_off UNUSEDSIGNAL */
    wire unused = ^{eep_q, eep_dirty};
    /* verilator lint_on UNUSEDSIGNAL */
endmodule
