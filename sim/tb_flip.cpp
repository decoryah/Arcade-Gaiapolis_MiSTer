// Driver for tb_flip_top: clock it until the bench says it is done.
#include "Vtb_flip_top.h"
#include "verilated.h"
#include <cstdio>

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    Vtb_flip_top *dut = new Vtb_flip_top;
    unsigned long long n = 0, limit = 600ull * 1000 * 1000;
    dut->clk = 0;
    while (!dut->done && n < limit) {
        dut->clk = 0; dut->eval();
        dut->clk = 1; dut->eval();
        n++;
    }
    if (!dut->done) { printf("FAIL: did not finish in %llu clocks\n", n); return 1; }
    printf("%s: %llu clocks\n", dut->fail ? "FAIL" : "PASS", n);
    int rc = dut->fail ? 1 : 0;
    delete dut;
    return rc;
}
