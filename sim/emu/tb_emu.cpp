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
static long long audio_nonzero = 0;
static unsigned errors = 0;

#ifdef PROBE
// signals inside the top level (the bench is built with --public-flat-rw when PROBE is set)
#define EMUV(n) dut->rootp->tb_emu_top__DOT__u_emu__DOT__##n
static unsigned pk_ovl = 0, pk_core = 0, pk_gade = 0, pk_cen = 0, pk_en = 0, pk_arc = 0, pk_vga_any = 0;
static unsigned pk_fix = 0, pk_frz = 0, pk_sd = 0, pk_rt = 0, gb_or = 0, gb_and = 0x3fffff;
static void probe() {
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
static void video_watch() {
#ifdef PROBE
    probe();
#endif
    if (audio_nonzero == 0 && (dut->AUDIO_L != 0 || dut->AUDIO_R != 0)) audio_nonzero = 1;
    bool vs = dut->VGA_VS;
    if (vs && !prev_vs) {                       // a frame ends
        if (de_count == VIS_W * VIS_H) { frame_prev = frame_last; frame_last = frame_now; }
        de_last_count = de_count;
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
    while (frames_done < target && guard++ < 4000000000ull) { tick(); video_watch(); }
    printf("%d frames after the load, last frame had %d visible pixels (expect %d)\n", frames_done - start_frames, de_last_count, VIS_W * VIS_H);
    if (de_last_count != VIS_W * VIS_H) { printf("  FAIL: visible pixel count\n"); errors++; }

    unsigned nonblack = 0; for (unsigned v : frame_last) if (v) nonblack++;
    printf("last captured frame: %u non-black pixels\n", nonblack);
#ifdef PROBE
    printf("probe: status[9]=%u  core de clocks %u  core cen_pix ticks %u  max core rgb %06x  max overlay out %06x  VGA nonzero clocks %u (in DE %u)\n",
           pk_en, pk_gade, pk_cen, pk_core, pk_ovl, pk_vga_any, pk_arc);
    printf("probe: arcade_video RGB_fix max %06x  mixer frz set on %u clocks  scandoubler set on %u clocks  mixer rt/gt/bt non-zero on %u clocks\n", pk_fix, pk_frz, pk_sd, pk_rt);
    printf("probe: gamma_bus bits ever set %06x, bits always set %06x  (bit 19 is gamma_en)\n", gb_or, gb_and);
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
