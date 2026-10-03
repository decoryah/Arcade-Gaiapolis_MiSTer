#!/usr/bin/env python3
"""Reads the diagnostic overlay out of a frame captured by tb_emu (<prefix>_scaler.ppm,
376x224): three rows of 32 squares along the bottom, green = 1 (see Gaiapolis.sv for
the meaning of every bit and rtl/dbg_overlay.sv for the geometry).

    python decode_overlay.py emu2_scaler.ppm
"""
import sys

def load(path):
    d = open(path, 'rb').read()
    parts = d.split(b'\n', 3)
    w, h = map(int, parts[1].split())
    return w, h, parts[3]

def bits(px, w, h, y):
    row = []
    for col in range(32):
        x = col * 11 + 5                       # the middle of the square (11 px a square, the last a gap)
        o = (y * w + x) * 3
        r, g, b = px[o], px[o + 1], px[o + 2]
        row.append(1 if (g > 0x80 and r < 0x60) else 0)
    return row

def val(b):
    n = 0
    for v in b:
        n = (n << 1) | v
    return n

def main():
    w, h, px = load(sys.argv[1])
    assert (w, h) == (376, 224), (w, h)
    # visible lines 213..215 are row 0, 217..219 row 1, 221..223 row 2 (a black gap line between)
    rows = [bits(px, w, h, y) for y in (214, 218, 222)]
    r0, r1, r2 = rows
    print("row0 %s" % ''.join(map(str, r0)))
    print("row1 %s" % ''.join(map(str, r1)))
    print("row2 %s" % ''.join(map(str, r2)))
    print("frame counter          %d" % val(r0[0:8]))
    names = ["pll locked", "memories ready", "download", "test held", "(0)", "core in reset", "IRQ5 seen", "68000 stepped"]
    print("flags                  " + ", ".join("%s=%d" % (n, v) for n, v in zip(names, r0[8:16])))
    print("core resets seen       %d" % val(r0[16:24]))
    print("test done=%d running=%d  tile RAM ok=%d bad(log)=%d  Z80 stepped=%d" % (r0[24], r0[25], r0[26], val(r0[27:31]), r0[31]))
    print("68000 bus address      %06x" % val(r1[0:24]))
    reg = ["prog", "snd", "tile", "chr", "map", "pcm", "spr"]
    print("read back ok           " + "  ".join("%s=%d" % (n, v) for n, v in zip(reg, r1[24:31])) + "   sound heard=%d" % r1[31])
    print("read back stable       " + "  ".join("%s=%d" % (n, v) for n, v in zip(reg, r2[0:7])) + "   ddr fifo overflow=%d" % r2[7])
    print("overrun lines last frame %d  sprites/4 %d  unsupported=%d shadow2=%d  overran(tm,roz,spr)=%s" %
          (val(r2[8:16]), val(r2[16:24]), r2[24], r2[25], ''.join(map(str, r2[29:32]))))

if __name__ == '__main__':
    main()
