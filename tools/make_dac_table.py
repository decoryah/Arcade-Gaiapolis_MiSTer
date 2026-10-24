#!/usr/bin/env python3
"""make_dac_table.py [out.hex] : the OSD's Colours = Board DAC table (rtl/data/k054573_dac.hex), one byte per code.

The board turns each 8-bit colour into a voltage with a Konami 054573 per channel (brightness from the 054574). Traced
from the Gerbers and BOM of Ace's 054573 reproduction
(https://www.ukvac.com/forum/threads/konami-054573-and-054574-reproductions.84054/): eight open-collector 74LS07 outputs, one per bit, pull a summing node
down through 49k, 24k, 12k, 6k, 3.1k, 1.7k, 800R and 380R (D0..D7) when the bit is 0; the node has 1.2k to ground and is
fed by a current source (the brightness); two diodes and an NPN emitter follower with 220R take it to the output.
A conductance divider, not a resistor ladder: the output rises faster near the top, so mid tones are darker than a
linear DAC (MAME) gives. The source current, 14.5 mA, is the fit to a recording of a Gaiapolis PCB (rms 0.7 of 255
against 10.5 for a linear DAC). The table maps code 0 to 0 and 0xEF, the brightest value the game writes, to 255."""
import math, sys

VT = 0.02585
R_BITS = [49000, 24000, 12000, 6000, 3100, 1700, 800, 380]
ISRC, VOL, BETA = 14.5e-3, 0.2, 200

def diode_v(i, Is=1e-9, n=1.8): return n * VT * math.log(i / Is + 1) if i > 0 else 0.0
def vbe(i, Is=1e-14): return VT * math.log(i / Is + 1) if i > 0 else 0.0

def follower(v29):
    """the emitter follower into 220R: the output voltage for base voltage v29, and its emitter current"""
    lo, hi = 0.0, max(v29, 0.0)
    for _ in range(60):
        vo = (lo + hi) / 2
        if vo + vbe(vo / 220) > v29: hi = vo
        else: lo = vo
    vo = (lo + hi) / 2
    return vo, vo / 220

def node(code, v29):
    """the current the summing node takes for follower base voltage v29, and the output voltage"""
    vo, ie = follower(v29)
    id2 = v29 / 2000 + ie / (BETA + 1); v31 = v29 + diode_v(id2)
    id1 = v31 / 1100 + id2;             v11 = v31 + diode_v(id1)
    i = v11 / 1200 + id1
    for b in range(8):
        if not (code >> b) & 1: i += max(0.0, v11 - VOL) / R_BITS[b]
    return i, vo

def vout(code):
    lo, hi = 0.0, 11.0
    for _ in range(60):
        m = (lo + hi) / 2
        if node(code, m)[0] > ISRC: hi = m
        else: lo = m
    return node(code, (lo + hi) / 2)[1]

v = [vout(c) for c in range(256)]
tab = [max(0, min(255, round(255 * (x - v[0]) / (v[0xef] - v[0])))) for x in v]
out = sys.argv[1] if len(sys.argv) > 1 else 'rtl/data/k054573_dac.hex'
open(out, 'w', newline='\n').write(''.join('%02x\n' % t for t in tab))
print(out, ' '.join('%d:%d' % (c, tab[c]) for c in range(0, 256, 32)), '239:%d' % tab[239])
