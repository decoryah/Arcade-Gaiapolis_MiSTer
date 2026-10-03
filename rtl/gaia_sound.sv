//------------------------------------------------------------------------------
// Gaiapolis sound board: Z80 @ 8 MHz, two K054539s, the K054321 latch.
// Memory map from docs/hardware.md section 7:
//   0000-7fff ROM      8000-bfff ROM bank (16 x 16 KB, sound_ctrl bits 3:0)
//   c000-dfff RAM      e000-e22f K054539 #1     e230-e3ff RAM
//   e400-e62f K054539 #2   e630-e7ff RAM   f000-f003 K054321   f800 sound_ctrl
// IRQ0 comes from the 68000 writing 6E0000; NMI from K054539 #1's timer,
// gated by sound_ctrl bit 4 and cleared by writing sound_ctrl with bit 4 low.
//------------------------------------------------------------------------------
`default_nettype none

module gaia_sound #(
    parameter string HEXDIR = "rtl/data"
) (
    input  logic        clk,
    input  logic        reset,
    input  logic        cen_8m,
    input  logic        cen_48k,

    // sound program ROM, 256 KB, byte address
    output logic        rom_req,
    output logic [17:0] rom_addr,
    input  logic        rom_ack,
    input  logic  [7:0] rom_q,
    // PCM ROM, 4 MB, shared by both chips
    output logic        pcm_req,
    output logic [21:0] pcm_addr,
    input  logic        pcm_ack,
    input  logic  [7:0] pcm_q,

    // K054321 sound side
    output logic        lat_wr,
    output logic  [1:0] lat_off,
    output logic  [7:0] lat_wdata,
    input  logic  [7:0] lat_rdata,

    input  logic        irq_pulse,      // from the 68000's 6E0000 write

    output logic [15:0] snd_l,
    output logic [15:0] snd_r,
    output logic [15:0] dbg_pc,
    output logic        dbg_step,
    output logic        dbg_wait,
    output logic        dbg_wr,         // memory write strobe, dbg_pc = address
    output logic        dbg_rd,
    output logic  [7:0] dbg_wdata
);
    // ------------------------------------------------------------- CPU
    logic        m1_n, mreq_n, iorq_n, rd_n, wr_n, rfsh_n;
    logic [15:0] A;
    logic  [7:0] cpu_di, cpu_do;
    logic        nmi_n, int_n, wait_n;

    tv80s_cen u_cpu (
        .reset_n(~reset), .clk(clk), .cen(cen_8m), .wait_n(wait_n),
        .int_n(int_n), .nmi_n(nmi_n), .busrq_n(1'b1),
        .m1_n(m1_n), .mreq_n(mreq_n), .iorq_n(iorq_n), .rd_n(rd_n), .wr_n(wr_n),
        .rfsh_n(rfsh_n), .halt_n(), .busak_n(), .A(A), .di(cpu_di), .dout(cpu_do)
    );
    assign dbg_pc = A;
    logic m1_d;
    always_ff @(posedge clk) m1_d <= !m1_n && !mreq_n;
    assign dbg_step = !m1_n && !mreq_n && !m1_d;
    assign dbg_wait = !wait_n;

    // The Z80 steps on cen_8m, so its address and data are multicycle paths
    // (projects/gaia_pocket.sdc): the devices see the strobes four clocks
    // after the CPU raises them, when both have settled. RD stays a level
    // (the RAMs and ports are read on it); WR is low for two T-states (24
    // clocks) and becomes one pulse per bus cycle, since a K054539 port
    // write has side effects (0x22d steps the streaming pointer).
    wire  mem_rd_raw = !mreq_n && !rd_n && rfsh_n;
    wire  mem_wr_raw = !mreq_n && !wr_n && rfsh_n;
    logic [3:0] rd_dl;
    logic [4:0] wr_dl;
    always_ff @(posedge clk) begin
        rd_dl <= {rd_dl[2:0], mem_rd_raw};
        wr_dl <= {wr_dl[3:0], mem_wr_raw};
    end
    wire  mem_rd = rd_dl[3];
    wire  mem_wr = wr_dl[3] && !wr_dl[4];
    assign dbg_wr = mem_wr; assign dbg_rd = mem_rd && wait_n; assign dbg_wdata = cpu_do;

    // ---------------------------------------------------------- decode
    wire sel_rom0 = (A[15] == 1'b0);                        // 0000-7fff
    wire sel_bank = (A[15:14] == 2'b10);                    // 8000-bfff
    wire sel_ram  = (A[15:13] == 3'b110);                   // c000-dfff
    wire sel_k1   = (A[15:10] == 6'b1110_00) && (A[9:0] < 10'h230);   // e000-e22f
    wire sel_ram1 = (A[15:9]  == 7'b1110_001) && (A[8:0] >= 9'h030);  // e230-e3ff
    wire sel_k2   = (A[15:10] == 6'b1110_01) && (A[9:0] < 10'h230);   // e400-e62f
    wire sel_ram2 = (A[15:9]  == 7'b1110_011) && (A[8:0] >= 9'h030);  // e630-e7ff
    wire sel_lat  = (A[15:2]  == 14'b1111_0000_0000_00);              // f000-f003
    wire sel_ctrl = (A == 16'hf800);

    // ------------------------------------------------------------ RAM
    logic [7:0] ram [8192];
    logic [7:0] ram1 [512], ram2 [512];
    logic [7:0] ram_q, ram1_q, ram2_q;
    always_ff @(posedge clk) begin
        if (mem_wr && sel_ram)  ram[A[12:0]]  <= cpu_do;
        if (mem_wr && sel_ram1) ram1[A[8:0]]  <= cpu_do;
        if (mem_wr && sel_ram2) ram2[A[8:0]]  <= cpu_do;
        ram_q  <= ram[A[12:0]];
        ram1_q <= ram1[A[8:0]];
        ram2_q <= ram2[A[8:0]];
    end

    // ---------------------------------------------------- sound_ctrl
    logic [7:0] sound_ctrl;
    logic       nmi_pend, tmr_d;
    always_ff @(posedge clk) begin
        if (reset) begin sound_ctrl <= 8'h02; nmi_pend <= 1'b0; tmr_d <= 1'b0; end   // MACHINE_START: bank 2
        else begin
            if (mem_wr && sel_ctrl) begin
                sound_ctrl <= cpu_do;
                if (!cpu_do[4]) nmi_pend <= 1'b0;
            end
            tmr_d <= timer1;
            if (sound_ctrl[4] && timer1 && !tmr_d) nmi_pend <= 1'b1;
        end
    end
    assign nmi_n = ~nmi_pend;

    // IRQ0: a pulse from the 68000, held until the Z80 acknowledges (M1+IORQ)
    logic irq_pend;
    always_ff @(posedge clk) begin
        if (reset) irq_pend <= 1'b0;
        else if (irq_pulse) irq_pend <= 1'b1;
        else if (!m1_n && !iorq_n) irq_pend <= 1'b0;
    end
    assign int_n = ~irq_pend;

    // ------------------------------------------------------------ ROM
    // Byte reads through the request/ack port; the Z80 waits on wait_n.
    logic       rom_busy, rom_have;
    logic [7:0] rom_data;
    wire rom_sel = mem_rd && (sel_rom0 || sel_bank);
    wire [17:0] rom_byte = sel_rom0 ? {3'd0, A[14:0]} : {sound_ctrl[3:0], A[13:0]};
    always_ff @(posedge clk) begin
        if (reset) begin rom_busy <= 1'b0; rom_have <= 1'b0; rom_req <= 1'b0; end
        else begin
            if (rom_sel && !rom_busy && !rom_have) begin
                rom_addr <= rom_byte; rom_req <= 1'b1; rom_busy <= 1'b1;
            end else if (rom_busy && rom_ack) begin
                rom_data <= rom_q; rom_req <= 1'b0; rom_busy <= 1'b0; rom_have <= 1'b1;
            end
            if (!rom_sel) rom_have <= 1'b0;
        end
    end

    // ---------------------------------------------------------- chips
    logic [7:0] k1_q, k2_q;
    logic       k1_stall, k2_stall, timer1, timer2;
    logic       p1_req, p2_req, p1_ack, p2_ack;
    logic [21:0] p1_addr, p2_addr;
    logic [15:0] l1, r1, l2, r2;

    // MACHINE_RESET gaiapols: chip 1 channels 5-7 ("voice") x2.0. The packed
    // literal lists index 7 first, so the three 0x8000 entries are channels 7..5.
    k054539 #(.HEXDIR(HEXDIR), .GAIN_Q14({16'h8000, 16'h8000, 16'h8000, 16'h4000, 16'h4000, 16'h4000, 16'h4000, 16'h4000})) u_k1 (
        .clk(clk), .reset(reset), .cen_48k(cen_48k),
        .cs(sel_k1), .wr(mem_wr), .rd(mem_rd), .addr(A[9:0]), .wdata(cpu_do), .rdata(k1_q), .rd_stall(k1_stall),
        .rom_req(p1_req), .rom_addr(p1_addr), .rom_ack(p1_ack), .rom_q(pcm_q),
        .timer_out(timer1), .snd_l(l1), .snd_r(r1)
    );
    k054539 #(.HEXDIR(HEXDIR)) u_k2 (
        .clk(clk), .reset(reset), .cen_48k(cen_48k),
        .cs(sel_k2), .wr(mem_wr), .rd(mem_rd), .addr(A[9:0]), .wdata(cpu_do), .rdata(k2_q), .rd_stall(k2_stall),
        .rom_req(p2_req), .rom_addr(p2_addr), .rom_ack(p2_ack), .rom_q(pcm_q),
        .timer_out(timer2), .snd_l(l2), .snd_r(r2)
    );
    rom_arb2 #(.AW(22), .DW(8)) u_pcm_arb (
        .clk(clk), .reset(reset),
        .c0_req(p1_req), .c0_addr(p1_addr), .c0_ack(p1_ack),
        .c1_req(p2_req), .c1_addr(p2_addr), .c1_ack(p2_ack),
        .m_req(pcm_req), .m_addr(pcm_addr), .m_ack(pcm_ack), .m_q(pcm_q), .q()
    );

    // ---------------------------------------------------------- latch
    assign lat_wr    = mem_wr && sel_lat;
    assign lat_off   = A[1:0];
    assign lat_wdata = cpu_do;

    // ----------------------------------------------------- read mux
    always_comb begin
        cpu_di = 8'hff;
        if      (rom_sel)  cpu_di = rom_data;
        else if (sel_ram)  cpu_di = ram_q;
        else if (sel_ram1) cpu_di = ram1_q;
        else if (sel_ram2) cpu_di = ram2_q;
        else if (sel_k1)   cpu_di = k1_q;
        else if (sel_k2)   cpu_di = k2_q;
        else if (sel_lat)  cpu_di = lat_rdata;
    end
    assign wait_n = !((rom_sel && !rom_have) || k1_stall || k2_stall);

    // mix: the two chips sum; the K054321 volume is applied by the platform
    assign snd_l = l1 + l2;
    assign snd_r = r1 + r2;
    /* verilator lint_off UNUSEDSIGNAL */
    wire unused = ^{timer2, sound_ctrl[7:5]};
    /* verilator lint_on UNUSEDSIGNAL */
endmodule
