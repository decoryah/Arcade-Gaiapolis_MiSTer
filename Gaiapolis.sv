//============================================================================
//
//  Konami "pre-GX" GX123 arcade board -- Gaiapolis (1993) -- for MiSTer.
//
//  The machine (rtl/) is the Gaiapolis core written for the Analogue Pocket by
//  plasticbugs (https://github.com/plasticbugs/analogue-pocket-gaiapolis);
//  this is its MiSTer platform layer: memory (target/mister), clocks, video,
//  audio, controls and ROM/NVRAM loading through the MiSTer framework.
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 3 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//============================================================================

module emu
(
	`include "sys/emu_ports.vh"
);

///////// Default values for ports not used in this core /////////

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;

assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

assign AUDIO_S   = 1;       // signed samples
assign AUDIO_MIX = 0;

assign LED_DISK  = 0;
assign LED_POWER = 0;
assign BUTTONS   = 0;

//////////////////////////////////////////////////////////////////

wire [127:0] status;
wire   [1:0] buttons;
wire         forced_scandoubler;
wire         direct_video;
wire  [21:0] gamma_bus;
wire         video_rotated;

wire        no_rotate  = status[2] | direct_video;
wire  [1:0] ar         = status[122:121];

assign VIDEO_ARX = (!ar) ? (no_rotate ? 13'd4 : 13'd3) : (ar - 1'd1);
assign VIDEO_ARY = (!ar) ? (no_rotate ? 13'd3 : 13'd4) : 13'd0;

`include "build_id.v"
localparam CONF_STR = {
	"A.GAIAPOLIS;;",
	"-;",
	"O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"H0O[2],Orientation,Vert,Horz;",
	"H0O[11],Rotation,CW,CCW;",
	"O[12],Flip Screen,Off,On;",
	"O[5:3],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	"-;",
	"O[6],Test Mode,Off,On;",
	"O[8],Audio,Stereo,Mono;",
	"-;",
	"O[9],Diagnostic overlay,Off,On;",
	"O[10],SDRAM read capture,Normal,Late;",
	"-;",
	"R0,Reset;",
	"J1,Button 1,Button 2,Button 3,Start,Coin;",
	"jn,A,B,R,Start,Select;",
	"V,v",`BUILD_DATE
};

////////////////////   CLOCKS   ///////////////////

wire clk_sys;           // 96 MHz: the whole machine
wire clk_sdram;         // 96 MHz, shifted: the SDRAM chip's clock pin
wire pll_locked;

pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.outclk_1(clk_sdram),
	.locked(pll_locked)
);

///////////////////////////////////////////////////

wire         ioctl_download;
wire         ioctl_upload;
wire         ioctl_wr;
wire  [15:0] ioctl_index;
wire  [26:0] ioctl_addr;
wire   [7:0] ioctl_dout;
wire   [7:0] ioctl_din;
wire         ioctl_rd;
wire         ioctl_wait;
reg          ioctl_upload_req;

wire  [31:0] joystick_0, joystick_1;
wire  [10:0] ps2_key;

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),

	.buttons(buttons),
	.status(status),
	.status_menumask({15'd0, direct_video}),
	.forced_scandoubler(forced_scandoubler),
	.video_rotated(video_rotated),
	.direct_video(direct_video),
	.gamma_bus(gamma_bus),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait),
	.ioctl_upload(ioctl_upload),
	.ioctl_upload_req(ioctl_upload_req),
	.ioctl_upload_index(8'd2),
	.ioctl_din(ioctl_din),
	.ioctl_rd(ioctl_rd),

	.joystick_0(joystick_0),
	.joystick_1(joystick_1),
	.ps2_key(ps2_key)
);

///////////////////////   CONTROLS   ///////////////////////

// keyboard: 1/2 start, 5/6 coin, F2 test (MAME's defaults)
reg key_start1, key_start2, key_coin1, key_coin2, key_test;
always @(posedge clk_sys) begin
	reg old_stb;
	old_stb <= ps2_key[10];
	if (old_stb != ps2_key[10]) begin
		case (ps2_key[7:0])
			8'h16: key_start1 <= ps2_key[9];
			8'h1E: key_start2 <= ps2_key[9];
			8'h2E: key_coin1  <= ps2_key[9];
			8'h36: key_coin2  <= ps2_key[9];
			8'h06: key_test   <= ps2_key[9];
			default: ;
		endcase
	end
end

// joystick bits: 0 right, 1 left, 2 down, 3 up, 4-6 buttons 1-3, 7 start, 8 coin
wire j1_r = joystick_0[0], j1_l = joystick_0[1], j1_d = joystick_0[2], j1_u = joystick_0[3];
wire j1_b1 = joystick_0[4], j1_b2 = joystick_0[5], j1_b3 = joystick_0[6];
wire j1_start = joystick_0[7] | key_start1, j1_coin = joystick_0[8] | key_coin1;
wire j2_r = joystick_1[0], j2_l = joystick_1[1], j2_d = joystick_1[2], j2_u = joystick_1[3];
wire j2_b1 = joystick_1[4], j2_b2 = joystick_1[5], j2_b3 = joystick_1[6];
wire j2_start = joystick_1[7] | key_start2, j2_coin = joystick_1[8] | key_coin2;

// the board's inputs, active low (docs/hardware.md section 8):
//   IN0_P1: bit0 L, 1 R, 2 U, 3 D, 4-6 buttons 1-3, 7 start1, 8 coin1, 9 coin2, 11 test switch
//   P2: the same low byte
//   IN1: bit3 test (low = on), bit4 mono (0 = stereo), bit5 flip (1 = off, held: the tilemap renderer has no global flip); bits 1:0 are the EEPROM
//        pins, bit2 an unassigned input the game polls for 0 after the self-test
wire        test_sw = status[6] | key_test;
wire [15:0] in0_p1  = ~{2'b00, 1'b0, 1'b0, test_sw, 1'b0, j2_coin, j1_coin,
                        j1_start, j1_b3, j1_b2, j1_b1, j1_d, j1_u, j1_r, j1_l};
wire  [7:0] p2      = ~{j2_start, j2_b3, j2_b2, j2_b1, j2_d, j2_u, j2_r, j2_l};
wire  [7:0] in1     = {2'b11, 1'b1, status[8], ~test_sw, 1'b0, 2'b11};      // bit 5, flip: off (see the OSD note)

///////////////////////   MEMORIES   ///////////////////////

// the ROM image: MRA index 0
wire        rom_dl   = ioctl_download && (ioctl_index[7:0] == 8'd0);
wire        dl_we    = rom_dl && ioctl_wr;
// the EEPROM: its default (MRA index 2) and the saved file
wire        nv_dl_we = ioctl_download && (ioctl_index[7:0] == 8'd2) && ioctl_wr;

reg   rom_dl_d;
always @(posedge clk_sys) rom_dl_d <= rom_dl;
wire  dl_start = rom_dl && !rom_dl_d;
wire  dl_done  = !rom_dl && rom_dl_d;

wire        mem_init = ~pll_locked | RESET;

wire        mem_ready, test_run, test_done, vram_ok;
wire  [6:0] test_ok, test_stable;
wire  [3:0] vram_bad;

// the built-in memory test: only with the diagnostic overlay on, at the end of a load
reg   test_start, test_hold;
always @(posedge clk_sys) begin
	test_start <= dl_done && status[9];
	if (test_start) test_hold <= 1'b1;
	else if (test_done) test_hold <= 1'b0;
end

wire        prog_req, prog_ack, tile_req, tile_ack, map_req, map_ack, spr_req, spr_ack;
wire        blk_req, blk_wr, blk_ack; wire [15:0] blk_addr, blk_data; wire [5:0] blk_idx; wire [3:0] roz_lead;
wire        snd_req, snd_ack, pcm_req, pcm_ack;
wire [22:1] prog_addr; wire [18:0] tile_addr; wire [19:0] map_addr; wire [19:0] spr_addr;
wire [17:0] snd_addr; wire [21:0] pcm_addr;
wire [15:0] prog_q, map_q; wire [31:0] tile_q; wire [63:0] spr_q; wire [7:0] snd_q, pcm_q;
wire        vram_req, vram_we, vram_ack; wire [15:0] vram_addr, vram_wdata, vram_q; wire [1:0] vram_be;

wire        ddr_rd, ddr_we, ddr_busy, ddr_dready;
wire [24:0] ddr_addr; wire [7:0] ddr_burst, ddr_be; wire [63:0] ddr_din, ddr_dout;

wire        dram_cke;
wire  [1:0] dram_dqm;

gaia_mem u_mem
(
	.clk(clk_sys), .clk_sdram(clk_sdram), .init(mem_init), .dl_start(dl_start), .ready(mem_ready),
	.test_start(test_start), .test_run(test_run), .test_done(test_done), .test_ok(test_ok), .test_stable(test_stable),
	.vram_ok(vram_ok), .vram_bad(vram_bad),
	.rd_late(status[10]), .burst_slow(1'b0),
	.dl_we(dl_we), .dl_addr(ioctl_addr[24:0]), .dl_data(ioctl_dout), .dl_wait(ioctl_wait),
	.prog_req(prog_req), .prog_addr(prog_addr), .prog_ack(prog_ack), .prog_q(prog_q),
	.tile_req(tile_req), .tile_addr(tile_addr), .tile_ack(tile_ack), .tile_q(tile_q),
	.map_req(map_req), .map_addr(map_addr), .map_ack(map_ack), .map_q(map_q),
	.blk_req(blk_req), .blk_addr(blk_addr), .blk_wr(blk_wr), .blk_idx(blk_idx), .blk_data(blk_data), .blk_ack(blk_ack),
	.roz_lead(roz_lead),
	.spr_req(spr_req), .spr_addr(spr_addr), .spr_ack(spr_ack), .spr_q(spr_q),
	.snd_req(snd_req), .snd_addr(snd_addr), .snd_ack(snd_ack), .snd_q(snd_q),
	.pcm_req(pcm_req), .pcm_addr(pcm_addr), .pcm_ack(pcm_ack), .pcm_q(pcm_q),
	.vram_req(vram_req), .vram_we(vram_we), .vram_addr(vram_addr), .vram_be(vram_be), .vram_wdata(vram_wdata),
	.vram_ack(vram_ack), .vram_q(vram_q),
	.dram_dq(SDRAM_DQ), .dram_a(SDRAM_A), .dram_ba(SDRAM_BA), .dram_dqm(dram_dqm),
	.dram_clk(SDRAM_CLK), .dram_cke(dram_cke), .dram_ras_n(SDRAM_nRAS), .dram_cas_n(SDRAM_nCAS), .dram_we_n(SDRAM_nWE),
	.ddr_rd(ddr_rd), .ddr_we(ddr_we), .ddr_addr(ddr_addr), .ddr_burst(ddr_burst), .ddr_din(ddr_din), .ddr_be(ddr_be),
	.ddr_busy(ddr_busy), .ddr_dout(ddr_dout), .ddr_dready(ddr_dready)
);
assign SDRAM_CKE  = dram_cke;
assign SDRAM_nCS  = 1'b0;
assign {SDRAM_DQMH, SDRAM_DQML} = dram_dqm;

// DDR3: the core's ROZ client, the rotated frame buffer's writes, and Flip Screen's frame buffers
wire        rot_we;
wire [28:0] rot_addr;
wire [63:0] rot_din;
wire  [7:0] rot_be;
wire        ddr_overflow;
wire        fb_we, fl_rd, fl_busy, fl_dready;       // flip_buf: frame writes (they join screen_rotate's FIFO) and line reads
wire [28:0] fb_addr;
wire [63:0] fb_din;
wire [24:0] fl_addr;
wire  [7:0] fl_burst;

ddr_arb u_ddr
(
	.clk(clk_sys), .reset(~pll_locked),
	.c_rd(ddr_rd), .c_we(ddr_we), .c_addr(ddr_addr), .c_burst(ddr_burst), .c_din(ddr_din), .c_be(ddr_be),
	.c_busy(ddr_busy), .c_dout(ddr_dout), .c_dready(ddr_dready),
	.r_we(rot_we | fb_we), .r_addr(fb_we ? fb_addr : rot_addr), .r_din(fb_we ? fb_din : rot_din), .r_be(fb_we ? 8'hFF : rot_be),
	.f_rd(fl_rd), .f_addr(fl_addr), .f_burst(fl_burst), .f_busy(fl_busy), .f_dready(fl_dready),
	.DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(DDRAM_BURSTCNT), .DDRAM_ADDR(DDRAM_ADDR),
	.DDRAM_DOUT(DDRAM_DOUT), .DDRAM_DOUT_READY(DDRAM_DOUT_READY),
	.DDRAM_RD(DDRAM_RD), .DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE), .DDRAM_WE(DDRAM_WE),
	.overflow(ddr_overflow)
);
assign DDRAM_CLK = clk_sys;

///////////////////////   THE MACHINE   ///////////////////////

wire        reset_sw  = RESET | status[0] | buttons[1];
// the machine's reset is registered: it fans out to the whole core, including the
// Z80's asynchronous reset, and the OR of its sources in front of that fan-out
// was the tightest recovery path of the first fits
wire        ga_reset_c = reset_sw | ioctl_download | ~mem_ready | test_hold | test_run;
reg         ga_reset = 1'b1;
always @(posedge clk_sys) ga_reset <= ga_reset_c;

// the EEPROM port: the default and the saved file in, the upload out
wire        eep_dirty;
wire  [7:0] eep_q;
wire        eep_we    = nv_dl_we;
wire  [6:0] eep_addr  = ioctl_addr[6:0];
wire  [7:0] eep_wdata = ioctl_dout;
assign      ioctl_din = eep_q;

wire        ga_cen_pix, ga_hs, ga_vs, ga_de, ga_vb;
wire [23:0] ga_rgb;
wire [15:0] ga_snd_l, ga_snd_r;
wire        ga_snd_valid;
wire [23:0] dbg_addr; wire [15:0] dbg_data; wire [1:0] dbg_busstate; wire [9:0] dbg_objcount; wire [8:0] dbg_vcount;
wire [15:0] dbg_zpc;
wire        dbg_step, dbg_irq5, dbg_overrun, dbg_unsupported, dbg_shadow_overlap, dbg_zstep, dbg_zwait;
wire  [2:0] dbg_overrun_src;

gaia_core #(.HEXDIR("rtl/data")) ga
(
	.clk(clk_sys), .reset(ga_reset), .pix_sync(1'b0), .vid_reset(~pll_locked),
	.prog_req(prog_req), .prog_addr(prog_addr), .prog_ack(prog_ack), .prog_q(prog_q),
	.tile_req(tile_req), .tile_addr(tile_addr), .tile_ack(tile_ack), .tile_q(tile_q),
	.map_req(map_req), .map_addr(map_addr), .map_ack(map_ack), .map_q(map_q),
	.blk_req(blk_req), .blk_addr(blk_addr), .blk_wr(blk_wr), .blk_idx(blk_idx), .blk_data(blk_data), .blk_ack(blk_ack), .roz_lead(roz_lead),
	.spr_req(spr_req), .spr_addr(spr_addr), .spr_ack(spr_ack), .spr_q(spr_q),
	.vram_req(vram_req), .vram_we(vram_we), .vram_addr(vram_addr), .vram_be(vram_be), .vram_wdata(vram_wdata),
	.vram_ack(vram_ack), .vram_q(vram_q),
	.snd_rom_req(snd_req), .snd_rom_addr(snd_addr), .snd_rom_ack(snd_ack), .snd_rom_q(snd_q),
	.pcm_req(pcm_req), .pcm_addr(pcm_addr), .pcm_ack(pcm_ack), .pcm_q(pcm_q),
	.eep_ld_we(eep_we), .eep_ld_addr(eep_addr), .eep_ld_wdata(eep_wdata), .eep_ld_q(eep_q), .eep_dirty(eep_dirty),
	.in0_p1(in0_p1), .in1(in1), .p2(p2),
	.cen_pix(ga_cen_pix), .rgb(ga_rgb), .hsync(ga_hs), .vsync(ga_vs), .de(ga_de), .vblank(ga_vb),
	.snd_l(ga_snd_l), .snd_r(ga_snd_r), .snd_valid(ga_snd_valid),
	.dbg_addr(dbg_addr), .dbg_data(dbg_data), .dbg_busstate(dbg_busstate), .dbg_step(dbg_step), .dbg_irq5(dbg_irq5),
	.dbg_overrun(dbg_overrun), .dbg_overrun_src(dbg_overrun_src), .dbg_draw_objs(), .dbg_draw_rows(), .dbg_draw_cols(), .dbg_draw_pxw(),
	.dbg_spr_we(), .dbg_roz_en(), .dbg_rozctrl(), .dbg_rozclip(), .dbg_k55(),
	.dbg_unsupported(dbg_unsupported), .dbg_shadow_overlap(dbg_shadow_overlap),
	.dbg_objcount(dbg_objcount), .dbg_vcount(dbg_vcount), .dbg_zpc(dbg_zpc), .dbg_zstep(dbg_zstep), .dbg_zwait(dbg_zwait),
	.dbg_zwr(), .dbg_zrd(), .dbg_zwdata()
);

// NVRAM: ask the HPS to save the EEPROM a second after the game's last write
reg        old_dirty;
reg [26:0] save_timer;
always @(posedge clk_sys) begin
	ioctl_upload_req <= 1'b0;
	old_dirty <= eep_dirty;
	if (ga_reset) save_timer <= 0;
	else if (old_dirty != eep_dirty) save_timer <= 27'd96_000_000;
	else if (save_timer != 0) begin
		save_timer <= save_timer - 1'd1;
		if (save_timer == 27'd1) ioctl_upload_req <= 1'b1;
	end
end

///////////////////////   DIAGNOSTIC OVERLAY   ///////////////////////
// The bottom twelve lines show three rows of 32 squares, green = 1 (as on the
// Pocket; rtl/dbg_overlay.sv). The raster runs even while the machine is held
// in reset, so a black screen can still be read:
//   row 0  frame count[7:0] | pll locked, sdram+cache ready, download, test hold, 0, core reset, irq5, 68000 stepped |
//          core resets seen | test done, test running, tile RAM ok, tile RAM bad words (4), Z80 stepped
//   row 1  68000 bus address[23:0] | region read back ok: prog, snd, tile, chr, map, pcm, spr | sound heard
//   row 2  region read stable (7), ddr rotate-FIFO overflow | lines overrun last frame (8) |
//          sprites in the list / 4 (8) | unsupported mode met, second shadow on a pixel, 0, 0, flip line underrun, which renderers overran
reg  [7:0] ovl_frames, ovl_resets, ovl_overruns, ovl_overruns_l;
reg  [2:0] ovl_ovsrc, ovl_ovsrc_l;
reg        ovl_ovr_d, ovl_vs_d, ovl_rst_d, ovl_seen_step, ovl_seen_zstep, ovl_seen_snd, ovl_unsup, ovl_shadow, ovl_unsup_l, ovl_shadow_l;
reg        ovl_funder, ovl_funder_l;
always @(posedge clk_sys) begin
	ovl_vs_d <= ga_vs; ovl_rst_d <= ga_reset;
	if (ga_reset && !ovl_rst_d) ovl_resets <= ovl_resets + 8'd1;
	if (ga_vs && !ovl_vs_d) begin
		ovl_frames <= ovl_frames + 8'd1;
		ovl_seen_step <= 1'b0; ovl_seen_zstep <= 1'b0; ovl_seen_snd <= 1'b0;
		ovl_overruns_l <= ovl_overruns; ovl_overruns <= 8'd0;
		ovl_ovsrc_l <= ovl_ovsrc; ovl_ovsrc <= 3'd0;
		ovl_unsup_l <= ovl_unsup; ovl_unsup <= 1'b0; ovl_shadow_l <= ovl_shadow; ovl_shadow <= 1'b0;
			ovl_funder_l <= ovl_funder; ovl_funder <= 1'b0;
	end
	ovl_ovr_d <= dbg_overrun;
	if (dbg_overrun && !ovl_ovr_d && ovl_overruns != 8'hff) ovl_overruns <= ovl_overruns + 8'd1;
	if (dbg_overrun && !ovl_ovr_d) ovl_ovsrc <= ovl_ovsrc | dbg_overrun_src;
	if (dbg_unsupported)    ovl_unsup  <= 1'b1;
	if (dbg_shadow_overlap) ovl_shadow <= 1'b1;
	if (fb_underrun)        ovl_funder <= 1'b1;
	if (dbg_step)  ovl_seen_step  <= 1'b1;
	if (dbg_zstep) ovl_seen_zstep <= 1'b1;
	if (ga_snd_valid && (ga_snd_l != 16'd0)) ovl_seen_snd <= 1'b1;
end
wire [95:0] ovl_status = {
	ovl_frames, pll_locked, mem_ready, ioctl_download, test_hold, 1'b0, ga_reset, dbg_irq5, ovl_seen_step,
	ovl_resets, test_done, test_run, vram_ok, vram_bad, ovl_seen_zstep,
	dbg_addr, test_ok[0], test_ok[1], test_ok[2], test_ok[3], test_ok[4], test_ok[5], test_ok[6], ovl_seen_snd,
	test_stable[0], test_stable[1], test_stable[2], test_stable[3], test_stable[4], test_stable[5], test_stable[6], ddr_overflow,
	ovl_overruns_l, dbg_objcount[9:2], ovl_unsup_l, ovl_shadow_l, 2'd0, ovl_funder_l, ovl_ovsrc_l
};
wire [7:0] ovl_r, ovl_g, ovl_b;
dbg_overlay ovl
(
	.clk(clk_sys), .cen_pix(ga_cen_pix), .enable(status[9]), .de(ga_de), .vsync(ga_vs),
	.r_in(ga_rgb[23:16]), .g_in(ga_rgb[15:8]), .b_in(ga_rgb[7:0]),
	.status(ovl_status), .r_out(ovl_r), .g_out(ovl_g), .b_out(ovl_b)
);

///////////////////////   AUDIO   ///////////////////////

reg [15:0] aud_l, aud_r;
always @(posedge clk_sys) if (ga_snd_valid) begin aud_l <= ga_snd_l; aud_r <= ga_snd_r; end
assign AUDIO_L = aud_l;
assign AUDIO_R = status[8] ? aud_l : aud_r;      // mono: the left mix on both

///////////////////////   VIDEO   ///////////////////////

// the core emits one pixel per 8 MHz enable on the 96 MHz clock and holds it
// for the twelve clocks; its de is the visible rectangle, its vblank the
// vertical blanking, so HBlank follows de and is high through the vertical blank
wire hblank_c = ~ga_de;

// Flip Screen: the finished picture (overlay included) turned 180 degrees, one frame late, through
// two frame buffers in the DDR3; the picture is untouched when it is off (target/mister/flip_buf.sv)
wire [23:0] flip_rgb;
wire        fb_underrun;
flip_buf u_flip
(
	.clk(clk_sys), .cen(ga_cen_pix), .flip_en(status[12]),
	.rgb_i({ovl_r, ovl_g, ovl_b}), .de_i(ga_de), .vs_i(ga_vs), .rgb_o(flip_rgb),
	.wr_hold(rot_we), .wr_we(fb_we), .wr_addr(fb_addr), .wr_din(fb_din),
	.rd_req(fl_rd), .rd_addr(fl_addr), .rd_burst(fl_burst), .rd_busy(fl_busy), .rd_data(ddr_dout), .rd_ready(fl_dready),
	.underrun(fb_underrun)
);

arcade_video #(.WIDTH(376), .DW(24), .GAMMA(1)) arcade_video
(
	.clk_video(clk_sys),
	.ce_pix(ga_cen_pix),
	.RGB_in(flip_rgb),
	.HBlank(hblank_c),
	.VBlank(ga_vb),
	.HSync(ga_hs),
	.VSync(ga_vs),

	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B),
	.VGA_HS(VGA_HS), .VGA_VS(VGA_VS), .VGA_DE(VGA_DE),
	.VGA_SL(VGA_SL),

	.fx(status[5:3]),
	.forced_scandoubler(forced_scandoubler),
	.gamma_bus(gamma_bus)
);

// the cabinet's monitor is on its side: rotate the picture into a frame buffer
// in DDR3 that the scaler reads (the framework's screen_rotate)
wire rotate_ccw = status[11];
wire fb_ddr_clk, fb_busy_unused, fb_rd_unused;
wire [7:0] fb_burst_unused;
screen_rotate screen_rotate
(
	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B),
	.VGA_HS(VGA_HS), .VGA_VS(VGA_VS), .VGA_DE(VGA_DE),

	.rotate_ccw(rotate_ccw),
	.no_rotate(no_rotate),
	.flip(1'b0),
	.video_rotated(video_rotated),

	.FB_EN(FB_EN),
	.FB_FORMAT(FB_FORMAT),
	.FB_WIDTH(FB_WIDTH),
	.FB_HEIGHT(FB_HEIGHT),
	.FB_BASE(FB_BASE),
	.FB_STRIDE(FB_STRIDE),
	.FB_VBL(FB_VBL),
	.FB_LL(FB_LL),

	.DDRAM_CLK(fb_ddr_clk),
	.DDRAM_BUSY(DDRAM_BUSY),
	.DDRAM_BURSTCNT(fb_burst_unused),
	.DDRAM_ADDR(rot_addr),
	.DDRAM_DIN(rot_din),
	.DDRAM_BE(rot_be),
	.DDRAM_WE(rot_we),
	.DDRAM_RD(fb_rd_unused)
);
assign FB_FORCE_BLANK = 1'b0;

///////////////////////   LED   ///////////////////////

reg [26:0] act_cnt;
always @(posedge clk_sys) act_cnt <= act_cnt + 1'd1;
assign LED_USER = ga_reset ? act_cnt[24] : ~dbg_irq5 | act_cnt[26];

endmodule
