//------------------------------------------------------------------------------
// K054539 8-channel PCM/ADPCM sound chip -- register interface, ROM/RAM read
// port and timer. Modelled on MAME's k054539.cpp.
//
// This half is what the Z80's self-test and the game's driver code talk to:
//   0x000-0x0ff  channel registers (8 x 0x20)
//   0x200-0x22f  global: 0x214 key on, 0x215 key off, 0x227 timer period,
//                0x22c active channels, 0x22d ROM/RAM data port,
//                0x22e ROM bank (0x80 = internal RAM), 0x22f control
// Reading 0x22d with control bit 4 set streams the ROM at bank*0x20000 +
// pointer, or the 32 KB internal RAM when the bank is 0x80; writing 0x22d
// with the bank at 0x80 writes that RAM. The pointer post-increments in
// both cases. The timer output toggles every 7200/(38+period) samples at
// 48 kHz (clock/384) and drives the Z80's NMI on the board.
//
// Rendering follows sound_stream_update: per 48 kHz sample, each keyed
// channel steps its 16.16 position by the 24-bit delta, fetching 8-bit PCM,
// 16-bit PCM or 4-bit DPCM from the ROM (looping at the end marker if reg
// 0x201 bit 0 is set, else keying off), and adds its sample times volume x
// pan x gain to the mix; a reverb ring of 8192 x int16 lives in the chip RAM,
// the current entry is read into the mix and cleared, and each channel adds
// into it at its own delay. Positions write back to regs 0x0c-0x0e unless
// 0x22f bit 7 holds them. Volumes are Q2.14 tables from
// tools/gen_k054539_tables.py; the per-channel gain MAME applies at reset
// for this game (chip 1 channels 5-7 x2.0, the "voice" channels) comes in
// through GAIN_Q14.
//------------------------------------------------------------------------------
`default_nettype none

module k054539 #(
    parameter string HEXDIR = "rtl/data",
    // Q2.14 per-channel gain, MSB channel 7; 0x4000 = 1.0
    parameter logic [7:0][15:0] GAIN_Q14 = {8{16'h4000}}
) (
    input  logic        clk,
    input  logic        reset,
    input  logic        cen_48k,        // one pulse per output sample

    // Z80 side
    input  logic        cs,
    input  logic        wr,
    input  logic        rd,
    input  logic  [9:0] addr,           // 0x000..0x22f
    input  logic  [7:0] wdata,
    output logic  [7:0] rdata,
    output logic        rd_stall,       // hold the CPU while a ROM read is in flight

    // sample ROM, 4 MB, byte address
    output logic        rom_req,
    output logic [21:0] rom_addr,
    input  logic        rom_ack,
    input  logic  [7:0] rom_q,

    output logic        timer_out,      // toggles; NMI on its rising edge
    output logic [15:0] snd_l,
    output logic [15:0] snd_r
);
    // register file: the channel bytes (0x000-0x1ff) in a block RAM read a
    // byte a cycle, the globals and mode bytes (0x200-0x22f) as registers.
    // (As one 560-byte register array it cost ~2K ALUTs a chip.)
    logic [7:0] chreg [512];
    logic [7:0] greg  [48];
    logic [7:0] chreg_cpu_q, chreg_q;   // CPU readback, renderer parameter fetch
    logic [8:0] chreg_rd;
    wire        cpu_wr    = cs && wr;
    wire        cpu_wr_ch = cpu_wr && !addr[9];         // 0x000-0x1ff
    wire        cpu_wr_g  = cpu_wr &&  addr[9];         // 0x200-0x22f
    // the renderer's position write-back, three bytes through the one write
    // port; a CPU write to the same bytes is newer and cancels it
    logic        wb_run;
    logic  [1:0] wb_i;
    logic  [2:0] wb_chl;
    logic [23:0] wb_posl;
    wire   [8:0] wb_addr = {1'b0, wb_chl, 5'h0c} + {7'd0, wb_i};
    wire   [7:0] wb_byte = (wb_i == 2'd0) ? wb_posl[7:0] : (wb_i == 2'd1) ? wb_posl[15:8] : wb_posl[23:16];
    always_ff @(posedge clk) begin
        chreg_cpu_q <= chreg[addr[8:0]];
        chreg_q     <= chreg[chreg_rd];
        if (cpu_wr_ch)   chreg[addr[8:0]] <= wdata;
        else if (wb_run) chreg[wb_addr]   <= wb_byte;
    end
    // 32 KB chip RAM: byte port for the Z80, 16-bit port for the reverb ring
    // 32 KB chip RAM as two byte-wide true dual-port blocks (low and high
    // byte of each 16-bit word): port A is the Z80's byte port (0x22d with
    // 0x22e = 0x80), port B the renderer's 16-bit reverb ring. Written in
    // Quartus's true-dual-port template: a port never reads while it writes.
    logic [7:0] ram_lo [16384];
    logic [7:0] ram_hi [16384];
    logic [15:0] vol_tab [256];
    logic [15:0] pan_tab [16];
    initial begin
        $readmemh({HEXDIR, "/k539_vol.hex"}, vol_tab);
        $readmemh({HEXDIR, "/k539_pan.hex"}, pan_tab);
    end
    logic [16:0] cur_ptr;
    logic  [7:0] rom_bank;
    logic [15:0] tcount;
    logic  [7:0] ram_q;

    wire [14:0] ram_addr = {cur_ptr[16], cur_ptr[13:0]};   // (ptr & 0x3fff) | (ptr & 0x10000) >> 2
    wire        ram_sel  = (rom_bank == 8'h80);
    wire        stream_en = greg[6'h2f][4];

    // ---- data port read: ROM reads go through the request/ack port ----
    typedef enum logic [1:0] { P_IDLE, P_ROM, P_DONE } pst_t;
    pst_t pst;
    logic [7:0] port_q;
    logic       rd_d;
    logic        strm_req;
    logic [21:0] strm_addr;

    logic [7:0] ram_qlo, ram_qhi;
    logic       ram_lane;
    wire        ram_wr_a = cs && wr && (addr == 10'h22d) && ram_sel;
    always_ff @(posedge clk) begin
        if (ram_wr_a && !ram_addr[0]) begin ram_lo[ram_addr[14:1]] <= wdata; ram_qlo <= wdata; end
        else ram_qlo <= ram_lo[ram_addr[14:1]];
    end
    always_ff @(posedge clk) begin
        if (ram_wr_a && ram_addr[0]) begin ram_hi[ram_addr[14:1]] <= wdata; ram_qhi <= wdata; end
        else ram_qhi <= ram_hi[ram_addr[14:1]];
    end
    always_ff @(posedge clk) ram_lane <= ram_addr[0];
    assign ram_q = ram_lane ? ram_qhi : ram_qlo;

    always_comb begin
        rdata = addr[9] ? greg[addr[5:0]] : chreg_cpu_q;   // the CPU holds the address a whole bus cycle
        if (addr == 10'h22d) rdata = stream_en ? port_q : 8'h00;
    end
    assign rd_stall = cs && rd && (addr == 10'h22d) && stream_en && !ram_sel && (pst != P_DONE);

    // timer: toggle every 7200/(38+period) samples
    // timer period in samples, 7200 / (38 + regs[0x227]), from a table rather
    // than a 16-bit divider
    logic [15:0] timer_tab [256];
    initial $readmemh({HEXDIR, "/k539_timer.hex"}, timer_tab);
    wire [15:0] tperiod = timer_tab[greg[6'h27]];

    always_ff @(posedge clk) begin
        if (reset) begin
            for (int i = 0; i < 48; i++) greg[i] <= '0;
            wb_run <= 1'b0; wb_i <= '0;
            cur_ptr <= '0; rom_bank <= '0; pst <= P_IDLE; strm_req <= 1'b0;
            timer_out <= 1'b0; tcount <= '0; rd_d <= 1'b0;
        end else begin
            rd_d <= cs && rd;

            // ---- streaming read of 0x22d ----
            case (pst)
                P_IDLE: if (cs && rd && addr == 10'h22d && stream_en) begin
                    if (ram_sel) begin
                        port_q <= ram_q; pst <= P_DONE;
                    end else if (!rrom_req) begin      // the renderer's fetch finishes first
                        strm_addr <= {rom_bank[4:0], cur_ptr};   // bank*0x20000 + ptr, 4 MB
                        strm_req <= 1'b1; pst <= P_ROM;
                    end
                end
                P_ROM: if (rom_ack && strm_req) begin
                    port_q <= rom_q; strm_req <= 1'b0; pst <= P_DONE;
                end
                P_DONE: if (!(cs && rd)) begin          // the CPU has taken the byte
                    cur_ptr <= cur_ptr + 17'd1;
                    pst <= P_IDLE;
                end
                default: pst <= P_IDLE;
            endcase

            // ---- the renderer's key-off and position write-back ----
            if (ko_we) greg[6'h2c][ko_ch] <= 1'b0;
            if (wb_we) begin wb_run <= 1'b1; wb_i <= '0; wb_chl <= wb_ch; wb_posl <= wb_pos; end
            else if (wb_run) begin
                if (cpu_wr_ch && addr[8:5] == {1'b0, wb_chl} && addr[4:0] >= 5'h0c && addr[4:0] <= 5'h0e) wb_run <= 1'b0;
                else if (!cpu_wr_ch) begin
                    if (wb_i == 2'd2) wb_run <= 1'b0; else wb_i <= wb_i + 2'd1;
                end
            end

            // ---- writes to the globals (channel bytes go to the RAM above) ----
            if (cpu_wr_g) begin
                case (addr)
                    10'h214: greg[6'h2c] <= greg[6'h2c] | wdata;               // key on
                    10'h215: greg[6'h2c] <= greg[6'h2c] & ~wdata;              // key off
                    10'h22d: cur_ptr <= cur_ptr + 17'd1;      // the RAM write is port A above
                    10'h22e: begin rom_bank <= wdata; cur_ptr <= '0; end
                    10'h227: begin tcount <= '0; timer_out <= 1'b0; end
                    default: ;
                endcase
                if (addr != 10'h214 && addr != 10'h215) greg[addr[5:0]] <= wdata;
                if (addr == 10'h22f && !wdata[5]) timer_out <= 1'b0;   // timer output disabled
            end

            // ---- timer ----
            if (cen_48k && greg[6'h2f][5]) begin
                if (tcount + 16'd1 >= tperiod) begin
                    tcount <= '0; timer_out <= ~timer_out;
                end else tcount <= tcount + 16'd1;
            end
        end
    end

    // ------------------------------------------------------------ renderer
    // One sample per cen_48k: read and clear the reverb entry, then walk the
    // eight channels. Every position step fetches a sample, as MAME does, so
    // a pitch above 1.0 costs one ROM read per step; DPCM depends on that.
    // The ROM port is shared with the Z80's streaming reads, which win.
    typedef enum logic [4:0] {
        A_IDLE, A_RVB_RD, A_RVB_CLR, A_CH, A_CHF, A_CHX, A_CHV1, A_CHV2, A_CHV3, A_CHV4, A_STEP, A_ROM, A_ROMW, A_ROM2, A_DEC,
        A_RVB_RMW, A_RVB_RD2, A_RVB_WR, A_NEXT, A_OUT
    } ast_t;
    ast_t ast;

    logic [23:0] ch_pos  [8];
    logic [15:0] ch_pfrac[8];
    logic signed [15:0] ch_val [8], ch_pval [8];

    logic  [2:0] ch;
    logic [12:0] reverb_pos;
    logic signed [31:0] lval, rval;
    logic [23:0] delta, cur_pos, loop_pos;
    logic [24:0] cur_pfrac;            // 16-bit fraction plus the integer carry
    logic signed [16:0] cur_val, cur_pval;
    logic        neg_dir, is_16, is_dpcm, loop_en;
    logic [15:0] lvol, rvol, rbvol;
    logic [13:0] rdelta;
    logic [15:0] rvb_q;
    logic  [7:0] rbyte, rbyte2;
    logic [12:0] rvb_addr;              // read and write address of port B
    logic        rvb_we;
    logic [15:0] rvb_wdata;
    logic        rrom_req;
    logic        wb_we, ko_we;          // renderer -> register file
    logic  [2:0] wb_ch, ko_ch;
    logic [23:0] wb_pos;
    logic [21:0] rrom_addr;

    // the channel's first 15 register bytes, fetched at channel start
    logic [7:0] p [15];
    logic [3:0] pi;
    wire [7:0]  vol   = p[3];
    wire [8:0]  bsum  = {1'b0, vol} + {1'b0, p[4]};
    wire [7:0]  bval  = bsum[8] ? 8'hff : bsum[7:0];
    wire [7:0]  panr  = p[5];
    wire [3:0]  pan   = (panr >= 8'h81 && panr <= 8'h8f) ? panr[3:0] - 4'd1
                      : (panr >= 8'h11 && panr <= 8'h1f) ? panr[3:0] - 4'd1 : 4'd7;
    // channel mode bytes at 0x200 + ch*2: [0] bit5 direction, bits 3:2 type;
    // [1] bit0 loop
    /* verilator lint_off UNUSEDSIGNAL */
    wire [7:0]  mode  = greg[{2'd0, ch, 1'b0}];
    wire [7:0]  mode1 = greg[{2'd0, ch, 1'b1}];
    wire [15:0] rdel16 = {p[7], p[6]};
    /* verilator lint_on UNUSEDSIGNAL */

    // (a * b >> 14) * g >> 14, capped at 1.80 (0x7333 in Q2.14), as two
    // pipeline steps: one 16x16 multiply a cycle (the pair in one cycle was
    // the design's worst path, -7.6 ns at 96 MHz)
    function automatic logic [15:0] q14mul(input logic [15:0] a, input logic [15:0] b);
        // the Q2.14 fraction bits of the product are dropped, as MAME does
        /* verilator lint_off UNUSEDSIGNAL */
        logic [31:0] t;
        /* verilator lint_on UNUSEDSIGNAL */
        t = a * b;
        return t[29:14];
    endfunction
    // the gain product and its cap are two more steps (the pair was -2.3 ns)
    function automatic logic [15:0] q14cap(input logic [31:0] u);
        /* verilator lint_off UNUSEDSIGNAL */
        logic [31:0] t; t = u;
        /* verilator lint_on UNUSEDSIGNAL */
        return (t[31:14] > 18'h07333) ? 16'h7333 : t[29:14];
    endfunction
    logic  [3:0] pan_d;
    logic [15:0] vt, bvt, pl, pr, m_l, m_r, m_b;
    logic [31:0] u_l, u_r, u_b;

    function automatic logic signed [16:0] dpcm(input logic [3:0] n);
        case (n)
            4'd0: return 17'sd0;     4'd1: return 17'sd256;    4'd2: return 17'sd512;    4'd3: return 17'sd1024;
            4'd4: return 17'sd2048;  4'd5: return 17'sd4096;   4'd6: return 17'sd8192;   4'd7: return 17'sd16384;
            4'd8: return 17'sd0;     4'd9: return -17'sd16384; 4'd10: return -17'sd8192; 4'd11: return -17'sd4096;
            4'd12: return -17'sd2048; 4'd13: return -17'sd1024; 4'd14: return -17'sd512; default: return -17'sd256;
        endcase
    endfunction

    // reverb ring: 8192 x int16 at the start of the chip RAM (port B)
    always_ff @(posedge clk) begin
        if (rvb_we) begin ram_lo[{1'b0, rvb_addr}] <= rvb_wdata[7:0]; rvb_q[7:0] <= rvb_wdata[7:0]; end
        else rvb_q[7:0] <= ram_lo[{1'b0, rvb_addr}];
    end
    always_ff @(posedge clk) begin
        if (rvb_we) begin ram_hi[{1'b0, rvb_addr}] <= rvb_wdata[15:8]; rvb_q[15:8] <= rvb_wdata[15:8]; end
        else rvb_q[15:8] <= ram_hi[{1'b0, rvb_addr}];
    end

    // ROM port: the Z80's streaming read wins, the renderer waits
    // one request at a time on the port: the streaming port and the renderer
    // each wait for the other's fetch to finish before issuing theirs
    assign rom_req  = strm_req | rrom_req;
    assign rom_addr = strm_req ? strm_addr : rrom_addr;
    wire   rrom_ack = rom_ack && rrom_req && !strm_req;

    wire [21:0] fetch_addr = is_dpcm ? cur_pos[22:1] : (is_16 ? {cur_pos[21:1], 1'b0} : cur_pos[21:0]);

    always_ff @(posedge clk) begin
        if (reset) begin
            ast <= A_IDLE; reverb_pos <= '0; rvb_we <= 1'b0; rrom_req <= 1'b0;
            wb_we <= 1'b0; ko_we <= 1'b0;
            snd_l <= '0; snd_r <= '0;
            for (int i = 0; i < 8; i++) begin ch_pos[i] <= '0; ch_pfrac[i] <= '0; ch_val[i] <= '0; ch_pval[i] <= '0; end
        end else begin
            rvb_we <= 1'b0; wb_we <= 1'b0; ko_we <= 1'b0;
            case (ast)
                A_IDLE: if (cen_48k) begin
                    if (greg[6'h2f][0]) begin rvb_addr <= reverb_pos; ast <= A_RVB_RD; end
                    else begin snd_l <= '0; snd_r <= '0; end
                end
                A_RVB_RD: ast <= A_RVB_CLR;
                A_RVB_CLR: begin
                    lval <= $signed({{16{rvb_q[15]}}, rvb_q});
                    rval <= $signed({{16{rvb_q[15]}}, rvb_q});
                    rvb_we <= 1'b1; rvb_wdata <= '0;            // rvb_addr is still reverb_pos
                    ch <= 3'd0; ast <= A_CH;
                end

                A_CH: begin
                    if (!greg[6'h2c][ch]) ast <= A_NEXT;
                    else begin chreg_rd <= {1'b0, ch, 5'd0}; pi <= 4'd0; ast <= A_CHF; end
                end
                // the 15 parameter bytes, one a cycle: chreg_q holds byte pi-1
                // while byte pi is being addressed
                A_CHF: begin
                    chreg_rd <= chreg_rd + 9'd1;
                    if (pi != 4'd0) p[pi - 4'd1] <= chreg_q;
                    if (pi == 4'd15) ast <= A_CHX; else pi <= pi + 4'd1;
                end
                A_CHX: begin
                    begin
                        delta    <= {p[2], p[1], p[0]};
                        loop_pos <= {p[10], p[9], p[8]};
                        cur_pos  <= {p[14], p[13], p[12]};
                        rdelta   <= {1'b0, rdel16[15:3]};
                        neg_dir  <= mode[5];
                        is_16    <= (mode[3:2] == 2'b01);
                        is_dpcm  <= (mode[3:2] == 2'b10);
                        loop_en  <= mode1[0];
                        // volume pipeline: tables, pan tables, product, gain and cap
                        pan_d <= pan; vt <= vol_tab[vol]; bvt <= vol_tab[bval];
                        ast <= A_CHV1;
                    end
                end
                A_CHV1: begin pl <= pan_tab[pan_d]; pr <= pan_tab[4'd14 - pan_d]; ast <= A_CHV2; end
                A_CHV2: begin m_l <= q14mul(vt, pl); m_r <= q14mul(vt, pr); m_b <= q14mul(bvt, 16'h2000); ast <= A_CHV3; end
                A_CHV3: begin
                    u_l <= m_l * GAIN_Q14[ch]; u_r <= m_r * GAIN_Q14[ch]; u_b <= m_b * GAIN_Q14[ch];
                    ast <= A_CHV4;
                end
                A_CHV4: begin
                    lvol <= q14cap(u_l); rvol <= q14cap(u_r); rbvol <= q14cap(u_b);   // rbvol: gain / 2
                    ast <= A_STEP;
                end
                // restart detection, DPCM nibble addressing, pfrac += delta
                A_STEP: begin
                    logic [15:0] pf; logic signed [16:0] v, pv; logic [23:0] pos;
                    if (cur_pos != ch_pos[ch]) begin pf = '0; v = '0; pv = '0; end
                    else begin pf = ch_pfrac[ch]; v = {ch_val[ch][15], ch_val[ch]}; pv = {ch_pval[ch][15], ch_pval[ch]}; end
                    pos = cur_pos;
                    if (is_dpcm) begin pos = {cur_pos[22:0], pf[15]}; pf = {pf[14:0], 1'b0}; end
                    cur_pos <= pos; cur_val <= v; cur_pval <= pv;
                    cur_pfrac <= {9'd0, pf} + {1'b0, delta};
                    ast <= A_ROM;
                end
                // while (pfrac & ~0xffff): one position step and one fetch
                A_ROM: begin
                    if (cur_pfrac[24:16] == 9'd0) ast <= A_RVB_RMW;
                    else begin
                        cur_pfrac <= cur_pfrac - 25'h10000;
                        cur_pos   <= neg_dir ? cur_pos - 24'd1 : cur_pos + 24'd1;
                        cur_pval  <= cur_val;
                        ast <= A_ROMW;
                    end
                end
                A_ROMW: begin
                    if (!rrom_req) begin if (!strm_req) begin rrom_addr <= fetch_addr; rrom_req <= 1'b1; end end
                    else if (rrom_ack) begin
                        rrom_req <= 1'b0; rbyte <= rom_q;
                        ast <= is_16 ? A_ROM2 : A_DEC;
                    end
                end
                A_ROM2: begin
                    if (!rrom_req) begin if (!strm_req) begin rrom_addr <= {cur_pos[21:1], 1'b1}; rrom_req <= 1'b1; end end
                    else if (rrom_ack) begin rrom_req <= 1'b0; rbyte2 <= rom_q; ast <= A_DEC; end
                end
                A_DEC: begin
                    logic signed [16:0] nv; logic endmark;
                    if (is_16) begin
                        nv = $signed({rbyte2[7], rbyte2, rbyte}); endmark = ({rbyte2, rbyte} == 16'h8000);
                    end else if (is_dpcm) begin
                        logic [3:0] nib; nib = cur_pos[0] ? rbyte[7:4] : rbyte[3:0];
                        endmark = (rbyte == 8'h88);
                        nv = cur_pval + dpcm(nib);
                        if (nv > 17'sd32767) nv = 17'sd32767;
                        if (nv < -17'sd32768) nv = -17'sd32768;
                    end else begin
                        nv = $signed({rbyte[7], rbyte, 8'd0}); endmark = (rbyte == 8'h80);
                    end
                    if (endmark && loop_en) begin
                        // jump to the loop point and refetch there
                        cur_pos <= is_dpcm ? {loop_pos[22:0], 1'b0} : loop_pos;
                        ast <= A_ROMW;
                    end else if (endmark) begin
                        ko_we <= 1'b1; ko_ch <= ch;            // keyoff
                        cur_val <= '0; ast <= A_RVB_RMW;
                    end else begin
                        cur_val <= nv; ast <= A_ROM;
                    end
                end

                A_RVB_RMW: begin
                    lval <= lval + (($signed(cur_val) * $signed({1'b0, lvol})) >>> 14);
                    rval <= rval + (($signed(cur_val) * $signed({1'b0, rvol})) >>> 14);
                    rvb_addr <= 13'(rdelta + reverb_pos);
                    ast <= A_RVB_RD2;
                end
                A_RVB_RD2: ast <= A_RVB_WR;                    // rvb_q catches up with rvb_addr
                A_RVB_WR: begin
                    // the ring holds int16; MAME truncates the scaled sample the same way
                    /* verilator lint_off UNUSEDSIGNAL */
                    logic signed [31:0] add;
                    /* verilator lint_on UNUSEDSIGNAL */
                    add = ($signed(cur_val) * $signed({1'b0, rbvol})) >>> 14;
                    rvb_we <= 1'b1;                              // at rvb_addr, the entry just read
                    rvb_wdata <= 16'($signed(rvb_q) + add[15:0]);
                    if (is_dpcm) begin
                        ch_pfrac[ch] <= {cur_pos[0], cur_pfrac[15:1]};
                        ch_pos[ch]   <= {1'b0, cur_pos[23:1]};
                    end else begin
                        ch_pfrac[ch] <= cur_pfrac[15:0]; ch_pos[ch] <= cur_pos;
                    end
                    ch_val[ch] <= cur_val[15:0]; ch_pval[ch] <= cur_pval[15:0];
                    // position write-back unless 0x22f bit 7 holds the registers
                    if (!greg[6'h2f][7]) begin
                        wb_we <= 1'b1; wb_ch <= ch; wb_pos <= is_dpcm ? {1'b0, cur_pos[23:1]} : cur_pos;
                    end
                    ast <= A_NEXT;
                end
                A_NEXT: begin
                    if (ch == 3'd7) ast <= A_OUT;
                    else begin ch <= ch + 3'd1; ast <= A_CH; end
                end
                A_OUT: begin
                    reverb_pos <= reverb_pos + 13'd1;
                    snd_l <= (lval > 32'sd32767) ? 16'h7fff : (lval < -32'sd32768) ? 16'h8000 : lval[15:0];
                    snd_r <= (rval > 32'sd32767) ? 16'h7fff : (rval < -32'sd32768) ? 16'h8000 : rval[15:0];
                    ast <= A_IDLE;
                end
                default: ast <= A_IDLE;
            endcase
        end
    end
    /* verilator lint_off UNUSEDSIGNAL */
    wire unused = rd_d;
    /* verilator lint_on UNUSEDSIGNAL */
endmodule
