// End-to-end bench of the MiSTer top (Gaiapolis.sv): plays the HPS. It
//   * resets, waits for the PLL stand-in and the memories,
//   * streams the ROM image through the ioctl port (MRA index 0), a byte per
//     STRIDE clocks and held off by ioctl_wait, then the EEPROM default (index 2),
//   * sets OSD options and runs frames, capturing the picture as the scaler gets it
//     (VGA_*, 376x224) and as screen_rotate leaves it in the DDR3 frame buffer
//     (224x376), and checks the second is the first rotated a quarter turn clockwise,
//   * reads the EEPROM back through the upload path (the save) and compares it.
//
//   tb_emu <image> <eeprom-default-file> <frames> <out-prefix> [diag]
// <image> is the MiSTer-layout image (0x1360000 bytes: the first 0x1360000 of the
// Pocket's gaiapols.rom); the EEPROM default is the 128-byte .nv file.
#include "Vtb_emu_top.h"
#include "Vtb_emu_top___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

static Vtb_emu_top *dut;
static unsigned long long cycles = 0;
#define HPSV(n) dut->rootp->tb_emu_top__DOT__u_emu__DOT__hps_io__DOT__##n
static inline void tick() { dut->CLK_50M = 0; dut->eval(); dut->CLK_50M = 1; dut->eval(); cycles++; }

static const int VIS_W = 376, VIS_H = 224;
static const long IMG_LEN = 0x1360000;
static std::vector<unsigned> frame_now(VIS_W * VIS_H), frame_last(VIS_W * VIS_H), frame_prev(VIS_W * VIS_H);
static int de_count = 0, frames_done = 0, de_last_count = 0;
static bool prev_vs = false;
static unsigned long long last_frame_cycle = 0, frame_period = 0;
static std::vector<unsigned long long> periods;
static bool record_periods = false;
static long long audio_nonzero = 0;
static unsigned errors = 0;

