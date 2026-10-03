// gaia_mem gate (MiSTer): samples of every ROM region go in through the download
// port -- the HPS's byte-at-a-time stream, held off by dl_wait -- and come back
// through every core port; the tile RAM is written and read; the ports are
// then hammered together with the DDR3 busy and the frame buffer's write
// traffic running; and the built-in memory test is run on a clean machine,
// then with words corrupted behind the caches.
//   tb_mem <gaiapolis.rom> [load gap in clocks, default 6]
#include "Vtb_mem_top.h"
#include "Vtb_mem_top___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <vector>

static Vtb_mem_top *dut;
static unsigned long long cycles = 0;
static void tick(int n = 1) { while (n--) { dut->clk = 0; dut->eval(); dut->clk = 1; dut->eval(); cycles++; } }
static const long IMG_PROG = 0x0000000, IMG_SND = 0x0300000, IMG_TILE = 0x0340000, IMG_CHR = 0x0540000,
                  IMG_MAP = 0x06C0000, IMG_PCM = 0x0760000, IMG_SPR = 0x0B60000, IMG_END = 0x1360000;
// gaia_mem's layout
static const unsigned SD_TILE = 0x000000, SD_PCM = 0x100000, SD_SPR = 0x300000, SD_PROG = 0x700000, SD_SND = 0x880000;
static const unsigned DD_MAP = 0x00000, DD_CHR = 0x20000;
static std::vector<unsigned char> img;
static unsigned errors = 0;
static int load_gap = 6;            // clocks between download bytes

static void load(long a0, long n) {
    for (long a = a0; a < a0 + n; a++) {
        int w = 0; while (dut->dl_wait && w++ < 100000) tick();
        dut->dl_we = 1; dut->dl_addr = a; dut->dl_data = img[a]; tick();
        dut->dl_we = 0; tick(load_gap - 1);
    }
}
static bool wait_ack(unsigned char &ack, const char *what) {
    for (int i = 0; i < 4000; i++) { tick(); if (ack) return true; }
    printf("timeout waiting for %s\n", what); errors++; return false;
}
static unsigned prog_rd(long w) { dut->prog_req = 1; dut->prog_addr = w; bool ok = wait_ack(dut->prog_ack, "prog"); unsigned q = dut->prog_q; dut->prog_req = 0; tick(2); return ok ? q : 0xdead; }
static unsigned snd_rd(long b)  { dut->snd_req = 1;  dut->snd_addr = b;  bool ok = wait_ack(dut->snd_ack, "snd");   unsigned q = dut->snd_q;  dut->snd_req = 0;  tick(2); return ok ? q : 0xdd; }
static unsigned pcm_rd(long b)  { dut->pcm_req = 1;  dut->pcm_addr = b;  bool ok = wait_ack(dut->pcm_ack, "pcm");   unsigned q = dut->pcm_q;  dut->pcm_req = 0;  tick(2); return ok ? q : 0xdd; }
static unsigned map_rd(long b)  { dut->map_req = 1;  dut->map_addr = b;  bool ok = wait_ack(dut->map_ack, "map");   unsigned q = dut->map_q;  dut->map_req = 0;  tick(2); return ok ? q : 0xdead; }
// a character tile: 64 words streamed in {column, row} order, checked against the image's tile*64 + row*4 + column
static unsigned long long blk_rd(long tile, unsigned short *w) {
    dut->blk_req = 1; dut->blk_addr = tile; unsigned long long got = 0;
    for (int i = 0; i < 4000; i++) { tick(); if (dut->blk_wr) { w[dut->blk_idx] = dut->blk_data; got |= 1ull << dut->blk_idx; } if (dut->blk_ack) break; }
    bool ok = dut->blk_ack; dut->blk_req = 0; tick(2); return ok ? got : 0;
}
static unsigned tile_rd(long w) { dut->tile_req = 1; dut->tile_addr = w; bool ok = wait_ack(dut->tile_ack, "tile"); unsigned q = dut->tile_q; dut->tile_req = 0; tick(2); return ok ? q : 0xdeadbeef; }
static unsigned long long spr_rd(long w) { dut->spr_req = 1; dut->spr_addr = w; bool ok = wait_ack(dut->spr_ack, "spr"); unsigned long long q = dut->spr_q; dut->spr_req = 0; tick(2); return ok ? q : 0xdeadbeefdeadbeefULL; }
static void vram_wr(unsigned a, unsigned d, unsigned be) { dut->vram_req = 1; dut->vram_we = 1; dut->vram_addr = a; dut->vram_wdata = d; dut->vram_be = be; wait_ack(dut->vram_ack, "vram write"); dut->vram_req = 0; dut->vram_we = 0; tick(2); }
static unsigned vram_rd(unsigned a) { dut->vram_req = 1; dut->vram_we = 0; dut->vram_addr = a; bool ok = wait_ack(dut->vram_ack, "vram read"); unsigned q = dut->vram_q; dut->vram_req = 0; tick(2); return ok ? q : 0xdead; }
static unsigned be16(long a) { return ((unsigned)img[a] << 8) | img[a + 1]; }
static unsigned long long be64(long a) { unsigned long long v = 0; for (int b = 0; b < 8; b++) v = (v << 8) | img[a + b]; return v; }

