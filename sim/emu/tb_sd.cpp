// What the framework's scandoubler makes of this core's raster (see tb_sd_top.sv).
//   tb_sd <frames> <fx 0..7> <forced_scandoubler 0/1> <timing_mame 0/1>
#include "Vtb_sd_top.h"
#include "Vtb_sd_top___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <vector>
static Vtb_sd_top *dut;
static unsigned long long cycles = 0;
static inline void tick() { dut->clk = 0; dut->eval(); dut->clk = 1; dut->eval(); cycles++; }
int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    int frames = argc > 1 ? atoi(argv[1]) : 6, fx = argc > 2 ? atoi(argv[2]) : 0, fsd = argc > 3 ? atoi(argv[3]) : 0;
    int tm = argc > 4 ? atoi(argv[4]) : 0;
    dut = new Vtb_sd_top;
    dut->fx = fx; dut->fsd = fsd; dut->timing_mame = tm;
    dut->reset = 1; for (int i = 0; i < 40; i++) tick(); dut->reset = 0;
    bool phs = false, pvs = false, pde = false;
    unsigned long long last_hs = 0, last_vs = 0, de_start = 0, hs_sum = 0, hs_n = 0;
    long lines_de = 0, hs_edges = 0, ce = 0, de_pix_line = 0; long px_min = 1 << 30, px_max = -1;
    unsigned long long tot_hs = 0, tot_vs = 0, tot_de = 0, tot_ce = 0, pr_vs_arc = 0, pr_vs_g = 0, pr_vs_sd = 0, pr_hs_sd = 0, pr_vb_sd = 0;
    std::vector<int> first_g;
    int fr = 0; unsigned long long limit = (unsigned long long)frames * 2000000ull + 4000000ull;
    printf("frame |   period | HS edges | DE lines | px/line | HS period (clk)\n");
    while (fr < frames + 2 && cycles < limit) {
        tick();
        bool hs = dut->VGA_HS, vs = dut->VGA_VS, de = dut->VGA_DE;
#ifdef PROBE
        {   // inside the framework: arcade_video's VS / HS registers, the mixer's gamma output and scandoubler output
            static bool p1 = false, p2 = false, p3 = false, p4 = false, p5 = false;
            #define P(sig, prev, cnt) { bool v = (sig); if (v && !prev) cnt++; prev = v; }
            P(dut->rootp->tb_sd_top__DOT__av__DOT__VS, p1, pr_vs_arc)
            P(dut->rootp->tb_sd_top__DOT__av__DOT__video_mixer__DOT__vs_g, p2, pr_vs_g)
            P(dut->rootp->tb_sd_top__DOT__av__DOT__video_mixer__DOT__vs_sd, p3, pr_vs_sd)
            P(dut->rootp->tb_sd_top__DOT__av__DOT__video_mixer__DOT__hs_sd, p4, pr_hs_sd)
            P(dut->rootp->tb_sd_top__DOT__av__DOT__video_mixer__DOT__vb_sd, p5, pr_vb_sd)
        }
#endif
        if (dut->CE_PIXEL) tot_ce++;
        if (dut->CE_PIXEL && de) { if (de_pix_line == 0) first_g.push_back(dut->VGA_G); de_pix_line++; }
        if (hs && !phs) tot_hs++;
        if (de && !pde) tot_de++;
        if (vs && !pvs) tot_vs++;
        if (hs && !phs) { hs_edges++; if (last_hs) { hs_sum += cycles - last_hs; hs_n++; } last_hs = cycles; }
        if (de && !pde) { lines_de++; de_pix_line = 0; }
        if (!de && pde) { if (de_pix_line < px_min) px_min = de_pix_line; if (de_pix_line > px_max) px_max = de_pix_line; }
        if (vs && !pvs) {
            if (last_vs) {
                fr++;
                if (fr >= 2) printf("%5d | %8llu | %8ld | %8ld | %3ld-%-3ld | %.1f\n", fr, cycles - last_vs, hs_edges, lines_de, px_min, px_max, hs_n ? (double)hs_sum / hs_n : 0.0);
            }
            if (fr >= 2 && !first_g.empty()) {   // each source line twice, in order (the picture's green is the line number)
                size_t n = first_g.size(); long same = 0, step = 0, pairs = 0;
                int rep = (int)n >= 400 ? 2 : 1;
                for (size_t i = 0; i + rep < n; i += rep) {
                    pairs++;
                    bool eq = true; for (int k = 1; k < rep; k++) if (first_g[i + k] != first_g[i]) eq = false;
                    if (eq) same++;
                    if (i + 2 * rep <= n - 1 && ((first_g[i + rep] - first_g[i]) & 255) == 1) step++;
                }
                printf("      line check: %zu lines, repeated x%d, %ld of %ld repeats identical, %ld of %ld steps +1\n", n, rep, same, pairs, step, pairs);
            }
            first_g.clear();
            last_vs = cycles; hs_edges = 0; lines_de = 0; px_min = 1 << 30; px_max = -1; hs_sum = 0; hs_n = 0;
        }
        phs = hs; pvs = vs; pde = de;
    }
    printf("totals over %llu clocks: VGA_VS rises %llu, VGA_HS rises %llu, DE rises %llu, CE_PIXEL pulses %llu\n",
           cycles, tot_vs, tot_hs, tot_de, tot_ce);
    printf("%s after %llu clocks (%d frames counted)\n", fr >= frames + 2 ? "done" : "STALLED", cycles, fr);
#ifdef PROBE
    printf("probe: arcade_video VS rises %llu, mixer vs_g %llu, vs_sd %llu, hs_sd %llu, vb_sd %llu\n",
           pr_vs_arc, pr_vs_g, pr_vs_sd, pr_hs_sd, pr_vb_sd);
#endif
    delete dut;
    return fr >= frames + 2 ? 0 : 1;
}