#ifdef PROBE
// signals inside the top level (the bench is built with --public-flat-rw when PROBE is set)
#define EMUV(n) dut->rootp->tb_emu_top__DOT__u_emu__DOT__##n
static unsigned pk_ovl = 0, pk_core = 0, pk_gade = 0, pk_cen = 0, pk_en = 0, pk_arc = 0, pk_vga_any = 0;
static unsigned pk_fix = 0, pk_frz = 0, pk_sd = 0, pk_rt = 0, gb_or = 0, gb_and = 0x3fffff;
// the picture entering the flip stage (the overlay's output), three frames deep, for the Flip Screen check
static std::vector<unsigned> ovl_now(376 * 224), ovl_f1(376 * 224), ovl_f2(376 * 224), ovl_f3(376 * 224);
static int ovl_count = 0; static bool prev_gavs = false;
static void probe() {
    {
        bool gavs = EMUV(ga_vs);
        if (gavs && !prev_gavs) {
            if (ovl_count == 376 * 224) { ovl_f3 = ovl_f2; ovl_f2 = ovl_f1; ovl_f1 = ovl_now; }
            ovl_count = 0;
        }
        prev_gavs = gavs;
        if (EMUV(ga_cen_pix) && EMUV(ga_de)) {
            if (ovl_count < 376 * 224) ovl_now[ovl_count] = ((unsigned)EMUV(ovl_r) << 16) | ((unsigned)EMUV(ovl_g) << 8) | (unsigned)EMUV(ovl_b);
            ovl_count++;
        }
    }
    unsigned ovl = ((unsigned)EMUV(ovl_r) << 16) | ((unsigned)EMUV(ovl_g) << 8) | (unsigned)EMUV(ovl_b);
    if (ovl > pk_ovl) pk_ovl = ovl;
    if ((unsigned)EMUV(ga_rgb) > pk_core) pk_core = EMUV(ga_rgb);
    if (EMUV(ga_de)) pk_gade++;
    if (EMUV(ga_cen_pix)) pk_cen++;
    pk_en = (EMUV(status)[0] >> 9) & 1;
    {
        { unsigned gb = EMUV(gamma_bus); gb_or |= gb; gb_and &= gb; }
        unsigned fix = EMUV(arcade_video__DOT__RGB_fix);
        if (fix > pk_fix) pk_fix = fix;
        if (EMUV(arcade_video__DOT__video_mixer__DOT__frz)) pk_frz++;
        if (EMUV(arcade_video__DOT__video_mixer__DOT__scandoubler)) pk_sd++;
        unsigned rt = EMUV(arcade_video__DOT__video_mixer__DOT__rt) | EMUV(arcade_video__DOT__video_mixer__DOT__gt) | EMUV(arcade_video__DOT__video_mixer__DOT__bt);
        if (rt) pk_rt++;
    }
    if (dut->VGA_R | dut->VGA_G | dut->VGA_B) pk_vga_any++;
    if (dut->VGA_DE && (dut->VGA_R | dut->VGA_G | dut->VGA_B)) pk_arc++;
}
#endif
// the geometry of the analog picture as the monitor gets it: lines from the vsync pulse to the first row with picture,
// the number of rows, and where each row starts and how wide it is, in clocks from the hsync pulse before it
static bool g_prev_hs = false, g_prev_de = false;
static unsigned long long g_hs_clk = 0, g_de_clk = 0;
static int g_line = 0, g_rows = 0, g_lines_frame = 0; static long g_first = -1; static unsigned long long g_vs_clk = 0;
static long g_smin = 1 << 30, g_smax = -1, g_wmin = 1 << 30, g_wmax = -1;
static int geo_rows = 0, geo_lines = 0; static long geo_first = -1;
static long geo_smin = 0, geo_smax = 0, geo_wmin = 0, geo_wmax = 0;
static void video_watch() {
#ifdef PROBE
    probe();
#endif
    if (audio_nonzero == 0 && (dut->AUDIO_L != 0 || dut->AUDIO_R != 0)) audio_nonzero = 1;
    {   // geometry at clock level (VGA_HS, VGA_DE, and the frame's end at VGA_VS)
        bool hs = dut->VGA_HS, de = dut->VGA_DE;
        if (hs && !g_prev_hs) { g_line++; g_lines_frame++; g_hs_clk = cycles; }
        if (de && !g_prev_de) {
            long s = (long)(cycles - g_hs_clk); g_de_clk = cycles; g_rows++;
            if (g_first < 0) g_first = (long)(cycles - g_vs_clk);
            if (s < g_smin) g_smin = s; if (s > g_smax) g_smax = s;
        }
        if (!de && g_prev_de) { long w = (long)(cycles - g_de_clk); if (w < g_wmin) g_wmin = w; if (w > g_wmax) g_wmax = w; }
        g_prev_hs = hs; g_prev_de = de;
        if (dut->VGA_VS && !prev_vs) {
            geo_first = g_first; geo_rows = g_rows; geo_lines = g_lines_frame; geo_smin = g_smin; geo_smax = g_smax; geo_wmin = g_wmin; geo_wmax = g_wmax;
            g_vs_clk = cycles; g_line = 0; g_lines_frame = 0; g_first = -1; g_rows = 0; g_smin = 1 << 30; g_smax = -1; g_wmin = 1 << 30; g_wmax = -1;
        }
    }
    bool vs = dut->VGA_VS;
    if (vs && !prev_vs) {                       // a frame ends
        if (de_count == VIS_W * VIS_H) { frame_prev = frame_last; frame_last = frame_now; }
        de_last_count = de_count;
        frame_period = cycles - last_frame_cycle; last_frame_cycle = cycles;
        if (record_periods) periods.push_back(frame_period);
        de_count = 0; frames_done++;
    }
    prev_vs = vs;
    if (dut->CE_PIXEL && dut->VGA_DE) {
        if (de_count < VIS_W * VIS_H) frame_now[de_count] = ((unsigned)dut->VGA_R << 16) | ((unsigned)dut->VGA_G << 8) | dut->VGA_B;
        de_count++;
    }
}
static void run(long n) { while (n--) { tick(); video_watch(); } }

static void set_status(int bit, int v) {
    int w = bit / 32, b = bit % 32;
    unsigned x = HPSV(r_status)[w];
    HPSV(r_status)[w] = v ? (x | (1u << b)) : (x & ~(1u << b));
}

// stream bytes of data[0..n) as one download of the given index; stride = clocks per byte
static void download(int index, const unsigned char *data, long n, int stride, long addr0 = 0) {
    HPSV(r_index) = index; HPSV(r_download) = 1; HPSV(r_addr) = addr0;
    run(8);
    for (long i = 0; i < n; i++) {
        long guard = 0;
        while (HPSV(r_wait_seen) && guard++ < 1000000) run(1);
        HPSV(r_addr) = addr0 + i; HPSV(r_dout) = data[i]; HPSV(r_wr) = 1; run(1);
        HPSV(r_wr) = 0; run(stride - 1);
    }
    run(40);
    HPSV(r_download) = 0; HPSV(r_index) = 0;
    run(8);
}