static void reset_dut() {
    dut->init = 1; tick(8); dut->init = 0;
    int w = 0; while (!dut->ready && w++ < 200000) tick();
    if (!dut->ready) { printf("memories never ready\n"); exit(1); }
}

struct Reg { const char *name; long base, len; std::vector<long> wins; };
static const long S = 2048;

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 2) { fprintf(stderr, "usage: %s <rom>\n", argv[0]); return 2; }
    FILE *rf = fopen(argv[1], "rb"); if (!rf) { fprintf(stderr, "cannot open %s\n", argv[1]); return 1; }
    fseek(rf, 0, SEEK_END); long n = ftell(rf); fseek(rf, 0, SEEK_SET);
    img.resize(n); if (fread(img.data(), 1, n, rf) != (size_t)n) return 1; fclose(rf);
    if (n < IMG_END) { fprintf(stderr, "image shorter than the layout\n"); return 1; }
    if (argc > 2) load_gap = atoi(argv[2]);

    dut = new Vtb_mem_top;
    dut->rot_en = 1;
    reset_dut();
    printf("memories ready after %llu clocks (SDRAM init, cache sweeps)\n", cycles);
    dut->dl_start = 1; tick(); dut->dl_start = 0; tick(2100);        // a download begins: the caches sweep
    if (!dut->ready) { printf("not ready after the cache sweep\n"); errors++; }

    // samples: the first and last 2 KB of every region, plus windows that alias in the
    // program caches (16 KB and 4 KB, direct mapped) and the map's three regions
    std::vector<Reg> regs = {
        {"prog", IMG_PROG, IMG_SND - IMG_PROG, {0, 0x4000, 0x8000, IMG_SND - IMG_PROG - S}},
        {"snd",  IMG_SND,  IMG_TILE - IMG_SND, {0, 0x1000, 0x2000, IMG_TILE - IMG_SND - S}},
        {"tile", IMG_TILE, IMG_CHR - IMG_TILE, {0, IMG_CHR - IMG_TILE - S}},
        {"chr",  IMG_CHR,  IMG_MAP - IMG_CHR,  {0, IMG_MAP - IMG_CHR - S}},
        {"map",  IMG_MAP,  IMG_PCM - IMG_MAP,  {0, 0x20000, 0x60000, IMG_PCM - IMG_MAP - S}},
        {"pcm",  IMG_PCM,  IMG_SPR - IMG_PCM,  {0, IMG_SPR - IMG_PCM - S}},
        {"spr",  IMG_SPR,  IMG_END - IMG_SPR,  {0, IMG_END - IMG_SPR - S}} };
    for (auto &r : regs) for (long w : r.wins) load(r.base + w, S);
    tick(400);
    printf("loaded\n");

    // read back, every port, every window
    auto check = [&](const char *name, Reg &r, auto rd, long unit, auto expect) {
        unsigned bad = 0, cnt = 0;
        for (long w0 : r.wins)
            for (long off = w0; off < w0 + S; off += unit) {
                long a = r.base + off; unsigned long long got = rd(off / unit, off), exp = expect(a);
                cnt++;
                if (got != exp) { if (bad < 4) printf("  %s @ image %07lx: got %llx expected %llx\n", name, a, got, exp); bad++; }
            }
        printf("%-5s %u words checked, %u bad\n", name, cnt, bad); errors += bad;
    };
    check("prog", regs[0], [](long w, long){ return (unsigned long long)prog_rd(w); }, 2, [](long a){ return (unsigned long long)be16(a); });
    check("snd",  regs[1], [](long, long off){ return (unsigned long long)snd_rd(off); }, 1, [](long a){ return (unsigned long long)img[a]; });
    check("tile", regs[2], [](long w, long){ return (unsigned long long)tile_rd(w); }, 4,
          [](long a){ return (unsigned long long)(((unsigned)be16(a) << 16) | be16(a + 2)); });
    {   // chr: every block in the sampled windows
        unsigned bad = 0, cnt = 0;
        for (long w0 : regs[3].wins)
            for (long off = w0; off < w0 + S; off += 128) {            // one tile = 128 bytes = 64 words
                long tile = off / 128;
                unsigned short w[64]; unsigned long long got = blk_rd(tile, w); cnt++;
                if (got != ~0ull) { if (bad < 4) printf("  chr tile %ld: only %016llx words arrived\n", tile, got); bad++; continue; }
                for (int wc = 0; wc < 4; wc++)
                    for (int row = 0; row < 16; row++) {
                        unsigned exp = be16(IMG_CHR + tile * 128 + row * 8 + wc * 2);
                        if (w[wc * 16 + row] != exp) { if (bad < 4) printf("  chr tile %ld column %d row %d: got %04x expected %04x\n", tile, wc, row, w[wc * 16 + row], exp); bad++; }
                    }
            }
        printf("chr   %u tiles checked, %u bad\n", cnt, bad); errors += bad;
    }
    check("map",  regs[4], [](long, long off){ return (unsigned long long)map_rd(off); }, 2, [](long a){ return (unsigned long long)be16(a); });
    check("pcm",  regs[5], [](long, long off){ return (unsigned long long)pcm_rd(off); }, 1, [](long a){ return (unsigned long long)img[a]; });
    check("spr",  regs[6], [](long w, long){ return spr_rd(w); }, 8, [](long a){ return be64(a); });

    // program caches: random reads over windows that alias, so lines are evicted and refilled
    {
        unsigned seed = 777, bad = 0;
        auto rnd = [&]() { seed = seed * 1103515245u + 12345u; return seed >> 8; };
        const long pw[4] = {0, 0x4000, 0x8000, IMG_SND - IMG_PROG - S}, sw[4] = {0, 0x1000, 0x2000, IMG_TILE - IMG_SND - S};
        for (int i = 0; i < 4000; i++) {
            long off = pw[rnd() & 3] + (rnd() % (S / 2)) * 2;
            unsigned g = prog_rd(off / 2), e = be16(IMG_PROG + off);
            if (g != e) { if (bad < 4) printf("  prog cache @ %lx: got %04x expected %04x\n", off, g, e); bad++; }
            long so = sw[rnd() & 3] + rnd() % S;
            g = snd_rd(so); e = img[IMG_SND + so];
            if (g != e) { if (bad < 4) printf("  snd cache @ %lx: got %02x expected %02x\n", so, g, e); bad++; }
        }
        printf("caches: 4000 random prog and snd reads across aliasing windows, %u bad\n", bad); errors += bad;
    }

    // the ROZ plane's map access pattern: a tile's colour byte, then its two attribute bytes,
    // three far-apart regions, tiles in a random walk over a window
    {
        unsigned seed = 4242, bad = 0;
        auto rnd = [&]() { seed = seed * 1103515245u + 12345u; return seed >> 8; };
        auto word = [&](long a) { return be16(IMG_MAP + (a & ~1L)); };
        long ti = 0;
        for (int i = 0; i < 3000; i++) {
            ti = (rnd() % 8 == 0) ? rnd() % 2048 : (ti + 1 + (rnd() % 3)) % 2048;       // mostly neighbours, sometimes a jump
            long a0 = ti >> 1, a1 = 0x20000 + ti, a2 = 0x60000 + ti;
            unsigned g0 = map_rd(a0), g1 = map_rd(a1), g2 = map_rd(a2);
            if (g0 != word(a0) || g1 != word(a1) || g2 != word(a2)) {
                if (bad < 4) printf("  map tile %ld: got %04x %04x %04x expected %04x %04x %04x\n", ti, g0, g1, g2, word(a0), word(a1), word(a2));
                bad++;
            }
        }
        printf("map   3000 renderer-style tile reads (three regions each), %u bad\n", bad); errors += bad;
    }

    // tile RAM: words and byte lanes
    unsigned vbad = 0;
    for (unsigned a = 0; a < 64; a++) vram_wr(a * 1021 & 0xffff, (a * 0x3579) & 0xffff, 3);
    for (unsigned a = 0; a < 64; a++) { unsigned e = (a * 0x3579) & 0xffff, g = vram_rd(a * 1021 & 0xffff); if (g != e) { if (vbad < 4) printf("  vram %04x: got %04x expected %04x\n", a * 1021 & 0xffff, g, e); vbad++; } }
    vram_wr(0x1234, 0xaa55, 3); vram_wr(0x1234, 0x11ff, 2); { unsigned g = vram_rd(0x1234); if (g != 0x1155) { printf("  vram byte lane: got %04x expected 1155\n", g); vbad++; } }
    vram_wr(0x1234, 0x22cc, 1); { unsigned g = vram_rd(0x1234); if (g != 0x11cc) { printf("  vram byte lane: got %04x expected 11cc\n", g); vbad++; } }
    printf("vram  %u bad\n", vbad); errors += vbad;

    // contention: every port raised together, each held until its ack (or withdrawn early and
    // re-raised for another address, as a renderer restarting a line does), every word checked,
    // with the DDR3 pushing back and the frame buffer's writes going through the arbiter
    {
        unsigned bad = 0, done[8] = {0}, withdrawn = 0; unsigned seed = 12345;
        auto rnd = [&]() { seed = seed * 1103515245u + 12345u; return seed >> 8; };
        // 0 tile, 1 spr, 2 pcm, 3 chr block, 4 prog, 5 snd, 6 map
        long t_w = 0, s_w = 0, p_b = 0, b_t = 0, g_w = 0, z_b = 0, m_a = 0; bool on[7] = {false};
        unsigned short bw[64]; unsigned long long b_got = 0; unsigned b_words = 0; long b_off_until = 0;
        auto new_t = [&]() { t_w = rnd() % (S / 4); dut->tile_addr = t_w; dut->tile_req = 1; on[0] = true; };
        auto new_s = [&]() { s_w = rnd() % (S / 8); dut->spr_addr = s_w; dut->spr_req = 1; on[1] = true; };
        auto new_p = [&]() { p_b = rnd() % S; dut->pcm_addr = p_b; dut->pcm_req = 1; on[2] = true; };
        auto new_b = [&]() { b_t = rnd() % (S / 128); dut->blk_addr = b_t; dut->blk_req = 1; on[3] = true; b_got = 0; b_words = 0; };
        auto new_g = [&]() { static const long pw[3] = {0, 0x4000, 0x8000}; g_w = (pw[rnd() % 3] + (rnd() % (S / 2)) * 2) / 2; dut->prog_addr = g_w; dut->prog_req = 1; on[4] = true; };
        auto new_z = [&]() { static const long sw[3] = {0, 0x1000, 0x2000}; z_b = sw[rnd() % 3] + rnd() % S; dut->snd_addr = z_b; dut->snd_req = 1; on[5] = true; };
        auto new_m = [&]() { m_a = (rnd() % (S / 2)) * 2; dut->map_addr = m_a; dut->map_req = 1; on[6] = true; };
        new_t(); new_s(); new_p(); new_b(); new_g(); new_z(); new_m();
        long target = 1500;
        for (long nn = 0; nn < 1500000; nn++) {
            bool all = true; for (int k = 0; k < 7; k++) if (done[k] < (k == 3 ? 150u : (unsigned)target)) all = false;
            if (all) break;
            tick();
            if (on[3] && dut->blk_wr) { bw[dut->blk_idx] = dut->blk_data; b_got |= 1ull << dut->blk_idx; b_words++; }
            if (on[3] && dut->blk_ack) {
                if (b_got != ~0ull || b_words != 64) { if (bad < 6) printf("  contention chr tile %ld: %u words, mask %016llx\n", b_t, b_words, b_got); bad++; }
                else for (int wc = 0; wc < 4; wc++) for (int row = 0; row < 16; row++) {
                    unsigned exp = be16(IMG_CHR + b_t * 128 + row * 8 + wc * 2);
                    if (bw[wc * 16 + row] != exp) { if (bad < 6) printf("  contention chr tile %ld c%d r%d: got %04x expected %04x\n", b_t, wc, row, bw[wc * 16 + row], exp); bad++; }
                }
                dut->blk_req = 0; on[3] = false; done[3]++;
            }
            if (on[0] && dut->tile_ack) {
                unsigned long long exp = ((unsigned long long)be16(IMG_TILE + t_w * 4) << 16) | be16(IMG_TILE + t_w * 4 + 2);
                if (dut->tile_q != exp) { if (bad < 6) printf("  contention tile w%ld: got %08x expected %08llx\n", t_w, dut->tile_q, exp); bad++; }
                dut->tile_req = 0; on[0] = false; done[0]++;
            }
            if (on[1] && dut->spr_ack) {
                unsigned long long exp = be64(IMG_SPR + s_w * 8);
                if (dut->spr_q != exp) { if (bad < 6) printf("  contention spr w%ld: got %016llx expected %016llx\n", s_w, (unsigned long long)dut->spr_q, exp); bad++; }
                dut->spr_req = 0; on[1] = false; done[1]++;
            }
            if (on[2] && dut->pcm_ack) {
                if (dut->pcm_q != img[IMG_PCM + p_b]) { if (bad < 6) printf("  contention pcm b%ld: got %02x expected %02x\n", p_b, dut->pcm_q, img[IMG_PCM + p_b]); bad++; }
                dut->pcm_req = 0; on[2] = false; done[2]++;
            }
            if (on[4] && dut->prog_ack) {
                // the window's offset was folded into g_w (a word address): the image word is g_w
                if (dut->prog_q != be16(IMG_PROG + g_w * 2)) { if (bad < 6) printf("  contention prog w%lx: got %04x expected %04x\n", g_w, dut->prog_q, be16(IMG_PROG + g_w * 2)); bad++; }
                dut->prog_req = 0; on[4] = false; done[4]++;
            }
            if (on[5] && dut->snd_ack) {
                if (dut->snd_q != img[IMG_SND + z_b]) { if (bad < 6) printf("  contention snd b%lx: got %02x expected %02x\n", z_b, dut->snd_q, img[IMG_SND + z_b]); bad++; }
                dut->snd_req = 0; on[5] = false; done[5]++;
            }
            if (on[6] && dut->map_ack) {
                if (dut->map_q != be16(IMG_MAP + m_a)) { if (bad < 6) printf("  contention map a%lx: got %04x expected %04x\n", m_a, dut->map_q, be16(IMG_MAP + m_a)); bad++; }
                dut->map_req = 0; on[6] = false; done[6]++;
            }
            // withdraw a standing request now and then, then ask for something else
            if (on[0] && (rnd() % 97) == 0) { dut->tile_req = 0; on[0] = false; withdrawn++; }
            if (on[1] && (rnd() % 89) == 0) { dut->spr_req = 0; on[1] = false; withdrawn++; }
            if (on[4] && (rnd() % 211) == 0) { dut->prog_req = 0; on[4] = false; withdrawn++; }
            if (on[6] && (rnd() % 131) == 0) { dut->map_req = 0; on[6] = false; withdrawn++; }
            // a block fetch cut off part-way: the port finishes streaming it, which the renderer's
            // cache entry simply absorbs: stay off long enough for that
            if (on[3] && (rnd() % 3000) == 0) { dut->blk_req = 0; on[3] = false; withdrawn++; b_off_until = nn + 400; }
            if (!on[3] && nn >= b_off_until && (rnd() % 3) == 0) new_b();
            if (!on[0] && (rnd() % 3) == 0) new_t();
            if (!on[1] && (rnd() % 3) == 0) new_s();
            if (!on[2] && (rnd() % 5) == 0) new_p();
            if (!on[4] && (rnd() % 4) == 0) new_g();
            if (!on[5] && (rnd() % 6) == 0) new_z();
            if (!on[6] && (rnd() % 4) == 0) new_m();
        }
        dut->tile_req = 0; dut->spr_req = 0; dut->pcm_req = 0; dut->blk_req = 0; dut->prog_req = 0; dut->snd_req = 0; dut->map_req = 0; tick(400);
        printf("contention: %u tile, %u sprite, %u pcm, %u chr tiles, %u prog, %u snd, %u map reads, %u withdrawn, %u bad; rotate writes %d, DDR protocol errors %d, FIFO overflow %d\n",
               done[0], done[1], done[2], done[3], done[4], done[5], done[6], withdrawn, bad,
               (int)dut->rootp->tb_mem_top__DOT__ddr__DOT__rot_writes, (int)dut->rootp->tb_mem_top__DOT__ddr__DOT__protocol_errors, (int)dut->ddr_overflow);
        errors += bad;
        if (dut->rootp->tb_mem_top__DOT__ddr__DOT__protocol_errors) errors++;
        if (dut->ddr_overflow) errors++;
        for (int k = 0; k < 7; k++) if (done[k] < (k == 3 ? 150u : (unsigned)target)) { printf("  contention: port %d starved (%u)\n", k, done[k]); errors++; }
    }
    delete dut;

    // the built-in memory test (1/64 of each region) on a fresh machine: load the heads of the
    // regions so the load-time sums start at image byte 0, run it, then corrupt words behind
    // the caches and run it again
    dut = new Vtb_mem_top;
    dut->rot_en = 1;
    reset_dut();
    dut->dl_start = 1; tick(); dut->dl_start = 0; tick(2100);
    bool poke_vram = false;             // corrupt two tile RAM words once the read-back pass has begun
    auto run_test = [&](const char *what, unsigned exp_ok) {
        dut->test_start = 1; tick(4); dut->test_start = 0;
        long cnt = 0; bool poked = false;
        while (!dut->test_done && cnt++ < 60000000) {
            tick();
            if (poke_vram && !poked && dut->rootp->tb_mem_top__DOT__dut__DOT__u_test__DOT__st == 5) {   // T_VR
                dut->rootp->tb_mem_top__DOT__dut__DOT__u_vram__DOT__ram_lo[0x8234] ^= 0x01;
                dut->rootp->tb_mem_top__DOT__dut__DOT__u_vram__DOT__ram_hi[0x8235] ^= 0x80; poked = true;
            }
        }
        printf("memtest %s: done=%d ok=%02x stable=%02x vram_ok=%d vram_bad=%d (%ld clocks)\n", what, dut->test_done,
               dut->test_ok, dut->test_stable, dut->vram_ok, dut->vram_bad, cnt);
        if (!dut->test_done || dut->test_ok != exp_ok || dut->test_stable != 0x7f || !dut->vram_ok) errors++;
    };
    for (auto &r : regs) load(r.base, S);
    run_test("clean", 0x7f);
    // two bad tile RAM words show as 2 on the log scale
    poke_vram = true; run_test("corrupted tile RAM (2 words, expect vram_bad 2)", 0x7f); poke_vram = false;
    if (dut->vram_bad == 2 && !dut->vram_ok) errors--;                  // run_test counted the expected failure
    else printf("  tile RAM corruption not reported as 2\n");
    // behind the caches: drop them (a download starts), corrupt, read back
    dut->dl_start = 1; tick(); dut->dl_start = 0; tick(2100);
    dut->rootp->tb_mem_top__DOT__chip__DOT__mem[SD_PROG + 5] ^= 0x0100;      // prog word 5
    dut->rootp->tb_mem_top__DOT__chip__DOT__mem[SD_TILE + 7] ^= 0x0001;      // tile word 7
    dut->rootp->tb_mem_top__DOT__ddr__DOT__mem[DD_MAP + 3] ^= 0x0000000000010000ULL;   // map word 1 of beat 3
    run_test("corrupted prog+tile+map", 0x7f & ~0x01 & ~0x04 & ~0x10);         // bits 0 prog, 2 tile, 4 map
    printf("%s: %u errors, %llu clocks\n", errors ? "FAIL" : "PASS", errors, cycles);
    delete dut; return errors ? 1 : 0;
}
