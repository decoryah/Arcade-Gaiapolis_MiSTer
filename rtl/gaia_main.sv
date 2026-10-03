//------------------------------------------------------------------------------
// Gaiapolis main board: 68000 @ 16 MHz and everything on its bus.
//
// Address decode follows docs/hardware.md section 3 (gaiapols_map). The CPU
// is TG68K.C, paced by a token bucket the way the S.T.U.N. Runner core paces
// its 68010 -- STEP_COST_BUS/STEP_COST_INT/STEP_GAIN set the step rate; the
// values are calibrated against MAME's frame timing (docs/hardware.md
// section 10, "68000 pacing").
//
// What lives here: work RAM, K056832 tile RAM (all 16 pages, one visible
// through the banked window), palette, sprite RAM through the K053247's
// scattered window, the ROZ control block and line RAM, and the register
// files of every video chip, exported to the renderers. Renderers read the
// memories through their own ports.
//
// All five ROM-readback windows are real. The self-test checksums every
// graphics ROM through them, and the full-system bench showed what a stub
// costs: with 440000/450000 returning 0 the DATA ROM item failed and the test
// re-ran it forever. They share the renderers' ROM ports through arbiters
// that give the renderer priority.
//   440000  K056832 mw_rom_word_r: bank regs[0x1a]|regs[0x1b]<<16 (mod 256)
//           selects 2048 four-byte groups; a word is one half of a group.
//           regsb[2] bit 3 asks for the fifth plane, which this ROM set does
//           not populate, so that reads 0.
//   450000  K055673 rom_word_r (4bpp): a 16-bit little-endian view of the
//           sprite ROM at the offset in k053246 regs 6/7/4.
//------------------------------------------------------------------------------
`default_nettype none

module gaia_main #(
    parameter int STEP_COST_BUS = 16, // tokens per kernel step that runs a bus cycle: 4 clocks, as the 68000's
    parameter int STEP_COST_INT = 8,  // tokens per internal step: 2 clocks
    parameter int STEP_GAIN = 4       // tokens per cen_16m: 4 tokens = one 16 MHz clock
) (
    input  logic        clk,
    input  logic        reset,
    input  logic        cen_16m,

    // program ROM, 3 MB
    output logic        rom_req,
    output logic [22:1] rom_addr,
    input  logic        rom_ack,
    input  logic [15:0] rom_q,

    // ROZ ROMs for the readback windows (shared with the renderer's ports)
    output logic        map_req,
    output logic [19:0] map_addr,
    input  logic        map_ack,
    input  logic [15:0] map_q,
    output logic        chr_req,
    output logic [20:0] chr_addr,
    input  logic        chr_ack,
    input  logic [15:0] chr_q,
    // tile ROM (K056832 readback) and sprite ROM (K055673 readback)
    output logic        trom_req,
    output logic [18:0] trom_addr,
    input  logic        trom_ack,
    input  logic [31:0] trom_q,
    output logic        srom_req,
    output logic [19:0] srom_addr,
    input  logic        srom_ack,
    input  logic [63:0] srom_q,

    // vblank interrupt (IRQ5, held until acknowledged)
    input  logic        vblank_rise,

    // inputs, active low as the board sees them. in1[1:0] are replaced by the
    // EEPROM's DO and READY lines on the way in (dddeeprom_r).
    input  logic [15:0] in0_p1,
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic  [7:0] in1,
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic  [7:0] p2,

    // ER5911 serial EEPROM
    output logic        eep_di,
    output logic        eep_cs,
    output logic        eep_clk,
    input  logic        eep_do,
    input  logic        eep_ready,

    // K054321 main side: byte registers at word offsets 0..15
    output logic        snd_wr,
    output logic        snd_rd,
    output logic  [3:0] snd_off,
    output logic  [7:0] snd_wdata,
    input  logic  [7:0] snd_rdata,
    output logic        snd_irq,        // 6E0000 write: Z80 IRQ0

    // K054000 collision chip: byte registers at word offsets 0..31
    output logic        col_wr,
    output logic        col_rd,
    output logic  [4:0] col_off,
    output logic  [7:0] col_wdata,
    input  logic  [7:0] col_rdata,

    // video chip register files
    output logic [15:0] k56regs  [32],
    output logic [15:0] k56regsb [4],
    output logic  [7:0] k55regs  [48],
    output logic [15:0] k38regs  [16],
    output logic [15:0] rozctrl  [16],
    output logic [15:0] rozclip  [2],
    output logic        roz_enable,
    output logic  [1:0] roz_rombank,
    output logic  [7:0] k46regs  [8],
    output logic [15:0] k47regs  [8],

    // memories the renderers read
    // tile RAM lives outside (the Pocket's SRAM); the CPU window's accesses
    // go out as request/ack, writes byte-enabled, and the kernel waits for them
    output logic        vc_req,
    output logic        vc_we,
    output logic [15:0] vc_addr,
    output logic  [1:0] vc_be,
    output logic [15:0] vc_wdata,
    input  logic        vc_ack,
    input  logic [15:0] vc_q,
    input  logic [10:0] sram_raddr,
    output logic [15:0] sram_q,
    input  logic [10:0] pal_raddr,
    output logic [23:0] pal_q,

    // diagnostics
    output logic [23:0] dbg_addr,
    output logic [15:0] dbg_data,       // data_in of the last completed read
    output logic  [1:0] dbg_busstate,
    output logic        dbg_step,
    output logic        dbg_irq5,
    output logic        dbg_spr_we           // a CPU write into the sprite RAM (benches)
);
    // ------------------------------------------------------------ TG68K
    logic        clkena;
    logic [15:0] data_in;
    logic  [2:0] ipl_n;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [31:0] addr_out;   // a 68000 has 24 address lines and no A0
    /* verilator lint_on UNUSEDSIGNAL */
    logic [15:0] data_write;
    logic        nWr, nUDS, nLDS;
    logic  [1:0] busstate;
    logic        nResetOut;
    logic [31:0] regin_out, vbr_out;
    logic  [3:0] cacr_out;
    logic  [2:0] fc;
    logic        longword, clr_berr, skipFetch;
    logic  [2:0] step_gap;

    TG68KdotC_Kernel cpu (
        .clk            ( clk ),
        .nReset         ( ~reset ),
        .clkena_in      ( clkena ),
        .data_in        ( data_in ),
        .IPL            ( ipl_n ),
        .IPL_autovector ( 1'b1 ),
        .berr           ( 1'b0 ),
        .CPU            ( 2'b00 ),          // 68000
        .addr_out       ( addr_out ),
        .data_write     ( data_write ),
        .nWr            ( nWr ),
        .nUDS           ( nUDS ),
        .nLDS           ( nLDS ),
        .busstate       ( busstate ),
        .longword       ( longword ),
        .nResetOut      ( nResetOut ),
        .FC             ( fc ),
        .clr_berr       ( clr_berr ),
        .skipFetch      ( skipFetch ),
        .regin_out      ( regin_out ),
        .CACR_out       ( cacr_out ),
        .VBR_out        ( vbr_out )
    );

    wire [23:1] A     = addr_out[23:1];
    wire        is_wr = (busstate == 2'b11);
    wire  [5:0] step_cost = (busstate == 2'b01 || skipFetch) ? 6'(STEP_COST_INT) : 6'(STEP_COST_BUS);
    wire        uds   = ~nUDS;             // D15:8
    wire        lds   = ~nLDS;             // D7:0
    assign dbg_addr     = {addr_out[23:1], 1'b0};
    assign dbg_data     = data_in;
    assign dbg_busstate = busstate;

    // --------------------------------------------------------- decode
    wire sel_rom    = (A[23:20] <= 4'h2);                       // 000000-2fffff
    wire sel_sprwin = (A[23:16] == 8'h40);                      // 400000-40ffff
    wire sel_vram   = (A[23:14] == 10'b0100_0001_00);           // 410000-413fff (mirror at 412000)
    wire sel_pal    = (A[23:13] == 11'b0100_0010_000);          // 420000-421fff
    wire sel_k46    = (A[23:3]  == 21'h086000);                 // 430000-430007
    wire sel_tmrb   = (A[23:13] == 11'b0100_0100_000);          // 440000-441fff  tile ROM readback
    wire sel_sprrb  = (A[23:4]  == 20'h45000);                  // 450000-45000f  sprite ROM readback
    wire sel_k47    = (A[23:4]  == 20'h45001);                  // 450010-45001f
    wire sel_rozct  = (A[23:5]  == 19'h23000);                  // 460000-46001f
    wire sel_rozli  = (A[23:12] == 12'h470);                    // 470000-470fff
    wire sel_vacset = (A[23:6]  == 18'h12000);                  // 480000-48003f
    wire sel_vsccs  = (A[23:3]  == 21'h090400);                 // 482000-482007
    wire sel_clip   = (A[23:2]  == 22'h121000);                 // 484000-484003
    wire sel_k252   = (A[23:5]  == 19'h24300);                  // 486000-48601f
    wire sel_k555   = (A[23:8]  == 16'h4880);                   // 488000-4880ff
    wire sel_k321   = (A[23:5]  == 19'h24500);                  // 48a000-48a01f
    wire sel_k338   = (A[23:5]  == 19'h24600);                  // 48c000-48c01f
    wire sel_in0    = (A[23:1]  == 23'h247000);                 // 48e000
    wire sel_in1    = (A[23:1]  == 23'h247010);                 // 48e020
    wire sel_wram   = (A[23:16] == 8'h60);                      // 600000-60ffff
    wire sel_k000   = (A[23:6]  == 18'h19800);                  // 660000-66003f
    wire sel_eep    = (A[23:1]  == 23'h350000);                 // 6a0000
    wire sel_rozen  = (A[23:1]  == 23'h360000);                 // 6c0000
    wire sel_sndirq = (A[23:1]  == 23'h370000);                 // 6e0000
    wire sel_rb0    = (A[23:19] == 5'b1000_0);                  // 800000-87ffff
    wire sel_rb1    = (A[23:19] == 5'b1010_0);                  // a00000-a7ffff
    wire sel_rb2    = (A[23:21] == 3'b110);                     // c00000-dfffff
    /* verilator lint_off UNUSEDSIGNAL */
    wire sel_wdog   = (A[23:1]  == 23'h700000);                 // e00000: decoded, deliberately ignored
    /* verilator lint_on UNUSEDSIGNAL */

    // -------------------------------------------------------- memories
    // work RAM 32K x 16, byte lanes
    logic [1:0][7:0] wram [32768];
    logic [15:0] wram_q;
    // K056832 tile RAM, 16 pages x 4096 words; CPU sees the selected page
    // palette 2048 x {word0, word1}; word0 = 00RR, word1 = GGBB
    // palette: two 16-bit words per entry (00RR, GGBB), each a byte-enabled
    // RAM in Quartus's template form so it infers rather than becoming 64K
    // registers; the CPU and the mixer each read a copy
    logic [1:0][7:0] pal0 [2048];
    logic [1:0][7:0] pal1 [2048];
    logic [1:0][15:0] pal_cpu_q, pal_rd_q;
    logic        pal_we;
    logic [10:0] pal_waddr;
    logic  [1:0] pal_wsel;             // which word, {word1, word0}
    logic  [1:0] pal_wbe;              // {uds, lds}
    logic [15:0] pal_wdata;
    always_ff @(posedge clk) begin
        if (pal_we && pal_wsel[0]) begin
            if (pal_wbe[1]) pal0[pal_waddr][1] <= pal_wdata[15:8];
            if (pal_wbe[0]) pal0[pal_waddr][0] <= pal_wdata[7:0];
        end
        pal_cpu_q[0] <= pal0[A[12:2]];
        pal_rd_q[0]  <= pal0[pal_raddr];
    end
    always_ff @(posedge clk) begin
        if (pal_we && pal_wsel[1]) begin
            if (pal_wbe[1]) pal1[pal_waddr][1] <= pal_wdata[15:8];
            if (pal_wbe[0]) pal1[pal_waddr][0] <= pal_wdata[7:0];
        end
        pal_cpu_q[1] <= pal1[A[12:2]];
        pal_rd_q[1]  <= pal1[pal_raddr];
    end
    // sprite RAM 0x800 words behind the scattered window, plus the plain
    // 32K x 16 the rest of the 64 KB window lands in (the board has it, and
    // the self-test writes and reads all of it)
    logic [15:0] sram [2048] /*verilator public_flat_rd*/;
    logic [15:0] sram_cpu_q;
    logic [15:0] sshadow [32768];
    logic [15:0] sshadow_q;
    // ROZ line RAM
    logic [15:0] rozli [2048];
    logic [15:0] rozli_q;
    // K053252 bytes (kept so reads return what was written)
    logic  [7:0] k252 [16];

    // tile-RAM page select: regs[0x19] bits {4:3, 1:0}, or the external
    // linescroll page when regs[0] bit 1 is set (not fitted on this board)
    wire [3:0] vram_page = {k56regs[25][4:3], k56regs[25][1:0]};
    wire       vram_ext  = k56regs[0][1];
    wire [15:0] vram_cpu_addr = {vram_page, A[12:1]};

    // scattered sprite window: word w of the chip lives at
    // 400000 + ((w & 0x7f8) << 5) + (w & 7) * 2; the rest is shadow RAM.
    // MAME's test is (word offset & 0x78) == 0, i.e. A[7:4] all clear --
    // four bits, not three. With A[7] left out, two CPU addresses aliased
    // onto one chip word and the self-test marked both sprite-window RAMs bad.
    wire        spr_hit  = (A[7:4] == 4'd0);
    wire [10:0] spr_word = {A[15:8], A[3:1]};

    always_ff @(posedge clk) begin
        wram_q      <= wram[A[15:1]];
        sram_cpu_q  <= sram[spr_word];
        sshadow_q   <= sshadow[A[15:1]];
        sram_q      <= sram[sram_raddr];
        rozli_q     <= rozli[A[11:1]];
    end
    // xRGB888 across the two words: word0 = 00RR, word1 = GGBB
    assign pal_q = {pal_rd_q[0][7:0], pal_rd_q[1]};

    // ------------------------------------------------- bus sequencer
    typedef enum logic [3:0] {
        B_IDLE, B_RAM_RD, B_WAIT_ROM, B_WAIT_MAP0, B_WAIT_MAP0B, B_WAIT_MAP1, B_WAIT_CHR,
        B_WAIT_TROM, B_WAIT_SROM, B_WAIT_VRAM, B_WAIT_VRAMW
    } bst_t;
    bst_t bst;
    logic [5:0]  tok;
    logic        irq5_pend;
    logic [15:0] rd_mux;
    logic [7:0]  rb_hi;
    logic [15:0] in1_word;

    assign ipl_n    = irq5_pend ? 3'b010 : 3'b111;    // level 5

    // K056832 readback: 32-bit group index = bank * 2048 + (offset >> 1).
    // Only the low byte of the bank and the low 22 bits of the sprite word
    // index can address the ROMs fitted; the rest of each register is ignored.
    /* verilator lint_off UNUSEDSIGNAL */
    wire [23:0] tile_bank32 = {k56regs[27][7:0], k56regs[26]};      // regs[0x1b]<<16 | regs[0x1a]
    wire  [7:0] tile_bank   = tile_bank32[7:0];                    // mod 256 banks
    wire [18:0] trom_group  = {tile_bank, A[12:2]};
    wire        tile_plane5 = k56regsb[2][3];
    // K055673 readback: 16-bit word index from k053246 regs 6/7/4
    wire [23:0] spr_romofs  = {k46regs[6], k46regs[7], k46regs[4]};
    wire [23:0] spr_widx    = {spr_romofs[23:2], 2'b00} + (A[3] ? 24'd0 : 24'd2) + {22'd0, A[2:1]};
    logic [1:0] srom_sel;
    /* verilator lint_on UNUSEDSIGNAL */
    assign dbg_irq5 = irq5_pend;
    // MAME's dddeeprom_r: an access that includes the high byte returns IN1
    // there with a zero low byte; only a low-byte access reads P2
    assign in1_word = {in1[7:2], eep_ready, eep_do, uds ? 8'h00 : p2};

    // sources that answer in one cycle
    always_comb begin
        rd_mux = 16'h0000;
        if      (sel_wram)   rd_mux = wram_q;
        else if (sel_vram)   rd_mux = 16'h0000;            // only the external-linescroll mode reads here
        else if (sel_pal)    rd_mux = A[1] ? pal_cpu_q[1] : pal_cpu_q[0];
        else if (sel_sprwin) rd_mux = spr_hit ? sram_cpu_q : sshadow_q;
        else if (sel_rozli)  rd_mux = rozli_q;
        else if (sel_rozct)  rd_mux = rozctrl[A[4:1]];
        else if (sel_k252)   rd_mux = {8'h00, k252[A[4:1]]};
        else if (sel_in0)    rd_mux = in0_p1;
        else if (sel_in1)    rd_mux = in1_word;
        else if (sel_k321)   rd_mux = {snd_rdata, 8'h00};
        else if (sel_k000)   rd_mux = {8'h00, col_rdata};
    end

    always_ff @(posedge clk) begin
        clkena   <= 1'b0;
        dbg_step <= 1'b0;
        dbg_spr_we <= 1'b0;
        snd_wr <= 1'b0; snd_rd <= 1'b0; snd_irq <= 1'b0; pal_we <= 1'b0;
        col_wr <= 1'b0; col_rd <= 1'b0;
        step_gap <= {step_gap[1:0], clkena};

        if (reset) begin
            bst <= B_IDLE; tok <= '0; step_gap <= '0; irq5_pend <= 1'b0; vc_req <= 1'b0;
            rom_req <= 1'b0; map_req <= 1'b0; chr_req <= 1'b0; trom_req <= 1'b0; srom_req <= 1'b0;
            roz_enable <= 1'b0; roz_rombank <= 2'd0;
            eep_di <= 1'b0; eep_cs <= 1'b0; eep_clk <= 1'b0;
            for (int i = 0; i < 32; i++) k56regs[i] <= '0;
            for (int i = 0; i < 4;  i++) k56regsb[i] <= '0;
            for (int i = 0; i < 48; i++) k55regs[i] <= '0;
            for (int i = 0; i < 16; i++) begin k38regs[i] <= '0; k252[i] <= '0; end
            for (int i = 0; i < 16; i++) rozctrl[i] <= '0;
            for (int i = 0; i < 8;  i++) begin k46regs[i] <= '0; k47regs[i] <= '0; end
            rozclip[0] <= '0; rozclip[1] <= '0;
        end else begin
            if (cen_16m && tok < 6'd48) tok <= tok + 6'(STEP_GAIN);

            // IRQ5 is asserted at vblank and held until the kernel's
            // interrupt-acknowledge cycle -- a *read* with FC = 111, which
            // TG68K performs even with IPL_autovector (MAME's HOLD_LINE).
            // Nothing on the board answers it; the vector is internal.
            if (vblank_rise) irq5_pend <= 1'b1;

            case (bst)
                B_IDLE: begin
                    // sample the bus only after the kernel has settled (see the
                    // S.T.U.N. Runner core's note on the four-clock gap)
                    if (tok >= 6'(step_cost) && !clkena && step_gap == 3'd0) begin
                        if (fc == 3'b111) begin
                            // interrupt acknowledge: the IRQ drops, the step completes
                            clkena <= 1'b1; tok <= tok - 6'(STEP_COST_BUS); dbg_step <= 1'b1;
                            irq5_pend <= 1'b0;
                        end else if (busstate == 2'b01 || skipFetch) begin
                            clkena <= 1'b1; tok <= tok - 6'(STEP_COST_INT); dbg_step <= 1'b1;
                        end else if (is_wr) begin
                            // writes are posted: complete immediately
                            tok <= tok - 6'(STEP_COST_BUS); clkena <= 1'b1; dbg_step <= 1'b1;
                            if (sel_wram) begin
                                if (uds) wram[A[15:1]][1] <= data_write[15:8];
                                if (lds) wram[A[15:1]][0] <= data_write[7:0];
                            end else if (sel_vram) begin
                                if (!vram_ext) begin
                                    // the external tile RAM: a byte-enabled write the kernel waits for
                                    vc_req <= 1'b1; vc_we <= 1'b1; vc_addr <= vram_cpu_addr;
                                    vc_be <= {uds, lds}; vc_wdata <= data_write;
                                    clkena <= 1'b0; dbg_step <= 1'b0; bst <= B_WAIT_VRAMW;
                                end
                            end else if (sel_pal) begin
                                pal_we <= 1'b1; pal_waddr <= A[12:2]; pal_wsel <= {A[1], ~A[1]};
                                pal_wbe <= {uds, lds}; pal_wdata <= data_write;
                            end else if (sel_sprwin) begin
                                if (spr_hit) dbg_spr_we <= 1'b1;
                                if (spr_hit)
                                    sram[spr_word] <= {uds ? data_write[15:8] : sram_cpu_q[15:8],
                                                       lds ? data_write[7:0]  : sram_cpu_q[7:0]};
                                else
                                    sshadow[A[15:1]] <= {uds ? data_write[15:8] : sshadow_q[15:8],
                                                         lds ? data_write[7:0]  : sshadow_q[7:0]};
                            end else if (sel_k46) begin
                                // k053246_w: byte pair per word
                                if (uds) k46regs[{A[2:1], 1'b0}] <= data_write[15:8];
                                if (lds) k46regs[{A[2:1], 1'b1}] <= data_write[7:0];
                            end else if (sel_k47) begin
                                k47regs[A[3:1]] <= {uds ? data_write[15:8] : k47regs[A[3:1]][15:8],
                                                    lds ? data_write[7:0]  : k47regs[A[3:1]][7:0]};
                            end else if (sel_rozct) begin
                                // 16 words: 0-7 zoom coefficients, 8-15 the chip's own
                                // clip window (unused by the renderer, but they must not
                                // alias onto the coefficients).
                                rozctrl[A[4:1]] <= {uds ? data_write[15:8] : rozctrl[A[4:1]][15:8],
                                                    lds ? data_write[7:0]  : rozctrl[A[4:1]][7:0]};
                            end else if (sel_rozli) begin
                                rozli[A[11:1]] <= {uds ? data_write[15:8] : rozli_q[15:8],
                                                   lds ? data_write[7:0]  : rozli_q[7:0]};
                            end else if (sel_vacset) begin
                                k56regs[A[5:1]] <= {uds ? data_write[15:8] : k56regs[A[5:1]][15:8],
                                                    lds ? data_write[7:0]  : k56regs[A[5:1]][7:0]};
                            end else if (sel_vsccs) begin
                                k56regsb[A[2:1]] <= {uds ? data_write[15:8] : k56regsb[A[2:1]][15:8],
                                                     lds ? data_write[7:0]  : k56regsb[A[2:1]][7:0]};
                            end else if (sel_clip) begin
                                rozclip[A[1]] <= {uds ? data_write[15:8] : rozclip[A[1]][15:8],
                                                  lds ? data_write[7:0]  : rozclip[A[1]][7:0]};
                            end else if (sel_k252) begin
                                if (lds) k252[A[4:1]] <= data_write[7:0];
                            end else if (sel_k555) begin
                                // K055555_word_w: low byte if only LDS, else the high byte
                                if (A[7:1] < 7'd48)
                                    k55regs[A[6:1]] <= (lds && !uds) ? data_write[7:0] : data_write[15:8];
                            end else if (sel_k321) begin
                                // umask16(0xff00): the high byte
                                if (uds) begin snd_wr <= 1'b1; snd_off <= A[4:1]; snd_wdata <= data_write[15:8]; end
                            end else if (sel_k338) begin
                                k38regs[A[4:1]] <= {uds ? data_write[15:8] : k38regs[A[4:1]][15:8],
                                                    lds ? data_write[7:0]  : k38regs[A[4:1]][7:0]};
                            end else if (sel_k000) begin
                                if (lds) begin col_wr <= 1'b1; col_off <= A[5:1]; col_wdata <= data_write[7:0]; end
                            end else if (sel_eep) begin
                                if (lds) begin eep_di <= data_write[0]; eep_cs <= data_write[1]; eep_clk <= data_write[2]; end
                            end else if (sel_rozen) begin
                                if (uds) begin roz_enable <= data_write[8]; roz_rombank <= data_write[15:14]; end
                            end else if (sel_sndirq) begin
                                snd_irq <= 1'b1;
                            end
                            // sel_wdog and anything unmapped: ignored
                        end else begin
                            // reads
                            tok <= tok - 6'(STEP_COST_BUS);
                            if (sel_rom) begin
                                rom_addr <= A[22:1]; rom_req <= 1'b1; bst <= B_WAIT_ROM;
                            end else if (sel_vram && !vram_ext) begin
                                vc_req <= 1'b1; vc_we <= 1'b0; vc_addr <= vram_cpu_addr; bst <= B_WAIT_VRAM;
                            end else if (sel_rb0) begin
                                // (gfx4[0x20000 + off] << 8) | gfx4[0x60000 + off], off = word offset
                                map_addr <= 20'h20000 + {2'd0, A[18:1]}; map_req <= 1'b1; bst <= B_WAIT_MAP0;
                            end else if (sel_rb1) begin
                                // gfx4[off / 2] in the low byte
                                map_addr <= {3'd0, A[18:2]}; map_req <= 1'b1; bst <= B_WAIT_MAP1;
                            end else if (sel_rb2) begin
                                // gfx3[(bank * 0x100000 + off) / 2] << 8
                                chr_addr <= {roz_rombank, A[20:2]}; chr_req <= 1'b1; bst <= B_WAIT_CHR;
                            end else if (sel_tmrb) begin
                                if (tile_plane5) begin
                                    bst <= B_RAM_RD;             // rd_mux gives 0
                                end else begin
                                    trom_addr <= trom_group; trom_req <= 1'b1; bst <= B_WAIT_TROM;
                                end
                            end else if (sel_sprrb) begin
                                srom_addr <= spr_widx[21:2]; srom_sel <= spr_widx[1:0];
                                srom_req <= 1'b1; bst <= B_WAIT_SROM;
                            end else begin
                                if (sel_k321) snd_rd <= 1'b1;
                                if (sel_k000) col_rd <= 1'b1;
                                snd_off <= A[4:1]; col_off <= A[5:1];
                                bst <= B_RAM_RD;
                            end
                        end
                    end
                end

                // block RAMs and latches answer one cycle after the live address
                B_RAM_RD: begin
                    data_in <= rd_mux; clkena <= 1'b1; dbg_step <= 1'b1; bst <= B_IDLE;
                end
                B_WAIT_ROM: if (rom_ack) begin
                    rom_req <= 1'b0; data_in <= rom_q; clkena <= 1'b1; dbg_step <= 1'b1; bst <= B_IDLE;
                end
                B_WAIT_VRAM: if (vc_ack) begin
                    vc_req <= 1'b0; data_in <= vc_q; clkena <= 1'b1; dbg_step <= 1'b1; bst <= B_IDLE;
                end
                B_WAIT_VRAMW: if (vc_ack) begin
                    vc_req <= 1'b0; clkena <= 1'b1; dbg_step <= 1'b1; bst <= B_IDLE;
                end
                B_WAIT_MAP0: if (map_ack) begin
                    rb_hi <= map_addr[0] ? map_q[7:0] : map_q[15:8];
                    map_addr <= 20'h60000 + {2'd0, A[18:1]}; bst <= B_WAIT_MAP0B;
                end
                B_WAIT_MAP0B: if (map_ack) begin
                    map_req <= 1'b0;
                    data_in <= {rb_hi, map_addr[0] ? map_q[7:0] : map_q[15:8]};
                    clkena <= 1'b1; dbg_step <= 1'b1; bst <= B_IDLE;
                end
                B_WAIT_MAP1: if (map_ack) begin
                    map_req <= 1'b0;
                    data_in <= {8'h00, map_addr[0] ? map_q[7:0] : map_q[15:8]};
                    clkena <= 1'b1; dbg_step <= 1'b1; bst <= B_IDLE;
                end
                B_WAIT_CHR: if (chr_ack) begin
                    chr_req <= 1'b0;
                    data_in <= {chr_addr[0] ? chr_q[7:0] : chr_q[15:8], 8'h00};
                    clkena <= 1'b1; dbg_step <= 1'b1; bst <= B_IDLE;
                end
                B_WAIT_TROM: if (trom_ack) begin
                    trom_req <= 1'b0;
                    // rom[addr+1] | rom[addr] << 8: the group's first or second byte pair
                    data_in <= A[1] ? trom_q[15:0] : trom_q[31:16];
                    clkena <= 1'b1; dbg_step <= 1'b1; bst <= B_IDLE;
                end
                B_WAIT_SROM: if (srom_ack) begin
                    srom_req <= 1'b0;
                    // (u16*) view on a little-endian host: low byte is the even byte
                    case (srom_sel)
                        2'd0: data_in <= {srom_q[55:48], srom_q[63:56]};
                        2'd1: data_in <= {srom_q[39:32], srom_q[47:40]};
                        2'd2: data_in <= {srom_q[23:16], srom_q[31:24]};
                        default: data_in <= {srom_q[7:0], srom_q[15:8]};
                    endcase
                    clkena <= 1'b1; dbg_step <= 1'b1; bst <= B_IDLE;
                end
                default: bst <= B_IDLE;
            endcase
        end
    end
endmodule
