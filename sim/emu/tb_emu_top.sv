// The real MiSTer top (Gaiapolis.sv's `emu`) with its framework dependencies stubbed
// (sim/emu/hps_io_stub.sv, pll_stub.sv) and a behavioural SDRAM and Avalon DDR3 on its
// pins. sim/emu/tb_emu.cpp plays the HPS: it streams the ROM image and the EEPROM
// default through the ioctl port, sets the OSD options, and captures the video both as
// the scaler would receive it (VGA_*) and as screen_rotate leaves it in DDR3.
`default_nettype none
module tb_emu_top #(
    parameter int DDR_LAT      = 24,
    parameter int DDR_BUSY_PCT = 10
) (
    input  logic        CLK_50M,
    input  logic        RESET,
    output logic        CLK_VIDEO, CE_PIXEL,
    output logic  [7:0] VGA_R, VGA_G, VGA_B,
    output logic        VGA_HS, VGA_VS, VGA_DE,
    output logic [15:0] AUDIO_L, AUDIO_R,
    output logic        FB_EN,
    output logic [11:0] FB_WIDTH, FB_HEIGHT,
    output logic [12:0] VIDEO_ARX, VIDEO_ARY
);
    wire  [45:0] HPS_BUS;
    wire         VGA_F1, VGA_SCALER, VGA_DISABLE, HDMI_FREEZE, HDMI_BLACKOUT, HDMI_BOB_DEINT;
    wire   [1:0] VGA_SL, LED_POWER, LED_DISK, BUTTONS, AUDIO_MIX;
    wire   [4:0] FB_FORMAT; wire [31:0] FB_BASE; wire [13:0] FB_STRIDE; wire FB_FORCE_BLANK;
    wire         LED_USER, AUDIO_S;
    wire   [3:0] ADC_BUS;
    wire         SD_SCK, SD_MOSI, SD_CS;
    wire         DDRAM_CLK, DDRAM_BUSY, DDRAM_DOUT_READY, DDRAM_RD, DDRAM_WE;
    wire   [7:0] DDRAM_BURSTCNT, DDRAM_BE;
    wire  [28:0] DDRAM_ADDR;
    wire  [63:0] DDRAM_DOUT, DDRAM_DIN;
    wire         SDRAM_CLK, SDRAM_CKE, SDRAM_DQML, SDRAM_DQMH, SDRAM_nCS, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nWE;
    wire  [12:0] SDRAM_A; wire [1:0] SDRAM_BA; wire [15:0] SDRAM_DQ;
    wire         UART_RTS, UART_TXD, UART_DTR;
    wire   [6:0] USER_OUT;
    wire  [11:0] HDMI_WIDTH = 12'd1920, HDMI_HEIGHT = 12'd1080;
    wire         FB_VBL = 1'b0, FB_LL = 1'b0;
    wire         CLK_AUDIO = 1'b0, SD_MISO = 1'b0, SD_CD = 1'b0, UART_CTS = 1'b0, UART_RXD = 1'b0, UART_DSR = 1'b0, OSD_STATUS = 1'b0;
    wire   [6:0] USER_IN = 7'h7f;

    emu u_emu (.*);

    sdram_model #(.PHASE_LAG(0), .AW(24)) chip (
        .clk(CLK_50M), .dq(SDRAM_DQ), .a(SDRAM_A), .ba(SDRAM_BA), .dqml(SDRAM_DQML), .dqmh(SDRAM_DQMH),
        .cs_n(SDRAM_nCS), .ras_n(SDRAM_nRAS), .cas_n(SDRAM_nCAS), .we_n(SDRAM_nWE), .cke(SDRAM_CKE)
    );
    ddr_model #(.AW(20), .LAT(DDR_LAT), .BUSY_PCT(DDR_BUSY_PCT), .FB_STORE(1)) ddr (
        .clk(DDRAM_CLK), .DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(DDRAM_BURSTCNT), .DDRAM_ADDR(DDRAM_ADDR),
        .DDRAM_DOUT(DDRAM_DOUT), .DDRAM_DOUT_READY(DDRAM_DOUT_READY),
        .DDRAM_RD(DDRAM_RD), .DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE), .DDRAM_WE(DDRAM_WE)
    );
    /* verilator lint_off UNUSEDSIGNAL */
    wire unused = ^{VGA_F1, VGA_SCALER, VGA_DISABLE, HDMI_FREEZE, HDMI_BLACKOUT, HDMI_BOB_DEINT, VGA_SL, LED_POWER, LED_DISK,
                    BUTTONS, AUDIO_MIX, FB_FORMAT, FB_BASE, FB_STRIDE, FB_FORCE_BLANK, LED_USER, AUDIO_S, ADC_BUS, SD_SCK,
                    SD_MOSI, SD_CS, SDRAM_CLK, UART_RTS, UART_TXD, UART_DTR, USER_OUT};
    /* verilator lint_on UNUSEDSIGNAL */
endmodule
