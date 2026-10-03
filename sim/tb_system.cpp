// Full-system bench: the whole machine from reset, real program ROM, video
// out. Runs N frames, writes the last frame as RGB and a PNG-able dump, and
// reports what the 68000 did: steps, IRQ5 count per frame, the PC histogram
// of the last frame, and the diagnostics flags.
//
//   tb_system <gaiapolis.rom> <frames> <out.rgb> [trace.txt]
// The sound board's output is written next to the RGB dump as a 48 kHz
// stereo 16-bit WAV (<out>.wav) when AUDIO=1.
#include "Vtb_system_top.h"
#include "Vtb_system_top___024root.h"
// the sprite RAM inside the core, by the wrapper's scope name (MEM=pocket builds tb_pocket_top under the same class name)
#if defined(MISTER_TOP)
#define SPRRAM dut->rootp->tb_mister_top__DOT__u_core__DOT__u_main__DOT__sram
#elif defined(POCKET_TOP)
#define SPRRAM dut->rootp->tb_pocket_top__DOT__u_core__DOT__u_main__DOT__sram
#else
#define SPRRAM dut->rootp->tb_system_top__DOT__u_core__DOT__u_main__DOT__sram
#endif
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <map>
#include <algorithm>
#include <string>

static const int VIS_W = 376, VIS_H = 224;
static const long ROM_MAINCPU = 0x0000000, MAINCPU_LEN = 0x300000;
static const long ROM_TILES = 0x0340000, TILES_LEN = 0x200000;
static const long ROM_ROZCHAR = 0x0540000, ROZCHAR_LEN = 0x180000;
static const long ROM_ROZMAP = 0x06C0000, ROZMAP_LEN = 0x0A0000;
static const long ROM_SPRITES = 0x0B60000, SPRITES_LEN = 0x800000;
static const long ROM_EEPROM = 0x1360000, EEPROM_LEN = 0x80;
static const long ROM_SOUNDCPU = 0x0300000, SOUNDCPU_LEN = 0x40000;
static const long ROM_PCM = 0x0760000, PCM_LEN = 0x400000;

static Vtb_system_top *dut;
static unsigned long long cycles = 0;
static inline void tick() { dut->clk = 0; dut->eval(); dut->clk = 1; dut->eval(); cycles++; }

