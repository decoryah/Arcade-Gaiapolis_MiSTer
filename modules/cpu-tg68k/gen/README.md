tg68k.v is generated from the VHDL kernel with GHDL (6.0):

    ghdl -a --std=08 -fsynopsys -frelaxed TG68K_Pack.vhd TG68K_ALU.vhd TG68KdotC_Kernel.vhd
    ghdl synth --std=08 -fsynopsys -frelaxed --latches --out=verilog TG68KdotC_Kernel > gen/tg68k.v

Both Quartus and Verilator compile this file; the VHDL is kept for reference only.
Regenerate with tools/gen_vhdl_cores.sh.
