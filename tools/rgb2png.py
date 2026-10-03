#!/usr/bin/env python3
"""Turn a 376x224 uint32 RGB raster dump into the ROT90 PNG the snapshots use."""
import sys, os, struct
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pngio
VIS_W, VIS_H = 376, 224
d = open(sys.argv[1], 'rb').read(); buf = struct.unpack('<%dI' % (VIS_W * VIS_H), d)
w, h = VIS_H, VIS_W; out = bytearray(w * h * 3)
for y in range(VIS_H):
    for x in range(VIS_W):
        v = buf[y * VIS_W + x]; o = (x * w + (VIS_H - 1 - y)) * 3
        out[o] = (v >> 16) & 0xff; out[o + 1] = (v >> 8) & 0xff; out[o + 2] = v & 0xff
pngio.write(sys.argv[2], w, h, out)
print('wrote', sys.argv[2])