static std::vector<unsigned char> region(FILE *rf, long off, long len, const char *what) {
    std::vector<unsigned char> d(len);
    fseek(rf, off, SEEK_SET);
    if (fread(d.data(), 1, len, rf) != (size_t)len) { fprintf(stderr, "short read of %s\n", what); exit(1); }
    return d;
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 4) { fprintf(stderr, "usage: %s <rom> <frames> <out.rgb> [trace.txt]\n", argv[0]); return 2; }
    int frames = atoi(argv[2]);
    FILE *tr = argc > 4 ? fopen(argv[4], "w") : nullptr;

    FILE *rf = fopen(argv[1], "rb");
    if (!rf) { fprintf(stderr, "cannot open %s\n", argv[1]); return 1; }
    auto prog = region(rf, ROM_MAINCPU, MAINCPU_LEN, "program");
    auto tiles = region(rf, ROM_TILES, TILES_LEN, "tiles");
    auto rchr = region(rf, ROM_ROZCHAR, ROZCHAR_LEN, "gfx3");
    auto rmap = region(rf, ROM_ROZMAP, ROZMAP_LEN, "gfx4");
    auto spr = region(rf, ROM_SPRITES, SPRITES_LEN, "sprites");
    auto eep = region(rf, ROM_EEPROM, EEPROM_LEN, "eeprom");
    auto sndrom = region(rf, ROM_SOUNDCPU, SOUNDCPU_LEN, "sound program");
    auto pcm = region(rf, ROM_PCM, PCM_LEN, "pcm");
    fclose(rf);

    dut = new Vtb_system_top;
    dut->reset = 1;
    // nothing pressed; IN1 bit 4 = 0 stereo, bit 2 = 0 (an unassigned custom
    // input that MAME reads as 0 -- the game waits for it after the self-test)
    dut->in0_p1 = 0xffff; dut->in1 = 0xff & ~0x10 & ~0x04; dut->p2 = 0xff;
    for (int i = 0; i < 8; i++) tick();

    // 68000 program: big-endian words
    for (long w = 0; w < MAINCPU_LEN / 2; w++) {
        dut->prog_we = 1; dut->prog_waddr = w; dut->prog_wdata = ((unsigned)prog[w*2] << 8) | prog[w*2+1]; tick();
    }
    dut->prog_we = 0;
    for (long w = 0; w < TILES_LEN / 4; w++) {
        dut->tile_we = 1; dut->tile_waddr = w;
        dut->tile_wdata = ((unsigned)tiles[w*4] << 24) | ((unsigned)tiles[w*4+1] << 16) | ((unsigned)tiles[w*4+2] << 8) | tiles[w*4+3];
        tick();
    }
    dut->tile_we = 0;
    for (long w = 0; w < ROZMAP_LEN / 2; w++) { dut->map_we = 1; dut->map_waddr = w; dut->map_wdata = ((unsigned)rmap[w*2] << 8) | rmap[w*2+1]; tick(); }
    dut->map_we = 0;
    for (long w = 0; w < ROZCHAR_LEN / 2; w++) { dut->chr_we = 1; dut->chr_waddr = w; dut->chr_wdata = ((unsigned)rchr[w*2] << 8) | rchr[w*2+1]; tick(); }
    dut->chr_we = 0;
    for (long w = 0; w < SPRITES_LEN / 8; w++) {
        unsigned long long v = 0; for (int b = 0; b < 8; b++) v = (v << 8) | spr[w*8+b];
        dut->spr_we = 1; dut->spr_waddr = w; dut->spr_wdata = v; tick();
    }
    dut->spr_we = 0;
    for (int i = 0; i < EEPROM_LEN; i++) { dut->eep_we = 1; dut->eep_waddr = i; dut->eep_wdata = eep[i]; tick(); }
    dut->eep_we = 0;
    for (long i = 0; i < SOUNDCPU_LEN; i++) { dut->srom_we = 1; dut->srom_waddr = i; dut->srom_wdata = sndrom[i]; tick(); }
    dut->srom_we = 0;
    for (long i = 0; i < PCM_LEN; i++) { dut->pcm_we = 1; dut->pcm_waddr = i; dut->pcm_wdata = pcm[i]; tick(); }
    dut->pcm_we = 0;

    dut->reset = 0;

    // run frames, capturing the visible pixels of the last one
    std::vector<unsigned> fb(VIS_W * VIS_H, 0);
    int snapevery = getenv("SNAPEVERY") ? atoi(getenv("SNAPEVERY")) : 0;
    auto save_frame = [&](const char *path) {
        FILE *o = fopen(path, "wb"); if (!o) return;
        fwrite(fb.data(), 4, fb.size(), o); fclose(o);
    };
    unsigned long long steps_total = 0;
    std::map<unsigned, unsigned> pc_hist;      // opcode-fetch addresses, last frame
    int frame = 0;
    bool prev_vblank = true;
    int x = 0, y = -1;
    unsigned irq_frames = 0; bool irq_seen = false, prev_irq = false;
    unsigned long long frame_steps = 0;
    unsigned de_pixels = 0;
    unsigned last_fetch = 0;
    unsigned logwin_lo = 0, logwin_hi = 0; unsigned logged = 0;
    // LOGRD=lo,hi[,lo2,hi2] (hex): log every data read inside these address
    // ranges as "frame addr data", the format tools/probe_reads.lua uses
    unsigned rd_lo[2] = {0, 0}, rd_hi[2] = {0, 0}; int nrd = 0;
    FILE *rdlog = nullptr;
    if (getenv("LOGRD")) { nrd = sscanf(getenv("LOGRD"), "%x,%x,%x,%x", &rd_lo[0], &rd_hi[0], &rd_lo[1], &rd_hi[1]) / 2; rdlog = fopen(getenv("RDLOG") ? getenv("RDLOG") : "rtl_reads.txt", "w"); }
    if (getenv("LOGWIN")) sscanf(getenv("LOGWIN"), "%x,%x", &logwin_lo, &logwin_hi);
    // WATCH=addr[,addr...] (hex): count opcode fetches of these per frame
    std::vector<unsigned> watch; std::vector<unsigned> watch_n;
    if (getenv("WATCH")) { char *w = strdup(getenv("WATCH")); for (char *t = strtok(w, ","); t; t = strtok(nullptr, ",")) { watch.push_back(strtoul(t, nullptr, 16)); watch_n.push_back(0); } }
    std::map<unsigned, unsigned> fr_hist, z_hist;
    unsigned z_steps = 0, z_wait = 0, z_s1 = 0, z_s2 = 0, overruns = 0, overruns_total = 0, ovr_tm = 0, ovr_roz = 0, ovr_dr = 0;
    unsigned vc_last = 0xffff;
    unsigned dr_objs0 = 0, dr_rows0 = 0, dr_cols0 = 0, dr_pxw0 = 0;   // the sprite renderer's counters at the last frame print
    unsigned sprw_vis = 0, sprw_blank = 0;      // CPU writes into the sprite RAM this frame, by beam position
    int sprdump = -1; { const char *e = getenv("SPRDUMP"); if (e) sprdump = atoi(e); }   // dump sprite RAM after this frame
    // COINAT=<frame> holds player 1's coin (in0_p1 bit 8, active low) for 8 frames from that frame; STARTAT likewise bit 7
    // COINAT=<frame> holds player 1's coin for 8 frames from that frame; PRESSES=<frame>,<frame>,... presses start
    // for 8 frames from each (the title, the NEW GAME menu, the character select); STARTAT/STARTAT2 are older spellings
    int coinat = -1; std::vector<int> presses; bool mamesched = getenv("MAMESCHED") && atoi(getenv("MAMESCHED"));
    { const char *e = getenv("COINAT"); if (e) coinat = atoi(e);
      e = getenv("STARTAT"); if (e) presses.push_back(atoi(e)); e = getenv("STARTAT2"); if (e) presses.push_back(atoi(e));
      e = getenv("PRESSES"); if (e) { char *w = strdup(e); for (char *t = strtok(w, ","); t; t = strtok(nullptr, ",")) presses.push_back(atoi(t)); } }
    bool ovr_d = false;
    // ZLOG=path: the Z80's writes to the K054539 control registers, the latch
    // and sound_ctrl as "frame W addr data" (tools/probe_z80.lua's format), and
    // its streaming-port reads counted per frame (zs1/zs2 in the frame line)
    FILE *zlog = getenv("ZLOG") ? fopen(getenv("ZLOG"), "w") : nullptr;
    bool zrd_d = false, zwr_d = false;
    std::vector<short> audio; bool want_audio = getenv("AUDIO") && atoi(getenv("AUDIO"));

    while (frame < frames) {
        tick();
        if (want_audio && dut->snd_valid) { audio.push_back((short)dut->snd_l); audio.push_back((short)dut->snd_r); }
        if (dut->dbg_zstep) { z_steps++; z_hist[dut->dbg_zpc]++; }
        if (dut->dbg_zwait) z_wait++;
        if (dut->dbg_spr_we) { if (dut->dbg_vcount >= 16 && dut->dbg_vcount < 240) sprw_vis++; else sprw_blank++; }
        // the overrun flag holds for the whole line: count lines, on the line counter's change
        if (dut->dbg_vcount != vc_last) {
            vc_last = dut->dbg_vcount;
            if (dut->dbg_overrun) { overruns++; if (dut->dbg_overrun_src & 4) ovr_tm++; if (dut->dbg_overrun_src & 2) ovr_roz++; if (dut->dbg_overrun_src & 1) ovr_dr++; }
        }
        ovr_d = dut->dbg_overrun;
        if (dut->dbg_zrd && !zrd_d) { unsigned a = dut->dbg_zpc; if (a == 0xe22d) z_s1++; else if (a == 0xe62d) z_s2++; }
        if (dut->dbg_zwr && !zwr_d && zlog) {
            unsigned a = dut->dbg_zpc, lo = a & 0x3ff;
            if (((a & 0xfc00) == 0xe000 || (a & 0xfc00) == 0xe400) && (lo == 0x22c || lo == 0x22e || lo == 0x22f || lo == 0x214 || lo == 0x215))
                fprintf(zlog, "%d W %04x %02x\n", frame, a, (unsigned)dut->dbg_zwdata);
            else if ((a & 0xfffc) == 0xf000) fprintf(zlog, "%d LAT %04x %02x\n", frame, a, (unsigned)dut->dbg_zwdata);
            else if (a == 0xf800) fprintf(zlog, "%d CTL %02x\n", frame, (unsigned)dut->dbg_zwdata);
        }
        zrd_d = dut->dbg_zrd; zwr_d = dut->dbg_zwr;
        if (dut->dbg_step) {
            steps_total++; frame_steps++;
            if (rdlog && dut->dbg_busstate == 2) {
                unsigned a = dut->dbg_addr;
                for (int i = 0; i < nrd; i++) if (a >= rd_lo[i] && a <= rd_hi[i]) { fprintf(rdlog, "%d %06x %04x\n", frame, a, (unsigned)dut->dbg_data); break; }
            }
            if (tr && logwin_hi && last_fetch >= logwin_lo && last_fetch <= logwin_hi && logged < 400) {
                fprintf(tr, "  bus f%d %s %06x = %04x\n", frame,
                        dut->dbg_busstate == 0 ? "fetch" : dut->dbg_busstate == 3 ? "write" : "read ",
                        (unsigned)dut->dbg_addr, (unsigned)dut->dbg_data);
                logged++;
            }
            if (dut->dbg_busstate == 0) {
                last_fetch = dut->dbg_addr;
                fr_hist[last_fetch]++;
                for (size_t i = 0; i < watch.size(); i++) if (watch[i] == last_fetch) watch_n[i]++;
                if (frame == frames - 1) pc_hist[last_fetch]++;
            }
        }
        if (dut->dbg_irq5 && !prev_irq) irq_seen = true;
        prev_irq = dut->dbg_irq5;
        if (dut->cen_pix) {
            if (dut->de) {
                if (frame == frames - 1 || (snapevery && ((frame + 1) % snapevery) == 0)) {
                    if (y >= 0 && y < VIS_H && x < VIS_W) fb[y * VIS_W + x] = dut->rgb;
                }
                x++; de_pixels++;
            } else if (x) { x = 0; y++; }
            if (dut->vblank && !prev_vblank) {
                // end of a frame
                if (tr) {
                    unsigned hot = 0, hotn = 0;
                    for (auto &kv : fr_hist) if (kv.second > hotn) { hotn = kv.second; hot = kv.first; }
                    unsigned zhot = 0, zhotn = 0;
                    for (auto &kv : z_hist) if (kv.second > zhotn) { zhotn = kv.second; zhot = kv.first; }
                    fprintf(tr, "frame %d: steps=%llu irq5=%d objs=%u overrun=%u unsup=%d de_px=%u pc=%06x hot=%06x(%u) zpc=%04x zsteps=%u zhot=%04x(%u) zwait=%u zs1=%u zs2=%u ovr_tm=%u ovr_roz=%u ovr_dr=%u draw_objs=%u draw_rows=%u draw_cols=%u draw_pxw=%u sprw_vis=%u sprw_blank=%u\n",
                            frame, frame_steps, irq_seen, (unsigned)dut->dbg_objcount,
                            overruns, (int)dut->dbg_unsupported, de_pixels, last_fetch, hot, hotn,
                            (unsigned)dut->dbg_zpc, z_steps, zhot, zhotn, z_wait, z_s1, z_s2, ovr_tm, ovr_roz, ovr_dr,
                            dut->dbg_draw_objs - dr_objs0, dut->dbg_draw_rows - dr_rows0, dut->dbg_draw_cols - dr_cols0, dut->dbg_draw_pxw - dr_pxw0,
                            sprw_vis, sprw_blank);
                    sprw_vis = 0; sprw_blank = 0;
                    dr_objs0 = dut->dbg_draw_objs; dr_rows0 = dut->dbg_draw_rows; dr_cols0 = dut->dbg_draw_cols; dr_pxw0 = dut->dbg_draw_pxw;
                    z_hist.clear(); z_steps = 0; z_wait = 0; z_s1 = 0; z_s2 = 0;
                    overruns_total += overruns; overruns = 0; ovr_tm = 0; ovr_roz = 0; ovr_dr = 0;
                    {   // the ROZ plane's registers and the mixer's, when they change
                        static std::string last_regs;
                        char rb[1400]; int n = 0;
                        n += snprintf(rb + n, sizeof rb - n, "   rozregs: en=%d ctrl=", (int)dut->dbg_roz_en);
                        for (int i = 0; i < 8; i++) n += snprintf(rb + n, sizeof rb - n, "%04x ", (dut->dbg_rozctrl[i / 2] >> ((i & 1) * 16)) & 0xffff);
                        n += snprintf(rb + n, sizeof rb - n, "clip=%04x %04x k55=", dut->dbg_rozclip & 0xffff, (dut->dbg_rozclip >> 16) & 0xffff);
                        for (int i = 0; i < 48; i++) n += snprintf(rb + n, sizeof rb - n, "%02x", (dut->dbg_k55[i / 4] >> ((i & 3) * 8)) & 0xff);
                        if (last_regs != rb) { fprintf(tr, "%s\n", rb); last_regs = rb; }
                    }
                    if (frame == sprdump) {     // the 256 entries x 8 words, as the renderer sees them
                        std::string sp = argv[3]; size_t dot = sp.rfind('.'); if (dot != std::string::npos) sp.resize(dot); sp += ".sprram.txt";
                        FILE *sf = fopen(sp.c_str(), "w");
                        if (sf) { for (int e = 0; e < 256; e++) { fprintf(sf, "%02x:", e); for (int w = 0; w < 8; w++) fprintf(sf, " %04x", SPRRAM[e * 8 + w]); fprintf(sf, "\n"); } fclose(sf); }
                    }
                    for (size_t i = 0; i < watch.size(); i++) { fprintf(tr, "   watch %06x: %u\n", watch[i], watch_n[i]); watch_n[i] = 0; }
                    fr_hist.clear();
                }
                if (irq_seen) irq_frames++;
                {   // scripted inputs for the next frame
                    unsigned in0 = 0xffff;
                    if (coinat  >= 0 && frame + 1 >= coinat  && frame + 1 < coinat  + 8) in0 &= ~0x0100u;
                    for (int pf : presses) if (frame + 1 >= pf && frame + 1 < pf + 8) in0 &= ~0x0080u;
                    if (mamesched) {            // tools/dump_state.lua's schedule, so frames line up with the frozen states
                        int n = frame + 1;
                        if (n > 200 && (n % 120) < 8) in0 &= ~0x0100u;                                   // coin
                        if (n > 240 && (n % 60) < 8 && (n % 120) >= 8) in0 &= ~0x0080u;                  // start
                        if (n > 400) { if (n % 11 < 4) in0 &= ~0x0010u; if (n % 97 < 40) in0 &= ~0x0002u; if (n % 53 < 20) in0 &= ~0x0004u; }   // button 1, right, up
                    }
                    dut->in0_p1 = in0;
                }
                irq_seen = false; frame_steps = 0; de_pixels = 0;
                if (snapevery && ((frame + 1) % snapevery) == 0) {
                    char path[512]; snprintf(path, sizeof path, "%s.f%d", argv[3], frame + 1);
                    save_frame(path);
                }
                frame++; y = -1; x = 0;
            }
            prev_vblank = dut->vblank;
        }
    }

    FILE *of = fopen(argv[3], "wb");
    if (!of) { fprintf(stderr, "cannot write %s\n", argv[3]); return 1; }
    fwrite(fb.data(), 4, fb.size(), of); fclose(of);

    printf("%d frames, %llu clocks, %llu kernel steps (%.1f per frame)\n",
           frames, cycles, steps_total, (double)steps_total / frames);
    printf("IRQ5 seen in %u of %d frames; objects in list: %u; overrun lines=%u unsupported=%d shadow_overlap=%d\n",
           irq_frames, frames, (unsigned)dut->dbg_objcount,
           overruns_total + overruns, (int)dut->dbg_unsupported, (int)dut->dbg_shadow_overlap);
    // top opcode-fetch addresses in the last frame: where the CPU is spending time
    std::vector<std::pair<unsigned, unsigned>> top(pc_hist.begin(), pc_hist.end());
    std::sort(top.begin(), top.end(), [](auto &a, auto &b){ return a.second > b.second; });
    printf("hottest fetch addresses in the last frame:");
    for (size_t i = 0; i < top.size() && i < 6; i++) printf(" %06x(%u)", top[i].first, top[i].second);
    printf("\n");
    if (want_audio) {
        std::string wp = argv[3]; size_t dot = wp.rfind('.'); if (dot != std::string::npos) wp.resize(dot); wp += ".wav";
        FILE *wf = fopen(wp.c_str(), "wb");
        if (wf) {
            unsigned data_bytes = audio.size() * 2, rate = 48000;
            auto u32 = [&](unsigned v) { fputc(v & 255, wf); fputc((v >> 8) & 255, wf); fputc((v >> 16) & 255, wf); fputc((v >> 24) & 255, wf); };
            auto u16 = [&](unsigned v) { fputc(v & 255, wf); fputc((v >> 8) & 255, wf); };
            fwrite("RIFF", 1, 4, wf); u32(36 + data_bytes); fwrite("WAVEfmt ", 1, 8, wf);
            u32(16); u16(1); u16(2); u32(rate); u32(rate * 4); u16(4); u16(16);
            fwrite("data", 1, 4, wf); u32(data_bytes);
            fwrite(audio.data(), 2, audio.size(), wf); fclose(wf);
            printf("audio: %zu stereo samples -> %s\n", audio.size() / 2, wp.c_str());
        }
    }
    if (tr) fclose(tr);
    if (rdlog) fclose(rdlog);
    if (zlog) fclose(zlog);
    delete dut;
    return 0;
}