static void write_ppm(const char *path, const std::vector<unsigned> &px, int w, int h) {
    FILE *f = fopen(path, "wb"); if (!f) return;
    fprintf(f, "P6\n%d %d\n255\n", w, h);
    for (int i = 0; i < w * h; i++) { unsigned v = px[i]; fputc((v >> 16) & 255, f); fputc((v >> 8) & 255, f); fputc(v & 255, f); }
    fclose(f);
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 5) { fprintf(stderr, "usage: %s <image> <eeprom.nv> <frames> <out-prefix> [diag]\n", argv[0]); return 2; }
    int frames = atoi(argv[3]); const char *pre = argv[4]; bool diag = argc > 5 && atoi(argv[5]); bool noload = argc > 6 && atoi(argv[6]);
    std::vector<unsigned char> img(IMG_LEN), nv(128);
    FILE *f = fopen(argv[1], "rb"); if (!f) { fprintf(stderr, "cannot open %s\n", argv[1]); return 1; }
    if (fread(img.data(), 1, IMG_LEN, f) != (size_t)IMG_LEN) { fprintf(stderr, "short image\n"); return 1; } fclose(f);
    f = fopen(argv[2], "rb"); if (!f) { fprintf(stderr, "cannot open %s\n", argv[2]); return 1; }
    if (fread(nv.data(), 1, 128, f) != 128) { fprintf(stderr, "short eeprom\n"); return 1; } fclose(f);

    dut = new Vtb_emu_top;
    dut->RESET = 1; run(40); dut->RESET = 0;
    if (diag) set_status(9, 1);                 // diagnostic overlay + memory test at the end of the load
    bool flip = getenv("FLIP") && atoi(getenv("FLIP"));
    if (flip) set_status(12, 1);                // Flip Screen
    bool tmame = getenv("TIMING_MAME") && atoi(getenv("TIMING_MAME"));
    if (tmame) set_status(13, 1);               // Video timing: MAME's (the default is the board's)
    {   // CRT Adjust (status[14] on, [19:15] H-Size, [26:20] H-Position, [31:27] V-Shift), values as the OSD menu counts them
        auto field = [&](int lo, int w, int v) { for (int i = 0; i < w; i++) set_status(lo + i, (v >> i) & 1); };
        if (getenv("CRT") && atoi(getenv("CRT"))) set_status(14, 1);
        if (getenv("HSIZE")) { int v = atoi(getenv("HSIZE")); field(15, 5, v >= 0 ? v : 25 + v); }
        if (getenv("HPOS")) { int v = atoi(getenv("HPOS")); field(20, 7, v >= 0 ? v : 77 + v); }
        if (getenv("VSHIFT")) field(27, 5, atoi(getenv("VSHIFT")) & 31);
    }
    run(40000);                                  // SDRAM init, cache sweeps
    if (noload) {                                // a quick check of the video path: no ROM, the overlay is the test pattern
        printf("up after %llu clocks; no image download (video-path check)\n", cycles);
        download(2, nv.data(), 128, 40);
        run(200000);
    } else {
        printf("up after %llu clocks; loading %ld bytes\n", cycles, IMG_LEN);
        unsigned long long t0 = cycles;
        download(0, img.data(), IMG_LEN, 2);
        printf("image loaded in %llu clocks\n", cycles - t0);
        download(2, nv.data(), 128, 40);
        printf("EEPROM default loaded; frames so far %d\n", frames_done);
    }

    // run frames: the first complete frame after the load
    int start_frames = frames_done;
    int target = start_frames + frames;
    unsigned long long guard = 0;
    // TIMING_TOGGLE=1: switch Video timing three times, a good way into a frame each time (at frames 3, 6 and 9
    // after the load), and check that every frame is whole -- the board's size or MAME's, never in between
    bool toggle = getenv("TIMING_TOGGLE") && atoi(getenv("TIMING_TOGGLE")), tnow = tmame;
    int tg = 0; long long twait = -1;
    record_periods = true;
    while (frames_done < target && guard++ < 4000000000ull) {
        tick(); video_watch();
        if (toggle && tg < 3) {
            if (twait < 0 && frames_done - start_frames == 3 + 3 * tg) twait = 700000;
            else if (twait > 0 && --twait == 0) { twait = -1; tnow = !tnow; set_status(13, tnow); tg++; printf("  frame %d: Video timing -> %s\n", frames_done - start_frames, tnow ? "MAME" : "board"); }
        }
    }
    printf("%d frames after the load, last frame had %d visible pixels (expect %d)\n", frames_done - start_frames, de_last_count, VIS_W * VIS_H);
    if (de_last_count != VIS_W * VIS_H) { printf("  FAIL: visible pixel count\n"); errors++; }

    {   // the raster's period: 12 clocks a pixel; board 508 x 263, MAME 512 x 264
        const unsigned long long wb = 12ull * 508 * 263, wm = 12ull * 512 * 264;
        unsigned long long want = tnow ? wm : wb;
        printf("frame period %llu clocks (%s timing: expect %llu = %.4f Hz)\n", frame_period, tnow ? "MAME" : "board", want, 96e6 / (double)want);
        if (frame_period != want) { printf("  FAIL: the frame period\n"); errors++; }
        // the time between two vsync pulses is a whole frame, except across a switch, where the pulse moves (line 255
        // of the board's 263 lines, line 248 of MAME's 264): board to MAME is 8 lines of 508 plus 248 of 512, MAME to
        // board is 16 lines of 512 plus 255 of 508
        const unsigned long long t_bm = 12ull * (8 * 508 + 248 * 512), t_mb = 12ull * (16 * 512 + 255 * 508);
        // (with a V-Shift the sync of the transitional frame moves by that many lines of the shift register as well)
        const long long tol = 96 + (getenv("VSHIFT") ? 6144LL * (llabs(atoi(getenv("VSHIFT"))) + 1) : 0);
        int nb = 0, nm = 0, nbm = 0, nmb = 0, bad = 0;
        for (size_t i = 1; i < periods.size(); i++) {    // [0] may span the load
            if (periods[i] == wb) nb++; else if (periods[i] == wm) nm++;
            // (the picture path lines vsync up with hsync, whose phase differs by 4 pixels between the two: allow 8 pixels)
            else if (llabs((long long)periods[i] - (long long)t_bm) <= tol) nbm++;
            else if (llabs((long long)periods[i] - (long long)t_mb) <= tol) nmb++;
            else { bad++; printf("  frame %zu: period %llu clocks = %.3f lines of 508 / %.3f of 512\n", i, periods[i], periods[i] / 6096.0, periods[i] / 6144.0); }
        }
        printf("frame periods after the load: %d board, %d MAME, %d board-to-MAME, %d MAME-to-board, %d other\n", nb, nm, nbm, nmb, bad);
        if (bad) { printf("  FAIL: a frame of the wrong length\n"); errors++; }
        if (toggle && (nbm + nmb != tg || nb == 0 || nm == 0)) { printf("  FAIL: expected one transitional frame per switch\n"); errors++; }
    }
    unsigned nonblack = 0; for (unsigned v : frame_last) if (v) nonblack++;
    printf("last captured frame: %u non-black pixels\n", nonblack);
    printf("geometry (last frame): %d rows with picture, %d lines a frame; first row %ld clocks after the vsync pulse (%.3f lines);"
           " rows start %ld..%ld clocks after hsync, %ld..%ld clocks wide\n",
           geo_rows, geo_lines, geo_first, geo_first / (tnow ? 6144.0 : 6096.0), geo_smin, geo_smax, geo_wmin, geo_wmax);
