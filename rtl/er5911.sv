//------------------------------------------------------------------------------
// ER5911 serial EEPROM, 128 x 8, as MAME's eeprom_serial_er5911_device models
// it (eepromser.cpp): a start bit, a 2-bit opcode and a 9-bit address field
// (only the low 7 bits select a cell) on rising CLK while CS is high; READ
// shifts data out MSB first after a dummy 0; WRITE takes 8 more data bits;
// opcode 0 uses the top two address bits for LOCK / ERASEALL / UNLOCK. ERASE
// maps to WRITE on this part. DO reads 1 when not shifting data out (pull-up),
// READY reads 0 for a while after a write. tools/eeprom_replay.py checks this
// protocol against MAME's pin traffic.
//
// Contents load through the byte port: the 128-byte default image in the ROM
// file at start, and a saved image later if the platform provides one.
//------------------------------------------------------------------------------
`default_nettype none

module er5911 #(
    parameter int BUSY_CLOCKS = 960     // ~10 us at 96 MHz after a write
) (
    input  logic       clk,
    input  logic       reset,

    // serial pins, sampled every clk
    input  logic       cs,
    input  logic       sclk,
    input  logic       di,
    output logic       dout,
    output logic       ready,

    // byte port: load / readback of the array
    input  logic       ld_we,
    input  logic [6:0] ld_addr,
    input  logic [7:0] ld_wdata,
    output logic [7:0] ld_q,

    output logic       dirty            // toggles on every array write
);
    logic [7:0] mem [128];

    typedef enum logic [2:0] {
        S_RESET, S_START, S_CMD, S_READ, S_WDATA, S_WAIT
    } state_t;
    state_t st;

    logic        cs_d, clk_d;
    logic  [9:0] cmdacc;          // the first 10 of the 11 command bits; the 11th arrives with di
    logic  [3:0] nbits;
    logic  [7:0] shreg;
    logic        do_bit;
    logic        locked;
    logic [15:0] busy;
    logic  [6:0] addr;

    wire cs_rise  = cs & ~cs_d;
    wire cs_fall  = ~cs & cs_d;
    wire clk_rise = sclk & ~clk_d;

    // the array is a block RAM: one write port shared by ERASEALL (a sweep
    // of 128 cycles inside the busy time), the serial WRITE and the byte
    // port's load; the READ command's byte is fetched on entering S_READ,
    // long before the first clock asks for its top bit
    logic       ser_we, ser_erase, erase_run;
    logic [6:0] ser_addr, erase_i, rd_addr;
    logic [7:0] ser_wdata, rd_q;
    logic       rd_first;
    // the byte port loads during reset too: the bench and the Pocket both
    // hold the machine in reset while the image (and a save) arrive
    always_ff @(posedge clk) begin
        ld_q <= mem[ld_addr];
        rd_q <= mem[rd_addr];
        if (reset) begin erase_run <= 1'b0; erase_i <= '0; end
        else if (ser_erase) begin erase_run <= 1'b1; erase_i <= '0; end
        else if (erase_run) begin
            erase_i <= erase_i + 7'd1;
            if (erase_i == 7'd127) erase_run <= 1'b0;
        end
        if (!reset && erase_run) mem[erase_i] <= 8'hff;
        else if (!reset && ser_we) mem[ser_addr] <= ser_wdata;
        else if (ld_we)  mem[ld_addr] <= ld_wdata;
    end

    assign dout  = (st == S_READ) ? do_bit : 1'b1;
    assign ready = (busy == 16'd0);

    always_ff @(posedge clk) begin
        ser_we <= 1'b0; ser_erase <= 1'b0;
        if (reset) begin
            st <= S_RESET; cs_d <= 1'b0; clk_d <= 1'b0; busy <= '0;
            locked <= 1'b1; do_bit <= 1'b1; nbits <= '0; dirty <= 1'b0;
        end else begin
            cs_d  <= cs;
            clk_d <= sclk;
            if (busy != 16'd0) busy <= busy - 16'd1;

            if (cs_fall) st <= S_RESET;
            else case (st)
                S_RESET: if (cs_rise) st <= S_START;

                // a 1 on DI at a rising clock is the start bit (edges that
                // coincide with CS rising are ignored, as MAME does)
                S_START: if (clk_rise && di && ready && !cs_rise) begin
                    cmdacc <= '0; nbits <= '0; st <= S_CMD;
                end

                S_CMD: if (clk_rise) begin
                    cmdacc <= {cmdacc[8:0], di};
                    nbits  <= nbits + 4'd1;
                    if (nbits == 4'd10) begin
                        // full 11 bits present after this shift
                        logic [10:0] c; c = {cmdacc, di};
                        addr <= c[6:0];
                        case (c[10:9])
                            2'd0: begin
                                case (c[8:7])
                                    2'd0: locked <= 1'b1;                      // LOCK
                                    2'd2: begin                                // ERASEALL
                                        if (!locked) begin
                                            ser_erase <= 1'b1;
                                            dirty <= ~dirty; busy <= 16'(BUSY_CLOCKS);
                                        end
                                    end
                                    2'd3: locked <= 1'b0;                      // UNLOCK
                                    default: ;
                                endcase
                                st <= S_WAIT;
                            end
                            2'd2: begin                                        // READ
                                rd_addr <= c[6:0]; rd_first <= 1'b1; do_bit <= 1'b0; nbits <= '0;
                                st <= S_READ;
                            end
                            default: begin                                     // WRITE (1 and 3)
                                shreg <= '0; nbits <= '0; st <= S_WDATA;
                            end
                        endcase
                    end
                end

                // MSB first; the first rising edge presents bit 7 (of the byte
                // the RAM fetched on entry), then ones after the data
                S_READ: if (clk_rise) begin
                    if (rd_first) begin do_bit <= rd_q[7]; shreg <= {rd_q[6:0], 1'b1}; rd_first <= 1'b0; end
                    else begin do_bit <= shreg[7]; shreg <= {shreg[6:0], 1'b1}; end
                end

                S_WDATA: if (clk_rise) begin
                    shreg <= {shreg[6:0], di};
                    nbits <= nbits + 4'd1;
                    if (nbits == 4'd7) begin
                        if (!locked) begin
                            ser_we <= 1'b1; ser_addr <= addr; ser_wdata <= {shreg[6:0], di};
                            dirty <= ~dirty; busy <= 16'(BUSY_CLOCKS);
                        end
                        st <= S_WAIT;
                    end
                end

                S_WAIT: ;                                   // CS falling resets
                default: st <= S_RESET;
            endcase
        end
    end
endmodule
