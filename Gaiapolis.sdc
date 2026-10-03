derive_pll_clocks
derive_clock_uncertainty

# ==============================================================================
# SDRAM. The chip is clocked by the PLL's second 96 MHz output, shifted about
# half a period (pll/pll_0002.v); like JTFRAME's MiSTer builds the pin's clock
# is modelled as the machine clock inverted, and the read data -- launched by
# the chip's edge, captured by sdram_ctrl's input register three edges after
# the READ command -- gets a two-cycle path. The register assignments in
# sys/sys.tcl put the SDRAM pins' registers in the IO cells.
# ==============================================================================
set sdram_clk_src [get_pins -nowarn {emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk}]
if { [get_collection_size $sdram_clk_src] == 0 } {
    set sdram_clk_src [get_pins {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
}
create_generated_clock -name SDRAM_CLK -source $sdram_clk_src -divide_by 1 -phase 180 [get_ports {SDRAM_CLK}]

set sys_clk [get_clocks -nowarn {emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk}]
if { [get_collection_size $sys_clk] == 0 } {
    set sys_clk [get_clocks {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
}
set_multicycle_path -from [get_clocks {SDRAM_CLK}] -to $sys_clk -setup -end 2
set_multicycle_path -from [get_clocks {SDRAM_CLK}] -to $sys_clk -hold  -end 2

# the controller's round-robin pointer settles long before it is used (S_IDLE -> S_ARB)
set_multicycle_path -setup 3 -from [get_registers {*|sdram_ctrl:*|last[*]}] -to [get_registers {*|sdram_ctrl:*|*}]
set_multicycle_path -hold  2 -from [get_registers {*|sdram_ctrl:*|last[*]}] -to [get_registers {*|sdram_ctrl:*|*}]

# ==============================================================================
# The machine: the CPUs and the scan-out step on clock enables (carried over from
# the Pocket core, where each was verified against the board's timing).
# ==============================================================================

# TG68K: the kernel steps on a clock enable, at most one step every 4 cycles
set_multicycle_path -setup 4 -from [get_registers {*|TG68KdotC_Kernel:*|*}] -to [get_registers {*|TG68KdotC_Kernel:*|*}]
set_multicycle_path -hold  3 -from [get_registers {*|TG68KdotC_Kernel:*|*}] -to [get_registers {*|TG68KdotC_Kernel:*|*}]

# The scan-out pipeline -- the line-buffer reads, the K055555 priority
# encoder, the palette read and the RGB stage -- re-evaluates once per 8 MHz
# pixel, twelve clocks apart, and its registers latch only at fixed phases
# inside the pixel (k055555_mixer.sv: the address at phase 5, the colour at
# 9), so a path really has those clocks. Registers that clock every cycle
# must never be given a multicycle on that reasoning alone. (The Pocket core also
# granted the palette's read register four; here it is a block RAM output stage
# and the paths to it meet timing as they are.)
set MIX [get_registers {*|k055555_mixer:*|*}]
set_multicycle_path -setup 4 -to $MIX
set_multicycle_path -hold  3 -to $MIX

# TG68K to the board: the kernel's address, data and bus-state outputs settle
# after a clkena step and are sampled only after gaia_main's three-clock gap
# (step_gap), so the decode and the block-RAM write ports have three cycles
# (keepers, not registers: the kernel's register file and the board's RAMs
# are M10K cells, which get_registers does not match)
set_multicycle_path -setup 3 -from [get_keepers {*|TG68KdotC_Kernel:*|*}] -to [get_keepers {*|gaia_main:*|*}]
set_multicycle_path -hold  2 -from [get_keepers {*|TG68KdotC_Kernel:*|*}] -to [get_keepers {*|gaia_main:*|*}]

# The Z80 (tv80) steps on cen_8m, one clock in twelve: its registers, and
# the sound board's registers and RAM ports it drives, change only at those
# steps, and what the board hands back (data, wait) is sampled only there
set Z80 [get_keepers {*|tv80s_cen:*|*}]
set SND [get_keepers {*|gaia_sound:*|*}]
set_multicycle_path -setup 4 -from $Z80 -to $SND
set_multicycle_path -hold  3 -from $Z80 -to $SND
set_multicycle_path -setup 4 -from $SND -to $Z80
set_multicycle_path -hold  3 -from $SND -to $Z80

# ==============================================================================
# The framework's HQ2x blender (sys/hq2x.sv, Blend) updates all of its registers on
# one clock enable, the pixel enable: one clock in twelve here (8 MHz pixels on the
# 96 MHz clock), at most one in six after the scandoubler. The framework does not
# constrain it; its paths have far more than the one clock the analyser assumes.
# ==============================================================================
set_multicycle_path -setup 4 -from [get_registers {*|Blend:*|*}] -to [get_registers {*|Blend:*|*}]
set_multicycle_path -hold  3 -from [get_registers {*|Blend:*|*}] -to [get_registers {*|Blend:*|*}]