#ifdef PROBE
    printf("probe: status[9]=%u  core de clocks %u  core cen_pix ticks %u  max core rgb %06x  max overlay out %06x  VGA nonzero clocks %u (in DE %u)\n",
           pk_en, pk_gade, pk_cen, pk_core, pk_ovl, pk_vga_any, pk_arc);
    printf("probe: arcade_video RGB_fix max %06x  mixer frz set on %u clocks  scandoubler set on %u clocks  mixer rt/gt/bt non-zero on %u clocks\n", pk_fix, pk_frz, pk_sd, pk_rt);
    printf("probe: gamma_bus bits ever set %06x, bits always set %06x  (bit 19 is gamma_en)\n", gb_or, gb_and);
#endif
#ifdef PROBE
    if (flip) {
        // Flip Screen: the picture the scaler gets is the flip stage's input turned 180 degrees, from the frame before
        auto flipped_match = [&](const std::vector<unsigned> &src) {
            long ok = 0;
            for (int y = 0; y < VIS_H; y++) for (int x = 0; x < VIS_W; x++)
                if (frame_last[y * VIS_W + x] == src[(VIS_H - 1 - y) * VIS_W + (VIS_W - 1 - x)]) ok++;
            return ok;
        };
        long m1 = flipped_match(ovl_f1), m2 = flipped_match(ovl_f2), m3 = flipped_match(ovl_f3);
        long fbest = m1 > m2 ? m1 : m2; if (m3 > fbest) fbest = m3;
        long same = 0; for (int i = 0; i < VIS_W * VIS_H; i++) if (frame_last[i] == ovl_f2[i]) same++;
        printf("flip check: the last picture equals the overlay's turned 180 degrees: %ld / %ld / %ld of %d pixels (1, 2, 3 frames back);"
               " unflipped it would match %ld\n", m1, m2, m3, VIS_W * VIS_H, same);
        if (fbest != VIS_W * VIS_H) { printf("  FAIL: the flipped picture is not the overlay turned 180 degrees\n"); errors++; }
    }
