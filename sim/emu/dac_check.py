#!/usr/bin/env python3
"""Checks the OSD's Colours option on two tb_emu runs of the same frames: the default (Board DAC) and COLOURS_MAME=1.
Every pixel of the Board DAC run's picture must be the MAME run's pixel with each channel looked up in the table
(rtl/data/k054573_dac.hex), at the same place: a pixel off by a clock would show as a shifted picture.

    python dac_check.py board_scaler.ppm mame_scaler.ppm [rtl/data/k054573_dac.hex]
"""
import sys

def load(path):
    d = open(path, 'rb').read()
    parts = d.split(b'\n', 3)
    w, h = map(int, parts[1].split())
    return w, h, parts[3]

tab = [int(l, 16) for l in open(sys.argv[3] if len(sys.argv) > 3 else 'rtl/data/k054573_dac.hex') if l.strip()]
assert len(tab) == 256, 'the table has %d entries' % len(tab)
wb, hb, pb = load(sys.argv[1])
wm, hm, pm = load(sys.argv[2])
assert (wb, hb) == (wm, hm), 'sizes differ: %dx%d and %dx%d' % (wb, hb, wm, hm)
bad = [i for i in range(len(pm)) if pb[i] != tab[pm[i]]]
lit = sum(1 for v in pm if v)
same = sum(1 for i in range(len(pm)) if pb[i] == pm[i])
print('%dx%d: %d channel values, %d not black; %d unchanged by the table, %d not the table of the MAME run\'s'
      % (wb, hb, len(pm), lit, same, len(bad)))
for i in bad[:8]:
    p = i // 3
    print('  x %d y %d channel %d: MAME %d, Board DAC %d, table %d' % (p % wb, p // wb, i % 3, pm[i], pb[i], tab[pm[i]]))
print('PASS' if not bad and lit else 'FAIL')
sys.exit(0 if not bad and lit else 1)
