//------------------------------------------------------------------------------
// Multi-port SDR SDRAM controller (the Pocket Gaiapolis core's, carried over
// to MiSTer; the port structure below is unchanged).
//
// Pin-level behaviour (CL2, single-word accesses with auto-precharge, 7-clock
// write cycle) is carried over from the Punch-Out!! core's sdram16.sv, which
// is proven on the Pocket at 96 MHz. On the Pocket the chip was clocked in
// phase and the read data captured at READ+4; the MiSTer build clocks the chip
// from a shifted PLL output and captures at READ+3 (see the end of the file).
// The port structure:
//
//   * six random-access 16-bit clients (docs/rtl-conventions.md "memory
//     request interface": level req, one-cycle ack, shared rdata bus), fixed
//     priority client 0 first;
//   * one burst client for the display line fetch: up to 512 consecutive
//     words from one open row (re-activating across SDRAM row boundaries),
//     delivered one word per b_wr strobe with its index. Bursts are chunked so
//     a random client never waits more than a chunk (BURST_CHUNK words);
//   * refresh every CYCLES_PER_REFRESH clocks, 7.8 us.
//
// Address mapping (word address a[24:1]): bank = a[24:23], row = a[22:10],
// column = a[9:1]. BL=1 so a burst is a run of READ commands in an open row,
// one every 2 clocks (`burst_slow` = 1 stretches that to the 5-clock spacing
// the Punch-Out!! core used, selectable from the Pocket menu as a diagnostic).
//------------------------------------------------------------------------------
`default_nettype none

module sdram_ctrl #(
    parameter [13:0] CYCLES_PER_REFRESH = 14'd750,   // 64 ms / 8192 rows at 96 MHz
    parameter        NCLI = 6
) (
    input  logic        clk,          // 96 MHz
    input  logic        clk_pin,      // same frequency, phase-shifted, drives SDRAM_CLK
    input  logic        init,         // reset / (re)initialise the chip
    input  logic        rd_late,      // 1: capture read data at READ+4 (in-phase chip clock)
    input  logic        burst_slow,   // 1: one burst READ every 5 clocks instead of 2
    output logic        ready,        // init complete

    // chip
    inout  wire  [15:0] SDRAM_DQ,
    output logic [12:0] SDRAM_A,
    output logic        SDRAM_DQML, SDRAM_DQMH,
    output logic  [1:0] SDRAM_BA,
    output logic        SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS,
    output logic        SDRAM_CKE, SDRAM_CLK,

    // random-access clients
    input  logic [24:1] c_addr  [NCLI],
    input  logic        c_req   [NCLI],
    input  logic        c_we    [NCLI],
    input  logic [15:0] c_wdata [NCLI],
    input  logic  [1:0] c_be    [NCLI],
    output logic        c_ack   [NCLI],
    output logic [15:0] rdata,        // shared: valid on the cycle of c_ack[i]

    // burst client
    input  logic [24:1] b_addr,       // first word
    input  logic  [9:0] b_len,        // number of words, 1..512
    input  logic        b_req,        // level; hold until b_done
    input  logic        b_abort,      // level: end the burst as soon as possible; b_done then
                                      // follows, the words delivered so far being all there are
    output logic        b_wr,         // one word delivered
    output logic  [9:0] b_idx,        // its index (0..b_len-1)
    output logic [15:0] b_data,
    output logic        b_done,       // pulse; b_req may drop
    // burst writes (GSP shift-register-transfer rows): b_we with b_req selects
    // a run of WRITEs in the open row, one every 2 clocks; the client presents
    // b_wdata for word b_widx (its own index of the next word to issue), which
    // the 2-clock spacing gives a registered RAM read time to settle
    input  logic        b_we,
    input  logic [15:0] b_wdata,
    input  logic  [1:0] b_be,         // byte enables for word b_widx (writes)
    output logic  [9:0] b_widx
);
    localparam BURST_CHUNK = 10'd32;

    // ---- pins ---------------------------------------------------------------
    logic [15:0] dq_out;
    logic        dq_oe;
    assign SDRAM_DQ  = dq_oe ? dq_out : 16'bZ;
    logic  [2:0] command;
    assign SDRAM_nRAS = command[2];
    assign SDRAM_nCAS = command[1];
    assign SDRAM_nWE  = command[0];
    assign SDRAM_nCS  = 1'b0;
    assign SDRAM_CKE  = 1'b1;

    localparam [2:0] CMD_NOP = 3'b111, CMD_ACTIVE = 3'b011, CMD_READ = 3'b101,
                     CMD_WRITE = 3'b100, CMD_PRECHARGE = 3'b010,
                     CMD_AUTO_REFRESH = 3'b001, CMD_LOAD_MODE = 3'b000;
    // BL=1, sequential, CL2, standard, single-write
    localparam [12:0] MODE = {3'b000, 1'b1, 2'b00, 3'd2, 1'b0, 3'b000};
    localparam [13:0] STARTUP_CYCLES = 14'd12100;     // > 100 us
    localparam [13:0] REFRESH_MAX    = 14'h3fff;

    // ---- read capture pipeline ------------------------------------------------
    // A tag rides along with every READ: {valid, is_burst, client, idx}. The
    // tag reaching stage 0 marks the cycle dq_in holds that READ's data.
    localparam TAGW = 1 + 1 + 3 + 10;
    logic [TAGW-1:0] cap [0:5];
    logic [15:0] dq_in;
    wire  [TAGW-1:0] cap_now = cap[0];

    // ---- state ---------------------------------------------------------------
    typedef enum logic [3:0] {
        S_STARTUP, S_IDLE, S_ARB, S_OPEN1, S_OPEN2, S_WAIT5, S_WAIT4, S_WAIT3, S_WAIT2, S_WAIT1,
        S_REF, S_BOPEN1, S_BOPEN2, S_BREAD, S_BEND
    } state_t;
    state_t state;

    logic [13:0] refresh_count;
    // The refresh-due comparison is registered one clock ahead. Evaluated in
    // place inside S_IDLE it put a 14-bit compare in series with the branch
    // select that loads SDRAM_A, which was the last path missing 96 MHz
    // setup; as a single registered bit the cone to SDRAM_A is short. It is
    // It compares the current count (no extra adder -- an incremented compare
    // cost 6 ALMs we do not have), so the refresh is issued one clock later
    // than the in-place test would have: irrelevant against a 750-clock
    // interval, and the interval itself is unchanged.
    logic        refresh_due;
    logic  [2:0] cur;            // client being served
    logic  [9:1] cur_col;
    logic        cur_we;
    logic [15:0] cur_wdata;
    logic  [1:0] cur_be;
    logic  [2:0] wait_n;

    // burst context
    logic        b_active;       // a burst is in progress (possibly paused)
    logic [24:1] b_next;         // next word address
    logic  [9:0] b_remain;       // words still to issue
    logic  [9:0] b_issued;       // index of the next word
    logic  [5:0] b_chunk;        // words issued in this chunk
    logic        b_yield;        // after a chunk, let one random client in
    logic        b_accepted;     // b_req latched; cleared when it drops
    logic        b_aborted;      // this burst was cut short (b_done even if nothing was issued)
    logic        b_is_we;        // this burst is a write
    logic  [2:0] b_gap;
    assign b_widx = b_issued;

    // any random client pending? Round-robin: the first pending client after
    // the one served last, so a saturating client cannot starve the others.
    //
    // The scan and the c_addr[] mux behind it are ~15 ns at 96 MHz, and a
    // client's `req` is a genuinely single-cycle input: it can rise on the
    // clock before the controller happens to be in S_IDLE, so no multicycle
    // can cover req -> SDRAM_A. The two halves are therefore split by the
    // S_ARB state: S_IDLE registers the winner (req -> pick -> cur, ~5.5 ns)
    // and S_ARB drives the row address from the registered index
    // (c_addr -> mux -> SDRAM_A, ~9 ns). Both halves are honest single-cycle
    // paths. It costs one clock per random access (9 instead of 8); the
    // random clients are all cen-throttled well below that rate and the
    // display line fetch uses the burst port, which is untouched.
    logic        any_req;
    logic  [2:0] pick, last;
    // Registered copy, used ONLY by the burst branch's yield gate below. That
    // branch drives SDRAM_A, so a combinational any_req there would put c_req
    // and c_ack back on a single-cycle path to the address pins -- the very
    // thing S_ARB exists to avoid. Letting the gate see the request one clock
    // late only means a burst chunk may start one clock before a random client
    // is noticed; the client is then served at the end of that chunk exactly as
    // before.
    logic        any_req_q;
    always_ff @(posedge clk) any_req_q <= any_req;

    // Registered burst-open decision. Evaluated in place, the
    // b_active && !(b_yield && any_req_q) test sat in series with the b_next
    // mux onto the SDRAM address pins and was the last path missing setup.
    // As a register it is one bit into that branch; it is re-qualified with
    // the live b_active at the use site so a burst that ended on the
    // previous clock can never be re-opened from a stale decision. Being one
    // clock late only delays a chunk open by a clock, at chunk boundaries.
    logic        b_start;
    always_ff @(posedge clk) b_start <= b_active && !(b_yield && any_req_q) && !refresh_due;
    always_comb begin
        any_req = 1'b0; pick = 3'd0;
        for (int k = NCLI; k >= 1; k--) begin
            logic [2:0] i;
            i = 3'((int'(last) + k) % NCLI);
            if (c_req[i] && !c_ack[i]) begin any_req = 1'b1; pick = i; end
        end
    end

    always_ff @(posedge clk) begin
        // defaults
        command <= CMD_NOP;
        dq_oe   <= 1'b0;
        b_wr    <= 1'b0;
        b_done  <= 1'b0;
        for (int i = 0; i < NCLI; i++) c_ack[i] <= 1'b0;
        refresh_count <= refresh_count + 14'd1;
        refresh_due   <= (refresh_count > CYCLES_PER_REFRESH);

        // capture pipeline: dq_in registered every clock (I/O cell register)
        dq_in <= SDRAM_DQ;
        for (int i = 0; i < 5; i++) cap[i] <= cap[i+1];
        cap[5] <= '0;
        if (cap_now[TAGW-1]) begin
            rdata <= dq_in;
            if (cap_now[TAGW-2]) begin
                b_wr   <= 1'b1;
                b_idx  <= cap_now[9:0];
                b_data <= dq_in;
            end else begin
                c_ack[cap_now[12:10]] <= 1'b1;
            end
        end

        case (state)
            S_STARTUP: begin
                SDRAM_A  <= '0;
                SDRAM_BA <= '0;
                ready    <= 1'b0;
                if (refresh_count == REFRESH_MAX - 14'd31) begin
                    command <= CMD_PRECHARGE; SDRAM_A[10] <= 1'b1;
                end
                if (refresh_count == REFRESH_MAX - 14'd23) command <= CMD_AUTO_REFRESH;
                if (refresh_count == REFRESH_MAX - 14'd15) command <= CMD_AUTO_REFRESH;
                if (refresh_count == REFRESH_MAX - 14'd7) begin
                    command <= CMD_LOAD_MODE; SDRAM_A <= MODE;
                end
                if (refresh_count == 14'd0) begin
                    state <= S_IDLE; ready <= 1'b1;
                end
            end

            S_IDLE: begin
                if (refresh_due) begin
                    command <= CMD_AUTO_REFRESH;
                    refresh_count <= '0;
                    refresh_due   <= 1'b0;      // overrides the default above
                    wait_n <= 3'd6;              // tRFC 66 ns
                    state  <= S_REF;
                end
                else if (b_active && b_abort) begin
                    // cut short between chunks: nothing is in flight, so this is
                    // the end of the burst; b_done follows from S_WAIT1
                    b_active <= 1'b0; b_remain <= '0; b_aborted <= 1'b1;
                    state <= S_WAIT1;
                end
                else if (b_start && b_active) begin
                    // (re)open the row for the next chunk
                    command  <= CMD_ACTIVE;
                    b_chunk  <= '0;
                    b_gap    <= '0;
                    state    <= S_BOPEN1;
                end
                else if (any_req) begin
                    cur       <= pick;
                    last      <= pick;
                    b_yield   <= 1'b0;
                    state     <= S_ARB;
                end
                // The burst row address is loaded outside the priority chain:
                // AUTO REFRESH ignores the address pins and nothing else drives
                // SDRAM_A in S_IDLE, so whether the refresh branch wins this
                // clock need not be in SDRAM_A's cone (refresh_due -> SDRAM_A[10]
                // missed setup by 0.07 ns on one placement). If the refresh does
                // win, the row is simply loaded again when the burst reopens.
                if (b_start && b_active) begin
                    SDRAM_A  <= b_next[22:10];
                    SDRAM_BA <= b_next[24:23];
                end
            end

            // ---- single access -----------------------------------------------
            // Grant: the winner is now a register, so the client address mux
            // and the ACTIVE command are one clock clear of the request scan.
            S_ARB: begin
                cur_col   <= c_addr[cur][9:1];
                cur_we    <= c_we[cur];
                cur_wdata <= c_wdata[cur];
                cur_be    <= c_be[cur];
                SDRAM_A   <= c_addr[cur][22:10];
                SDRAM_BA  <= c_addr[cur][24:23];
                command   <= CMD_ACTIVE;
                state     <= S_OPEN1;
            end
            S_OPEN1: state <= S_OPEN2;                          // tRCD
            S_OPEN2: begin
                // A10 = auto precharge; A12:11 drive DQM (write byte enables)
                SDRAM_A <= {cur_we ? ~cur_be : 2'b00, 2'b10, cur_col};
                if (cur_we) begin
                    command <= CMD_WRITE;
                    dq_out  <= cur_wdata;
                    dq_oe   <= 1'b1;
                    c_ack[cur] <= 1'b1;
                    state   <= S_WAIT3;                         // 7-clock write cycle (tRC)
                end else begin
                    command <= CMD_READ;
                    cap[rd_late ? 4 : 3] <= {1'b1, 1'b0, cur, 10'd0};
                    state   <= S_WAIT5;
                end
            end
            S_WAIT5: state <= S_WAIT4;
            S_WAIT4: state <= S_WAIT3;
            S_WAIT3: state <= S_WAIT2;
            S_WAIT2: state <= S_WAIT1;
            S_WAIT1: state <= S_IDLE;

            S_REF: begin
                wait_n <= wait_n - 3'd1;
                if (wait_n == 3'd0) state <= S_IDLE;
            end

            // ---- burst -------------------------------------------------------
            S_BOPEN1: state <= S_BOPEN2;
            S_BOPEN2: state <= S_BREAD;
            S_BREAD: begin
                // issue a READ (no auto precharge) every 2 or 5 clocks
                if (b_gap == 3'd0 && b_abort) begin
                    // cut short mid-chunk: no more READs; what was issued still lands
                    b_remain <= '0; b_aborted <= 1'b1;
                    state  <= S_BEND;
                    wait_n <= 3'd1;
                end else if (b_gap == 3'd0) begin
                    SDRAM_A <= {b_is_we ? ~b_be : 2'b00, 2'b00, b_next[9:1]};   // A12:11 = DQM
                    if (b_is_we) begin
                        command <= CMD_WRITE;
                        dq_out  <= b_wdata;
                        dq_oe   <= 1'b1;
                    end else begin
                        command <= CMD_READ;
                        cap[rd_late ? 4 : 3] <= {1'b1, 1'b1, 3'd0, b_issued};
                    end
                    b_next   <= b_next + 24'd1;
                    b_issued <= b_issued + 10'd1;
                    b_remain <= b_remain - 10'd1;
                    b_chunk  <= b_chunk + 6'd1;
                    b_gap    <= burst_slow ? 3'd4 : 3'd1;
                    // stop at: end of burst, end of chunk, end of SDRAM row
                    if (b_remain == 10'd1 || b_chunk == 6'(BURST_CHUNK - 10'd1) || b_next[9:1] == 9'h1ff) begin
                        state  <= S_BEND;
                        wait_n <= 3'd1;
                    end
                end else
                    b_gap <= b_gap - 3'd1;
            end
            S_BEND: begin
                // precharge after the last read's data has left the pins, then tRP
                wait_n <= wait_n - 3'd1;
                if (wait_n == 3'd0) begin
                    command <= CMD_PRECHARGE; SDRAM_A[10] <= 1'b1;
                    state   <= S_WAIT2;
                    b_yield <= 1'b1;
                    if (b_remain == 10'd0) begin
                        b_active <= 1'b0;
                        // b_done after the final capture has certainly landed
                        state <= S_WAIT5;
                    end
                end
            end
            default: state <= S_IDLE;
        endcase

        // accept a burst request (served from the next idle slot)
        if (b_req && !b_active && !b_done && !b_accepted) begin
            b_active <= 1'b1; b_accepted <= 1'b1;
            b_is_we  <= b_we;
            b_next   <= b_addr;
            b_remain <= b_len;
            b_issued <= '0;
            b_yield  <= 1'b0;
            b_aborted <= 1'b0;
        end
        if (!b_req) b_accepted <= 1'b0;

        // burst completion: signalled when the controller returns to idle with
        // nothing left to issue and the pipeline drained
        if (state == S_WAIT1 && !b_active && b_req && !b_done && (b_issued != 10'd0 || b_aborted) && b_remain == 10'd0) begin
            b_done   <= 1'b1;
            b_issued <= '0;
            b_aborted <= 1'b0;
        end

        if (init) begin
            state <= S_STARTUP;
            refresh_count <= REFRESH_MAX - STARTUP_CYCLES;
            refresh_due   <= 1'b0;
            ready <= 1'b0;
            b_active <= 1'b0; b_issued <= '0; b_remain <= '0; b_yield <= 1'b0; b_accepted <= 1'b0; b_aborted <= 1'b0; last <= '0;
            for (int i = 0; i < 6; i++) cap[i] <= '0;
        end
    end

    assign {SDRAM_DQMH, SDRAM_DQML} = SDRAM_A[12:11];

    // MiSTer: the chip's clock is a PLL output shifted about half a period
    // from the controller's (pll/pll_0002.v), taken straight to the pin as
    // JTFRAME's MiSTer builds do. With that phase the read data of a CL2 READ
    // is good at the edge three clocks after the command's (`rd_late` = 0);
    // `rd_late` = 1 samples one clock later, an OSD diagnostic for modules
    // whose chips answer slowly.
    assign SDRAM_CLK = clk_pin;
endmodule