#else
    if (flip) printf("(Flip Screen check needs PROBE=1)\n");
#endif
    // a blank picture would make the rotation check below pass on nothing
    if (nonblack == 0) { printf("  FAIL: the picture is blank, so the rotation check proves nothing\n"); errors++; }
    write_ppm((std::string(pre) + "_scaler.ppm").c_str(), frame_last, VIS_W, VIS_H);

    // the rotated frame buffer: 224 wide, 376 tall, 4 bytes a pixel, stride 896, three 8 MB buffers
    int fbw = dut->FB_WIDTH, fbh = dut->FB_HEIGHT;
    printf("FB_EN=%d FB_WIDTH=%d FB_HEIGHT=%d aspect %d:%d\n", dut->FB_EN, fbw, fbh, dut->VIDEO_ARX, dut->VIDEO_ARY);
    if (!dut->FB_EN || fbw != VIS_H || fbh != VIS_W) { printf("  FAIL: frame buffer geometry\n"); errors++; }
    const int stride = 896;
    auto fb_pixel = [&](int buf, int row, int col) -> unsigned {
        unsigned long off = (unsigned long)row * stride + (unsigned long)col * 4;
        unsigned long long w = dut->rootp->tb_emu_top__DOT__ddr__DOT__fb[((unsigned long)buf << 20) | (off >> 3)];
        unsigned px = (unsigned)(w >> (32 * ((off >> 2) & 1)));
        return ((px & 0xff) << 16) | (px & 0xff00) | ((px >> 16) & 0xff);        // {8'd0, B, G, R} -> 0xRRGGBB
    };
    // clockwise: source (x, y) -> frame buffer (row x, column 223 - y)
    auto match = [&](const std::vector<unsigned> &src, int buf) {
        long ok = 0;
        for (int y = 0; y < VIS_H; y++) for (int x = 0; x < VIS_W; x++) if (fb_pixel(buf, x, VIS_H - 1 - y) == src[y * VIS_W + x]) ok++;
        return ok;
    };
    long best = 0; int best_buf = -1; const char *best_src = "";
    for (int buf = 0; buf < 3; buf++) {
        long a = match(frame_last, buf), b = match(frame_prev, buf);
        printf("  buffer %d: %ld of %d pixels equal the last frame rotated, %ld the one before\n", buf, a, VIS_W * VIS_H, b);
        if (a > best) { best = a; best_buf = buf; best_src = "last"; }
        if (b > best) { best = b; best_buf = buf; best_src = "previous"; }
    }
    printf("frame buffer vs picture: best buffer %d (%s frame) matches %ld of %d pixels\n", best_buf, best_src, best, VIS_W * VIS_H);
    if (best != VIS_W * VIS_H) { printf("  FAIL: the rotated frame buffer is not the picture turned a quarter clockwise\n"); errors++; }
    else {
        std::vector<unsigned> rot(VIS_W * VIS_H);
        for (int r = 0; r < VIS_W; r++) for (int c = 0; c < VIS_H; c++) rot[r * VIS_H + c] = fb_pixel(best_buf, r, c);
        write_ppm((std::string(pre) + "_rotated.ppm").c_str(), rot, VIS_H, VIS_W);
    }
    printf("rotate writes seen by the DDR3: %d, DDR protocol errors %d\n", (int)dut->rootp->tb_emu_top__DOT__ddr__DOT__rot_writes, (int)dut->rootp->tb_emu_top__DOT__ddr__DOT__protocol_errors);
    if (dut->rootp->tb_emu_top__DOT__ddr__DOT__protocol_errors) errors++;

    // the EEPROM through the upload path (what the save reads)
    HPSV(r_upload) = 1; unsigned bad = 0;
    for (int i = 0; i < 128; i++) { HPSV(r_addr) = i; run(6); if (HPSV(r_din_seen) != nv[i]) { if (bad < 4) printf("  eeprom byte %d: read %02x expected %02x\n", i, HPSV(r_din_seen), nv[i]); bad++; } }
    HPSV(r_upload) = 0; run(4);
    printf("EEPROM read back through the upload port: %u of 128 bytes differ\n", bad);
    if (bad) errors++;
    printf("audio samples non-zero seen: %lld; upload requests %d\n", audio_nonzero, (int)HPSV(upload_reqs));

    printf("%s: %u errors, %llu clocks\n", errors ? "FAIL" : "PASS", errors, cycles);
    delete dut; return errors ? 1 : 0;
}
